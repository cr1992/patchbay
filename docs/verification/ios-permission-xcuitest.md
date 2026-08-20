# iOS XCUITest 权限真机验证

> 日期：2026-08-20
>
> 结论：真实接入方 App 的 iPhone 真机已打通 camera、microphone、locationWhenInUse 的
> `reset → App 触发 → XCUITest 处理系统弹窗 → Patchbay 恢复`。报告只保留中性结论，不记录接入方、
> bundle、设备、签名身份或业务 payload。

## 验证对象与约束

- App 以 debug 构建运行，通过真实 patchbay session 连接；系统权限请求由 App 自己的 debug/domain 命令
  发起，Patchbay 不在 App 内越权请求权限。
- 外部 runner 使用 XCTest 公共 `XCUIProtectedResource` 与 SpringBoard accessibility tree；不使用坐标、
  OCR、截图识别或私有 API。
- runner 由本机 Xcode 自动签名后 `build-for-testing`，CLI 通过签名 `.xctestrun` 执行
  `test-without-building`。
- 设备系统语言为中文，验证命中了中文 permission identity 与 decision matcher。
- 关闭 iPhone 镜像、直接解锁并观察真机后，重复完成 microphone allow 与 locationWhenInUse allowOnce；
  两条仍返回 `uiObserved` 和 `recovery.state: ready`，证明操作目标是设备端 SpringBoard，不依赖 Mac 镜像 UI。

## 真机矩阵

| 权限 | 初始动作 | decision | runner 事实 | 恢复结果 |
|---|---|---|---|---|
| microphone | reset → `notDetermined` | allow | `granted` / `uiObserved` | resumed；同一 App 实例 |
| microphone | reset → `notDetermined` | deny | `denied` / `uiObserved`；App 权限 API 独立读回拒绝 | resumed；随后再次 reset/allow 恢复为 granted |
| camera | reset → `notDetermined` | allow | `granted` / `uiObserved` | resumed；同一 App 实例 |
| locationWhenInUse | reset → `notDetermined` | allowOnce | `allowOnce` / `uiObserved` | resumed；同一 App 实例 |

capability 真机探测只发布 runner 实际声明的动作：camera/microphone 为 reset + allow/deny，
locationWhenInUse 另含 allowOnce；notifications 不发布 reset。

## 未宣称全绿的路径

- **物理真机 status/normalize**：iOS 没有面向任意 App 的公开通用授权查询/grant API；保持
  `permissionUnsupported`，不把 XCTest 命令退出 0 当设备事实。
- **notifications 端到端**：XCTest 没有 notifications reset resource，本轮接入方也没有通知权限请求入口。
  runner 可处理已经出现且身份匹配的通知弹窗，但没有可重复初始态与真实 App 触发证据，不计为已验证。
- **其他系统语言**：0.4.0 只发布英语、简体中文和繁体中文 matcher；其他语言 capability fail-closed。
- **reset 后 debug attach**：真机 `resetAuthorizationStatus(for:)` 会终止被试 App；本轮仓库 launcher 能识别
  断连但没有自动拉起新的 debug isolate，需要重新执行接入方官方 run/attach 工具。重新附加后 exercise
  阶段可恢复到同一 App 实例；0.4.0 不把 reset 的进程重启写成无感恢复。

## 回归证据

- XCUITest 工程可在 Simulator build-for-testing。
- Dart wrapper 单测覆盖参数注入、稳定 JSON、缺少签名产物拒绝，以及复制 `.xctestrun` 后把相对
  `__TESTROOT__` 解析回原 build products 的回归。
- iOS adapter 单测覆盖 Simulator/物理设备分流、逐权限 decision、runner 身份绑定与不支持动作拒绝。
