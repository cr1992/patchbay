# 0.5.0 Audit sink 顺序投递与有界背压

> 状态：已接受
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

overflow、delivery closed 与普通 sink failure 都复用
`onAuditSinkError(error, stackTrace, event)`。新增公开错误类型
`PatchbayAuditDeliveryOverflow`，字段只含 `droppedCount/firstSequence/lastSequence/capacity`；新增
`PatchbayAuditDeliveryClosed`，只含未投递事件的 `sequence`。传给 observer 的 event 是对应的已脱敏事件，
不构造含原值的旁路日志。overflow observer 的 event 固定为 burst 的第一条 dropped event；dispatcher 最多
为当前 burst 额外保留这一条已脱敏引用。overflow burst 在下一条事件恢复 enqueue，或 drain 终结 dispatcher
时结束并只通知一次；因此通知中的 count/range 是完整事实，而不是第一条 drop 的临时快照。

host 新增显式 `Future<PatchbayAuditDrainResult> drainAudit({Duration timeout = const Duration(seconds: 2)})`，
并由 additive async `Future<void> dispose({Duration auditTimeout = const Duration(seconds: 2)})` 调用。audit
dispatcher 只持有一个幂等的 terminal Future；第一次 `drainAudit`（含 dispose 内部调用）关闭 enqueue 闸并
冻结本次 timeout，后续 `drainAudit` 忽略自己的 timeout 参数并返回同一 Future，不允许同一 dispatcher 被
drain 两次得到两份终态。`dispose` 自身也幂等，但只等待 audit terminal Future 后完成，不把 host 生命周期的
公开返回类型绑定为 audit result；需要终态统计的调用方显式调用 `drainAudit`。这样后续 host 子系统可以在
`dispose` 中按顺序加入自己的 terminal 步骤，而不改写本提案的 audit result。`PatchbayAuditDrainResult` 字段固定为
`outcome: PatchbayAuditDrainOutcome.drained | timedOut`、`settledCount`、`overflowDroppedCount` 与
`abandonedCount`。其中 settled 是 terminal result 形成前已经 settle 的闸前 accepted event 累计数，包含关闸前
与 drain 等待期间完成的 sink Future；overflow 是 drain 闸前因满载未进入 sink 队列的累计数；abandoned 只在
timeout 时计算，为该时刻仍 active 与 waiting 的总数。三类互斥，且三者之和必须等于该 sink 在闸前对应的
ledger event 数；`drained` 的 abandoned 固定为 0。未配置 sink 时四项分别为 `drained/0/0/0`。timeout 是
受控资源结果，不抛异常；成功只表示 drain 闸前已接收事件的 sink Future 都 settle，不表示每项 sink 成功。

## 状态、失败与预算

dispatcher 状态为 `open -> draining -> closed`。draining 后拒绝新 sink enqueue；已经发生但晚于关闭闸的
命令仍保留在 ledger，并以 `PatchbayAuditDeliveryClosed` 异步通知 observer，不能悄悄消失，也不能让 observer
时延进入 invocation response。closed 后不再调用 sink；迟到的已启动 sink Future 只被安全吸收，不能重新
启动队列或改写已经返回的 drain 结果。

队列容量默认 256，与 audit ledger retention 对齐，并且**同时计入一个 active sink Future 与所有 waiting
事件**；因此任意时刻由 dispatcher 保留的未 settle 事件总数不超过 capacity。队列满时保留已经接收的前缀、
丢弃最新事件：这样 sink 恢复后先交付无缺口的最长前缀，overflow sequence 精确指出缺失区间；不得驱逐
较老未投递事件制造一个看似连续但中间缺口未知的后缀。一个持续 overflow burst 聚合成一次 observer 通知，
恢复可 enqueue 后结束 burst，避免 error observer 自身被放大；永久不 settle 时由 drain timeout 终结 burst。

drain timeout 接受 `Duration.zero..30s`。队列容量由 additive host 参数配置为 `1..4096`；0 不合法，禁用
sink 继续通过 `auditSink: null` 表达，避免第三种状态。timeout 时 waiting 队列立即清空并计入
`abandonedCount`；已经启动的一个 sink Future 无法被 Patchbay 伪造取消确认，也计入本次 immutable result
的 abandoned 事实，其迟到 settle 只负责释放引用。若迟到 settle 失败，仍按普通 sink failure 调用一次
error observer，但不能重启队列、改变 drain 结果或把该事件从 abandoned 改记为 settled。

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
- 平台预检：不需要业务接入方验收；仓内 example 用慢 sink 在 Android 真机与 iOS 模拟器分别验证有界内存、
  dispose 终态和 invocation response 不受影响，profile 数值只从 profile 会话记录。
- 失败注入：永久不 settle sink、连续 throw、dispose 与 enqueue 同时发生，命令结果逐字节不变。

## 裁决结果

已接受。capacity 默认 256，计入 active 与 waiting；满时保留已接收前缀、丢最新，以精确 burst range 报告
缺口。drain 默认 2 秒、上限 30 秒，timeout 返回结构化 `PatchbayAuditDrainResult` 而不抛异常；超时不能
伪装成已取消已经启动的 sink Future。PB-050-05 实现须在 PB-050-03 的 host 热点改动进入 `dev/0.5.0`
后再基于新主线串行推进，Proposal 本身可独立先合入。

## 被否决方案

- 在 invocation 返回前直接 await sink：外部审计存储会改写命令延迟与超时，违反 sink failure 隔离。
- 每个事件继续独立 Future、只加 pending counter：限制了数量但仍不保证 settle/持久化顺序。
- 队列满时阻塞新命令：把审计背压升级为业务 admission 事实，违背既有 best-effort 契约。
- 自动重试 sink failure：没有 audit event idempotency/dedup 契约，会制造重复记录。
- 只写日志报告 overflow：日志可能未接、不可结构化处理，也容易泄漏错误上下文。
