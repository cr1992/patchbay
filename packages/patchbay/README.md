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
- Flutter 文本 target、规范化 Semantics 树与 policy-gated 标准 action；
- VM Service client 和 Flutter Widget/Render/Focus 诊断 extension 代理。

下列能力仍属于设计方向，不是当前公共 API：

- 自动会话发现和 stale session 文件清理；
- 不依赖 VM Service 端口转发的局域网/反向 WebSocket 传输；
- 结构化日志 query/tail/watch/export；
- Flutter 语义导航、wait 和 capture。

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

`source` 采用层级继承：对象上的来源适用于其未另行标注的后代；更深层字段可以用自己的 `source`
覆盖。例如整个 snapshot 可标为 `appRecorded`，其中一条状态读回再明确标为 `deviceReported`。这样每个
叶子都有可解析来源，同时避免把每个标量包装成 `{value, source}`。descriptor 的 `factSources` 只是
可能来源的闭集，实际 payload 上的 `source` 才是该次结果的事实。

## Wire contract 与生成代码

协议层的 descriptor、invocation、job、UI target 和 Semantics tree DTO，以及 Moii 试点的配网快照与终态
证据，都从 JSON contract 生成双向 codec。生成物负责字段名、枚举、嵌套结构、未知字段拒绝、JSON 值
校验和 `toJson` / `fromJson`；任何 consumer 不再手写协议 map。

仍需人工维护的是语义投影：领域状态对应哪个稳定枚举、哪些字段必须脱敏、事实来源强度和什么才算业务
终态。这些判断必须用穷举 switch 映射到生成 DTO，不能用 `runtimeType` / `toString()` 推导协议值。

契约格式与生成命令见 [contracts/wire-contract-v1.md](contracts/wire-contract-v1.md)。仓库统一入口是
`just gen patchbay-wire write|check`，两份零漂移检查已进入 commit、push 与 CI 门禁。

## Descriptor

`PatchbayCommandDescriptor` 是 CLI 帮助、参数校验和副作用提示的唯一来源，至少描述：

- 稳定完整命令名和摘要；
- `readOnly`、`immediate` 或 `job` mode；
- 参数类型、必填、默认值和枚举集合；
- consumer gate ID 集合；
- `none`、`appState` 或 `external` side-effect；
- 敏感参数策略。
- 结果中允许出现的 `factSources` 集合。

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

consumer 的异步 API 若只表示“订阅已建立/请求已发出”，job body 不能在该 Future 返回时直接记
`completed`，必须继续观察领域状态直到真实终态。consumer 已完成脱敏与稳定分类时可用
`PatchbayJobFailure` / `PatchbayJobCancellationSignal` 把结构化终态证据写入 job；普通异常仍只记录
`errorType`，避免把凭据或 vendor 响应体带出进程。

admission payload 可给出 consumer-neutral 的 `suggestedWaitTimeoutMs`。CLI 默认等待 60 秒；存在该提示
时使用提示值，但提示只决定观察窗口，不改变 job 的完成语义。

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

## 交付阶段与退出条件

阶段表是依赖闸，不是功能数量承诺。某个 consumer 可以在同一 worktree 连续实现多个批次，但不得用
后续代码量替代前置证据；当前实现范围仍以本文开头的“当前实现”为准。

所有新增或改变的 CLI 能力还有一道共同退出门：必须在真实 iPhone 或 Android 上完成
`启动 App → identity/catalog → CLI 调用 → 类型化结果/job 终态 → snapshot、UI tree 或外部读回` 闭环。
单元测试、fake、桌面 Dart VM 和仅证明 RPC 可连都不能替代真机闭环。平台中性的 Flutter/领域能力每批
至少一台真机；涉及原生平台、权限、transport、build mode 或宣称双端一致的能力，必须覆盖每个受影响
平台。无法安全执行解绑、写 DP 等副作用时，该项保持“未真机验证”，不能用只读邻近能力代为销账。

真机证据至少记录目标 commit、设备平台与 build mode、运行时 catalog 是否含目标命令、脱敏后的输入
类别、admission/job 事件序列、最终事实来源和可独立观察的完成证据。敏感值、VM Service 认证 URI 与
设备凭据不得进入记录。

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| v0.1a | 显式 URI 下的 identity、catalog、snapshot 和 schema/instance 校验 | 至少一个 iOS profile 真机会话跑通 extension 纵切；未跑通不得扩展 consumer 命令目录 |
| v0.1b | launcher machine protocol、会话文件、stale 与多会话选择 | 分片 machine 事件、原子写入、PID/wsUri/identity 三类 stale 判据和 URI 脱敏测试通过 |
| v0.2a | 无容器的 Widget/Render/Semantics 只读观察 | debug/profile 读取、节点上限、脱敏、generation 与 release 裁剪通过；不注入 action policy 时只读 |
| v0.2b | 标准 Semantics action 与单 Key 增强 | tap/scroll/focus/setText、gate await 后二次解析、敏感值、三模式 Key/State 等价性及 UI/领域门隔离通过 |
| v0.2c | DevTools 诊断代理 | extension 运行时发现、object group 释放、passthrough schema 与 extension 不可用失败语义通过 |
| v0.2d | 稳定导航与等待 | destination observer/revision/redirect/超时语义按需独立退出；不作为树驱动标准 action 的前置 |
| v0.3a | consumer runtime 所有权和类型化 invocation facade | 页面与 adapter 复用同一 controller/并发账本，生命周期和迟到 continuation 回归通过 |
| v0.3b | consumer 领域命令与 job | permit 单一所有权，失败/取消/撤回/generation 失效终态可测，并按共同真机门逐项验证本批 CLI 能力 |
| v0.4 | 结构化事件与日志；生成型 descriptor | tail 无敏感字段，生成真源全量映射，新增条目无需手改通用 CLI |
| v0.5 | 评估迁入共享仓 | 两个真实 consumer、连续兼容批次、consumer adapter 留在各 App，且发布维护者明确 |

## 风险登记

| 风险 | 必须保留的处置 |
|---|---|
| iOS profile 的 service extension 行为 | v0.1a 首个 spike 验证；未跑通不扩 consumer 命令集 |
| hot restart 后 extension、isolate 与实例漂移 | 每次连接重做 schema、isolate、`appInstanceId` 校验，不复用旧 identity |
| DevTools 与 CLI 多客户端共存 | 使用 DDS 暴露的 URI；真机纵切同时打开 DevTools 验证互不抢占 |
| 多设备或多 worktree 会话混淆 | 会话记录携带 workspace/device/instance 身份；歧义时要求显式选择 |
| VM Service URI 含认证信息 | 最小权限存储、普通输出脱敏、进程退出清理 |
| 大量 GlobalKey 影响重建 | 只标明确需要控制的目标；根观察不要求 Key；标准 harness 保留性能基线 |
| Flutter operator 随 SDK 漂移 | 只用公开 API，catalog 取运行时能力，每次 Flutter 升级跑 operator 契约测试 |
| capture 漏掉 PlatformView、texture 或系统 UI | 返回 capability warning，不把 Flutter PNG 宣称为完整物理屏幕 |
| Semantics 合并、offstage 或 ID 重复 | 只接受唯一且声明支持的动作；歧义时 fail-closed，不退化到 label 或坐标 |
| Widget Inspector schema 随 Flutter SDK 漂移 | 诊断代理标明 passthrough 与 SDK 版本；稳定自动化只消费 Patchbay 规范化 Semantics schema |
| Semantics 快照泄露输入值 | `isObscured` 强制隐藏 value，consumer 可注入更严格脱敏；敏感 setText 只接受 stdin |
| build mode 间 Key 种类漂移 | 所有模式保持同一种 GlobalKey 和 State 语义，release 只裁登记与 operator |
| UI 调试门绕过领域门 | descriptor 是 consumer gate 唯一真源；可能产生领域副作用的 UI action 显式声明强门 |
| registry、operator 或 callback 残留 release | AOT 做 extension/descriptor/operator/callback 引用扫描，并验证 root 只透传 child |
| 命令产生外部副作用 | descriptor 明示 side-effect；真机写操作遵守 consumer 的设备占用、备份与恢复纪律 |
| release 没有 VM Service | 明确非目标，不建立隐式降级或运行时后门 |
