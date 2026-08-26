# Flutter UI inspection 与 action 设计

本文冻结 Patchbay Flutter 的低侵入 UI 观察与交互契约。它描述通用 package 的能力边界，
不登记任何 consumer 页面、路由、文案或业务命令。

## 目标

Patchbay 在 App 已启动的前提下提供三层互补能力：

1. 读取 Flutter Widget 诊断树，排查装配、类型与属性关系；
2. 读取规范化 Semantics 树，发现当前可交互节点及其公开 action；
3. 对明确支持 action 的唯一 Semantics 节点执行 Flutter 层交互。

默认路径不要求页面容器、不要求逐控件 Key，也不要求 consumer 提供路由表。`PatchbayKey` 只用于
消歧、敏感目标、缺少 Semantics 的自定义控件和需要长期稳定身份的脚本锚点。

本文不覆盖系统权限弹窗、软键盘 UI、其他 App、PlatformView 内部节点或物理屏幕级输入注入。

## 三棵树的职责

| 观察面 | 主要用途 | 稳定性承诺 |
|---|---|---|
| Widget / Element | 类型、Key、父子装配、诊断属性 | 复用 Flutter Inspector；schema 随 Flutter SDK，属于诊断面 |
| Render | 尺寸、位置、可见性、截图边界 | Patchbay 只输出规范化摘要；不把像素推导成业务状态 |
| Semantics | label、value、flags、公开 action、滚动指标 | Patchbay 提供稳定 schema，是默认交互面 |

Flutter debug 构建已有 Inspector service extension。CLI 可以在运行时发现并读取它，不复制 DevTools
协议，也不把 Flutter SDK 的诊断 object ID 当成 Patchbay 稳定身份。profile 构建不保证 Inspector
extension 存在，因此稳定自动化不能只依赖该扩展。

Semantics 观察由 `patchbay_flutter` 使用公开 Flutter API 建立。host 启动时持有一个
`SemanticsHandle`，停止时释放；不需要在 `MaterialApp.builder` 外再包一层 Widget。可选 root bridge
只用于根截图、帧协调等确实需要根渲染上下文的能力。

## Semantics 快照

稳定快照使用扁平节点表，避免深树 JSON 难以增量处理：

```json
{
  "source": "uiObserved",
  "treeRevision": 7,
  "rootNodeId": 0,
  "truncated": false,
  "nodes": [
    {
      "nodeId": 42,
      "generation": 3,
      "parentNodeId": 0,
      "depth": 1,
      "identifier": "",
      "label": "设置",
      "value": "",
      "flags": ["isButton"],
      "actions": ["tap"],
      "rect": {"left": 268.0, "top": 742.0, "width": 91.0, "height": 52.0},
      "children": []
    }
  ]
}
```

约束：

- `nodeId` 是 Flutter 当前 SemanticsOwner 内的瞬时 ID，不是跨挂载稳定身份；
- bridge 按 `SemanticsNode` 对象身份维护单调 `generation`；同 ID 绑定新对象时 generation 增长；
- 需要被稳定执行的 `identifier` 必须与目标 action 落在同一个 Semantics 节点；仅给按钮外层观察节点加
  identifier 会形成“可定位但不可操作”的空 action 节点。低侵入 wrapper 应合并子节点语义并在同层
  公开 label、role 与 callback，不能靠 CLI 猜它的可点击子节点；
- action 必须携带最近快照返回的 `nodeId + generation`；
- gate 中发生 await 后必须重新遍历当前树，复核对象身份、generation 和 action 仍可用；
- label、runtime type、树路径与坐标只能查询，不能单独充当执行身份；
- `rect` 使用节点本地坐标系；存在变换时同时返回 `transformToParent`，不能把本地矩形冒充屏幕坐标；
- 默认限制节点数与深度，截断必须返回 `truncated=true` 和实际计数；
- `isObscured` 节点不返回原始 value；consumer 可注入更严格的观察脱敏策略；
- detached、不可见、用户 action 被阻断或 action 不唯一时 fail-closed。

`treeRevision` 在 SemanticsOwner 更新后单调增长，供观察者判断树是否变化；它不替代节点 generation。

## Action 执行

当前支持 Flutter 已公开且参数能够稳定表达的标准 action：

- `tap`、`longPress`；
- `focus`、`dismiss`、`showOnScreen`；
- `scrollUp`、`scrollDown`、`scrollLeft`、`scrollRight`；
- `increase`、`decrease`、`expand`、`collapse`；
- `setText`，文本只能通过显式参数传入，敏感输入必须来自 stdin。

`setSelection`、剪贴板、custom action、任意屏幕坐标和 `scrollToOffset` 当前不支持。它们的参数、
隐私或跨 SDK 语义未冻结，不能用无类型 JSON 猜测补齐。锚定式指针手势走下述独立命令与 policy，
不属于 Semantics action。

### 按 identifier 直接 tap

`ui.semantics.tap` 用稳定 Semantics identifier 在一次受理内完成解析、代际校验与派发，取代
`ui.semantics.tree` + `ui.semantics.action` 两跳。它不是新的定位方式：identifier 已经是本文冻结的
稳定身份，label、树路径和坐标仍然不能充当执行身份。

约束（与两跳路径同源，不因为省了一跳而放宽）：

- 解析出的 generation 在过门前被 pin；门 await 之后必须重新遍历当前树并命中同一 generation，
  否则以 `uiSemanticsGenerationStale` 拒绝。调用方可另外传入 `generation` 作为前置围栏；
- 同 identifier 多个 mounted 节点一律 `uiSemanticsIdentifierAmbiguous`，不按树顺序选；
- 节点 detached、不可见、user action 被阻断或没有 `tap` action 时 fail-closed；
- 三类拒绝都必须带 details——未命中给出已挂载 identifier 清单（上限 20 条，超出标记截断）、
  多义给出候选摘要、代际过期给出 expected/current。空拒绝会把调用方推回它本来要省掉的全树 dump；
- details 中 obscured 节点的 label 脱敏，且 details 不得成为绕过快照节点上限的第二个观察面；
- 与 `ui.semantics.action` 共用同一个 `PatchbaySemanticsActionPolicy`：没有注入 policy 时该命令
  不出现在 catalog，也不可派发。

结果同样只声明 `dispatched`，不冒充页面或领域完成。

### 按 identifier 派发通用 action

`ui.semantics.actionByIdentifier` 把同一安全原语扩展到公开的 tap、focus、四向 scroll 与 setText；CLI
canonical path 是 `ui action <identifier> <generation> <action> [text]`。generation 必填，先在首次解析时
核对，再 pin 过 policy/gate await，派发前按同一 identifier 与 generation 二次解析。缺失或过期、同名
多节点、unknown key 与未公开 action 都 fail-closed；不接受 `latest`，也不自动重取或重放写操作。

setText 仅在 action 为 `setText` 时接收 text；敏感输入继续要求 `--stdin`，响应只给 length/redaction，
从不回显原文。旧 `ui tap` 与 nodeId `ui semantics action` 的命令、JSON 和失败码保持不变。

### 锚定式 press-hold / drag / fling

`ui.gesture.pressHold|drag|fling` 先按稳定 Semantics `identifier` 找到唯一节点，并要求调用方携带该
节点的 `generation`。起点、drag path 和 fling velocity 都以目标边界归一化；bridge 只在单次调用
内部把它们换算成当前 view 的逻辑像素并合成 pointer event，换算后的坐标不进入响应、日志或轨迹。

手势使用独立 `PatchbayGesturePolicy`。没有注入 policy 时三条命令都不进 catalog；policy 可附加 gate，
也只能把 30 秒、64 点、20 倍目标尺寸/秒的固定上限继续收紧。门后会再次按 identifier 解析并核对同一
generation，再执行生命周期、paint clip 和当前 hit-test 遮挡检查。真实 overlay、裁剪区域和不可映射的
render anchor 均以 `uiGestureTargetObscured` fail-closed；custom paint、translucent hit behavior 与
不拦截指针的 `IgnorePointer` 装饰层不会因此误拒。

手势开始后不逐帧重解析。布局变化只在终态 payload 以 `layoutChangedDuringGesture` 报告；
`outcome=dispatched` 仅证明 Flutter 收到了完整指针序列，业务完成仍需 snapshot、manifest 或 capture
另行验证。

Semantics action 是“沿 Flutter 已公开辅助功能 action 分派了一次”，不是业务成功：

- admission accepted 不等于 callback 产生的网络、文件或设备动作完成；
- 返回 `outcome=dispatched`、操作前后 tree revision 和 `source=uiObserved`；
- 无法证明页面已切换时不得返回 `applied` 或 `completed`；
- consumer 需要稳定页面终态时，使用 navigation destination observer 或 `ui.wait`。

## 门与 action policy

只读 Widget/Semantics 观察经过 Patchbay 基础门。任意 Semantics action 额外经过 consumer 注入的
`PatchbaySemanticsActionPolicy`：

- 默认 policy 是 deny，因此只启动 host 不会获得全局点击能力；
- policy 根据节点摘要与 action 返回允许/拒绝、gate ID 集合和敏感策略；
- bridge 固定要求 App lifecycle 为 `resumed`；后台或熄屏时不执行 action；
- consumer gate 仍由 `PatchbayGateEvaluator` 逐次求值；
- action 触发的领域 handler 仍拥有自己的 permit、generation、权限和并发账本；
- policy 不能把系统 UI 或外部设备结果声明成 Flutter action 的完成事实。

consumer 可以用一个保守的全局 UI interaction gate 开始接入，无须逐页面登记；高风险或敏感节点应
通过 Semantics identifier、`PatchbayKey` declaration 或 consumer policy 细分。

## 设备端 inspector 选择模式（`ui.inspect.*`）

`ui.inspect.select` 开关的是 Flutter 自带的设备端 widget inspector 选择模式——三棵树是**观察**，
这一条是**改 App 状态**：模式开着时设备上的点按被 inspector 消费，不再抵达 App。因此它按
`sideEffect: appState` 声明，并且是 Patchbay 里唯一一条会自己撤销自己的命令。

- **默认关。** consumer 不注入 `PatchbayInspectPolicy` 时两条命令不进 catalog，调用得
  `commandNotRegistered`——与 action policy 同一口径；
- **每次启用带租约。** 两条传输都是请求/响应，App 侧观察不到断连，所以「断开还原」只能表达成
  「静默还原」：租约到期无人续约即回退。续约不改写基线，`dispose()` 同样回退；
- **还原是有条件的。** 只在开关仍为 Patchbay 装上去的值时回退，避免掀掉 DevTools 期间拨的开关；
  显式 `off` 则是操作者指令，即使基线为开也照关；
- **构建不支持就拒绝，不返回布尔。** overlay 由 `WidgetsApp` 在 `assert` 内注入，仅 debug 成立；
  profile / release 下标志位可写可读却永不渲染。桥先判 `notDebugBuild` /
  `rootInspectorExcluded`，命中即 `inspectorUnavailable`，**不写标志位、不问 consumer gate**；
- **销毁后不得复活。** gate 恢复点重查一次 disposed：请求卡在 gate 里等待时 host 被销毁，返回后
  若继续开启，会留下一个开着的 inspector 和无人持有的租约，设备从此吞掉每一次点击。已销毁即以
  `inspectorUnavailable` / `hostDisposed` 拒绝且不碰标志位；销毁后再发的调用（含只读的 `status`）
  同样——一座已拆掉的桥没有状态可报；
- **事实来源恒为 `appRecorded`。** 写标志位只排了一次重建，不是「带 overlay 的那帧到过屏幕」，
  不冒充 `uiObserved`；`selectionOnTap` 一并报出，区分 App 侧那个独立开关；
- **不发 DevTools 的 extension state 事件。** 两边写同一标志位，但 DevTools 的按钮不会跟着亮，
  以 `ui.inspect.status` 为准。

`ttlMs` 只跟启用一起走：与 `enabled: false` 同发是 `invalidInspectArguments`，而不是被悄悄忽略；
超出 policy 的 `maxLease` 同样拒绝，`details.maxTtlMs` 给出上限。policy 声明的 `defaultLease`
就是 catalog 里 `ttlMs` 的 `default`，descriptor 与实现是同一个数。

## CLI 面

当前稳定命令：

```text
patchbay ui semantics tree
patchbay ui semantics action <node-id> <generation> <action>
patchbay ui semantics action <node-id> <generation> setText --stdin
patchbay ui action <identifier> <generation> <action> [text]
patchbay --stdin ui action <identifier> <generation> setText
patchbay ui tap <identifier>
patchbay ui tap <identifier> --generation <generation>
patchbay ui widget-tree
patchbay ui render-tree
patchbay ui focus-tree
patchbay ui inspect on [--ttl-ms <ms>]
patchbay ui inspect off
patchbay ui inspect status
```

`widget-tree`、`render-tree` 与 `focus-tree` 是 Flutter 诊断扩展的只读代理：CLI 必须先检查当前 isolate
实际注册的 extension，不存在就返回 capability unavailable，不能伪造空树。输出明确标记 Flutter SDK
版本与 passthrough schema，不承诺跨 SDK 字段稳定。

典型探索流程：

```text
ui semantics tree
  -> 从当前树筛出 label=设置 且 actions 唯一包含 tap 的节点
  -> 使用该节点的 nodeId + generation 执行 tap
  -> 再取 semantics/widget tree 验证设置内容已出现
```

控件已有稳定 identifier 时，探索阶段之后的重复执行走一步式：

```text
ui tap app.settings.entry
  -> 再取 semantics/widget tree 验证设置内容已出现
```

这条路径会调用目标 Widget 原有的 action callback。因此 Shell tab、抽屉或按钮已有正确 teardown 时，
Patchbay 不另建状态机，也不绕过它。

## 与语义导航的关系

树驱动 action 是默认低侵入路径，适合“从当前画面找到设置并点击”。navigation adapter 是增强层，
仅在以下情形需要：

- 目的地当前不在树上；
- 脚本需要独立于本地化文案和当前布局的稳定 destination ID；
- 需要 observer 明确证明 redirect 后的最终页面；
- 需要跨 Router、Shell tab、overlay 的统一导航目录。

navigation adapter 仍只在 composition root 接一次，复用 consumer 既有 router/controller；它不能成为
获取 Widget/Semantics 树的前置条件。

当前已实现的 adapter 只登记 destination ID、允许的 go/push callback、gate 与 settled observation；
back callback 由 adapter 顶层提供。所有写导航携带 revision 并串行化，gate await 后重新解析。callback
返回后还要由 observer 确认 destination 并等待下一帧，才能声明 `uiObserved`；redirect、timeout、后台和
stale revision 均以稳定 rejection 收尾。

`ui.wait` 当前支持稳定 Semantics identifier 的 mounted/unmounted/value、navigation destination、tree
revision 与 frame revision。它不使用 label、Widget path 或坐标作为身份；重复 identifier fail-closed，
obscured value 不读取，每次调用必须显式给出 timeout。

## Release 与平台边界

- release 不启动 Patchbay host，不持有 SemanticsHandle，不注册 action policy；
- release 不因 Patchbay 改变 Semantics、Element、RenderObject 或导航行为；
- Android、iOS、HarmonyOS/CPF 都只依赖 Flutter 公开 API，不新增原生 plugin；
- Inspector passthrough 是否存在由运行时 catalog 决定，profile 与不同 Flutter SDK 可返回 unavailable；
- 设备端 inspector 选择模式只在 debug 成立，profile / release 以 `inspectorUnavailable` 拒绝，
  不返回一个渲染不出任何东西的布尔；
- PlatformView 只作为边界节点报告，不能遍历其原生内部树；
- 系统权限弹窗不属于 Flutter 树，不在本 package 的能力范围内。

## 验收标准

以下清单描述能力对外发布时的验收标准，不等于当前仓库的完成度声明。除自动化测试外，还应在真实
iPhone 或 Android 的 debug/profile App 上用通用 CLI 完成闭环。
平台中性能力至少选一台真机；涉及平台差异或声称 Android/iOS 一致时两端都跑。只看到命令出现在 catalog、
只连通 VM Service、或只在 widget test 中派发 action，都不算该能力完成。

### A. 只读观察

- 规范化 Semantics 快照、节点上限、脱敏和 generation 完成；
- debug/profile Widget harness 都能读取标准按钮、文本框、滚动区；
- 不注入 action policy 时 catalog 不出现可执行语义 action；
- release 引用扫描确认 observer、handle 和 callback 不可达。
- 真机 CLI 能读取非空 Semantics tree，并与手机当前可见页面相互印证。

### B. 标准 action

- tap、scroll、focus、setText 至少各有一次正向与拒绝测试；
- gate await 后节点 remount、action 消失、重复/失效身份全部拒绝；
- action 结果只声明 dispatched，不冒充页面或领域完成；
- consumer 真实 Shell tab 通过 Semantics tap 切换，并复用其原 teardown 顺序。
- 真机从 action 前树定位节点，执行后读取新 revision/目标页面；旧 generation 必须稳定拒绝。

### C. DevTools 诊断代理

- debug isolate 可读取 Widget/Render/Focus tree；
- profile 中扩展缺失稳定返回 unavailable；
- object group 在读取后释放，连续调用不累计保活对象；
- Flutter SDK schema 与 Patchbay 稳定 Semantics schema 在输出中明确区分。
- 真机记录当前 build mode 下各诊断 extension 的真实可用性；空或 unavailable 不得包装成有效树。

### D. 稳定导航与等待

- destination catalog/current/go/push/back 与 `ui.wait` 已实现；
- observer、revision、串行化、redirect、歧义、后台化和超时语义已有 unit/widget 覆盖；
- 不倒灌为 A/B/C 的前置条件。
- 真机仍须至少完成一次 destination 到达与一次超时或 redirect 反向路径，完成前不宣称该能力已验收。
