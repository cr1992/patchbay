# 0.5.0 Invocation cooperative cancellation、deadline 与统一受理预算

> 状态：提案中
>
> 关联：PB-050-06
>
> 设计闸门：DG-050-04

## 问题

direct host 在请求 timeout 后刻意保留 `_activeRequests` slot，直到 handler Future 真正 settle；默认容量为 1。
这是防止卡死 handler 后继续堆积的安全选择，不是待修的计数错误。没有 cooperative cancellation 时，
仅因 HTTP 调用方不再等待就释放 slot，只会把仍在执行的工作从账本里藏起来。

另一方面，VM Service host 只有 external fallback 的 requestId ledger 上限 256；走 registry `tryDispatch`
的命令不经过这条容量闸。当前也没有统一上下文让 handler 区分 caller deadline、transport disconnect、
host dispose 或显式 cancel，更无法证明底层副作用已经停止。

## 目标与非目标

### 目标

- deadline 只表达调用方等待预算；取消请求、取消已观察、底层停止确认与 handler settle 分开记账。
- 为 registry 与 external handler 提供 additive cooperative cancellation context，legacy handler 不破坏。
- 建立 transport 之上的 host-wide admission budget，registry/external 共用；direct 自身连接容量仍是外层门。
- 只有 handler settle，或 consumer 明确确认底层停止且不再产生副作用，才能回收执行 slot。
- VM Service 与 direct 返回相同 code/details；transport 只能提供不同 cancellation trigger，不能重写事实。

### 非目标

- 不把 Dart Future 强制终止；Patchbay 只发信号并等待 consumer 证明。
- 不改写 `PatchbayJobRegistry` 的 cancel callback、终态或 retainedJobs。job 是已受理后的业务生命周期，本提案
  处理的是一次 invocation handler 的生命周期。
- 不因 caller disconnect 自动写 `cancelled` 业务结果。
- 不承诺 legacy handler 在 deadline 后释放容量。

## 契约

新增不可变 `PatchbayInvocationContext`，至少包含：

```dart
requestId
deadline // monotonic absolute deadline；未声明时为 null
cancellation // 只读 signal：reason + whenRequested
registerCancellationConfirmation(Future<void> Function(reason) callback)
```

registry/external source 通过 additive 的 context-aware handler API 接入；旧 handler typedef 由 adapter 调用，
但不伪造 confirmation。一个 command 不能同时注册 legacy 与 context-aware handler。

取消 reason 为封闭词表：`callerDeadlineExceeded | callerDisconnected | explicitRequest | hostDisposed`。
“requested”只证明 host 发出了 cooperative signal；confirmation callback 成功只证明 consumer 声明底层已
停止且不会再产生副作用。callback 缺失、抛错或超时都不是确认。

invocation response 继续使用既有受理信封。deadline 在信封返回前耗尽时，host 返回 rejected code
`invocationDeadlineExceeded`，details 至少含 `cancellation: requested | confirmed | unconfirmed`；不得返回
accepted 再把执行失败藏进 payload。已经返回 accepted 并启动 job 的命令由 job 契约继续管理，不受后续
transport disconnect 改写。

显式 cancel 需要稳定寻址 `(command, requestId)`，只对仍在 running ledger 的 owner 有效；settled replay、
unknown 或不支持 cooperative cancellation 都返回类型化结果，不通过重复 invoke 猜测取消。

## 状态、失败与预算

内部 invocation 状态机：

```text
admitted -> running -> settled
                  -> cancelRequested -> cancelConfirmed -> settled
                                     -> cancelUnconfirmed -> settled | wedged
admissionRejected
```

`cancelConfirmed` 允许回收执行 slot，但 record 必须保留到原 handler Future settle 或 retention 淘汰，以隔离
迟到结果；迟到结果不得覆盖已经发给调用方的 deadline/cancel response。若 consumer 确认后仍产生可观测
副作用，属于 provider 契约违约，host 应通过 audit/error observer 报告，不能事后改写旧响应。

推荐 host-wide `maxConcurrentInvocations` 默认 32、配置范围 1..256；它限制 running registry + external
owner，不把 settled replay 计入。external requestId ledger 仍最多 256 条，用于去重/重放，不与运行容量
混成一个数字。满容量稳定拒绝 `invocationCapacityExceeded`，details 只含 limit/running。

取消 confirmation 默认等待 2 秒、最大 30 秒；caller deadline 更短时取剩余预算。预算耗尽标
`unconfirmed` 并继续占用 slot，保持当前 direct 的保护。direct `maxConcurrentRequests` 仍限制 HTTP 层；
它不应大于 host-wide budget，构造时可拒绝明显矛盾配置。

所有 deadline 用可注入 monotonic clock 计算。相同 requestId 的 external retry 继续共享 owner/response；
取消状态也必须共享，不能由 retry 新建执行。

## 兼容与降级

- legacy handler 无 confirmation 能力：收到 deadline/cancel signal 后调用方可停止等待，但 slot 保留到 Future
  settle；响应明确 `cancellation: unsupported | unconfirmed`。
- 新 handler + 老 CLI：没有显式 cancel 请求时仍可从 transport deadline/host dispose 收到 signal；既有 invoke
  响应字段保持松读追加，老 CLI 继续按 rejection code 处理。
- 新 CLI + 老 host：capability 缺失时不发送显式 cancel，deadline 只作用于客户端等待，并显示
  `cancellationMode: legacyWaitOnly`。
- VM Service 若无法可靠观测 client disconnect，不得伪造 `callerDisconnected`；仍可处理显式 deadline/cancel。
  direct 可在 socket 关闭被可靠观测时发送该 reason。
- direct timeout 后只有 `confirmed` 或 handler settle 才释放 host execution slot；HTTP `_activeRequests` 是否
  同时释放由 DG-050-04 裁决，但不得早于对应执行容量。

## 安全与隐私

cancel 只能由持有当前 session/transport 授权且能给出原 command + requestId 的调用方请求；不能列出其他
调用方的 requestId。details/audit 不含 arguments、handler error message、transport token 或 URI。
release 构建继续不可达。

## 验证

- 单元/协议测试：legacy/context-aware handler、settle/cancel/deadline 的全部竞速、confirmation success/
  throw/timeout、late result、duplicate requestId/retry、unknown/settled explicit cancel、host dispose。
- 容量：registry/external 混合打满、replay 不占新 slot、unconfirmed 保留、confirmed/settled 精确释放，
  running 计数不负、不双释放。
- VM/direct：同一 deadline 与 explicit cancel 的 code/details 一致；disconnect reason 只在 transport 有证据时
  出现；direct 现有 wedged-handler 防堆积用例继续通过。
- 接入方/真机：example 提供一个可确认停止和一个故意不响应的 handler；业务接入方只需在采用 context-aware
  API 时验证真实 controller 的停止证明。
- 失败注入：callback 永不 settle、确认后 handler 迟到成功、取消与正常 settle 同 tick、host dispose 时满载。

## 待裁决

- confirmation 成功后是否立即释放 direct HTTP `_activeRequests`，还是仍等 handler Future settle？本稿倾向
  host execution slot 可释放、HTTP request slot 等响应关闭后释放，但二者必须分别计数。
- host-wide 默认 32 是否与真实 UI/consumer handler 负载匹配？
- 显式 cancel 使用新的 protocol-owned command，还是 invoke endpoint 的独立 operation？必须先查严格解码
  surface，不能向已发布 request wire 静默加字段。
- consumer “确认已停止”的违约只能观测，是否还需要在当前 appInstance 永久熔断该 command？

## 被否决方案

- direct timeout 立即 `_activeRequests -= 1`：handler 仍运行，后续请求会继续堆积。
- 只加 host-wide semaphore、不加 cooperative context：只能更早拒绝，无法恢复被卡死容量。
- 把 caller deadline 当作业务 cancelled：调用方不等了不等于设备操作已停止。
- 用 isolate kill/zone 强制取消任意 Future：破坏 consumer 状态且无法证明外部设备副作用已停止。
- 复用 job cancel 处理 invocation：job 已经是 accepted 之后的业务事实，生命周期与调用信封不是一层。
