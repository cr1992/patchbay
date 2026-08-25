# 0.5.0 点性 semantics 派发的遮挡准入

> 状态：已接受
>
> 关联：PB-050-16
>
> 设计闸门：DG-050-09

## 问题

`PatchbaySemanticsBridge` 在派发前只检查 `node.isInvisible || node.areUserActionsBlocked`
（`packages/patchbay_flutter/lib/src/semantics/semantics_bridge.dart` 的两条 resolve 路径），随后直接
`owner.performAction(...)`。`areUserActionsBlocked` 只有 `BlockSemantics`（以及走它的 `ModalBarrier`）会置真，
因此**任何不使用 BlockSemantics 的覆盖层都不会让被盖节点失去准入**：Stack 里后画的不透明层、非模态浮层、
局部 sheet、悬浮控件、自绘遮罩都属于这一类。

结果是 `ui.semantics.tap` 会激活一个真实指针根本够不到的目标。repro 已经落在
`packages/patchbay_flutter/test/bridge/semantics_obscured_tap_bridge_test.dart`（分支
`claude/050-16-obscured-repro`，MR !124），它同时断言两件事：同一个不透明非模态 overlay 下
`tapIdentifier` 仍然 `dispatched` 且目标回调 `+1`；而同一屏幕位置的真实指针只到 overlay。这不是理论竞态，
是一次调用就能复现的穿透。

本版必须解决，是因为这条准入路径正在扩面：PB-050-10 会把同一个 `_dispatch` 通用到七项公开 action，
PB-050-15 会在旁边并列一条指针路径。先补闸再扩面，才不会把一个已知穿透复制到更多入口，也才不会让
「防误击」在两条路径上给出相反的答案。

## 目标与非目标

### 目标

- 点性 action 在派发前完成 hit-test 遮挡复核；目标被非模态层覆盖时以稳定码 fail-closed。
- 复用 gesture 家族已有的逐点判定基建（clip 包含 + `hitTestInView` + 命中链上溯），并把它整理成
  PB-050-17 可以直接复用的公共底座。
- 可达目标的 valid/rejection JSON 逐字节不变；非点性 action 行为完全不变；新增错误码为 additive。
- MR !124 的 repro 在实现 MR 内由「断言缺陷现状」翻转为「断言拒绝」。

### 非目标

- 不提供 bypass / force / `ignoreOcclusion` 参数或环境变量。确需穿透覆盖层的动作属 domain command 领域，
  不属于 UI 驱动面。
- 不为非点性 action 定义遮挡语义，也不借本条把 `longPress` 等 enum 值放进公开 descriptor allowlist。
- 不引入坐标入参，不把探针点或转换后的全局坐标写进 payload、日志与 trace（沿 DG-040-01 冻结的红线）。
- 不修改 `isInvisible` / `areUserActionsBlocked` 的既有含义，也不改写 `uiSemanticsActionBlocked` 的语义与
  details 形状。
- 不承诺 App 外部系统窗口的遮挡判定；那一面继续由 `systemUiUnexpected` 表达。
- 不改变 PB-050-07 负责的请帧策略、identifier 索引与遍历预算。

## 契约

### 「点性 action」的封闭定义

判据：**该 action 的真实用户对应物是一次落在目标边界内单点上的指针接触**，因而一个盖住该点的前景层会
吸走这次接触。三条同时成立才算点性：有指针对应物；对应物是单点而不是路径或方向；覆盖该点即改变真实
用户的可达性。

| action | 点性 | 判据说明 |
|---|:---:|---|
| `tap` | 是 | 单点 down/up |
| `longPress` | 是 | 单点 down/hold/up |
| `focus` | 否 | 无障碍焦点遍历，无指针对应物；焦点合法地移动到被覆盖或离屏节点 |
| `scrollUp` / `scrollDown` / `scrollLeft` / `scrollRight` | 否 | 对应物是拖动而非单点，部分覆盖也应可滚动 |
| `showOnScreen` | 否 | 无障碍滚入视口原语，按定义要在目标尚不可达时工作 |
| `setText` | 否 | IME/辅助输入，无位置对应物；敏感输入另有 stdin 门 |
| `dismiss` / `increase` / `decrease` / `expand` / `collapse` | 否 | 纯辅助功能语义，无单点对应物 |

以**库私有 extension getter `_isPointLike`**（实现文件内 `extension on PatchbaySemanticsAction`，下划线私有，不构成公共 API 成员）承载分类，用**穷尽 switch、无 `default` 分支**实现：
enum 新增值时编译期就必须显式分类，而不是靠后来的记忆。另加一条封闭集合测试，断言点性集合恰为
`{tap, longPress}`（与 PB-050-23 的封闭注册表同一风格）。

0.5.0 的公开 descriptor allowlist 是 `tap`、`focus`、`scrollUp`、`scrollDown`、`scrollLeft`、`scrollRight`、
`setText` 七项，因此本版**唯一公开可达的点性 action 是 `tap`**。`longPress` 现在就完成分类，只是为了它将来
进 allowlist 时按构造继承本闸，本条不扩张 allowlist。

### 稳定拒绝码

新增 `uiSemanticsTargetObscured`，与 gesture 家族的 `uiGestureTargetObscured` 对称命名、对称语义，前缀继续
落在 `uiSemantics*` 命名空间内。details 固定为：

| 字段 | 出现条件 |
|---|---|
| `reason` | 必有，取 `hitTestOrClip`、`emptyBounds`、`viewUnavailable`、`renderAnchorUnavailable` 之一 |
| `nodeId`、`generation` | 必有 |
| `identifier` | 仅 identifier 锚定入口出现，与现有 payload 的 `?identifier` 一致 |

`reason` 与 gesture 共用同一词表。details 不含坐标、rect、探针点、devicePixelRatio、viewId、label、value、
hint、tooltip 与 render 类名。

分工沿 PB-040-26 判例：**App 内可观测的遮挡报 `uiSemanticsTargetObscured`，外部 driver 观测到的系统窗口报
`systemUiUnexpected`**，两者可同时出现，轨迹里能看出先后。

CLI 侧不需要码表改动：`patchbayExitCodeFor` 按 `admission` 分类，新码落在既有 `PatchbayExitCode.rejected`。

### 遮挡判定算法

共享基元与 gesture 完全一致，实现 MR 把它从 `gesture_models.dart` / `gesture_bridge.dart` 抽成两族共用的
内部判定：由 semantics 节点向上找到匹配的 `RenderObject` 锚点，取该节点所属 `RenderView`，把局部点映射到
全局，先查 `parentPaintClip` 包含，再 `GestureBinding.hitTestInView`，最后把命中链上每个条目沿 `parent`
上溯，看是否到达锚点。

与 gesture 逐点管线的两处差异必须写死：

**差异一：探针点由 App 决定，判定是「固定采样准入」。** gesture 探的是调用方给出的每一个点，要求**全部**通过；
semantics 没有坐标入参（也不打算有），因此探针点是内部固定集合，按目标 rect 归一化取
`(0.5,0.5)`、`(0.25,0.25)`、`(0.75,0.25)`、`(0.25,0.75)`、`(0.75,0.75)` 五点，**任一点通过即通过，五点全被挡
才拒绝**。必须诚实命名：这是**固定采样**，不是可达性证明——目标只在五个采样点之外露出窄缝时，采样会
全部被挡而误拒（fail-closed，与本闸方向一致）。文档与 help 只承诺「固定采样全部被挡即拒绝」，不得声称
本闸精确回答「用户能否触达」。裁决冻结的场景是「被覆盖」，固定采样把全覆盖判死、把大面积露出放行，
并把无 bypass 情况下的误拒面压在已声明的采样边界内。

**差异二：判定结果是三态而不是布尔。** 对每个探针点得出：

- `reachable`——命中链中存在条目可上溯到锚点。与 gesture 的通过条件相同。
- `noPointerFootprint`——锚点不在命中链中，且链中**最前**一条是锚点的祖先。目标本身没有指针占位，但也
  没有任何外来层挡在前面。
- `obstructed`——锚点不在命中链中，且最前一条既不是锚点也不是锚点的祖先（即外来子树），或该点落在
  `parentPaintClip` 之外。

`reachable` 与 `noPointerFootprint` 都算通过。**`noPointerFootprint` 这一态不可省**：`Semantics(onTap:)`
包一个不参与命中测试的子树（`SizedBox`、纯 `CustomPaint`、离屏文本）是完全合法的无障碍写法，仓内现有绿灯用例
就是 `Semantics(onTap:) > SizedBox`。照搬 gesture 的布尔规则（「最顶命中必须落在目标子树内」）会把这些目标
全判成遮挡，直接违反「可达目标行为不变」。`RenderView.hitTest` 恒把自己追加到链尾，所以「没有覆盖层且
目标没有占位」的命中链最前一条必然是锚点的祖先——这正是把两种情形区分开的锚。

rect 为空或非有限时按 `emptyBounds` 拒绝；找不到 `RenderView` 或渲染锚点时分别按 `viewUnavailable` /
`renderAnchorUnavailable` 拒绝——三者都是 fail-closed，与 gesture 现有行为同形。

**已知的保守边界**：无指针占位的目标叠在一个无关不透明兄弟**之上**时（目标在前、兄弟在后），命中链最前
一条是那个兄弟，本算法会判 `obstructed`，属于误拒。本稿选择接受这一代价而不引入绘制顺序比较：绘制顺序
只能靠 `visitChildren` 次序推断，推断错误会让闸变成放行，方向上比误拒更糟。实现 MR 必须按 DG-040-01 的
举证纪律提交可行性证据（example 与现有测试全绿、没有真实用例落进这一格）；如果真实用例存在，回到本
Proposal 改判定，**不以放宽遮挡语义换取合入**。

### 与相邻条目的接缝

- 闸放在 `_dispatch` 内、按 `action._isPointLike` 分支，因此 `invoke`（nodeId）、`tapIdentifier` 与
  PB-050-10 的 `invokeIdentifier` 三条入口按构造同时继承，不逐命令重写，也不会出现某条入口漏挂。
- PB-050-10 的 [identifier action Proposal](semantics-identifier-action.md) 冻结了一条七步状态序列与一份稳定
  code 列表；本闸在点性 action 上给它加一步（第 6 步之后、派发之前），并在 `action: tap` 时给它加
  `uiSemanticsTargetObscured` 一项。两份文档由**后合入的一方在自己的 MR 内同步**，不得由实现 MR 静默改写
  另一份已接受结论。两者的合入顺序都可行（接缝就是 `_dispatch`），但不并行改同一函数：先合者先，后者显式
  rebase。
- PB-050-15 的指针路径继续走 gesture 家族的逐点管线与 `uiGestureTargetObscured`，不改用本码；两条路径的选择
  指引由 DG-050-08 负责。
- PB-050-17 复用同一判定基元与三态结果，成功判据是 `reachable` 或 `noPointerFootprint`。reveal 依赖的
  `showOnScreen` 与 `scroll*` 都被判为非点性，因此不会被本闸挡住——否则 reveal 会在「要滚动才能露出目标、
  但滚动容器自己被部分覆盖」时自锁。

## 状态、失败与预算

### 在既有准入序列中的插入位置

`_dispatch` 现有顺序是：policy 存在性 → 基础 gate → lifecycle → 第一次 resolve（含 invisible/blocked/action
可用性）→ policy 决策 → setText/敏感输入检查 → 声明 gate（await）→ lifecycle → 第二次 resolve → 第二次
policy 与漂移核对 → 敏感输入复核 → `performAction`。

**遮挡复核插在敏感输入复核之后、`performAction` 之前，并且全程只有这一处。** 论证：

1. **权威性**：声明 gate 的 await 可能等待人工确认，恰恰是覆盖层出现的窗口。门前的判定不权威，门后的判定
   不可省；既然门后必须查，门前那一次就只是重复。
2. **不抢 consumer 的权威**：policy 拒绝与 gate 拒绝保持在前，consumer 自己写下的决定仍然先生效，它们的
   既有 rejection 字节因此完全不受影响。
3. **早失败没有预算收益**：一次复核最多五次 hit-test，命中链长度是渲染树深度量级，不请帧、不遍历语义树。
   没有值得为之增加一个判定点的成本。
4. **早拒可能更差**：受理瞬间被盖、gate 期间散开的目标会被无谓拒绝，而本闸没有 bypass 可救。晚查天然吃到
   这段时间的好转。

### TOCTOU

- **复核与 `performAction` 之间不得存在任何 await/yield**：两者必须在同一微任务内，使用同一次 resolve 得到的
  `owner`/`nodeId`/锚点。复核结论只对这一次派发有效，不缓存、不跨调用复用。
- **gate await 期间遮挡状态变化一律以门后这一次为准**：之前可达、之后被盖 → 拒绝；之前被盖、之后可达 →
  放行。不引入「曾经被盖」这种记忆状态，也不因此制造第三个漂移码。
- **遮挡不是换代**：覆盖层出现不改变目标的 generation，不得用 `uiSemanticsGenerationStale` 表达遮挡，也不得
  因遮挡触发重解析、等待或重试——写操作不重放，这条与 PB-050-10 的立场一致。
- **诚实边界**：本闸证明的是派发瞬间目标未被 App 内可观测的层覆盖，不保证同帧稍后不会弹出浮层。
  `dispatched` 的含义不变，仍然只是「Flutter SemanticsOwner 收到了这次派发」，不升级为业务已确认。

### 预算

每次点性派发最多 5 次 `hitTestInView`；不新增帧、不新增语义树遍历、不新增 timer 或独立 deadline。非点性
action 的开销为零（分支不进入）。若 PB-050-07 统一 identifier 遍历/请帧预算，本闸不在其预算范围内，两者
不互为前置。

## 兼容与降级

- 这是**收紧方向的行为变更**，影响面严格限于「点性 action + 目标所有探针点都被非模态层挡住」这一格。
  其余全部路径逐字节不变。
- **老 CLI + 新 host**：新码是普通 rejection 字符串，`patchbayExitCodeFor` 按 `admission` 分类到既有
  `rejected`；老 reader 不把 code 解成枚举，不会 `FormatException`。
- **新 CLI + 老 host**：老 host 没有本闸，新 CLI **不做客户端遮挡判定、不伪造拒绝**，也不降级成先读树再判断。
- **descriptor / catalog**：不改参数、enum、必填性、strictKeys 与 CLI 语法；`covers: [commands]` 与 catalog
  digest 不变。
- **VM Service ↔ direct**：闸在 Flutter 桥内，两条传输共享同一实现，跑同一份矩阵；transport 不实现判定。
- **非点性 action** 与 `uiSemanticsActionBlocked`、`isInvisible`、`areUserActionsBlocked` 的含义均不变；
  `BlockSemantics` 场景继续报 `uiSemanticsActionBlocked`，不改判成新码。
- **构建模式**：渲染锚点解析依赖 `debugSemantics`（`kReleaseMode` 下为 null），与 gesture 现有实现同源；
  debug 与 profile 行为一致，release 由既有编译期裁除边界控制，不新增暴露面。

### 实施顺序与回退

1. 前置：MR !124 的 repro 先合，保持红/断言现状。
2. 实现 MR 内顺序：抽出两族共用的判定基元 → 加 `_isPointLike` 分类与封闭集合测试 → 在 `_dispatch` 接闸 →
   翻转 repro 断言并补齐遮挡矩阵。抽基元时不得改动 gesture 现有拒绝语义与 `uiGestureTargetObscured` 的
   details 形状，`gesture_visibility_spike_test.dart` 必须原样全绿。
3. 若 PB-050-23 的封闭错误码注册表先合，`uiSemanticsTargetObscured` 必须先进注册表再合闸。
4. **回退**：回退准入闸 = 移除 `_dispatch` 的点性分支与新码，`ui.semantics.*` 回到 0.4.1 行为；
   **repro 测试保留并标注 skip 理由，不得连同证据一起回退**（版本计划回退边界）。若 PB-050-17 已经依赖共享
   基元，回退闸不回退基元。

## 安全与隐私

- 拒绝 details 不含全局坐标、rect、探针点、devicePixelRatio 与 viewId：DG-040-01 已冻结「转换后的全局坐标是
  一次调用内的瞬时实现细节，不进 payload、日志与 trace」，本闸是 semantics 侧第一次引入全局坐标计算，必须
  同样守住。
- 不回显 label、value、hint、tooltip 与 render 类名；`nodeId`、`generation`、`identifier` 是既有公开身份域。
- 闸只收紧不放宽：不提供 bypass、force、`ignoreOcclusion` 参数或环境变量；穿透覆盖层的合法业务需求走
  domain command，由接入方自己的 policy 与 gate 负责。
- `_isPointLike` 与判定基元都是包内实现，不进公共 API golden，不改变 PB-050-13 的公共面清单。
- 拒绝本身不泄露超出调用方已知信息的内容：identifier 由调用方给出，遮挡结论不附带覆盖层的业务标识。

## 验证

- **单元/协议测试**：`_isPointLike` 穷尽分类与封闭集合断言；`uiSemanticsTargetObscured` 的 details
  presence/absence golden（四种 `reason` 各一条）；断言 payload、日志与 trace 中不出现坐标/rect 字段。
- **repro 翻转**：MR !124 的 (a) 组由 `dispatched` + `taps == 1` 翻成 `rejected` +
  `uiSemanticsTargetObscured` + `taps == 0`；(b) 组的真实指针断言保持不变。
- **遮挡矩阵**：全覆盖不透明非模态 overlay（拒）；部分覆盖且至少一个象限探针可达（放行）；覆盖层为
  `IgnorePointer`（放行）；覆盖层为 `HitTestBehavior.translucent` 且目标仍在命中链中（放行）；`CustomPaint`
  目标（放行）；无占位的 `Semantics(onTap:) > SizedBox` 且无覆盖（放行，现有绿灯用例不动）；探针点落在祖先
  `parentPaintClip` 之外（拒）；空/非有限 rect（`emptyBounds`）；`BlockSemantics` 仍报
  `uiSemanticsActionBlocked`。
- **序列与竞态**：gate await 期间盖上 → 拒；gate await 期间撤走 → 放行；policy deny + 被盖 → 仍
  `uiSemanticsActionDenied`；policy 漂移 + 被盖 → 仍 `uiSemanticsPolicyChanged`；断言复核与 `performAction`
  之间没有 await（以「盖上动作只能发生在复核之前」的时序用例证明）。
- **非点性不变**：`focus`、四个 `scroll*`、`setText` 在同一被盖 fixture 上的 valid/rejection JSON 与现状逐字节
  对拍。
- **三入口一致**：nodeId `invoke`、`tapIdentifier`、PB-050-10 的 `invokeIdentifier` 在同一 fixture 上给出同一
  code 与同一 details 形状。
- **gesture 回归**：`gesture_visibility_spike_test.dart` 原样全绿，`uiGestureTargetObscured` 的语义、reason
  词表与 details 形状不变。
- **VM/direct**：两端跑同一矩阵。
- **失败注入**：`RenderView` 缺失、渲染锚点解析失败、rect 退化为空——三者都必须落在 fail-closed 一侧。
- **example 预检**：debug 主链覆盖一次被非模态浮层盖住的 tap 拒绝，以及浮层撤走后同一 identifier 成功；
  profile smoke 只验答复形态。
- **接入方真机**：至少一次真实非模态浮层下的拒绝证据，以及一次常规回归证明没有误拒既有可达目标。

## 待裁决

- details 是否附带 `occluderIdentifier`（仅当覆盖层最近的语义节点声明了 identifier 时出现）？本稿建议附带：
  与现有 `mountedIdentifiers` 的隐私尺度一致，且能直接回答「谁盖住了我」；presence 与 absence 两个分支都上
  golden。
- 探针点集是五点 ANY-pass，还是只探几何中心？本稿建议五点 ANY-pass，理由见判定算法一节；只探中心会把
  「中心被一个悬浮控件压住、其余大片露着」判死。
- 「无占位目标叠在无关不透明兄弟之上」这一保守误拒是否接受？本稿建议接受，并以实现 MR 的可行性证据兜底；
  若真实用例存在，回到本 Proposal 引入绘制顺序比较，不放宽语义换合入。
- `longPress` 是否借本条进入公开 descriptor allowlist？本稿建议否，只做分类不扩面。

### 裁决结论（2026-08-25，仓主授权代理裁决，记录于范围扩充流程）

- `details` **不附带 `occluderIdentifier`**（2026-08-25 仓主复核改判，推翻此前代理裁决）：稳定错误面不
  顺带泄露另一节点身份，以正文 details 表与安全章节的口径为准；「谁盖住了我」由调用方用 capture 或
  semantics tree 另行诊断。
- 探针点集 **五点固定采样、任一命中即通过**（仓主复核补充定性）：只探中心会误杀部分遮挡；同时明确本闸
  是固定采样准入而非可达性证明，窄缝露出的误拒作为 fail-closed 代价写入文档。
- 「无占位目标叠在无关不透明兄弟之上」的保守误拒 **接受**：fail-closed 优先，实现 MR 负举证义务；
  真实用例出现时回本 Proposal 引入绘制顺序比较，不放宽语义换合入。
- `longPress` **不借本条进入公开 allowlist**：只做分类不扩面，扩 allowlist 是独立条目。

## 被否决方案

- **继续只用 `areUserActionsBlocked`**：它只有 `BlockSemantics` 会置真，正是缺陷本身。
- **复用 `uiGestureTargetObscured`**：跨命令族串码，会让诊断和封闭错误码注册表的分工失效，也与
  「错误码 additive」的裁决不符。
- **把遮挡并进 `uiSemanticsActionBlocked`**：「语义被屏蔽」与「视觉被覆盖」补救方式不同（一个改
  `BlockSemantics`/`ModalBarrier`，一个改层级），合并成一个码会让接入方无法定位，且不是 additive。
- **给所有 action 加闸**：`showOnScreen` 与 `scroll*` 恰恰是 PB-050-17 用来把被覆盖目标露出来的原语，加闸会
  让 reveal 自锁；`focus` 与 `setText` 没有单点对应物，遮挡语义不成立。
- **提供 bypass / force 参数**：与 DG-050-09 直接冲突；一旦存在，防误击就只剩字面。
- **只做几何包含判断（rect 相交）**：判不出 `IgnorePointer`、`translucent` 与自绘层，误拒与误放两头都占。
- **照搬 gesture 的布尔规则**：会把仓内全部无指针占位的合法目标判成遮挡，直接违反「可达目标行为不变」。
- **把闸放在第一次 resolve 之后**：gate await 期间才出现的覆盖层照样穿透，等于没修。
- **遮挡时自动等待覆盖层消失或重试**：写操作不重放，且会引入不可预算的等待与新的竞态。
