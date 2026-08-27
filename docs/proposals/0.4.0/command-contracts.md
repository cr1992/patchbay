# 0.4.0 命令契约与执行证据

> 状态：已接受
>
> 关联：PB-040-21；registry/descriptor/响应 schema/CLI 生成面已随 0.4.0 发布，见
> [CHANGELOG.md 0.4.0 段](../../../CHANGELOG.md#040---2026-08-20)
>
> 设计闸门：DG-040-05

## 问题

命令目录、host 分发、CLI 注册和文档目前由多处手写；请求已有 descriptor 约束，但受理 payload 和
job 终态 payload 仍是自由 `Map`。接入方可以漏掉 `session` 等字段，CLI 的 `--json` 只能保证外层
信封，不能让脚本判断字段缺失究竟是“不适用”“未知”还是 provider 违规。同值写入不产生设备回报
时，超时又会把“已经发送”与“根本没发送”压成同一种失败。

## 目标与非目标

### 目标

- 一份 CommandRegistry 同时驱动目录、解码、门、handler、响应校验和 CLI/help/docs 生成。
- descriptor 明示受理 payload 与终态 payload 的必填、可空、变体和未知字段策略。
- 脚本能区分 `notSent`、`sentUnconfirmed`、`unchanged`、`deviceConfirmed`，并知道事实来源。
- provider 违规在 host 边界被替换成稳定拒绝，不把坏 payload 继续传给 CLI。

### 非目标

- 不把领域 payload 收编成 Patchbay 统一业务模型。
- 不把“命令已发送”升级成“设备已完成”。
- 不新增含义模糊的 job phase；job 仍使用 `running/completed/failed/cancelled`。
- 不在 0.4.0 移除老 host 的自由 payload 兼容路径。

## Registry 与 schema 契约

每条 descriptor 形成一个不可分割的注册单元：

```text
name + sideEffects + gates + requestSchema + responseSchema
  -> request decoder
  -> gate runner
  -> handler
  -> accepted/terminal response validator
  -> catalog + CLI/help/docs
```

`responseSchema` 分两面：

- `accepted`：即时受理返回；声明字段、类型、是否必填/可空和允许的变体 discriminator；
- `terminal`：job 终态返回；按 `completed/failed/cancelled` 分别声明 payload；
- 未声明字段默认拒绝。确需开放扩展时必须显式声明 `additionalProperties`，不能靠 validator 漏检；
- “字段不适用”用变体表达，“值未知”用显式可空表达，禁止二者都退化成缺字段；
- schema 作为 descriptor 的一部分进入 catalog digest，调用前目录复核继续覆盖请求和响应两面。

`catalogDigest` 的 `covers` **保持 `["commands"]` 不变**。摘要是对 `commands` 数组逐条递归规范化后
算出来的，未知嵌套字段照样参与计算，两端都拿收到的目录原文重算，所以 `responseSchema` 天然被覆盖，
老 CLI 复算仍得同一个值。反过来，`isRecomputable` 要求 `covers` 恰好是 `["commands"]`——新增一个
covers 条目才会让老 CLI 整份降级 `unsupported`。只有将来摘要要覆盖 `commands` 以外的区域时，才新增
covers 项。

`schemaMode` 是**逐命令**而不是逐 host 的：新 host 上仍会有没声明 `responseSchema` 的接入方命令，
这些命令即使在新 host 上也是 `legacyUnvalidated`。否则 `responseSchemas` capability 就变成协议层
替接入方的每条命令背书。

host 在 adapter 回程、写入 job ledger 前校验；CLI 在收到信封后按同一 descriptor 表面复核。任一层
发现必填字段缺失、类型错误、未知变体或额外字段，返回 `providerProtocolViolation`，`details.reason`
使用封闭值：`missingField`、`unexpectedNull`、`wrongType`、`unknownVariant`、`unknownField`。

## CLI 生成面的边界（已随 0.4.0 发布）

CLI 与 host **分开部署**，CLI 不可能从运行时 catalog 生成自己的解析表——它必须在拨号之前就能解析
argv，也必须能对着一个从没见过的接入方目录工作。所以“由 descriptor 生成”只覆盖**协议自有命令**：
`ui.*`、`navigation.*`、`patchbay.*` 这些由本仓四个包定义的命令，从仓内 descriptor 源生成 CLI 注册、
帮助与文档表。接入方命令继续走 `exec <service-command>`，运行时可用性仍由 catalog 决定。

CLI 侧的命令表因此仍然是**语法**，不是能力清单；本提案消除的是同一份语法在多处手写，不是把语法
和能力合并成一张表。

## 执行证据

需要表达设备执行结果的命令，在受理或终态 payload 中使用统一对象：

```json
{
  "execution": {
    "classification": "notSent | sentUnconfirmed | unchanged | deviceConfirmed",
    "factSource": "appRecorded | commandEcho | deviceReported | uiObserved | unknown",
    "observedAtMs": null,
    "reasonCode": null
  }
}
```

- `notSent`：有证据表明发送动作未发生；终态必须为 `failed`。
- `sentUnconfirmed`：发送动作已发生，但确认预算内未观察到设备事实；要求确认的命令必须 `failed`，
  允许弱确认的命令可 `completed`，但 descriptor 必须显式声明 `weakConfirmationCompletes: true`，
  默认为否。该策略只对 `mode: job` 有效；即时命令声明它属于无效 descriptor，注册与 catalog
  解析都必须拒绝，避免同一分类在即时和 job 路径产生相反退出码。
- `unchanged`：发送前已有可信的同值证据，且发送后没有相反设备事实；可以 `completed`。
- `deviceConfirmed`：存在 `deviceReported` 或 descriptor 明示可接受的更强观测；可以 `completed`。

`observedAtMs` 只在确有观测时间时出现，否则为 `null`。`reasonCode` 是命令 schema 声明的封闭值，
不得塞自由文本。CLI 退出码由 job 终态决定，不能只看 `classification` 猜成功。

### `unchanged` 的前置证据必须可判定

“可信的同值证据”若不给形状，就是一句谁都可以说的话——而同值写入设备不回报，正是已经造成回归
误判的那个场景。所以判定 `unchanged` 的 payload 必须同时给出：

- `priorValueSource`：封闭值 `deviceReported | appRecorded`；
- `priorObservedAtMs`：该同值证据的观测时刻。

且 `priorObservedAtMs` 必须落在 descriptor 声明的 `unchangedEvidenceMaxAgeMs` 之内。任一条不满足，
host 按 `providerProtocolViolation` 拒绝，`details.reason` 用既有封闭值。

### 确认预算属于 descriptor，不是等待预算

需要确认的命令在 descriptor 上声明 `confirmationBudgetMs`。它与 CLI `--wait` 的等待预算是两件事：
前者是“多久没看到设备事实就判 `sentUnconfirmed`”，后者是“调用方还愿意等多久”。两者混用会让
“确认失败”和“我等得不够久”重新变得不可区分，而这正是本提案要消除的那类歧义。

### 与既有 `payload.dispatched` 的关系

0.3.x 已有接入方用 `payload.dispatched: false` 表达“没发出去”，CLI 也已按它判类型化失败。它是
`notSent` 的遗留投影，本版不移除。两者同时出现且矛盾时，**以 `execution` 为准**，并在 `details` 里
记 `legacyDispatchedConflict`；只有 payload 确实带有类型化 `execution` 时才适用这条优先级。没有
`execution` 的旧 payload 仍按 `dispatched: false` 判失败，即使 job 的末事件写成 `completed` 也不能
把它升级为成功。不写这条，同一份 payload 会有两套事实。

## 兼容与降级

- 新 host 只有在真正执行响应校验后才声明 `responseSchemas` capability。
- 新 CLI 遇老 host：保留 payload 原样，输出 `schemaMode: legacyUnvalidated`，不得补造缺失字段。
- 老 CLI 遇新 host：忽略 catalog 新字段，继续读取既有信封；新增响应字段必须处在松读面。
- VM Service 与 direct 使用同一个 registry/validator，不允许各自实现 schema 分支。

## 安全与资源

- validator 错误只返回字段路径、reason 和期望类型，不回显 sensitive 值。
- retry 仅适用于 descriptor 标记幂等的 external 命令，并按 requestId 去重。
- audit sink 只记录命令名、requestId、参数形状、门结果和执行分类；默认不记录原值。
- schema 最大嵌套深度为 12、单份 schema 最多 256 个字段、一次校验最多返回 20 条错误；超过上限在注册
  或校验边界稳定拒绝，避免恶意 payload 放大内存与输出。
- 允许 `unchanged` 的 descriptor 必须显式声明 `unchangedEvidenceMaxAgeMs`，没有全局默认值；合法范围为
  `1..300000`。需要设备确认的 descriptor 同样必须显式声明 `confirmationBudgetMs`，合法范围为
  `1..120000`。把这两个时间预算省略或写出范围都属于 descriptor 无效，不能拖到运行时猜默认值。

### 幂等重试、去重与审计的冻结契约

只有 `sideEffect: external` 的 consumer command 可以声明 `retryPolicy`；字段存在本身就是幂等 opt-in，
没有另一个可漂移的 `idempotent` 开关。形状固定为
`{maxAttempts, backoffMs}`：`maxAttempts` 包含首次调用，合法范围 `2..3`；`backoffMs` 合法范围
`0..5000`。CLI 只对 transport unavailable/timeout 重试；协议错误、host/provider 拒绝和任何已经返回的
provider 结果都不重试。所有 attempt 必须复用同一 requestId。

host 在 external fallback 前以 `(command, requestId)` 去重，并用完整 canonical arguments 的内部摘要
校验同一 key 是否仍是同一请求；摘要和参数值都不外发。同 key、同参数且声明 policy 时，in-flight 共享，
settled 结果重放；参数不同稳定拒绝 `requestIdConflict`。未声明 policy 的 external 命令第二次出现同一
requestId 时稳定拒绝 `duplicateRequestId`，绝不再次调用 provider。ledger 按插入顺序最多保留 256 条；
容量全被 in-flight 占用时 fail-closed，不通过驱逐正在执行的记录制造重复执行窗口。

audit event 固定为 `command/requestId/parameterShape/gateResult/executionClassification`。参数形状只保留
递归 JSON 类型、对象键和粗粒度长度区间，不保留标量值或其摘要。事件先进入 host 内部 256 条有界
ledger，再 best-effort 投递 `FutureOr<void> Function(PatchbayAuditEvent)` sink；sink 失败不改写已经发生
的命令事实，可交给 `onAuditSinkError(error, stackTrace, event)` 观测，默认静默隔离。

CLI `describe <service-command>` 只读活体 catalog、不 invoke，输出
`{command: <catalog row>, schemaMode, retryEligibility}`；`retryEligibility` 是封闭值
`eligible | notDeclared | notExternal`。

## 验证

- registry 单测证明目录、dispatcher、CLI/help/docs 来自同一注册单元；并断言生成面只包含协议自有
  命令，接入方命令不进 CLI 语法表。
- 对必填缺失、可空、未知字段、未知变体、敏感值和资源上限逐项失败注入。
- `unchanged` 缺 `priorObservedAtMs`、或 `priorObservedAtMs` 超出 `unchangedEvidenceMaxAgeMs` 时，
  各有一条 `providerProtocolViolation` 用例，`details.field` 指到具体路径。
- 同一 payload 同时带 `execution.classification` 与矛盾的 `dispatched` 时，断言以 `execution` 为准
  且 `details` 出现 `legacyDispatchedConflict`。
- 0.3.x fixture 覆盖新 CLI 的 `legacyUnvalidated`，并断言混合目录里逐命令 `schemaMode` 两种值并存；
  0.4 host fixture 覆盖老 CLI 松读。
- **catalog digest 透明性四条**（复刻老客户端读法，不 import 当前实现）：
  1. `covers` 恒为 `["commands"]`；
  2. command 条目含未知嵌套字段时，两侧复算得同一摘要；
  3. 带 `responseSchema` 的 0.4 目录喂给复刻的 0.3 reader，结果为 `verified`；
  4. **负向**：人为多加一个 covers 条目时，复刻 reader 必须得 `unsupported`——这条把“为什么不扩
     covers”变成会红的闸，而不是一句注释。
- VM/direct 对同一请求返回相同 schemaMode、稳定 code、requestId 和执行证据。
- retry policy 的范围、额外字段和非 external 声明逐项 fail-closed；CLI 只在可重试 transport failure
  复用同一 requestId，协议错误、provider 拒绝和非可用性 transport 错误均只调用一次。
- host 覆盖同参数 in-flight 共享与 settled 重放、异参 `requestIdConflict`、无 policy
  `duplicateRequestId` 和 256 条资源上限；纯重放不重复写 provider execution 审计事实。
- audit 参数形状对对象键与数组 item type 排序确定、标量值不可见、未知运行时类型稳定为
  `unsupported`；sink 与 error observer 抛错均不能改写命令结果。
- CLI `describe` 覆盖三种 retryEligibility、逐命令 schemaMode，并断言只读 catalog、零 invoke。
- 双平台 example 预检各验证 `notSent/unchanged/sentUnconfirmed/deviceConfirmed`，并覆盖同值写入；真实
  设备 SDK 的确认语义由接入方补充（发布判据见[版本计划 SC-040-01](../../releases/0.4.0.md#范围变更记录)）。

## 已裁决补充

- 0.4.0 中 `uiObserved` **不能**把执行分类升级为 `deviceConfirmed`，只能作为领域成功证据；设备确认必须
  来自 `deviceReported`。未来若出现必须放宽的真实用例，先修改本 Proposal 并重新评审。
- schema 与时间预算已经在“安全与资源”冻结；实现只能提供更小的接入方配置，不能突破协议上限。

## 被否决方案

- 把 `sentUnconfirmed` 新增为 job phase：phase 与事实强度混在一起，旧客户端也无法解释。
- 等 TTL 到期一律报普通 timeout：丢失“已经发送”的关键事实。
- 让 CLI 用字段是否存在推断 provider 版本：继续制造不可区分的缺失语义。
- 为 `responseSchema` 新增 `catalogDigest` 的 covers 条目：摘要本来就递归覆盖 command 条目的全部
  内容，新增覆盖项反而会让老 CLI 整份降级 `unsupported`——正是它想避免的后果。
- 从活体 catalog 生成 CLI 命令表：CLI 需要在拨号前解析 argv，也要能对陌生接入方目录工作。
