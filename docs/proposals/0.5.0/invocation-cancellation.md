# 0.5.0 Invocation cooperative cancellation、deadline 与统一受理预算

> 状态：已接受
>
> 关联：PB-050-06
>
> 设计闸门：DG-050-04

## 问题

direct host 在请求 timeout 后刻意保留 `_activeRequests` slot，直到处理 Future 真正 settle；默认容量为 1。
这是防止卡死 handler 后继续堆积的安全选择，不是待修的计数错误。没有 cooperative cancellation 时，
仅因 HTTP 调用方不再等待就释放 slot，只会把仍在执行的工作从账本里藏起来。

另一方面，VM Service host 只有 external fallback 的 requestId ledger 上限 256；registry `tryDispatch` 不经过
统一运行容量闸。当前也没有上下文让 handler 区分 caller deadline、transport disconnect、host dispose 或
显式 cancel，更无法证明底层副作用已经停止。

## 目标与非目标

### 目标

- deadline 只表达调用方等待预算；取消请求、取消已观察、底层停止确认与 handler settle 分开记账。
- 为 registry 与 external handler 提供 additive cooperative cancellation context，legacy handler 不破坏。
- 建立 transport 之上的 host-wide admission budget，registry/external 共用；direct 的 HTTP 请求容量仍是外层门。
- 只有完整 invocation pipeline settle，或 handler 已启动且 consumer 明确确认底层停止且不再产生副作用，
  才能回收执行 slot。
- VM Service 与 direct 返回相同 code/details；transport 只能提供不同 cancellation trigger，不能重写事实。

### 非目标

- 不把 Dart Future 强制终止；Patchbay 只发信号并等待 consumer 证明。
- 不改写 `PatchbayJobRegistry` 的 cancel callback、终态或 retainedJobs。job 是已受理后的业务生命周期，本提案
  处理的是一次 invocation handler 的生命周期。
- 不因 caller disconnect 自动写 `cancelled` 业务结果，也不承诺 legacy handler 在 deadline 后释放容量。
- 不把 handler 在 confirmation 后正常完成清理或返回迟到结果本身判成新副作用；host 看不见 controller 外部
  世界，不能据此永久熔断 command。

## 公共上下文与接入形状

新增不可变 `PatchbayInvocationContext`，至少提供：

```dart
requestId
deadline // host 本地 monotonic deadline；未声明时为 null
cancellation // 只读 signal：isRequested、reason、whenRequested
registerCancellationConfirmation(Future<void> Function(reason) callback)
```

公开 deadline 不使用 wall-clock `DateTime`；consumer 读取 host 以可注入 monotonic clock 计算的 remaining/
expired 视图。取消 reason 为封闭词表：
`callerDeadlineExceeded | callerDisconnected | explicitRequest | hostDisposed`。第一次 trigger 冻结 reason，
后续 trigger 不重复调用 callback，也不覆盖已观察事实。

`registerCancellationConfirmation` 每次 invocation 最多成功注册一次。取消先到、callback 后注册时，host 在注册
后立即且只调用一次；callback 先注册则在 signal 到达时调用。callback Future 成功只表示 consumer 声明底层
已停止且以后不再产生副作用；callback 缺失、抛错或在观察预算内未完成都不是确认。迟到成功仍可把内部状态
推进为 confirmed 并释放执行 slot，但不得改写已经返回的 response 或 drain result。

registry 新增独立 context-aware registration 入口；既有 `PatchbayCommandHandler<T>` 与默认构造保持不变，
一个 registration 不能同时提供 legacy 与 context-aware handler。external source 同样新增 context-aware 入口，
既有 `PatchbayInvocationSource` 保持可用；host 构造必须在两种 source 中恰选一种，不要求接入方为了采用新 API
同时实现一份假的 legacy handler。

取消发生在 catalog、gate 等 handler 前置阶段时，host 在前置 Future settle 后不得再启动 handler；但仅仅丢弃
continuation 不能证明该 Future 已停止，因此执行 slot 仍保留到完整 pipeline settle。handler 已启动后，只有
handler settle 或 confirmation 成功能够释放 slot。

## Deadline 与 invocation response

wire 只传相对毫秒预算，host 收到后换算成本地 monotonic deadline。direct 继续使用既有
`x-patchbay-deadline-ms`，但 header 值必须是调用方声明的 deadline 本身；client 为网络往返另加的 socket
headroom 只用于本地 wait，不能写进 header 冒充更长的 caller budget。VM Service 在 host 声明
`invocationCancellation` feature 时允许 invoke 增加严格的可选 `deadlineMs` 参数，范围 1..300000。新 CLI 对
没有 feature 的老 host 不发送该参数，只在客户端停止等待并显示 `cancellationMode: legacyWaitOnly`；未知字段
在新老 host 上仍 fail-closed。

同一 feature 还允许 invoke 携带 client 生成的 `ownerToken`：128-bit、base64url、每次新 owner 唯一。它不是
consumer argument，也不进入 catalog policy；host 只用它把迟到 cancel 围栏在原 owner。新 CLI 只在 feature
存在时发送；legacy invoke 没有 token 时由 host 生成内部 token，仍可接收 deadline/dispose signal，但不能被
新 CLI 通过显式 cancel 猜测寻址。

feature-aware direct invoke 的 strict body 是既有 identity 公共字段加必填
`command/arguments/requestId` 与可选 `ownerToken`；deadline 只在 header，不复制进 body。feature-aware VM
invoke 仍是既有 `command/args/requestId` 加可选 `deadlineMs/ownerToken`。两端未知字段继续拒绝。

VM Service 的 identity `features` 已有能力声明。direct 的 `/identity` **result** additive 增加同一
`features` 列表；request body 与 response envelope 中用于 runtime pin 的 identity projection 仍严格只有
`schemaVersion/applicationId/appInstanceId`。实现必须拆开 request identity 与 capability response serializer，
不能直接扩写当前两用的 `PatchbayDirectIdentity.toJson()`。新 direct client 先读 identity result 再决定是否发送
`ownerToken` 或调用 cancel endpoint；字段缺失按老 host 降级。既有 direct deadline header 不受 feature gate，
对老 host 仍照常发送 caller budget，只是不把 transport wait 冒充 cooperative cancellation。

任一 cancellation trigger 在 invocation 信封返回前被 terminal arbiter 观察到时，都冻结一份 rejected envelope；
stable code 与第一次 reason 一一对应：

| reason | rejection code |
|---|---|
| `callerDeadlineExceeded` | `invocationDeadlineExceeded` |
| `callerDisconnected` | `invocationCallerDisconnected` |
| `explicitRequest` | `invocationCancelled` |
| `hostDisposed` | `hostDisposed` |

四种 rejection 的 details 都固定包含：

```text
reason: callerDeadlineExceeded | callerDisconnected | explicitRequest | hostDisposed
cancellation: unsupported | requested | confirmed | unconfirmed
```

deadline response 不额外等待 confirmation，因为调用方预算已经耗尽；pending callback 可在后台迟到确认并释放
slot。caller disconnect 时当前 socket 可能已无接收方，但 host 仍把 `invocationCallerDisconnected` envelope 冻结
进 owner，之后的 external idempotent replay 与 audit 使用同一份事实，不能改写成通用 transport error 或
`invocationCancelled`。若 handler settlement 与 deadline/disconnect trigger 在同一 event turn 都已就绪，
先被 host terminal arbiter 观察到的 settlement 生效；每个 owner 只能冻结一份 response 且容量只能释放一次。
迟到 handler 结果被吸收，不能覆盖已冻结的 cancellation response。若迟到结果是 accepted job，也不能把旧
rejection 改成 accepted；job 是否已经产生副作用仍只能由 consumer 事实说明。

显式 cancel 与 host dispose 同样在 trigger 时冻结上表 envelope；cancel operation / drain 可以继续等待
confirmation，但不能回写原 invocation response。已经返回 accepted 并启动 job 的命令已不再是 running
invocation，由 job 契约继续管理。

## 显式 cancel 协议面

显式 cancel 不复用 consumer catalog command，也不向严格 invoke body 添加 operation 字段。新增：

- VM Service method：`ext.patchbay.cancelInvocation`；
- direct endpoint：`/patchbay/direct/v1/cancel-invocation`。

VM 参数只允许 `isolateId/command/requestId/ownerToken`；direct body 只允许既有 identity 公共字段加
`command/requestId/ownerToken`。两端都以当前 appInstance/session 授权，并以
`(command, requestId, ownerToken)` 寻址；协议不提供列举 requestId 或 token 的能力。当前授权控制器持有准确
三元组即可请求，host 不虚构 transport 无法证明的“原始客户端本人”身份。ownerToken 不匹配一律返回
`unknown`，不能退回二元 tuple 猜测当前 owner。

新增稳定结果 `PatchbayInvocationCancellationResult`，两端 `result` 字段逐字节同构：

```text
command
requestId
outcome: confirmed | unconfirmed | unsupported | settled | unknown
reason // running owner 存在时为第一次冻结的 cancellation reason
confirmation // unconfirmed 时为 pending | callbackFailed | timedOut
```

显式 cancel 使用 host 配置的 confirmation 观察预算，默认 2 秒、范围 0..30 秒。`confirmed` 只来自 callback
成功；callback pending/throw/预算耗尽均返回 `unconfirmed`，`confirmation` 只给稳定分类，不含 exception message。
legacy owner 返回 `unsupported`。已保留 settled tombstone 返回 `settled`；超出保留窗或从未存在返回
`unknown`。重复 cancel 复用同一 signal/callback 和当前状态，不二次触发副作用。

cancel 是释放资源所必需的控制面，不能先经过可能已被目标 invocation 占满的普通 admission。VM cancel method
不占 host execution slot；direct cancel endpoint 也绕过普通 `_activeRequests`，改走独立
`maxConcurrentCancellationRequests`，默认 1、范围 1..8。控制通道仍依次经过 origin/expiry/auth、当前 identity、
bounded body、strict fields 与 response limit；满载只拒绝额外 cancel，不影响已经进入的那条。signal 先发出，
再在固定 confirmation 预算内形成 result，因此 callback 永不 settle 也会释放控制 slot。该专用通道不能承载
identity/catalog/snapshot/invoke 或任意 consumer command。

## 状态、记录与容量

内部 owner 状态机：

```text
admitted -> running -> settled
                  -> cancelRequested -> cancelConfirmed -> settled
                                     -> cancelUnconfirmed -> cancelConfirmed | settled | wedged
admissionRejected
```

`cancelConfirmed` 允许回收 execution slot，但 owner record 必须保留到原 handler Future settle；否则相同 owner
可能重新执行。handler settle 后才进入普通 retention/淘汰。confirmation 后的迟到 settlement 只记
`lateHandlerSettlement` 分类，不等同于 consumer 产生新副作用，不永久熔断 command。

host-wide `maxConcurrentInvocations` 默认 8，配置范围 1..256，限制正在占用 execution slot 的 registry +
external owner。8 与 direct 现有 `maxConcurrentRequests` 上限一致，避免默认 host 比任一 direct 配置更窄；它仍
允许 VM Service 并发，又不以未经量测的 32 路工作压向 App isolate。满容量稳定拒绝
`invocationCapacityExceeded`，details 只含 `limit/running`。

host 另以 256 条 active-owner 硬上限约束完整 pipeline 尚未 settle 的 record，包括已 confirmed、已释放
execution slot 但 handler Future 仍未完成的 owner；满时拒绝 `invocationRecordCapacityExceeded`。这避免
consumer 连续“确认后永久不 settle”造成无界 requestId 记录。external 既有 256 条 replay ledger 仍独立存在，
只淘汰 handler 已 settle 的记录；running/confirmed-late owner 不被 eviction 伪装成可重试。另保留最新 256 条
settled cancellation tombstone，只含 command/requestId/ownerToken/settled 状态，用于把准确 token 的迟到 cancel
答成 `settled`；淘汰后答 `unknown`，不能命中新 token 的后继 owner。

external 的 lookup/replay 必须发生在 active-owner 256 与 execution admission 之前，并完整保留既有条件：只有
`(command, requestId)` 命中、argumentDigest 相同且 catalog retryPolicy 声明幂等时才共享原 owner/冻结
response；参数不同仍拒绝 `requestIdConflict`，非幂等仍拒绝 `duplicateRequestId`，replay 不占新 slot。
feature-aware retry 的 ownerToken 还必须与原 owner 一致；不同 token 不能绕过上述 duplicate 规则创建第二个
external owner，而是复用既有 `requestIdConflict`。legacy retry 没有 token 时继续复用第一次 lookup 已绑定的
内部 token，不为 retry 新建 token。

registry 的并发重复 `(command, requestId)` 稳定拒绝 `duplicateRequestId`，不启动第二个 handler；原 owner
settle 后可按既有语义以同一 requestId 创建新 owner，但必须使用新的 ownerToken，因此迟到 cancel 无法误伤。
所有计数由一个 terminal arbiter 精确释放，不允许负数或双释放。

direct `maxConcurrentRequests` 是 identity/catalog/snapshot/invoke 共用的 transport processing 门，与 host
execution slot 分开记账，但不能简化成“HTTP response 已关闭”。context-aware direct invoke 必须返回两个
独立 Future 的 `PatchbayDirectInvocationHandle`：`response` 允许在 deadline/cancel 时先冻结并关闭连接；
`lifecycle` 只在完整 pipeline settle 或 cancellation confirmed 后完成。`_activeRequests` 绑定后者，legacy
handler 的两个 Future 是同一条。`PatchbayDirectHandlers` 为此提供与 legacy `invoke` 二选一的 additive
context-aware 入口，不要求 adapter 同时实现两套。
因此 caller timeout/disconnect 或 unconfirmed rejection 都不会提前释放 direct processing slot；两份配置不要求
互相比较，超过 host budget 的 invoke 由 host 类型化拒绝。

## Host terminal 与 audit 顺序

新增幂等 `Future<PatchbayInvocationDrainResult> drainInvocations({Duration timeout = const Duration(seconds: 2)})`。
第一次调用关闭 invocation admission，向所有闸前 owner 发出 `hostDisposed`（未曾取消者），并冻结 timeout；
后续调用复用同一 terminal Future。timeout 接受 0..30 秒，返回结果而不抛异常：

```text
outcome: drained | timedOut
settledCount
confirmedCount
abandonedCount
```

三项以 terminal result 形成时的状态互斥分类闸前 owner：handler 已 settle 计 settled；尚未 settle 但已确认
停止计 confirmed；两者都不是且预算耗尽计 abandoned。三项之和等于关闸时 owner 数，`drained` 的 abandoned
固定为 0。迟到 settle/confirmation 可释放内部资源，但不改写 immutable drain result。

M3 已冻结的 `Future<void> dispose(...)` 返回类型保持不变；M4 只 additive 增加 `invocationTimeout` 参数并按固定
顺序执行：先 `drainInvocations` 关闭受理、产出 invocation terminal audit，再 `drainAudit`。这样取消/放弃事实
不会被 host 自己提前关闭的 audit 闸挡住。调用方若显式先调用 `drainAudit`，之后的 invocation 事实仍进 ledger
并按已接受 M3 契约以 delivery-closed observer 报告，host 不伪造已经外投。

## 兼容与降级

- legacy handler 无 confirmation 能力：deadline/cancel 可让调用方停止等待，但 slot 保留到 pipeline settle；
  response 明确 `cancellation: unsupported`。
- 新 handler + 老 CLI：没有 VM `deadlineMs` 或显式 cancel 时，仍可从 direct deadline、可靠 disconnect 或 host
  dispose 收到 signal；既有 invoke 响应字段保持松读追加。
- 新 CLI + 老 host：VM feature 缺失时不发送 `deadlineMs`；两端 feature 缺失时不发送 `ownerToken`、不调用
  cancel method/endpoint。direct 仍发送既有 deadline header，让老 host 保留 transport wait 行为，但 CLI 标为
  `legacyWaitOnly`，表示没有 cooperative confirmation。
- VM Service 无法可靠观测 client disconnect 时不得伪造 `callerDisconnected`；direct 也只在 socket 关闭有
  可靠证据时触发，不把普通 response timeout 当 disconnect。
- direct generic timeout 继续保护 identity/catalog/snapshot；支持新 feature 的 invoke 必须把有效 deadline 交给
  host terminal arbiter，response 不再与 generic transport timer 竞速，不能让 transport timeout 抢先改写成
  另一种错误形状；lifecycle Future 仍保留资源保护。

## 安全与隐私

cancel 只对当前 session/appInstance 中准确的 `(command, requestId, ownerToken)` 生效，不能列举其他调用的 ID。
ownerToken 是 capability secret，永不进入 audit、error details、日志、trace、响应回显或 MR 证据，只能保存在
active-owner、external replay 与 settled tombstone 的有界内存记录。其他 details/audit 也不含 arguments、
handler error message、transport token、URI 或 consumer callback 字符串；release 构建继续不可达。

## 验证

- 单元/协议：legacy/context-aware handler、callback 注册先后、settle/cancel/deadline 的全部竞速、confirmation
  success/throw/timeout/late success、late handler result、requestId 复用时旧 token cancel、unknown/settled
  cancel、host dispose。
- 容量：registry/external 混合打满、replay 不占新 slot、unconfirmed 保留、confirmed/settled 精确释放，active
  owner 256 硬闸，running/record 计数不负、不双释放。
- VM/direct：同一 deadline 与 explicit cancel 的 code/details 一致；strict unknown field 继续拒绝；direct
  identity result 的 additive feature 不污染 request identity；header deadline 与 client socket wait 分开；
  disconnect reason 只在 transport 有证据时出现；response/lifecycle 双 Future 保持现有 wedged-handler 防堆积。
- direct control：普通 processing slot 全满、默认容量 1 的 wedged invoke、control slot 自身满载、callback 永不
  settle 都有测试；第一条合法 cancel 始终可达且不占 host execution admission，额外请求只在独立 control 门拒绝。
- terminal：dispose 关闭新受理，invocation drain 的互斥守恒成立，invocation terminal audit 发生在 audit drain
  前；调用方预先 drain audit 的 delivery-closed 降级有复刻测试。
- 仓内 example：提供一个可确认停止和一个故意不响应的 handler，先跑本地端到端预检，再在 Android 真机与
  iOS 模拟器验证 deadline、explicit cancel、dispose、两层容量与 response 隔离；业务接入方只在采用
  context-aware API 时验证真实 controller 的停止证明。
- 失败注入：callback 永不 settle、确认后 handler 迟到 accepted、取消与正常 settle 同 turn、host dispose
  满载、256 个 confirmed 但 handler 不 settle；日志与 MR 证据不含接入方身份。

## 裁决结果

已接受。host-wide execution budget 默认 8、active-owner record 上限 256；执行 slot 与 direct HTTP slot 分开
记账。deadline 只表达等待预算，显式 cancel 使用独立 protocol-owned method/endpoint 与 per-owner token；
consumer confirmation 是提前释放 execution slot 的唯一新证明。host dispose 先 terminal invocation、再
drain audit。PB-050-06
运行时实现必须等待 PB-050-05 进入 `dev/0.5.0` 后基于新主线串行推进，Proposal 本身以 PB-050-05 Proposal
为父分支独立评审。

## 被否决方案

- direct timeout 立即 `_activeRequests -= 1`：handler 仍运行，后续请求会继续堆积。
- 只加 host-wide semaphore、不加 cooperative context：只能更早拒绝，无法恢复被卡死容量。
- 推荐默认 32：缺少 App isolate/consumer handler 的负载证据，且比 direct 已有上限放大四倍。
- 把 cancel 塞进 invoke 的 operation/arguments：会穿过 consumer catalog namespace并破坏严格 request wire。
- 把 caller deadline 当作业务 cancelled：调用方不等了不等于设备操作已停止。
- 用 isolate kill/zone 强制取消任意 Future：破坏 consumer 状态且无法证明外部设备副作用已停止。
- confirmation 后永久熔断 command：host 只能看到 handler Future，无法观察 controller 外部副作用；迟到清理
  不是违约证据。
- 复用 job cancel 处理 invocation：job 已经是 accepted 之后的业务事实，生命周期与调用信封不是一层。
