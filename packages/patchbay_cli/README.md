# Patchbay CLI

`patchbay_cli` 是 Patchbay 的 consumer-neutral 命令行客户端。它连接运行中的 Dart/Flutter App，
根据 App 实际返回的 catalog 调用命令，不依赖 consumer 代码，也不维护业务命令副本。

协议、生命周期和传输边界见 [`../patchbay/README.md`](../patchbay/README.md)，Flutter UI 控制面见
[`../patchbay_flutter/README.md`](../patchbay_flutter/README.md)。

## 当前命令

当前实现显式接收 VM Service URI：

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
```

完整命令名是协议身份。consumer 可以在自己的工具入口提供薄别名，但通用 parser、输出、退出码和
catalog 解析不应复制到 consumer 工程。

## 连接边界

`--ws-uri` 可能含 VM Service 认证信息：

- 只从可信 launcher 输出或当前调试会话取得；
- 不写入脚本、日志、快照和提交物；
- CLI 错误只报告错误类别，不回显完整 URI。

当前命令执行路径自身不调用 ADB。不过在 Android 上，如果 URI 来自 `flutter run`，Flutter 的启动、
安装和端口转发仍可能间接使用 ADB；因此当前实现不能宣称端到端零 ADB。独立局域网或反向 WebSocket
传输属于后续设计，且不改变 catalog、gate 和 invocation 语义。

## 输入与结果

普通结构化参数通过 `--args` 传 JSON object。descriptor 标记为敏感的参数必须把完整 JSON object 从
stdin 传入，并显式使用 `--stdin`；输出只保留 redacted 元数据。

`admission=accepted` 只表示 App 已受理请求，不代表副作用已完成。长任务会返回 `jobId`：

- `--wait` 持续读取到终态；
- `job get` 读取当前快照；
- `job cancel` 请求取消，但取消结果仍以 App 返回的 job 状态为准。

`--wait` 默认最多等待 60 秒。超时表示 App 已受理但在观察窗口内没有终态，归为类型化操作失败
（退出码 `6`），不是连接失败。

JSON 输出保留事实来源、rejection code、job event sequence 和 capability warning。CLI 不把这些字段
升级解释为设备执行成功、像素正确或系统 UI 已操作。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 请求完成，或 App 返回了可解析的非错误结果 |
| `3` | 连接、传输或 VM Service RPC 失败 |
| `4` | schema/identity 不兼容，或目录中没有该命令 |
| `5` | App adapter 或 Flutter bridge 拒绝受理 |
| `6` | 已受理的 operation 返回 `outcome=failed`、job 失败/取消，或等待终态超时 |
| `64` | 命令格式、参数或本地输入不合法 |

调用方应同时读取 JSON 信封；退出码不承载设备完成性。

## 后续方向

下列能力尚未实现：

- 安全会话发现、identity 复核和 stale session 清理；
- 语义导航、focus、action、scroll、wait 与 Flutter capture 命令；
- consumer 注册的结构化 App 日志 query/tail/watch/export；
- 不依赖 VM Service 端口转发的独立调试传输。

这些能力必须继续由运行时 catalog 声明。CLI 不通过 ADB、坐标点击或 Widget 文本猜测补齐缺失能力。
