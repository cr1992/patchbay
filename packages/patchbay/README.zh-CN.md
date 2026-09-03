# patchbay

[English](https://github.com/cr1992/patchbay/blob/main/packages/patchbay/README.md) | 简体中文

`patchbay` 是 Patchbay 的纯 Dart 协议与 host package。它让本机客户端连接正在运行的 Dart / Flutter
App，读取 runtime identity、catalog 和 snapshot，并调用 App 明确注册的调试命令。

本 package 不认识页面、设备 SDK、路由或业务领域。使用 Patchbay 的 App（下文称“接入方”）需要在
自己的 adapter 中完成领域类型转换、门禁判断、并发所有权、脱敏和事实裁决。

完整上手流程见[仓库 README](https://github.com/cr1992/patchbay/blob/main/README.zh-CN.md#快速开始)。Flutter UI 接入见
[`patchbay_flutter`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/README.zh-CN.md)，CLI 用法见
[`patchbay_cli`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_cli/README.zh-CN.md)。

## Package 边界

| Package | 职责 | 依赖边界 |
|---|---|---|
| `patchbay` | 协议、service extension host、门禁、命令声明、调用信封、job、日志与 blob | 纯 Dart |
| `patchbay_flutter` | 可选 Flutter UI、Semantics、导航、等待与截图 bridge | Flutter + `patchbay` |
| `patchbay_cli` | VM Service / direct client、会话发现、命令行和稳定输出 | 纯 Dart |
| `patchbay_transport` | 显式启用的 direct HTTP/JSON host/client | 纯 Dart，不依赖 VM Service |

领域 DTO、品牌命令别名、设备 SDK、路由映射和日志源都留在接入方工程。通用 package 不依赖这些类型，
也不从自由文本、Widget 状态或命令名推导业务结论。

## 公共入口

0.6.0 起本 package 按角色发布三个入口，每个都是逐名列出的封闭 `show` 清单——没有兜底默认面，
也没有 `legacy.dart`：

| import | 角色 | 内容 |
|---|---|---|
| `package:patchbay/patchbay.dart` | 默认 consumer | 命令注册与 descriptor、参数与响应 schema、gate、catalog 与 snapshot provider、job ledger、artifact/blob/log service、navigation 与 UI 声明 |
| `package:patchbay/patchbay_host.dart` | host implementer | 默认清单的严格超集，再加 `PatchbayServiceHost`、audit sink/event、invocation 与 cancellation lifecycle、admission/rejection 与响应校验 |
| `package:patchbay/patchbay_protocol.dart` | protocol / wire implementer | 生成的 `*Wire` 类型、catalog capability 与 digest、CLI syntax 词汇、permission companion 协议、client 请求类型与 canonical protocol descriptor |

`patchbay_host.dart` **不** re-export protocol：实现 host 与直接读写 raw wire 是两个角色，同一文件
两者都做就写两个显式 import。除「host ⊃ consumer」外三份清单互不相交，因此同时 import host 与
protocol 不会冲突。

### 0.5.x → 0.6.0 source 迁移

默认入口收窄是有意的 source breaking：旧 import 会编译失败，报错里点名的符号唯一对应一行替换。

| 0.5.x 使用方式 | 0.6.0 import |
|---|---|
| 业务 descriptor、schema、gate、provider、job/artifact/log adapter | `package:patchbay/patchbay.dart`，多数代码不改 |
| `PatchbayServiceHost`、audit、invocation/cancellation 或 validation lifecycle | `package:patchbay/patchbay_host.dart` |
| 生成 wire、capability/digest、permission companion、client request、canonical descriptor | `package:patchbay/patchbay_protocol.dart` |

wire、错误码、稳定 JSON、资源上限与运行时行为都没有变化，本项只改 Dart 源码可见性。

## 核心能力

- `PatchbayServiceHost`：注册 identity、catalog、snapshot、invoke 与 invocation cancel；
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

`PatchbayServiceHost` 注册五个稳定 RPC：

| RPC | 含义 |
|---|---|
| `ext.patchbay.identity` | App、isolate、schema 与短期实例 ID |
| `ext.patchbay.catalog` | 当前实际注册的命令和动态 UI target |
| `ext.patchbay.snapshot` | 接入方提供的只读 runtime 快照 |
| `ext.patchbay.invoke` | 调用 catalog 中存在的命令 |
| `ext.patchbay.cancelInvocation` | 用准确 owner token 取消一条 invocation |

所有载荷带 `schemaVersion`。`appInstanceId` 在同一 isolate 内稳定，hot restart 后必须变化。客户端连接后
会重新校验 schema、isolate 和 App 实例，不能只凭 PID 或旧 URI 判断会话仍有效。

`schemaVersion` 由 host 拥有，接入方回调不能覆盖。catalog 中 command name 必须非空且全局唯一；
invocation 返回值必须是合法 wire envelope，并回显同一个 `requestId`。违反这些 provider 契约时 host
返回 `providerProtocolViolation`，不会把无法关联或无法解析的结果继续交给客户端。

Command catalog 行必须是带合法 dotted `name` 的对象，不接受字符串缩写。命令名语法是
`^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$`：每段以小写字母开头，段内只有字母和数字，**不允许
连字符**（`auth.switch-tenant` 非法，写成 `auth.tenant.switch`）。`requestId` 必须非空；
accepted 信封不能带 rejection，rejected 信封必须带 rejection 且不能带 payload / jobId。

catalog 违反上述约定时，**整个 catalog 调用**返回拒绝信封，而不是抛异常——异常在 VM Service 和
direct HTTP 上都变不成回复，调用方只会看到挂起：

```json
{
  "schemaVersion": 1,
  "admission": "rejected",
  "rejection": {
    "code": "providerProtocolViolation",
    "details": {
      "reason": "invalidCatalogCommands",
      "commandNamePattern": "^[a-z][A-Za-z0-9]*(?:\\.[a-z][A-Za-z0-9]*)+$",
      "violations": [
        {"index": 1, "name": "auth.switch-tenant", "reason": "invalidCommandName"}
      ]
    }
  }
}
```

`details.reason` 另有 `commandsNotAnArray` 和 `catalogSourceFailed`（接入方回调自己抛异常，
`details.error` 只给异常类型名，不回显消息）；逐条 `reason` 另有 `duplicateCommandName` 和
`missingCommandName`（没有可回显的名字时只给 `index`）。命令名是协议词汇不是接入方数据，所以直接
指名。非法名、重名、缺名一次全报，不是报完第一条就停。违规目录**不带 `commands`**：跳过坏条目只
服务其余的，等于把接入方 bug 藏成「App 少了个能力」。

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

接入方拥有的 external 命令可通过
`retryPolicy: PatchbayRetryPolicy(maxAttempts: 2..3, backoffMs: 0..5000)` 显式选择幂等 transport
重试。host 在 external adapter 前按 `(command, requestId)` 与内部 canonical 参数摘要去重：同参数共享
进行中的工作并重放已完成结果；不同参数拒绝为 `requestIdConflict`；未声明策略的命令遇到重复 ID 则拒绝
为 `duplicateRequestId`。registry 命令不经过这条 external 去重边界，因此不能声明该策略。

`PatchbayServiceHost` 可注入 `auditSink` 与 `onAuditSinkError`。host 先在 `auditEvents` 中保留最近 256 条
脱敏 `PatchbayAuditEvent`，再由一个 FIFO 消费者顺序投递 sink。投递队列把 active Future 与 waiting 事件
一起计入 `auditQueueCapacity`（默认 256，范围 1–4096）；overflow 与关闸后的事件分别通过
`PatchbayAuditDeliveryOverflow`、`PatchbayAuditDeliveryClosed` 交给 `onAuditSinkError`，均不改变调用结果。
终止时可显式调用 `drainAudit()` 取得统计，或调用 `dispose()` 完成同一有界 drain。参数形状只暴露递归
JSON 类型、对象键和粗粒度长度档位；标量值和内部参数摘要绝不离开 host。

registry 与 external invocation 共用 `maxConcurrentInvocations`（默认 8，范围 1～256）。既有 `invoke`
handler 保持可用；取消会返回类型化拒绝，但容量仍等到 handler settle 才释放。能够证明底层工作已停止的
consumer 可改用 `invokeWithContext`，在 `PatchbayInvocationContext` 上注册一次 cancellation confirmation；
callback 成功后即可释放容量。deadline、断连、显式 cancel 与 host dispose 保持为不同 reason。`dispose()`
先 drain invocation、再 drain audit；这些规则不改变 `PatchbayJobRegistry` 的 job cancel 语义。

`sensitive: true` 的强制由 host 完成，不由接入方 handler 完成。客户端用 `inputWasStdin` 标记值来自
无回显 stdin；host 在 dispatch 之前按 catalog 声明校验，并把这个元键从 arguments 中剥掉，因此
`PatchbayInvocationSource` 收到的参数里永远没有它。任意 sensitive 参数带非空值却缺少该标记时，host
以 `sensitiveInputRequiresStdin` 拒绝，`details.parameters` 列出违规参数名。手写 adapter 既不需要在
参数白名单里豁免它，也**不得**再自行实现这条 stdin 检查——剥键之后那种检查恒为假。

唯一例外是 `plane: flutterUi` 的命令：那条平面由 `patchbay_flutter` 自己的 bridge 服务，敏感性是
目标级（`PatchbaySensitivePolicy.redacted`、obscured Semantics 节点）而不是参数级，descriptor 无法
表达，所以元键继续交给该 bridge。领域平面的接入方不受影响。

catalog 是这条策略的唯一真源。host 读不到**可用**的 catalog 时 fail-closed（读不出来和读出来不合法
一样算）：带参数的调用以 `providerProtocolViolation`（`reason: catalogUnavailable`）拒绝，
`details.catalog` 原样带上目录本身的违规原因，不把未校验的参数交给 adapter；
无参调用不查 catalog——没有可剥的元键，也没有任何被传输的值可能是敏感的。descriptor 声明的默认值
不参与这条校验：标记描述的是**被传输的值**的来源，App 自带的默认值从未上过 wire。

每次调用依次通过不可省略的基础门，再通过 descriptor 声明的接入方门：

```dart
final gates = PatchbayGateEvaluator(
  // 没有任何参数会传进这个门，所以它保持放行——只读命令因此不需要任何
  // 额外接线。
  baseGate: () => const PatchbayGateDecision.allow(),
  // 每声明一个 gate ID 就会跑一次。出厂安全默认是：没有被显式放行的一律
  // 拒绝：
  consumerGate: (id) => PatchbayGateDecision.reject(
    code: 'unknownConsumerGate',
    notice: '没有叫 "$id" 的 consumer gate——这是出厂安全默认：写操作在'
        '这里被显式放行之前一律保持关闭。',
  ),
  // 需要为可信的驱动放行某个写门时，把上面的函数体换成类似这样：
  //   consumerGate: (id) => id == 'app.write'
  //       ? const PatchbayGateDecision.allow()
  //       : PatchbayGateDecision.reject(
  //           code: 'unknownConsumerGate',
  //           notice: '没有叫 "$id" 的 consumer gate。',
  //         ),
);
```

最短接入默认先开放只读诊断，写操作必须显式声明并通过门。基础门不会替 App 猜测登录、隐私同意、
依赖就绪或设备状态。会触发网络、文件、权限或外部设备动作的命令，必须显式声明相应门禁。
service extension 没有对称注销能力，所以状态撤回后 handler 仍需逐次 fail-closed。

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

`cancelAll()` 并行发起所有运行中 job 的取消：全部 callback 先被调用，再各自按 `cancellationTimeout`
收敛，一个卡死或抛错的 callback 只消耗一次超时，不阻塞也不中断其余 job。返回值是逐 job 的
`PatchbayJobCancelOutcome`（`cancelled` / `notCancellable` / `timedOut` / `callbackFailed` /
`alreadySettled`），只覆盖发起时仍在运行的 job；超时、抛错和无 callback 的 job 保持 running，
已自行进入终态的 job 保留自己的终态，不会被写成 cancelled。

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

wire 生成器把 Dart 文件与 `test/golden/wire_surface.json` 视为同一组生成物：`--write` 在一次
运行中同步刷新两者，任一文件缺失或漂移都会让 `--check` 失败。不要再通过测试专用环境变量更新
wire surface。

contract 格式与依赖方用法见 [wire-contract-v1.md](https://github.com/cr1992/patchbay/blob/main/packages/patchbay/contracts/wire-contract-v1.md)。

## Command contract 与生成代码

`command_codegen` 是给**接入方**用的：把自己的命令表写成 contract（`contractVersion: 2`），
生成 typed 命令 id、参数读取器、descriptor 与 dispatch 面。它不生成本仓自己的任何代码。

仓内带一份可跑的样例 contract 及其生成物，CI 的 `codegen_drift` 对它跑 `--check`——生成器改动
一旦让输出漂移，在本仓就判红，而不是等接入方升级 pin 之后才发现：

```console
$ dart run packages/patchbay/bin/command_codegen.dart \
    --contract packages/patchbay/contracts/example_commands.json \
    --output packages/patchbay/contracts/example_commands.g.dart --check
```

与 `wire_codegen` 不同，这条**从哪个目录调用都一样**：生成物 header 记录的是相对生成物自身的
路径，不是相对调用目录的路径。

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
