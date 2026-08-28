# 0.6.0 UI 可达性与遮挡语义

> 状态：提案中
>
> 关联：PB-050-34、PB-050-35
>
> 设计闸门：DG-060-05

## 问题

同一浮层遮挡下，Semantics/pointer 点按按用户可达性拒绝，而注册文本 target 的 direct `setText` 仍应用；
`ui.reveal` 又把 mounted-but-obscured、identifier 不存在和无滚动容器合并成同一个拒绝。差异有实现理由，
但 descriptor/help 和稳定错误形状没有把理由表达出来，任务导向入口无法可靠解释失败。

## 目标与非目标

### 目标

- 冻结 direct-target 与 user-like action 的可达性分层。
- 为 reveal 区分遮挡、不存在与无授权滚动容器，给调用方正确恢复方向。
- 与 canonical UI 入口、gate pipeline、错误码 ratchet 和审计投影一致。

### 非目标

- 不让 direct text 操作伪装成真实用户触摸，不给它补坐标 hit-test。
- 不为任何 action 提供 ignoreOcclusion/force/bypass。
- 不改变 DG-050-09 五点采样口径或把 reveal 扩成通用导航。

## 契约

推荐裁决：注册 target 是 consumer 显式开放的 direct automation surface，`text.set/enter` 不以视觉遮挡作为
拒绝条件，但 descriptor/help 必须声明 `interactionModel: directTarget`；Semantics 与 pointer 保持
`interactionModel: userLike` 并执行遮挡准入。`ui.reveal` 在 identifier 已挂载且 obscured 时返回独立稳定码
`uiRevealTargetObscured`，identifier 不存在返回 `uiRevealTargetNotFound`，存在但没有显式授权滚动容器继续
返回 `uiRevealNoScrollableContainer`。最终码名与 details 封闭表待裁决。

## 状态、失败与预算

reveal 的可达性分类发生在滚动派发前，不消耗 step；被遮挡不尝试滚动穿透。details 只含稳定 reason、
identifier/generation 和必要状态，不含 rect、采样点或覆盖层身份。direct-target 成功仍只证明 controller
操作已应用，不升级成 pointer/device 事实。

## 兼容与降级

新增 reveal error code 是收紧且 additive；老 CLI 按既有 rejected 分类退出，不解析失败。新 CLI 面对老
host 仍可能收到合并码，必须标为 legacy ambiguous，不能自行猜遮挡。`interactionModel` 若进 descriptor wire，
老 reader 忽略；若只进 command docs，则不能承担机器路由事实。

## 安全与隐私

不提供 bypass；遮挡 details 不暴露坐标和覆盖层。direct-target 的差异必须在 help/descriptor 明示，避免
使用者把 applied 误读为用户真实可达或设备确认。

## 验证

- 单元/协议测试：三种 reveal 拒绝、direct-target 遮挡下应用、user-like 遮挡拒绝与 details 封闭表。
- VM/direct：新旧码、descriptor additive 字段与退出码一致。
- 接入方/真机：modal、部分遮挡、懒加载列表与真实文本 controller。
- 失败注入：门后浮层增删、target remount、identifier 拼错、无授权 container 和 policy 拒绝。

## 待裁决

- `interactionModel` 是否进入公共 descriptor wire；推荐进入，供 canonical CLI 与审计解释。
- 三个 reveal 稳定 code 的最终命名和 details 字段。
- mounted 但完全剪裁出 viewport 是否归 obscured、notReachable 还是 noScrollableContainer。
- PB-050-34/35 是否一份 Proposal 裁决、两个实现 MR交付；推荐是。

## 被否决方案

- 给 direct text 操作补 hit-test：把显式 controller 自动化错误伪装成用户触摸。
- 继续用一个 reveal 码承载三种事实：调用方无法选择正确恢复动作。
- 在 CLI 根据旧 host 的树输出猜遮挡：产生第二套可达性算法和 VM/direct 漂移。
