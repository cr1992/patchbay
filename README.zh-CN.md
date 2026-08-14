# Patchbay

<p align="center">
  <img src="docs/assets/patchbay-hero.svg" width="100%" alt="Patchbay：从终端安全连接正在运行的 Flutter App">
</p>

<p align="center">
  <strong>Talk to your running Flutter app the way adb talks to a device.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

<p align="center">
  <a href="#适合解决什么问题">适用场景</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#能做什么">核心能力</a> ·
  <a href="#架构与包">架构</a> ·
  <a href="docs/guide.md">使用指南</a> ·
  <a href="docs/design.md">设计</a>
</p>

Patchbay 是一条伸进 Flutter runtime 的类型化控制通道：从终端连接正在运行的 App，
读取带来源的状态、调用业务命令、按稳定 ID 操作控件，以及获取脱敏日志和截图。

adb 站在系统外面看设备；Patchbay 站在 App 里面看 runtime。对 iOS 来说，它补上了
系统工具无法提供的 App 内部调试面。

> **项目状态：** `v0.2.1`，源码方式使用；需要 Dart `>=3.11.0`，Flutter UI 能力需要
> Flutter `>=3.38.0`。控制面仅在 debug / profile 启用；package 可以参与 release 编译，但接入方
> 必须在组合根通过编译期分支让 host 与 adapter 保持不可达。

## 适合解决什么问题

| 使用 Patchbay | 继续使用 adb / xcrun |
|---|---|
| 读取 App 内部类型化状态 | 安装、卸载和启动 App |
| 调用 App 主动开放的业务命令 | 执行系统 shell |
| 操作 Flutter Semantics 或稳定 UI ID | 处理系统权限弹窗和其他 App |
| 获取 App 侧脱敏日志与 Flutter 截图 | 获取完整物理屏幕或原生 `PlatformView` 内部状态 |

Patchbay 不是 adb 的替代品，也不是坐标驱动的黑盒测试框架；两者组合使用才是完整的调试工具链。

## 快速开始

下面用 VM Service 跑通最短链路。完整的门禁、业务命令、会话发现和 direct HTTP 接入见
[使用指南](docs/guide.md)。

### 1. 添加 Flutter 依赖

当前 package 尚未发布到 pub.dev，请固定 tag 从 Git 引用：

```yaml
dependencies:
  patchbay_flutter:
    git:
      url: https://github.com/cr1992/patchbay.git
      ref: patchbay-v0.2.1
      path: packages/patchbay_flutter
```

`patchbay_flutter` 已导出 core API；纯 Dart 接入可改用 `packages/patchbay`。

### 2. 安装 CLI

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.2.1 --git-path packages/patchbay_cli
$ patchbay --help
```

如果全局命令不在 `PATH`，按 Dart 提示把 pub cache 的 `bin` 目录加入 `PATH`。

### 3. 在组合根注册

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  if (!kReleaseMode) {
    final gates = PatchbayGateEvaluator(
      baseGate: () => const PatchbayGateDecision.allow(),
      consumerGate: (id) => PatchbayGateDecision.reject(
        code: 'unknownConsumerGate',
        notice: 'No consumer gate named $id.',
      ),
    );

    PatchbayFlutterServiceHost(
      applicationId: 'com.example.app',
      bridge: PatchbayFlutterBridge(gates: gates),
    ).register();
  }

  runApp(const MyApp());
}
```

这段最小接入已能提供 identity、catalog、空 snapshot、Semantics 只读观察和 `ui.wait`。
Semantics action 默认拒绝；领域命令、截图、日志和导航都需要 App 显式注入对应能力。

需要稳定文本目标时，用 `PatchbayKey` 替换现有 Key。它是 `GlobalKey`，必须像普通
`GlobalKey` 一样缓存，不能在 `build()` 中每次重新构造：

```dart
late final PatchbayKey phoneKey = PatchbayKey.text('login.phone');

@override
Widget build(BuildContext context) => TextField(
  key: phoneKey,
  controller: phoneController,
);
```

### 4. 连接运行中的 App

运行 App，复制 `flutter run` 输出的 VM Service URI。Patchbay 同时接受 `http(s)` 和 `ws(s)` URI：

```console
$ flutter run
$ patchbay --ws-uri '<VM Service URI>' identity
$ patchbay --ws-uri '<VM Service URI>' catalog
$ patchbay --ws-uri '<VM Service URI>' --json snapshot
```

VM Service URI 通常包含认证信息，不要把它写入脚本、日志或提交物。接入 launcher 后可以把
`--ws-uri` 省略，详见[会话自动发现](docs/guide.md#6-会话自动发现可选)。多台设备同时连着时用
`patchbay sessions list` 看有哪些会话、`patchbay session use <session-id>` 固定一个，之后的命令
不必再逐条敲 `--session`，详见[会话选择](docs/guide.md#会话选择)。

catalog 中的 UI target 会返回当前 `generation`。声明了调用方代际围栏的写操作（如文本输入）
必须携带这个值，防止迟到的命令打到重挂载后的同名控件；`ui tap` 可以省略 generation，host 会在
解析 identifier 后钉住本次操作的代际：

```console
$ patchbay --ws-uri '<VM Service URI>' ui text set login.phone <generation> '13800000000'
```

## 能做什么

| 能力 | Patchbay 提供什么 |
|---|---|
| **状态** | `snapshot` 类型化快照，每个值带事实来源（App 记账 / 命令回显 / 设备上报 / UI 观测） |
| **业务命令** | 接入方注册的领域命令直调既有 controller；长流程走 job（受理 / 事件 / 终态） |
| **UI 操作** | 文本输入、Semantics action、三种诊断树、截图和条件等待，只作用于明确开放的目标 |
| **日志** | query / tail / export，所有出口统一脱敏 |
| **导航** | 按稳定 destination ID 跳转，不暴露任意 route 字符串 |
| **连续执行** | `repl` 在一次连接内逐行跑 typed 命令，每行自带退出码 |
| **帮助** | 由命令声明生成，使用 `patchbay help <topic>` 查看 |

```console
$ patchbay identity
$ patchbay --json snapshot
$ patchbay --wait exec pairing.ble.pair
$ patchbay ui semantics tree
$ patchbay ui tap login.submit
$ patchbay --output screen.png capture root
$ patchbay logs tail
$ patchbay repl < commands.txt
```

## 为什么是 Patchbay

普通外部自动化看到的是像素、文案和坐标；Patchbay 看到的是 App 主动暴露的语义与事实：

- **可信**：状态值携带事实来源，受理、执行和设备完成性不混为一谈；
- **可控**：每条命令经过基础门与声明门，只触达 App 明确开放的能力；
- **稳定**：UI 目标使用稳定 ID 和 generation 围栏，不依赖坐标、树序号或易变文案；
- **可裁剪**：接入方用编译期分支让 host 与 adapter 在 release 不可达，不留运行时重开入口。

这些不是传输层替 App 做出的保证。领域完成性、隐私脱敏、release 产物扫描和平台行为仍由接入方
根据自己的 controller、构建链与真机结果负责。设计理由见[六条设计立场](docs/design.md#六条设计立场)。

## 架构与包

<p align="center">
  <img src="docs/assets/patchbay-architecture.svg" width="100%" alt="Patchbay 架构：CLI 通过 VM Service 或 direct HTTP 进入 App 内的门禁控制面">
</p>

CLI 只面对统一协议。VM Service 是默认主通道；direct HTTP 是显式开启的可选通道。进入 App 后，
所有操作先过门禁，再分别交给 Flutter bridge、业务 adapter 或 artifact service；真正的状态机、
router、设备 SDK 和隐私策略仍由 App 自己拥有。

| Package | 依赖 | 职责 |
|---|---|---|
| [`patchbay`](packages/patchbay) | 纯 Dart | 协议、命令声明、信封、事实来源、门禁、job、blob |
| [`patchbay_cli`](packages/patchbay_cli) | 纯 Dart | CLI、会话发现、VM Service / direct client、输出与退出码 |
| [`patchbay_flutter`](packages/patchbay_flutter) | Flutter | Key / Semantics 操作、截图、导航与等待 |
| [`patchbay_transport`](packages/patchbay_transport) | 纯 Dart | 可选 direct HTTP；默认关闭，必须显式启动 |

业务 DTO、设备 SDK、路由和领域词汇都留在接入方 adapter，不进入这四个通用 package。

## 术语速查

| 文档术语 | 含义 |
|---|---|
| consumer / 接入方 | 使用 Patchbay 的 App 或它的适配层 |
| descriptor / 命令声明 | 命令名、参数、门禁、副作用和事实来源的结构化描述 |
| gate / 门禁 | App 在每次操作前执行的准入判断 |
| generation / 代际 | UI 目标每次重新挂载时变化的防误击版本号 |
| job / 长任务 | 通过事件与类型化终态表达的异步业务操作 |

## 文档

- **[使用指南](docs/guide.md)** — 安装、App 接入、CLI 手册、退出码与边界
- **[设计](docs/design.md)** — 架构、六条设计立场与传输选型
- **[Core package](packages/patchbay/README.zh-CN.md)** — 协议、信封、门禁、job 与 blob
- **[Flutter package](packages/patchbay_flutter/README.zh-CN.md)** — UI 观察、操作、导航与截图
- **[CLI package](packages/patchbay_cli/README.zh-CN.md)** — 完整命令和连接安全
- **[Direct transport](packages/patchbay_transport/README.zh-CN.md)** — HTTP 协议与 LAN 风险
- **[变更记录](CHANGELOG.md)** — 未发布与已发布的 API、协议和安全行为变化

## License

[MIT](LICENSE)
