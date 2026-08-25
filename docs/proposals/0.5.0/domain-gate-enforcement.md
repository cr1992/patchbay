# 0.5.0 domain-plane 写命令的 gate 强制执行

> 状态：已接受
>
> 关联：PB-050-25
>
> 设计闸门：DG-050-11

## 问题

`PatchbayCommandDescriptor.gates` 对 `plane: domain` 的命令**只进目录，不进派发**。
`packages/patchbay/lib/src/host/host_invoker.dart` 的 `_dispatchInvoke` 在读取目录有效性、投影
`PatchbayCommandPolicy`、执行 sensitive-stdin 校验之后，直接把未被 registry 处理的命令交给
`_dispatchExternal`，后者只做 requestId 去重、ledger 容量保护，然后调用 `domainInvoke`。整条路径上没有任何
`PatchbayGateEvaluator`。

结果是两条同时成立的事实：

1. **声明的门不会被执行。** 接入方在 domain descriptor 上写 `gates: {...}`，CLI `describe` 与 catalog 会如实
   展示它，但没有任何代码会读回来求值。`packages/patchbay_flutter/example/lib/example_domain.dart` 的
   `descriptors` getter 上方那段注释就是这条缺口的实证记录——它是 PB-050-22 实现期间发现并如实标注的
   已知限制。
2. **不可省略的基础门也不会被执行。** `PatchbayGateEvaluator.evaluate` 的语义是"基础门先行，再按 gateId
   排序跑声明门"。domain 写命令根本不进入这个方法，因此连
   [`docs/design.md` 立场 3](../../design.md) 所说"不可省略的基础门"都被跳过。

这与设计立场的字面文本冲突：立场 3 要求"领域 adapter 必须使用生成 decoder 或等价 validator 执行参数、
敏感输入和声明门校验，不能把 descriptor 只当展示数据"。当前实现把参数与敏感输入交给了 host 和 adapter，
唯独把**声明门**留成了展示数据。

同一进程内的 UI 面则是另一套现实：`ui.*` / `navigation.*` 的每条写路径都在派发前调用
`_gates.evaluate(...)`（`flutter_bridge.dart:410`、`semantics_bridge.dart:118/219/267`、
`gesture_bridge.dart:170/184`、`navigation_bridge.dart:97/122/259`、`keep_awake_bridge.dart:148/242`、
`capture_bridge.dart:157/315`、`inspect_bridge.dart:165/210`、`artifact_service.dart:125`）。也就是说
"双层门"这套安全叙事在 UI 面是真的，在 domain 面是空的，而 domain 面恰恰是接入方写真实设备的那一面。

PB-050-22 把"只读默认开放、写入显式开放"确立为出厂默认；但基础门签名是
`FutureOr<PatchbayGateDecision> Function()`，**没有参数**，无法区分读写。接入方唯一能表达"这是写操作、
需要授权"的位置就是 descriptor 的 `gates`。这个字段在 domain 面不生效，PB-050-22 的默认策略在 domain 面
就没有落点——这是本条被列为 P0 发布阻断的理由。

## 目标与非目标

### 目标

- `sideEffect` 非 `none` 的 domain 命令在 host 受理内评估门，求值语义与 `packages/patchbay/lib/src/gates.dart`
  完全一致：基础门先行，声明门按 gateId 排序，首个拒绝即返回。
- 拒绝复用既有 rejection 信封与既有稳定 code 词表，不新增稳定 code。
- 冻结受影响面：哪些命令被加闸、哪些不被加闸、老 consumer 升级后的确切行为、迁移路径与发布说明义务。
- 冻结 example 全部 domain 命令的逐命令回归矩阵。
- VM Service 与 direct 共享同一实现，不产生第二份门语义。

### 非目标

- 不给只读 domain 命令加闸（`sideEffect: none` 行为逐字节不变，含基础门也不跑）。
- 不改 `PatchbayGateEvaluator`、`PatchbayBaseGate`、`PatchbayConsumerGate` 的签名或语义；特别是不给基础门
  加"读写"参数——那是另一次 breaking，且 descriptor `gates` 已经能表达同一事实。
- 不改 wire、不新增 CLI 命令/参数/别名、不改 catalog 与 descriptor 的稳定 JSON 字节。
- 不改 registry 自有命令（含 `ui.*` 与 artifact service 的 `blob.*` / `logs.*`）的现有门序。
- 不在 job 执行期间重评门；门是受理闸，不是执行期看门狗。
- 不引入按命令名硬编码的门表：门只能来自 descriptor 声明。

## 契约

### 闸点位置

闸插在 `HostInvokerHandler._dispatchInvoke` 的既有受理序列内，位置为**sensitive-stdin 校验之后、
`_registry.tryDispatch` / `_dispatchExternal` 之前**，且只对未被 registry 处理的命令生效：

```
requestId 非空校验
  → readInvocationCatalog()（目录整体有效性，PB-050-03 已冻结）
  → commandPolicies[command] 投影
  → sensitiveViolations()（sensitiveInputRequiresStdin）
  → withoutStdinProvenance() 参数白名单投影
  → 【本条新增】registry 未处理 && 判定为写 ⇒ PatchbayGateEvaluator.evaluate(policy.gates)
  → 【本条新增】门后目录复核
  → registry.tryDispatch / _dispatchExternal → domainInvoke
  → 信封复核 / responseSchema / executionContract（不变）
```

三条论证：

1. **与 UI 桥门序一致。** `flutter_bridge.dart` 的 `_applyText` 是"目标解析 → sensitive 校验 → 过门 →
   门后二次解析"；本条采用同样的"sensitive 先于门"。sensitive 校验不需要授权即可给出答复，因为它拒绝的是
   *调用方把密钥写进了命令行*，越早说越好；门则是授权判断，必须在任何副作用之前。
2. **与"受理 ≠ 执行"一致。** 门在受理段求值，产出 `admission: rejected` 的信封；它不进入 payload，也不
   声称设备做了或没做什么。
3. **不被 registry 处理**是路由判据，而非读取目录行的 `plane` 字符串。理由：`plane: flutterUi` 的命令全部
   protocol-owned 且必在 registry 内，能走到 external fallback 的只可能是接入方自有的 domain 命令；采用路由
   判据可以不依赖接入方目录行是否正确填写 `plane`，也不必为 `plane` 字段新增一类目录失败。registry 内的
   domain 命令（`blob.metadata`、`blob.read`、`logs.query`、`logs.export`、`logs.tail`）全部
   `sideEffect: none`，且已在 `artifact_service.dart:125` 的注册 gate 阶段评估自己的 `gates`，本条不碰它们，
   也不制造二次求值。

registry 自有命令保持现状：它们的门在 `PatchbayCommandRegistration.dispatch` 的 gate 阶段或桥内部求值。
本条不为 registry 增加"声明了 gates 就必须有 gate 阶段"的构造期断言——UI registration 的 `_gate` 全为 null，
其声明门由桥 handler 内部求值（`keepAwakeGates`、`captureGates`、`inspectPolicy.gates` 均已验证有
`evaluate` 调用点），加断言会误伤这条既有形状。这条不对称写在这里，是为了下一个读代码的人不必重新
调查一遍。

### 判定输入

判定只用两项事实，两项都来自**同一次已通过校验的目录读取**：

- `sideEffect`：`none` 不加闸；`appState` / `external` 加闸。
- `gates`：该命令声明的 consumer 门 ID 集合，原样交给 evaluator。

`PatchbayCommandPolicy` 增加 additive 投影字段（最终命名按仓内风格微调，语义不可变）：

```dart
final class PatchbayCommandPolicy {
  // 既有
  final Set<String> sensitiveParameters;
  final bool retainsStdinProvenance;
  // 本条新增
  final Set<String> declaredGates;   // 目录行 gates，缺失即空集
  final bool writesSideEffect;       // 见下方缺失/非法值规则
}
```

`fromCatalogRow` 的取值规则，全部 fail-closed 方向：

| 目录行状态 | `writesSideEffect` | 理由 |
|---|---|---|
| `sideEffect: "none"` | false | 声明为只读，DG-050-11 明确不加闸 |
| `sideEffect: "appState"` / `"external"` | true | 声明为写 |
| `sideEffect` 键缺失 | true | 只可能来自手写目录行；descriptor `toJson()` 总是写出该字段。无法证明只读时按写处理 |
| `sideEffect` 值不在封闭词表内 | true | 同上；本条**不**把非法值升级为整份目录违规（见待裁决 5） |
| 命令未出现在目录中（`undeclared()`） | true | host 无法证明 adapter 不认识一条它没声明的命令；"目录里没有"不等于"不会执行" |

`gates` 缺失或不是字符串数组时按空集处理，并不因此让目录整体失效——这与既有 `sensitiveParameters` 的
宽容投影一致，且空集在下一节有确定语义。

### 门求值语义

一次调用只求值一次，直接调用既有 evaluator：

```dart
final PatchbayGateRejection? rejection =
    await _domainGates!.evaluate(policy.declaredGates);
```

不实现第二套排序或短路逻辑。由此继承 `gates.dart` 的全部既有语义：

- **基础门先行**。基础门拒绝时 `gateId` 为 `'patchbay.base'`，code 为基础门自带 code，缺省
  `'baseGateRejected'`。
- **声明门去重后按字典序**求值（`gateIds.toSet().toList()..sort()`），首个拒绝即返回；缺省 code 为
  `'consumerGateRejected'`。排序保证同一组门在两次相同调用中产出同一条拒绝，而不是随集合迭代顺序抖动。
- **空集 = 只跑基础门**。这不是本条发明的解释，而是 UI 面的既有判例：`ui.semantics.action`
  （`semantics_bridge.dart:118`）、`ui.semantics.tap`（`:219`）、`ui.gesture.*`（`gesture_bridge.dart:170`）、
  `navigation.go/push`（`navigation_bridge.dart:97/122`）都以 `evaluate(const <String>{})` 求值基础门。
  domain 面沿用同一含义，不为"写命令但没声明门"造第二种解释。这条的代价与补偿见下方兼容一节与待裁决 1。

### evaluator 的来源与"声明了却无处求值"

host 今天完全没有 evaluator：`PatchbayServiceHost` 不接收、也不构造 `PatchbayGateEvaluator`；evaluator 由
接入方构造后交给 `PatchbayFlutterBridge` 与 `PatchbayArtifactService`。因此本条必须新增注入点：

- `package:patchbay`：`PatchbayServiceHost` 两个工厂与 `HostInvokerHandler` 增加 additive 可选具名参数
  `domainGates`（`PatchbayGateEvaluator?`，默认 null）。不新增公共类型，`tool/api_surface.json` 的
  `patchbay` 符号清单不变。
- `package:patchbay_flutter`：`PatchbayFlutterServiceHost` **自动复用 bridge 已持有的 evaluator**（为
  `PatchbayFlutterBridge` 增加公开 getter），不新增构造参数。理由：一个 host 只应有一套门语义，同一个
  gateId 在 UI 面与 domain 面必须指同一件事；让 Flutter 接入方可以选择"UI 面强制、domain 面不强制"，等于
  把本条要修的缺口做成可配置项。

由此产生一条必须冻结的组合：**目录行声明了非空 `gates` 的写命令，落在没有 evaluator 的 host 上**。这是
不可满足的契约——声明的门永远不可能通过。处置为拒绝，复用既有形状：

```json
{
  "schemaVersion": 1,
  "admission": "rejected",
  "requestId": "…",
  "rejection": {
    "code": "consumerGateRejected",
    "details": {"gateId": "<字典序最小的声明门>", "reason": "gateEvaluatorUnavailable"}
  }
}
```

`gates` 为空且无 evaluator 时不加闸、不拒绝，行为与升级前逐字节一致（见兼容一节）。这条组合规则保证
本仓从此**不存在"声明了门但没人执行"的窗口**：要么门被求值，要么调用被拒绝。

### 拒绝形状

门拒绝复用 UI 面已经在用的同一形状（`flutter_bridge.dart:413-421`）：

- `admission: "rejected"`；
- `rejection.code`：consumer 门自己返回的 code；未提供时为 `baseGateRejected` / `consumerGateRejected`；
- `rejection.notice`：consumer 门自己的 notice（可空），信封顶层 `notice` 与之一致；
- `rejection.details.gateId`：被拒绝的门 ID。

**本条不新增稳定 error code。** 复用的四类是：consumer 自定义 code、`baseGateRejected`、
`consumerGateRejected`、`providerProtocolViolation`（门后漂移，见下节）。三个内建 code 均已在
`packages/patchbay/test/error_code_registry_ratchet_test.dart` 的 `_frozenStableCodes` 内，PB-050-23 的
ratchet 无需改动。本条引入的 `gateEvaluatorUnavailable`、`catalogGateDrift` 是
`details.reason` 值，按该 ratchet 文件明示的判据（"只在 `details.reason` 里出现、从未成为顶层 code 的
字符串……这类字符串故意不收录"）不进注册表。

若待裁决 1 或 2 改选新增稳定 code 的方案，该 code 必须**先**进 `_frozenStableCodes` 再合入实现，否则
ratchet 判红——这是 PB-050-23 与本条的硬接缝。

CLI 侧无改动：门拒绝是 `admission: rejected` 的响应信封，沿用
[`docs/design.md` 的"桥 / adapter 受理前拒绝"](../../design.md) 行，退出码 `5`。

### 门后复核与 TOCTOU

consumer 门可以 `await`。等待期间动态 catalog provider 的 `commandsRevision` 可能前进，同一命令的
`sideEffect` 或 `gates` 可能变化。UI 面对同类漂移的既有判例是"门后二次解析 / 二次比对，漂移即稳定拒绝，
不自动重试"（`uiGenerationStale`、`uiSemanticsPolicyChanged`、`uiGesturePolicyChanged`、
`navigationPolicyChanged`）。domain 面沿用同一姿势：

1. 门通过后再次 `readInvocationCatalog()`。命中 PB-050-03 的 revision 缓存时这是 O(1)：先读廉价同步
   getter，revision 未变即复用同一份 validity/index，不重新枚举 descriptor、不重算 canonical/digest。
2. 目录在此期间整体失效 → 沿用既有 `providerProtocolViolation` + `details.catalog`，reason 为
   `catalogUnavailable`，与闸前同一形状。
3. 目录有效但该命令的**门相关投影**（`writesSideEffect`、`declaredGates`）与闸前不同 →
   `providerProtocolViolation`，`details.reason = 'catalogGateDrift'`，`details.command` 为命令名。
   不携带新旧门 ID 差异（见安全与隐私）。**不自动按新声明重新求值**：一次调用只过一次门，漂移即如实
   拒绝，由调用方重发。
4. 投影一致 → 继续派发。

门求值期间不占用 external ledger slot：`_reserveExternalInvocationSlot()` 在 `_dispatchExternal` 内部，
位于闸之后。因此一个慢门不会消耗 256 条 ledger 容量，也不会把其他命令挤成 `requestLedgerFull`。

### 与 requestId 去重 / replay 的次序

闸位于 `_dispatchExternal` 之前，因此**先于**既有的 `(command, requestId)` ledger 查询与 replay。语义是
"每一次受理都要过门"，包括声明幂等的重试：replay 也会返回一个信封，返回信封就是一次受理。

这条与已接受的 DG-050-04 不冲突：
[invocation-cancellation Proposal](invocation-cancellation.md) 要求 "external 的 lookup/replay 必须发生在
active-owner 256 与 execution admission 之前"，约束的是 replay 与**容量**的次序（replay 不该被容量饿死）；
门是**授权**判断，不占执行容量、也不会被容量饿死，两者不在同一维度。

代价必须显式冻结：门在两次尝试之间关闭时，第二次尝试拿到的是门拒绝，而那次写**已经发生过**。若调用方
把它读成"没发生"，随后换一个 requestId 重试，就会产生第二次副作用。因此当 `(command, requestId)` 在
ledger 中已有记录时，门拒绝的 details 必须额外带 `priorRequestObserved: true`，让调用方无法把这条拒绝
读成"什么都没发生"。这个布尔只说明"这个 requestId 此前被受理过"，不泄露参数、结果或执行分类。

### 审计

`onGateResult` 回调现在也覆盖 external 路径，取值仍在既有封闭词表内，**不新增取值**：

| 场景 | `gateResult` |
|---|---|
| 只读 domain 命令（不加闸） | `notEvaluated`（不变） |
| 写命令，有 evaluator，门通过（含空集只过基础门） | `passed` |
| 写命令，有 evaluator，门拒绝 | `rejected` |
| 写命令，无 evaluator 且 `gates` 为空（老 consumer） | `notEvaluated`（不变） |
| 写命令，无 evaluator 但声明了 `gates`（不可满足契约） | `rejected` |

`_dispatchExternal` 的 `replay` disposition 继续抑制审计（既有语义）；门拒绝发生在 replay 判定之前，因此
门拒绝**总是**记一条审计事件。

### VM Service 与 direct

两条传输共用同一个 `HostInvokerHandler.dispatchInvoke`，没有第二条派发路径：

- VM Service：`packages/patchbay/lib/src/host/host_vm_service.dart:146` 的 `handleInvoke` 调用
  `_invokerHandler.dispatchInvoke`。
- direct：`PatchbayServiceHost.dispatchInvoke` 是公开的传输中立 seam，example 的
  `example_direct_transport.dart:52` 以 `invoke: host.dispatchInvoke` 接线。

因此闸点天然被两条传输共享，**不允许**在任一传输层再放一份门判断。验证仍按仓规对两条传输逐项对拍
code / details / 退出码 / 审计事件。

## 状态、失败与预算

- 门求值无内建超时。慢门的等待预算由调用方 deadline 承担；PB-050-06 落地后，门求值应计入统一受理预算，
  否则一个不返回的门可以绕过 deadline。本条不引入预算字段，只保证门不占用 external ledger slot，让
  PB-050-06 可以在不改门语义的前提下把它纳入预算。
- 门的失败模式只有"通过"和"拒绝"。consumer 门抛异常时按既有 evaluator 行为传播——`gates.dart` 今天不捕获
  异常，本条不改变这一点，也不新增一层 try/catch 把它变成一条新的拒绝码。这条现状写在这里以便评审：
  若仓主认为门抛异常应转成稳定拒绝，那是对 `gates.dart` 的独立改动，见待裁决 4。
- job 命令的门只在受理点求值一次。job 在后台执行期间不重评门，也不因门在执行期间关闭而取消 job。这与
  DG-050-10（reveal 每步重评门）不矛盾：reveal 是**一次调用内**的多步派发，每步都是一次新的派发；job 是
  **跨调用**的后台执行，其终止事实由 job ledger 与显式 cancel 表达，不由门表达。
- 资源上限不变：ledger 256 条、审计 256 条、目录缓存单 revision，均不因本条改动。

## 兼容与降级

### 老 consumer 升级后的确切行为

按"是否注入 evaluator"分两类，判据是包而不是接入方意图：

**A. 只用 `package:patchbay` 的 host（不传 `domainGates`）**

| 目录行 | 升级后 |
|---|---|
| 只读 domain 命令 | 逐字节不变 |
| 写命令，`gates` 为空 | 逐字节不变（无 evaluator、空集，不加闸） |
| 写命令，声明了 `gates` | 拒绝 `consumerGateRejected` + `reason: gateEvaluatorUnavailable` |

第三行是本条唯一会让"以前能跑"变成"现在被拒"的情况，且它本来就是一条无法满足的声明。今天没有任何
理由写出这种声明（写了也不生效），所以实测影响面预期为零；仓内 `idempotent_retry_audit_test.dart` 的
`device.write` fixture（无 evaluator、无 `gates`）落在第二行，保持 `gateResult: notEvaluated` 不变。

**B. 用 `package:patchbay_flutter` 的 host（evaluator 恒定存在）**

| 目录行 | 升级后 |
|---|---|
| 只读 domain 命令 | 逐字节不变 |
| 写命令，`gates` 为空 | **基础门开始对它求值**；基础门放行则逐字节不变，基础门拒绝则命令被拒 |
| 写命令，声明了 `gates` | 基础门 + 声明门按序求值 |

第二行是本条对老 consumer 的**主要行为变化**，必须在发布说明中单独列出：基础门是设计上不可省略的门，
domain 写命令此前完全跳过它。基础门永远放行的接入方（含仓内 example、双语 README quick-start）观察不到
差异；基础门带条件（例如"依赖未就绪时拒绝"）的接入方，会看到 domain 写命令在这些窗口内开始被拒——方向
正确，但确实是行为变化。

第三行今天不存在于任何已知接入方（该字段在 domain 面无效，没人会去写），因此"新拒绝"不会凭空出现；
它只在接入方**主动迁移**后才生效。

### 迁移路径

想要 PB-050-22 那套"只读默认开放、写入显式开放"落到 domain 面的接入方，只需两步，都是接入方仓内改动：

1. 给每条 `sideEffect != none` 的 domain descriptor 加 `gates: {<自己的写门 ID>}`；
2. 在 `consumerGate` 中处置该 ID。

注意一条有用的性质：多数接入方的 `consumerGate` 对未知 ID 返回拒绝（example 的 `_exampleConsumerGate`
返回 `unknownConsumerGate`）。因此**声明了一个没接线的门 = 拒绝，而不是放行**——迁移中途的半成品状态是
fail-closed 的。

不迁移的接入方保持 A/B 表中的行为；本条不强制任何接入方在 0.5.0 内完成迁移。

### 发布说明义务

0.5.0 发布说明必须列出下列四条，不得只写"修复 gate 未强制执行"：

1. 基础门开始覆盖 domain 写命令（`sideEffect` 非 `none`），此前完全跳过；
2. descriptor `gates` 对 domain 写命令从展示字段变为强制字段；
3. 审计事件 `gateResult` 对 domain 写命令从 `notEvaluated` 变为 `passed` / `rejected`；
4. 声明了 `gates` 但 host 无 evaluator 的组合会被拒绝，附迁移表。

### 其他兼容面

- wire、catalog / descriptor 稳定 JSON、`catalogDigest.covers`、退出码映射均不变；
- 0.4.1 复刻 reader 读取新 host 的 catalog 与 invocation 输出逐字节不变；
- 老 CLI ↔ 新 host：门拒绝是既有 rejection 信封，老 CLI 不需要认识任何新字段；
- 新 CLI ↔ 老 host：老 host 不加闸，CLI 不做任何补偿或本地模拟——门是 host 的事实，CLI 不得替它判断。

## 逐命令回归矩阵（example）

example 当前的 10 条 domain 命令（`example_domain.dart` 9 条 + `main.dart` 的
`example.benchmark.semanticsProbe`）。"迁移后"一列指 example 完成上节两步迁移、6 条写命令声明
`exampleWriteGate` 之后的状态；example 的 `consumerGate` 对该门放行，`factoryDefaultWriteGateDecision`
用于关门用例。

| 命令 | mode | sideEffect | 加闸 | 升级前 | 迁移后（门开） | 迁移后（门关） |
|---|---|---|---|---|---|---|
| `example.permission.request` | immediate | external | 是 | 直达 adapter | 逐字节不变 | `writeGateClosedByDefault` + `gateId` |
| `example.device.write` | immediate | external | 是 | 直达 adapter | 逐字节不变 | 同上，且设备值不变 |
| `example.idempotent.touch` | immediate | external | 是 | 直达 adapter | 逐字节不变；replay 仍返回同一执行事实 | 同上；已有 ledger 记录时带 `priorRequestObserved` |
| `example.counter.increment` | immediate | appState | 是 | 直达 adapter | 逐字节不变 | 同上，且 counter 不变 |
| `example.job.run` | job | appState | 是 | 直达 adapter | 逐字节不变；门只在受理点求值 | 同上，且不产生 jobId |
| `patchbay.job.cancel` | immediate | appState | 是 | 直达 adapter | 逐字节不变 | 同上——**见下方风险** |
| `example.permission.status` | immediate | none | 否 | — | 逐字节不变 | 逐字节不变 |
| `patchbay.job.get` | immediate | none | 否 | — | 逐字节不变 | 逐字节不变 |
| `patchbay.job.wait` | immediate | none | 否 | — | 逐字节不变 | 逐字节不变 |
| `example.benchmark.semanticsProbe` | immediate | none | 否 | — | 逐字节不变 | 逐字节不变 |

另外三条必须进矩阵的边界行：

| 场景 | 期望答复 |
|---|---|
| 目录中不存在的命令（`undeclared()`） | 按写加闸；门关时门拒绝先于 `commandNotRegistered` 出现 |
| 写命令 + 非法参数（如 `example.device.write` 的 `value: "x"`） | 门关时返回门拒绝，而不是 `invalidArguments` |
| 写命令 + sensitive 参数未走 stdin | 仍先返回 `sensitiveInputRequiresStdin`（sensitive 早于门） |

第二行是本条的一条**刻意的次序后果**，必须冻结而不是当 bug：registry 命令的次序是"decode → gate"，
domain 命令只能是"gate → adapter 自行 decode"，因为 host 不持有接入方的参数词表、无法在不进入 adapter 的
情况下解码。安全方向也更好：未获授权者不应先拿到参数探测反馈。

**`patchbay.job.cancel` 的风险与接入指引**：它是 `sideEffect: appState`，因此会被加闸；写门关闭时，正在
运行的 job 将无法通过 Patchbay 取消。这不是协议缺陷（cancel 确实改状态），但接入方必须知道。指引为：
让 cancel 与 run 共用同一个门（拿得到启动权限就拿得到停止权限），或为 cancel 单列一个不比 run 更严的门；
不要给 cancel 配一个比 run 更严的门。example 采用前者。

example 侧的具体改动清单（作为本条实现 MR 的一部分）：6 条写 descriptor 加 `gates`、删除
`example_domain.dart` 中那段"已知限制"注释、新增一条断言"每条 `sideEffect != none` 的 example domain 命令
都至少声明一个门"的测试、`tool/example_precheck.sh` 的写命令主链保持全绿（门开），关门路径由单元测试
覆盖而不进预检主链。

## 与相邻条目的接缝

- **PB-050-22（UI 面出厂门）**：本条是它在 domain 面的落点。PB-050-22 提供"写拒绝带解释 code 的预设门"
  与 example/README 的默认策略；本条提供让该策略在 domain 面生效的执行点。两条各自可独立回退：回退本条
  不影响 PB-050-22 的 UI 面默认门，回退 PB-050-22 不影响本条的执行机制。
- **PB-050-23（error code 注册表 ratchet，已验证）**：本条按当前方案不新增稳定 code，ratchet 不改。若
  待裁决 1/2 改选新增码，新码必须先进 `_frozenStableCodes` 再合实现。
- **PB-050-13 / DG-050-07（CLI 公共面收口）**：无交集。本条只改 `package:patchbay` 与
  `package:patchbay_flutter`，不增删任何 `patchbay_cli` 公共符号；`tool/api_surface.json` 的 `patchbay` /
  `patchbay_flutter` 清单也不变（新增的是具名参数与实例 getter，不是新类型）。
- **PB-050-03 / PB-050-05 / PB-050-06（同改 `host_invoker.dart`）**：按版本计划的串行纪律排队。建议顺序为
  PB-050-03（已接受，是本条门后复核 O(1) 的底座）→ **PB-050-25**（P0、改动面最小）→ PB-050-05 → PB-050-06。
  PB-050-06 重排 external lookup/replay 与 admission 次序时，必须保持门位于 lookup/replay 之前。
- **DG-050-10（reveal）**：reveal 被定性为写操作并"每步重评门"。两者不冲突：reveal 的多步在一次调用内，
  domain 命令的执行在 adapter 内且 host 无法观察其步骤，只能在受理点求值一次。

## 安全与隐私

- 拒绝 details 只带 `gateId`（协议词表，接入方自己命名）、`reason`（封闭内部词）、`command`（目录已公开）
  与 `priorRequestObserved`（布尔）。不带参数名、参数值、门的内部判据或漂移前后的门 ID 差异——后者会把
  接入方的授权策略变化泄露给一个刚刚被拒绝的调用方。
- 审计事件形状不变，仍只有 `command/requestId/parameterShape/gateResult/executionClassification`；门拒绝
  不新增字段，也不把门 ID 写进审计。
- 门求值不接触参数值：`evaluate` 只收 gateId 集合。接入方若需要按参数决策，那是 adapter 的职责，不是门的
  职责——把参数交给门会让门变成第二个 handler。
- release 裁除不受影响：门与 descriptor 都在调试面内，release 组合根不构造 host。

## 验证

- **单元/协议测试**：只读命令不加闸（含基础门不跑）；写命令空集只跑基础门；写命令声明门按字典序求值且
  首拒即返回；基础门拒绝优先于声明门；声明门未接线 → 拒绝；无 evaluator + 声明门 →
  `consumerGateRejected/gateEvaluatorUnavailable`；无 evaluator + 空集 → 逐字节不变；`sideEffect` 缺失 /
  非法 / 命令未声明三种目录行按写处理。
- **次序测试**：sensitive 早于门；门早于 registry/external 路由；门早于 ledger lookup/replay；门不占用
  ledger slot（慢门并发时其他命令不被 `requestLedgerFull` 拒绝）。
- **TOCTOU / 失败注入**：门 `await` 期间目录 revision 前进且 `gates` 变化 → `catalogGateDrift`；`sideEffect`
  从 `none` 变为写、从写变为 `none` 各一例；门期间目录整体失效 → `catalogUnavailable`；门后投影一致 →
  正常派发；漂移不触发自动重试。
- **幂等/replay**：同 requestId 第二次在门开时返回同一执行事实；门在两次之间关闭时返回门拒绝且带
  `priorRequestObserved: true`；`requestIdConflict` / `duplicateRequestId` / `requestLedgerFull` 的形状不变，
  只是次序在门之后。
- **审计**：上表五种 `gateResult` 各一例；门拒绝必记一条事件；replay 仍不记事件；事件不含参数值与 gateId。
- **VM/direct**：上述矩阵在两条传输上逐项对拍 code、details、notice、退出码与审计事件。
- **兼容**：0.4.1 复刻 reader 读取新 host 的 catalog 与 valid invocation 输出逐字节不变；只读 domain 命令
  golden 不变；`idempotent_retry_audit_test.dart` 现有断言（`gateResult: notEvaluated`）保持绿。
- **example 回归矩阵**：上表 10 条命令 + 3 条边界行，门开 / 门关两态各跑一遍。
- **接入方/真机**：`tool/example_precheck.sh` 的 debug 主链（门开）与 `tool/example_profile_smoke.sh` 的
  profile 答复形态全绿；随后由业务接入方在真机上验收自己的写门策略。本条改的是受理段逻辑，与构建模式
  无关，但按仓规两个脚本都要跑。

## 实施与回退

实施顺序（先失败测试，再实现）：

1. 补能失败的测试：一条声明了 `gates` 的 domain 写命令在当前 host 上被执行（复现缺口）；
2. `PatchbayCommandPolicy` 的 additive 投影 + `HostInvokerHandler` 闸点 + 门后复核；
3. `PatchbayServiceHost` 的 `domainGates` 注入点；
4. `PatchbayFlutterServiceHost` 复用 bridge evaluator + bridge 的公开 getter；
5. example 声明 `gates`、删除"已知限制"注释、补回归矩阵测试；
6. README / guide / SKILL 的接入规范同步（"domain 写命令必须声明门"）。

MR 颗粒度：第 2–4 步是同一条契约的两端，拆开后任一半不可用，必须同一个 MR；第 5–6 步可同 MR 或紧随其后
的独立 MR，但必须在同一版本内合入，否则 example 会停留在"缺口已修但样板未演示"的中间态。

回退边界：移除闸点即回到 catalog-only，可独立回退，不牵动 PB-050-22 的 UI 面默认门与 PB-050-03 的目录缓存。
回退时**必须同时回退 example 的 `gates` 声明**——否则会重新制造一份"声明了但不执行"的样板，正是本条要
消灭的东西。第 1 步的复现测试按 PB-050-16 的回退纪律保留并标注 skip 理由，不与实现一起回退。

## 待裁决

1. **写命令 `gates` 为空时是否 fail-closed。** 本文建议 A：只跑基础门，与 `gates.dart` 及 UI 面既有判例
   完全一致，不为 domain 面造第二种空集语义。代价是"写命令没声明门"仍然只受基础门保护，而基础门无参数、
   读写不分。补偿手段是把它变成可见且可机检的事实：catalog / `describe` 已经同时暴露 `gates` 与
   `sideEffect`，仓内新增测试锁定 example 的每条写命令都声明了门，接入文档写明这是接入规范。
   备选 B：空集写命令直接拒绝，新增稳定码（如 `writeGateUndeclared`）并先进 PB-050-23 注册表。B 的安全
   叙事更完整，但会让所有未迁移的接入方在升级瞬间失去全部 domain 写能力，且需要 0.5.0 内完成两个已知
   接入方的迁移。请仓主在 A/B 间裁决。
2. **无 evaluator + 声明了门时的答复。** 本文建议复用 `consumerGateRejected` +
   `details.reason: gateEvaluatorUnavailable`，不新增稳定码。备选：新增
   `gateEvaluatorUnavailable` 为顶层稳定码，诊断更直接但要扩注册表。
3. **门与 replay 的次序。** 本文建议门先于 ledger lookup/replay（每次受理都过门），并以
   `priorRequestObserved` 防止被读成"没发生"。备选：replay 先于门，让已记录的执行事实始终可取回；代价是
   门关闭后仍会把一次写的执行事实交给一个已不再被授权的调用方。
4. **consumer 门抛异常的处置。** 现状是异常向上传播，`gates.dart` 不捕获。本条维持现状；若仓主认为应转成
   稳定拒绝，那是对 `gates.dart` 的独立改动，会同时影响 UI 面全部门，应另立条目而不是夹带在本条。
5. **非法 `sideEffect` 值是否升级为整份目录违规。** 本文建议不升级（按写处理即可 fail-closed），避免在
   P0 里塞进一条新的硬 breaking。若仓主希望与"整份目录 fail-closed"完全对齐，应作为 PB-050-03 语义的
   独立扩展另行裁决。

### 裁决结论（2026-08-25，仓主授权代理裁决）

1. **A 采纳**：空 `gates` 写命令只跑基础门，与 UI 面空集判例一致，不造第二种空集语义；补偿三件套
   （catalog/describe 可见、example 写命令声明门的机检 ratchet、接入规范文档）升级为本条验收义务。
2. 复用 `consumerGateRejected` + `details.reason: gateEvaluatorUnavailable`，零新增稳定码。
3. **门先于 ledger lookup/replay**：授权是当下事实，不因历史写已发生而豁免；`priorRequestObserved`
   防误读。PB-050-06 重排受理次序时必须保持门在 lookup 之前（写入其接缝义务）。
4. consumer 门异常传播维持现状；改动属 `gates.dart` 全域语义，另立条目。
5. 非法 `sideEffect` 按写处理即 fail-closed，不升级为整份目录违规；目录级扩展归 PB-050-03 语义域另裁。

## 被否决方案

- **在 `domainInvoke` adapter 里由接入方自己按命令名求值门**：这正是今天的现状（且没有接入方在做）。它把
  安全边界从协议挪到每一个接入方，descriptor 的 `gates` 继续是装饰，`docs/design.md` 立场 3 继续被违反。
- **给基础门加"读写"参数以区分只读与写**：能让"写默认拒绝"不依赖 descriptor，但要改
  `PatchbayBaseGate` 签名（对所有接入方 breaking），且把"这是不是写操作"从 descriptor 搬进门实现——同一
  事实两处声明，必然漂移。descriptor 的 `sideEffect` 已经是该事实的唯一真源。
- **按命令名前缀（如 `*.write`、`*.set`）推断是否加闸**：命令名是接入方词表，不是协议事实；
  `example.counter.increment` 就不含任何写词。这是"用字面量猜语义"，与"事实来源是封闭词表"直接冲突。
- **在 VM Service 与 direct 两个传输各加一次门**：两份实现必然漂移，且违反"VM/direct 共享同一实现"的仓规。
  单一 `dispatchInvoke` seam 已经让一处实现覆盖两条传输。
- **门通过后不复核目录**：门可以 `await`，等待期间动态目录可以改声明。不复核等于让一次调用按旧声明拿到
  授权、按新声明执行，正是 UI 面用"门后二次解析"堵住的那个窗口。
- **门后自动按新声明重新求值**：会把一次调用变成不定次数的门求值循环，且调用方无法知道自己最终过的是
  哪一版声明。漂移即如实拒绝、由调用方重发，与 `uiGesturePolicyChanged` 一致。
- **让 Flutter host 用一个独立于 bridge 的 evaluator（或允许 domain 面不注入）**：同一个 gateId 会在两个平面
  指向两套判断，接入方还能选择"UI 面强制、domain 面不强制"——等于把本条要修的缺口做成配置项。
- **把参数值交给门以支持按值授权**：门会变成第二个 handler，且参数值将出现在授权决策路径上，与审计只留
  形状、不留值的边界冲突。按值决策属于 adapter 职责。
