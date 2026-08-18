# PB-040-27 HarmonyOS 兼容性验证报告

> 状态：阻塞于可构建 SDK 基线、moii app 与 HarmonyOS 真机
>
> 记录日期：2026-08-18
>
> 机器真源：[capability fixture](fixtures/harmonyos-permission-capability-v1.json)；
> 结构约束：[schema](fixtures/harmonyos-permission-capability-v1.schema.json)

## 结论

当前环境已经足够确认“协议可以保守表达未知”，还不足以确认 HarmonyOS 可用：本机有 OpenHarmony
Flutter fork、HarmonyOS/OpenHarmony SDK、`hdc`、`hvigorw` 和 `ohpm`，但临时 example 的 HAP 构建在
Hvigor SDK 完整性检查处失败，且没有可见的 HarmonyOS target。moii app 未进入本次工作区，也没有进行
安装、启动、授权或系统弹窗操作。

因此 fixture 的平台结论和所有 permission action/decision 都是 `unsupported`。本报告不能作为
README、identity 或发布说明宣称 HarmonyOS 支持的证据。

## 验收对象边界

验证分成两条证据线，不能互相冒充：

- `patchbay_flutter` example 只用于 package 导入、依赖解析和 HAP 构建预检；它没有 moii app 的路由、
  业务 adapter、权限声明和生命周期接线。
- 真机验收对象统一为 **moii app**。VM attach、identity/catalog/invoke、Semantics、lifecycle、artifact、
  App 权限 API、UiTest/Hypium 与 hdc 恢复都必须在 moii app 的固定 revision 上取证。

最终将 `supportStatus` 改为 `verified` 前，六步矩阵必须全部是 `verified`，且每步至少有一条可复核证据；
example 成功只能解除构建前置阻塞，不能把任何 moii app 项标绿。

## 当前环境基线

| 项目 | 当前事实 | 裁定 |
|---|---|---|
| Host | macOS 26.5.2, arm64 | 已记录 |
| Patchbay | `59fc140098a9a744c8a7222678f5ef8094ec4729`（本分支基线） | 已记录 |
| Flutter 候选 | CPF `3.41.10-ohos-0.0.3-beta`，revision `aa33b6e2a6ed5e2672e45eef43d1221310a96878`，Dart 3.11.5 | **候选，未完成选定** |
| 另一份 fork | OpenHarmony-SIG `3.35.8`，revision `6f4181db61f0db87339edca1fb0e5108c3740e11` | 引擎 artifact 不完整，不作为本轮候选 |
| HarmonyOS SDK | API 24 / 6.1.1 / `6.1.1.125`，由 DevEco SDK bridge 暴露 | doctor 可发现，HAP 构建仍报组件缺失 |
| OpenHarmony SDK | API 23 / 6.1.0.31 | 已安装；同一预检仍报组件缺失 |
| 构建工具 | hdc 3.2.0c；hvigorw 6.24.3；ohpm 6.1.2.285 | 存在；后两者未在默认 PATH |
| HarmonyOS target | `hdc list targets` 未返回 target | 阻塞真机验证 |
| 真机验收 App | moii app | 本工作区不可用，未执行 |

“候选”不等于项目已经选定 SDK。要固定基线，必须先让同一个 SDK root 通过 HAP 构建，并把 SDK
distribution、revision、API level 与 moii app revision 一起固定进 fixture；不能只因为 `flutter doctor`
能看到工具链就升级结论。

## 已执行的非设备预检

在临时目录用候选 fork 生成 OHOS app，将 `patchbay_flutter` 指向本分支源码：

1. `flutter create --platforms=ohos --no-pub`：通过；
2. `flutter pub get --offline`：通过，`patchbay_flutter 0.3.0` 与 `patchbay 0.3.0` 从本地源码解析；
3. `flutter build hap --debug`：默认 PATH 首先暴露 `ohpm`/`hvigorw` 不可发现；显式使用本机 DevEco
   二进制后，HarmonyOS API 24 bridge 与 OpenHarmony API 23 两条 SDK root 均停止于 Hvigor
   `00303168 SDK component missing`。

没有为推进预检安装或下载 SDK、构建工具或依赖，也没有把临时 HAP 安装到设备。临时 example 结果只写
入 `coreFlutterBuild`，其余五项不继承这条证据。

## 六步矩阵

| 步骤 | 验收对象 | 通过条件 | 当前状态 | 当前阻塞 |
|---|---|---|---|---|
| 1. core + Flutter build | example 预检；最终为 moii app | `patchbay`/`patchbay_flutter` 从固定源码解析，moii app debug/profile HAP 用选定 SDK 构建成功 | `blockedBySdk` | Hvigor `00303168`；moii app 未进入验收 |
| 2. VM Service attach | moii app 真机 | attach 后 identity、catalog、invoke 均成功，requestId/admission 可核对 | `blockedByDevice` | 无 HarmonyOS target、无 moii HAP |
| 3. Semantics/lifecycle/artifact | moii app 真机 | identifier 可读；前后台状态准确；artifact 可分块读取且预算生效 | `blockedByDevice` | 无 HarmonyOS target、无 moii HAP |
| 4. App permission API | moii app 真机 | camera/location 状态可读，请求可触发；原始平台状态与 factSource 有证据 | `blockedByDevice` | 无 HarmonyOS target、无 moii 权限 adapter |
| 5. UiTest/Hypium | moii app 真机 | runner 只处理预声明 camera/location 窗口；permission/decision 不匹配 fail-closed | `blockedBySdk` | runner 未构建，SDK 与设备均未固定 |
| 6. hdc recovery | moii app 真机 | hdc 断连、App 前后台、一次性授权回收后重新握手、刷新 catalog、重解析目标 | `blockedByDevice` | 无 HarmonyOS target、无 moii HAP |

任一步是 `failed` 或 `blocked*` 时，平台级 `supportStatus` 必须是 `unsupported`；未完成项不得用
`notRun` 隐去已经发现的 blocker。

## 真机到位后的执行清单

以下动作只在用户提供选定 SDK、HarmonyOS 真机和 moii app 固定 revision 后执行：

1. 记录 SDK distribution/revision、SDK API/build、设备 model/OS/API、moii app revision/applicationId/
   build mode，更新 baseline，不记录签名材料或设备凭据；
2. 先构建 moii app debug/profile HAP；失败时保留构建错误，矩阵不继续伪绿；
3. 通过 hdc 启动 moii app，仅对该 applicationId 建立 VM Service attach，验证
   identity/catalog/invoke；
4. 读取一个固定 Semantics identifier，执行前后台切换并读取 lifecycle，再下载一个无敏感内容的
   artifact；
5. 通过 moii app 权限 adapter 查询并请求 camera/location；UiTest/Hypium runner 只在预声明窗口身份
   匹配时执行 allow/deny/allowOnce；
6. 依次制造 hdc 断连、前后台切换、一次性授权回收，验证 session 重握手、catalog refresh 和 target
   re-resolve；最后把逐权限实测结果写回 fixture。

## Capability 写回规则

- `status` 只有 App 权限 API 或 hdc/driver 实际读取状态后才能变为 `verified`；命令退出码 0 不算状态证据。
- `normalize/reset` 只有存在稳定平台 API、动作后重新查询状态且至少一台目标设备通过时才能变为
  `verified`。
- `exercise` 与 `allow/deny/allowOnce` 必须由 UiTest/Hypium 在身份匹配的系统窗口上完成；坐标、按钮文案
  或人工点击不能写入 capability。
- camera、microphone、locationWhenInUse、notifications 是 P0；Bluetooth 是 P1。一个权限的成功不能
  外推到另一个权限。
- fixture 不写本机绝对路径、设备凭据、签名身份或系统弹窗截图中的个人内容。

## 当前需要的外部条件

下一轮不是继续写 Dart 代码，而是补齐环境与真机证据：

- 一份 Hvigor 能完整识别、可离线构建 moii app 的选定 OpenHarmony/HarmonyOS SDK；
- `ohpm`/`hvigorw` 的明确发现路径（不要求修改全局 PATH，可以由验收脚本显式提供）；
- 一台 `hdc list targets` 可见的 HarmonyOS 真机；
- moii app 的固定 revision、debug/profile HAP、applicationId 与权限 adapter/runner 接线。

这些条件未满足前，PB-040-27 的安全交付就是本报告、schema 和全 `unsupported` fixture，而不是一个
“看起来能跑”的 HarmonyOS driver。
