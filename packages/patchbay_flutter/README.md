# Patchbay Flutter

`patchbay_flutter` 是 Patchbay 的可选 Flutter adapter。它的目标是用最小 Widget 侵入提供稳定、
可发现、fail-closed 的 UI 调试能力，而不是实现一套坐标驱动的黑盒自动化框架。

通用协议和传输边界见 [`../patchbay/README.md`](../patchbay/README.md)。

## 当前实现

当前公共 API 已提供：

- `PatchbayKey.text`；
- 弱引用 `PatchbayUiRegistry`；
- mounted generation、重复 ID 歧义和 stale generation 拒绝；
- `text.set` 与 `text.enter`；
- 每操作 consumer gate、敏感输入和 side-effect descriptor；
- `PatchbayFlutterServiceHost`，把 UI catalog/operator 与领域 host 合并到同一 service extension。

当前尚未实现 `PatchbayRoot`、语义导航、tap、focus、scroll、wait、capture 和日志面。本文后半部分对
这些能力的描述是兼容方向，不是现有 API 使用说明。

## 低侵入分级

| 接入级别 | Consumer 改动 | 能力 |
|---|---|---|
| Host only | App 组合根启动 service host | identity、领域 catalog/snapshot/invoke；不承诺稳定 Widget 操作 |
| Optional root bridge | App 最上层包一次 root bridge（规划） | 根 Render/Semantics 摘要、帧等待和 Flutter 合成树截图 |
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

## 动态 target 与 generation

registry 不因为 Key 对象存在就宣称目标已挂载：

- catalog 只根据当前 `Element` 生成 mounted 状态；
- 同一个稳定 ID 每次挂载到新 Element 都获得更大的 generation；
- 同一 ID 同时挂载多次时标记 `ambiguous`，不暴露可执行 operation；
- 调用必须携带 catalog 返回的 generation；
- gate 中发生 `await` 后，operator 再解析一次 ID、generation 和歧义状态。

因此页面退出后，针对旧实例的迟到命令会以 `uiTargetNotFound`、`uiTargetUnmounted` 或
`uiGenerationStale` 拒绝，不会写入后来出现的同名控件。

## 文本语义

当前支持两种不同语义：

- `text.set`：直接替换 `TextEditingController.value`，不调用 formatter 和 `onChanged`；适合准备状态；
- `text.enter`：按顺序执行目标的 `inputFormatters`，写回 controller 后调用公开 `onChanged`；适合模拟
  一次 Flutter 层用户输入。

两者都只证明 Flutter target 接受并观测到值变化，不证明 IME、软键盘 UI 或系统输入法行为。

敏感 target 必须声明 `sensitive: true`。这类输入只接受 CLI stdin，catalog 和结果只返回长度及
redacted 标记，不回显明文。

## Optional root bridge（规划）

需要全局 Flutter 观察时，允许 consumer 在 `MaterialApp.builder` 最上层包一次 root bridge：

```dart
MaterialApp.router(
  builder: (context, child) => PatchbayRoot(child: child!),
)
```

root bridge 只负责持有根 context、帧调度、根 RenderObject 和 SemanticsOwner。它不登记业务页面，
不把所有后代自动变成可操作 target，也不在 release 改变布局。

根截图只证明 Flutter 合成树在该帧产生了这些像素。`PlatformView`、texture、系统弹窗和其他 App
可能不在图像中，capture 必须返回 capability warning，不能冒充完整物理屏幕截图。

## 语义导航（规划）

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
// 设计示例，不是当前公共 API。
PatchbayDestination(
  id: 'settings',
  gateIds: <String>{'debug.navigation'},
  navigate: () => shellController.select(settingsTab),
  observe: () => shellController.current == settingsTab,
)
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

## 后续标准 operator

新增 operator 时只使用公开 Flutter API，并由 runtime catalog 决定目标实际支持什么：

| Operator | 目标契约 | 失败策略 |
|---|---|---|
| `focus` | 唯一可聚焦目标 | 不可聚焦或歧义即拒绝 |
| `action.invoke` | 唯一公开 Semantics/Actions 动作 | 不退化到 label、类型或坐标猜测 |
| `scroll` | 唯一 ScrollableState | 返回操作前后 ScrollMetrics |
| `wait` | mounted/value/semantics/frame 条件 | 超时返回稳定 rejection |
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
