# 0.4.0 DevTools perf 与 net 画像

> 状态：已接受
>
> 关联：PB-040-09（perf，0.4.0 交付）、PB-040-28（net，已延期，无目标版本）
>
> 设计闸门：DG-040-03

## 问题

inspect 已能借用 VM Service，但性能和网络问题仍需跳回 DevTools 人工查看。直接暴露完整网络请求会
泄露认证头、query 和 body；两条传输若各自采集又会出现结果口径漂移。

## 目标与非目标

- perf 先提供有限窗口的帧耗时、jank 计数、heap 摘要和 GC 计数。
- net 只提供脱敏画像：方法、归一化 host/path 形状、状态类别、大小和耗时。
- 采集与读取分离，使用有限预算和 artifact/snapshot 引用。
- 不替代完整 DevTools，不采集 body、认证头、完整 query、cookie 或业务明文。

## 契约与预算

### perf 当前交付形态

`perf profile` 是 CLI 对**已经连接的 VM Service** 发起的一次同步有限窗口观测，不注册 App catalog
命令，也不伪装成 host job。它只调用 `vm_service` 的公开 `getVMTimelineFlags`、
`setVMTimelineFlags`、`getVMTimelineMicros`、`streamListen` / `streamCancel` 与 `getMemoryUsage` RPC：临时补齐
`Dart` / `Embedder` / `GC` stream，结束或失败时恢复原 stream 集合。输出是
`patchbay.performanceProfile.v1` 有界摘要，`factSource: uiObserved`，不转发原始 timeline event。

请求声明 `durationMs`（默认 10 s，范围 1..60000）和 `sampleLimit`（默认/最大 10000）；结果固定包含
窗口、接收/处理/丢弃事件数、截断标记、frame build/raster 耗时摘要、16 ms jank 计数、两次 heap
观测与新/老生代 GC 计数。已处理事件的计量预算最大 8 MiB；事件数或字节任一先到即停止汇总并明确
`truncated: true`。timeline event 逐批到达即汇总，不保留原始事件列表；达到预算就取消订阅，原始
事件不进入 Patchbay artifact、日志或输出。

direct 没有 VM timeline collector，必须返回 `profilingVmServiceRequired`，不得用 App snapshot 或
HTTP 往返时间伪造同口径。未来只有接入方注入与 VM 版同输入、同聚合器的 host collector 后，才可在
direct 发布 perf capability；届时再把长窗口采集升级为 host job + artifact/snapshot 引用。

### net 的实现阻断

CLI 保留 `net profile` 入口，但当前稳定返回 `networkProfilingUnavailable`，不发布 net capability、
不调用网络画像 RPC。仓内解析的 `vm_service 15.2.0` 只有 `getHttpProfile` /
`getHttpProfileRequest`：公开返回类型 `HttpProfileRequest` 在调用方介入前已经包含 request/response
body、headers、cookies 与带 query 值的 URI，且 RPC 没有采集前排除这些字段的参数。先取回再脱敏正是
本提案否决的方案，因此不能接。等待公开 API 支持采集前字段过滤，或接入方提供只产生已脱敏事件的
host collector 后，再实现下述 net 契约。

net 的 URL 默认只保留 scheme 类别、host 哈希和 path 段形状。header/body 永不进入原始缓冲。达到事件
数或字节上限后停止收集并报告 `truncated: true`，不能静默丢样。

### host 哈希的盐

盐随 **App 进程**生成。这样同一次调试内可以判断"这些请求打的是同一个 host"，跨会话则关联不上。
代价要写明：hot restart 会换盐，重启前后的同一 host 哈希对不上——把它当稳定标识去跨会话比较会得
出错误结论。

### path 段归一化是封闭规则，不是"疑似"判断

"疑似 token"不可判定，实现两次会得到两种结果。URL 先由标准 URI parser 拆成 path segments；每段只
做一次 percent decode，解码失败直接归一为 `{opaque}`。其余规则按序匹配：

| 形状 | 归一化为 |
|---|---|
| 纯数字段 | `{n}` |
| ASCII 大小写不敏感匹配 `^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` | `{uuid}` |
| 长度 ≥ 20，且匹配纯 hex `^[0-9A-Fa-f]+$` 或 base64url `^[A-Za-z0-9_-]+={0,2}$` | `{opaque}` |
| 其余 | 保留原文 |

最后一条是有意的：保留下来的段可能含业务词汇（包括中文路由）。上面的规则宁可把一个很长的普通
ASCII 段过度脱敏，也不允许依赖实现自选的熵算法；完全不保留其余 path 形状，net 画像又没有诊断价值。
这是一次明确取舍，不是疏漏。

### query 只留键名，且键名也过白名单

"不采集完整 query"留白太大——键名本身可能就是敏感信息（`?invite_code=`）。规则是：只保留
descriptor 白名单内的键名（排序去重），其余归一成 `queryKeyCount`，**任何 query 值都不保留**。

## 兼容、安全与验证

- 默认采集窗口 10 s，最大 60 s；单次 job 最多接收 10000 个事件和 8 MiB 已脱敏缓冲，任一上限先到即
  停止并返回 `truncated: true`。接入方可以配置更小值，不能突破这些上限。
- **未接线即不进目录**，与 `ui.capture` / `navigation.*` 一致，而不是像 keep-awake 那样留在目录里报
  未接线。两者理由不同：操作者伸手去按 keep-awake 恰恰是在 UI 面全挂的时候，那时 `commandNotRegistered`
  什么也没解释；而"性能命令不见了"不会被误判成设备故障。
- capability 不存在时显式 unavailable；不从错误文本猜支持情况。
- release 不注册采集扩展；debug/profile 的启用也必须由 consumer 显式声明。
- 仓内提交一份**冻结脱敏样本**：含 token、邮箱、UUID、中文业务路径、长 query 的输入，与期望输出
  golden。四条 path 归一化规则与 query 白名单各有正反用例。
- 断言 hot restart 前后同一 host 的哈希不同（盐已更换），防止有人把它当稳定标识用。
- perf 压测覆盖事件/字节上限、超时与失败时 stream 恢复；direct 明确返回
  `profilingVmServiceRequired`。未来 host-injected collector 开放 direct 前，必须证明它与 VM 路径使用
  同一聚合器；当前 direct 不伪造结果。
- net 脱敏 golden 与两接入方书面确认留作 net collector 的合入闸；当前阻断 MR 不用 fake source
  冒充已交付，也不把收全量后的纯脱敏函数接到生产路径。
- 接入方评审的产物是**对上述 golden 的书面确认**（记入 MR 描述），不是一次口头 review；至少一个
  接入方确认 perf、两个确认 net，net 才可合入。

## 已裁决预算

- 采集窗口、事件数与缓冲字节上限已在兼容、安全与验证一节冻结。

## 被否决方案

- 先收全量再在输出时脱敏：敏感值已经进入内存与 artifact，边界过晚。
- 直接转发 DevTools 原始事件：schema、体积和隐私都无法稳定承诺。
- 用"疑似 token"之类的启发式判断决定归一化：不可判定，两次实现会得到两种结果。
- 只说"不采集完整 query"而不规定键名处理：键名本身可能就是敏感信息。
