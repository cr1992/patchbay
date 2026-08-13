# Patchbay CLI

`patchbay_cli` 是 Patchbay 的 consumer-neutral 命令行客户端。它连接运行中的 Dart/Flutter App，
根据 App 实际返回的 catalog 调用命令，不依赖 consumer 代码，也不维护业务命令副本。

协议、生命周期和传输边界见 [`../patchbay/README.md`](../patchbay/README.md)，Flutter UI 控制面见
[`../patchbay_flutter/README.md`](../patchbay_flutter/README.md)。

## 当前命令

`PatchbayFriendlyCommand` 是 CLI 里唯一的命令表：路径解析、参数构造、dispatch 与帮助全部由它派生。
每条声明选一个 `PatchbayCommandTarget`，`runPatchbayCli` 对该 enum 做无 default 的 switch，因此新增
命令无法只接上执行而漏掉帮助。`exec` 的协议名来自调用方参数，`identity`/`catalog`/`snapshot` 与三棵
诊断树走 transport 方法而非 catalog 命令，这三类差异也写在声明里，由帮助按 target 分别措辞。

查看帮助不会发现会话、连接 App 或读取 bearer/敏感 stdin：

```text
dart run bin/patchbay.dart --help
dart run bin/patchbay.dart help
dart run bin/patchbay.dart help navigation
dart run bin/patchbay.dart help job
dart run bin/patchbay.dart help ui
dart run bin/patchbay.dart logs --help
dart run bin/patchbay.dart ui widget-tree --help
```

由 `flutter run --machine` launcher 启动 App 后，CLI 默认从用户临时目录发现唯一当前会话：

```text
dart run bin/patchbay.dart --json identity
dart run bin/patchbay.dart --json catalog
dart run bin/patchbay.dart --json snapshot
dart run bin/patchbay.dart --json exec <namespace.command>
```

多 App 或多 worktree 同时运行时不会按 PID、时间或当前目录猜测。CLI 以
`sessionAmbiguous` fail-closed，并打印不含 URI 的 session ID；调用方须显式选择：

```text
dart run bin/patchbay.dart --session <session-id> --json identity
```

`--ws-uri` 保留为 launcher 记录丢失时的恢复出口：

```text
dart run bin/patchbay.dart --ws-uri <uri> --json identity
dart run bin/patchbay.dart --ws-uri <uri> --json catalog
dart run bin/patchbay.dart --ws-uri <uri> --json snapshot
dart run bin/patchbay.dart --ws-uri <uri> --json exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json --args '{"value":42}' exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json --wait exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json job get <job-id>
dart run bin/patchbay.dart --ws-uri <uri> --json job cancel <job-id>
dart run bin/patchbay.dart --ws-uri <uri> --json ui text set <target-id> <generation> <text>
dart run bin/patchbay.dart --ws-uri <uri> --json ui text enter <target-id> <generation> <text>
dart run bin/patchbay.dart --ws-uri <uri> --json ui semantics tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui semantics action <node-id> <generation> <action>
dart run bin/patchbay.dart --ws-uri <uri> --json ui widget-tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui render-tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui focus-tree
dart run bin/patchbay.dart --ws-uri <uri> --json navigation catalog
dart run bin/patchbay.dart --ws-uri <uri> --json navigation current
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 4 navigation go settings
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 5 navigation push details
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 6 navigation back
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-mounted app.settings
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-unmounted app.loading
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-value app.status ready
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 4 ui wait destination settings
dart run bin/patchbay.dart --ws-uri <uri> --json ui wait tree-revision 10
dart run bin/patchbay.dart --ws-uri <uri> --json ui wait frame-revision 20
dart run bin/patchbay.dart --ws-uri <uri> --json --limit 100 logs query
dart run bin/patchbay.dart --ws-uri <uri> --json --cursor <cursor> --timeout-ms 5000 logs tail
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./logs.ndjson logs export
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./screen.png capture root
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./target.png capture target <target-id> <generation>
dart run bin/patchbay.dart --ws-uri <uri> --json blob metadata <blob-id>
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./artifact.bin blob get <blob-id>
```

所有命令（含 `exec`、`job`、`ui text`、`ui semantics` 与三棵诊断树）都对无关选项 fail-closed：
传入该命令不接受的选项时以退出码 `64` 报 `--<name> is not valid for <command>`，不静默忽略。

friendly command 只是稳定协议名的通用参数映射，不是另一份 capability 清单。CLI 每次执行仍读取
App 当前 catalog；catalog 与 invoke 结果矛盾时返回 `catalogInvocationDrift`，缺失命令仍保留 App 的
`commandNotRegistered` rejection 和退出码 `4`。CLI 从不按命令数量推断能力。完整命令名仍是协议身份，
任意 consumer 命令继续使用 `exec <namespace.command>`。

日志过滤支持 `--cursor`、`--direction`、`--limit`、逗号分隔的 `--levels`/`--categories` 以及
ISO-8601 `--since`/`--until`。capture 支持 `--pixel-ratio` 和 `--timeout-ms`。所有 artifact 下载先写同目录
临时文件，分块校验 blob metadata、offset、base64、总长度与 SHA-256，全部通过后才 rename；已有输出
默认拒绝，只有显式 `--force` 才替换。过期、拒绝、错序、哈希错误和中断不会留下完整输出名的残文件。

## 连接边界

`--ws-uri` 可能含 VM Service 认证信息：

- 只从可信 launcher 输出或当前调试会话取得；
- 不写入脚本、日志、快照和提交物；
- CLI 错误只报告错误类别，不回显完整 URI。

launcher 会先以原子替换写入 provisional 记录，再在收到 `app.debugPort` 后补 URI；CLI 连接并读取
`ext.patchbay.identity` 后才补齐 `appInstanceId` 和 `isolateId`。完整记录绑定 session schema、
`applicationId`、`appInstanceId`、`isolateId`、launcher PID、`wsUri`、build mode、创建时间、worktree
与设备 ID。记录默认位于当前用户的系统临时目录，可用 `PATCHBAY_SESSION_DIR` 覆盖。
launcher 仍会把 `app.log`、`app.progress` 和 stderr 以人可读形式回显，但统一替换其中的 http/ws URI；
`app.debugPort` 只显示“会话已发现”，永不回显 machine 事件载荷。

PID 存活只表示 launcher 可能仍在，不能证明 App 实例仍相同。以下任一情况都会删除记录并返回稳定的
session error：PID 不活、URI 不可连接、schema/identity 不匹配。hot restart 再次产生
`app.debugPort` 时 launcher 会原子重置已补齐的 identity，CLI 必须重新实测补齐；显式 `--ws-uri` 也会
执行同一 schema/isolate/appInstance identity 校验。launcher 退出时删除自己拥有的记录。POSIX 上目录和
文件分别收紧到 `0700` / `0600`，普通输出、错误和选择列表都不包含 URI/token。

当前命令执行路径自身不调用 ADB。不过在 Android 上，如果 URI 来自 `flutter run`，Flutter 的启动、
安装和端口转发仍可能间接使用 ADB；因此 VM Service 路径不能宣称端到端零 ADB。

CLI 也可连接 consumer 显式启动的 `patchbay_transport` direct host。direct host 不做发现，调用方必须从
可信的带外渠道取得 endpoint、runtime identity 和短期 bearer；token 只能从 no-echo stdin 读取，CLI
不提供 token argv/env/query 入口：

```text
dart run bin/patchbay.dart \
  --direct-endpoint http://192.0.2.10:12345/patchbay/direct/v1 \
  --direct-token-stdin \
  --direct-application-id dev.example.app \
  --direct-app-instance-id <instance-id> \
  --json identity
# CLI 在这里从当前 TTY 读取一行且不回显
```

上例是交互 TTY 形状；不要把 bearer 字面量写进 shell history。CLI 读取 bearer 时会自动关闭 echo。direct
LAN 是实验性的明文 HTTP：bearer 提供认证但不提供机密性，不能防止同网段被动监听和重放，不能称为
secure channel。应只在可信隔离网络和短 TTL 下显式启用；Flutter SDK 的 widget/render/focus diagnostic
extensions 仍只存在于 VM Service 路径。

## 输入与结果

普通结构化参数通过 `--args` 传 JSON object。descriptor 标记为敏感的参数必须把完整 JSON object 从
stdin 传入，并显式使用 `--stdin`；输出只保留 redacted 元数据。stdin 接管真实 TTY 时 CLI 会临时关闭
terminal echo，读取后恢复；无法关闭回显时以 `terminalEchoControlFailed` fail-closed。管道输入不修改
终端模式。

`admission=accepted` 只表示 App 已受理请求，不代表副作用已完成。长任务会返回 `jobId`：

- `--wait` 持续读取到终态；
- `job get` 读取当前快照；
- `job cancel` 请求取消，但取消结果仍以 App 返回的 job 状态为准。

`--wait` 默认最多等待 60 秒；descriptor/admission 带 `suggestedWaitTimeoutMs` 时采用 consumer 提示的观察窗口。
例如 BLE 配网提示 150 秒，以覆盖其 120 秒激活终态。超时表示 App 已受理但在观察窗口内没有终态，
归为类型化操作失败（退出码 `6`），不是连接失败。

host catalog 有 `patchbay.job.wait` 时，CLI 以 `afterSequence` 做 bounded long-poll，并在结果标记
`waitMode=serverLongPoll`。旧 host 没有该命令时保留 `patchbay.job.get` 兼容轮询，结果明确标记
`waitMode=legacyPolling` 和 `waitNotice`，不冒充服务端等待。`logs tail` 的 `outcome=timedOut` 是一次成功的
长轮询观察结果，退出码仍为 `0`，不会误报 transport error。

JSON 输出保留事实来源、rejection code、job event sequence 和 capability warning。CLI 不把这些字段
升级解释为设备执行成功、像素正确或系统 UI 已操作。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 请求完成，或 App 返回了可解析的非错误结果 |
| `3` | 会话发现、连接、传输或 VM Service RPC 失败 |
| `4` | schema/identity 不兼容，或目录中没有该命令 |
| `5` | App adapter 或 Flutter bridge 拒绝受理 |
| `6` | 已受理的 operation 返回 `outcome=failed`、job 失败/取消，或等待终态超时 |
| `64` | 命令格式、参数或本地输入不合法 |

调用方应同时读取 JSON 信封；退出码不承载设备完成性。

## 后续方向

Widget/Render/Focus 命令是 Flutter SDK 诊断 extension 的只读代理。输出带
`schema=flutterSdkPassthrough`，字段随 Flutter SDK 变化；profile 中对应 extension 不存在时稳定返回
`flutterDiagnosticUnavailable`。稳定自动化应消费 `ui semantics tree` 的 Patchbay schema。

navigation、wait、capture、结构化日志与 direct 仅在运行时 catalog/consumer host 实际注册时可用。CLI
不通过 ADB、坐标点击或 Widget 文本猜测补齐缺失能力，也不会替 App 自动启动 direct listener 或分发
bearer。日志是 consumer 已脱敏的 App 记录；capture 只证明 Flutter repaint boundary 的合成结果，不含
系统权限弹窗，PlatformView 也可能缺失。
三树与 action 的稳定命令、passthrough 边界和退出条件见
[`../patchbay_flutter/docs/ui-inspection-and-actions.md`](../patchbay_flutter/docs/ui-inspection-and-actions.md)。
