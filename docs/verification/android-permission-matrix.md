# Android 权限矩阵验证报告（PB-040-25 / PB-040-26）

> 状态：Android `status` / `normalize(granted)` / `reset` 已在真机取得设备事实；`normalize(denied)`
> 与真实系统弹窗 `exercise` 未通过，原因见下。报告只记结论与可复现步骤；含应用标识与设备标识的
> 原始输出按 [AGENTS.md](../../AGENTS.md) 的保密规则留在被 gitignore 的本地目录，不入库。

## 环境与被试对象

| 项 | 值 |
|---|---|
| 设备 | Android 16（API 36），真机 |
| CLI / driver | 由 `packages/patchbay_cli/bin/patchbay.dart` 与 `bin/patchbay_permission_android.dart` 现场 AOT 编出，源为本报告所在提交 |
| driver 标识 | `android.adb-uiautomator`，`driverVersion: 1` |
| 被试应用 | 一个接入方的 Android 调试构建：声明 camera / microphone / fine+coarse location / bluetooth，**未声明** `POST_NOTIFICATIONS` |
| 会话 | 由该接入方自己的 launcher 声明并登记（权限写操作只接受 `--session`，见下方「结构前提」） |
| 前置动作 | 卸载后重装，取得"从未询问"的首次授权态（全部 `granted=false` 且无 `USER_SET` 标记） |

## 逐权限矩阵

| 权限 | status（首次） | normalize granted | 幂等重放 | reset | reset 后 status | normalize denied |
|---|---|---|---|---|---|---|
| camera | `notDetermined` | `notDetermined → granted` | — | — | — | **退 5**，设备复核回 `notDetermined` |
| microphone | `notDetermined` | `notDetermined → granted` | — | — | — | 同上 |
| locationWhenInUse | `notDetermined` | `notDetermined → granted` | `granted → granted`（无变化） | `granted → notDetermined` | `notDetermined` | 同上 |
| notifications | **退 5 `permissionUnsupported`** | 同 status | — | — | — | — |

每条成功答复都带 `factSource: deviceReported`、`platformState`（`dumpsys` 的 `granted=` 与 flags 原文）
与 `supportedActions`，且写操作同时给出 `before` / `after` 两段状态——动作后复核设备事实这一条成立。
`adb shell dumpsys package` 的独立交叉核对与 CLI 的结论一致。

## 已证实成立

1. **Android 的读路径可信**：状态来自 `dumpsys package` 的运行时权限段，不是 shell 退出码。
2. **`normalize` 到 `granted` 与 `reset` 可达且幂等**，前后状态都被复核。
3. **权限写操作的会话绑定闸生效**：`--ws-uri` 被按用法错误拒绝并指向 `--session` 或
   `--device-id` + `--application-id`；陈旧会话按 `sessionSelectionStale` 退 3。
4. **撤销权限导致 App 被系统终止时，launcher 的监督循环按设计接住**：会话记录保留、状态转
   `pending`、按退避重连并给出剩余窗口。这条是真实事件触发的观测，不是模拟断连。

## 未通过与原因

### 1. `normalize --state denied` 在 Android 上不可达

`adb shell pm revoke` 只能把权限打回 `granted=false` **且不带 `USER_SET`**，而那正是
`notDetermined` 的判据。真正的"用户拒绝"只能由用户在系统弹窗上按下拒绝产生。适配器复核设备事实后
按状态不符拒绝（退 5），行为是诚实的；但 capability 仍然宣布 `revoke` 动作可用，读者会以为
`denied` 可达。**可达状态集必须如实收敛**。

### 2. 「应用未声明该权限」被报成 `permissionUnsupported`

被试应用没有声明 `POST_NOTIFICATIONS`，`dumpsys` 因此没有对应条目，适配器把"正则未匹配"映射成
协议拒绝 `permissionUnsupported`。同一个稳定 code 于是同时表示"driver/平台不支持这个权限"和
"这个应用没声明它"，而两者的处置完全不同。封闭状态词表里已有 `unsupported` 作为**可返回状态**，
这种情形应返回状态而非拒绝，并在证据里写明原因。

### 3. `requiresRestart` 与 `systemUiExpected` 硬编码为 `false`

两个平台适配器都固定回 `false`。实测在 Android 上撤销 camera / microphone 会**必然终止 App
进程**，操作者因此拿不到"需要重启 App"的机读信号，监督循环只能空转整个重连窗口等一个不会回来的
连接。`systemUiExpected` 同理：`exercise` 的前提就是预期出现系统 UI。这两个字段应按平台与操作
如实计算。

### 4. capability 是「runner 路径非空」而不是真实探测

只要配置了任意 instrumentation runner 字符串——包括**设备上并不存在**的字符串——四个 P0 权限
立刻同时宣布 `exercise` 动作与 `allow` / `allowOnce` / `deny` 三种 decision，全过程没有任何探测。
不配 runner 时 `decisions` 为空数组，这部分是诚实的。

### 5. 真实系统弹窗 `exercise` 未覆盖

仓内 companion 只有一个抽象 runner 源文件，没有可构建安装的 instrumentation 工程，因此
「reset → 触发应用请求 → 处理系统弹窗 → 复核状态 → 恢复 App」这条闭环本次未跑。

## 结构前提（影响仓内预检能覆盖什么）

权限写操作只接受 `--session`，即必须存在 launcher 会话库里的活动会话记录；而记录由
`patchbay launch` 的宿主侧子进程声明。仓内 example 的会话脚本用 `--vmservice-out-file` 直接取
URI、**不声明会话记录**，所以 `tool/example_precheck.sh` 里权限一节只能验证"没有 driver 时
fail-closed"。这是结构限制而不是覆盖疏漏：要让预检覆盖 normalize / exercise，必须先给 example
提供一个宿主侧会话声明器。

另外 example 生成的平台工程原本只声明 `INTERNET`，运行时权限段为空，四个 P0 权限在设备上没有可读
事实；会话脚本现已按需注入 P0 声明（Android manifest 与 iOS usage description，幂等、不入库）。
