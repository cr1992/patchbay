# 0.5.0 Audit sink 顺序投递与有界背压

> 状态：提案中
>
> 关联：PB-050-05
>
> 设计闸门：DG-050-03

## 问题

host 先把 `PatchbayAuditEvent` 写入 256 条内存 ledger，再对每个事件独立启动
`Future.sync(() => sink(event))`。同步调用的启动顺序与 ledger 一致，但异步 sink 的 settle/持久化顺序没有
保证；慢 sink 还会让未完成 Future 无上限增长。审计流水先失去顺序、再失去内存上限，比普通遥测丢点
更严重。

0.4.0 已接受契约同时要求：sink failure 不得改写已经发生的命令事实，错误由 `onAuditSinkError` 隔离观测。
因此不能简单 `await sink` 并让命令结果受外部存储速度或失败影响。

## 目标与非目标

### 目标

- host 以 ledger insertion sequence 为唯一顺序，单消费者在前一事件 Future settle 后才调用下一事件。
- 等待投递的事件数量有界；overflow 的数量与区间可通过既有 error observer 观测。
- sink、error observer 抛错与队列 overflow 都不改写 invocation response、admission 或 execution evidence。
- host dispose 提供有预算的 drain，预算耗尽后有明确丢失事实。

### 非目标

- 不声称 sink 调用成功等于外部系统已 durable commit；durability 由 sink Future 自己的完成语义定义。
- 不把 audit 自动传输给 CLI trace，也不新增跨进程 event stream。
- 不记录参数值、hash 或 payload；现有 parameterShape 脱敏边界不变。
- 不改变 requestId replay 时“纯重放不重复写 execution audit”的契约。

## 契约

`PatchbayAuditSink` 与 `PatchbayAuditSinkErrorHandler` 的公开签名保持不变。host 内部为每个 sink 建一个
FIFO dispatcher；`_recordAudit` 完成 ledger 记账后只做非等待 enqueue。dispatcher 串行执行：

```text
enqueue sequence N
  -> previous sink Future settled
  -> invoke sink(N)
  -> success | report sink failure
  -> invoke sink(N+1)
```

顺序定义是“开始调用 sink 的顺序严格等于 ledger sequence，且同时最多一个 sink Future 未完成”。如果
sink 只有在 durable write 后才 complete，则 durable 顺序也随之成立；否则 Patchbay 不替外部系统背书。

overflow 与普通 sink failure 都复用 `onAuditSinkError(error, stackTrace, event)`。新增公开错误类型
`PatchbayAuditDeliveryOverflow`，字段只含 `droppedCount/firstSequence/lastSequence/capacity`；传给 observer
的 event 为导致 overflow 被发现的已脱敏事件，不构造含原值的旁路日志。

host 新增显式 `drainAudit({Duration timeout})`，dispose 内调用同一逻辑。成功只表示队列内事件的 sink
Future 已 settle，不表示每个 sink 成功；超时返回/抛出类型化的 drain 结果，不能阻塞无限时间。

## 状态、失败与预算

dispatcher 状态为 `open -> draining -> closed`。draining 后拒绝新 enqueue；已经发生但晚于关闭闸的命令
仍保留在 ledger，并报告 delivery closed，不能悄悄消失。closed 后不会再调用 sink/error observer。

推荐队列容量为 256，与 audit ledger retention 对齐。队列满时本稿建议**保留已经排队的前缀、丢弃最新
事件**：这样 sink 恢复后交付的是无缺口的最长前缀，overflow sequence 明确指出从何处开始缺失；不得
驱逐较老未投递事件制造一个看似连续但中间缺口未知的后缀。一个持续 overflow burst 聚合成一次 observer
通知，恢复可 enqueue 后结束 burst，避免 error observer 自身被放大。

默认 drain timeout 推荐 2 秒，可配置 `Duration.zero..30s`。队列容量推荐可配置 `1..4096`；0 表示禁用
sink，应通过 `auditSink: null` 表达，避免第三种状态。

sink failure 消费当前事件并继续下一项，不自动重试；自动重试会在没有幂等 sink 契约时制造重复审计。
error observer 抛错继续吞掉，不停止 dispatcher。

## 兼容与降级

- 未配置 sink 时行为不变，只有 256 条 ledger。
- 现有同步 sink 仍按相同回调签名工作；差异只是从调用栈内启动变为队列 microtask 启动。
- 现有异步 sink 从无序并发变为单消费者；这是本提案明确修正的语义变化。
- VM/direct 调用共用同一 host dispatcher，排序按 host 受理后 `_recordAudit` 的全局 sequence，不按 transport
  各排一条队列。
- 老 host 没有 drain API；调用方不得从 dispose 成功猜测 audit 已清空。

## 安全与隐私

队列只保存现有 `PatchbayAuditEvent` 的脱敏投影。overflow/error details 不含 arguments、response、token、
URI 或 exception message。sink error 的 StackTrace 只交给 App 内 observer，不进入 wire/CLI。

## 验证

- 单元/协议测试：同步/异步 sink、不同延迟、sink throw、observer throw、burst overflow、恢复后新 burst、
  drain success/timeout、dispose race、replay 不重复。
- 受控 sink 记录 active count，断言始终 `<= 1`；sequence 严格递增且前一 Future settle 后才开始下一项。
- 容量边界 1、256、最大值；overflow 聚合的 count/range 精确，ledger 本身仍保留最后 256 条。
- VM/direct：交错发起请求，最终 audit sequence 只由 host 记账决定，两个 transport 无独立队列。
- 接入方/真机：不需要业务真机；example 用慢 sink 压测并记录 profile 内存上界。
- 失败注入：永久不 settle sink、连续 throw、dispose 与 enqueue 同时发生，命令结果逐字节不变。

## 待裁决

- 接受“保留前缀、丢最新”还是改为丢最老？本稿推荐保留前缀，因为审计缺口起点可证明。
- 默认 queue capacity 是否与 ledger 同为 256？
- `drainAudit` 应返回结构化结果还是在 timeout 时抛公开异常？

## 被否决方案

- 在 invocation 返回前直接 await sink：外部审计存储会改写命令延迟与超时，违反 sink failure 隔离。
- 每个事件继续独立 Future、只加 pending counter：限制了数量但仍不保证 settle/持久化顺序。
- 队列满时阻塞新命令：把审计背压升级为业务 admission 事实，违背既有 best-effort 契约。
- 自动重试 sink failure：没有 audit event idempotency/dedup 契约，会制造重复记录。
- 只写日志报告 overflow：日志可能未接、不可结构化处理，也容易泄漏错误上下文。
