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
      ref: patchbay-v0.2.0
      path: packages/patchbay_flutter
```

安装 CLI：

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.2.0 --git-path packages/patchbay_cli
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
- 敏感参数标 `sensitive: true`——值只能走 `--stdin`（不回显），强制由 host 完成，见下一节；
- handler 复用你既有的 controller / 并发约束，**不要**为 CLI 另建一套状态机。

#### 敏感参数由 host 强制，adapter 不用配合

`sensitive: true` 写在 descriptor 里就够了。客户端会用 `inputWasStdin` 标记「这个值来自无回显
stdin」，而这个键是**协议元数据，不是命令参数**。host 在把 arguments 交给你的 `domainInvoke` 之前
就把它消费掉：

1. **校验**——请求给任意一个 sensitive 参数带了非空值却没有该标记时，host 直接以
   `sensitiveInputRequiresStdin` 拒绝，`details.parameters` 按字典序列出违规参数名；你的 handler
   根本不会被调用；
2. **剥离**——校验通过后 host 把该键删掉，**手写 adapter 收到的 `arguments` 永远不含
   `inputWasStdin`**。

所以 handler 只管声明参数、按严格白名单校验、干活。

> **规范：host 已接管 sensitivePolicy 校验，手写 invoke 不得再依赖 `inputWasStdin` 键。**

catalog 是这条策略的唯一真源，host 读不到 catalog 时 fail-closed：带参数的调用以
`providerProtocolViolation`（`reason: catalogUnavailable`）拒绝，不会把未校验的参数交给 adapter。

**从旧版本升级：两步，都要做。**

1. 删掉 arguments 白名单里对 `inputWasStdin` 的豁免——host 不再传这个键，留着只是死代码
   （**不删无害**）；
2. 删掉 adapter 自己实现的 stdin 强制检查（形如 `if (args['inputWasStdin'] != true) reject(...)`
   或 `if (!args.fromStdin) reject(...)`）——**不删必炸**：host 剥键后该判断恒为假，所有合法的
   敏感调用都会被 App 侧误拒。

用 codegen 生成 typed 命令 API 的接入方，升级 pin 后重新生成即可。

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

`PatchbayKey` 的注册时机、代际推进规则，以及 `build()` 内裸构造导致丢状态的陷阱，见
[`patchbay_flutter/README` 的注册与重挂载语义](../packages/patchbay_flutter/README.md#注册与重挂载语义)。

#### ID 命名：三套校验口径不是同一套

标注前先分清三种 ID，它们的校验强度**不同**，混用会在不同的时刻炸：

| ID 种类 | 谁在校验 | 实际规则 | 违反时 |
|---|---|---|---|
| UI 目标 ID（`PatchbayKey.text/capture`） | `PatchbayUiTargetDeclaration` 构造函数 | 点分段，段内 `[A-Za-z0-9_-]`，不许空段 | 构造该 Key 时就抛 `ArgumentError`——在 Widget 构建处炸，不是被协议拒绝 |
| navigation destination ID | 同上，同一条正则 | 同上 | 同上 |
| 领域命令名（`ns.command`） | host 读 catalog 时 | **至少两段；每段小写字母开头；段内只许字母和数字** | 整份 catalog 作废 |
| Semantics `identifier` | 只要求非空 | 形状不校验 | —— |

两条要点：

1. **命令名禁连字符，也禁下划线。** `auth.switch-tenant` 不合法，要写成 `auth.tenant.switch`。
2. **违规的代价是整份目录，不是那一条命令。** host 发现非法或重名的命令名时，应答里干脆没有
   `commands` 键，`details.violations` 一次列全所有违规项并附上 `commandNamePattern`。
   于是 CLI 侧表现为"每条命令都找不到"（`catalogInvocationDrift`），而不是"某条命令没注册"。
   碰到这个码先跑 `patchbay catalog`——违规原因就在它的应答里，不必逐条命令试。

UI 目标 ID 的正则**允许**连字符，但建议直接按命令名的严格口径写（点分、小写、段内不带连字符）：
一套 ID 常量常常同时被拿来当 UI 目标、destination 和命令名用，按最严的那套写，跨面搬运时不会翻车。
这是约定，不是本仓的机检项——写了连字符的 UI 目标 ID 现在能跑。

#### 有组件库就把标注收口进组件层

call site 直接贴 `PatchbayKey` / `Semantics` 是**没有组件库时**的姿势。目标散落在各个页面时，
ID 无人总览、命名各写各的、改名要全仓 grep。有自家组件库的接入方应该往上收一层：

```dart
// 组件层：一个参数接进去，内部一次性接好两个身份空间
class AppTextField extends StatefulWidget {
  const AppTextField({super.key, this.patchbayId, /* … */});

  /// 调试目标 ID；不传即不登记，release 下整段不可达。
  final String? patchbayId;
}

class _AppTextFieldState extends State<AppTextField> {
  // Key 缓存在 State 里，不在 build() 内构造——理由见上面的链接。
  late final PatchbayKey? _key =
      (!kMyDebugToolsEnabled || widget.patchbayId == null)
          ? null
          : PatchbayKey.text(widget.patchbayId!);

  @override
  Widget build(BuildContext context) {
    final Widget field = TextField(key: _key, /* … */);
    return widget.patchbayId == null
        ? field
        : Semantics(identifier: widget.patchbayId!, child: field);
  }
}
```

```dart
// ID 台账：一处集中，改名有单一改点
abstract final class DebugIds {
  static const String loginPhone = 'login.phone';
  static const String loginSubmit = 'login.submit';
}
```

收口之后 call site 只多一个参数：

```dart
AppTextField(patchbayId: DebugIds.loginPhone, controller: phoneController)
```

三条落地建议：

- **两个身份空间一起接。** `PatchbayKey` 只换 Widget 的 `key`，**不会**顺带写 Semantics
  `identifier`；`ui wait semantics-mounted` 和 `ui tap` 走的又都是 Semantics 树。组件层同时接上
  两者（同一个 ID 字符串），接入方就不必记住"哪个命令认哪种标注"。
- **敏感性属于目标，不属于调用。** `PatchbayKey.text(..., sensitive: true)` 是**目标级**声明：
  该目标的所有写操作强制走 `--stdin`，否则以 `sensitiveInputRequiresStdin` 拒绝，回程 payload 只有
  `valueRedacted: true` 和 `length`，没有明文。正因为它不该由 call site 临时决定，密码、验证码
  这类组件适合在组件内部固定写死。
- **`inputWasStdin` 元键在两个平面的命运不同，别照抄。** 领域命令（`plane: domain`）的敏感性写在
  参数 descriptor 上，host 校验完就把这个元键**剥掉**，手写 adapter 永远看不到它（见
  [敏感参数由 host 强制](#敏感参数由-host-强制adapter-不用配合)）；UI 平面（`plane: flutterUi`）的敏感性
  是目标级的、参数 descriptor 表达不了，所以 host **保留**该元键交给桥自己读。写领域 adapter 时
  不要去读它，写 UI 桥扩展时才需要。

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
但那要求启动器接管 stdio 并自行转发按键，实测更脆，不是推荐路径。没有启动器时始终使用
`--ws-uri`。

## CLI 手册

### 连接

```console
$ patchbay identity                      # 已接 launcher：无参自动发现
$ patchbay --ws-uri '<uri>' identity      # 未接 launcher：使用 flutter run 打印的 URI
```

`<uri>` 可使用 VM Service 的 `http(s)` 或 `ws(s)` 形式。它通常包含认证信息，不要写入脚本、日志、
shell history 或提交物。

多个有效会话时要求显式选择，不猜——见[会话选择](#会话选择)。hot restart 后记录自动重锚，
不需要重启 CLI 或 `flutter run`。

### 会话选择

双设备并连（Android + iOS 同时跑）时会话不唯一，逐条命令敲长 `--session <id>` 很费。会话目录
本身有三条命令，它们**不连 App、不读 catalog**，只读写本地记录，因此在「CLI 选不出会话」时照样能用：

```console
$ patchbay sessions list                  # 有哪些记录，* 标记已固定的那条
$ patchbay session use <session-id>       # 固定一条，之后不带 --session 的命令都用它
$ patchbay session use --clear            # 取消固定
$ patchbay sessions prune                 # 删掉进程已经没了的记录
```

`session` / `sessions` 两种拼写都收（`session list` 与 `sessions list` 等价）。

**优先级链，三级，不混用：**

1. 命令行显式 `--session <id>` —— 永远最高，且不会顺手改掉固定项；
2. 已固定的会话 —— 有它就用它，即使目录里还有别的会话；
3. 都没有 —— 唯一会话直接用，多个会话以 `sessionAmbiguous` 拒绝并列出候选。

**固定项失效不回退。** 被固定的会话记录不见了、进程已死、或连不上时，命令以自己的稳定 code
失败（`sessionSelectionStale` / `sessionStaleProcess` / `sessionUnreachable`）并附一句处置提示，
**不会改用目录里另一条会话**——在双设备台上那意味着命令打到了另一台设备。固定项也不会被 CLI
自行清掉：清掉等于让下一条命令重新开始猜。要么 `sessions prune`，要么 `session use --clear`
之后重新选。`sessions prune` 只在它删掉的记录正是被固定的那条时才顺带取消固定。

`sessions list` 的 `status` 是**本地判定**，不是一次往返：`live`（进程在、URI 已落盘）、
`pending`（进程在、launcher 还没写 URI）、`stale`（进程没了）。列出 N 台设备不会变成 N 次连接
尝试，而一个「进程还在但已经不应答」的对端仍然显示 `live`——能不能连上只有真正的命令才知道，
它自带 RPC 预算。记录里的 VM Service URI 带认证 token，所以列表只打印 `scheme://host:port`，
路径一律不出（`--json` 的 `endpoint` 字段同样已打码）。

会话选择是「下一个进程连哪」的事，repl 里因此不可用：那条连接已经选定了。

### 常用命令

```console
$ patchbay catalog                          # App 实际注册了什么（唯一真源）
$ patchbay --json snapshot                  # 状态快照
$ patchbay --args '{...}' exec <ns.command> # 领域命令
$ patchbay --wait exec <ns.command>         # job 命令等终态
$ patchbay job get|cancel <job-id>
$ patchbay sessions list|prune               # 本地会话记录，不连 App
$ patchbay session use <id>|--clear          # 固定 / 取消固定会话
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
`semantics`，以及 `session` ↔ `sessions` 的互换，都是既有路径的别名拼写，不是新命令。

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

**动作之后确认页面切换或控件出现，用这两条，不要轮询整棵树**：等某个标注控件挂载是
`ui wait semantics-mounted <identifier>`（长轮询在 App 侧按帧推进，`--timeout-ms` 给上界，超时以
`uiWaitTimeout` 拒绝；同 identifier 挂载多个实例按 `uiSemanticsTargetAmbiguous` fail-closed 拒绝，
与 `ui tap` 的解析同源）；等导航落到某个 destination 是 `ui wait destination <destination-id>`。

两种拼写都能直接键入（`ui wait semanticsMounted app.ready` 与 `ui wait semantics-mounted app.ready`
等价），映射表也在 `patchbay help ui wait` 里。命令名与 condition 名都不会改——它们是 wire 契约。

`ui tap <identifier>` 面向带稳定 Semantics identifier 的可点控件：不用先读树抄 nodeId，解析与代际
校验都在 App 侧完成。`--generation` 可选，传了是你自己的前置围栏；不传时围栏由桥在过门前 pin 的
generation 提供。同 identifier 挂载多个实例、identifier 不存在、代际过期都是带 details 的稳定拒绝。

> `ui tap` 与 `ui semantics action` 需要 App 侧注入 `PatchbaySemanticsActionPolicy` 才会进 catalog
> ——默认 deny，没注入时这两条命令根本不出现在 `patchbay catalog` 里，调用得到
> `commandNotRegistered`（只读的 `ui semantics tree` 不受影响）。接法与 policy 语义见
> [`patchbay_flutter/docs/ui-inspection-and-actions.md`](../packages/patchbay_flutter/docs/ui-inspection-and-actions.md)。

### 超时与「对端不应答」

CLI 对**每一次** RPC 往返（含发现握手）都有预算，默认 30 秒，由 `--transport-timeout-ms` 调整；
两条传输都适用。预算耗尽时以退出码 `3` 和稳定 code `appUnresponsive` 失败，并附一句处置提示
（`--json` 时在 `details.hint`）——最常见的成因是移动端息屏后系统冻结了 App 进程，亮屏解锁即恢复，
见[边界](#边界)。

预算是**每次往返**的，但一条命令对不应答的对端只花**一个**预算：第一次没等到应答就结束整条命令，
后面的往返根本不会发出（`exec` 的 catalog 读没回来时，invoke 不会再试）。所以「单条命令的总失败
时间 ≈ 一个 `--transport-timeout-ms`」，不会按 RPC 段数叠加。判决作出即结束进程——被放弃的连接
（冻结对端的 WebSocket 握手无法从调用方取消）不会把 CLI 按在那里等操作系统回收。

对端**已死**（进程没了、端口无人监听）与**冻结**不同：内核立刻拒绝连接，CLI 在毫秒级以
`transportError` 失败，不等预算。把最清楚的失败拖成最不清楚的那一种没有意义，这条区分是有意的。

`--timeout-ms` 是**另一个量**，不要混用：它是请求 App 自己等多久（`ui wait`、`logs tail`、
`navigation go|push|back`、`capture`），会随请求发到 App 侧。声明了等待预算的请求，其 RPC 预算自动
放宽成「声明的等待 + 一次往返」，所以 `ui wait --timeout-ms 120000` 不会被 30 秒的默认预算腰斩；
`--wait` 的 job 长轮询同理。这也是不设「命令级总预算」的原因：那会把这类有意长等的命令一并砍掉。

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
| 3 | 无有效会话、连接失败，或对端在 RPC 预算内不应答（`appUnresponsive`） |
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
- 移动端息屏同理（Android 真机实测）：息屏后 UI 平面以 `*LifecycleNotResumed` 快速拒绝，
  协议面命令（`identity` / `catalog` / `logs` / `job`）短期内仍可用；息屏一段时间后系统可能
  冻结 App 进程（实测 MIUI），此时对端停止应答，CLI 请求在 RPC 预算（默认 30 秒）耗尽后以
  `appUnresponsive` 失败并给出处置提示，亮屏解锁即恢复。长会话调试的规避方式，按平台：
  - **Android**：`adb shell svc power stayon usb`（USB 供电期间屏幕常亮，即开发者选项的
    「充电时保持唤醒」），设备实验室标准做法，不改 App 行为。
  - **iOS 真机**：没有系统级等价命令（`devicectl` / libimobiledevice 均无电源控制），设备端
    只能手动把自动锁定设为「永不」。iOS 18 的 iPhone 镜像声称锁屏状态下可从 Mac 操作 App，
    可能可行，**未实测**。iOS 模拟器不锁屏，不受影响。
- 截图只证明 Flutter 合成树；系统弹窗、PlatformView 可能缺失，结果附能力警告。
- 系统权限弹窗、装卸包、shell、进程管理：用 adb / xcrun，Patchbay 不做。
- 直连 HTTP 明文、无 TLS，默认关闭；仅受信网络实验用途，边界见
  [`patchbay_transport/README`](../packages/patchbay_transport/README.md)。
- CLI 结果是调试证据，不是产品验收证据：证明 App 受理与 App 侧事实，不证明像素
  正确或设备物理行为。
