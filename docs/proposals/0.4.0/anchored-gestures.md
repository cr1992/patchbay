# 0.4.0 锚定式手势

> 状态：提案中
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

## 命令契约

统一命令族 `ui.gesture.pressHold|drag|fling`。共同字段：

- `identifier`：必填稳定 Semantics identifier；
- `generation`：必填，由读操作获得；
- `start`：目标边界内 `{x,y}`，各自范围 `[0,1]`；
- `durationMs`：正整数并受 host 上限夹紧；
- `path`：drag 专用，至少两个局部坐标点，每点可带相对时间；
- `velocity`：fling 专用，目标局部坐标系的方向和速率，受平台安全上限夹紧。

解析顺序固定为：查目标 → 歧义/挂载检查 → 基础门/声明门 → 再查目标 → generation 检查 → 将局部
坐标转换为当前全局坐标 → 注入手势。转换后的全局坐标只作为一次调用内的瞬时实现细节，不进入目录、
日志或可复用脚本。

## 状态、失败与预算

- 开始注入前失败均为 `admission: rejected`；开始后失败进入受理 payload，不改写成未受理。
- 稳定拒绝至少包括 `uiTargetNotFound`、`uiTargetAmbiguous`、`uiGenerationStale`、
  `uiGesturePointOutOfBounds`、`uiGestureBudgetExceeded`、`uiLifecycleNotResumed`。
- path 点数、总持续时间和速度有固定上限；取消只在手势注入器确认停止后报告 cancelled。
- 手势完成只证明框架完成注入，不证明业务状态变化；验证必须另读 snapshot/manifest/capture。

## 兼容与验证

- capability 未声明时新 CLI 类型化拒绝，不尝试降级为 adb 坐标。
- 共享 decoder/handler 位于 Flutter 桥，VM/direct 只负责传输同一 wire。
- widget 测试覆盖局部坐标转换、门等待期间换代、歧义、越界和嵌套滚动。
- Android/iOS 真机各覆盖普通滚动、嵌套滚动、方向盘按压态和可拖小窗中的适用路径。

## 待裁决

- fling 采用速度向量还是起止点 + duration 作为唯一公共表达。
- 手势过程中目标布局变化时立即取消，还是只保证开始前 generation 围栏。

## 被否决方案

- 暴露屏幕绝对坐标：无法跨设备复现并破坏 fail-closed。
- 复用 tree nodeId 作为长期身份：generation 变化后容易误击新节点。
