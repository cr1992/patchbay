# 0.5.0 identifier 锚定的 scroll-to-reveal

> 状态：已接受
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

- 以稳定 Semantics identifier 锚定目标，在一次 App 受理内把它驱动到**已挂载且露出**，返回可直接用作
  后续写命令围栏的 `generation`，以及告诉调用方该走哪条 tap 通道的 `reachability`。
- 覆盖目标当前**未挂载**的懒加载场景：这是本命令存在的理由，不是边角情况。
- 步数与 deadline 双重有界，且两者都由 host 硬顶 → 接入方 policy → 命令参数三层收紧；超限、滚到底、
  被覆盖都以类型化事实如实报告，不伪造成功。
- **每一步都是被显式授权的一次容器驱动**：逐容器解析、逐容器过 policy、逐步重评门。
- 实现留在 Semantics 域，机制唯一：只派发 scroll action。

### 非目标

- 不合成指针滚动。`ui.gesture.*` 是另一条注入通道，两族命令的证据强度不同（见
  [锚定式手势](../0.4.0/anchored-gestures.md)）。
- 不派发 `SemanticsAction.showOnScreen`，也不以任何受限形式保留它（理由见「被否决方案」）。
- 不引入 Element 全树打分启发式，也不按 label、树顺序或"看起来像列表"猜目标或猜容器。
- **不引入任何坐标入参**。offset、像素步长、`scrollToOffset` 都不进契约；这是
  [design.md 非目标（红线）](../../design.md#非目标红线)在本条目的落点。
- 不自己实现遮挡判定算法；露出判据复用 DG-050-09 的判定基建，也不要求该基建为 reveal 加判据。
- 不做失败回滚。滚动已经发生就如实留在那里，不再派发一串"恢复原位"的写操作。
- 不引入 lease、token 或任何形式的"持续授权凭据"新机制；持续授权就是逐步重评。
- 不改变 `ui.wait`、`ui.semantics.*`、`ui.gesture.*` 已有的 wire、CLI 与失败码，也不修改
  `PatchbaySemanticsActionDecision` / `PatchbaySemanticsActionPolicy`。

## 三条必须先冻结的框架事实

以下三条来自 Flutter 3.44.9 框架源码（0.5.0 的当前 CI 版本），它们决定了 reveal 的机制选择与步进规则。

**一、容器暴露的 scroll action 集合本身就是边界信号。**
`flutter/lib/src/widgets/scroll_position.dart` 的 `_updateSemanticActions` 按
`pixels > minScrollExtent` / `pixels < maxScrollExtent` 决定暴露 backward / forward 哪一个，并按
`axisDirection` 映射到 `scrollUp|Down|Left|Right`。所以"到底了"不需要比较像素，只需要看那个 action
是否还在容器节点上——reverse 列表与横向列表因此自动正确。步长同样不归我们管：语义滚动一步是
`RenderSemanticsGestureHandler` 的 `scrollFactor`（默认 `0.8`，见
`flutter/lib/src/rendering/proxy_box.dart`）乘视口尺寸。**reveal 只控制步数，不控制步长。**

**二、`showOnScreen` 在 `SemanticsData.hasAction` 上恒为假，但 `performAction` 一定能走通。**
框架没有任何 widget 设置 `SemanticsConfiguration.onShowOnScreen`；真正生效的是
`SemanticsOwner.performAction`（`flutter/lib/src/semantics/semantics.dart`）里的兜底分支——找不到
handler 时调用节点自带的 `_showOnScreen`，而每个语义节点在
`flutter/lib/src/rendering/object.dart` 的 `_createSemanticsNode` 里都被构造为
`SemanticsNode(showOnScreen: renderObject.showOnScreen)`，该回调沿 RenderObject 父链冒泡到视口。

这条事实在本稿中承担两个论证，方向相反但结论一致：

- 它使 reveal **不能**实现成 `ui.semantics.actionByIdentifier --action showOnScreen`——既有
  `_resolveIdentifier` 的 `!data.hasAction(...)` → `uiSemanticsActionUnavailable` 前置检查对它一律
  误拒，快照的 `actions` 数组里也永远不会出现它。
- 它同样使 reveal **不应**在内部派发它：一条既不出现在快照、又不出现在任何 policy 决策入参里的驱动
  通道，接入方既观察不到也否决不了。逐容器授权模型要求"被驱动的每一件事都是接入方看得见、拒得掉
  的那件事"，`showOnScreen` 按构造做不到。

**三、滚动极性不能从 `SemanticsData` 推出，只能观察。**
action 名字（`scrollUp` / `scrollDown` / …）描述的是**用户会做的手势**，不是内容序。`reverse: true` 的
竖直列表里，朝 `maxScrollExtent` 前进的那一个是 `scrollDown`。`SemanticsData` 不暴露 `axisDirection`，
所以当两个 action 同时暴露时（即 `min < pixels < max`），**无法从快照字段判断哪一个增大 `pixels`**。
可以判断的只有两种情形：

- 只暴露一个同轴 action 时，`pixels` 处于某一端，该 action 的极性由事实一唯一确定
  （在 `min` 处只暴露 forward，在 `max` 处只暴露 backward）；
- 派发一步之后，`scrollPosition` 的位移符号确定极性。

「由容器当前暴露的 action 与观察到的位移符号确定」这句话不够：代价必须说清。本稿把它写死为一条
可测规则，见「极性探测」。

## 契约

### 命令形状：独立顶层命令 `ui.reveal`

不进 `ui.gesture.*`：那族的性质已被冻结为"合成指针事件序列"，把一个 Semantics 通道的命令放进去，会让
同一个命令族名同时指两种注入通道，证据强度不再能从命令名读出来。

不进 `ui.semantics.*`：那族命令的形状是"派发一个 allowlist 内的 action，返回 dispatched"，而 reveal 是
"有界循环 + 露出验收"；那族的授权也已经绑在 `PatchbaySemanticsActionPolicy` 上，而本稿的授权模型需要
自己的预算字段。

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
| `container` | string | 否 | — | 非空；滚动容器的锚定 identifier，见「容器的选择」 |
| `direction` | enum | 否 | `both` | `forward` / `backward` / `both`，**内容序**不是屏幕方向 |
| `maxSteps` | integer | 否 | `40` | `1..200`；200 是协议硬上限，越界为 `invalidUiArguments` |
| `timeoutMs` | integer | 否 | `5000` | `1..120000`；上限沿用 snapshot wait ceiling（2 分钟） |

`direction` 用内容序而非 `up/down`：`forward` = 朝 `maxScrollExtent`（`pixels` 增大），`backward` = 朝
`minScrollExtent`。落到哪个 `SemanticsAction` 由容器当前暴露的 action 与观察到的位移符号确定（见
「极性探测」），不由参数字面指定——否则 reverse 列表和横向列表就要求调用方先知道布局方向。

**不接受调用方 generation。** reveal 要找的目标常常尚未挂载，一个"你先前看到的代际"在这里没有意义。
围栏出现在输出端：成功 payload 返回的 `generation` 就是调用方紧接着做 `ui tap` / `ui text set` 时该带的
那一个。

### reveal 专用 policy（新增公共 API）

```dart
/// Consumer decision and tighter budgets for driving one scroll container.
final class PatchbayRevealDecision {
  const PatchbayRevealDecision.allow({
    this.gateIds = const <String>{},
    this.maxSteps = 40,
    this.maxDurationMs = 30000,
  }) : rejectionCode = null, rejectionNotice = null;

  const PatchbayRevealDecision.reject({
    this.rejectionCode = 'uiRevealDenied',
    this.rejectionNotice,
  }) : gateIds = const <String>{}, maxSteps = 0, maxDurationMs = 0;

  final Set<String> gateIds;
  final int maxSteps;
  final int maxDurationMs;
  final String? rejectionCode;
  final String? rejectionNotice;

  bool get allowed => rejectionCode == null;
}

typedef PatchbayRevealPolicy =
    PatchbayRevealDecision Function(
      PatchbaySemanticsTarget container,
      PatchbayRevealDirection direction,
    );
```

形状刻意与 `PatchbayGestureDecision` / `PatchbayGesturePolicy` 同构：那一对已经确立了"consumer 在
`allow` 上声明可收紧预算、host 常量做硬顶、请求超出即 `*BudgetExceeded`"的判例
（`packages/patchbay_flutter/lib/src/gesture/gesture_bridge.dart` 的 529-538 段）。

入参是**容器**，不是目标：reveal 的核心场景里目标根本不存在，唯一存在的、也是真正被移动的东西是容器。
把 policy 问在目标上会引入"能 tap 才能 reveal"这种无关耦合，且在目标未挂载时无法求值。

`direction` 入参是本次调用请求的内容序方向（`forward` / `backward` / `both`），不是最终落到的
`SemanticsAction`——接入方要判断的是"允不允许把这块区域往内容深处推"，不是"允不允许一次 scrollUp"。

注入点是 `PatchbayFlutterBridge` 构造函数新增的可选具名参数 `PatchbayRevealPolicy? revealPolicy`，
与 `semanticsActionPolicy` / `gesturePolicy` 并列（`packages/patchbay_flutter/lib/src/flutter_bridge.dart`
的 223-224 段；example 已经按这个形状直接构造 bridge）。**additive、可选、默认 `null`。**

**未注入即不可达，且不进 catalog。** `ui.reveal` 的注册按
`available: bridge.reveal.enabled`，`enabled => !kReleaseMode && _policy != null`——与
`bridge.gesture.enabled` 逐字同形（`flutter_service_host.dart` 的 238/253/268 行）。因此：升级 package
不会让任何现有 App 多出一条命令，接入方必须显式写下 reveal policy 才拿得到它。bridge 内部另保留
`uiRevealDisabled` 拒绝码，作为直接调用 bridge 的防御纵深，与 `uiGesturesDisabled` 同形。

### 三层预算

| 层 | 载体 | 步数 | 时长 | 越界后果 |
|---|---|---|---|---|
| host 硬顶 | bridge 编译期常量 `revealMaxSteps = 200` / `revealMaxDurationMs = 120000` | 200 | 2 分钟 | 任何 policy 或参数都不能突破 |
| 接入方 policy | `PatchbayRevealDecision.allow` 的 `maxSteps` / `maxDurationMs` | 默认 40 | 默认 30000 | 自身越出 host 硬顶 ⇒ `uiRevealBudgetExceeded` |
| 命令参数 | `maxSteps` / `timeoutMs` | 默认 40 | 默认 5000 | 超出协议区间 ⇒ `invalidUiArguments`；超出 policy 上限 ⇒ `uiRevealBudgetExceeded` |

三条不可动摇的规则：

1. **只能收紧，不能放宽。** 生效预算恒为 `min(参数, policy, host)`，且这个 min 通过**拒绝**达成而不是
   通过夹取：参数超出 policy 上限直接拒绝。静默夹取会让调用方以为自己要到了 100 步，实际只跑了 12 步，
   然后把 `stepBudgetExceeded` 误读成"列表真的很长"。
2. **步数是两级的。** 全局 `steps` 受命令参数约束；单个容器上的 `container.steps` 另受**该容器自己**的
   `decision.maxSteps` 约束。嵌套场景里内外层可以有不同的容器级预算。
3. **时长是 reveal 级的，且 deadline 只算一次。** `deadline = 受理时刻 + min(timeoutMs,
   准入容器 decision.maxDurationMs, host 硬顶)`，此后不再改写——单一 deadline 贯穿是
   `ui_wait_bridge.dart` 已冻结的纪律，中途改写会让 `elapsedMs` 失去单调解释。升层到一个
   `maxDurationMs` **小于**本次已冻结时长预算的容器时，引擎不改写 deadline，而是**停止**并报
   `reason: containerBudgetTooSmall`——那个容器的接入方没有授权这么长的驱动，继续推它就是越权。

一次调用的资源上界因此是封闭的：policy 调用次数 ≤ `2 × 容器数 + steps`，门求值次数 ≤ `steps + 1`，
identifier / nodeId 解析次数 ≤ `2 × (steps + 1)`，请帧次数 ≤ `steps`。除请帧外全部是纯内存操作。

### 执行 payload

reveal 只有 `revealed` 与 `failed` 两种受理后形状，不合并字段：

| 字段 | `outcome: revealed` | `outcome: failed` |
|---|---|---|
| `outcome`、`source`、`identifier`、`steps`、`elapsedMs` | 必有 | 必有 |
| `containers` | 必有；`[] ⟺ steps == 0` | 必有；恒非空 |
| `nodeId`、`generation` | 必有 | 仅当终止时目标已挂载时必有，未挂载时不得出现 |
| `reachability` | 必有，`pointer` \| `semanticsOnly` | **不得出现** |
| `beforeTreeRevision`、`afterTreeRevision` | 必有 | 必有 |
| `reason` | 不得出现 | 必有，取值见失败表 |
| `failureType` | 不得出现 | 仅 `reason: scrollActionFailed` 时必有，只写 `runtimeType` |
| `gateId`、`gateCode` | 不得出现 | 仅 `reason: gateRejected` 时必有 |

`containers` 的元素形状（数组，按**被驱动的先后顺序**排列，即由内向外）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `nodeId` | integer | 该容器语义节点 id |
| `generation` | integer | 准入/升层时 pin 的代际，终止时仍成立 |
| `steps` | integer | 在该容器上实际派发的 scroll action 次数，恒 ≥ 1 |
| `direction` | enum | `forward` / `backward` / `both`，**实际驱动过的**方向，不是请求的方向 |
| `extentGrowthSteps` | integer | 该容器上观察到 `scrollExtentMax` 增长的步数（懒加载证据） |

三条不变式，全部上 golden：

- 元素只在**第一次在该容器上派发**时追加，因此 `steps ≥ 1`，因此 `containers.isEmpty ⟺ steps == 0`；
- `containers` 各元素 `steps` 之和 == 顶层 `steps`；
- **不存在任何单数 container 字段**（没有 `containerNodeId`、没有 `containerGeneration`）。

沿用 `outcome: 'failed'` 而不是发明第三个值，是因为已发布 CLI 的
`patchbayExitCodeFor` 已经把它映射为 `typedFailure`（`packages/patchbay_cli/lib/src/result.dart`）：老
客户端读到失败的 reveal 就已经拿到非零退出码，`reason` 只是松读面上多出来的一条事实。

payload 里出现的 `scrollExtentMax` 观察值只以"增长了几步"的计数形式出现，**不是输入**，也不回显像素值。
reveal 没有任何位置入参，这条区分就是坐标红线在本命令上的边界。

## 容器的选择与逐容器授权

### 准入容器的确定

容器不是"扫全树找最像的那个"。它按下面的顺序确定，每一步都要么唯一，要么拒绝：

1. **给了 `container`**：按 identifier 唯一解析该锚点节点（未找到 / 歧义复用既有
   `uiSemanticsIdentifierNotFound`、`uiSemanticsIdentifierAmbiguous`，details 带 `role: "container"`）。
   锚点通常包在 `Scrollable` 外层（例如 example 的 `Semantics(identifier: ..., child: ListView...)`），
   所以从锚点子树内取**唯一**的滚动节点；子树内 0 个 → `uiRevealNoScrollableContainer`，多于 1 个 →
   `uiRevealContainerAmbiguous`。
2. **没给 `container` 且目标已挂载**：取目标语义祖先链上**最内层**的滚动节点作为准入容器。
   链上 0 个滚动节点且目标已露出 → 直接成功返回 `steps: 0`、`containers: []`；不可达 →
   `uiRevealNoScrollableContainer`。
3. **没给 `container` 且目标未挂载**：没有祖先链可用。此时全树只有一个滚动节点就用它；0 个 →
   `uiRevealNoScrollableContainer`，多于 1 个 → `uiRevealContainerAmbiguous`，notice 指引调用方补
   `--container`。**不按尺寸、深度、可滚动距离打分挑一个**——那正是红线要挡的猜测。

"滚动节点"的判据是既有快照字段而非新概念：`SemanticsData.scrollPosition != null`（Flutter 只在
`position.haveDimensions` 时写这三个字段，见 `_RenderScrollSemantics.describeSemanticsConfiguration`）。
一个滚动节点若一个同轴 scroll action 都不暴露（例如 `NeverScrollableScrollPhysics`，或内容不足一屏），
它不构成可驱动容器：作为准入容器时按 `uiRevealNoScrollableContainer` 拒绝，作为升层候选时直接跳过。

### 逐容器授权（本稿的核心机制）

**"授权一次 reveal" 不存在。存在的只有"授权驱动这一个容器"。**

准入只对**准入容器**求值：`policy(container, direction)` → allow 才继续，reject 即
`uiRevealDenied`（或 policy 自定的 `rejectionCode`）。准入容器的 `gateIds` 进第一次
`_gates.evaluate`，这也是本次调用的基础门求值点。

之后每次**升层**（当前容器耗尽、引擎转向外层容器）都是一次**新的、完整的授权**：

1. 按下节规则确定下一个容器，解析并 pin 其 `nodeId + generation`；
2. `policy(nextContainer, direction)`——拒绝即停止，`reason: containerDenied`；
3. 校验 `decision.maxSteps` / `maxDurationMs` 在 host 硬顶内，且 `maxDurationMs` 不小于本次已冻结的
   时长预算——不满足即停止，`reason: containerBudgetTooSmall`；
4. `_gates.evaluate(decision.gateIds)`——拒绝即停止，`reason: gateRejected`（details 带 `gateId` /
   `gateCode`）；
5. 通过后该容器进入驱动，追加一个 `containers` 元素。

**准入容器被拒即整条命令拒绝，不尝试外层。** 内层拒绝时跳到外层去滚，等于用一个更大的授权面绕过一个
更小的拒绝，方向上是扩权。fail-closed。

### 升层规则（由内向外，一次一层）

当前层判定耗尽后（见「步进循环」），下一层按以下顺序取，取到第一个可用的就停：

1. **目标已挂载**：取目标语义祖先链上、位于当前层之外、且尚未被驱动过的**最内层**滚动节点。目标挂载
   之后它的祖先链就是权威的容器栈，比准入时的猜测更准。
2. **目标仍未挂载**：取当前层的语义祖先链上、尚未被驱动过的**最内层**滚动节点。
3. 取不到 ⇒ 终止，`reason: scrollExhausted`。

一条早停规则：**目标挂载后，若当前层不在目标的祖先链上，立即判该层耗尽并升层。** 继续推一个与目标
无关的容器不会让目标露出，只会白白花掉步数预算；这条规则不改变授权模型（升层照样要过 policy 与门）。

嵌套懒加载场景仍然建议显式给 `--container`：情形 3（目标未挂载 + 多个平级滚动容器）确定拒绝，指引
补 `--container`，不做打分猜测。

## 步进循环与终止条件

### 极性探测

进入一个容器时先固定该容器的极性映射，之后整次调用不再重探：

- 若该容器只暴露一个同轴 scroll action，极性由事实一唯一确定（在 `min` 端暴露的是 forward，在 `max`
  端暴露的是 backward），**零成本**；
- 若两个同轴 action 都暴露，且请求方向是 `both`：**不需要极性**。`both` 只要求把两个 action 各自驱动
  到耗尽，顺序不影响结果；极性只用于给 `containers[].direction` 打标签，而每一步都会观察
  `scrollPosition` 的位移符号，标签是免费得到的；
- 若两个同轴 action 都暴露，且请求方向是 `forward` / `backward`：需要一步**探测步**。派发一个候选
  action、等一帧、读位移符号；若方向反了，引擎为该容器翻转映射并继续。探测步**计入 `steps` 与
  `containers[].steps`**，每容器每次调用至多一次，且它本身也是一次完整授权下的驱动（它在门与 policy
  复核之后发生）。

探测步会造成一次朝反方向的真实滚动。这是诚实的代价，写进 help：请求显式方向时，容器不在端点上，则
第一步可能先朝反方向走 0.8 个视口。想避免它的调用方用默认的 `both`。

### 每一步的固定序列

单一 deadline 从受理起算。每一步之后的等待复用 `PatchbayFrameObserver.nextFrameBefore(deadline)`——与
`ui.wait` 同款帧驱动纪律，**不引入固定墙钟 sleep**，deadline 到即停并如实报已发生的步数。

```text
每一步（派发之前，顺序不可颠倒）：
  a. deadline 到？          ⇒ 终止 timeout
  b. steps == maxSteps？    ⇒ 终止 stepBudgetExceeded
  c. container.steps == 该容器 decision.maxSteps？ ⇒ 该层耗尽，升层
  d. _isAppResumed()？      ⇒ 否则终止 lifecycleNotResumed
  e. 按 pin 重解析容器（nodeId + generation）⇒ 换代则终止 containerChanged
  f. 重跑 policy(container, direction)
       不 allow                       ⇒ 终止 policyChanged
       gateIds / maxSteps / maxDurationMs 与 pin 的决策不等 ⇒ 终止 policyChanged
  g. await _gates.evaluate(gateIds)（含基础门），受 deadline 约束
       拒绝     ⇒ 终止 gateRejected（details: gateId / gateCode）
       超 deadline ⇒ 终止 timeout
  h. 派发该容器当前暴露的目标方向 action；抛出 ⇒ 终止 scrollActionFailed
  i. await nextFrameBefore(deadline)；未等到 ⇒ 终止 timeout（本步已计入 steps）
  j. 重解析目标 identifier：
       多个挂载实例 ⇒ 终止 targetAmbiguous
       挂载且 areUserActionsBlocked ⇒ 终止 targetBlocked
       挂载且遮挡基建判定为 reachable / noPointerFootprint ⇒ 成功 revealed
  k. 判定本步进展：
       scrollPosition 变化              ⇒ 有效步，stall 归零
       位置没变但 scrollExtentMax 增长  ⇒ 有效步，stall 归零，extentGrowthSteps += 1
       两者都没变，或该方向 action 已从容器上消失 ⇒ stall += 1
  l. stall == 2 ⇒ 该方向耗尽：direction == both 且该容器未走过反向 ⇒ 换向、stall 归零；
                             否则该层耗尽 ⇒ 升层
```

进入循环之前先做一次 j 的判定（步数为 0 的那一次）：目标已挂载且露出 ⇒ 直接
`revealed / steps: 0 / containers: []`，一次 action 也不派发。

`scrollExtentMax` 增长是"内容刚补进来"的直接证据，因此它把 stall 计数清零而**不是**追加步数预算：
`maxSteps` 是任何情况下都不被突破的唯一硬上限，懒加载再多页也不会把一次调用变成无界循环。

### 为什么每步重评门是可负担的

「门可能异步且昂贵」不构成拒绝逐步重评的理由——在有 deadline 的循环里这个担心不成立，理由有三条：

1. **门的耗时被同一个 deadline 吃掉，不产生新的无界性。** 每次 `_gates.evaluate` 都在
   `deadline` 之内 await；门慢，reveal 就少滚几步，最后以 `timeout` 如实报告 `steps`。循环的时间上界
   仍然只有 deadline 一个。
2. **门求值次数有硬上界 `steps + 1 ≤ 201`**，且这个上界由接入方自己的 policy 与命令参数再收紧。
3. **相反方向的代价更大**：一次准入求值 + 40 步滚动意味着"你在第 1 步同意的事，我替你做到第 40 步"。
   reveal 每一步都是真实的、不可回滚的写副作用；只在开头问一次，与"写操作过声明门"的立场不符。

对**交互式门**（例如人工确认）的诚实说明写进 help 与包文档：逐步重评意味着接入方的 gate 会被问到
`steps` 次。希望"一次确认覆盖整条 reveal"的接入方有两条现成路径，都不需要协议新机制：把 reveal 放在
非交互门后、把交互确认放到随后的 tap / setText 上；或者在自己的 gate 闭包内 latch（gate 是接入方自己
的代码，latch 是接入方自己的状态）。协议侧不提供 lease。

### 终止条件矩阵

每一格都标注它在 payload 里的形状。`containers` 一栏中「已驱动」= 按实际驱动顺序列出的非空数组。

| 情形 | 判定依据 | `outcome` / `reason` | `containers` | `nodeId`/`generation` | `reachability` |
|---|---|---|---|---|---|
| 进入循环前目标已挂载且露出 | 遮挡基建三态 | `revealed` | `[]` | 有 | 有 |
| 单容器滚动后露出 | 同上 | `revealed` | 1 个元素 | 有 | 有 |
| 内层不够、升外层后露出 | 同上 | `revealed` | 已驱动（≥2） | 有 | 有 |
| 目标挂载但被滚动裁剪 / `isInvisible` | 不是终态 | 继续步进 | — | — | — |
| 目标挂载但所有采样点被挡 | 三态 `obstructed` | 继续步进直到耗尽/超限 | — | — | — |
| 容器栈耗尽，目标已挂载但仍未露出 | 无层可升 | `failed` / `targetObscured` | 已驱动 | 有 | 无 |
| 容器栈耗尽，目标仍未挂载 | 无层可升 | `failed` / `scrollExhausted` | 已驱动 | 无 | 无 |
| 目标挂载且 `areUserActionsBlocked` | 模态屏蔽，滚动解决不了 | `failed` / `targetBlocked` | 已驱动 | 有 | 无 |
| `steps == maxSteps` | 预算用完，可能还有 | `failed` / `stepBudgetExceeded` | 已驱动 | 有则有 | 无 |
| deadline 到 | 同上但因时间 | `failed` / `timeout` | 已驱动 | 有则有 | 无 |
| 循环中出现多个挂载实例 | 分页可能渲染重复项 | `failed` / `targetAmbiguous` | 已驱动 | 无 | 无 |
| 当前层容器换代 | 推的已不是被授权的那块区域 | `failed` / `containerChanged` | 已驱动 | 有则有 | 无 |
| 当前层 policy 决策漂移 | 授权前提变了 | `failed` / `policyChanged` | 已驱动 | 有则有 | 无 |
| 某一步门拒绝（含基础门） | 持续授权被撤回 | `failed` / `gateRejected` | 已驱动 | 有则有 | 无 |
| 升层时新容器被 policy 拒绝 | 未授权该区域 | `failed` / `containerDenied` | 已驱动 | 有则有 | 无 |
| 升层时新容器时长上限更严 | 未授权这么长的驱动 | `failed` / `containerBudgetTooSmall` | 已驱动 | 有则有 | 无 |
| 步内 App 离开 resumed | | `failed` / `lifecycleNotResumed` | 已驱动 | 有则有 | 无 |
| `performAction` 抛出 | | `failed` / `scrollActionFailed` | 已驱动 | 有则有 | 无 |

「有则有」= 该字段按统一规则出现：终止时目标已挂载就必有，未挂载就不得出现。

`scrollExhausted` 与 `stepBudgetExceeded` 必须是两个事实：一个说"这个列表里没有它"，另一个说
"我没看完"。把两者合成一个码，等于让调用方无法判断该不该加预算重试。`targetObscured` 与
`scrollExhausted` 同理：前者"找到了但露不出来"（改 UI 层级），后者"根本没找到"（改数据或加预算）。

## 可达性语义

### `reachability` 的定义与对应关系

露出判据复用 PB-050-16 的判定基建（[遮挡准入 Proposal](semantics-occlusion-admission.md)，随
PB-050-16 一并合入），reveal 不重复设计它，也不要求它为 reveal 增加任何判据。

成功的定义是**目标已挂载且露出**，`revealed` payload 必须带 `reachability`，取值封闭：

| `reachability` | 对应遮挡 Proposal 三态 | 含义 | 调用方随后应走 |
|---|---|---|---|
| `pointer` | `reachable` | 固定采样中至少一点的命中链可上溯到目标锚点 | `ui.gesture.tap` |
| `semanticsOnly` | `noPointerFootprint` | 目标本身没有指针占位，但也没有外来层挡在前面 | `ui.semantics.tap` |

第三态 `obstructed` **不是**成功，因此没有对应的枚举值；它在 reveal 里表现为"继续步进"，耗尽后表现为
`failed / targetObscured`。这是枚举只有两个值的原因，也是它可以被直接当作"下一步走哪条通道"的原因。

### 为什么这个枚举不可省

`noPointerFootprint` 是完全合法的无障碍写法——`Semantics(onTap:)` 包一个不参与命中测试的子树
（`SizedBox`、纯 `CustomPaint`、离屏文本），仓内现有绿灯用例就是这一形状。遮挡 Proposal 明确把它判为
通过，因此 `ui.semantics.tap` 会放行。但 gesture 家族的逐点管线用的是布尔规则（最顶命中必须落在目标
子树内），同一个目标送进 `ui.gesture.tap` 会**确定性地**拿到 `uiGestureTargetObscured`。

「reveal 之后直接 tap」的笼统建议因此在两条通道上各错一半：对 `semanticsOnly` 目标推荐指针通道会稳定失败，
而对 `pointer` 目标推荐语义通道又放弃了 DG-050-08 认定的防误击首选路径。枚举把这次分流从"调用方试
错发现"变成"reveal 直接给出"。

### 诚实边界：这是固定采样，不是可达性证明

reachability 判定与遮挡 Proposal 使用同一套基建、同一口径：按目标 rect 归一化取
`(0.5,0.5)`、`(0.25,0.25)`、`(0.75,0.25)`、`(0.25,0.75)`、`(0.75,0.75)` 五点，**任一点通过即通过**。
用语与遮挡 Proposal 保持一致：这是**固定采样准入**，不是可达性证明。目标只在五个采样点之外露出窄缝
时，采样会全部被挡而误拒（fail-closed，与本命令"不伪造成功"的方向一致）。

因此 `reachability` 承诺的是：**Patchbay 在终止那一帧的固定采样下观察到目标以该形态露出**。它不证明
业务状态，不证明目标完全入视口，不承诺下一帧仍然如此——那是返回的 `generation` 要解决的问题。help
与文档不得把它写成"用户一定能点到"。

reveal 不要求遮挡基建为它增加任何判据：三态就是它需要的全部，`reason` 词表是否区分 clip 与 hit-test
与 reveal 无关。

## 门、授权与 TOCTOU

与 `_dispatch` 同构的 TOCTOU 纪律，扩展到循环里：

- **容器 generation 在准入/升层时 pin，每一步派发之前按同一 pin 重解析并核对**，换代即停
  （`containerChanged`）。容器换掉意味着这已经不是被授权的那块可滚动区域。显式 `--container` 的容器
  按 identifier 锚点重解析；来自祖先链的容器没有 identifier，按桥已有的 `nodeId + generation` 解析
  原语重解析，**不复制第二套解析**。
- **每一步派发之前重跑 policy 并比对决策**：`allowed`、`gateIds`、`maxSteps`、`maxDurationMs` 四项与
  pin 的决策逐项相等才继续；任一项漂移即停（准入前用 `uiRevealPolicyChanged`，准入后用
  `reason: policyChanged`）。比对项与 gesture 的 `_decisionEquals` 同构。
- **每一步派发之前重评门**，见上节。
- 每一步重查 `_isAppResumed()`；App 离开 resumed 立即停。
- 目标 identifier 每一步重解析，不缓存 nodeId：懒加载列表回收 node 是常态。
- **门求值与 `performAction` 之间不得存在额外 await/yield**：同一步内 g 与 h 之间不插入其他异步点，
  用同一次解析得到的 `owner` / `nodeId`。

**受理边界是第一次派发。** 第一次 scroll action 派发（含探测步）之前的任何失败都是
`admission: rejected`；之后的失败进入受理 payload（`outcome: 'failed'` + `reason`），不改写成未受理——
滚动已经发生，把它报成"没受理"就是对副作用撒谎。同一个条件（policy 漂移、门拒绝、容器换代、
lifecycle）因此可能出现在两边，分界线只有这一条。

`steps` 的计数口径随之固定：**已派发的 action 次数**。门在第 k 步拒绝时，`steps == k - 1`——那一步没
派发出去。这条要有专门的测试。

## 状态、失败与预算

准入前稳定拒绝码：

| code | 触发 | 新增 |
|---|---|---|
| `invalidUiArguments` | identifier/container 为空，`maxSteps`/`timeoutMs` 越出协议区间，`direction` 非法 | 否 |
| `uiLifecycleNotResumed` | 受理时 App 不在 resumed | 否 |
| `uiSemanticsUnavailable` | 拿不到 owner / root | 否 |
| `uiSemanticsIdentifierNotFound` | 显式 `container` 未挂载（details 带 `role`） | 否 |
| `uiSemanticsIdentifierAmbiguous` | 显式 `container` 歧义 | 否 |
| 各 gate code | 基础门 / 声明门在准入时拒绝，形状沿用 `_gateRejected` | 否 |
| `uiRevealDisabled` | 接入方未注入 reveal policy（命令同时不进 catalog） | **是** |
| `uiRevealNoScrollableContainer` | 锚点/祖先链/全树内没有可驱动滚动节点，且目标未露出 | **是** |
| `uiRevealContainerAmbiguous` | 候选滚动容器多于一个且未给 `container` | **是** |
| `uiRevealDenied` | reveal policy 拒绝准入容器（可被 policy 自定 code 覆盖） | **是** |
| `uiRevealBudgetExceeded` | 参数超出 policy 上限，或 policy 自身超出 host 硬顶 | **是** |
| `uiRevealPolicyChanged` | 准入期两次 policy 求值的决策不等 | **是** |

受理后 `reason` 取值封闭：`stepBudgetExceeded`、`scrollExhausted`、`targetObscured`、`targetBlocked`、
`targetAmbiguous`、`containerChanged`、`containerDenied`、`containerBudgetTooSmall`、`policyChanged`、
`gateRejected`、`lifecycleNotResumed`、`timeout`、`scrollActionFailed`。按 PB-050-23 的口径，这两组
字面量都必须进封闭注册表，并配穷尽性测试。

不可参数化常量（全部在 payload 或失败 details 里如实回报，调用方才知道自己撞的是哪一条）：
`stallSteps = 2`、`revealMaxSteps = 200`、`revealMaxDurationMs = 120000`、每容器至多 1 次探测步。

## 兼容与降级

- **老 CLI + 新 host**：catalog 至多多一条命令（且只在接入方注入了 reveal policy 时才多）；
  `catalogDigest` 因 `commands` 集变化而变化，`covers: [commands]` 不变。不新增任何 wire 类型字段，
  尤其不动 `PatchbayUiTargetDescriptorWire`——已发布客户端严格解码它，加字段即当场 `FormatException`。
  新命令的请求/响应类型是全新类型，不在 `strictlyDecodedByShippedClients` 名单内。
- **新 CLI + 老 host**：catalog 无 `ui.reveal` 时类型化报告 command unavailable，**不降级**为客户端侧
  "读树—滚一步—再读树"循环：那个循环没有 App 内代际围栏、没有逐步门，正是本条目要消灭的东西。
- **未注入 reveal policy 的新 host**：与老 host 对同一 CLI 呈现同一事实（命令不在 catalog）。这是刻意
  的：接入方没写下授权，就不存在"能力可用但会被拒"的中间态。
- **公共 API additive**：`PatchbayRevealPolicy`、`PatchbayRevealDecision`、`PatchbayRevealDirection`
  与 `PatchbayFlutterBridge` 的可选具名参数 `revealPolicy` 都是新增，`tool/api_surface.json` 的
  `patchbay_flutter` 段按新增更新，不删除、不改签名。既有 `PatchbaySemanticsActionPolicy` /
  `PatchbaySemanticsActionDecision` **一个字节不动**，因此所有现存接入方代码无需改动即可编译。
  PB-050-13 收口的是 `patchbay_cli` 的公共面，与本条不相交。
- **VM Service ↔ direct**：共享同一 decoder、registration 与 Flutter 桥；transport 两侧都不实现容器
  选择、极性探测、步进或终止判定。
- `ui.wait`、`ui.semantics.*`、`ui.gesture.*` 的 wire、CLI 与失败码逐字节不变。

### 与 ui.wait 的组合语义

- reveal **不内嵌** wait condition，也不接受 `condition` 参数：它只有一个成功判据。
- `ui reveal X` 之后**不需要**再 `ui wait semantics-mounted X`：挂载与露出在同一次受理内完成，且
  `semanticsMounted` 的判据（`matches.isNotEmpty && !invisible`）比固定采样露出弱，两者不能互相代替。
  help 必须写清这条强弱关系，避免调用方用 wait 的成功替 reveal 背书。
- 典型链路按 `reachability` 分流：
  `ui reveal X` → `pointer` ⇒ `ui gesture tap X --generation <g>`；`semanticsOnly` ⇒
  `ui tap X --generation <g>`。中间的窗口由调用方用那个 generation 兜住，reveal 不替它保留。
- reveal 的 deadline 语义与 `ui.wait` 同源：单一 deadline、帧驱动推进、超时如实回报已观察到的进度。

## 安全与隐私

- identifier 是声明式稳定身份，不以 label / value 兜底；目标与容器歧义一律 fail-closed，不按树顺序选。
- 响应、日志、audit 与 trace 不写入 label、value 或任何目标文本；容器观察值只保留 `nodeId`、
  `generation` 与计数型的 `steps` / `extentGrowthSteps`，**不回显 `scrollPosition` / `scrollExtent*` 的
  像素值**，也不回显坐标、rect、探针点（沿 DG-040-01 冻结的红线与遮挡 Proposal 的口径）。
- 没有敏感输入面：reveal 不接受 text，也不派发 `setText`。
- 授权面按构造收敛：未注入 reveal policy 即无命令；注入后每个被驱动的容器都经过接入方自己的 policy 与
  门，且每一步都重问一次。不提供 bypass / force 参数或环境变量。
- release 构建的可裁除边界不因新增 public 入口而改变；`enabled` 含 `!kReleaseMode`，与 gesture 同形。
- reveal 产生真实副作用（列表位置改变、懒加载触发网络请求），因此它必须留在写命令的门与审计路径上，
  不得因为"只是滚动"被降级成只读。审计事件按每次调用一条，携带 `steps` 与被驱动容器的 `nodeId` 列表。

## 验证

- **单元/协议**：descriptor / codegen / CLI parity；`strictKeys` 对未知 key 在 bridge 与 policy 之前拒绝；
  `maxSteps` / `timeoutMs` 边界值；`direction` 非法值；`revealed` 与 `failed` 两种 payload 按字段表逐项
  断言 presence 与 absence（尤其 `reachability` 只在 `revealed` 出现、`containers` 恒出现、任何单数
  container 字段恒不出现）；`containers` 三条不变式；两组错误码字面量进封闭注册表（PB-050-23）。
- **policy 与预算矩阵**：
  - 未注入 reveal policy ⇒ 命令不在 catalog；直接调 bridge ⇒ `uiRevealDisabled`；
  - 参数 `maxSteps` 超 policy 上限 ⇒ `uiRevealBudgetExceeded`（断言**没有**静默夹取：一步都没派发）；
  - policy 自身 `maxSteps > 200` 或 `maxDurationMs > 120000` ⇒ `uiRevealBudgetExceeded`；
  - policy 拒绝准入容器 ⇒ `uiRevealDenied`；自定 `rejectionCode` 原样透出；
  - 内层 allow、外层 reject ⇒ 内层滚完后 `containerDenied`，`containers` 只含内层；
  - 外层 `maxDurationMs` 小于已冻结时长预算 ⇒ `containerBudgetTooSmall`；
  - 生效预算恒为 `min(参数, policy, host)`，用三组取值断言。
- **逐步授权矩阵**：
  - 门在第 k 步转为拒绝 ⇒ `gateRejected` 且 `steps == k - 1`（证明门在派发之前）；
  - 门被调用次数 == `steps + 1`（准入 1 次 + 每步 1 次），用计数 fake gate 断言；
  - 慢门（每次 await 一段可控时长）⇒ 以 `timeout` 终止且 `steps` 如实小于 `maxSteps`，证明门耗时被同一
    deadline 吸收；
  - 步间 policy `gateIds` / `maxSteps` / `maxDurationMs` 任一漂移 ⇒ `policyChanged`；
  - 步间 App 进入 paused ⇒ `lifecycleNotResumed`，payload 报告已发生步数。
- **机制唯一性回归**：用记录 `performAction` 调用的 fake owner 断言**整个矩阵中从未派发
  `SemanticsAction.showOnScreen`**。这条必须以机检落地，不能只靠代码评审。
- **widget 测试矩阵**：
  - 懒加载分页：`itemCount` 随滚动增长的列表，断言对应 `containers` 元素 `extentGrowthSteps > 0` 且
    stall 被增长清零；
  - 嵌套滚动：复用 example 的 `gestureListSemanticsId` / `gestureNestedListSemanticsId`，断言由内向外的
    换层顺序、`containers` 有 2 个元素且顺序为内→外、每层各自过了一次 policy 与门；
  - `reverse: true` 与 `Axis.horizontal`：断言 `direction: forward` 落到正确的 `SemanticsAction`，且不
    依赖参数里出现任何屏幕方向词；
  - 极性探测：容器停在中段 + 显式 `--direction forward` ⇒ 至多一次反向探测步，且探测步计入 `steps`；
    容器停在端点 ⇒ 零探测步；`--direction both` ⇒ 零探测步；
  - 固定 overlay（pinned header / 底栏）盖住目标：断言继续滚动后成功；始终被盖且容器耗尽 ⇒
    `targetObscured` 而不是伪造成功；
  - `ModalBarrier` / `BlockSemantics` 盖住已挂载目标 ⇒ `targetBlocked`，且不再继续滚动（断言 `steps`
    停在该步）；
  - reachability 两个值各一条：普通按钮行 ⇒ `pointer`；`Semantics(onTap:) > SizedBox` 行 ⇒
    `semanticsOnly`；两者 `outcome` 都是 `revealed`；
  - 超限：`maxSteps: 1` 而目标在数屏之外 ⇒ `stepBudgetExceeded`；滚到底仍无目标 ⇒ `scrollExhausted`；
    两者的 details 可区分；
  - `NeverScrollableScrollPhysics` / 内容不足一屏 ⇒ 无同轴 scroll action ⇒
    `uiRevealNoScrollableContainer`；
  - 容器歧义：两个平级 ListView 且目标未挂载 ⇒ `uiRevealContainerAmbiguous`，补 `--container` 后成功；
  - 目标一开始就露出 ⇒ `steps: 0`、`containers: []`、`reachability` 有值、未派发任何 action；
  - 循环中目标出现两个实例 ⇒ `targetAmbiguous`。
- **竞态与失败注入**：门 await 期间容器换代（准入前拒绝）与步间容器换代（受理后 `containerChanged`）；
  `performAction` 抛出 ⇒ `scrollActionFailed` 且只写 `runtimeType`；deadline 恰好落在两步之间；
  deadline 落在门 await 之中；owner 中途消失。
- **VM/direct**：同一矩阵在两条传输上跑，断言两侧 JSON 逐字节一致。
- **兼容**：复刻 0.4.1 reader 读取新 catalog 与新 payload；老 CLI 对 `outcome: 'failed'` 得到
  `typedFailure` 退出码；`ui.wait` / `ui.semantics.*` / `ui.gesture.*` 的 golden 不变；
  `tool/api_surface.json` diff 只有新增。
- **example 预检（debug）**：example 需注入一份 reveal policy（连同 PB-050-22 的预设门），补一屏懒加载
  分页列表（带 identifier 的远端行）与一层固定 overlay；`tool/example_precheck.sh` 覆盖
  reveal → 按 `reachability` 分流 tap 的完整链路，`tool/example_profile_smoke.sh` 只验答复形态。
  预检不过不进业务验收。
- **接入方真机**：真实长列表的分页节奏、真实固定层与真实控制器语义只能由接入方出证据；至少覆盖一次
  "reveal 成功后立即用返回的 generation 与 reachability 完成写操作"，以及一次"逐步门在中途拒绝"的
  实际观感确认（确认逐步重评没有把接入方的交互门变成不可用）。

## 实施与回退

- 落在 M7，与 PB-050-16 共享遮挡判定基建；PB-050-16 先合入。
- reveal 的循环不塞进 `PatchbaySemanticsBridge._dispatch`（结构警戒线：不新增 long-function 警戒线），
  独立成 Semantics 域内的一个可单测阶段（建议 `reveal_engine`：入参是容器解析原语、policy、门、帧
  观察者，出参是终态），bridge 只做受理、payload 组装与拒绝码映射。identifier / nodeId 解析、
  `observe` / generation 与 owner 获取**复用**桥已有原语，不复制第二套解析。帧等待复用
  `PatchbayFrameObserver`，由组合根注入。
- 若 PB-050-16 的判定基建未能在本版落地，**reveal 一并回退**，不以"几何入视口"临时冒充成功判据——
  那是 DG-050-10 明确禁止的伪造成功；也不以"派发成功"冒充，那是本条目问题陈述里的假覆盖。
- reveal 独立回退：回退不触碰 `ui.semantics.*`、`ui.gesture.*` 与 `ui.wait` 的任何字节；回退时
  `PatchbayRevealPolicy` 等新公共类型一并移除（它们没有其他消费者），`api_surface.json` 回到基线。

## 待裁决

- `PatchbayRevealPolicy` 的入参是否确定为 `(容器, 请求方向)`？本稿建议是：目标未挂载时没有目标可问，
  而"允不允许把这块区域往内容深处推"正是接入方要判断的事。备选是 `(容器, 落到的 SemanticsAction)`，
  但那会把布局方向知识塞进 policy 实现。
- 逐步重门是否需要给 `PatchbayGateEvaluator.evaluate` 增加 `requestId`，以便接入方在自己的 gate 里按
  请求 latch 一次确认？本稿建议**本条不改公共 gate API**（PB-050-13 正在收口公共面，且接入方可在自己
  的闭包内 latch），但这是逐步授权带来的真实摩擦，值得仓主明确。
- `containerBudgetTooSmall` 是否保留？备选是要求 policy 对同一次 reveal 的所有容器返回相同的
  `maxDurationMs`，不一致即视为 policy 实现错误。本稿建议保留该 reason：它把"外层授权更严"表达成
  一个可读事实，而不是把接入方的合法收紧当成 bug。
- 显式 `--direction forward` 且容器停在中段时，至多一次反向探测步是否可接受？本稿建议接受并写进 help；
  备选是显式方向下要求容器先在端点，等于把布局状态知识写进脚本。
- `maxSteps` 默认 `40` / host 硬顶 `200` 是否合适？本稿按"一步约 0.8 视口"取值：40 步约 32 屏，足够覆盖
  常见分页列表而不至于让一次误用长时间占住 App。policy 默认 `maxDurationMs = 30000` 与 gesture 的
  30 秒默认对齐。
- 目标未挂载且全树有多个滚动容器时，是否确定拒绝而不是"从最内层可见的那个开始试"？本稿建议拒绝并
  指引 `--container`。
- example 补的懒加载屏与 reveal policy 是否与 PB-050-22 的写拒绝预设门一并调整，避免两个 MR 改同一个
  example 文件。

### 实现期裁决补记（2026-08-26，仓主授权代理裁决）

- **准入期 deadline 超时的码**：不新设码，复用 `uiRevealBudgetExceeded` 并以 `details.exceeded:
  timeoutMs` 指名维度——timeout 本就是三层预算的一维，封闭码表克制优先。
- **交给 policy 的容器身份**：`container.identifier` 取该容器最内层的锚点 identifier（沿 parent 上溯
  取第一个非空、遇另一滚动节点即停）。滚动语义节点自身的 identifier 按惯例恒为空串，原样上交会让
  policy 结构上无法辨认区域；此规则是确定规则，非启发式打分。
- 审计事件的 reveal 富化（steps + 被驱动容器 nodeId 列表）涉及 `PatchbayAuditEvent` 公共形状与
  host_invoker，越出本条授权面，另立 PB-050-26 追踪。

## 被否决方案

### 关于 `showOnScreen` 的三个层次（阻断点三的完整论证）

**层次一：实现成 `ui.semantics.actionByIdentifier --action showOnScreen`。** 事实二使
`hasAction(showOnScreen)` 恒假，那族命令的可执行性检查会一律误拒；且那族的成功判据是 `dispatched`，
无法表达"验收露出"。

**层次二：内部无条件派发 `showOnScreen`。** 否决理由：它是一条接入方在
快照里看不见、在任何 policy 入参里也见不到的驱动通道。逐容器授权模型的前提是"被驱动的每一件事都是
接入方看得见、拒得掉的那件事"，`showOnScreen` 按构造做不到。

**层次三：受限使用——只在"全树只有一个滚动容器且该容器已通过 policy 与门"时派发一次
`showOnScreen`。** 这是唯一在直觉上可辩护的变体：既然只有一个容器被授权，冒泡也只可能冒到它。本稿
仍然不采用，四条理由，按分量排序：

1. **"只影响单一已授权容器"在这个场景里不可证明，只能假设。** `showOnScreen` 沿 **RenderObject** 父链
   冒泡，而 reveal 手上的是**语义树**。语义树上只有一个滚动节点，不等于渲染树上只有一个能响应
   `showOnScreen` 的祖先：不产生滚动语义节点的可滚动祖先（`haveDimensions` 尚未成立、被
   `ExcludeSemantics` 包住、或语义被合并）在渲染树上照样吃这次冒泡。要真正证明它，reveal 就得去读
   渲染树的父链——那是 Element/Render 全树推断，正是 DG-050-10 与 design.md 红线排除的东西。
2. **它没有步的粒度，因此逐步授权在它上面失去意义。** 一次 `showOnScreen` 的位移由框架决定，可能是
   零，也可能是任意多屏。阻断点二要的"每一步都被重新授权"无法定义在一个位移不可预知的原语上；
   把它混进循环，等于在一条"每步重问"的链路里插入一段"问一次、走多远由框架说了算"。
3. **它的失败与"无事可做"不可区分。** `RenderViewportBase.showOnScreen`
   （`flutter/lib/src/rendering/viewport.dart`）在 `!offset.allowImplicitScrolling` 时直接冒泡给父级、
   不动 offset；目标未挂载时更是连节点都没有。派发不抛错、不返回值，唯一可观测的差别是
   `scrollPosition` 没变。要区分这两种情况，就不得不在稳定 payload 上加 `usedShowOnScreen` 与
   `showOnScreenNoop` 一类字段——把实现机制泄露进契约。不引入该机制，这类字段就不存在。
4. **收益接近零。** 它省下的只是若干步 scroll action，而步数本来就有预算、有硬顶、有如实回报；换来的
   是一套第二机制、两套终止词表、两套证据形状。机制唯一是本命令可被评审和可被回退的前提。

**"证明只影响单一容器后再启用"作为后续条目的可能性也一并说明**：若将来 Patchbay 有了从语义节点到
渲染锚点的稳定映射（PB-050-16 的判定基建已经需要一部分），理论上可以在派发前枚举渲染父链上的全部
视口并逐个过 policy。届时它仍要面对理由 2（无步粒度），所以本稿判断它不会成为一条更好的路径，而不是
"暂时不做"。

### 其余被否决方案

- **合成指针滚动**：DG-050-10 已裁决实现留在 Semantics 域；指针滚动还要处理惯性与 fling 收敛，终止判据
  会从"观察 action 与 extent"退化成"等动画停"。
- **`SemanticsAction.scrollToOffset` 精确跳转**：它需要一个像素 offset，直接踩坐标红线；且只在
  `allowImplicitScrolling` 为真时存在（`_RenderScrollSemantics`），不在 `PatchbaySemanticsAction` 公开
  allowlist 内，等于用一条新坐标入口换步数。
- **复用 `PatchbaySemanticsActionPolicy` 授权 reveal**：它把"允许一次单步
  scroll"当成"允许一次 40 步循环"的凭据，且那份 decision 没有任何预算字段可供接入方收紧。
- **给 `PatchbaySemanticsActionDecision` 加 `maxSteps` 等字段**：会改动一个已发布的公共类型，所有现存
  接入方的 `allow(...)` 调用点都要重新理解语义；且那份 decision 是"一次 action"的决定，加步数字段会让
  它对 `ui.semantics.action` 的调用者失去意义。
- **引入 reveal lease / 授权 token**：阻断点二明确排除。lease 是一个新的、需要发放、续期、撤销与过期
  语义的机制，且它仍然只在发放那一刻询问接入方；逐步重评用已有的门原语解决同一问题，不加机制。
- **只在准入求值一次声明门**：见「为什么每步重评门是可负担的」。
- **失败时把容器滚回原位**：恢复本身是另一串写操作，且懒加载已改变 extent 时无法精确还原；与
  anchored-gestures 对"半截手势"的判断同理，停在一个可观测的位置比停在一个"看似没动过"的位置更好解释。
- **单数 `containerNodeId` / `containerGeneration` 字段**：无法表达嵌套换层，与
  "由内向外"设计自相矛盾。
- **`reachability` 增加第三个值表示 `obstructed`**：那不是成功，成功 payload 上不应出现一个表示失败的
  枚举值；它已经由 `failed / targetObscured` 表达。
- **"被固定层覆盖时有界继续滚动 N 步"**：该规则依赖遮挡基建区分"裁剪"与"覆盖"，而基建的
  `reason` 词表把两者合在 `hitTestOrClip` 里。规则删除，`obstructed` 统一走"继续步进直到耗尽/超限"。
- **Element 全树扫描按尺寸/深度给滚动容器打分**：DG-050-10 与 design.md 红线都明文排除；歧义就该拒绝。
- **懒加载增长时无限追加步数预算**：`scrollExtentMax` 可以一直增长（无限流），预算会失去上限；改为
  增长清零 stall 计数、`maxSteps` 保持唯一硬上限。
- **参数超出 policy 上限时静默夹取**：调用方会把被夹取后的 `stepBudgetExceeded` 误读成"列表真的很长"，
  从而做出错误的重试决定。拒绝比夹取诚实。
- **用 `direction: up/down` 表达方向**：reverse 列表与横向列表会要求调用方先知道布局方向，等于把布局
  知识写进脚本。
- **发明第三个 `outcome` 值表示"滚了但没找到"**：已发布 CLI 只把 `failed` 映射为 `typedFailure`，新值会
  让老客户端对一次失败的 reveal 返回 0。
- **`ui.wait` 加一个 `semanticsReachable` condition 并让它顺便滚**：把写副作用塞进已被当只读用的命令。
