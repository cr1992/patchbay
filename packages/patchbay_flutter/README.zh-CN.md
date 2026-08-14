# Patchbay Flutter

[English](README.md) | 简体中文

`patchbay_flutter` 是 Patchbay 的可选 Flutter adapter。它的目标是用最小 Widget 侵入提供稳定、
可发现、fail-closed 的 UI 调试能力，而不是实现一套坐标驱动的黑盒自动化框架。本文中的
consumer 指接入 Patchbay 的 App。

快速安装和首次连接见[仓库 README](../../README.zh-CN.md#快速开始)，通用协议和传输边界见
[`../patchbay/README.zh-CN.md`](../patchbay/README.zh-CN.md)。

## 当前能力

| 能力面 | 公共 API 与边界 |
|---|---|
| **稳定 target** | `PatchbayKey.text`、弱引用 registry、mounted generation、重复 ID 歧义和 stale 拒绝 |
| **文本操作** | `text.set` / `text.enter`、每操作 gate、敏感输入和 side-effect descriptor |
| **Semantics** | 无容器的规范化树、节点 generation、obscured value 脱敏，以及 policy 默认拒绝的标准 action |
| **导航与等待** | composition-root navigation adapter、revision / redirect / timeout 语义和 `ui.wait` 条件 |
| **截图** | 可选 root / target capture、下一帧复核、像素与字节上限、chunked blob 输出 |
| **Host 组合** | `PatchbayFlutterServiceHost` 把 UI 与领域 catalog/operator 合并到同一 service extension |

日志面位于 core `patchbay`，只有 consumer 显式注入 `PatchbayArtifactService` 时才进入本 host 的
catalog。Widget/Render/Focus 诊断树由
`patchbay_cli` 直接代理 Flutter 运行时 extension，不经过本包复制协议。

Widget/Render/Semantics 三树、标准 action、节点 generation、脱敏与 DevTools 诊断代理的契约
见 [`doc/ui-inspection-and-actions.md`](doc/ui-inspection-and-actions.md)。该文档明确树驱动 action
是默认低侵入路径，语义导航只作稳定增强。

## 低侵入分级

| 接入级别 | Consumer 改动 | 能力 |
|---|---|---|
| Host only | App 组合根启动 service host | identity、领域 catalog/snapshot/invoke；不承诺稳定 Widget 操作 |
| Runtime observation | 只启动 Flutter host，不改 Widget 树 | Widget/Render/Semantics 摘要和标准 Semantics action |
| Optional root bridge | App 最上层包一次 root bridge | 根截图和确实需要根渲染上下文的帧协调 |
| Single Key | 目标 Widget 的 `key` 换成 `PatchbayKey` | 该目标 catalog 明示的操作 |

不要求页面继承基类，不要求逐页面容器，不要求给所有 Widget 标 Key，也不维护一份与 Widget 树重复的
集中 target 清单。

## Key 接入

需要远程操作的控件只替换 Key：

```dart
late final PatchbayKey nameKey = PatchbayKey.text(
  'profile.displayName',
  operationGates: <PatchbayUiOperation, Set<String>>{
    PatchbayUiOperation.textEnter: <String>{'profile.editable'},
  },
);

TextField(
  key: nameKey,
  controller: controller,
  inputFormatters: formatters,
  onChanged: onChanged,
)
```

`PatchbayKey` 本身就是目标 Widget 唯一的 `key`，不再包 `PatchbayTextTarget` 等容器。

Key 在 debug、profile、release 中始终是同一种 `GlobalKey`，保持 Element/State 的挂载和跨位置移动
语义。release 只裁掉 declaration、弱登记和 operator 引用，不能退化成另一种 Key。

## 注册与重挂载语义

这一节是接入方最容易靠逆向源码才搞明白的部分，三句话概括：**构造即注册、弱引用出册、
只有同时挂载才判歧义**。

### 构造即注册

登记发生在 `PatchbayKey.text(...)` / `PatchbayKey.capture(...)` 的**构造函数**里，不是在
Widget 挂载时。所以：

- 一个从未挂载过的 Key 也会出现在 `patchbay catalog` 的 `uiTargets` 里，只是 `mounted: false`
  且 `operations` 为空——目录列出的是"声明过的目标"，不是"当前可操作的目标"；
- release 下 `declaration` 为 `null` 且完全不登记，Key 退化成一个普通 `GlobalKey`；
- 没有、也不需要 `dispose()`：接入方创建 Key，不管理注册生命周期。

### 弱引用出册

registry 对每个 Key 持 `WeakReference`。Key 对象被 GC 后，条目在**下一次被观察时**
（读 catalog 或解析一次调用）清掉；一个 ID 的条目全部清空后，该 ID 从目录消失。

这是弱引用语义，不是确定性析构：**页面已经销毁但 Key 还没被 GC 时，目录里仍会看到那条
`mounted: false` 的记录**。这不是泄漏，也不影响操作——mounted 状态是当场按 `Element` 判的。

### mounted、generation 与歧义

| 事实 | 判定方式 |
|---|---|
| `mounted` | 当场读 Key 的 `currentContext`，有 `Element` 才算挂载 |
| `generation` | 每个 ID 一个单调递增计数器；观察到 `Element` 身份变化时 +1 |
| `ambiguous` | **只数同时 mounted 的实例**；>1 才置位 |

几个由此推出、但容易猜错的结论：

- **首次观察到挂载时 generation 是 1，不是 0。** 未挂载过的条目是 0。
- **计数器按 ID 共享**，不按 Key 实例。同一 ID 的第二个实例挂载时拿到的是全局下一个号，
  不会从 1 重新开始。
- **GlobalKey 跨位置移动不改号。** Element 被带着走、身份没变，generation 就不变——这正是
  Key 必须保持 `GlobalKey` 语义的原因之一。
- **未挂载的重复条目不构成歧义。** 三个同 ID 的 Key 只有一个挂载时，操作照常可执行。
- **generation 只在被观察时推进。** 两次观察之间重挂载了三回，号也只 +1；重点是"变了"，
  不是"变了几次"。

写操作必须携带最近观察到的 generation，解析失败的稳定 code 是：

| code | 含义 |
|---|---|
| `uiTargetNotFound` | 该 ID 没有任何存活条目（从未声明，或 Key 已被 GC） |
| `uiTargetUnmounted` | 有条目但一个都没挂载 |
| `uiTargetAmbiguous` | 同时挂载了多个同 ID 实例 |
| `uiGenerationStale` | 号对不上，`details.currentGeneration` 给出当前值 |
| `uiOperationUnavailable` | 目标挂载了，但不支持这个 operation（如 text 目标的 Widget 不是 `TextField`/`EditableText`，或 capture 目标的 render object 不是现成的 `RenderRepaintBoundary`） |

gate 中发生 `await` 后，operator 会**再解析一次** ID、generation 和歧义状态，所以门后发生的
重挂载或新出现的重名实例同样拿不到这次调用的续程。页面退出后针对旧实例的迟到命令因此稳定被拒，
不会写入后来出现的同名控件。

### 陷阱：`build()` 内裸构造 Key 会重挂载丢状态

```dart
// ❌ 每次 build 造一个新 GlobalKey
@override
Widget build(BuildContext context) {
  return TextField(key: PatchbayKey.text('login.phone'), controller: _controller);
}
```

`PatchbayKey` 是 `GlobalKey`，Flutter 按 Key **实例身份**决定复用还是重建。每帧换一个新实例，
等于每帧告诉 Flutter"这是另一个控件"，代价是三重的：

1. **丢状态**——旧 `Element`/`State` 被销毁重建，输入焦点、滚动位置、动画进度一并丢失；
2. **generation 每次观察都在跳**——你刚从 catalog 读到的号，下一次解析时已经过期，
   写操作稳定以 `uiGenerationStale` 被拒，看上去像"围栏坏了"，其实是 Key 在漂；
3. **registry 条目堆积**——每次构造都新增一条，只能等 GC 清。

正确做法是把实例缓存住，让它跨 build 稳定：

```dart
// ✅ State 字段：一个 State 实例一个 Key
class _LoginFormState extends State<LoginForm> {
  late final PatchbayKey _phoneKey = PatchbayKey.text('login.phone');

  @override
  Widget build(BuildContext context) =>
      TextField(key: _phoneKey, controller: _controller);
}
```

`StatelessWidget` 同理：Key 要放在外层 `State`、注入的 controller，或一张模块级常量表里，
**不能放在 `build()` 里**。这条对每一个 `GlobalKey` 都成立，不是 Patchbay 特有的规则；
但因为 Patchbay 的代际围栏会把它变成一串看不懂的 `uiGenerationStale`，这里显式写明。

### 怎么确认目标已经挂载

页面切换或一次动作之后要确认控件出现了，走哪条路取决于你标的是哪种 ID——**这是两个互不相通的
身份空间**：

| 标注方式 | 查挂载的方式 |
|---|---|
| `PatchbayKey.text/capture('id')` | 读 `patchbay catalog`，看 `uiTargets` 里该 ID 的 `mounted` / `generation` |
| `Semantics(identifier: 'id')` | `patchbay ui wait semantics-mounted <identifier>`（长轮询，自 `patchbay-v0.1.0` 起提供） |

`PatchbayKey` 只替换 Widget 的 `key`，**不会**顺带写 Semantics `identifier`；反过来
`ui wait semantics-mounted` 走的是 Semantics 树遍历，看不到只标了 `PatchbayKey` 的目标。
需要"等它出现再操作"的控件，标 Semantics `identifier`（或两个都标）。

`ui wait` 的完整条件表、CLI 子命令与 wire 值的对应关系见
[使用指南的 `ui wait` 一节](../../docs/guide.md#ui-wait-的-condition-名)。

### requestId

通过 `PatchbayFlutterServiceHost` 调用时，text 与 Semantics operator 会沿用 transport 传入的
`requestId`；bridge 只在被直接调用且调用方未提供 ID 时生成本地 ID。这样日志、CLI 输出和 invocation
信封可以稳定关联到同一次请求。

## 文本语义

当前支持两种不同语义：

- `text.set`：直接替换 `TextEditingController.value`，不调用 formatter 和 `onChanged`；适合准备状态；
- `text.enter`：按顺序执行目标的 `inputFormatters`，写回 controller 后调用公开 `onChanged`；适合模拟
  一次 Flutter 层用户输入。

两者都只证明 Flutter target 接受并观测到值变化，不证明 IME、软键盘 UI 或系统输入法行为。

敏感 target 必须声明 `sensitive: true`。这类输入只接受 CLI stdin，catalog 和结果只返回长度及
redacted 标记，不回显明文。

## Runtime observation

Widget 与 Semantics 树不要求 consumer 包一层 root。Flutter host 可以通过公开 binding、Inspector 和
Semantics API 读取当前树；Semantics action 由 consumer 在 composition root 注入一次 policy，默认拒绝。

标准组件已有 label、flags 与 action 时不需要 `PatchbayKey`。例如一个带 `button + label + tap` 的底部
Tab 可以直接从 Semantics 快照发现并执行原 callback，完整复用 Widget 自身的退出与切换流程。

控件带稳定 Semantics identifier 时，`ui.semantics.tap` 把「解析 → 代际校验 → 派发」收进一次受理：
调用方不必先读整棵树，再搬运只在当前 SemanticsOwner 内有效的 `nodeId`。围栏没有因此变松——bridge
在过门前 pin 住解析到的 generation，门后二次解析必须命中同一 generation，await 期间发生重挂载仍以
`uiSemanticsGenerationStale` 拒绝；调用方另可传 `generation` 做自己的前置围栏。同 identifier 多个
mounted 实例一律歧义拒绝，不按树顺序选。

该命令与 `ui.semantics.action` 共用同一个 action policy：没有 consumer policy 时它不进 catalog、
也不可派发。未命中、多义与代际过期都带 details（已挂载 identifier 清单上限 20 条、候选列表、
expected/current generation），obscured 节点的 label 在 details 中脱敏——拒绝要可行动，但不能变成
第二个绕过树上限的观察面。

详细协议、隐私边界和分批退出条件见
[`doc/ui-inspection-and-actions.md`](doc/ui-inspection-and-actions.md)。

## Optional root bridge 与 capture

需要全局 Flutter 观察时，允许 consumer 在 `MaterialApp.builder` 最上层包一次 root bridge：

```dart
MaterialApp.router(
  builder: (context, child) => PatchbayRoot(child: child!),
)
```

root bridge 只负责确实需要根渲染上下文的截图与帧调度。它不负责 Widget/Semantics 树发现，不登记
业务页面，不把所有后代自动变成可操作 target，也不在 release 改变布局；release 构建直接返回原
`child`，不保留运行时重新开启入口。

默认路径是 root capture。确需局部截图时，可把现有 `RenderRepaintBoundary` 的 key 换成
`PatchbayKey.capture('stable.id')`；Key 只负责稳定定位与 generation fencing，**不会**把任意 Widget
变成 repaint boundary。目标不是唯一、未挂载、generation 过期或 render object 不是现成 boundary 时
一律 fail-closed。

根截图只证明 Flutter 合成树在该帧产生了这些像素。`PlatformView`、texture、系统弹窗和其他 App
可能不在图像中，结果固定返回 `flutterSubtreeOnly`、`platformViewsMayBeMissing`、
`systemUiNotIncluded` warning，不能冒充完整物理屏幕截图。capture 等待下一帧，调用前、gate await 后及
编码前复核 resumed/target；默认限制 16 MP、8 MiB PNG、pixelRatio 不超过 3。PNG 只进入共享 blob
store，响应返回尺寸、ratio、SHA-256、TTL 和 blobId，大字节不塞进单个 service-extension 响应。

## 语义导航

导航不应通过给首页、设置按钮加 Key 后模拟点击完成。推荐在 App 组合根注入一个 consumer adapter，
协议只暴露稳定 destination ID：

```text
navigation.catalog
navigation.current
navigation.go <destination-id>
navigation.push <destination-id>
navigation.back
```

这里使用 destination 而不是 route：一个 consumer 的目标可能是 Router route、Shell tab、overlay 或
dialog。差异只存在于 consumer adapter，通用 CLI 不认识路径和页面实现。

```dart
final navigation = PatchbayNavigationAdapter(
  destinations: () => <PatchbayNavigationDestination>[
    PatchbayNavigationDestination(
      id: 'settings',
      gateIds: <String>{'debug.navigation'},
      go: () => shellController.select(settingsTab),
      push: () => router.pushNamed('settings'),
    ),
  ],
  current: () => PatchbayNavigationObservation(
    revision: navigationRevision,
    destinationId: settledDestinationId,
  ),
  back: router.pop,
);
```

低侵入约束：

- App 顶层只接一个 navigation adapter；
- 每个 destination 只在中央 catalog 登记一行，不修改目标页面；
- Router route 使用现有 router，Shell tab 使用一个注入式 controller；
- 不接受任意 route 字符串，不暴露 consumer 的真实 path；
- 不绕过登录、隐私同意、startup redirect 或业务 route guard。

调用 router/controller 返回只代表导航请求已发出。只有 observer 确认当前 destination，并等待下一帧
完成后，结果才能标为 `uiObserved`。被 redirect、超时、后台化或 revision 失效必须稳定拒绝。

导航命令串行化并携带 navigation revision，避免迟到的 `back`/`go` 操作新的页面栈。需要声明
“页面已展示”的操作应要求 App lifecycle 为 `resumed`；后台或熄屏时最多报告路由状态变化。

`navigation.catalog` 和 `navigation.current` 是只读命令。`go`、`push`、`back` 必须携带调用方刚观察到的
`revision`，可选 `timeoutMs` 默认 5000。consumer callback 返回只代表请求已交给既有 router/controller；
bridge 继续观察 settled destination，并在下一帧复核后才返回 `outcome=arrived`、`source=uiObserved`。

consumer observer 必须只发布已经 settled 的 destination，并在 settled destination 变化时单调增加
revision。请求被业务 guard 改写到其他 settled destination 时返回 `navigationRedirected`；此外稳定拒绝码
包括 `navigationTimeout`、`navigationLifecycleNotResumed`、`navigationRevisionStale`、
`navigationDestinationAmbiguous`。gate 发生 await 后会重新解析 destination callback、歧义和 revision。

## ui.wait

`ui.wait` 是无副作用、有明确 `timeoutMs` 的长轮询调用，不把“开始等待”包装成完成。当前条件为：

- `semanticsMounted` / `semanticsUnmounted` / `semanticsValue`：只接受稳定、非空的 Semantics
  `identifier`，重复 identifier 返回 `uiSemanticsTargetAmbiguous`，obscured value 不可读取；
- `navigationDestination`：等待 cataloged destination，可选要求 navigation revision 必须前进；
- `treeRevision` / `frameRevision`：等待 revision 严格大于调用方基线。

成功结果统一为 `outcome=observed`、`source=uiObserved`，并返回该次可直接观测到的 revision/节点事实；
超时统一返回 `uiWaitTimeout` 和明确的 timeout/当前 revision 摘要。App 不在 resumed 时返回
`uiWaitLifecycleNotResumed`。

## 标准 operator 状态

新增 operator 时只使用公开 Flutter API，并由 runtime catalog 决定目标实际支持什么：

| Operator | 目标契约 | 失败策略 |
|---|---|---|
| `focus` | 唯一可聚焦目标 | 不可聚焦或歧义即拒绝 |
| `action.invoke` | 唯一公开 Semantics/Actions 动作 | 不退化到 label、类型或坐标猜测 |
| `scroll` | 唯一 ScrollableState | 返回操作前后 ScrollMetrics |
| `wait` | Semantics identifier、destination、tree/frame revision | 超时与歧义返回稳定 rejection |
| `capture` | root 或唯一 target RenderObject | 返回 warning、blob metadata 和 sha256 |

普通 `ValueKey`、Widget 文案、runtime type 和 Element 路径可以出现在只读摘要中，但不会自动成为稳定
可操作目标。

## UI 与领域能力分离

UI action 只证明 Flutter callback、controller 或 RenderObject 的直接结果。如果 action 最终调用网络、
文件、设备 SDK 或权限能力，真实 handler 仍必须经过 consumer 领域 gate、permit 和 generation。

Flutter bridge 不获取 consumer 的领域锁，也不提供绕过 controller 的快捷调用。对于复杂业务行为，
优先注册领域命令；Key 只负责验证 UI 接线和标准控件语义。

## Release 边界

- release 不注册 Flutter service host；
- registry、descriptor、operator 和 consumer callback 必须不可达；
- Key 类型、相等性和 State 保留语义保持不变；
- root bridge 在 release 只透传 child；
- 不提供运行时配置重新开启 Patchbay。
