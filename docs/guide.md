# 使用指南

> 从安装到跑通，再到领域命令和自动发现。设计理由见[设计](design.md)，只想快速体验可先看
> [根 README](../README.md#快速开始)。

## 前置条件

- Dart `>=3.11.0 <4.0.0`；
- 使用 UI 能力时需要 Flutter `>=3.38.0`；
- App 必须以 debug 或 profile 构建运行；
- 当前 package 尚未发布到 pub.dev，需要从 Git tag 引用。

## 安装

Flutter App 添加：

```yaml
dependencies:
  patchbay_flutter:
    git:
      url: https://github.com/cr1992/patchbay.git
      ref: patchbay-v0.1.0
      path: packages/patchbay_flutter
```

安装 CLI：

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.1.0 --git-path packages/patchbay_cli
$ patchbay --help
```

版本升级时同时更新 App 依赖和全局 CLI，避免 schema 或命令面漂移。

## App 接入

### 1. 选择 package

Flutter App 通常只依赖 `patchbay_flutter`，它已经导出 `patchbay` 的 core API。纯 Dart App 或只需要
协议层时，改为引用同一仓库的 `packages/patchbay`。只有需要 direct HTTP 时才额外依赖
`packages/patchbay_transport`。

### 2. 组合根注册（唯一必做项）

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

/// 接入方的编译期边界。release 下不构造 host、bridge 或 adapter。
const bool kMyDebugToolsEnabled = !kReleaseMode && bool.fromEnvironment('MY_DEBUG');

void main() {
  if (kMyDebugToolsEnabled) {
    final gates = PatchbayGateEvaluator(
      baseGate: () => const PatchbayGateDecision.allow(),
      consumerGate: (id) => switch (id) {
        'my.domain.ready' => appIsReady
            ? const PatchbayGateDecision.allow()
            : const PatchbayGateDecision.reject(code: 'domainNotReady'),
        _ => PatchbayGateDecision.reject(code: 'unknownConsumerGate'),
      },
    );
    PatchbayFlutterServiceHost(
      applicationId: 'com.example.app',
      bridge: PatchbayFlutterBridge(gates: gates),
      domainCatalog: myAdapter.catalog,
      snapshot: myAdapter.snapshot,
      domainInvoke: myAdapter.invoke,
    ).register();
  }
  runApp(const MyApp());
}
```

上例使用额外的显式开关，运行时需要传入 `flutter run --dart-define=MY_DEBUG=true`。如果你的 debug / profile
构建始终允许 Patchbay，可以把常量简化为 `const bool kMyDebugToolsEnabled = !kReleaseMode`。

最小 API 示例：[`patchbay_flutter/example`](../packages/patchbay_flutter/example)。它没有 iOS / Android
平台目录，因此用于 analyze、test 和阅读接法，不是可直接 `flutter run` 的真机 Demo。

### 3. 领域命令（可选，按需累加）

每条命令由一份 descriptor（命令声明）和一段调用既有 controller 的 adapter 组成：

```dart
PatchbayCommandDescriptor(
  name: 'cache.refresh',
  summary: '刷新首页缓存',
  plane: PatchbayPlane.domain,
  mode: PatchbayCommandMode.job,          // readOnly | immediate | job
  sideEffect: PatchbaySideEffect.appState, // none | appState | external
  factSources: {PatchbayFactSource.appRecorded},
  gates: {'my.domain.ready'},
)
```

规则：
- 长流程用 `job` 模式——受理即返回 `jobId`，别让 CLI 干等；
- 敏感参数标 `sensitive: true`——CLI 会强制 `--stdin` 且不回显；
- handler 复用你既有的 controller / 并发约束，**不要**为 CLI 另建一套状态机。

Job registry 必须使用有限预算。默认值适合普通调试会话，也可以按 App 的资源成本调整：

```dart
final jobs = PatchbayJobRegistry(
  maxRunningJobs: 16,
  retainedJobs: 100,
  cancellationTimeout: const Duration(seconds: 3),
);
```

达到 `maxRunningJobs` 时，`start()` 会在 body 启动前抛出 `PatchbayJobCapacityExceeded`。adapter 应把它
转换成稳定 rejection（例如 `jobCapacityExceeded`），不要排入无界队列。取消 callback 超时后任务仍是
running；只有 controller 提供了真实终态，才能写入 completed / failed / cancelled。

没有 cancellation callback 时 `cancel()` 返回 `false`。callback 只有在 controller 已确认操作停止后才可
返回；若底层 API 只确认“取消请求已发送”，adapter 应继续观察真实终态，而不是提前释放运行名额。

会话收尾用 `cancelAll()`：所有 callback 并行发起，单个卡死的 callback 只消耗一次 `cancellationTimeout`，
不会把整批取消堵在后面。它返回逐 job 的 `PatchbayJobCancelOutcome`，adapter 不能把这次调用当作
“全部已停止”——`timedOut` / `callbackFailed` / `notCancellable` 的 job 仍在运行。

### 4. UI 目标标注（可选，一行一个）

```dart
// 文本输入：换 key；release 中仍保持同一种 GlobalKey 语义，但不登记调试目标
TextField(key: PatchbayKey.text('login.phone'), controller: phoneController)

// 可点控件：加稳定 identifier（本来就是无障碍属性）
Semantics(identifier: 'login.submit', child: SubmitButton())
```

ID 是 wire 契约：点分、小写、语义化（`<区>.<屏>.<控件>`），不含索引。
同一 ID 同时挂载多个实例会被 fail-closed 拒绝。

### 5. 会话自动发现（可选）

自动发现不是 `flutter run` 自带行为。需要由你的启动器包住 `flutter run --machine`，再用
`patchbay_cli` 提供的 machine frame parser 与 session writer 写入会话记录（含 `appInstanceId`）。
完成这层接入后 CLI 才能无参连接；没有启动器时始终使用 `--ws-uri`。

## CLI 手册

### 连接

```console
$ patchbay identity                      # 已接 launcher：无参自动发现
$ patchbay --ws-uri '<uri>' identity      # 未接 launcher：使用 flutter run 打印的 URI
```

`<uri>` 可使用 VM Service 的 `http(s)` 或 `ws(s)` 形式。它通常包含认证信息，不要写入脚本、日志、
shell history 或提交物。

多个有效会话时要求 `--session` 显式选择，不猜。hot restart 后记录自动重锚，
不需要重启 CLI 或 `flutter run`。

### 常用命令

```console
$ patchbay catalog                          # App 实际注册了什么（唯一真源）
$ patchbay --json snapshot                  # 状态快照
$ patchbay --args '{...}' exec <ns.command> # 领域命令
$ patchbay --wait exec <ns.command>         # job 命令等终态
$ patchbay job get|cancel <job-id>
$ patchbay ui text set|enter <id> <gen> <text…>
$ patchbay ui semantics tree|action …
$ patchbay ui tap <identifier>                # 一步：解析 + 代际校验 + 派发
$ patchbay ui widget-tree|render-tree|focus-tree
$ patchbay --output out.png capture root
$ patchbay ui wait <condition> …
$ patchbay logs query|tail|export …
$ patchbay help <topic>                     # 帮助由声明生成
```

`<gen>` 是 catalog 返回的 UI target generation。控件重新挂载后 generation 会变化；写操作必须携带
最近观察到的值，否则会以 `uiGenerationStale` 拒绝。

`ui tap <identifier>` 面向带稳定 Semantics identifier 的可点控件：不用先读树抄 nodeId，解析与代际
校验都在 App 侧完成。`--generation` 可选，传了是你自己的前置围栏；不传时围栏由桥在过门前 pin 的
generation 提供。同 identifier 挂载多个实例、identifier 不存在、代际过期都是带 details 的稳定拒绝。

敏感值一律 `--stdin` 传入，输出只保留 redacted 元数据。

### 连续执行（repl）

每条命令单独起进程要重新发现会话并重连，一条 1–3 秒。需要连着跑多条时用 repl：

```console
$ patchbay --json repl <<'EOF'
ui wait semantics-mounted app.settings
ui tap app.settings.save
ui semantics tree
EOF
```

repl 只做「连一次、连续执行」，命令语法与一次性调用完全相同；它不是宏系统，不做脚本录制、回放
或变量。每行结果自带 `exitCode`，进程退出码只描述会话本身（干净跑完 `0`，被错误终止则是该错误的
类别）。被拒绝或失败的行不终止会话，连接类错误终止——CLI 不会替你悄悄换一条连接。

连接类参数、`--json` 与 `--stdin` 在 repl 内逐行 fail-closed；敏感输入请用一次性调用。direct HTTP
不支持 repl（bearer token 会与命令流抢同一个 stdin）。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | App 受理，且 snapshot/operation 返回非失败结果——**不代表设备执行成功** |
| 3 | 无有效会话或连接失败 |
| 4 | schema/identity 不兼容，或目录中没有该命令 |
| 5 | App adapter 或 UI 桥拒绝受理（门、参数、目标歧义…） |
| 6 | 已受理但业务返回类型化失败 / job 失败 / 等待超时 |
| 64 | 命令行用法错误 |

脚本应同时读 JSON 信封；退出码不承载设备完成性。

### 输出

`--json` 稳定 JSON（可存档比对）；默认人读摘要；`logs tail` 为 NDJSON 流。

## 边界

- 只支持 debug / profile。接入方必须用编译期分支让 release 不构造 Patchbay；仓库不提供运行时后门。
- 截图只证明 Flutter 合成树；系统弹窗、PlatformView 可能缺失，结果附能力警告。
- 系统权限弹窗、装卸包、shell、进程管理：用 adb / xcrun，Patchbay 不做。
- 直连 HTTP 明文、无 TLS，默认关闭；仅受信网络实验用途，边界见
  [`patchbay_transport/README`](../packages/patchbay_transport/README.md)。
- CLI 结果是调试证据，不是产品验收证据：证明 App 受理与 App 侧事实，不证明像素
  正确或设备物理行为。
