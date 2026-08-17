# 0.4.0 DevTools perf 与 net 画像

> 状态：提案中
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

net 的 URL 默认只保留 scheme 类别、host 哈希和 path 段形状；数字、UUID 和疑似 token 段归一化。
header/body/query 永不进入原始缓冲。达到事件数或字节上限后停止收集并报告 `truncated: true`，不能
静默丢样。

## 兼容、安全与验证

- capability 不存在时显式 unavailable；不从错误文本猜支持情况。
- release 不注册采集扩展；debug/profile 的启用也必须由 consumer 显式声明。
- 单测用含 token、邮箱、UUID、中文业务路径的样本证明输出不可还原敏感值。
- 压测覆盖事件上限、取消和超时；VM/direct 返回相同聚合口径。
- 至少一个接入方对 perf、两个接入方对 net 脱敏样本进行评审后，net 才可越过 DG-040-03。

## 待裁决

- host 使用哈希还是固定占位符；提案默认带进程级随机盐的哈希，避免跨会话关联。
- path 段的封闭归一化规则和默认采样上限。

## 被否决方案

- 先收全量再在输出时脱敏：敏感值已经进入内存与 artifact，边界过晚。
- 直接转发 DevTools 原始事件：schema、体积和隐私都无法稳定承诺。
