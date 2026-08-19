# 0.4.0 锚定式手势

> 状态：已接受
>
> 关联：PB-040-01
>
> 设计闸门：DG-040-01、DG-040-04

## 问题

长按、拖动和 fling 只能退回 adb 绝对坐标，无法复用 Patchbay 的 identifier、歧义拒绝和 generation
围栏。绝对屏幕坐标会随分辨率、窗口和布局变化误击，也绕开已建立的低侵入 UI 边界。

## 目标与非目标

- 所有写手势先解析稳定 identifier，再使用目标局部的归一化坐标。
- 支持 press-hold、分段 drag 和 fling，VM/direct 语义一致。
- 门等待后重解析目标并核对 generation；目标歧义、卸载或换代均 fail-closed。
- 不接受屏幕绝对坐标、文案、树路径或 node 顺序作为写目标。
- 不承诺 OS 合成层、系统手势区或 App 外部表面的自动化。

## 手势是什么，不是什么

`ui.gesture.*` 产生的是**合成指针事件序列**，不是 Semantics action。这条必须先冻结，因为仓内已经
有一族 Semantics 动作（`longPress`、`scrollUp|Down|Left|Right`），它们走无障碍派发通道，只对声明了
对应 action 的 widget 生效。本条目的动机场景——方向盘按压态、可拖小窗——恰恰是那条通道打不到的。

两族命令并存，语义与证据强度都不同：Semantics 动作证明“框架派发了一个无障碍动作”，手势证明
“框架收到了指针”。两者都不证明业务状态变化。

具体注入 API 由实现阶段验证后确定，本提案不冻结；冻结的是上面这条性质，以及下面的锚定、围栏和
坐标不外泄三条约束。

## 命令契约

统一命令族 `ui.gesture.pressHold|drag|fling`。共同字段：

- `identifier`：必填稳定 Semantics identifier；
- `generation`：必填，取 **Semantics 节点代际**（与 `ui.semantics.tap` 的 `expectedGeneration` 同源，
  不是 catalog `uiTargets` 那个代际——两者是不同命名空间的不同计数）。与 tap 不同的是这里必填：
  写手势比 tap 危险，fling 甩出后也没有第二次确认的机会，所以不接受“先看看现在挂着什么”的调用；
- `start`：目标边界内 `{x,y}`，各自范围 `[0,1]`；
- `durationMs`：正整数；press-hold 默认 500 ms、drag 默认 300 ms、fling 默认 100 ms，三者合法范围
  均为 `1..30000`；
- `path`：drag 专用，包含 `2..64` 个局部坐标点，每点可带相对时间且时间必须单调；
- `velocity`：fling 专用，以“目标宽/高每秒”为各轴单位，向量长度必须大于 0 且不超过 20；这样预算
  随目标尺寸缩放，不退化成设备像素速度。

解析顺序固定为：查目标 → 歧义/挂载检查 → 基础门/声明门 → 再查目标 → generation 检查 → 遮挡检查
→ 将局部坐标转换为当前全局坐标 → 注入手势。

**转换后的全局坐标是一次调用内的瞬时实现细节**：不进入目录、日志、可复用脚本，也不进入 Debug
Trace 的事件 payload（`ui.gesture.*` 在轨迹里只留局部坐标与 generation）。这条是「不做坐标定位」
这条红线在本版唯一会被侵蚀的地方——一旦全局坐标被持久化，未来任何回放能力都天然有了一个绝对
坐标入口，红线就只剩字面。

## 门与策略

手势不复用 Semantics 动作的 policy 枚举。老接入方的 `(target, action) -> decision` 回调是对着 tap 和
setText 写的，往那个枚举加值会让它们的默认分支替新手势做决定——结果是 App 只是升级了 patchbay，
就突然可以被拖拽。所以手势走**独立的 gesture policy**，未提供即命令不进目录，与 `actionPolicy` 缺席
时 Semantics 动作不进目录同构。

不得向 `PatchbayUiTargetDescriptorWire` 增加字段：已发布客户端严格解码该类型，加字段会让它们读
catalog 时当场 `FormatException`。目标侧需要暴露的手势能力走既有 `operations` 字符串列表。

## 状态、失败与预算

- 开始注入前失败均为 `admission: rejected`；开始后失败进入受理 payload，不改写成未受理。
- 稳定拒绝至少包括 `uiTargetNotFound`、`uiTargetAmbiguous`、`uiGenerationStale`、
  `uiGesturePointOutOfBounds`、`uiGestureTargetObscured`、`uiGestureBudgetExceeded`、
  `uiLifecycleNotResumed`。
- path 点数、持续时间和速度使用命令契约中的固定上限；接入方只能收紧。取消只在手势注入器确认停止
  后报告 cancelled。
- 手势完成只证明框架完成注入，不证明业务状态变化；验证必须另读 snapshot/manifest/capture。
- 手势进行中目标布局变化**不中途取消**：只保证开始前的代际围栏，并在终态报告
  `layoutChangedDuringGesture: true`。逐帧重解析的代价与收益不匹配，而一个被截断的手势留下的设备
  状态比一个完整手势更难解释。

### 遮挡：冻结行为契约，算法由实现举证

目标可能被滚动裁剪、被 overlay 或被系统弹窗盖住。此时注入指针会打到别的东西上，所以**遮挡必须
fail-closed**，稳定 code 为 `uiGestureTargetObscured`。这一条与 PB-040-26 的系统弹窗遮挡是同一个失败
面，两份提案共用该 code；分工是：App 内可观测的遮挡报这一个，外部 driver 观测到的系统窗口报
`systemUiUnexpected`，两者可同时出现，轨迹里要能看出先后。

**判定算法不是公共契约。** “hit-test 最顶命中必须落在目标子树内”这条朴素规则会误拒 custom paint、
`HitTestBehavior.translucent` 和 `IgnorePointer` 的合法用法。实现 MR 必须提交覆盖这三种用法的可行性
证据，并证明所选算法满足上述 fail-closed 契约；如果做不到，应停止实现并把 Proposal 重新改回“提案中”，
不能以放宽遮挡语义换取合入。

## 兼容与验证

- capability 未声明时新 CLI 类型化拒绝，不尝试降级为 adb 坐标。
- 共享 decoder/handler 位于 Flutter 桥，VM/direct 只负责传输同一 wire。
- widget 测试覆盖局部坐标转换、门等待期间换代、歧义、越界和嵌套滚动的内外层归属。
- 遮挡先出可行性结论（含 custom paint、`HitTestBehavior.translucent`、`IgnorePointer` 三种合法用法的
  误拒检查），再补 `uiGestureTargetObscured` 的正反用例。
- 断言未提供 gesture policy 的接入方目录里没有 `ui.gesture.*`。
- 断言转换后的全局坐标不出现在响应 payload、日志与 trace 事件中。
- Android/iOS 真机上的 example 预检各覆盖普通滚动与锚定后的 press-hold / drag / fling；嵌套滚动与真实
  业务控件（按压态、可拖浮层）中的适用路径由接入方补充，发布判据见
  [版本计划 SC-040-01](../../releases/0.4.0.md#范围变更记录)。

## 被否决方案

- 暴露屏幕绝对坐标：无法跨设备复现并破坏 fail-closed。
- 复用 tree nodeId 作为长期身份：generation 变化后容易误击新节点。
- 用 Semantics action 表达 press-hold / drag / fling：只对声明了对应 action 的 widget 生效，打不到本
  条目的动机场景。
- 往既有 Semantics 动作枚举里加手势值：老接入方的 policy 默认分支会替新手势做决定。
- fling 用起止点 + duration 表达：表达不了甩出后的惯性，与平台 fling 语义不符；采用速度向量。
- 手势中途因布局变化立即取消：需逐帧重解析，且半截手势的设备状态更难解释。
