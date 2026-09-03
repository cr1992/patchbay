# 0.6.0 任务导向 UI 命令入口

> 状态：已接受
>
> 关联：PB-060-01、PB-060-08
>
> 设计闸门：DG-060-01

## 问题

0.5.0 的 UI 写操作按内部能力面组织：注册 target 使用 `ui text set/enter`，Semantics 使用 `ui tap` /
`ui action`，真实指针使用 `ui gesture tap`，未挂载目标先走 `ui reveal`。每条路径的安全语义都成立，但
使用者必须先理解 target id、Semantics identifier、nodeId、generation 与执行通道，才能选择命令。

## 目标与非目标

### 目标

- 为 UI 任务建立唯一推荐的 CLI 入口，身份域和执行通道在参数与结果中明示。
- 复用现有 wire 命令与 host 语义，不因 CLI 收敛制造第二套协议能力。
- 每条旧入口同时得到“本版即删 / 保留一版并告警 / 保留至 1.0”的迁移结论。

### 非目标

- 不新增身份域、模糊 selector、label/value 猜测、Element 自动发现或绝对屏幕坐标。
- 不在 semantics、pointer 与 direct-target 之间自动回退。
- 不把 reveal 扩成导航或把多步任务藏成不可观察的隐式流程。
- 不在 canonical 入口冻结前为即将废弃的旧命令面生成 shell 补全，也不由本 Proposal 直接授权补全实现。

## 契约

推荐候选是新增一个 CLI-only canonical 家族，例如 `patchbay ui perform <action> <selector>`：selector 显式
携带 `target:` / `semantics:` 身份，存在多种合法执行通道时由 `--via direct|semantics|pointer` 选择；只有
一种合法通道时 CLI 可以补默认，但必须在机器结果中报告实际 `executionPath`。canonical 入口解析后调用
现有 protocol command，不新增同义 service command。旧命令在迁移窗口内仍产生逐字节相同的既有结果。

## 状态、失败与预算

CLI 只做解析、live catalog 验证与一次显式派发；不得在首条路径拒绝后尝试另一条路径。用法错误仍退 64，
catalog/identity 漂移仍退 protocol，host admission 与执行终态沿用现有分类。`ui reveal` 若作为显式前置任务，
它有自己的 deadline、门和结果，不与后续 action 合成一个不可拆预算。

## 兼容与降级

优先保持 wire 不变，因此新 CLI 可面对 0.5.x host，只要 live catalog 包含被映射的既有命令；缺命令时按
`commandNotRegistered` 明示，不换通道。老 CLI 面对新 host 继续使用旧 service command。CLI 旧入口的
迁移窗口必须在实现 MR 前冻结，并由 command docs、Skill 与 CHANGELOG 共用一张生成清单。

## 安全与隐私

selector 不接收 copy/label 猜测；sensitive 输入继续走 stdin；响应不得持久化换算坐标。`--via` 是显式安全
选择，不提供 `auto`、`best` 或 fallback。direct-target、semantics 与 pointer 的遮挡差异由 DG-060-05
裁决，CLI 不自行改写 host 拒绝。

## 验证

- 单元/协议测试：旧路径到 canonical 入口的映射、参数白名单、禁止 fallback、退出码与机器结果。
- VM/direct：同一 canonical 调用映射到同一 service command 时逐字节对账。
- 接入方/真机：无先验操作者完成文本输入、语义点按、指针点按与 reveal，记录命令选择过程。
- 失败注入：目标歧义、generation stale、遮挡、policy 拒绝、catalog 漂移和传输中断。

## 待裁决

- canonical 家族最终命名与 selector 语法。
- `--via` 是否总是必填，还是仅在多通道 action 上必填。
- 四类旧入口各自的迁移窗口；推荐保留一版并告警，1.0 前删除非 canonical 推荐面。
- `executionPath` 是 canonical CLI 的本地投影字段，还是进入稳定 host payload。
- DG-060-01 接受后，是否以同一 command registry/生成清单派生 zsh/bash completion，使 deprecated 命令按
  迁移窗口自动退出补全；实现条目只在入口冻结后另立，避免维护两套短命命令树。

## 裁决结论（DG-060-01，2026-08-31）

### canonical 家族与 selector 语法

接受 CLI-only 的 `patchbay ui perform <action> <selector> ...` 家族。它解析后只调用既有 service command，
不新增 wire command、身份域或 host fallback。`action` 封闭为 `enter-text`、`tap`、`action`、
`press-hold`、`drag`、`fling`、`reveal`（`set-text` 于 2026-09-03 修订移除，见下）；selector 只允许：

- `target:<id>`：现有注册 target id；第一个冒号后的非空原文是 id，id 内后续冒号保留；
- `semantics:<identifier>`：现有 Semantics identifier，同样只消费第一个冒号；
- `node:<non-negative-int>`：现有 Semantics nodeId，不引入新的节点身份。

canonical 拼写与映射冻结为：

| CLI 入口 | selector / generation | 映射的既有 service command |
|---|---|---|
| `ui perform enter-text target:<id> <generation> [text]` | target；generation 必填 | `ui.text.enter` |
| `ui perform tap semantics:<identifier> <generation> --via semantics` | semantics；generation 必填 | `ui.semantics.tap` |
| `ui perform tap semantics:<identifier> <generation> --via pointer [--start <json>]` | semantics；generation 必填 | `ui.gesture.tap` |
| `ui perform action semantics:<identifier> <generation> <action> [text]` | semantics；generation 必填 | `ui.semantics.actionByIdentifier` |
| `ui perform action node:<nodeId> <generation> <action> [text]` | node；generation 必填 | `ui.semantics.action` |
| `ui perform press-hold/drag/fling semantics:<identifier> <generation> ...` | semantics；generation 必填 | 对应 `ui.gesture.*` |
| `ui perform reveal semantics:<identifier> ...` | semantics；无 generation | `ui.reveal` |

参数尾部、stdin、安全上限与各 service command 既有 descriptor 完全同源，不在 canonical registry 复制。
selector/action 组合不在表中即 usage error 64；node selector 不允许 tap/pointer/reveal；target selector 不允许
Semantics action。`ui.semantics.tap` 旧入口允许省 generation 的兼容行为不进入 canonical 家族，新入口一律
要求调用方携带观察代际。

### 通道选择与结果

只有 `tap semantics:` 同时存在 semantics 与 pointer 两条合法通道，因此 `--via semantics|pointer` 必填。
不提供默认值、`auto`、`best` 或失败后的第二次派发。set/enter 固定 `directTarget`，action 固定
`semanticsAction`，press-hold/drag/fling 固定 `pointerGesture`，reveal 固定 `scrollReveal`，这些命令拒绝
多余的 `--via`。

canonical 机器结果在 CLI-local 的顶层 `localRoute` 报告 `selectorKind`、`executionPath` 与实际
`serviceCommand`；不把 CLI 路由事实伪装进 host payload。`executionPath` 封闭值为 `directTarget`、
`semanticsAction`、`pointerGesture`、`scrollReveal`，与 DG-060-05 的 `interactionModel` 一致但不替代它。
底层 host response、requestId、admission、payload、退出码与 VM/direct 字节保持不变。

### 裁决修订（2026-09-03，PB-060-08）：移除 `set-text`

`ui.text.set` 只替换 controller 值，不跑 `inputFormatters`、不调 `onChanged`；`set-text` 这个名字不表达这层
差别。接入方首次使用就把它当成「输入文本」，表单状态不动、提交按钮恒禁用。`enter-text` 在实践上是超集：
formatter 与 `onChanged` 都走，`onChanged` 为空时退化成同一结果。canonical 家族因此只保留 `enter-text`。

- `ui text set` 的迁移目标改为 `ui perform enter-text target:<id> <generation> [text]`；deprecated 窗口不变，
  仍保留至 1.0 并向 stderr 告警。
- wire 命令 `ui.text.set` 与 host 行为不变。只写 controller 的自动化面继续经 deprecated 入口与 wire 命令可达；
  `ui.text.set` 是否进入 1.0 承诺留给 RC 的候选评估。
- `ui perform` 的 help 标明 `target:` 的 generation 来自 `ui targets`，`semantics:` / `node:` 的来自
  `ui semantics tree`；stale 拒绝携带 `currentGeneration`，CLI 不据此自动重发。

### 旧入口窗口

以下写入口在 0.6.0 保留一版并标记 deprecated，在 1.0 删除：`ui text set|enter`、`ui tap`、`ui action`、
`ui semantics action`、`ui gesture tap|press-hold|drag|fling`、`ui reveal`。0.6.0 的 help、command docs、Skill
与发布迁移表给出逐项 canonical 替代；人读调用向 stderr 给一次告警，`--json` stdout、退出码与底层应答
逐字节不变。只读 `ui semantics tree`、`ui wait`、capture/inspect/keep-awake 不属于本次入口迁移。

新 CLI 面对 0.5.x host 先按 live catalog 验证映射的 service command；缺失即 `commandNotRegistered`，不换
通道。老 CLI 面对新 host 不受影响。shell completion 不在 PB-060-01 内实现；若另立条目，必须从同一
canonical/deprecation registry 生成，不能维护第二棵命令树。

## 被否决方案

- 只重排 help、不改变推荐命令：只能移动解释成本，不能减少选择成本。
- 首条路径失败后自动换 semantics/pointer：会让成功结果与调用方选择的安全语义脱钩。
- 保留全部旧路径且永久新增第五套入口：表面继续增长，违背本版目标。
