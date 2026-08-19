# Android 权限弹窗闭环预检（PB-040-25 / PB-040-26 / PB-040-29）

> 日期：2026-08-19
>
> 结论：应用侧触发已在 Android 16 真机跑通；现有 AOSP resource-id matcher 在当前 Xiaomi
> 系统上 fail-closed，真实弹窗 `exercise` 尚未闭环，不能宣称可用。

## 已通过

- `tool/example_precheck.sh`：54 通过、0 失败，覆盖四个 P0 权限的 capability/status，以及 camera
  的 `normalize granted`、幂等重放、不可达 denied 的无副作用拒绝和 `reset`。
- `example.permission.status`：返回 `appRecorded` 原始视图，响应经 schema 校验。
- `example.permission.request`：受理后立即返回 `outcome: requested`，系统 camera 权限弹窗真实出现，
  响应经 schema 校验；命令不等待弹窗结果，避免编排方与 App 互相等待。

应用侧插件把“从未询问”读成 `denied`，同一时刻 adb 设备事实为 `notDetermined`。因此 example 只把
该值命名为 `platformState`，不冒充 Patchbay 的规范化 `state`；这个 App adapter 可以承担触发，不能
单独作为 Android/iOS 的权威状态源。

## 弹窗身份事实

UiAutomator 层级显示：

- active window package 为 `com.android.permissioncontroller`；
- 标题节点有稳定 resource-id，并包含被试 App label；
- allow、deny、allow-once 三个按钮都是可点击 `Button`，但 **resource-id 全为空**；
- 按钮只有本地化文案、节点顺序和 bounds。

交接分支的 reference matcher 只接受 AOSP 按钮 resource-id。对同一真实弹窗运行时按
`expected permission dialog identity did not match` 失败，未点击任何按钮。这证明它的 fail-closed
行为成立，也证明“resource-id + bounds”不是当前设备上可用的稳定实现；bounds/绝对坐标又被已接受的
平台权限 Proposal 明确排除，不能为了让矩阵变绿而降级使用。

## 剩余阻断

1. reference runner 需要独立 companion test APK，不能把 instrumentation target 设为被试 App；后者会
   重启被试进程并破坏刚触发的弹窗。
2. matcher 必须在点击前绑定被试 App、权限和 decision。只认 permission-controller package 或按钮文案
   都不足以防止误点其他系统确认框。
3. OEM 支持范围需要显式裁决：AOSP matcher 可按其封闭标识交付；当前 Xiaomi 结构若纳入承诺，需要
   独立 matcher 与 capability 声明，不能外推为“所有 OEM”。
4. `allowOnce` 在当前层级没有资源标识，未取得安全 matcher 前 capability 不应仅因 runner 已安装就
   宣称支持。

因此本报告不是第三份“全绿矩阵”，而是闭环前置证据与阻断记录。后续 runner 通过后，应另归档
`reset → App 触发 → driver 处理 → device/app 双源复核 → session 恢复` 的完整矩阵。
