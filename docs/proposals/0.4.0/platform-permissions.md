# 0.4.0 平台权限编排与系统弹窗恢复

> 状态：提案中
>
> 关联：PB-040-25、PB-040-26、PB-040-27
>
> 设计闸门：DG-040-07

## 问题

Patchbay 的 UI 面运行在 App 内，只能观察 Flutter Widget/Render/Semantics；Android、iOS 和 HarmonyOS
的权限弹窗属于系统 UI。弹窗出现后，Patchbay 可能仍保持传输连接，但 Flutter 操作会因为目标被遮挡、
lifecycle 变化或 generation 过期而失败，等待型命令还可能把“等待系统授权”压成普通超时。面向 AI 的
debug CLI 若只能要求人手点弹窗，就不能形成可持续的调试闭环。

## 目标与非目标

### 目标

- AI 能先查询当前平台、权限状态、可执行动作和 driver 证据，再选择确定性策略。
- 普通调试默认将权限规范化到已声明状态，避免无关弹窗打断。
- 专门测试权限 UX 时，可显式触发并由外部平台 driver 操作预期系统弹窗。
- 系统弹窗结束后等待 App 恢复，重新握手 session/catalog，重新解析 identifier/generation 后继续。
- Android、iOS、HarmonyOS 使用同一上层状态和事件信封，但保留原始平台状态与能力差异。
- 所有权限动作进入 Debug Trace，且不记录敏感值、设备凭据或签名材料。

### 非目标

- 不允许 App 内的 `patchbay_flutter` 绕过操作系统权限模型。
- 不提供“看到任意系统弹窗就点允许”的通用机器人。
- 不用屏幕绝对坐标或本地化按钮文本作为稳定权限操作契约。
- 不承诺所有特殊权限都可自动 grant；unsupported 必须是正常、类型化结果。
- 不因抽象统一而抹平 `limited/restricted/permanentlyDenied/allowOnce` 等平台差异。

## 包与进程边界

权限能力落地后，Patchbay 仍以现有 Dart/Flutter packages 为公共集成面，但不再是“仅靠一个 Flutter
package 完成全部自动化”：

| 组件 | 职责 | 约束 |
|---|---|---|
| `patchbay` | 纯 Dart 权限状态、capability、interruption 和 driver wire 模型 | 不依赖 Flutter、adb、Xcode、hdc |
| `patchbay_cli` | AI 命令、策略编排、driver 发现、超时、恢复和 trace 投递 | 只调用声明能力的 driver，不解析本地化弹窗文案 |
| `patchbay_flutter` | 可选的 App 内权限状态/请求 adapter，报告 lifecycle 与请求结果 | 不能操作 App 外系统 UI，release 继续可裁除 |
| Android companion | adb/package-manager adapter + UiAutomator runner | 独立测试 APK/runner，通过版本化 driver wire 通信 |
| Apple companion | simctl adapter + XCUITest runner | 需要 Xcode；真机受签名、设备和 XCTest 能力约束 |
| Harmony companion | hdc adapter + HarmonyOS UiTest/Hypium runner | 首版先验证，不宣称已支持 |

native companion 使用 JSON Lines stdin/stdout driver protocol，可由 Kotlin、Swift、ArkTS/Python 分别实现，
不强行包装成 pub package。CLI 发布物可以携带模板和协议 schema，但平台 SDK、签名身份和设备授权由
本机环境提供。

## 平台无关状态

CLI 对 AI 输出以下封闭状态：

```text
notDetermined
granted
denied
permanentlyDenied
limited
restricted
allowOnce
unsupported
unknown
```

每份结果同时保留：

- `permission`：Patchbay 稳定名，如 `camera`、`microphone`、`locationWhenInUse`；
- `platformPermission`：平台原始权限名；
- `state` 与 `platformState`；
- `factSource`：`deviceReported`、`appRecorded`、`uiObserved` 或 `unknown`；
- `driver`、`driverVersion`、`supportedActions`；
- `requiresRestart`、`requiresSettings`、`systemUiExpected`；
- `notice`：只提供行动提示，不作为机器分支依据。

`granted` 必须来自 OS/测试 driver 或 App 权限 API 的实际读取，不能因为 grant 命令退出码为 0 就直接
推断。动作完成后必须再次查询状态。

## Driver capability 与协议

driver 在执行前返回逐权限能力，而不是只声明“支持权限”：

```json
{
  "platform": "android",
  "driver": "android.adb-uiautomator",
  "driverVersion": "1",
  "permissions": {
    "camera": {
      "actions": ["status", "grant", "revoke", "reset", "exercise"],
      "decisions": ["allow", "deny", "allowOnce"]
    }
  }
}
```

请求使用 `{protocolVersion, requestId, operation, deviceId, applicationId, permission, policy, decision,
timeoutMs}`；响应使用 Patchbay admission 语义，并提供 `before/after/evidence/interruption`。driver 的 stderr
只用于人类诊断，stdout 只能输出 machine frames。

driver 缺失、版本不兼容、设备不唯一、权限不支持和签名不可用分别返回稳定 code，不允许退化成 shell
文本解析或人工等待：

```text
platformDriverUnavailable
platformDriverVersionMismatch
platformDeviceAmbiguous
permissionUnsupported
permissionDecisionUnsupported
platformSigningUnavailable
systemUiUnexpected
appDidNotResume
```

## CLI 契约

```console
$ patchbay permission capabilities --json
$ patchbay permission status camera --json
$ patchbay permission normalize camera --state granted --json
$ patchbay permission reset camera --json
$ patchbay permission exercise camera --decision allow --json --wait
```

Scenario 前置条件使用：

```yaml
permissions:
  camera:
    state: granted
    strategy: normalize
```

策略封闭为：

- `normalize`：使用平台状态控制能力建立目标状态，默认用于普通 AI 调试；
- `exercise`：重置/触发真实系统弹窗并按声明 decision 操作，用于权限 UX；
- `fail`：当前状态不符合就停止，不改变设备。

AI 未显式选择时默认 `fail`；项目级调试配置可以把特定权限设为 `normalize`，但不能设置全局“自动允许
所有权限”。`exercise` 必须声明 permission 和 decision，实际弹窗身份不匹配时 fail-closed。

## Android driver

状态规范化优先使用 adb shell package manager：`pm grant/revoke`、权限 flags 和安装时 grant；动作后用
package manager/dumpsys 或 App 权限 API复核。特殊权限如悬浮窗、VPN、无障碍、默认应用、通知监听和
精确闹钟必须逐项声明能力，不能把 appops 退出成功等同于用户授权。

真实弹窗由 UiAutomator runner 处理。runner 按系统权限 dialog/window 与权限上下文识别，使用平台测试
API选择 allow/deny/allow-once，不使用坐标。OEM/系统版本不支持的 decision 返回 unsupported。Android
runtime permissions 的 P0 验收至少覆盖 emulator 与一台 adb 真机；特殊权限建立能力矩阵但不阻塞 P0。

参考：[Android runtime permission 测试](https://developer.android.com/training/permissions/requesting)、
[UiAutomator PermissionDialog](https://developer.android.com/reference/androidx/test/uiautomator/watcher/PermissionDialog)。

## iOS driver

Simulator 的 normalize/reset 使用 `xcrun simctl privacy`，只对当前 simctl 声明支持的 protected service
开放。真实弹窗和真机路径由 XCUITest runner 处理：通过 `XCUIApplication` 查询/等待状态，使用
`resetAuthorizationStatus(for:)` 恢复可测试状态，并显式处理预期 alert；非预期 modal 才使用 UI
interruption monitor。

iOS 不存在面向普通真机的通用 adb shell grant。真机支持程度取决于 Xcode/XCTest、签名身份、设备授权
和具体 `XCUIProtectedResource`；driver 必须逐资源报告 capability。无法 reset/grant 的权限允许
`exercise` 或 `manualRequired`，不能伪报 normalize 成功。

参考：[Simulator privacy](https://developer.apple.com/videos/play/wwdc2020/10647/)、
[XCTest protected resource](https://developer.apple.com/documentation/xcuiautomation/xcuiprotectedresource)、
[UI interruption](https://developer.apple.com/documentation/xctest/handling-ui-interruptions)。

## HarmonyOS driver 与当前结论

架构上可以接入 HarmonyOS，但当前 Patchbay **尚未验证可用**：

- OpenHarmony-SIG 提供支持 `run/attach/build hap` 的 Flutter OpenHarmony 适配分支，说明 Flutter App 与
  VM attach 路径具备技术基础；它不是本仓当前 Flutter 3.44.9 CI 的已验证目标。
- HarmonyOS App 可以通过权限 API 查询/请求授权，系统也存在一次性授权语义。
- HarmonyOS Test Kit UiTest/Hypium 能查找控件、窗口并执行点击/滑动，可作为系统弹窗 runner 的候选。
- hdc 可承担设备发现、安装、启动和 runner 通信；是否存在可用于第三方应用的稳定 grant/revoke/reset
  命令，需要在目标 SDK/真机上验证，未验证前 capability 只能声明 `status/exercise`。

PB-040-27 的兼容验证必须完成：

1. 用项目选定的 OpenHarmony Flutter SDK 构建 `patchbay_flutter` example；
2. 真机验证 VM Service extension、identity/catalog/invoke、Semantics、lifecycle 和 artifact；
3. 用 App 权限 API获取状态并触发权限请求；
4. 用 UiTest/Hypium 识别和处理至少 camera/location 权限弹窗；
5. 验证 hdc 断连、App 前后台和一次性权限回收后的恢复路径；
6. 把实际支持动作写入 capability fixture，不通过测试就保持 `unsupported`。

参考：[Flutter OpenHarmony 适配](https://gitee.com/openharmony-sig/flutter_flutter)、
[HarmonyOS UiTest](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/js-apis-uitest-V13)、
[HarmonyOS 单次授权](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/one-time-authorization)。

## 系统中断与恢复状态机

```text
preflight
  -> stateSatisfied -> continue
  -> normalizing -> verifyState -> continue | failed
  -> requesting -> waitingSystemUi -> handled -> waitingAppResume
  -> waitingAppResume -> reconnecting -> refreshCatalog -> reResolveTargets -> continue
任意阶段 -> unexpectedSystemUi | budgetExceeded | cancelled
```

系统 UI 处理完成不等于 App 已恢复。CLI 必须重新检查 lifecycle；session/appInstanceId 变化时重新握手；
所有后续 UI 写操作重新读取 identifier/generation。触发权限请求的原命令若已经返回 accepted，不自动重发；
只有 scenario 明确声明幂等和 retryPolicy 才能再次调用。

当前无法从 App 内可靠识别所有系统弹窗，因此 expected interruption 由 scenario/descriptor 预声明，外部
driver 负责验证实际 window。未声明弹窗出现时返回 `systemUiUnexpected` 并附可行动提示，不等待到普通
TTL。

## Trace 与审计

Debug Trace 增加：`permission.preflight`、`permission.transition`、`systemUi.detected`、
`systemUi.handled`、`app.resumeObserved`。事件记录 before/after、decision、driver、factSource、耗时和稳定
code；不保存设备配对凭据、Apple 签名材料、stdin sensitive 值或系统弹窗截图中的个人内容。

audit 只保留权限名、动作、调用者和结果摘要；`exercise allow` 属于高风险动作，必须在 trace 中可追踪。

## 兼容、发布与安装

- 没有 platform driver 时，现有 Patchbay 命令继续工作；permission capability 明确 unavailable。
- CLI AOT 发布物不内置 adb/Xcode/hdc，`patchbay doctor permission` 检查工具、版本、设备和 runner。
- companion 版本独立于 App package 版本，但 driver protocol major 不匹配时拒绝执行。
- release 构建不注册 App 内 permission adapter；外部 driver 只允许操作显式指定的 debug/test App。
- GitHub/pub 发布必须说明哪些 driver 随包、哪些需要本机 SDK生成，不能首次运行时静默下载可执行文件。

## 验证

- 纯 Dart contract 测试覆盖状态映射、capability、unknown/unsupported、超时和 driver protocol。
- CLI fake-driver golden 覆盖 normalize/exercise/fail、非预期弹窗、App 未恢复和 session 变化。
- Android emulator + 真机覆盖 grant/revoke/reset、allow/deny/allow-once 与永久拒绝。
- iOS Simulator 覆盖 simctl normalize/reset 和 XCUITest alert；至少一台真机验证支持矩阵。
- HarmonyOS 在 PB-040-27 验证完成前不进入“支持平台”列表。
- AI 端到端验收：AI 只读 capability 和稳定 JSON 即可决定下一步，不解析 shell stderr 或本地化文案。
- 安全 mutation：弹窗权限名、App identity 或 decision 不匹配时必须拒绝，不能误点其他系统确认框。

## 待裁决

- DG-040-07：`exercise allow` 是否每次需要交互确认；提案建议显式 scenario 可免二次人工确认，临时命令
  默认要求 `--confirm-system-permission`。
- Android/iOS P0 必须覆盖的权限集合；提案建议 camera、microphone、location、Bluetooth、notifications。
- native companion 是随 CLI release archive 分发，还是由仓库模板在本机 SDK 下构建。
- HarmonyOS 选定的 Flutter OpenHarmony SDK/设备/API 基线。

## 被否决方案

- 把平台权限逻辑全部塞进 `patchbay_flutter`：App 内代码无权稳定操作系统窗口，且破坏纯 Flutter 边界。
- 用 AI 视觉识别按钮并点击坐标：语言、ROM、分辨率和弹窗身份均不稳定，可能误授权。
- Android/iOS/HarmonyOS 统一成一个布尔 granted：丢失永久拒绝、受限、有限授权和一次性授权语义。
- 等权限弹窗消失后继续使用旧 generation：可能把写操作落到重建后的错误控件。
