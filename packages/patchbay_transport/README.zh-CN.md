# Patchbay direct transport

[English](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_transport/README.md) | 简体中文

`patchbay_transport` 是与业务无关的纯 Dart 调试传输。它用固定 HTTP/JSON 协议承载
`identity`、`catalog`、`snapshot` 和 `invoke`，不依赖 Flutter、业务 App、plugin、VM Service 或 CLI。
包同时提供 host 与 client，产品装配层无需复制 wire codec。

## 安全边界

- 构造 host 不监听；只有显式 `start()` 才绑定 socket，默认 IPv4 loopback 和系统分配端口；
- 非 loopback 地址只有再显式选择
  `PatchbayLanExposure.experimentalSameTrustedNetworkOnly` 才允许绑定；没有 mDNS、广播、扫描或常驻发现；
- `Random.secure` 生成 256-bit、最长一小时的短期 bearer，只接受
  `Authorization: Bearer ...`；URI query 一律拒绝；
- session 和 client 的 `toString()` 隐去 token，类型化错误不带 token、请求体或 endpoint；本包不记录日志；
- 浏览器 `Origin` / preflight 默认拒绝，不返回 CORS 放行头；
- 每个响应关闭 HTTP 连接；默认同一时刻只处理一个请求，可配置硬上限 1–8；
- request body、response body、callback timeout 和 token TTL 都有硬上限；
- `stop()`、TTL、产品通知的 background / identity change、请求中检测到的 identity drift 或 handler timeout
  都停止接收新连接；
- 每个已认证请求仍必须在 JSON object 中携带 `schemaVersion`、`applicationId`、`appInstanceId`；
  host 在调用业务 handler 前重新读取 identity 并同时与启动身份、请求身份核对；
- `/patchbay/direct/v1/{identity,catalog,snapshot,invoke}` 是全部可达面。未知字段、路径、方法、query、
  content type 或 JSON 形状 fail-closed；没有远端任意方法反射。

LAN 模式是明文 HTTP。bearer 只提供持有者认证，**不提供机密性、服务端身份认证或重放防护**；同一
网络中的被动监听者可窃取 token 和全部载荷，主动攻击者也可冒充端点。因此 LAN 模式只能标记为
experimental，并仅用于受信任、隔离的同一网络；不能称为 secure。需要跨不受信网络时，应在产品层
增加经过评审的 TLS 与端点 pinning，不能靠本文档升级安全结论。

## 产品装配

本包不决定 debug/profile/release build policy。consumer 必须以编译期边界确保 release 不构造 host，
并自行提供显式用户入口、token 的带外分发、前后台通知和 identity 变化通知。token 不应进入普通日志、
错误、剪贴板历史、shell history、URL 或持久会话文件。

Android、iOS 与 HarmonyOS 都只消费本包的 `dart:io` socket；package 本身不包含 native 改动：

- Android：产品层负责选择并声明网络权限，只在允许的调试构建装配；本包不改 manifest；
- iOS：LAN 模式是否申请 Local Network 权限由产品装配层决定；本包不改 Info.plist、不触发权限
  弹窗；loopback 是否满足目标真机工作流也必须真机验证；
- HarmonyOS/CPF：本包不声明已通过 fork 编译或真机网络策略，接线时需单独验证。

前后台 hook 不是平台生命周期监听器；产品若漏接 `notifyBackgrounded()`，本包无法推断 App 已进入后台。
同理，本包无法安全地“发现”客户端，endpoint 与 token 必须由产品选择的带外渠道交付。

## 固定协议

所有请求是 `POST`、`application/json`，并在 header 中携带 bearer。基础请求：

```json
{
  "schemaVersion": 1,
  "applicationId": "dev.consumer.app",
  "appInstanceId": "short-lived-instance"
}
```

`invoke` 仅增加 `command`、`arguments` 和 `requestId`。command 是否存在、参数 schema、gate、并发所有权
和事实强度继续由注入 handler 负责；transport 不从字符串推导命令，也不把 `accepted` 升级为执行成功。
Direct client 会验证 handler result 回显同一个 `requestId`；不一致返回 `requestIdMismatch`，不会作为
业务结果交给调用方。空 `requestId` 在发送前以 `protocolError` 拒绝。

成功响应固定包含 schema、复核后的完整 identity 与 handler result。错误响应只含稳定 code：
`protocolError`、`unauthorized`、`expired`、`busy`、`bodyTooLarge`、`responseTooLarge`、`originDenied`、
`identityMismatch`、`identityDrift`、`timeout` 或 `internalError`。

## 验证

在本目录运行：

```sh
dart analyze
dart test --reporter expanded
```

测试使用真实 loopback socket，并单独拉起子进程验证 client/host wire 兼容；不以 mock HTTP 代替传输验收。
