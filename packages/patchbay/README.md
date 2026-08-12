# Patchbay

Patchbay 是一个 consumer-neutral 的 Dart 运行时调试协议。它让本机 CLI 能够连接一个正在运行的
Dart/Flutter App，读取运行时身份和目录、获取状态快照，并调用 consumer 明确注册的调试命令。

本包不认识具体 App、页面、设备 SDK 或业务领域。consumer 必须在自己的 adapter 中完成类型转换、
运行时门、并发所有权和事实裁决。

## Package 边界

| Package | 职责 | 依赖边界 |
|---|---|---|
| `patchbay` | 协议、service extension host、gate、descriptor、invocation、job | 纯 Dart，不依赖 Flutter 或 consumer |
| `patchbay_flutter` | 可选 Flutter target registry 与 UI operator | 只依赖 Flutter 和 `patchbay` |
| `patchbay_cli` | VM Service client、通用命令行和稳定输出 | 纯 Dart，不依赖 consumer |

consumer adapter、品牌命令别名、领域 DTO、路由映射和日志源都留在 consumer 工程。三个通用包不得
依赖 consumer feature、vendor adapter、设备 SDK 或 consumer observability。

Flutter 控制面的接入与语义导航设计见
[`../patchbay_flutter/README.md`](../patchbay_flutter/README.md)，CLI 用法见
[`../patchbay_cli/README.md`](../patchbay_cli/README.md)。

## 当前实现

当前代码已经提供：

- `ext.patchbay.identity`、`catalog`、`snapshot` 和 `invoke`；
- 命令 descriptor、参数 schema、gate ID、side-effect 和敏感策略；
- `accepted` / `rejected` invocation 信封；
- App 内 job registry、单调事件序号、取消和终态快照；
- Flutter 文本 target 与 VM Service client。

下列能力仍属于设计方向，不是当前公共 API：

- 自动会话发现和 stale session 文件清理；
- 不依赖 VM Service 端口转发的局域网/反向 WebSocket 传输；
- 结构化日志 query/tail/watch/export；
- Flutter 语义导航、tap、focus、scroll、wait 和 capture。

## 架构

```text
CLI / automation
       │
       │ Patchbay transport
       ▼
PatchbayServiceHost
       │
       ├── identity / catalog / snapshot
       ├── PatchbayGateEvaluator
       ├── PatchbayInvocationSource
       └── PatchbayJobRegistry
                    │
                    ▼
             consumer adapter
                    │
                    ▼
       existing runtime / controller / ports
```

协议只传递中立 JSON。领域状态必须先由 consumer adapter 转成中立 DTO；Patchbay 不从自由文本、
Widget 状态或命令名推导业务结论。

## Service extension

`PatchbayServiceHost` 注册四个稳定入口：

| RPC | 含义 |
|---|---|
| `ext.patchbay.identity` | App、isolate、schema 与实例 nonce |
| `ext.patchbay.catalog` | 当前实际注册的命令和动态 UI target |
| `ext.patchbay.snapshot` | consumer 提供的只读运行时快照 |
| `ext.patchbay.invoke` | 调用 catalog 中存在的命令 |

所有载荷带 `schemaVersion`。`appInstanceId` 在同一个 isolate 内稳定，hot restart 后必须变化；client
连接后必须重新校验 schema、isolate 和实例身份，不能只凭 PID 或旧 URI 判断会话仍有效。

## 结果信封与事实来源

外层信封只表达 handler 是否接纳请求：

```json
{
  "schemaVersion": 1,
  "requestId": "request-1",
  "admission": "accepted",
  "payload": {},
  "jobId": null,
  "rejection": null
}
```

`accepted` 不等于业务完成、设备执行或 UI 正确。协议不得增加容易被误读的外层 `ok`、`success`、
`executed` 字段。

payload 中的观测值应使用以下来源词汇：

| 来源 | 含义 |
|---|---|
| `appRecorded` | App 本地记账或请求回执 |
| `commandEcho` | 命令回显，不是外部状态 |
| `deviceReported` | 设备主动上报或可验证读回 |
| `uiObserved` | Flutter target、metrics 或 render tree 的直接观测 |
| `unknown` | 当前证据不足 |

consumer 可以增加领域内的细分字段，但不能把较弱来源升级成较强结论。

## Descriptor

`PatchbayCommandDescriptor` 是 CLI 帮助、参数校验和副作用提示的唯一来源，至少描述：

- 稳定完整命令名和摘要；
- `readOnly`、`immediate` 或 `job` mode；
- 参数类型、必填、默认值和枚举集合；
- consumer gate ID 集合；
- `none`、`appState` 或 `external` side-effect；
- 敏感参数策略。

consumer 可注册任意 namespace，例如 `cache.refresh` 或 `session.connect`。通用包不预留设备、配网、
呼叫或其他业务 namespace，也不在 CLI 维护第二份命令表。

## Gate

每次调用必须依次通过：

1. Patchbay 基础门：当前构建允许、host 启用、identity 有效；
2. descriptor 声明的 consumer gate。

```dart
final evaluator = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (gateId) => evaluateConsumerGate(gateId),
);
```

基础门不替 consumer 猜登录、隐私同意、数据准备或设备 ready。descriptor 是 consumer gate 的唯一
能力真源。未声明 gate 不会被通用层自动补上；会触发网络、文件、权限或外部设备动作的命令必须由
consumer 显式声明对应 gate。

service extension 没有对称注销能力，因此 consumer 状态撤回后 handler 仍必须逐次 fail-closed。

## Job

长操作不能伪装成立即命令。`PatchbayJobRegistry` 的基本契约是：

1. admission 返回 `jobId`；
2. job 先产生 `running` 事件，再进入单一终态；
3. 每个事件有单调 sequence、时间、phase、source 和 payload；
4. 取消只终止对应 job，不推导外部系统已经停止；
5. App/isolate 消失时 client 以连接终止收尾，不伪造 App job 终态。

consumer 负责把生命周期撤回、generation 失效和自身 runtime 销毁映射为稳定取消原因。

## 传输

协议层不应绑定某一种连接方式。当前实现以 Dart VM Service extension 为唯一 transport，CLI 接受显式
VM Service URI。命令执行本身不调用 ADB，但 Android 上由 `flutter run` 建立 VM Service 转发时，
launcher 底层仍可能使用 ADB，因此当前实现不是端到端 zero-ADB。

若 consumer 需要日常调试完全不依赖 ADB，后续 transport 必须满足相同 identity、catalog、gate 和
信封契约，可采用 debug-only 的局域网 WebSocket，或由 App 主动反连桌面 CLI。该 transport：

- 只能在允许的 debug/profile 构建中可达；
- 必须有短期认证材料和 App 实例身份校验；
- 不得把认证 URI 或 token 写进普通日志；
- 不得改变上层 descriptor、invocation 和 job 语义。

## Release 边界

consumer 必须用编译期常量让 Patchbay host、adapter 和注册调用在 release 不可达，不能只靠运行时
flag 隐藏入口。`patchbay` 不提供 release 后门或远程重开机制。

Flutter Key 的跨 build mode 语义由 `patchbay_flutter` 负责；core 只要求 release 中不存在 extension、
descriptor、operator 和 consumer callback 的可达引用。

## Consumer 接入原则

- 复用既有 runtime/controller，不为 CLI 另建一套状态机；
- 并发 permit、lease、generation 和取消所有权仍归 consumer；
- snapshot 只读现有状态，不隐式启动订阅或外部动作；
- 敏感值在进入 Patchbay 前完成脱敏，通用层不复制 consumer 的隐私规则；
- UI 观测、领域状态和外部设备结果分别标明来源，不能互相反推。

一个 consumer 的品牌入口可以转发到通用 CLI，但不得 fork parser、协议或 catalog。
