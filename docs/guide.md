# 使用指南

> App 怎么接、CLI 怎么用。为什么这样设计见 [设计](design.md)。

## App 接入

### 1. 依赖

```yaml
dependencies:
  patchbay:
    git: { url: <repo>, ref: patchbay-vX.Y.Z, path: packages/patchbay }
  patchbay_flutter:   # 需要 UI 操作才加
    git: { url: <repo>, ref: patchbay-vX.Y.Z, path: packages/patchbay_flutter }
```

### 2. 组合根注册（唯一必做项）

```dart
/// 你的编译期门。release 下为 false 时，整棵 Patchbay 装配被 tree-shake。
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

最小可运行示例：[`patchbay_flutter/example`](../packages/patchbay_flutter/example)。

### 3. 领域命令（可选，按需累加）

每条命令 = 一个 descriptor + 一段调你自己 controller 的胶水（约 10–15 行）：

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

### 4. UI 目标标注（可选，一行一个）

```dart
// 文本输入：换 key（release 下退化为普通 GlobalKey，不登记）
TextField(key: PatchbayKey.text('login.phone'), controller: phoneController)

// 可点控件：加稳定 identifier（本来就是无障碍属性）
Semantics(identifier: 'login.submit', child: SubmitButton())
```

ID 是 wire 契约：点分、小写、语义化（`<区>.<屏>.<控件>`），不含索引。
同一 ID 同时挂载多个实例会被 fail-closed 拒绝。

### 5. 会话自动发现（可选）

你的启动器包住 `flutter run --machine`，用 `patchbay_cli` 提供的 machine frame parser
与 session writer 落会话记录（含 `appInstanceId`），CLI 即可无参连接。没有启动器时
`--ws-uri` 直连永远可用。

## CLI 手册

### 连接

```console
$ patchbay identity                # 有会话记录：无参自动发现
$ patchbay --ws-uri <uri> identity # 无会话记录：直连 flutter run 打印的 URI
```

多个有效会话时要求 `--session` 显式选择，不猜。hot restart 后记录自动重锚，
不需要重启 CLI 或 `flutter run`。

### 常用命令

```console
$ patchbay catalog                          # App 实际注册了什么（唯一真源）
$ patchbay snapshot --json                  # 状态快照
$ patchbay exec <ns.command> --args '{...}' # 领域命令
$ patchbay exec <ns.command> --wait         # job 命令等终态
$ patchbay job get|cancel <job-id>
$ patchbay ui text set|enter <id> <gen> <text…>
$ patchbay ui semantics tree|action …
$ patchbay ui widget-tree|render-tree|focus-tree
$ patchbay ui capture root -o out.png
$ patchbay ui wait <condition> …
$ patchbay logs query|tail|export …
$ patchbay help <topic>                     # 帮助由声明生成
```

敏感值一律 `--stdin` 传入，输出只保留 redacted 元数据。

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

- 只支持 debug / profile。release 无 VM Service 且被编译期裁除，没有降级通道。
- 截图只证明 Flutter 合成树；系统弹窗、PlatformView 可能缺失，结果附能力警告。
- 系统权限弹窗、装卸包、shell、进程管理：用 adb / xcrun，Patchbay 不做。
- 直连 HTTP 明文、无 TLS，默认关闭；仅受信网络实验用途，边界见
  [`patchbay_transport/README`](../packages/patchbay_transport/README.md)。
- CLI 结果是调试证据，不是产品验收证据：证明 App 受理与 App 侧事实，不证明像素
  正确或设备物理行为。
