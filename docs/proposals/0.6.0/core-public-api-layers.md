# 0.6.0 Core 公共 Dart API 分层

> 状态：已接受
>
> 关联：PB-060-02
>
> 设计闸门：DG-060-02（已裁决）
>
> 裁决修订：2026-09-03 重锚定基线摘要，并把 PB-050-39 新增的三个 audit 词表符号归入 host-only 集
> `H`（41 → 44）。详见下文「裁决修订」。**待仓主确认。**

## 问题

`package:patchbay/patchbay.dart` 当前公开 247 个符号，混合 consumer DTO/descriptor、host lifecycle、
invocation internals 与生成 wire 类型；`patchbay_flutter.dart` 又整体 re-export core。API golden 能防止
意外漂移，却不能让普通 App 接入者只看到自己需要的表面。0.6.0 若是 1.0 候选，必须先冻结使用者分层。

## 目标与非目标

### 目标

- 将默认 consumer、host implementer、protocol/wire implementer 的公共入口与符号清单分开冻结。
- 默认 Flutter 接入不再无条件暴露 raw wire、host lifecycle 或低层 bridge seam。
- API checker 对每个入口及跨包 re-export 的真实表面判定增删，不能留下无法展开的整库 export。
- 给 0.5.x source 用户一张可以由编译错误逐项执行的迁移表，不保留永久兼容大口袋。

### 非目标

- 不拆第五个运行时 package，不改变 wire、错误码、稳定 JSON 或运行时行为。
- 不建立 `legacy.dart` / `testing.dart` 大口袋，也不公开包内测试时钟、session store 或 transport token seam。
- 不通过 typedef、别名或默认整库 re-export 维持两套同等推荐入口。
- 不把 `patchbay_transport` 的 client/host 进一步拆 library；本条只收口 core 与 Flutter 的默认面。

## 裁决摘要

1. `patchbay.dart` 保留为默认 consumer façade；不新增 `patchbay_consumer.dart`。
2. core 新增 `patchbay_host.dart` 与 `patchbay_protocol.dart`。`PatchbayServiceHost` 是 host-only，不进入默认
   consumer 面。
3. `patchbay_flutter.dart` 只 re-export core consumer 清单与四个 widget 侧符号；新增
   `patchbay_flutter_host.dart` 承载 Flutter service host、bridge、policy 与低层实现 seam。
4. 所有公共 barrel 都使用封闭 `show` 清单。API checker 对四个 package 都执行 closed-surface 规则，并
   把带 `show` 的跨包 re-export 计入当前 library 的 golden；无 `show` 的跨包 export 一律判红。
5. 这是 0.6.0 明示的 source breaking：旧默认 import 不保留兼容 re-export。CLI/JSON 用户和 wire 本身
   不受影响。

## 公共 library 拓扑

| package | library | 角色与内容 |
|---|---|---|
| `patchbay` | `patchbay.dart` | 默认 consumer；业务 descriptor、schema、gate、provider、job、artifact/log 与 UI 声明 |
| `patchbay` | `patchbay_host.dart` | consumer 的严格超集；再加 service host、audit、invocation/cancellation 与 validation lifecycle |
| `patchbay` | `patchbay_protocol.dart` | raw wire、catalog capability/digest、CLI syntax、permission companion、client request 与 canonical protocol descriptor |
| `patchbay_flutter` | `patchbay_flutter.dart` | core consumer 加 `PatchbayKey`、`PatchbayRoot`、`PatchbayRootController`、`PatchbayUiRegistry` |
| `patchbay_flutter` | `patchbay_flutter_host.dart` | core host 与 Flutter 默认面的严格超集；再加现有其余 44 个 Flutter host/bridge/policy symbol |

`patchbay_host.dart` 不 re-export protocol；需要同时实现 host 与 raw transport 的高级使用者显式双 import。
`patchbay_flutter_host.dart` re-export core host 的封闭清单，因此组合根只需一个 Flutter host import；widget
文件继续只 import 默认 Flutter façade。不存在 `patchbay_flutter_protocol.dart`。

包内实现可以直接 import 自己的 `src/`；跨 package 实现只能 import 上表公共 library，不能用对方
`lib/src/` 绕过分层。`patchbay_cli.dart`、`patchbay_client.dart` 与 `patchbay_transport.dart` 的既有公共
符号集合不变，但其内部 import 必须迁到对应 consumer/host/protocol 入口。

## 精确 core 集合

本裁决的基线全集 `U` 是 `tool/api_surface.json` 中 `patchbay/lib/patchbay.dart` 的 250 个符号；该文件内容
SHA-256 为 `835c329c32acf38997d79a683a7e35e575562f3335252fec85d3c42a3284a6e7`。实现 MR 必须先核对
该摘要，摘要不符说明基线已漂移，必须回到 Proposal 修订，不能自行重算集合掩盖并发公共面变化。

本节的基线由 2026-09-03 的「裁决修订」重锚定；原锚定是 247 个符号、摘要
`4fe8cfb9f6fb81cc9ef460a18e895f9dc020b053313110d10793b729fb6e29f3`。

### protocol 集 `P`

`P` 包含 `U` 中全部 71 个以 `Wire` 结尾的生成符号，再加下列 58 个精确符号，共 129 个：

```text
PatchbayCatalogDigest
PatchbayCliArtifactDisposition
PatchbayCliEqualsCondition
PatchbayCliInputMode
PatchbayCliSyntax
PatchbayFeature
PatchbayPermissionAction
PatchbayPermissionCapabilities
PatchbayPermissionCapability
PatchbayPermissionDecision
PatchbayPermissionDriverRequest
PatchbayPermissionDriverResponse
PatchbayPermissionEvidence
PatchbayPermissionFactSource
PatchbayPermissionInterruption
PatchbayPermissionOperation
PatchbayPermissionState
PatchbayPermissionStatus
PatchbayPermissionWireException
PatchbaySnapshotCondition
PatchbaySnapshotDiffRequest
PatchbaySnapshotMiss
PatchbaySnapshotRequest
PatchbaySnapshotSelection
PatchbayUiWaitCondition
PatchbayUiWaitRequest
patchbayCanonicalJson
patchbayCatalogDigestScopeCommands
patchbayDigestAlgorithmSha256
patchbayJsonEquals
patchbayNavigationBackCommandDescriptor
patchbayNavigationCatalogCommandDescriptor
patchbayNavigationCurrentCommandDescriptor
patchbayNavigationGoCommandDescriptor
patchbayNavigationPushCommandDescriptor
patchbayParameterShape
patchbayPermissionProtocolMajor
patchbayPermissionProtocolMajorOf
patchbayPermissionProtocolVersion
patchbayProtocolCliCommandDescriptors
patchbayUiCaptureCommandDescriptor
patchbayUiGestureDragCommandDescriptor
patchbayUiGestureFlingCommandDescriptor
patchbayUiGesturePressHoldCommandDescriptor
patchbayUiGestureTapCommandDescriptor
patchbayUiInspectSelectCommandDescriptor
patchbayUiInspectStatusCommandDescriptor
patchbayUiKeepAwakeSetCommandDescriptor
patchbayUiKeepAwakeStatusCommandDescriptor
patchbayUiProtocolCliCommandDescriptors
patchbayUiRevealCommandDescriptor
patchbayUiSemanticsActionByIdentifierCommandDescriptor
patchbayUiSemanticsActionCommandDescriptor
patchbayUiSemanticsTapCommandDescriptor
patchbayUiSemanticsTreeCommandDescriptor
patchbayUiTextEnterCommandDescriptor
patchbayUiTextSetCommandDescriptor
patchbayUiWaitCommandDescriptor
```

### host-only 集 `H`

`H` 是下列 44 个精确符号（41 个原始符号，加 2026-09-03「裁决修订」追加的三个 audit 词表符号）：

```text
PatchbayAdmission
PatchbayAuditDeliveryClosed
PatchbayAuditDeliveryOverflow
PatchbayAuditDrainOutcome
PatchbayAuditDrainResult
PatchbayAuditEvent
PatchbayAuditSink
PatchbayAuditSinkErrorHandler
PatchbayCancellationConfirmation
PatchbayCancellationSignal
PatchbayContextCommandHandler
PatchbayContextInvocationSource
PatchbayExecutionValidationResult
PatchbayExtensionRegistrar
PatchbayHostInvocationHandle
PatchbayInvocation
PatchbayInvocationCancellationOutcome
PatchbayInvocationCancellationReason
PatchbayInvocationCancellationResult
PatchbayInvocationCancellationSignal
PatchbayInvocationConfirmationState
PatchbayInvocationContext
PatchbayInvocationDeadline
PatchbayInvocationDrainOutcome
PatchbayInvocationDrainResult
PatchbayInvocationSource
PatchbayMonotonicClock
PatchbayRejection
PatchbayResponseValidationIssue
PatchbayServiceHost
patchbayAuditAdmissionStages
patchbayAuditExecutionClassification
patchbayAuditGateDispositions
patchbayAuditLegacyUnknown
patchbayGenerateOwnerToken
patchbayProjectAuditEvent
patchbayResponseSchemaMaxDepth
patchbayResponseSchemaMaxFields
patchbayResponseValidationMaxIssues
validatePatchbayExecutionContract
validatePatchbayExecutionEvidence
validatePatchbayResponsePayload
validatePatchbayResponseSchema
validatePatchbayTerminalPayload
```

### consumer 集 `C`

`C = U - P - H`，三集合在本基线上互不相交，因此 `C` 恰为 77 个符号。这个差集有意保留 App 作者直接使用的 command registry、
descriptor/schema、gate、catalog/snapshot provider、job ledger、artifact/blob/log service、navigation/UI 声明与
资源预算；它删除的是 raw wire、client-only protocol 词汇和 host lifecycle，而不是把业务 adapter 逼进
host 入口。

实现 MR 把 `C` 逐名写进 `patchbay.dart` 的 `show` 清单；`patchbay_host.dart` 精确导出 `C ∪ H`；
`patchbay_protocol.dart` 精确导出 `P`。不能把上述集合公式留成运行时代码或生成时的后缀猜测；公式只用于
冻结本次 247 符号的裁决，落地后由每个 library 的显式清单与 golden 成为真源。

DG-060-03 后续新增的 `PatchbayOutputProjection` 一组 Dart descriptor 类型属于 `C`；对应 raw parser/wire
类型属于 `P`。任何在本 Proposal 后新增的公共符号都必须在所属 MR 中显式选择 consumer、host 或 protocol，
更新相应 `show` 与 golden；未分类默认判红，不能自动落入差集。

### 裁决修订（2026-09-03，DG-060-02）

**待仓主确认。** 本 Proposal 接受时锚定的 `tool/api_surface.json` 摘要
（`4fe8cfb9…`，247 个符号）在实现开工时已不成立：当前基线摘要是 `835c329c…`，
`patchbay/lib/patchbay.dart` 为 250 个符号。逐符号 diff 只有一处差异——PB-050-39 在
`patchbay.dart` 新增了三个 audit 词表符号：

```text
patchbayAuditAdmissionStages
patchbayAuditGateDispositions
patchbayAuditLegacyUnknown
```

其余四个公开 library（`patchbay_cli` 两个、`patchbay_flutter`、`patchbay_transport`）逐符号无变化，
Flutter 自有全集 `F` 仍是 48 个符号。

本次重新接受以下结论，而不是由实现 MR 静默重算集合：

- 这三个符号只被 audit sink 与 audit reader 消费，与已经归入 `H` 的 `PatchbayAuditEvent`、
  `PatchbayAuditSink`、`patchbayAuditExecutionClassification` 同属一组词表，因此归入 host-only 集
  `H`，不进入默认 consumer 面。
- 修订后的精确计数是 `U = 250`、`P = 129`、`H = 44`、`C = 250 − 129 − 44 = 77`。`P` 与 `C` 均不变，
  因此本 Proposal 正文里 protocol 与 consumer 两节的清单与计数原样有效。
- 基线摘要重锚定为 `835c329c32acf38997d79a683a7e35e575562f3335252fec85d3c42a3284a6e7`。此后再出现
  摘要不符仍按原规则处理：回到本节修订，不在实现 MR 里重算。

## 精确 Flutter 集合

同一基线 golden 中 Flutter 自有全集 `F` 为 48 个符号。默认 Flutter 自有集合固定为：

```text
PatchbayKey
PatchbayRoot
PatchbayRootController
PatchbayUiRegistry
```

Flutter host 自有集合为 `F` 减去上述四项，即现有其余 44 个 bridge、service host、policy、inspector、
lifecycle、navigation、gesture、semantics、reveal 与 capture symbol。实现时 `patchbay_flutter.dart` 精确导出
`C` 和这四项；`patchbay_flutter_host.dart` 精确导出 `C ∪ H ∪ F`。其中
`PatchbayFlutterServiceHost`、`PatchbayFlutterBridge`、`PatchbayRevealPolicy`、
`PatchbaySemanticsActionPolicy` 与 `PatchbayGesturePolicy` 都是 host 面，不因普通 App 需要在组合根配置它们
就重新塞回每个 widget 文件默认可见的 consumer 面。

## API checker 与 golden

- `_closedSurfacePackages` 扩为四个 package；任何公共 library 出现无法展开的跨包整库 export，普通检查与
  `--update` 都必须先失败。
- checker 按 `package + library` 展开本地 export/part 和跨包 `show`，新增 library 本身、符号新增与符号
  移除分别报告；不能把两个入口折成包级并集。
- `tool/api_surface.json` 同一实现 MR 新增 core 两个、Flutter 一个 library 的清单，并记录默认入口大量
  source breaking diff。更新 golden 不是验收替代：实现先用本 Proposal 集合生成期望，再由 checker 反向
  展开实际源码对账。
- 增加角色编译 fixture：consumer fixture 只导入默认入口；host fixture 只导入 host 入口；protocol fixture
  只导入 protocol 入口。每个 fixture 同时有正向可见与反向不可见断言，防止 `show` 漏项或旁路扩大。
- API checker 自身测试必须覆盖带 `show` 跨包 re-export 的展开，以及无 `show` export 在四包均判红。

## Source 迁移

| 0.5.x 使用方式 | 0.6.0 import |
|---|---|
| 业务 descriptor、schema、gate、provider、job/artifact/log adapter | `package:patchbay/patchbay.dart`，多数代码不改 |
| `PatchbayServiceHost`、audit、invocation/cancellation 或 validation lifecycle | `package:patchbay/patchbay_host.dart` |
| 生成 wire、capability/digest、permission companion、client request、canonical descriptor | `package:patchbay/patchbay_protocol.dart` |
| Widget 中的 `PatchbayKey`、`PatchbayRoot`、controller、registry | `package:patchbay_flutter/patchbay_flutter.dart` |
| Flutter 组合根的 service host、bridge、policy 与 adapter | `package:patchbay_flutter/patchbay_flutter_host.dart` |

同一文件跨角色时允许两个显式 import；不提供 `legacy.dart`。仓内 example 必须先拆成 widget 默认 import 与
组合根 host import，证明迁移表真实可编译；两个已知 consumer 在各自 pin 上的中性编译摘要放入 gitignore
证据目录，不把接入方名称、应用 ID、包名或内部路径写进仓库。

`patchbay_client.dart` 的八符号公共面保持不变，但其 `PatchbaySnapshotRequest` 改从 protocol 入口精确
re-export。CLI canonical 两符号入口与 opt-in client 八符号入口不得趁本条扩大或缩小。

## 状态、失败、兼容与回退

本项只改变 Dart source 可见性，不改变运行时状态、失败、资源上限、wire、JSON 或 feature capability。
library 拆分不得引入 wrapper 对象或转发开销；同一个声明、host 与 wire 类型仍是原类型，不复制 class。

0.5.x package constraint 不会自动选择 0.6.0；git pin consumer 必须按上表迁移。默认入口收窄是有意的
source breaking，旧 import 编译失败必须能由迁移表唯一定位。回退以 PB-060-02 整个实现 MR 为单位：撤回
新入口与所有 `show`，恢复原 barrel 和旧 golden；不能只把默认整库 re-export 加回来，因为那会让表面看似
兼容、分层实际失效。

## 安全与隐私

收口不能让 gate evaluator、release compile-time boundary 或 sensitive policy 变成内部不可配置；这些
仍通过 consumer/host 入口可达。raw wire、request token、session store、测试时钟和 transport credential
不会因为迁移便利进入默认面。source scan 与外部 consumer 编译证据只记录符号和结果，不记录业务身份。

## 实施与验证

PB-060-02 走一个实现 MR：新增三份 public library、迁移包内 import、更新 checker/golden、example、guide 与
0.5.x→0.6.0 迁移表。拆开会出现默认面已经收窄但 host/protocol 入口尚不可用，或新入口存在但默认全量面
仍在的不可验收中间态。

- format、analyze `--fatal-infos`、四包全量 test、API surface 与 codegen/check 全绿。
- 默认 consumer/Flutter fixture 对 raw wire、service host、bridge/policy 的负向可见性测试全绿；host 与
  protocol 正向 fixture 覆盖全部清单。
- VM/direct 与 CLI stable JSON 复用完整回归，证明只有 source surface 变化。
- 仓内 example 与两个中性 consumer pin 编译；example 本地端到端预检在 source 迁移后跑绿，再进入 RC
  真机矩阵。单纯 library 可见性不要求为 Proposal MR 补设备会话。
- `dart pub publish --dry-run` 或等价 package 内容检查证明三个新增 public library 被发布且没有 `src/`
  旁路文档成为推荐入口。

## 被否决方案

- 新增 `patchbay_consumer.dart` 再迁移默认入口：制造两个 consumer 名称，没有收益。
- 只新增 core host/protocol 而让默认 Flutter 继续全量 re-export：raw wire 仍从最常用入口泄漏。
- 让 `patchbay_flutter.dart` 暴露 service host/bridge，但把 core host 藏起来：角色边界前后矛盾。
- 新增分层入口但保留默认全量或 `legacy.dart`：不会降低普通接入者的认知与兼容成本。
- 把所有 internals 移到另一个 package：增加发布拓扑而没有新的运行时边界。
