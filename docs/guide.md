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

自动发现不是 `flutter run` 自带行为，需要一层启动器把 VM Service URI 写成会话记录。推荐让
`flutter run` 自己把 URI 落盘，启动器只监视这个文件：

```console
$ flutter run --vmservice-out-file .dart_tool/patchbay/vmservice.txt
```

读到 URI 后用 `patchbay_cli` 的 session writer（`PatchbaySessionStore` + `PatchbaySessionRecord`）
写记录，`appInstanceId` 由 CLI 首次连上后补齐。这条路径不接管 `flutter run` 的 stdio：`r` / `R` /
`q` 与热重载输出照旧，启动器解析出问题也只影响发现，不会连交互一起毁掉。

包住 `flutter run --machine` 再解析 machine frame 仍然可行（它额外提供 `app.debugPort` 等事件），
但那要求启动器接管 stdio 并自行转发按键，实测更脆，已不再是推荐路径。没有启动器时始终使用
`--ws-uri`。

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
$ patchbay navigation go <dest>             # 不带 --revision 时自动先读当前 revision
$ patchbay ui wait <condition> …
$ patchbay logs query|tail|export …
$ patchbay help <topic>                     # 帮助由声明生成
```

`<gen>` 是 catalog 返回的 UI target generation。控件重新挂载后 generation 会变化；写操作必须携带
最近观察到的值，否则会以 `uiGenerationStale` 拒绝。

`patchbay help` 的 topic 除了 CLI 路径（`ui wait`），还接受 catalog 里的协议名——手上拿着
`navigation.go` 或响应里的 `ui.semantics.tap` 就能直接查，不必先反推 CLI 路径。多个 CLI 命令共用
一个协议名（`ui.wait`、`blob.metadata`）时列出它们。`navigate` / `nav` / `wait` / `tap` / `text` /
`semantics` 是既有路径的别名拼写，不是新命令。

### navigation 的 revision 围栏

`navigation go|push|back` 省略 `--revision` 时，CLI 先调 `navigation.current` 读当前 revision 再
派发，结果带 `revisionSource: navigation.current` 标记。围栏本身没变：revision 照样随请求发出，
读到与派发之间导航动过照样被 App 拒绝。需要用自己亲眼观察到的 revision 当围栏时显式传
`--revision`，此时不会多一次读取，也不会有该标记。

### ui wait 的 condition 名

`ui wait <子命令>` 是带连字符的 CLI 语法，响应 payload 里的 `condition` 是 wire 值，两者刻意不同名：

| 子命令 | payload `condition` |
|---|---|
| `ui wait semantics-mounted` | `semanticsMounted` |
| `ui wait semantics-unmounted` | `semanticsUnmounted` |
| `ui wait semantics-value` | `semanticsValue` |
| `ui wait destination` | `navigationDestination` |
| `ui wait tree-revision` | `treeRevision` |
| `ui wait frame-revision` | `frameRevision` |

两种拼写都能直接键入（`ui wait semanticsMounted app.ready` 与 `ui wait semantics-mounted app.ready`
等价），映射表也在 `patchbay help ui wait` 里。命令名与 condition 名都不会改——它们是 wire 契约。

`ui tap <identifier>` 面向带稳定 Semantics identifier 的可点控件：不用先读树抄 nodeId，解析与代际
校验都在 App 侧完成。`--generation` 可选，传了是你自己的前置围栏；不传时围栏由桥在过门前 pin 的
generation 提供。同 identifier 挂载多个实例、identifier 不存在、代际过期都是带 details 的稳定拒绝。

### 参数与敏感值

`--args` 传普通结构化参数，`--stdin` 从一行 no-echo stdin 读入。两者可以同时用：stdin 的 JSON
object 与 `--args` 合并，同名键以 stdin 为准。所以「可读的那半写在命令行、只有密文走 no-echo」是
标准用法，不必把整个 object 塞进 stdin；只给 stdin 不给 `--args` 仍然合法，那是合并的退化情形。
stdin 内容不是 JSON object（裸文本、数组）仍然报错。

descriptor 标了 `sensitive: true` 的参数只能走 stdin：它出现在 `--args` 里时 CLI 直接以用法错误拒发，
不会等到 App 再拒，错误信息只点名参数、不回显值。输出仍只保留 redacted 元数据。

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

带 `--json` 时 stdout 只会有一个 JSON 文档：要么是响应信封，要么是错误信封

```json
{"error": {"code": "sessionAmbiguous", "details": {"sessions": ["…"]}}}
```

字段与 App 的 rejection 信封同形（稳定 `code` + 自由 `details`），一个解析器读两种。用法错误的
`code` 是 `usageError`，具体句子在 `details.message`；session、protocol、transport 类错误用它们自己
的稳定 code。人读的那句话仍然只走 stderr，不会混进 stdout。不带 `--json` 时行为完全不变。

`--wait` 的终态结果里，**顶层 `jobId` 是稳定取值位置**——它就是这条命令受理的那个 job。
`payload.jobId` 是 App job snapshot 自带的字段，两处都保留，脚本读顶层那个。

## 边界

- 只支持 debug / profile。接入方必须用编译期分支让 release 不构造 Patchbay；仓库不提供运行时后门。
- UI 平面要求 App 处于 `resumed`。桌面端（macOS 等）窗口一旦失焦就是 `inactive`，此时
  `ui.semantics.*`、`ui.capture`、`ui.wait` 与 `navigation.go|push|back` 都会以
  `*LifecycleNotResumed` 拒绝。这是 fail-closed 设计——未 resumed 的引擎不出帧，请求只会永远等下去，
  拒绝比挂起诚实。无头自动化必须让目标窗口保持聚焦（别在跑用例时切到别的窗口）。
  更细粒度的判定（例如区分「失焦但仍在出帧」）是待评估的优化项，不在本版范围内，闸本身不放松；
  各桥的 resumed 要求见
  [`patchbay_flutter/docs/ui-inspection-and-actions.md`](../packages/patchbay_flutter/docs/ui-inspection-and-actions.md)。
- 截图只证明 Flutter 合成树；系统弹窗、PlatformView 可能缺失，结果附能力警告。
- 系统权限弹窗、装卸包、shell、进程管理：用 adb / xcrun，Patchbay 不做。
- 直连 HTTP 明文、无 TLS，默认关闭；仅受信网络实验用途，边界见
  [`patchbay_transport/README`](../packages/patchbay_transport/README.md)。
- CLI 结果是调试证据，不是产品验收证据：证明 App 受理与 App 侧事实，不证明像素
  正确或设备物理行为。
