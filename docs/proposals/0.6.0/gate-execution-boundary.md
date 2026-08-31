# 0.6.0 Gate 声明与执行真源

> 状态：已接受
>
> 关联：PB-050-39、PB-050-26
>
> 设计闸门：DG-060-04

## 问题

0.5.0 已修复 domain descriptor 的 `gates` 只展示、不强制执行，但完整准入仍分布在 core host、Flutter
bridge、Semantics action policy、gesture policy 与 reveal 每步重评。声明、执行和审计不在同一边界，新 plane
或新 action 仍可能重复出现“目录承诺了一条门，dispatch 没经过它”的缺口。
同一分裂也体现在 reveal 审计：当前事件缺少实际 steps 与被驱动容器标识，但直接补字段会改变公共
`PatchbayAuditEvent` 形状，必须与 admission stage 和审计投影一起裁决，不能由实现 MR 顺手富化。

## 目标与非目标

### 目标

- 每类 gate/policy 都能回答声明者、所有者、评估阶段、拒绝形状、审计结果与兼容降级。
- core host 统一执行 base gate、descriptor gate、sideEffect 与审计投影。
- Flutter bridge 只拥有需要 UI 现场事实的 target/generation/lifecycle/occlusion/policy 阶段。
- 冻结 reveal 审计是否记录 steps 与被驱动容器标识，以及字段预算、脱敏和老 reader 降级。

### 非目标

- 不把语义不同的 base gate、consumer gate、gesture policy 合并成一个布尔 callback。
- 不减少 reveal 每步重评，不缓存授权结果，不提供 bypass。
- 不以重构名义改变 0.5.0 domain 只读/写门语义。

## 契约

推荐建立显式 admission pipeline：descriptor 解析与整份 catalog validity → core base/declared gate → UI
preflight 与操作 policy → await 后 catalog/target/generation/lifecycle 二次复核 → dispatch → evidence/audit
投影。每阶段返回类型化 decision 和封闭 stage 标识；core 负责通用 gate audit，Flutter 只返回 UI-specific
decision，不自行解释 descriptor 字段。reveal 每一步复用同一 evaluator，但每步持有独立现场复核。

## 状态、失败与预算

受理与执行继续分离。gate await 计入单一调用 deadline；任一阶段拒绝后不得执行后续 gate 或 handler。
catalog/target 在 await 后漂移返回 provider/target 稳定拒绝，不重试。审计记录 stage 与 passed/rejected，
不记录参数值、策略自由文本或目标坐标。若接受 reveal 富化，steps 必须有既有执行预算上界，容器标识使用
稳定、非坐标、非文案的有界列表；字段在未执行或旧 host 上的缺省形状必须明确。

## 兼容与降级

目标是拒绝形状逐字节保持；若需要新增 additive `admissionStage`，老 reader 忽略，新 reader 对老 host 视为
unknown/legacy，不能推断为 passed。VM/direct 使用同一 host pipeline。任何 consumer gate 注入 API 变化都
属于 source breaking，必须在 Proposal 接受前冻结迁移表。

## 安全与隐私

未知 gate、缺 evaluator、目录漂移与 policy 异常均 fail-closed。details 只报告稳定 stage/reason/gateId，
不回显 consumer callback 错误消息、参数原值或命中坐标。release compile-time 裁除边界不变。

## 验证

- 单元/协议测试：每阶段拒绝、短路、await 漂移、审计与异常隔离矩阵。
- 审计兼容：PB-050-26 候选字段的 absent/empty/populated、最大 steps/容器数、老 reader 与脱敏矩阵。
- VM/direct：同一 registry/external/UI 命令的 envelope 与退出码一致。
- 接入方/真机：domain write、text、semantics、pointer、reveal 多步和 navigation。
- 失败注入：缺 evaluator、未知 gate、policy throw、deadline、dispose 与 post-gate remount。

## 待裁决

- operation policy 是否进入 descriptor 声明，还是保持注入对象但统一执行阶段；推荐后者，避免假装静态。
- 是否新增稳定 `admissionStage`；若仅进 audit/details，兼容边界分别是什么。
- Flutter host 是否把 domain 与 UI registry 合成一份 pipeline，还是共享中立 admission primitive。
- consumer gate 注入形态是否改变；推荐优先零 source breaking 的边界收敛。
- PB-050-26 的 reveal 审计是否增加 steps 与被驱动容器标识；若增加，字段命名、缺省形状、列表上限和
  老 reader 行为是什么；若不增加，是否明确移出 1.0 承诺面。

## 裁决结论（DG-060-04，2026-08-31）

### 一条 pipeline，两种 registry，不序列化动态 policy

接受中立、invocation-scoped 的 admission primitive，不把 domain registry 与 Flutter UI registry 合成一个
对象。core host 对 registry-owned 与 external command 执行同一条前半 pipeline：catalog validity → sensitive
input → base gate → descriptor gate；Flutter handler 只追加 target/generation/lifecycle/occlusion 与动态
operation policy，随后把类型化 UI decision 交回 core 完成 response validation 与 audit projection。

动态 Semantics/gesture/reveal policy 保持构造注入对象，不进入 descriptor wire。descriptor 只能声明静态
`gates`、`sideEffect` 与 DG-060-05 接受的 `interactionModel`；把现场 policy 序列化会把“当前 callback 的
判断”伪装成目录静态事实。现有 `PatchbayGateEvaluator`、base gate 与 consumer gate 构造注入保持
source-compatible；实现可增加内部阶段 API，但不得要求 consumer 改签名或重复注册同一个 gate。

base gate 对所有 `sideEffect != none` 的命令执行；descriptor gate 只要声明非空就执行，不以 registry/external
分叉。纯只读且无声明门的命令不凭空触发 base gate。任一 await 后只做一次 catalog/target/generation/
lifecycle 复核；漂移类型化拒绝，不在同一次 invocation 重跑新声明。reveal 每一步仍重新取得现场并重评动态
policy/gate，不缓存、不租约化。

### 阶段只进入 host audit，不进入公共应答

不向 invocation envelope 或所有 rejection details 增加 `admissionStage`。调用方恢复由稳定 code、`gateId`
与既有 details 决定；把内部阶段写进公共应答会让重构拓扑变成协议。host-only `PatchbayAuditEvent` 以可选、
additive 字段记录：

- `admissionStage`：本次事实停止或完成的阶段，封闭值 `catalog`、`inputPolicy`、`baseGate`、
  `descriptorGate`、`uiPreflight`、`operationPolicy`、`postAwaitRecheck`、`dispatch`、
  `responseValidation`；
- `gateDisposition`：相对 consumer 声明门/动态 policy 的封闭值 `notReached`、`notDeclared`、`passed`、
  `rejected`。base gate 拒绝也记 `rejected`；早于任何 gate 的失败记 `notReached`。

既有 `gateResult` 字段和值保持逐字节兼容；新字段不作为它的重命名。构造参数为可选且有默认值，旧源码
构造 `PatchbayAuditEvent` 继续编译；`toJson` 对空值省略。老 audit reader 忽略新键，新 reader 遇老 host
缺键按 `legacyUnknown`，不得把缺失推断为 passed。

### 接受 PB-050-26，但只由 core 投影已校验结果

接受 reveal 审计富化。`PatchbayAuditEvent` 新增可选 `executionDetails`；仅当 `ui.reveal` 返回 accepted、
payload 已通过 response schema 与语义校验后，core host 写入以下封闭形状：

```json
{
  "reveal": {
    "steps": 3,
    "containerNodeIds": [41, 57]
  }
}
```

`steps` 必须在 `0..200`；`containerNodeIds` 按首次驱动顺序，元素为非负 int，至多 200 个，不含 generation、
identifier、rect、文案或 policy 文本。`steps == 0` 时列表为空；拒绝、provider 违规、旧 host 与非 reveal
命令省略整个 `executionDetails`。投影只读已校验 response，Flutter bridge 不直接写 audit，也不新增跨进程
audit stream。字段越界视为 host 投影缺陷并省略整块、报告既有 error observer，不截断后冒充完整事实。

PB-050-39 与 PB-050-26 分两个实现 MR：前者收敛 pipeline/阶段，必须先合；后者只增加 audit 公共形状与
reveal 投影。任一 MR 单独回退都不得撤销 0.5.0 已交付的 domain 写门强制执行。

## 被否决方案

- 每个 bridge 自己读取 descriptor 并评估通用 gate：声明和执行继续分裂。
- 把所有 policy 序列化进 catalog：动态 UI 现场策略无法由静态声明完整表达。
- gate 结果跨 invocation 缓存：授权事实可能随生命周期和 consumer 状态变化。
