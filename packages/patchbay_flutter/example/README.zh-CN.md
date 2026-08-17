# Patchbay Flutter minimal consumer

[English](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/example/README.md) | 简体中文

这个 example 只验证通用接入面，不依赖任何业务 App，也不包含 Android / iOS 平台工程：

- 组合根注册一个 `PatchbayFlutterServiceHost`；
- App identity 为 `dev.patchbay.example`；
- consumer 自己声明 `example.counter.increment` 领域命令；
- `Semantics.identifier` 暴露稳定的计数值与按钮目标；
- 一个 `TextField` 只把现有 `key` 换成 `PatchbayKey.text`。

运行机械验收：

```text
flutter analyze
flutter test
```

没有平台目录意味着这里不是可直接 `flutter run` 的真机 Demo。真机传输、端口发现与产品生命周期
接线由实际 App 负责；本 example 用于证明公开 API 可以完成 identity、catalog、Flutter observation 和
领域 invoke 闭环。
