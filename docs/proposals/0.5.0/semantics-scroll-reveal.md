# 0.5.0 identifier 锚定的 scroll-to-reveal

> 状态：提案中
>
> 关联：PB-050-17
>
> 设计闸门：DG-050-10

## 问题

懒加载列表里的目标在滚到之前根本不在 Semantics 树上。`ui.wait --condition semanticsMounted` 只会等到
超时——它是只读命令，不会让列表动；`ui.semantics.action --action scrollDown` 能滚一步，但调用方必须自己
写「滚一步—重读树—再判断」的循环，而这个循环的每一次重读都在 CLI 侧，拿不到 App 内的代际围栏，也没有
任何终止判据可依据。结果是长列表页面的 example 预检只覆盖首屏，剩下的部分被当成"已覆盖"，这是假覆盖。

本条目要补的就是这一段：把「把目标滚到可操作」变成 App 内一次受理内完成、有界、可如实拒绝的写操作。

## 目标与非目标

### 目标

- 以稳定 Semantics identifier 锚定目标，在一次 App 受理内把它驱动到 **hit-test 可达**，并返回可直接
  用作后续写命令围栏的 `generation`。
- 覆盖目标当前**未挂载**的懒加载场景：这是本命令存在的理由，不是边角情况。
- 步数与 deadline 双重有界；超限、滚到底、被固定层覆盖都以类型化事实如实报告，不伪造成功。
- 实现留在 Semantics 域：优先 `SemanticsAction.showOnScreen`，步进用既有 scroll action。

### 非目标

- 不合成指针滚动。`ui.gesture.*` 是另一条注入通道，两族命令的证据强度不同（见
  [锚定式手势](../0.4.0/anchored-gestures.md)）。
- 不引入 Element 全树打分启发式，也不按 label、树顺序或"看起来像列表"猜目标或猜容器。
- **不引入任何坐标入参**。offset、像素步长、`scrollToOffset` 都不进契约；这是
  [design.md 非目标（红线）](../../design.md#非目标红线)在本条目的落点。
- 不自己实现遮挡判定算法；成功判据复用 DG-050-09 的判定基建。
- 不做失败回滚。滚动已经发生就如实留在那里，不再派发一串"恢复原位"的写操作。
- 不改变 `ui.wait`、`ui.semantics.*`、`ui.gesture.*` 已有的 wire、CLI 与失败码。

## reveal 是什么，不是什么：三条必须先冻结的框架事实

以下三条来自 Flutter 3.44.9 框架源码（0.5.0 的当前 CI 版本），它们决定了 reveal 不能被写成"多派发几次
既有 action"。

**一、`showOnScreen` 在 `SemanticsData.hasAction` 上恒为假，但 `performAction` 一定能走通。**
框架没有任何 widget 设置 `SemanticsConfiguration.onShowOnScreen`；真正生效的是
`SemanticsOwner.performAction`（`flutter/lib/src/semantics/semantics.dart`）里的兜底分支——找不到
handler 时调用节点自带的 `_showOnScreen`，而每个语义节点在
`flutter/lib/src/rendering/object.dart` 的 `_createSemanticsNode` 里都被构造为
`SemanticsNode(showOnScreen: renderObject.showOnScreen)`，该回调沿 RenderObject 父链冒泡到视口。

推论：既有 `_resolveIdentifier` 的 `!data.hasAction(...)` → `uiSemanticsActionUnavailable` 前置检查
**对 showOnScreen 一律误拒**，快照的 `actions` 数组里也永远不会出现它。所以 reveal 不能实现成
`ui.semantics.actionByIdentifier --action showOnScreen`（PB-050-10 的 allowlist 与可执行性检查都挡它），
必须是独立命令，并且必须**用重新观察而不是派发返回来判定成功**。

**二、`showOnScreen` 会静默 no-op。** `RenderViewportBase.showOnScreen`
（`flutter/lib/src/rendering/viewport.dart`）在 `!offset.allowImplicitScrolling` 时直接冒泡给父级、
不动 offset；目标未挂载时更是连节点都没有。派发不抛错、不返回值，唯一可观测的差别是容器
`scrollPosition` 没变。这正是"不伪造成功"必须落到观察上的原因。

**三、容器暴露的 scroll action 集合本身就是边界信号。**
`flutter/lib/src/widgets/scroll_position.dart` 的 `_updateSemanticActions` 按
`pixels > minScrollExtent` / `pixels < maxScrollExtent` 决定暴露 backward / forward 哪一个，并按
`axisDirection` 映射到 `scrollUp|Down|Left|Right`。所以"到底了"不需要比较像素，只需要看那个 action
是否还在容器节点上——reverse 列表与横向列表因此自动正确。步长同样不归我们管：语义滚动一步是
`RenderSemanticsGestureHandler` 的 `scrollFactor`（默认 `0.8`，见
`flutter/lib/src/rendering/proxy_box.dart`）乘视口尺寸。**reveal 只控制步数，不控制步长。**

## 契约

### 命令形状：独立顶层命令 `ui.reveal`

不进 `ui.gesture.*`：那族的性质已被冻结为"合成指针事件序列"，把一个 Semantics 通道的命令放进去，会让
同一个命令族名同时指两种注入通道，证据强度不再能从命令名读出来。

不进 `ui.semantics.*`：那族命令的形状是"派发一个 allowlist 内的 action，返回 dispatched"，而 reveal 是
"有界循环 + 可达性验收"；上一节的事实一使它无法复用那族的可执行性前置检查，事实二使它无法把
`dispatched` 当结果。

不是 `ui.wait` 的一个 condition：`ui.wait` 是 `readOnly` / `effect: none`，reveal 是写操作。把写塞进 wait
会让一条已经被接入方当只读用的命令突然产生副作用。

命令名与 CLI 路径与 [0.5.0 版本计划](../../releases/0.5.0.md) P1 能力批表冻结的字面一致：

```console
$ patchbay ui reveal <identifier>
$ patchbay ui reveal <identifier> --container <identifier> --direction forward
$ patchbay ui reveal <identifier> --max-steps 12 --timeout-ms 8000
```

service command `ui.reveal`，`plane: flutterUi`，`mode: immediate`，`sideEffect: appState`，
`factSources: {uiObserved}`。descriptor 必须 `strictKeys: true`，允许的 key 只有下表五个；额外 key 在进入
bridge 与 policy 之前按既有 unknown-field 形状拒绝。

| 参数 | 类型 | 必填 | 默认 | 约束 |
|---|---|---|---|---|
| `identifier` | string | 是 | — | 非空，Semantics identifier 命名空间 |
| `container` | string | 否 | — | 非空；滚动容器的锚定 identifier，见下节 |
| `direction` | enum | 否 | `both` | `forward` / `backward` / `both`，**内容序**不是屏幕方向 |
| `maxSteps` | integer | 否 | `40` | `1..200`；200 是协议硬上限，接入方只能收紧 |
| `timeoutMs` | integer | 否 | `5000` | 正整数，上限沿用 `patchbaySnapshotWaitCeiling`（2 分钟） |

`direction` 用内容序而非 `up/down`：`forward` = 朝 `maxScrollExtent`，`backward` = 朝 `minScrollExtent`。
具体落到哪个 `SemanticsAction` 由容器当前暴露的 action 与观察到的 `scrollPosition` 位移符号确定
（见「步进循环」），不由参数字面指定——否则 reverse 列表和横向列表就要求调用方先知道布局方向。

**不接受调用方 generation。** reveal 要找的目标常常尚未挂载，一个"你先前看到的代际"在这里没有意义。
围栏出现在输出端：成功 payload 返回的 `generation` 就是调用方紧接着做 `ui tap` / `ui text set` 时该带的
那一个。

### 执行 payload

reveal 只有 `revealed` 与 `failed` 两种受理后形状，不合并字段：

| 字段 | `outcome: revealed` | `outcome: failed` |
|---|---|---|
| `outcome`、`source`、`identifier`、`steps`、`elapsedMs` | 必有 | 必有 |
| `containerNodeId`、`containerGeneration` | 必有 | 必有 |
| `nodeId`、`generation` | 必有 | 仅当目标已挂载时必有，未挂载时不得出现 |
| `direction`、`reversed` | 必有 | 必有 |
| `extentGrowthSteps` | 必有（观察到 `scrollExtentMax` 增长的步数） | 必有 |
| `usedShowOnScreen`、`showOnScreenNoop` | 必有 | 必有 |
| `beforeTreeRevision`、`afterTreeRevision` | 必有 | 必有 |
| `reason` | 不得出现 | 必有，取值见失败表 |
| `failureType` | 不得出现 | 仅 `reason: scrollActionFailed` 时必有，只写 `runtimeType` |

沿用 `outcome: 'failed'` 而不是发明第三个值，是因为已发布 CLI 的
`patchbayExitCodeFor` 已经把它映射为 `typedFailure`（`packages/patchbay_cli/lib/src/result.dart`）：老
客户端读到失败的 reveal 就已经拿到非零退出码，`reason` 只是松读面上多出来的一条事实。

payload 里出现的 `scrollPosition` 类观察值（如失败详情中的容器位置）来自既有只读快照字段，**不是输入**。
reveal 没有任何位置入参，这条区分就是坐标红线在本命令上的边界。

## 滚动容器的选择

容器不是"扫全树找最像的那个"。它按下面的顺序确定，每一步都要么唯一，要么拒绝：

1. **给了 `container`**：按 identifier 唯一解析该锚点节点（未找到 / 歧义复用既有
   `uiSemanticsIdentifierNotFound`、`uiSemanticsIdentifierAmbiguous`，details 带 `role: "container"`）。
   锚点通常包在 `Scrollable` 外层（例如 example 的 `Semantics(identifier: ..., child: ListView...)`），
   所以从锚点子树内取**唯一**的滚动节点；子树内 0 个 → `uiRevealNoScrollableContainer`，多于 1 个 →
   `uiRevealContainerAmbiguous`。
2. **没给 `container` 且目标已挂载**：取目标语义祖先链上的全部滚动节点，**由内向外**排成容器栈。
   链上 0 个滚动节点且目标已可达 → 直接成功返回 `steps: 0`；不可达 → `uiRevealNoScrollableContainer`。
3. **没给 `container` 且目标未挂载**：没有祖先链可用。此时全树只有一个滚动节点就用它；0 个 →
   `uiRevealNoScrollableContainer`，多于 1 个 → `uiRevealContainerAmbiguous`，notice 指引调用方补
   `--container`。**不按尺寸、深度、可滚动距离打分挑一个**——那正是红线要挡的猜测。

"滚动节点"的判据是既有快照字段而非新概念：`SemanticsData.scrollPosition != null`（Flutter 只在
`position.haveDimensions` 时写这三个字段，见 `_RenderScrollSemantics.describeSemanticsConfiguration`）。
容器节点的 `hasImplicitScrolling` flag 同源于 physics 的 `allowImplicitScrolling`，为假即事实二成立，
**直接跳过 showOnScreen 进入步进**，这是读到的确定事实，不是猜测。

嵌套只在情形 2 有栈：先推最内层，该层判定耗尽后换下一层，每换一层都要复核该容器仍在准入时的授权集合内
（见下节）。情形 1 与 3 只有一个容器，不做由内向外——这也是嵌套懒加载场景必须显式给 `container` 的原因。

## 步进循环与终止条件

单一 deadline 从受理起算。每一步之后的等待复用 `PatchbayFrameObserver.nextFrameBefore(deadline)`——与
`ui.wait` 同款帧驱动纪律，**不引入固定墙钟 sleep**，deadline 到即停并如实报已发生的步数。

```text
0. 解析目标 → 已挂载且可达 ⇒ revealed(steps: 0)
1. 已挂载但不可达 且 容器 hasImplicitScrolling ⇒ 派发一次 showOnScreen，等一帧，回 0
   （每次调用最多 2 次；位移为 0 记 showOnScreenNoop=true，不重试）
2. 派发容器当前暴露的方向 action，等一帧，重解析目标与容器
3. 判定本步：
   scrollPosition 变化            ⇒ 有效步，stall 归零
   位置没变但 scrollExtentMax 增长 ⇒ 有效步，stall 归零  ← 懒加载补步判据（DG-050-10）
   两者都没变 或 该方向 action 已从容器上消失 ⇒ stall += 1
4. stall 达到 2 ⇒ 该方向耗尽：direction=both 且未反向过则反向继续，否则终止
5. 目标从未挂载变为挂载 ⇒ 回 1（showOnScreen 配额未用尽时）
6. steps 达到 maxSteps 或 deadline 到 ⇒ 终止
```

`scrollExtentMax` 增长是"内容刚补进来"的直接证据，因此它把 stall 计数清零而**不是**追加步数预算：
`maxSteps` 是任何情况下都不被突破的唯一硬上限，懒加载再多页也不会把一次调用变成无界循环。

### 终止条件矩阵

| 情形 | 判定 | 结果 |
|---|---|---|
| 目标唯一挂载 + 可达 | DG-050-09 基建判定可达 | `revealed` |
| 目标挂载 + 被滚动裁剪 / `isInvisible` / hidden | 不是遮挡，是还没滚到 | 继续步进 |
| 目标挂载 + 几何入视口 + 被固定层覆盖 | 有界继续滚动最多 4 步，其间任一步可达即成功 | 4 步后仍不可达 ⇒ `failed / targetObscured` |
| 目标挂载 + 被模态层覆盖 | 继续滚动不可能解决 | `failed / targetObscured`，不消耗剩余步数 |
| 两个方向均耗尽，目标仍未挂载或不可达 | 滚到底也没有 | `failed / scrollExhausted` |
| `steps == maxSteps` | 预算用完，可能还有 | `failed / stepBudgetExceeded` |
| deadline 到 | 同上但因时间 | `failed / timeout` |
| 循环中 identifier 出现多个挂载实例 | 分页可能渲染出重复项 | `failed / targetAmbiguous` |
| 容器节点换代 | 推的已不是被授权的那块区域 | `failed / containerChanged` |
| 步内 App 离开 resumed | | `failed / lifecycleNotResumed` |

`scrollExhausted` 与 `stepBudgetExceeded` 必须是两个事实：一个说"这个列表里没有它"，另一个说
"我没看完"。把两者合成一个码，等于让调用方无法判断该不该加预算重试。

## 门、授权与 TOCTOU

reveal 是写操作，过基础门 + 声明门（DG-050-10）。声明门的来源必须解决一个具体问题：**reveal 的核心
场景里目标根本不存在，所以 policy 不可能问在目标上。** 唯一存在的、也是真正被移动的东西是容器。

因此授权模型是：**把本次调用要行使的权限如实表述为"滚动这些容器"**。准入时对容器栈里每一个容器，
以该容器当前暴露的具体 scroll action 走一次既有 `PatchbaySemanticsActionPolicy`；任一容器被拒即整条命令
拒绝，全部 `gateIds` 的并集构成声明门，`_gates.evaluate(union)` 求值一次。

这样做的三个后果都是要的：

- 不把 `showOnScreen` 当成一个新 action 值喂给老接入方 policy 的 default 分支——升级 package 不会让 App
  突然多出一种被驱动的方式（与 anchored-gestures 拒绝"往既有 action 枚举加手势值"同一条理由）；
- 今天已经拒绝 scroll action 的接入方，明天自动继续拒绝 reveal，**reveal 不扩权**：它做的每一件事都是
  接入方已经可以通过 `ui.semantics.action` 授权或拒绝的那件事；
- 目标本身不会被激活，所以不需要目标侧授权；把 policy 问在目标上反而会引入"能 tap 才能 reveal"这种
  无关耦合。

与 `_dispatch` 同构的 TOCTOU 纪律，扩展到循环里：

- 容器 generation 在准入时 pin；**每一步之后按同一锚点重解析容器并核对 pin**，换代即停
  （`containerChanged`）。容器换掉意味着这已经不是被授权的那块可滚动区域。
- **每一步之后重跑 policy 并比对 `gateIds` 集合**；漂移即停（准入前用既有 `uiSemanticsPolicyChanged`，
  准入后用 `reason: policyChanged`）。
- **声明门只在准入时求值一次，不每步重求**：门可能是异步且昂贵的，每步重求会把一个有界循环变成不可
  预算的东西；"门集合变了就停"已经覆盖了授权前提改变的情况。
- 每一步重查 `_isAppResumed()`；App 离开 resumed 立即停。
- 目标 identifier 每一步重解析，不缓存 nodeId：懒加载列表回收 node 是常态。

**受理边界是第一次派发。** 第一次 showOnScreen / scroll action 派发之前的任何失败都是
`admission: rejected`；之后的失败进入受理 payload（`outcome: 'failed'` + `reason`），不改写成未受理——
滚动已经发生，把它报成"没受理"就是对副作用撒谎。同一个条件（policy 漂移、容器换代、lifecycle）因此
可能出现在两边，分界线只有这一条。

## 状态、失败与预算

准入前稳定拒绝码，除新增两个外全部复用既有码：

| code | 触发 | 新增 |
|---|---|---|
| `invalidUiArguments` | identifier/container 为空，`maxSteps`/`timeoutMs` 越界，`direction` 非法 | 否 |
| `uiSemanticsActionsDisabled` | 接入方未提供 action policy | 否 |
| `uiLifecycleNotResumed` | 受理时 App 不在 resumed | 否 |
| `uiSemanticsUnavailable` | 拿不到 owner / root | 否 |
| `uiSemanticsIdentifierNotFound` | 显式 `container` 未挂载（details 带 `role`） | 否 |
| `uiSemanticsIdentifierAmbiguous` | 显式 `container` 歧义 | 否 |
| `uiSemanticsActionDenied` | policy 拒绝容器 scroll | 否 |
| `uiSemanticsPolicyChanged` | 门后二次复核时 gateIds 漂移 | 否 |
| 各 gate code | 基础门 / 声明门拒绝，形状沿用 `_gateRejected` | 否 |
| `uiRevealNoScrollableContainer` | 锚点/祖先链/全树内没有滚动节点，且目标不可达 | **是** |
| `uiRevealContainerAmbiguous` | 候选滚动容器多于一个且未给 `container` | **是** |

受理后 `reason` 取值封闭：`stepBudgetExceeded`、`scrollExhausted`、`targetObscured`、`targetAmbiguous`、
`containerChanged`、`policyChanged`、`lifecycleNotResumed`、`timeout`、`scrollActionFailed`。按 PB-050-23
的口径，这两组字面量都必须进封闭注册表。

预算与不可参数化常量（全部在失败 details 里如实回报，调用方才知道自己撞的是哪一条）：
`maxSteps`（参数，硬上限 200）、`stallSteps = 2`、`maxShowOnScreenAttempts = 2`、`obscuredSteps = 4`、
`timeoutMs`（参数，上限 2 分钟）。一次调用的 policy 调用次数上界为 `容器数 × (2 + maxSteps)`，
identifier 解析次数上界为 `2 + maxSteps`；两者都是纯内存操作，不涉及额外请帧以外的等待。

reveal 成功只证明 **Patchbay 观察到该目标此刻 hit-test 可达**。它不证明业务状态、不证明目标已完全入
视口的某个几何位置，也不承诺下一帧仍然可达——那是返回的 `generation` 要解决的问题。

## 与遮挡判定基建的接口期望（DG-050-09）

成功判据复用 PB-050-16 的判定基建（[遮挡准入 Proposal](semantics-occlusion-admission.md)），reveal 不
重复设计它。reveal 对该基建有一条**硬性**要求，写在这里以免被当成实现细节漏掉：

> 判定结果必须能区分「被滚动裁剪 / 尚未进入视口」与「被固定层或模态层覆盖」。

只给一个布尔值不够：前者是"继续滚"的信号，后者是"有界重试后拒绝"的信号，合成一个值会让 reveal 的这
一步退化成猜测，而"继续滚还是拒绝"正是 DG-050-10 点名要回答的问题。除此之外 reveal 只需要基建给出
「对该已挂载节点做点性派发是否会落到其子树内」这一个判定，遮挡算法、误拒边界与拒绝码归 PB-050-16。

## 兼容与降级

- **老 CLI + 新 host**：catalog 只多一条命令；`catalogDigest` 因 `commands` 集变化而变化，
  `covers: [commands]` 不变。不新增任何 wire 类型字段，尤其不动 `PatchbayUiTargetDescriptorWire`——
  已发布客户端严格解码它，加字段即当场 `FormatException`。新命令的请求/响应类型是全新类型，不在
  `strictlyDecodedByShippedClients` 名单内。
- **新 CLI + 老 host**：catalog 无 `ui.reveal` 时类型化报告 command unavailable，**不降级**为客户端侧
  "读树—滚一步—再读树"循环：那个循环没有 App 内代际围栏，正是本条目要消灭的东西。
- **VM Service ↔ direct**：共享同一 decoder、registration 与 Flutter 桥；transport 两侧都不实现容器选择、
  步进或终止判定。
- 命令只在接入方提供了 semantics action policy 时进目录，与 `uiSemanticsActionsDisabled` 同构。
- `ui.wait`、`ui.semantics.*`、`ui.gesture.*` 的 wire、CLI 与失败码逐字节不变。

### 与 ui.wait 的组合语义

- reveal **不内嵌** wait condition，也不接受 `condition` 参数：它只有一个成功判据。
- `ui reveal X` 之后**不需要**再 `ui wait semantics-mounted X`：挂载与可达在同一次受理内完成，且
  `semanticsMounted` 的判据（`matches.isNotEmpty && !invisible`）比 hit-test 可达弱，两者不能互相代替。
  help 必须写清这条强弱关系，避免调用方用 wait 的成功替 reveal 背书。
- 典型链路是 `ui reveal X` → 拿 `generation` → `ui tap X --generation <g>`。中间的窗口由调用方用那个
  generation 兜住，reveal 不替它保留。
- reveal 的 deadline 语义与 `ui.wait` 同源：单一 deadline、帧驱动推进、超时如实回报已观察到的进度。

## 安全与隐私

- identifier 是声明式稳定身份，不以 label / value 兜底；目标与容器歧义一律 fail-closed，不按树顺序选。
- 响应、日志、audit 与 trace 不写入 label、value 或任何目标文本；容器观察值只保留数值型
  `scrollPosition` / `scrollExtent*` 与 nodeId/generation。
- 没有敏感输入面：reveal 不接受 text，也不派发 `setText`。
- release 构建的可裁除边界不因新增 public 入口而改变；未注册 host 时 reveal 与其余 UI 命令一样不可达。
- reveal 产生真实副作用（列表位置改变、懒加载触发网络请求），因此它必须留在写命令的门与审计路径上，
  不得因为"只是滚动"被降级成只读。

## 验证

- **单元/协议**：descriptor / codegen / CLI parity；`strictKeys` 对未知 key 在 bridge 与 policy 之前拒绝；
  `maxSteps` / `timeoutMs` 边界值；`direction` 非法值；`revealed` 与 `failed` 两种 payload 按字段表逐项
  断言 presence 与 absence；两组错误码字面量进封闭注册表（PB-050-23）。
- **widget 测试矩阵**：
  - 懒加载分页：`itemCount` 随滚动增长的列表，断言 `extentGrowthSteps > 0` 且 stall 被增长清零；
  - 嵌套滚动：复用 example 的 `gestureListSemanticsId` / `gestureNestedListSemanticsId`，断言由内向外的
    容器换层顺序与每层的 policy 复核；
  - `reverse: true` 与 `Axis.horizontal`：断言 `direction: forward` 落到正确的 `SemanticsAction`，且不
    依赖参数里出现任何屏幕方向词；
  - 固定 overlay（pinned header / 底栏）盖住目标：断言有界继续滚动后成功，以及始终被盖时
    `targetObscured` 而不是伪造成功；
  - 超限：`maxSteps: 1` 而目标在数屏之外 ⇒ `stepBudgetExceeded`；滚到底仍无目标 ⇒ `scrollExhausted`；
    两者的 details 可区分；
  - `NeverScrollableScrollPhysics`：`hasImplicitScrolling` 为假 ⇒ 跳过 showOnScreen；无 scroll action ⇒
    `uiRevealNoScrollableContainer`；
  - 容器歧义：两个平级 ListView 且目标未挂载 ⇒ `uiRevealContainerAmbiguous`，补 `--container` 后成功；
  - 目标一开始就可达 ⇒ `steps: 0` 且未派发任何 action；
  - 循环中目标出现两个实例 ⇒ `targetAmbiguous`。
- **竞态与失败注入**：门 await 期间容器换代（准入前拒绝）与步间容器换代（受理后 `containerChanged`）；
  步间 policy gateIds 漂移；步间 App 进入 paused；`performAction` 抛出 ⇒ `scrollActionFailed` 且只写
  `runtimeType`；deadline 恰好落在两步之间；owner 中途消失。
- **VM/direct**：同一矩阵在两条传输上跑，断言两侧 JSON 逐字节一致。
- **兼容**：复刻 0.4.1 reader 读取新 catalog 与新 payload；老 CLI 对 `outcome: 'failed'` 得到
  `typedFailure` 退出码；`ui.wait` / `ui.semantics.*` / `ui.gesture.*` 的 golden 不变。
- **example 预检（debug）**：example 需补一屏懒加载分页列表（带 identifier 的远端行）与一层固定
  overlay；`tool/example_precheck.sh` 覆盖 reveal → tap 的完整链路，`tool/example_profile_smoke.sh` 只验
  答复形态。预检不过不进业务验收。
- **接入方真机**：真实长列表的分页节奏、真实固定层与真实控制器语义只能由接入方出证据；至少覆盖一次
  "reveal 成功后立即用返回的 generation 完成写操作"。

## 实施与回退

- 落在 M7，与 PB-050-16 共享遮挡判定基建；PB-050-16 先合入。
- reveal 的循环不塞进 `PatchbaySemanticsBridge._dispatch`（结构警戒线：不新增 long-function 警戒线），
  独立成 Semantics 域内的一个可单测阶段；identifier 解析、`observe`/generation 与 owner 获取**复用**桥
  已有原语，不复制第二套解析。帧等待复用 `PatchbayFrameObserver`，由组合根注入。
- 若 PB-050-16 的判定基建未能在本版落地，**reveal 一并回退**，不以"几何入视口"临时冒充成功判据——
  那是 DG-050-10 明确禁止的伪造成功。
- reveal 独立回退：回退不触碰 `ui.semantics.*`、`ui.gesture.*` 与 `ui.wait` 的任何字节。

## 待裁决

- policy 是否确定问在**容器 + 具体 scroll action** 上（本稿建议是，理由是目标未挂载时根本没有目标可问，
  且这样不给老接入方的 default 分支新东西可决定）？备选是在目标上以一个新 action 值询问。
- `maxSteps` 默认 `40` / 硬上限 `200` 是否合适？本稿按"一步约 0.8 视口"取值：40 步约 32 屏，足够覆盖
  常见分页列表而不至于让一次误用长时间占住 App。
- 目标未挂载且全树有多个滚动容器时，是否确定拒绝而不是"从最内层可见的那个开始试"？本稿建议拒绝并
  指引 `--container`。
- example 补的懒加载屏是否与 PB-050-22 的写拒绝预设门一并调整，避免两个 MR 改同一个 example 文件。

## 被否决方案

- **合成指针滚动**：DG-050-10 已裁决实现留在 Semantics 域；指针滚动还要处理惯性与 fling 收敛，终止判据
  会从"观察 action 与 extent"退化成"等动画停"。
- **`SemanticsAction.scrollToOffset` 精确跳转**：它需要一个像素 offset，直接踩坐标红线；且只在
  `allowImplicitScrolling` 为真时存在（`_RenderScrollSemantics`），不在 `PatchbaySemanticsAction` 公开
  allowlist 内，等于用一条新坐标入口换步数。
- **实现成 `ui.semantics.actionByIdentifier --action showOnScreen`**：`hasAction(showOnScreen)` 恒假会被
  那族命令的可执行性检查一律误拒；且那族的成功判据是 dispatched，无法表达"验收可达"。
- **`ui.wait` 加一个 `semanticsReachable` condition 并让它顺便滚**：把写副作用塞进已被当只读用的命令。
- **Element 全树扫描按尺寸/深度给滚动容器打分**：DG-050-10 与 design.md 红线都明文排除；歧义就该拒绝。
- **懒加载增长时无限追加步数预算**：`scrollExtentMax` 可以一直增长（无限流），预算会失去上限；改为
  增长清零 stall 计数、`maxSteps` 保持唯一硬上限。
- **失败后把容器滚回原位**：恢复本身是另一串写操作，且懒加载已改变 extent 时无法精确还原；与
  anchored-gestures 对"半截手势"的判断同理，停在一个可观测的位置比停在一个"看似没动过"的位置更好解释。
- **用 `direction: up/down` 表达方向**：reverse 列表与横向列表会要求调用方先知道布局方向，等于把布局
  知识写进脚本。
- **发明第三个 `outcome` 值表示"滚了但没找到"**：已发布 CLI 只把 `failed` 映射为 `typedFailure`，新值会
  让老客户端对一次失败的 reveal 返回 0。
