# Patchbay

**Talk to your running Flutter app the way adb talks to a device.**

调试 Flutter App 的 CLI：从终端直连正在运行的 App——读类型化状态、调业务命令、
按稳定 ID 操作控件、拉脱敏日志与截图。adb 站在系统外面看设备，Patchbay 站在
App 里面看 runtime；iOS 上它就是那个"不存在的 adb"。

```console
$ patchbay identity                        # 自动发现当前 flutter run 会话
$ patchbay snapshot --json                 # 类型化状态快照
$ patchbay exec pairing.ble.pair --wait    # 调业务命令，等 job 终态
$ patchbay ui text set login.phone 1 138…  # 按稳定 ID 输入，不是坐标盲点
$ patchbay ui capture root -o screen.png   # Flutter 合成树截图
$ patchbay logs tail                       # 脱敏日志流
```

## 能做什么

| | |
|---|---|
| 状态 | `snapshot` 类型化快照，每个值带事实来源（App 记账 / 命令回显 / 设备上报 / UI 观测） |
| 业务命令 | consumer 注册的领域命令直调 App controller，长流程走 job（受理 / 事件 / 终态） |
| UI 操作 | 文本输入、Semantics 动作、三种诊断树、截图、条件等待——只作用于显式标注的目标 |
| 日志 | query / tail / export，出口过脱敏 |
| 导航 | 稳定目的地 ID 跳转 |
| 帮助 | 全部由命令声明生成，`patchbay help <topic>` |

系统层的活（装卸包、权限弹窗、shell）不做，继续用 adb / xcrun——分工与边界见
[使用指南](docs/guide.md#边界)。

## 30 秒接入

```dart
// 组合根，一个编译期常量决定一切；release 彻底裁除（AOT 零符号残留，有 guard 钉住）
if (kMyDebugToolsEnabled) {
  PatchbayFlutterServiceHost(
    applicationId: 'com.example.app',
    bridge: PatchbayFlutterBridge(gates: myGates),
    domainCatalog: myAdapter.catalog,
    snapshot: myAdapter.snapshot,
    domainInvoke: myAdapter.invoke,
  ).register();
}
```

```dart
// 要控制的控件各标一行
TextField(key: PatchbayKey.text('login.phone'), controller: phoneController)
Semantics(identifier: 'login.submit', child: SubmitButton())
```

完整接入步骤（gates、领域命令、会话发现）见 [使用指南](docs/guide.md)；
可运行的最小示例在 [`patchbay_flutter/example`](packages/patchbay_flutter/example)（199 行）。

## 包

| 包 | 依赖 | 职责 |
|---|---|---|
| [`patchbay`](packages/patchbay) | 纯 Dart | 协议：descriptor、信封、事实来源、门、job、blob |
| [`patchbay_cli`](packages/patchbay_cli) | 纯 Dart | CLI：会话发现、VM Service 客户端、帮助、退出码 |
| [`patchbay_flutter`](packages/patchbay_flutter) | Flutter | UI 桥：Key / Semantics 操作、截图、导航、等待 |
| [`patchbay_transport`](packages/patchbay_transport) | 纯 Dart | 可选直连 HTTP（默认关闭，显式启动） |

业务永远不进这四个包；设备 SDK、路由、领域词汇都留在 consumer adapter。

## 文档

- **[使用指南](docs/guide.md)** — App 接入、CLI 手册、退出码、边界
- **[设计](docs/design.md)** — 六条设计立场、架构与时序图、为什么需要 App 合作接入

## License

MIT
