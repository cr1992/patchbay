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
| `patchbay_cli` | VM Service/direct client、通用命令行和稳定输出 | 纯 Dart，不依赖 consumer |
| `patchbay_transport` | 显式启用的 direct HTTP/JSON host/client | 纯 Dart，不依赖 VM Service、Flutter 或 consumer |

consumer adapter、品牌命令别名、领域 DTO、路由映射和日志源都留在 consumer 工程。通用包不得
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
- consumer-neutral destination catalog/current/go/push/back 与类型化导航结果；
- 有界 `ui.wait` 条件 DTO（Semantics、destination、tree/frame revision）；
- consumer 注入的已脱敏结构化日志 `query` / `tail` / `export`；
- 带 TTL、总容量、SHA-256 和 offset/limit chunk 的通用内存 blob store；
- 可选 Flutter root/registered boundary PNG capture（由 `patchbay_flutter` 提供）；
- VM Service client 和 Flutter Widget/Render/Focus 诊断 extension 代理；
- 构造惰性、显式 `start` 的 direct HTTP/JSON host/client，复用同一组 transport-neutral dispatcher。

下列能力仍属于设计方向，不是当前公共 API：

- direct transport 的自动发现、TLS、端点 pinning 与反向连接；
- 持续日志 watch/job；
- 物理屏幕、系统 UI 或 PlatformView 的完整 capture。

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

Moii consumer 的 61 条领域命令目录以 `lib/debug_console/patchbay/contracts/patchbay_commands.json` 为唯一真源；
Flutter host 在不改该目录的前提下合并通用 UI 命令，并仅在 consumer 显式注入对应 bridge 时增加
navigation、日志、blob 与 capture 条目；因此运行时 catalog 是实际能力，不维护固定总数。
`just gen patchbay-commands write` 生成 command ID/string parse、descriptor、默认值已应用的类型化参数入口，
以及权限、取消、等待和显式确认元数据；`just gen patchbay-commands check` 只读检查漂移。生成的
`dispatch` 把每个命令暴露为 required callback，commit gate 还会比对 adapter callback，因此新增契约
命令但未接业务 handler 会在生成/编译或专项检查阶段失败。snapshot、领域终态和 projection 的事实判断
仍由 consumer adapter 手写，不进入生成器。

命令生成器是 consumer-neutral 的：契约用 `apiPrefix` 决定生成类型与顶层符号前缀，并自行声明
`permissions` / `cancellations` 封闭词表；通用 generator 不包含 Moii、BLE、Wi-Fi 或 call 词汇。
`descriptorImport` 必须显式选择 consumer 已直接依赖的 descriptor export，且只接受
`package:patchbay/patchbay.dart` 或 `package:patchbay_flutter/patchbay_flutter.dart`。生成器本身不硬编码
Flutter；Moii App 因当前直接依赖 `patchbay_flutter` 而选择后者，纯 Dart consumer 选择 core 包。

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

## 结构化日志与 blob

`PatchbayLogSource` 只是一条 consumer 注入的查询 seam。它不接管、复制或订阅 App 的日志管线；
consumer 先执行自己的 schema-aware 脱敏，再构造 `PatchbayRedactedLogRecord`。该类型额外拒绝常见敏感
字段名、Bearer/JWT/私钥形态，但这是防御层，不是万能脱敏器，也不能替代 consumer policy。

`logs.query` 与 `logs.tail` 同时受条数、编码字节和时间上限约束。cursor 是 consumer 的 opaque token；
source 必须保证同页唯一且 `nextCursor` 等于实际末条 cursor，过期 cursor 返回类型化 `staleCursor`。
长轮询 `tail` 是单次请求：到时返回 `timedOut`，service dispose/连接终止时 cancellation signal 关闭
consumer wait，不建立常驻 watch 或隐式后台订阅。首条记录本身超过响应上限时返回
`logRecordTooLarge`，绝不前移 cursor。

`logs.export` 把 NDJSON 写入同一个 `PatchbayMemoryBlobStore`。capture 也复用该 store；service extension
响应只返回 metadata/blobId，二进制由 `blob.read(blobId, offset, limit)` 分块读取。默认容量 16 MiB、
chunk 64 KiB、TTL 5 分钟（最大 15 分钟）；过期、越界、非法 chunk、单 blob/总容量超限都有稳定拒绝码。

## 传输

协议层不绑定某一种连接方式。VM Service extension 与 `patchbay_transport` 的 direct HTTP/JSON host
复用同一组 identity、catalog、snapshot 和 invoke dispatcher；consumer 不得为 direct 通道复制命令路由。
VM Service 模式在 Android 上仍可能由 `flutter run` 间接使用 ADB。direct 模式不依赖 VM Service 端口
转发，但是否真正 zero-ADB 仍取决于产品如何启动 App、交付一次性 endpoint/token 及平台网络策略。

direct host 构造不监听，默认只绑 loopback；LAN 必须显式选择
`experimentalSameTrustedNetworkOnly`。LAN 是明文 HTTP，bearer 只提供持有者认证，不提供机密性、服务端
身份认证或重放防护，因此：

- 只能在允许的 debug/profile 构建中可达；
- 必须有短期认证材料和 App 实例身份校验；
- 不得把认证 URI 或 token 写进普通日志；
- 不得改变上层 descriptor、invocation 和 job 语义。

更完整的固定协议与安全边界见
[`../patchbay_transport/README.md`](../patchbay_transport/README.md)。

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
| v0.1c | 显式 direct transport 产品装配 | 默认零监听、用户确认后 start、短期 token 不进日志/URL/持久化/剪贴板、前后台与 dispose 关闭、两 transport handler parity 通过；各平台 LAN 可达性分别真机验收 |
| v0.2a | 无容器的 Widget/Render/Semantics 只读观察 | debug/profile 读取、节点上限、脱敏、generation 与 release 裁剪通过；不注入 action policy 时只读 |
| v0.2b | 标准 Semantics action 与单 Key 增强 | tap/scroll/focus/setText、gate await 后二次解析、敏感值、三模式 Key/State 等价性及 UI/领域门隔离通过 |
| v0.2c | DevTools 诊断代理 | extension 运行时发现、object group 释放、passthrough schema 与 extension 不可用失败语义通过 |
| v0.2d | 稳定导航与等待 | destination observer/revision/redirect/超时语义按需独立退出；不作为树驱动标准 action 的前置 |
| v0.3a | consumer runtime 所有权和类型化 invocation facade | 页面与 adapter 复用同一 controller/并发账本，生命周期和迟到 continuation 回归通过 |
| v0.3b | consumer 领域命令与 job | permit 单一所有权，失败/取消/撤回/generation 失效终态可测，并按共同真机门逐项验证本批 CLI 能力 |
| v0.4 | 结构化事件、日志与 capture blob | wire DTO 全部生成，tail 无敏感字段，二进制不进入单个 extension 响应；consumer 接线与真机证据另批退出 |
| v0.5 | 评估迁入共享仓 | 两个真实 consumer、连续兼容批次、consumer adapter 留在各 App，且发布维护者明确 |

## 风险登记

| 风险 | 必须保留的处置 |
|---|---|
| iOS profile 的 service extension 行为 | v0.1a 首个 spike 验证；未跑通不扩 consumer 命令集 |
| hot restart 后 extension、isolate 与实例漂移 | 每次连接重做 schema、isolate、`appInstanceId` 校验，不复用旧 identity |
| DevTools 与 CLI 多客户端共存 | 使用 DDS 暴露的 URI；真机纵切同时打开 DevTools 验证互不抢占 |
| 多设备或多 worktree 会话混淆 | 会话记录携带 workspace/device/instance 身份；歧义时要求显式选择 |
| VM Service URI 含认证信息 | 最小权限存储、普通输出脱敏、进程退出清理 |
| 明文 LAN bearer 被监听或重放 | 只标 experimental/trusted-network，短 TTL、显式用户确认、后台即关闭；需要不受信网络时另立 TLS 与 pinning 设计 |
| iOS Local Network 策略阻断 direct LAN | consumer 未声明 Info.plist 时明确不承诺 LAN 可达；不得以纯 Dart socket 编译通过替代真机验收 |
| 大量 GlobalKey 影响重建 | 只标明确需要控制的目标；根观察不要求 Key；标准 harness 保留性能基线 |
| Flutter operator 随 SDK 漂移 | 只用公开 API，catalog 取运行时能力，每次 Flutter 升级跑 operator 契约测试 |
| capture 漏掉 PlatformView、texture 或系统 UI | 返回 capability warning，不把 Flutter PNG 宣称为完整物理屏幕 |
| Semantics 合并、offstage 或 ID 重复 | 只接受唯一且声明支持的动作；歧义时 fail-closed，不退化到 label 或坐标 |
| Widget Inspector schema 随 Flutter SDK 漂移 | 诊断代理标明 passthrough 与 SDK 版本；稳定自动化只消费 Patchbay 规范化 Semantics schema |
| Semantics 快照泄露输入值 | `isObscured` 强制隐藏 value，consumer 可注入更严格脱敏；敏感 setText 只接受 stdin |
| build mode 间 Key 种类漂移 | 所有模式保持同一种 GlobalKey 和 State 语义，release 只裁登记与 operator |
| UI 调试门绕过领域门 | descriptor 是 consumer gate 唯一真源；可能产生领域副作用的 UI action 显式声明强门 |
| registry、operator 或 callback 残留 release | `just check release_debug_surface`（`tools/checks/release_scan.py`）对 release 产物的 `libapp.so` 与 `classes*.dex` 做 extension/descriptor/operator/callback 引用扫描，产物缺失时明确报跳过而非通过；另需验证 root 只透传 child |
| 命令产生外部副作用 | descriptor 明示 side-effect；真机写操作遵守 consumer 的设备占用、备份与恢复纪律 |
| release 没有 VM Service | 明确非目标，不建立隐式降级或运行时后门 |
