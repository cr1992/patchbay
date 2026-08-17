# 0.4.0 Launcher、Session 与唤醒租约

> 状态：提案中
>
> 关联：PB-040-03、PB-040-11
>
> 设计闸门：DG-040-02、DG-040-04

## 问题

接入方分别实现启动、等待会话、断连重试和过期清理，session 文件只能描述已连通记录，启动中的
pending 状态依赖外部 PID 猜测。断连时 CLI 直接退出，用户需要手工 `prune/use --clear`。真机调试
期间息屏又会让 UI 命令全部拒绝，但永久 keep-awake 会污染息屏测试并泄漏系统资源。

## 目标与非目标

- `patchbay launch -- <consumer command>` 监督一个子进程和它声明的 session，输出稳定 machine frame。
- session store 显式区分 `pending/ready/stale`，并保留 owner 与最后观测时间。
- 断连按有限退避恢复；选择仍 fail-closed，不自动切到另一台设备。
- keep-awake 是显式、可续租、会自动释放的 debug-only session 策略。
- 0.4.0 不做常驻 daemon，不托管设备 SDK，也不代替接入方构建/安装 App。

## Session schema 与监督状态机

session 记录新增松读字段：`state`、`ownerPid`、`launchId`、`observedAtMs`、`expiresAtMs`。老记录没有
`state` 时按现有 ready/stale 探活逻辑读取；新 writer 必须先写 `pending`，identity 握手成功后原子替换为
`ready`。

```text
starting -> pending -> connecting -> ready
                    -> retrying -> connecting
                    -> failed
ready -> disconnected -> retrying | completed
任意非终态 -> cancelled
```

- 同一 `launchId` 只认一个 owner；PID 存活只证明 launcher 仍在，不证明 App ready。
- 重试使用带抖动指数退避和总预算；预算耗尽以类型化 `launchFailed` 收尾。
- 监督期间发现别的 session 不自动切换，只在 machine frame 中报告候选。
- 正常退出、信号取消和启动失败都清理自己拥有的 pending 记录；不删除其他 owner 的记录。

machine frame 至少稳定输出：`launchId/state/sessionId?/attempt/elapsedMs/nextRetryMs?/reasonCode?`。
人类可读日志写 stderr，`--json`/machine frame 写 stdout，二者不能混行。

## keep-awake 租约

launcher 只有在显式 `--keep-awake` 或配置策略开启时申请租约。租约绑定 `launchId + sessionId`，带最大
TTL；CLI 在 session 有活动时续租，退出、静默超时、App detach 或租约过期时释放。Android 使用
`FLAG_KEEP_SCREEN_ON`，iOS 使用 `isIdleTimerDisabled`，但平台句柄只由 patchbay_flutter 管理。

默认关闭；开启后 identity/catalog 明示 capability 和当前租约状态。release 构建不注册命令、不创建
平台句柄。测试息屏行为时 `--no-keep-awake` 必须覆盖任何本地默认值。

## 兼容与降级

- 新 CLI 遇不支持 pending schema 的接入方，使用既有探活并标记 `sessionMode: legacy`。
- 老 CLI 忽略新 session 字段；writer 保持既有必填字段语义。
- keep-awake capability 不存在时显式拒绝，不假装策略已生效。
- VM/direct 只影响连接方式，不改变监督状态和 reasonCode。

## 验证

- 子进程未启动、启动后无 session、握手失败、断连恢复、预算耗尽、SIGINT 分别有确定终态。
- 注入 PID 重用、过期 pending、两个设备同时出现，证明不会误删或自动切换。
- Android/iOS 真机验证租约申请、续租、静默释放和显式关闭；release 产物验证不可达。
- 两个接入方使用同一 machine-frame parser，不再各自解析人类日志。

## 待裁决

- 默认退避、总预算和 pending TTL 的具体值。
- macOS 失焦但仍渲染时是否以帧活性补充 lifecycle 判断。

## 被否决方案

- 0.4.0 直接上常驻 daemon：扩大安装、升级和孤儿进程治理范围，不能解决契约本身缺失。
- session 失效时自动选择最新设备：可能把写操作发送到错误设备。
- App 启动后永久 keep-awake：资源泄漏且使息屏测试失真。
