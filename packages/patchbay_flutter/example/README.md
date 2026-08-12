# Patchbay Flutter minimal consumer

这个 example 只验证 consumer-neutral 接入面，不依赖 Moii，也不包含 Android/iOS 平台工程：

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

没有平台目录意味着这里不冒充真机 App。真机传输、端口发现与产品生命周期接线由真实 consumer
负责；本 example 只证明第二个 consumer 能用公开 API 完成 identity、catalog、Flutter observation 和
领域 invoke 闭环。
