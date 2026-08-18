# 使用指南

> 从安装到跑通，再到领域命令和自动发现。设计理由见[设计](design.md)，只想快速体验可先看
> [根 README](../README.zh-CN.md#快速开始)。

## 前置条件

- Dart `>=3.11.0 <4.0.0`；
- 使用 UI 能力时需要 Flutter `>=3.38.0`；
- App 必须以 debug 或 profile 构建运行；
- 当前 package 尚未发布到 pub.dev，需要从 Git tag 引用。

## 安装

### App 依赖

```yaml
dependencies:
  patchbay_flutter:
    git:
      url: https://github.com/cr1992/patchbay.git
      ref: patchbay-v0.2.0
      path: packages/patchbay_flutter
```

### CLI

CLI 每条命令起一个进程，启动开销**按条计费**，所以装成什么形态直接决定手感。三种形态：

| 形态 | 任意目录可用 | 启动 + 一次 `catalog` 往返 | 适用 |
|---|---|---|---|
| Release 预编译二进制（`0.3.0` 起） | 是 | ~45 ms | 只用 CLI；机器上不必有 Dart SDK |
| `dart pub global activate` app snapshot | 是 | ~160 ms | 需要 Dart SDK 的兼容形态 |
| 仓内 `dart run bin/patchbay.dart` | 要写全路径 | ~540 ms | 改 CLI 本身 |

> 数字是 macOS arm64 对同一个 example host 各连 8 次的中位数，同机同链路，只用于比较量级；
> 真机跨 USB 时连接本身的耗时会盖过这段差距。

> **坑：在接入方仓目录里 `dart run patchbay_cli:patchbay` 解析到的是该仓 pin 的版本。**
> `<包名>:<可执行文件>` 形式按**当前目录所属的包**解析，在接入方仓里那是它 pin 的 tag，不是你
> 手上的 CLI。表现是新命令「不存在」的用法错误（退出码 `64`），很容易被误读成 CLI 有 bug 或者
> 没编译。上面前两种形态都不受当前目录影响——这是推荐全局安装的主要理由，快只是附带的。写绝对
> 路径的 `dart run <仓路径>/bin/patchbay.dart` 同样不受影响，但它长且仍然按条付 JIT 启动。

#### pub global app snapshot（兼容形态）

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.2.0 --git-path packages/patchbay_cli
$ export PATH="$PATH":"$HOME/.pub-cache/bin"   # 装进这里，但它默认不在 PATH 上
$ patchbay --help
```

`dart pub global activate` 把可执行文件装进 `$HOME/.pub-cache/bin`，**这个目录默认不在 PATH 上**
（pub 自己会在安装末尾打这条警告）。把 `export` 那行写进 shell 配置，否则 `patchbay` 会
「装完了却找不到」。

装好的是一个冻结在该 tag 上、由 `dart` runtime 加载的 app snapshot：换 tag 要重新
`activate`，跑起来不会再解析依赖。它不是 `dart compile exe` 生成的独立原生 AOT 二进制；
不要把这条形态的耗时当作原生 AOT 基准。版本升级时同时更新 App 依赖和全局 CLI，避免 schema
或命令面漂移。

`0.3.0` 起 `patchbay_cli` 会发布到 pub.dev，届时 `dart pub global activate patchbay_cli` 即可，
不再需要 `--source git`。

#### 预编译二进制（`0.3.0` 起）

`patchbay-v0.3.0` 起，每个 tag 的 GitHub Release 附带三平台 AOT 产物
（`macos-arm64` / `linux-x64` / `windows-x64`）与一份 `checksums.txt`。产物自带运行时，
**目标机器上不需要 Dart SDK**，这是给「只用 CLI、不写 Dart」的人和 CI 镜像准备的形态：

```console
$ curl -fL -O https://github.com/cr1992/patchbay/releases/download/patchbay-v0.3.0/patchbay-0.3.0-macos-arm64
$ shasum -a 256 patchbay-0.3.0-macos-arm64      # 与同一 Release 的 checksums.txt 对照
$ chmod +x patchbay-0.3.0-macos-arm64
$ mkdir -p ~/.local/bin
$ mv patchbay-0.3.0-macos-arm64 ~/.local/bin/patchbay
```

Release 资产不携带可执行位，`chmod +x` 是必需的一步。用**浏览器**下载的 macOS 产物还会被
Gatekeeper 隔离，`xattr -d com.apple.quarantine <文件>` 解除；用 `curl` 下载不会。

如果目标是消除 Dart runtime 启动并验证 AOT 性能，必须使用本节产物。仅看到一个名为
`patchbay` 的全局命令并不能证明它是 AOT：`~/.pub-cache/bin/patchbay` 通常是启动 app snapshot
的 shell wrapper。

#### 开发 CLI 本身

改 CLI 时用仓内路径跑，改完即生效：

```console
$ cd packages/patchbay_cli && dart run bin/patchbay.dart --help
```

嫌每条命令等半秒，就把当前工作树编成 AOT 可执行文件（约 1.6 秒编一次，产物 7 MiB）：

```console
$ dart run packages/patchbay_cli/tool/build_cli.dart   # 仓根或包内调用均可
Built …/packages/patchbay_cli/build/patchbay (7.3 MiB)
```

产物落在 `packages/patchbay_cli/build/`（已 gitignore），放到 PATH 上即可任意目录直跑。它是
**当次编译时的工作树快照**，改完源码要重编——需要「改了立刻生效」时用 `dart run`。

`dart pub global activate --source path packages/patchbay_cli` 也能让 `patchbay` 指向工作树，
但**不要用于任何读 `--json` 输出的场景**：path 模式每次调用都会重新解析依赖，pub 把
`Resolving dependencies…` 打在 **stdout** 上，破坏了「`--json` 时 stdout 只有一个 JSON 文档」
这条约定，下游解析器会直接失败。要「任意目录可用」又要读 `--json`，用 AOT 产物。

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
[`patchbay_flutter/README` 的注册与重挂载语义](../packages/patchbay_flutter/README.zh-CN.md#注册与重挂载语义)。

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

### 5. 保持亮屏（可选，不接线就没有这个能力）

设备中途息屏会把整个 UI 面一起带走：`ui.*` / `navigation.*` 开始清一色回
`*LifecycleNotResumed`，再过一会儿系统冻结进程，CLI 只看得到 `appUnresponsive`。Android 有不碰
App 的外部解法（`adb shell svc power stayon usb`）；**iOS 真机没有**——`devicectl` 与
libimobiledevice 都不控制**电源**（`devicectl` 能把 App 拉回前台，那是另一回事），唯一的杠杆在
App 进程内的 `UIApplication.isIdleTimerDisabled`。所以长时间手动联调 iOS 真机时，这个开关是唯一
能让设备别睡的办法。

四个包都是纯 Dart / 纯 Flutter，不碰 platform channel。为一个调试开关把 `patchbay_flutter` 变成
plugin，或者引入第三方 wakelock 依赖，会改变每个接入方 release 构建链接的东西。所以框架只拿协议、
记账和租约，碰平台的那一行由 App 自己出：

```dart
PatchbayFlutterServiceHost(
  applicationId: 'com.example.app',
  bridge: PatchbayFlutterBridge(
    gates: gates,
    // Android: FLAG_KEEP_SCREEN_ON；iOS: UIApplication.isIdleTimerDisabled。
    keepAwakeDelegate: (bool enabled) => myPlatformChannel.setKeepAwake(enabled),
    // 可选：额外挂一道 consumer 门，门 id 会进 catalog descriptor。
    keepAwakeGates: const <String>{'my.debug.keepAwake'},
  ),
).register();
```

delegate 只在真正发生状态翻转时被调用，不会连着两次收到同一个值；抛异常是合法回答，请求以
`keepAwakeDelegateFailed` 拒绝，而不是记成一次并未发生的 hold。

**没接线也照样在 catalog 里。** 这点和 `ui.capture` / `navigation.*` 相反——那两个没注入就整条不出现。
操作者伸手找 keep-awake 恰恰是在屏幕刚黑、UI 面刚开始全拒的时候，此刻回 `commandNotRegistered`
等于什么都没说。所以命令留在目录里，回 `keepAwakeNotWired` 并指名缺的是哪个参数；
`patchbay ui keep-awake status` 用 `wired: false` 报同一件事，连试都不用试。

**默认关、显式开、会话断开自动还原。** 押着屏幕不灭会改变被观察 App 的行为（息屏行为本身也是接入方
要测的东西），所以没人开口就什么都不做。而两种 transport 都不给 App 连接生命周期——VM Service
扩展只管应答，不知道 CLI 死没死；终端被杀也不会道别。只靠显式 `off` 释放的 hold 会活过每一次崩掉的
会话，把设备一直点亮到没电。租约把这件事反过来：人还在就续租，人走了就不再续，于是**断开**和
**租约到期**在 App 看来就是同一件事。默认租约 10 分钟，上限 2 小时；App 销毁 debug 面时也会归还。

### 6. 会话自动发现（可选）

自动发现不是 `flutter run` 自带行为。`patchbay launch -- <consumer command>` 负责有界监督，consumer
仍负责提供真实的 App/device metadata 并声明自己的 session。推荐让 `flutter run` 自己把 URI 落盘：

```console
$ flutter run --vmservice-out-file .dart_tool/patchbay/vmservice.txt
```

`patchbay launch` 向 child 注入 `PATCHBAY_SESSION_DIR`、`PATCHBAY_LAUNCH_ID`、
`PATCHBAY_LAUNCH_OWNER_PID`。接入方用 `PatchbayLaunchContext.tryFromEnvironment` 判断是否处于受监督
启动；三项全无表示普通启动，部分存在则拒绝。参与 child 用 `pendingRecord` 写带完整必填 metadata 的
pending 记录，并显式传入真实 consumer/App `processId`；这个 PID 与 launcher `ownerPid` 各自独立。读到
URI 后用 `withTransport` 原子更新。launcher 不伪造 metadata、不解析 stdout 私有帧，
只认 `launchId + ownerPid` 都匹配的记录；identity 成功后才写入 `appInstanceId/isolateId` 并进入 `live`。

```console
$ patchbay launch -- flutter run --vmservice-out-file .dart_tool/patchbay/vmservice.txt
```

stdout 是稳定 machine frame；child stdout/stderr 作为人读日志转发到 stderr。没有执行上述声明步骤的
child 不会被猜成当前 App，而是在默认 120 秒预算耗尽后以 `failed/sessionNotDeclared` 终止。退避从
200 ms 指数增长、封顶 5 s 并带 `[50%,100%]` 抖动；hot restart 会重新校验并重锚 App instance。
稳定 `live` 状态每 5 秒观测一次；断连时恢复退避从 200 ms 重新起步，单次 identity probe 也受剩余
总预算和 child 退出约束。
consumer 内部仍可解析自己所用工具链的输出，但这是接入方实现，不是 launcher 的私有协议。没有
声明接入时始终使用 `--ws-uri` 或既有独立 session writer。

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

### 体检（doctor）

「连不上 / 没反应 / 命令全被拒」时先跑它，一次把四件事按依赖顺序查完，每项给
**现象 → 可能原因 → 建议动作**：

```console
$ patchbay doctor          # 人读
$ patchbay --json doctor   # 脚本读
```

| 检查项 | 查什么 |
|---|---|
| `session` | 本地会话目录：有几条记录、进程还在不在、不带 `--session` 会选中哪条 |
| `connection` | 真拨一次号并完成 identity 握手，报出 host 的 patchbay 版本与它声明的能力 |
| `catalog` | App 服不服目录、注册了多少命令与 UI target、命令面摘要复算得对不对 |
| `lifecycle` | 发一条只读 UI 探针（`ui.semantics.tree`，`maxDepth 0 / maxNodes 1`），看 UI 面答不答 |

**拨不通正是它被问的那个问题**，所以 doctor 自己拨号：连接失败在它这里是一条 finding，
不是命令终止。前一项失败时后面的标 `skipped`，报告不谎称查过够不着的东西；会话目录判定失败
时它连拨都不拨——目录已经说清没东西可拨了。

**退出码取第一处 failed 的类别**：会话 / 连接 `3`、catalog `4`、lifecycle `5`——就是
「换成普通命令撞上这一项时会拿到的那个码」，脚本判 doctor 与判原命令同构。只有 warning
（如会话不唯一、门未开）时仍是 `0`。

**它在跟哪个构建说话。** `connection` 一项报出 host 编译自的 patchbay 版本（`serverVersion`）
与它声明的能力（`features`）。CLI 和 host 是分开部署的——CLI 从终端装，host 跟着别人发布的
App 走——版本错配解释掉的故障比这里其它任何一项都多：

```console
$ patchbay --json doctor | jq '.doctor.checks[] | select(.check=="connection").details'
{
  "applicationId": "com.example.app",
  "appInstanceId": "a1b2c3",
  "schemaVersion": 1,
  "serverVersion": "0.2.1",
  "features": ["catalogDigest", "lifecycleState"]
}
```

老 host 不报版本时它明说「这个 host 不报自己的 patchbay 版本」，不留空让你猜。`features` 是
host 声明的能力，CLI 按声明降级而不是猜；**没有这个键**和 **`[]`** 是两个答案：前者是老 host
（关于它的能力什么都不能断言），后者是它说「我一个都没有」。所以 lifecycle 一项缺
`lifecycleState` 时，doctor 用 `lifecycleStateSource` 说清是哪一种，而不是一律印 `unknown`：

| `lifecycleStateSource` | 含义 |
|---|---|
| `hostReported` | host 报了状态，或探针被答复、CLI 自己看到了 |
| `featureUndeclared` | 这个 host 不声明 lifecycle 上报——**不是**关于 App 状态的结论 |
| `capabilityNotHonoured` | 声明了却没带，host bug |

**catalog 摘要。** host 服务的 catalog 带一份 `commands` 的稳定摘要，用来回答「App 声明的
能力面到底变没变」——注册顺序和排版不影响它，`uiTargets` 那种挂载态也不进摘要。CLI **自己
复算一遍**再给结论，不照抄 host 的说法：

| `catalogDigestCheck` | 含义 |
|---|---|
| `verified` | 复算一致 |
| `mismatched` | 对不上，另附 `catalogDigestRecomputed` |
| `unsupported` | 算法或覆盖面超出本版 CLI 认知，查不了——不等于「错了」 |

`unsupported` 时若还带 `catalogDigestCoversUnreadable: true`，说明 host 声明的覆盖面里有本版 CLI
读不懂的条目：同一份 details 里的 `catalogDigestCovers` 因此只是**能读懂的那部分**，比 host 实际
声明的要窄。CLI 不会把读不懂的条目丢掉后接着复算——丢完剩下的可能**恰好**是它认得的覆盖面，那样
就会对着一个并非按此口径算出来的值说 `verified`。

换个 App 构建后拿两次 `catalogDigest` 比一下，就知道命令面动没动。老 host 不带摘要不算问题，
CLI 也不会生造一个。

**能力失约单列警告。** host 声明了某能力却不兑现（如声明 `catalogDigest` 却不带摘要），
doctor 打一条 `capabilityNotHonoured` 警告——这是要归档的 host bug，不是停止调试的理由，
退出码仍是 `0`。

**活跃业务会话警示。** doctor 会读一次 snapshot，扫各领域里为 `true` 的布尔 `active`
（自顶层域起最多五层），命中就把路径原样打出来并劝阻 `force-stop` / `kill` / 卸载——
真机上强杀正在通话 / 配网中的 App，代价远大于等它。这是**结构化读法，不认领域词表**：
CLI 不认识任何 consumer 的业务名词，路径打出来由你判是不是误报。想让它认出来，把布尔
`active` 放在会话对象上即可（如 `snapshot.call.session.active`）。

App **连不上**时这条警示照样出，措辞换成「查不出设备上有没有活跃会话，按不安全对待」：
恰恰是那一刻最容易顺手强杀进程。

doctor 只读，不改会话目录、不删记录、不重连、不替你唤醒设备——解法它只写给你看。

### 常用命令

```console
$ patchbay doctor                           # 出问题先跑：会话/连接/catalog/lifecycle 逐项查
$ patchbay catalog                          # App 实际注册了什么（唯一真源）
$ patchbay --json snapshot                  # 状态快照
$ patchbay snapshot --path call.session      # 只取一个字段 / 子树
$ patchbay snapshot wait <dot.path> --until exists|absent|equals [<json>]
$ patchbay --args '{...}' exec <ns.command> # 领域命令
$ patchbay --wait exec <ns.command>         # job 命令等终态
$ patchbay job get|cancel <job-id>
$ patchbay sessions list|prune               # 本地会话记录，不连 App
$ patchbay session use <id>|--clear          # 固定 / 取消固定会话
$ patchbay ui text set|enter <id> <gen> <text…>
$ patchbay ui semantics tree|action …
$ patchbay ui tap <identifier>                # 一步：解析 + 代际校验 + 派发
$ patchbay ui verify-manifest <file>        # 声明 ↔ 运行时挂载对账
$ patchbay ui inspect on|off|status         # 设备端 widget inspector 选择模式（带租约，自动还原）
$ patchbay ui widget-tree|render-tree|focus-tree
$ patchbay --output out.png capture root
$ patchbay navigation go <dest>             # 不带 --revision 时自动先读当前 revision
$ patchbay ui wait <condition> …
$ patchbay ui keep-awake on|off|status      # 押住 / 归还 / 读屏幕常亮，接入方接线才有
$ patchbay logs query|tail|export …
$ patchbay help <topic>                     # 帮助由声明生成
```

`<gen>` 是 catalog 返回的 UI target generation。控件重新挂载后 generation 会变化；写操作必须携带
最近观察到的值，否则会以 `uiGenerationStale` 拒绝。

`patchbay help` 的 topic 除了 CLI 路径（`ui wait`），还接受 catalog 里的协议名——手上拿着
`navigation.go` 或响应里的 `ui.semantics.tap` 就能直接查，不必先反推 CLI 路径。多个 CLI 命令共用
一个协议名（`ui.wait`、`blob.metadata`）时列出它们。`navigate` / `nav` / `wait` / `tap` / `text` /
`semantics`，以及 `session` ↔ `sessions` 的互换，都是既有路径的别名拼写，不是新命令。

### 保持亮屏（ui keep-awake）

```console
$ patchbay ui keep-awake on                       # 默认租约（App 声明，当前 10 分钟）
$ patchbay ui keep-awake on --lease-ms 7200000    # 显式租约，上限 2 小时
$ patchbay ui keep-awake status                   # 只读，不续租
$ patchbay ui keep-awake off                      # 立刻归还，不等租约
```

`on` / `off` 是同一条协议命令 `ui.keepAwake.set` 的两种拼法，`enabled` 由**你敲的那个词**决定而不是
参数——`off` 不可能被一个多余的 flag 变成一次开启。`--lease-ms` 只属于 `on`：释放不带租约，读什么
都不带。不传 `--lease-ms` 时 CLI 什么都不发，默认值在 App 的 catalog descriptor 里，CLI 侧不留第二份
（留了就是会过期的那份）。

各 `outcome`：`engaged`（本次开启）、`renewed`（已经押着，只是续租，不会再调一次 delegate）、
`released`、`unchanged`（本来就没押着）、`observed`（`status`）。`source` 恒为 `appRecorded`——它说的
是 **App 让宿主做了什么**，不是「屏幕确实亮着」。Patchbay 不回读平台。

**平台释放失败时 hold 不落账，保持可重试。** delegate 抛错意味着平台没松手，此时把 `enabled` 记成
`false` 会让下一次 `off` 变成 `unchanged` 空转、再也不碰平台，屏幕就永久亮着且没有任何补救入口。
所以记账只在 delegate 成功后才落：失败时 `enabled` 保持 `true`、`lastRelease` 保持空，
`lastReleaseFailure` 带上失败类型，再敲一次 `off` 会真的再调一次平台。租约同理不撤——**它是没人
在场时唯一会替你重试的东西**，到期释放失败会在一个租约之后再试一次（与你选的租约同频，不是重试
风暴）。重新 `on` 属于你已经知情并主动改主意，会清掉这条陈旧失败。

**接入方没接线**时 `set` 回 `keepAwakeNotWired` 并在 notice 里点名 `keepAwakeDelegate`；`status`
不拒绝，回 `wired: false`。**App 不在前台**时 `on` 以 `keepAwakeLifecycleNotResumed` 拒绝并带上
`lifecycleState`（iOS 在后台设 `isIdleTimerDisabled` 是无效的，记下来等于记一件没发生的事）；
`off` 永远允许——归还屏幕不该是被拒的那个动作。**debug 面已销毁**时 `set` 回
`keepAwakeHostDisposed`（销毁时已经归还过），`status` 照常可读。

`doctor` 的 lifecycle 项在 iOS 上会顺带提这条命令：那正是「设备睡了、怎么让它别再睡」的场景，而
Android 的 `adb` 解法在 iOS 上不存在。

### snapshot 的字段选择与条件等待

`snapshot` 不带选项时仍是整树读，行为一个字没变。要盯一个字段时有两条：

```console
$ patchbay --json snapshot --path call.session.active
{"schemaVersion":1,"selection":{"path":"call.session.active","found":true,"value":true}}

$ patchbay snapshot wait call.session.active --until equals true
path=call.session.active found=true value=true wait=observed
```

`--path` 是**点路径**，段字符集与稳定 destination id 同一套（`[A-Za-z0-9_-]`）。取到什么就原样答什么
——叶子字段、整棵子树都一样，**不重塑、不汇总**；含点或其它字符的键无法被点路径无歧义寻址，那种
键仍然走整树读。路径写错（空段、空格、结尾的点）在 CLI 本地就以用法错误 `64` 挡下，不发请求。

**寻址根是 App 交出来的那张快照本身**，不是 CLI 打印的那个响应信封。两者只差协议自己盖上去的
`schemaVersion`——它不可寻址，否则 host 的字段会冒充成 App 发布的状态，操作者分辨不出来。

推论是：**App 自己怎么套，路径就得怎么写。** 本仓 `example/` 的参考接入方把状态平铺在顶层
（`--path counter`），而有的接入方会在自己的快照里再包一层：

```jsonc
// 某接入方的 snapshot 回调返回值
{"admission": "accepted", "source": "appRecorded", "snapshot": {"call": {…}}}
```

这时正确写法是 `--path snapshot.call.session.active`，`--path call.session.active` 取不到——那层
`snapshot` 是**该接入方自己的键**，不是协议字段，host 不会替谁拆包（拆了，平铺的接入方就全取不到
了）。拿不准就先跑一次不带 `--path` 的整树读，照着实际形状写路径；`patchbay doctor` 打印的活跃
会话路径也是同一套写法。

**取不到不是失败。** `selection.found: false` 时退出码仍是 `0`，并带一个 `miss` 说明取不到的原因
——整树读同样只是"没这个键"，一次读取不该因为答案是"没有"而变成错误：

| `miss` | 含义 | 该做什么 |
|---|---|---|
| `missingKey` | 某段的键不存在 | 等它出现，或核对键名 |
| `nullValue` | 某段是 JSON null | 同上；`null` 在本协议里等同"不在" |
| `notAnObject` | 中间段是个非对象值，后面的段无处可索引 | **改路径**——它与快照的形状矛盾 |

**只有等待会失败。** `snapshot wait` 由 App 侧长轮询（间隔 100ms，第一次探测不等待，所以条件已成立
就立刻答），条件在预算内没出现时以 `snapshotWaitTimeout` 拒绝，退出码 `5`——与 `ui wait` 超时同一
口径，脚本已有的分支照用。拒绝的 `details` 里带 `path` / `condition` / `timeoutMs` / `elapsedMs` /
`polls` 和 `observed`（最后一次解析结果），「等 `equals true`，一直看到 `false`」这半句才是决定
再等还是改路径的依据。观察到时响应里的 `wait.outcome` 是 `observed`。

条件是**闭合词表**，不是表达式语言：

| `--until` | 成立条件 |
|---|---|
| `exists` | 路径解析到非 null 值 |
| `absent` | 路径解析不到：键不存在或值为 null |
| `equals` | 解析到的值与声明值**结构相等**（`{"a":1}` 按内容比，不按引用） |

`absent` **不吃 `notAnObject`**：路径与快照形状矛盾时不算"字段不在"，否则一个写错的路径会安静地
报成功。`equals` 的比较值按 **JSON 字面量**读——`true` 是布尔，字符串要写成 `'"ready"'`；裸词会被
拒绝并把该加的引号写给你看。`null` 不接受，那是 `--until absent` 的事。

等待预算用 `--timeout-ms`（默认 5000，上限 2 分钟，与 `ui.wait` 家族同一上限）。**不必同时调
`--transport-timeout-ms`**：声明的等待会自动加进 CLI 的 RPC 预算，与 `--wait` 的做法一致——一次
有意的等待不是"对端不应答"。

**路径根本不存在时，超时会把可用的顶层键报给你。** 第一段就不存在的路径，等待表现和"字段还没来"
一模一样——白等满预算再超时，最容易被读成"条件还没发生"。所以这种情形下拒绝的 `details` 会多一个
`availableKeys`（App 快照的顶层键，排序），一眼就能看出是路径写错而不是等得不够久；路径解析到一半
才断的（真的在等某个字段）不会带这个键，免得指错方向。

**打到不认识选择器的老 App 时**，答复是稳定的 `snapshotSelectionUnsupportedByHost` 拒绝
（退出码 `5`），notice 里写明退路：改用不带 `--path` 的整树 `snapshot`，或把 App 侧 patchbay 升级到
支持选择器的版本。这是版本错配，不是连接故障——此前它表现为裸 `transportError`（退出码 `3`），
会把人引去查网络。

**预算是对答案的硬顶，不是探测的时间表。** 条件成立、但拿到它的那次读取已经越过预算时，答复仍是
`snapshotWaitTimeout`——超预算才拿到的成功，调用方已经不在等它了。墙上时间还可能再多出**一次快照
读取**的长度：consumer 的回调一旦在飞就没法中止。因此 App 侧 snapshot 回调本身慢过预算时，拒绝里的
`elapsedMs` 会明显大于 `timeoutMs`，那正是「慢的是快照源本身」的读法——该改的是那个回调，不是加大
预算。

App 的 snapshot 回调自己抛错时，答复是 `providerProtocolViolation` +
`details.reason: snapshotSourceFailed`，只带**异常类型**不带消息：那串消息是 consumer 的自由文本，
不该跟着协议信封出去。等待中途抛错直接以它收尾，不重试——读不出来的源不是等待能观察到的状态。

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
> [`patchbay_flutter/doc/ui-inspection-and-actions.md`](../packages/patchbay_flutter/doc/ui-inspection-and-actions.md)。

### UI 目标声明对账（ui verify-manifest）

接入方把「这个 App 应该开放哪些 UI 目标」写成一份 manifest，CLI 连上运行中的 App，把它与 catalog
的 `uiTargets` 对一遍，报三类偏差。**纯 CLI 侧比对**：不新增 wire 命令，App 侧零改动。

```console
$ patchbay ui verify-manifest ui-targets.json          # 人读：直接列出偏差条目
$ patchbay --json ui verify-manifest ui-targets.json   # 结构化报告
```

manifest 是 JSON（v1 只认 JSON），完整示例见
[`docs/examples/ui-targets-manifest.json`](examples/ui-targets-manifest.json)：

```json
{
  "version": 1,
  "targets": [
    {"id": "app.shell", "kind": "capture"},
    {"id": "login.password", "kind": "text", "sensitive": true, "destination": "login"}
  ]
}
```

| 字段 | 必填 | 含义 |
|---|---|---|
| `version` | 否 | 只接受 `1`；省略即 `1`，将来的版本号会被拒读，而不是当成 `1` 读 |
| `targets[].id` | 是 | 稳定 ID，与 catalog `uiTargets[].id` 是同一个 |
| `targets[].kind` | 是 | `text` / `capture`——词表就是 catalog `uiTargets[].kind` 的取值，不另立新词 |
| `targets[].sensitive` | 否 | 默认 `false`，对应 catalog 的 `sensitivePolicy`（`redacted` ⇔ `true`） |
| `targets[].destination` | 否 | 该声明属于哪个屏；v1 只用于过滤，不驱动导航 |

未声明的键、缺失的必填项、非法 `kind`、冲突的重复 ID 一律 fail-closed 拒读：退出码 `64`，
`--json` 的错误信封给稳定 code（`manifestInvalid` / `manifestUnreadable`）和
`details.field`，直接指到位置（形如 `$.targets[2].kind`）。文件内容本身不进信封。

三类偏差：

| 组 | 含义 |
|---|---|
| `declaredNotMounted` | manifest 有、运行时**此刻**没挂载；`runtime` 区分 `absent`（catalog 里没有这个 ID）与 `unmounted`（注册过但当前没挂载） |
| `mountedNotDeclared` | 运行时挂载着、manifest 里没有 |
| `propertyMismatch` | 两边都有但 `kind` / `sensitive` 对不上，逐字段给 `declared` / `runtime` |

**「未挂载」不等于「丢了」。** 对账范围是**当前挂载态**：非常驻控件不在当前屏本来就不该挂载，
所以输出如实说「当前未挂载」，不替你判成缺失。挂载状态与属性漂移是两个独立的轴，同一个 ID
可以同时出现在 `declaredNotMounted` 和 `propertyMismatch` 里。

`destination` 在 v1 只做过滤。manifest 里只要有一条写了 `destination`，CLI 就先读一次
`navigation.current`，然后只对账「没写 `destination`」和「`destination` 等于当前屏」的条目，其余
计入 `stats.skippedOutOfScope`；出现在别的屏的声明仍然算「已声明」，不会被报成挂载未声明。同一个
ID 可以在多条上重复，但每条都必须写各自不同的 `destination`——否则同一时刻会有两条声明去对同一个
运行时目标。逐屏自动巡检要驱动导航，不在 v1 内。

`destination` 与 `destinationSource` 一起读：`destinationSource` 为 `null` 表示 manifest 压根没
scope、没读过 `navigation.current`；为 `navigation.current` 而 `destination` 是 `null`，表示读了、
App 当时没有已落定的目的地。`navigation.current` 被拒时按该拒绝本身返回（退出码 `4` / `5`），不会
把 scope 的那半当成通过。

同一 ID 同时挂载多个实例（catalog 的 `ambiguous`）不算偏差——manifest 声明不了实例数——但桥对这种
目标拒绝一切操作，所以报告的 `notices` 会点名它，退出码不受影响。

退出码：全部相符 `0`，报告里有任一类偏差 `7`（见[退出码](#退出码)）。

### widget inspector 开关（ui inspect）

用 CLI 开关 Flutter 自带的**设备端 widget inspector 选择模式**——就是 DevTools 上那个「圈一下看
这块是什么 widget」。开着的时候设备上的点按会被 inspector 吃掉（不再传给 App），所以这条命令改的
是 **App 状态**（`sideEffect: appState`），不是一次观察。

```console
$ patchbay ui inspect on                 # 开，按 App 声明的默认租约
$ patchbay ui inspect on --ttl-ms 60000  # 开，租约 60 秒
$ patchbay ui inspect off                # 关，并释放租约
$ patchbay ui inspect status             # 只读：当前开关、租约剩余、上次释放原因
```

`on` / `off` 是同一条协议命令 `ui.inspect.select` 的两种拼法（布尔是参数，路径是给人敲的），
`status` 是另一条只读命令 `ui.inspect.status`。`--ttl-ms` 只跟 `on` 走：给 `off` 或 `status` 带上
是用法错误（退出码 `2`），因为租约是「开着的时候才会到期」的东西。

**租约到期自动还原，这是安全出口而不是便利功能。** 会话断开时 App 侧观察不到（两条传输都是
请求/响应，没有断连事件），所以「断开自动还原」在 App 侧只能表达成「静默即还原」：`on` 发出的每次
启用都带租约，租约走完没人续，桥就把开关放回**它接手前的值**。续租不会把 Patchbay 自己装上去的
`true` 当成基线。host 销毁（`dispose`）同样还原。

还原是有条件的：只有开关**仍是 Patchbay 装上去的那个值**时才回退。DevTools 写的是同一个标志位，
Patchbay 的租约到期不该伸手去掀别人刚拨的开关。反过来，`off` 是操作者的明确指令，即使接手前
本来就是开的也照关不误。

**release 构建如实拒绝，不给一个证明不了任何事的布尔。** 设备端 inspector 的 overlay 由
`WidgetsApp` 在一句 `assert` 里注入，只有 debug 构建成立；profile / release 下这个标志位写得进去、
读得回来，却永远不会有任何东西被渲染出来。所以桥在动手之前先问「这个构建能不能真的显示」，
答不上来就以 `inspectorUnavailable` 拒绝，`details.reason` 给出哪一种：

| `reason` | 含义 |
|---|---|
| `notDebugBuild` | 非 debug 构建，overlay 的注入点根本不执行 |
| `rootInspectorExcluded` | App 自己设了 `debugExcludeRootWidgetInspector`（通常是它要注入自己的 `WidgetInspector`） |
| `hostDisposed` | Patchbay host 已销毁，开关没有持租人了 |

被拒时**不写标志位、也不问 consumer gate**——一个永远渲染不出来的构建，用不着先去打扰接入方的
权限判断。

`hostDisposed` 挡的是一个竞态：请求正卡在 consumer gate 里等待时 host 被销毁。gate 返回后**不能**
继续把开关打开——那会留下一个开着的 inspector 和一个没人持有的租约，设备从此吞掉每一次点击。
所以 gate 恢复点会重查一次，已销毁就以 `hostDisposed` 拒绝，并且完全不碰 binding 标志位。销毁后
再发的调用（含只读的 `status`）同样按这个 reason 拒绝：一座已经拆掉的桥没有状态可报。

响应 payload 的 `source` 恒为 `appRecorded`：写标志位只是排了一次重建，不等于带 overlay 的那一帧
真的到过屏幕，所以这里不冒充 `uiObserved`。`selectionOnTap` 一并报出来，是为了让「模式开着但点按
没反应」不被误读成 Patchbay 的故障——那是 App 侧另一个开关。

> **默认关，要接入方显式打开。** App 不注入 `PatchbayInspectPolicy` 时，`ui.inspect.*` 根本不进
> catalog，调用得到 `commandNotRegistered`——与 `PatchbaySemanticsActionPolicy` 同一口径：「App 没
> 开这个」和「App 拒绝这次请求」是两个不同的答案。接法：
>
> ```dart
> PatchbayFlutterBridge(
>   registry: registry,
>   gates: gates,
>   inspectPolicy: const PatchbayInspectPolicy(
>     gates: {'debug.ready'},                 // 每次开/关都过这些 consumer 门
>     defaultLease: Duration(minutes: 5),     // 请求不带 --ttl-ms 时的租约
>     maxLease: Duration(minutes: 30),        // 请求带了也不许超过的上限
>   ),
> )
> ```
>
> 声明的 `defaultLease` 就是 catalog 里 `ttlMs` 的 `default`，也是这个桥真正发放的租约——文档、
> descriptor 与实现是同一个数。超上限的 `--ttl-ms` 以 `invalidInspectArguments` 拒绝，
> `details.maxTtlMs` 告诉你上限是多少。

同时开着 DevTools 时：两边写的是同一个标志位，但 Patchbay 直接写 binding，不会去发 DevTools 那条
extension state 变更事件，所以 DevTools 的按钮状态不会跟着 Patchbay 亮。以哪边为准看
`ui inspect status`。

perf 与 net 两批（VM RPC 性能面、请求画像）不在本批范围内，见
[台账](backlog.md)——net 画像还是 `design-gate`。

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

分不清是哪一种、或者不确定该不该动设备时，跑 [`patchbay doctor`](#体检doctor)：它把这两种
分开报，并在动手强杀之前提醒设备上可能有活跃业务会话。

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
不支持 repl（bearer token 会与命令流抢同一个 stdin）。`doctor` 在 repl 内也不可用：它诊断的是
「连接怎么建立的」，而这条连接已经建立；作为一次性调用跑。

**App 未 resumed 时会话会说出来。** 息屏 / 后台 / 桌面窗口失焦时每行 UI 命令都以
`*LifecycleNotResumed` 被拒，光看这个 code 猜不出该干什么。所以会话在**第一条**这样的拒绝之后，
把分平台解法打到 stderr（`--json` 的 stdout 仍然只有命令结果），一个会话只打一次。

这段提示是从 App 已经给出的拒绝里读的，会话**不会**为此额外发命令：唯一受 lifecycle 闸管的
只读命令会 `ensureSemantics()` 并催帧，等于替你改了被观测的 App——`patchbay doctor` 可以这么做
（是你点名要的体检），一条只是打开的会话不行。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | App 受理，且 snapshot/operation 返回非失败结果——**不代表设备执行成功** |
| 3 | 无有效会话、连接失败，或对端在 RPC 预算内不应答（`appUnresponsive`） |
| 4 | schema/identity 不兼容，或目录中没有该命令 |
| 5 | App adapter 或 UI 桥拒绝受理（门、参数、目标歧义…） |
| 6 | 已受理但业务返回类型化失败 / job 失败 / 等待超时 |
| 7 | 本地对账（`ui verify-manifest`）跑完了，报告里有偏差——App 这边一切正常应答 |
| 64 | 命令行用法错误，含拒读的 manifest 文件 |

脚本应同时读 JSON 信封；退出码不承载设备完成性。

**脚本和 agent 判定结果，请读 `--json` 的结构化字段，或直接取 patchbay 自己的退出码——不要在
管道之后取 `$?`。** `patchbay --json … | jq …` 之后的 `$?` 是 `jq` 的码，patchbay 判红也照样是
`0`；这是最容易把失败读成成功的一处。要在管道里拿到真正的码，用 `set -o pipefail`（或 bash 的
`${PIPESTATUS[0]}`），否则先把输出接到变量再解析。

`doctor` 不另立码：它报**第一处 failed 检查项**的类别（会话 / 连接 `3`、catalog `4`、
lifecycle `5`），只有 warning 时是 `0`。

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
  `patchbay doctor` 的 `lifecycle` 一项就是查这个，`repl` 会在第一条被拒的行之后打出分平台解法。
  更细粒度的判定（例如区分「失焦但仍在出帧」）是待评估的优化项，不在本版范围内，闸本身不放松；
  各桥的 resumed 要求见
  [`patchbay_flutter/doc/ui-inspection-and-actions.md`](../packages/patchbay_flutter/doc/ui-inspection-and-actions.md)。
- 移动端息屏同理（Android 真机实测）：息屏后 UI 平面以 `*LifecycleNotResumed` 快速拒绝，
  协议面命令（`identity` / `catalog` / `logs` / `job`）短期内仍可用；息屏一段时间后系统可能
  冻结 App 进程（实测 MIUI），此时对端停止应答，CLI 请求在 RPC 预算（默认 30 秒）耗尽后以
  `appUnresponsive` 失败并给出处置提示，亮屏解锁即恢复。长会话调试的规避方式，按平台：
  - **Android**：`adb shell svc power stayon usb`（USB 供电期间屏幕常亮，即开发者选项的
    「充电时保持唤醒」），设备实验室标准做法，不改 App 行为。
  - **iOS 真机**：没有系统级等价命令（`devicectl` / libimobiledevice 均无**电源**控制）。设备端可以
    手动把自动锁定设为「永不」；不想动设备设置时，接入方接线后可用
    [`patchbay ui keep-awake on`](#保持亮屏ui-keep-awake)——它是 App 进程内的杠杆，不是系统命令，
    因此**只在接入方注入了 delegate 时存在**。iOS 18 的 iPhone 镜像声称锁屏状态下可从 Mac 操作 App，
    可能可行，**未实测**。iOS 模拟器不锁屏，不受影响。
    **「屏幕黑着」和「App 掉到后台」是两回事**：后者不需要碰设备——已配对且屏幕已解锁时，
    `xcrun devicectl device process launch --device <udid> <bundle-id>` 能把 App 拉回前台
    （已实测）。`patchbay doctor` 的 lifecycle 解法里同时给这两条。
- 截图只证明 Flutter 合成树；系统弹窗、PlatformView 可能缺失，结果附能力警告。
- 系统权限弹窗、装卸包、shell、进程管理：用 adb / xcrun，Patchbay 不做。
- 直连 HTTP 明文、无 TLS，默认关闭；仅受信网络实验用途，边界见
  [`patchbay_transport/README`](../packages/patchbay_transport/README.md)。
- CLI 结果是调试证据，不是产品验收证据：证明 App 受理与 App 侧事实，不证明像素
  正确或设备物理行为。
