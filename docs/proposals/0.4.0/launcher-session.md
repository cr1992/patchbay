# 0.4.0 Launcher、Session 与唤醒租约

> 状态：已接受
>
> 关联：PB-040-03；launcher 监督循环已随 0.4.0 发布，见
> [CHANGELOG.md 0.4.0 段](../../../CHANGELOG.md#040---2026-08-20)
>
> 设计闸门：DG-040-02、DG-040-04

## 问题

接入方分别实现启动、等待会话、断连重试和过期清理，session 文件只能描述已连通记录，启动中的
pending 状态依赖外部 PID 猜测。断连时 CLI 直接退出，用户需要手工 `prune/use --clear`。真机调试
期间息屏又会让 UI 命令全部拒绝，但永久 keep-awake 会污染息屏测试并泄漏系统资源。

## 目标与非目标

- `patchbay launch -- <consumer command>` 监督一个子进程和它声明的 session，输出稳定 machine frame。
- session store 显式区分 `live/pending/stale`（沿用既有词表，不新造同义词），并保留 owner 与最后
  观测时间。
- 断连按有限退避恢复；选择仍 fail-closed，不自动切到另一台设备。
- keep-awake 是显式、可续租、会自动释放的 debug-only session 策略。
- 0.4.0 不做常驻 daemon，不托管设备 SDK，也不代替接入方构建/安装 App。

## Session schema 与监督状态机

session 记录新增松读字段：`state`、`ownerPid`、`launchId`、`observedAtMs`、`expiresAtMs`。`state` 沿用
既有 `live | pending | stale` 词表，**不引入 `ready` 这个同义词**——`status` 已经是 `sessions list --json`
的稳定输出字段，两个词表会让消费端分不清它们是不是同一件事。新增的持久化 `state` 与既有那个从
PID 探活加 URI 有无派生出来的 `status` 关系必须写明：前者是 writer 声明的，后者是 reader 观测的，
冲突时以观测为准。老记录没有 `state` 时按现有探活逻辑读取；新 writer 必须先写 `pending`，identity
握手成功后原子替换为 `live`。

`launch` 采用公开的 child-declaration 契约，不解析某一种设备工具的私有 stdout，也不凭空补
`applicationId/deviceId`：launcher 启动子进程时注入既有 `PATCHBAY_SESSION_DIR`，以及新增的
`PATCHBAY_LAUNCH_ID`、`PATCHBAY_LAUNCH_OWNER_PID`。参与接入的 child/consumer 通过
`PatchbayLaunchContext.tryFromEnvironment` 读取三者，并使用 `pendingRecord` 写入包含全部既有必填
metadata 的记录；其中 `processId` 必须由 child 显式传入真实 consumer/App 进程，拿到 transport 后以
`withTransport` 原子更新。`ownerPid` 是 launcher PID，不是 App PID；两者不得互相代填。launcher 只监督
同时匹配 `launchId + ownerPid` 的记录。三项都不存在表示普通独立启动，部分存在
则是 `launchContextInvalid`，不得猜测。无参与 child 在预算耗尽后以 `failed/sessionNotDeclared` 收尾。
这套声明不新增 metadata 命令行 flags，也不占用 child stdout 的私有 frame。

**session 记录的 `schemaVersion` 保持 `1`，新字段一律松读追加。** 这不是风格偏好：现有 reader 遇到
不认识的 `schemaVersion` 会抛，而目录扫描把解析失败的文件**直接删除**。所以升一次版本号的实际
后果是——装着老 CLI 的那台机器会悄悄删掉新 launcher 刚写下的会话记录。这是比 wire 面更容易踩的
一处，因为它是本地文件而不是网络面，没有握手会拦住它。

清理只针对自己拥有的记录：launcher 退出时清理自己 `launchId` 名下的 pending 记录。既有 `resolve`
在探活失败、URI 非法或 identity 不符时删除任意记录的行为不在本提案范围内改变，但两条路径必须在
实现中明确分开，不能让 launcher 的 owner 语义被读成对既有清理逻辑的收紧。

```text
starting -> pending -> connecting -> live
                    -> retrying -> connecting
                    -> failed
live -> disconnected -> retrying | completed
任意非终态 -> cancelled
```

- 同一 `launchId` 只认一个 owner；PID 存活只证明 launcher 仍在，不证明 App ready。
- 重试使用带抖动指数退避：首次等待 200 ms，每次翻倍并封顶 5 s，抖动取计算值的 `[50%,100%]`；默认
  总预算 120 s。预算耗尽以类型化 `launchFailed` 收尾。时钟与随机源必须可注入，测试不能靠真实等待。
- `live` 后的健康观测固定为 5 s cadence，不沿用恢复退避轮询；从 `live` 转为不可达时，恢复退避重新从
  200 ms 起步。identity probe 必须与 child 退出及剩余预算竞速，不能让一次无响应连接突破总预算。
- pending 记录默认 TTL 为 5 min；launcher 每次有效状态推进都刷新 `observedAtMs`，但单纯读取不续期。
  配置可把总预算和 TTL 调小，不能分别超过 10 min 与 30 min。
- 监督期间发现别的 session 不自动切换，只在 machine frame 中报告候选。
- 正常退出、信号取消和启动失败都清理自己拥有的 pending 记录；不删除其他 owner 的记录。

machine frame 至少稳定输出：`launchId/state/sessionId?/attempt/elapsedMs/nextRetryMs?/reasonCode?`。
人类可读日志写 stderr，`--json`/machine frame 写 stdout，二者不能混行。

## keep-awake 租约

**App 侧已经落地，本版不改协议面。** `ui.keepAwake.set|status`、`leaseMs`、默认与最大租约、
`operatorRequest / leaseExpired / hostDisposed` 三种释放原因，以及未接线时的 `keepAwakeNotWired`，
都已随 0.3.x 发布。平台句柄**由接入方通过 `keepAwakeDelegate` 注入**——四个 package 都不碰
platform channel，给 `patchbay_flutter` 加插件或第三方 wakelock 依赖，等于为了一个调试开关改变每个
接入方构建链接的东西。框架拥有协议、记账和租约，App 拥有那一行碰平台的代码。

所以 PB-040-03 在 0.4.0 的增量**只在 CLI/launcher 侧**：

- 全局可否定 flag 为 `--[no-]keep-awake`；本地默认只读环境变量 `PATCHBAY_KEEP_AWAKE`
  （`true/false`、`on/off` 或 `1/0`），未配置时关闭，显式 `--no-keep-awake` 优先级最高；
- 0.4 不再引入第二套可调租约：策略申请沿用 App 已冻结的 10 分钟默认租约，最大值仍为 2 小时；
  launcher 只在既有 5 秒健康观测中于半租期续租，不另起高频心跳，租约绑定当前 `launchId + sessionId`；
- 普通 one-shot / REPL 命令只在**命令成功之后**续租；`ui keep-awake on|off|status` 自己就是租约操作，
  不触发隐式续租，尤其不能让读一眼 `status` 改变过期时间；
- 正常退出、child 结束、监督失败、信号取消都尽力显式 release；连接已断时必须输出
  `releaseUnconfirmed`，不能伪称释放成功，最终仍由 App 租约到期静默兜底；
- `--no-keep-awake` 必须覆盖任何本地默认值，供息屏行为本身的测试使用。

普通命令的结构化结果在策略实际执行时增加 `localKeepAwake`；launcher machine frame 增加同形的
`keepAwake: {state, success, reasonCode?}`。续租拒绝或无法确认时普通命令以类型化失败退出，launcher 则
继续监督 App、但在 frame 中保留失败事实；两者都不输出 transport URI 或 token。

capability 沿用既有表达：`ui.keepAwake.status` 的 `wired: false` 与 `keepAwakeNotWired` 已经能说明
“这个 App 没接线”，不新增 feature 名。release 构建继续不注册命令、不创建平台句柄。

## 兼容与降级

- 新 CLI 遇不支持 pending schema 的接入方，使用既有探活并标记 `sessionMode: legacy`。
- 老 CLI 忽略新 session 字段；writer 保持既有必填字段语义与 `schemaVersion: 1`。
- 不参与 child 不会被 launcher 误认；它仍可沿用旧 writer 独立写记录，但 `patchbay launch` 不拥有它。
- keep-awake 未接线时按既有 `keepAwakeNotWired` 显式拒绝，不假装策略已生效。
- VM/direct 只影响连接方式，不改变监督状态和 reasonCode。

## 验证

- 子进程未启动、启动后无 session、握手失败、断连恢复、预算耗尽、SIGINT 分别有确定终态。
- 注入 PID 重用、过期 pending、两个设备同时出现，证明不会误删或自动切换。
- **老 reader 不删新记录**：用复刻的 0.3 读取逻辑读当前 writer 写出的记录，断言解析成功且文件仍在。
- `--no-keep-awake` 覆盖项目配置默认值的单测；续租只在命令成功后发生、读状态不续租的单测。
- Android/iOS 真机验证租约申请、续租、静默释放和显式关闭；release 产物验证不可达。
- 双平台 example 预检使用同一 machine-frame parser 解析 pending/握手/断连，不再依赖人类日志；接入方各自
  的 parser 验证为补充证据（发布判据见[版本计划 SC-040-01](../../releases/0.4.0.md#范围变更记录)）。

## 已裁决预算

- 退避、总预算和 pending TTL 已在监督状态机一节冻结；实现 MR 只负责把相同数值落入 descriptor、帮助
  与测试，不得另设一套默认值。

## lifecycle 门（DG-040-04）

移动端继续要求 `resumed`，桌面端**不引入“帧活性”作为第二判据**。lifecycle 门现在只有一个真源
——引擎报告的生命周期状态；加一条帧活性旁路会让它有两个，而 `lifecycleState` capability 刚刚建立
“客户端可以按声明降级”的承诺，一个有两个真源的门无法兑现这个承诺。

需要在 macOS 失焦状态下继续调试的接入方，用既有的 `isAppResumed` 注入点自行覆盖判定，并自行承担
由此带来的误判风险；`doctor` 显式标注该判定已被接入方替换。这样本仓不需要为一个桌面端边缘场景
背上真机验证预算，接入方也没有失去能力。

## 被否决方案

- 0.4.0 直接上常驻 daemon：扩大安装、升级和孤儿进程治理范围，不能解决契约本身缺失。
- session 失效时自动选择最新设备：可能把写操作发送到错误设备。
- App 启动后永久 keep-awake：资源泄漏且使息屏测试失真。
- 把 keep-awake 的平台句柄收进 `patchbay_flutter`：会给每个接入方的构建凭空加一条平台依赖，且与
  “接入方设备 SDK 不进这四个包”的依赖方向相反。
- session 记录升 `schemaVersion` 以容纳新字段：老 reader 会因此删除新 writer 的记录。
- 桌面端以帧活性补充 lifecycle 判定：让门有两个真源。
