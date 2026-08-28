# 0.6.0 任务导向 UI 命令入口

> 状态：提案中
>
> 关联：PB-060-01
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

## 被否决方案

- 只重排 help、不改变推荐命令：只能移动解释成本，不能减少选择成本。
- 首条路径失败后自动换 semantics/pointer：会让成功结果与调用方选择的安全语义脱钩。
- 保留全部旧路径且永久新增第五套入口：表面继续增长，违背本版目标。
