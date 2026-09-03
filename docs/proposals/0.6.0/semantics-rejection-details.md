# 0.6.0 Semantics 拒绝 details 对齐

> 状态：提案中
>
> 关联：PB-060-09
>
> 设计闸门：DG-060-06

## 问题

`PatchbaySemanticsBridge` 有两条解析路径。按 identifier 解析（`_resolveIdentifier`，服务
`ui.semantics.tap` / `ui.semantics.actionByIdentifier`）时，`uiSemanticsActionBlocked` 与
`uiSemanticsActionUnavailable` 的 details 带候选节点事实：`nodeId`、`generation`、`label`（obscured 时为
`labelRedacted`）、`actions`、`invisible`、`userActionsBlocked`，后者另带 `requestedAction`；
`uiSemanticsGenerationStale` 带 `identifier`、`nodeId`、`expectedGeneration`、`currentGeneration`。

按 nodeId 解析（`_resolve`，服务 `ui.semantics.action`，即 canonical `ui perform action node:`）对同一组码
返回裸码，`uiSemanticsGenerationStale` 只带 `currentGeneration`。两条路径都不表达节点的 enabled 状态：
接入方真机复现是浮层下点一个禁用按钮，只拿到 `uiSemanticsActionUnavailable`，要截屏才知道原因是「按钮禁用」，
而 Flutter 语义树本来就带 `hasEnabledState` / `isEnabled`。

## 目标与非目标

### 目标

- nodeId 路径的三个拒绝 details 与 identifier 路径同形，调用方按 nodeId 派发失败时得到同一份候选事实。
- 两条路径的候选节点 details 在节点声明 enabled 状态时新增 `enabled`，把「禁用」从截屏事实变成拒绝事实。
- 纯 additive：错误码、退出码、payload、审计与 VM/direct 行为不变。

### 非目标

- 不新增错误码，不改变 `uiSemanticsActionBlocked` 与 `uiSemanticsActionUnavailable` 的判定条件。
- 不为没有 enabled 状态的节点编造 `enabled: true`。
- 不在 details 里加坐标、rect、覆盖层身份或其他 0.5.0 遮挡准入 Proposal 已否决的内容。
- 不改 `ui.semantics.tree` 的节点 wire；enabled 状态在树里继续以 `flags` 字符串表达。

## 契约

候选节点 details（`_candidate`）封闭表，两条路径共用：

| 键 | 类型 | 出现条件 |
|---|---|---|
| `nodeId` | int | 必有 |
| `generation` | int | 必有；该节点当前观察代际 |
| `label` / `labelRedacted` | string / true | 二选一；节点 obscured 时只出 `labelRedacted: true` |
| `actions` | string[] | 必有；升序，只含公共 `PatchbaySemanticsAction` 名 |
| `enabled` | bool | 仅当 `hasEnabledState` 为真；值为 `isEnabled` |
| `invisible` | bool | 必有 |
| `userActionsBlocked` | bool | 必有 |

按码：

| code | nodeId 路径 details（新） | identifier 路径 details（不变，仅多 `enabled`） |
|---|---|---|
| `uiSemanticsActionBlocked` | 候选表 | 候选表 |
| `uiSemanticsActionUnavailable` | 候选表 + `requestedAction` | 候选表 + `requestedAction` |
| `uiSemanticsGenerationStale` | `nodeId`、`expectedGeneration`、`currentGeneration` | `identifier`、`nodeId`、`expectedGeneration`、`currentGeneration` |

`uiSemanticsIdentifierAmbiguous` 的 `candidates` 数组元素同为候选表，因此也随之带 `enabled`。

## 状态、失败与预算

不引入状态、超时或重试。details 由解析瞬间的 `SemanticsData` 一次性投影，不额外请帧、不遍历子树，
成本与 identifier 路径现状相同。

## 兼容与降级

- 老 CLI / reader：details 是松读面，未知键忽略；错误码不变，退出码不变。
- 新 CLI 面对老 host：nodeId 路径拒绝可能仍是裸码或缺 `enabled`，CLI 不据此猜测，按既有 rejected 分类退出。
- VM Service 与 direct：details 在 host 侧构造，两传输逐字节相同。

## 安全与隐私

沿用候选表既有的 label 脱敏规则：obscured 节点只出 `labelRedacted: true`。`enabled` 是布尔状态，不携带
文本或坐标。不提供任何绕过 blocked / unavailable 的参数。

## 验证

- 单元/协议测试：`packages/patchbay_flutter/test/bridge/semantics_rejection_details_test.dart` 覆盖
  nodeId 路径的 unavailable / blocked / stale details、无 enabled 状态不带键、identifier 路径 `enabled`
  真假两态；既有 identifier 路径用例不改。
- VM/direct：同一 host 构造，无需新增传输用例；错误码 ratchet 零变化。
- 接入方/真机：浮层下点禁用按钮，拒绝 details 应直接给出 `enabled: false` 与空 `actions`。
- 失败注入：无新增。

## 待裁决

- 候选表是否按上表冻结，`enabled` 是否只在 `hasEnabledState` 为真时出现（推荐是，理由见非目标第二条）。

## 被否决方案

- 只给 nodeId 路径补 `enabled` 而不对齐其余键：两条路径继续各说各话，调用方仍要按路径记两套形状。
- 用 `flags` 字符串数组代替布尔 `enabled`：把调用方推回去解析 Flutter 内部 flag 名，与树输出重复。
