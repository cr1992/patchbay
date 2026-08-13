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

`setSelection`、剪贴板、custom action、坐标手势和 `scrollToOffset` 当前不支持。它们的参数、
隐私或跨 SDK 语义未冻结，不能用无类型 JSON 猜测补齐。

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

## CLI 面

当前稳定命令：

```text
patchbay ui semantics tree
patchbay ui semantics action <node-id> <generation> <action>
patchbay ui semantics action <node-id> <generation> setText --stdin
patchbay ui widget-tree
patchbay ui render-tree
patchbay ui focus-tree
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
