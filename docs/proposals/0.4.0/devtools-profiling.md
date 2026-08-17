# 0.4.0 DevTools perf 与 net 画像

> 状态：已接受
>
> 关联：PB-040-09
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

采集命令声明 `durationMs` 和采样上限，返回 jobId；终态 payload 带窗口、样本数、丢弃数和
`factSource: appRecorded`。perf/net 各有独立 capability。direct 连接仍由 host 调用同一采集器，不另造
HTTP 代理或抓包路径。

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
- 压测覆盖事件上限、取消和超时；VM/direct 返回相同聚合口径。
- 接入方评审的产物是**对上述 golden 的书面确认**（记入 MR 描述），不是一次口头 review；至少一个
  接入方确认 perf、两个确认 net，net 才可合入。

## 已裁决预算

- 采集窗口、事件数与缓冲字节上限已在兼容、安全与验证一节冻结。

## 被否决方案

- 先收全量再在输出时脱敏：敏感值已经进入内存与 artifact，边界过晚。
- 直接转发 DevTools 原始事件：schema、体积和隐私都无法稳定承诺。
- 用"疑似 token"之类的启发式判断决定归一化：不可判定，两次实现会得到两种结果。
- 只说"不采集完整 query"而不规定键名处理：键名本身可能就是敏感信息。
