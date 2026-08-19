# example 权限矩阵验证报告（PB-040-25 / PB-040-29）

> 状态：仓内 example 已能作为权限被试对象，Android 真机上 `status` / `normalize(granted)` /
> `reset` 全部取得设备事实。真实系统弹窗 `exercise` 仍未覆盖（缺可构建的 companion runner）。
> 本报告是**仓内**证据，按 AGENTS.md 的两段验证顺序，它是接入方验收的前置门。

## 此前为什么跑不出来

三个前提同时缺失，任一缺失都会让权限路径在仓内不可达：

1. **平台工程不声明权限**。`flutter create` 生成的工程只有 `INTERNET`，`dumpsys package` 的
   `runtime permissions:` 段为空，四个 P0 权限在设备上没有可读事实，适配器的状态查询因「正则
   未匹配」退化成 `permissionUnsupported`。
2. **没有 launcher 会话记录**。权限写操作只接受 `--session`，而记录由 `patchbay launch` 的宿主侧
   子进程声明；会话脚本此前直接 `flutter run` 取 URI，从不声明记录。
3. **平台包名与 host 身份不一致**。权限命令会拿平台 `applicationId` 与会话记录的 applicationId
   对账，不一致按 `platformApplicationMismatch` 拒绝——这道检查是对的，但它推出一条隐含约束：
   **host 声明的 `applicationId` 必须等于平台包名**。生成工程的包名是
   `dev.patchbay.patchbay_flutter_example`，而 host 声明 `dev.patchbay.example`。

现在三项都由会话脚本按需处理，全部作用在**不入库的生成物**上：注入 P0 权限声明、经
`patchbay launch` + 参考声明器建立会话、对齐 `applicationId`（只改安装身份，不改 `namespace`——
`namespace` 决定 Android 到哪个包找 `.MainActivity`，一起改会让 App 以 `ClassNotFoundException`
起不来）。

## 矩阵（Android 16 真机，example debug 构建）

| 权限 | status（重装后） | normalize granted | 复核 | reset | 复核 |
|---|---|---|---|---|---|
| camera | `notDetermined` | → `granted` | `granted` | → `notDetermined` | — |
| microphone | `notDetermined` | — | — | — | — |
| locationWhenInUse | `notDetermined` | — | — | — | — |
| notifications | `notDetermined` | → `granted` | `granted` | — | — |

`requiresRestart` 按当前状态推导并在真机复核：`granted` 时为 `true`，未授予时为 `false`。这条不是
装饰——撤销一个已授予的运行时权限会让 Android 终止应用进程（确定性系统行为），矩阵里 `reset camera`
之后会话随即消失，正是该字段要提前告诉调用方的事。

与接入方矩阵的差异：example 声明了 `POST_NOTIFICATIONS`，所以四个 P0 权限都有事实；被试的接入方
应用没有声明它，于是那一格返回 `permissionUnsupported`——同一个稳定 code 既表示「平台不支持」又表示
「这个应用没声明」，两者处置不同，需要区分（见接入方报告）。

## 仍未覆盖

- 真实系统弹窗 `exercise`：`companions/` 下只有抽象 runner 源文件，没有可构建安装的 instrumentation
  工程，因此「reset → 触发应用请求 → 处理弹窗 → 复核 → 恢复」闭环未跑。
- `normalize --state denied`：`pm revoke` 只能到 `notDetermined`，真正的拒绝只能由用户在弹窗上产生。
- capability 仍是「runner 路径非空」而非逐权限逐 decision 探测。
- iOS：`status` / `normalize` 目前类型化返回不支持，`reset` 只认 Simulator。

## 顺带修掉的两个脚本缺陷

- `example_session_redact` 被两处失败路径引用却从未定义，于是 App 起不来时 `command not found`
  把日志尾部一起吞掉——恰好是唯一需要它的时刻。
- 参考声明器最初等到 URI 才写记录，而 `patchbay launch` 的声明窗口更短，于是它在子进程还在构建时
  就判 `sessionNotDeclared` 失败。正确顺序是先声明 pending 记录、再补传输（`withTransport`），
  且「尚无传输」必须用 `null` 而不是空字符串——监督循环按 `wsUri == null` 判断这件事。
