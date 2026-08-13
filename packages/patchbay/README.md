# patchbay

`patchbay` 是 Patchbay 的纯 Dart 协议与 host package。它让本机客户端连接正在运行的 Dart / Flutter
App，读取 runtime identity、catalog 和 snapshot，并调用 App 明确注册的调试命令。

本 package 不认识页面、设备 SDK、路由或业务领域。使用 Patchbay 的 App（下文称“接入方”）需要在
自己的 adapter 中完成领域类型转换、门禁判断、并发所有权、脱敏和事实裁决。

完整上手流程见[仓库 README](../../README.md#快速开始)。Flutter UI 接入见
[`patchbay_flutter`](../patchbay_flutter/README.md)，CLI 用法见
[`patchbay_cli`](../patchbay_cli/README.md)。

## Package 边界

| Package | 职责 | 依赖边界 |
|---|---|---|
| `patchbay` | 协议、service extension host、门禁、命令声明、调用信封、job、日志与 blob | 纯 Dart |
| `patchbay_flutter` | 可选 Flutter UI、Semantics、导航、等待与截图 bridge | Flutter + `patchbay` |
| `patchbay_cli` | VM Service / direct client、会话发现、命令行和稳定输出 | 纯 Dart |
| `patchbay_transport` | 显式启用的 direct HTTP/JSON host/client | 纯 Dart，不依赖 VM Service |

领域 DTO、品牌命令别名、设备 SDK、路由映射和日志源都留在接入方工程。通用 package 不依赖这些类型，
也不从自由文本、Widget 状态或命令名推导业务结论。

## 核心能力

- `PatchbayServiceHost`：注册 identity、catalog、snapshot 和 invoke 四个稳定入口；
- `PatchbayCommandDescriptor`：声明命令参数、模式、门禁、副作用和允许的事实来源；
- `PatchbayGateEvaluator`：按固定顺序执行基础门和命令声明门；
- `PatchbayInvocation`：区分“受理 / 拒绝”和业务执行结果；
- `PatchbayJobRegistry`：记录长任务、单调事件序号、取消和类型化终态；
- `PatchbayArtifactService`：提供脱敏日志与有界 blob 下载；
- wire DTO 与 codegen：统一字段、枚举、校验和双向 JSON codec。

Flutter UI、Semantics、导航和 capture 不在本 package 内实现；它们由 `patchbay_flutter` 组合到同一个
host catalog。direct HTTP 由 `patchbay_transport` 承载，并复用相同的上层 handler。

## 架构

```text
CLI / automation
       │
       │ VM Service 或 direct HTTP
       ▼
PatchbayServiceHost
       │
       ├── identity / catalog / snapshot
       ├── PatchbayGateEvaluator
       ├── PatchbayInvocationSource
       └── PatchbayJobRegistry
                    │
                    ▼
             接入方 adapter
                    │
                    ▼
       既有 runtime / controller / ports
```

adapter 复用 App 现有 controller 和状态机。Patchbay 负责协议与边界，不为 CLI 复制一套业务实现。

## Service extension

`PatchbayServiceHost` 注册四个稳定 RPC：

| RPC | 含义 |
|---|---|
| `ext.patchbay.identity` | App、isolate、schema 与短期实例 ID |
| `ext.patchbay.catalog` | 当前实际注册的命令和动态 UI target |
| `ext.patchbay.snapshot` | 接入方提供的只读 runtime 快照 |
| `ext.patchbay.invoke` | 调用 catalog 中存在的命令 |

所有载荷带 `schemaVersion`。`appInstanceId` 在同一 isolate 内稳定，hot restart 后必须变化。客户端连接后
会重新校验 schema、isolate 和 App 实例，不能只凭 PID 或旧 URI 判断会话仍有效。

`schemaVersion` 由 host 拥有，接入方回调不能覆盖。catalog 中 command name 必须非空且全局唯一；
invocation 返回值必须是合法 wire envelope，并回显同一个 `requestId`。违反这些 provider 契约时 host
返回 `providerProtocolViolation`，不会把无法关联或无法解析的结果继续交给客户端。

Command catalog 行必须是带合法 dotted `name` 的对象，不接受字符串缩写。`requestId` 必须非空；
accepted 信封不能带 rejection，rejected 信封必须带 rejection 且不能带 payload / jobId。

## 受理信封与事实来源

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

`accepted` 不等于业务完成、设备执行或 UI 正确。协议不会增加容易被误读的外层 `ok`、`success` 或
`executed` 字段。业务结果进入 payload 或 job 终态。

观测值使用以下事实来源：

| 来源 | 含义 |
|---|---|
| `appRecorded` | App 本地记账或请求回执 |
| `commandEcho` | 命令回显，不是外部状态 |
| `deviceReported` | 设备主动上报或可验证读回 |
| `uiObserved` | Flutter target、metrics 或 render tree 的直接观测 |
| `unknown` | 当前证据不足 |

对象上的 `source` 可由后代继承，更深层字段可以覆盖。descriptor 的 `factSources` 是可能来源的闭集，
实际 payload 上的 `source` 才是该次结果的事实。传输层和 CLI 都不能把弱来源升级成强结论。

## 命令声明与门禁

`PatchbayCommandDescriptor` 是 CLI 帮助、参数校验和副作用提示的真源，至少描述：

- 稳定完整命令名和摘要；
- `readOnly`、`immediate` 或 `job` mode；
- 参数类型、必填、默认值和枚举；
- 接入方 gate ID；
- `none`、`appState` 或 `external` side effect；
- 敏感参数策略和可能出现的事实来源。

`sensitive: true` 的强制由 host 完成，不由接入方 handler 完成。客户端用 `inputWasStdin` 标记值来自
无回显 stdin；host 在 dispatch 之前按 catalog 声明校验，并把这个元键从 arguments 中剥掉，因此
`PatchbayInvocationSource` 收到的参数里永远没有它。任意 sensitive 参数带非空值却缺少该标记时，host
以 `sensitiveInputRequiresStdin` 拒绝，`details.parameters` 列出违规参数名。手写 adapter 既不需要在
参数白名单里豁免它，也**不得**再自行实现这条 stdin 检查——剥键之后那种检查恒为假。

唯一例外是 `plane: flutterUi` 的命令：那条平面由 `patchbay_flutter` 自己的 bridge 服务，敏感性是
目标级（`PatchbaySensitivePolicy.redacted`、obscured Semantics 节点）而不是参数级，descriptor 无法
表达，所以元键继续交给该 bridge。领域平面的接入方不受影响。

catalog 是这条策略的唯一真源。host 读不到 catalog 时 fail-closed：带参数的调用以
`providerProtocolViolation`（`reason: catalogUnavailable`）拒绝，不把未校验的参数交给 adapter；
无参调用不查 catalog——没有可剥的元键，也没有任何被传输的值可能是敏感的。descriptor 声明的默认值
不参与这条校验：标记描述的是**被传输的值**的来源，App 自带的默认值从未上过 wire。

每次调用依次通过不可省略的基础门，再通过 descriptor 声明的接入方门：

```dart
final gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (id) => evaluateConsumerGate(id),
);
```

基础门不会替 App 猜测登录、隐私同意、依赖就绪或设备状态。会触发网络、文件、权限或外部设备动作的
命令，必须显式声明相应门禁。service extension 没有对称注销能力，所以状态撤回后 handler 仍需逐次
fail-closed。

## 长任务

长操作不能伪装成立即命令。`PatchbayJobRegistry` 的基本契约是：

1. admission 返回 `jobId`；
2. job 先产生 `running` 事件，再进入单一终态；
3. 每个事件有单调 sequence、时间、phase、source 和 payload；
4. 取消只终止对应 job，不推导外部系统已经停止；
5. App / isolate 消失时由客户端以连接终止收尾，不伪造 App job 终态。

Registry 默认最多同时运行 32 个 job，并保留最近 200 个已结束 job；两项都可在构造时调整，但必须是
有限正整数。达到运行上限时 `start()` 在启动 body 之前抛出 `PatchbayJobCapacityExceeded`，接入方应
转换成稳定 admission rejection。取消回调默认最多等待 5 秒；超时后 job 保持 running，因为“取消请求
超时”不能证明底层操作已经停止。

未提供 cancellation callback 时，`cancel()` 返回 `false` 并保持 running。callback 正常返回代表接入方
确认底层操作已经停止；如果 controller 的 API 只表示“取消请求已发送”，adapter 必须继续等待真实取消
终态，不能立即返回 callback。

因此 registry 中可观察记录的理论上限是 `maxRunningJobs + retainedJobs`。`runningJobs`、
`settledJobs` 和 `totalJobs` 可用于接入方健康检查，但不是业务完成性的替代证据。

如果接入方的异步 API 只表示“请求已发出”，不能在该 Future 返回时直接标记 `completed`；必须继续观察
领域状态，直到 App 能给出真实终态。`suggestedWaitTimeoutMs` 只建议客户端观察窗口，不改变完成语义。

## 日志与 blob

`PatchbayLogSource` 是接入方注入的查询接口，不接管或复制 App 日志管线。接入方先完成 schema-aware
脱敏，再构造 `PatchbayRedactedLogRecord`。core 会额外拒绝常见敏感字段名和凭据形态，但这只是防御层，
不能替代 App 自己的隐私策略。

日志 query / tail 受条数、编码字节和时间上限约束。日志 export 与 Flutter capture 复用
`PatchbayMemoryBlobStore`；响应只返回 metadata 和 `blobId`，二进制通过 offset / limit 分块读取，并校验
TTL、容量和 SHA-256。

## Wire contract 与生成代码

descriptor、invocation、job、UI target 等稳定 DTO 从 JSON contract 生成。生成物负责字段名、枚举、
嵌套结构、未知字段拒绝和 JSON 类型校验；接入方仍需手写“领域对象 → wire DTO”的语义投影。

仓库内生成和漂移检查：

```console
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --write
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --check
```

contract 格式与依赖方用法见 [wire-contract-v1.md](contracts/wire-contract-v1.md)。

## Release 边界

接入方必须用编译期常量让 host、adapter 和注册调用在 release 不可达，不能只靠运行时 flag 隐藏入口。
`patchbay` 不提供 release 后门或远程重开机制。

core 无法替任意 App 证明最终 AOT 产物中不存在调试符号。接入方需要在自己的构建链中扫描和验收 release
产物；Flutter Key 的跨 build mode 语义由 `patchbay_flutter` 负责。

## 接入方职责

- 复用既有 runtime / controller，不为 CLI 另建状态机；
- snapshot 只读现有状态，不隐式启动订阅或外部动作；
- 并发 permit、lease、generation 和取消所有权仍归 App；
- 敏感值在进入 Patchbay 前完成脱敏；
- UI 观测、App 状态和外部设备结果分别标明来源；
- 用真机结果验证平台行为和有副作用的领域命令。

## 非目标

- 不提供坐标驱动或跨 App 黑盒自动化；
- 不替代 Widget test、集成测试、DevTools 或人工验收；
- 不处理系统权限弹窗、安装卸载、shell 和其他 App；
- 不把 CLI 输出升级为完整产品验收证据；
- 不支持 release，也不建立隐式降级通道。

## 验证

```console
$ dart pub get
$ dart analyze --fatal-infos
$ dart test
```
