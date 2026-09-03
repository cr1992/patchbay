# 设计

> 本文回答"为什么长这样"。怎么用见 [使用指南](guide.md)。

## 架构

```mermaid
flowchart LR
    subgraph 终端
        CLI["patchbay CLI<br/>(patchbay_cli)"]
    end
    subgraph 传输
        VM["Dart VM Service<br/>(debug / profile 自带)"]
        DT["Direct HTTP<br/>(可选，显式启动)"]
    end
    subgraph App["运行中的 Flutter App"]
        HOST["service host<br/>(patchbay)"]
        GATE["双层门<br/>基础门 + descriptor 声明门"]
        UI["UI 桥<br/>(patchbay_flutter)"]
        ADPT["consumer adapter<br/>(App 自己写)"]
    end
    CLI --> VM --> HOST
    CLI -.-> DT -.-> HOST
    HOST --> GATE
    GATE --> UI
    GATE --> ADPT
```

依赖方向是治理边界：`patchbay` 与 `patchbay_cli` 是纯 Dart，`patchbay_flutter` 只依赖
Flutter 与 `patchbay`。接入方（consumer）的设备 SDK、路由字符串和领域词汇不进入这四个 package；
需要这些类型时，先在接入方 adapter 中转成中立 DTO。

这条边界连"只差一行平台代码"的能力也不放行，keep-awake 就是判例：亮屏要碰
`FLAG_KEEP_SCREEN_ON` / `isIdleTimerDisabled`，而给 `patchbay_flutter` 加个插件或第三方 wakelock
依赖，等于为了一个调试开关改变**每个**接入方构建时链接的东西。所以拆开来——框架拥有协议、记账
和租约，App 通过注入一个 delegate 拥有那一行碰平台的代码，没注入就明说没接线。需要平台能力的新
特性照这个形状走：Patchbay 定义契约与生命周期，接入方提供实现。

## 一条请求的生命周期

上面那张图说的是"谁依赖谁"。这一节说的是"一条命令实际走过哪些关口"——新接入方排查
"我的命令为什么被拒"时，先在这张图上定位是哪一层说的话，再去读对应的稳定 code。

```mermaid
sequenceDiagram
    participant CLI as patchbay CLI
    participant T as 传输<br/>VM Service / direct HTTP
    participant H as service host<br/>(patchbay)
    participant B as UI 桥 / 领域 adapter
    participant C as consumer controller

    CLI->>CLI: 解析 argv；CLI 路径译成协议命令名
    CLI->>CLI: 选会话（只读本地目录，不连 App）
    CLI->>T: 拨号 + identity 握手（同样计入 RPC 预算）
    CLI->>H: catalog（每条服务命令调用前必读一次）
    CLI->>CLI: sensitive 参数写在命令行 → 用法错误，请求根本不发出
    CLI->>H: invoke 命令、参数、requestId
    H->>H: 参数白名单 → 重读 catalog → sensitive 校验 → 处理 inputWasStdin 元键
    H->>B: 路由：ui.* / navigation.* / artifact → 桥；其余 → domainInvoke
    B->>B: 解析目标 → 基础门 + 声明门（可能 await）→ 门后二次解析
    B->>C: 复用既有 controller
    C-->>B: 类型化结果
    B-->>H: PatchbayInvocation 信封
    H->>H: 复核信封：schemaVersion / requestId / admission 语义
    H-->>CLI: admission 为 accepted 或 rejected
    CLI->>CLI: 目录漂移复核 → 分类退出码
```

### requestId 贯穿全程，三处独立校验

`requestId` 由客户端生成（VM Service 路径是 `patchbay-cli-vm-<n>`），随 invoke 发出，
沿途三处各自校验一次，任何一处对不上都不是"猜"，而是稳定拒绝：

1. **host 收到时**——参数里没带就自己补一个 nonce；带了但为空串，以 invalidParams 拒绝；
2. **host 拿到 adapter 回程信封时**——信封里的 `requestId` 与本次请求不一致，整条应答被替换成
   `providerProtocolViolation`（`details.reason: requestIdMismatch`），adapter 的原始 payload 不外发；
3. **CLI 收到应答时**——顶层 `requestId` 与自己发出的不同，抛 `requestIdMismatch`。

桥被 `PatchbayFlutterServiceHost` 调用时沿用传入的 `requestId`；只有在被直接调用且调用方没给 ID
时才生成本地 ID。所以日志、CLI 输出和信封能稳定关联到同一次请求。

### 谁能拒绝，用什么码

| 关口 | 典型稳定 code | 退出码 |
|---|---|---|
| CLI 用法（`--args` 塞 sensitive、参数形状不对） | `usageError` | 64 |
| 会话选择 / 拨号 / 对端不应答 | `sessionAmbiguous`、`appUnresponsive`、`transportError` | 3 |
| 协议不兼容、目录里没有该命令、目录漂移 | `schemaVersionMismatch`、`commandNotRegistered`、`catalogInvocationDrift` | 4 |
| host 前置校验（目录不可用、敏感值未走 stdin） | `providerProtocolViolation`、`sensitiveInputRequiresStdin` | 5 |
| 桥 / adapter 受理前拒绝（门、目标歧义、代际过期、生命周期） | `uiTargetAmbiguous`、`uiGenerationStale`、`*LifecycleNotResumed` | 5 |
| 已受理但业务返回类型化失败 | payload 里的 `outcome: failed` / job 终态 `failed` | 6 |

这张表跨了两种信封，别当成一种：

- **App 说的话**——`commandNotRegistered` 及第四、五行，是 `admission: rejected` 的响应信封，
  带 `rejection.code` 与自由 `details`；最后一行则是 `admission: accepted`，失败事实在 payload 里。
  受理与执行刻意不混，理由见[受理 ≠ 执行](#1-受理--执行)。
- **CLI 说的话**——用法、会话、传输，以及 CLI 侧的协议复核（`schemaVersionMismatch`、
  `catalogInvocationDrift`），App 根本没表态或表态没通过复核，走 CLI 自己的错误信封
  `{"error": {"code": …, "details": …}}`。

两种信封字段同构（稳定 `code` + 自由 `details`），所以一个解析器读两种；但"谁拒绝的"要看
它出现在哪一种里。

目录违规是**整份**失效而不是跳过坏行：host 发现命令名非法或重名时，应答里干脆没有 `commands`
键，并在 `details.violations` 里一次列全所有违规项。跳过坏行会让接入方以为自己只是少注册了几条
命令，而不是目录本身坏了。

目录 policy 缓存也不能绕过这条边界。registry 命中只负责 O(1) 取得 descriptor policy，命令真正受理前
仍须持有整份 commands 已验证的 `CatalogValidity`；validity 与按 name 投影的 policy index 来自同一次
完整验证。legacy 动态 source 没有失效事实，只允许并发调用共享一个 in-flight read，settle 后下一次调用
仍重新读取；不得用 TTL 或“最近没变化”推断安全复用。空参数也不构成旁路，registry/external invocation
都先取得 validity，再做路由或参数 policy。

需要跨 invocation 复用时，接入方显式提供 additive catalog provider：廉价 `commandsRevision` getter 只
报告失效信号，完整 sample 原子绑定 revision 与 catalog。相同 revision 承诺规范化 commands 不变，倒退或
在既有完整读取中观察到同 revision 内容漂移均按 provider 违规拒绝。commands revision 不覆盖动态
`uiTargets`；显式 catalog 仍读取当时的 UI target，invocation cache 不保留挂载态。VM Service 与 direct
共用同一 validity/index，不在 transport 层各建一份缓存。

完整状态机、失败分类与兼容矩阵见已接受的
[Invocation catalog policy 缓存与失效协议](proposals/0.5.0/catalog-policy-cache.md)。

### Provider JSON 先冻结，再进入协议

consumer provider 返回的 snapshot 等结构必须是严格 JSON：`null`、bool、有限 number、String、
string-key map 和这些值组成的 list。host 在同一个 provider 边界内完成显式有界验证、冻结和 canonical
编码；非字符串 key、非有限数、未知对象、循环、过深或过大的结构统一以既有
`providerProtocolViolation` 拒绝，不让异常、原值或 consumer 的 `toString()` 越过边界。

snapshot 的响应、selector、revision 与 diff 共用同一份冻结读视图。冻结保持 consumer map/list 的迭代
顺序，排序 canonical 只负责相等比较和字节计量，因此 consumer 返回后的 mutation 不会改写已观察事实，
也不会用排序副本改变既有响应字段顺序。验证不依赖递归调用栈：容器深度、展开 occurrence 与 canonical
UTF-8 分别受 128、2,097,152 和 4 MiB 的固定安全天花板约束；共享无环子树按每次出现重新计费，只以
活动路径判循环。VM Service 与 direct 复用同一个 host handler，失败形态不得在 transport 层分叉。

完整失败分类、预算优先级与兼容矩阵见已接受的
[Snapshot provider JSON 边界与冻结读视图](proposals/0.5.0/snapshot-provider-boundary.md)。

### snapshot retention 同时受份数与字节约束

只数 revision 份数能限制「能回溯多远」，不能限制「占多少内存」：一份大 snapshot 可以在 App instance
存活期内一直钉住几十 MB。因此 retention 由三个 host 内预算共同决定——保留份数、单份 canonical UTF-8
字节、累计 retained canonical UTF-8 字节，默认 32 份 / 1 MiB / 8 MiB（DG-050-01）。

单份预算是**运行预算**，与 PB-050-01 的 4 MiB 契约天花板是两件事：运行预算由接入方在
64 KiB..4 MiB 内配置，越界返回稳定 code `snapshotPayloadTooLarge`，details 只有
`encodedBytesAtLeast` 与 `maxSnapshotBytes`；天花板不可配置，越界仍是 `providerProtocolViolation`
的 `snapshotPayloadInvalid/payloadTooLarge`。两类失败都在提交前发生，既不改写 latest，也不改动
retention。字节计量走同一次有界遍历的增量 sink，超限即中止，不先生成完整 canonical 再量长度；
occurrence backstop 按常量关系 `maxExpandedOccurrences >= maxCanonicalBytes ~/ 2` 固定在字节预算
之后，1..4 MiB 的合法 payload 只由字节预算分类。

累计预算淘汰最老 revision，最新一份永不被自己的提交淘汰。因任一预算淘汰掉 baseline 后，diff 继续
返回既有 `snapshotRevisionUnavailable`，details 增加 `retainedByteLimit` 说明原因。返回 metadata 在
既有松读面追加 `retainedByteLimit` 与 `snapshotBytes`，不向严格解码的 request/wire 加字段。

### 并发读共享一次采样，不共享预算

同一时刻的并发 snapshot 读共享一次 provider sampling，以及随之而来的冻结、canonical 编码和 revision
提交；selection、diff、wait deadline 与响应组装仍逐调用者独立，慢调用者不能延长别人的 timeout。
single-flight 只覆盖进行中的采样：owner Future settle 即清除，失败对本批共享、下一次调用可重试，
owner 放弃等待也不会把这一批挂死。

开启采样和加入采样不是同一种等待。开启者拥有那次 provider 调用，保持既有语义——读完再由预算裁决这份
答复是否还算数，因此慢 source 仍能报出它看见的东西；**加入者等的是别人的 provider 调用，所以它的等待
以自己的剩余预算为上限**，预算耗尽即按既有 `snapshotWaitTimeout` 答复。**调用者超时不摘除进行中的
采样**：`_sampling` 只在 settle（成功或失败）时清除——摘除再重开会对挂死的 source 制造随流量线性增长
的悬空 provider 调用，还会让被摘除的旧采样与新采样乱序 settle，把 host 自己造成的乱序当成 App 的
revision 回退。于是一次永不返回的 provider 调用在 host 侧恒只有一条：后到的带预算调用者全部按自身
预算拿到类型化答复；开启它的那一位与不带 host 预算的纯读一样，由传输层 deadline 兜底——这与既有
纯读语义同形。若该采样最终 settle，结果照常判定并提交一次；`snapshotWaitTimeout` 的 `details` 在一次
轮询都没完成时不给出 `observed`（`polls` 为 `0`），因为「App 没答复」不是「字段不存在」。

### 可选的 consumer 上报 revision

`PatchbaySnapshotSource` 保持不变并继续返回 `revisionSource: hostObserved`；新增互斥的
`PatchbayVersionedSnapshotSource`，返回 `PatchbaySnapshotSample(contentRevision, body)`，有效采样返回
`revisionSource: consumerReported`。source 形态在 host 构造期确定，同一 appInstance 不允许运行中切换。
`contentRevision` 是**内容事实**：同值表示 body JSON 内容不变，此时 host 不读取也不保留新 body 引用，
直接复用上次冻结视图；revision 前进即使 canonical 相同也递增 host `snapshotRevision`，忠实于 provider
的提交节奏。负数或倒退返回 `providerProtocolViolation` 的 `revisionRegressed`。host 从不把 consumer
数值当作 `snapshotRevision`，仍维护自己的连续序号。逐响应的 `revisionSource` 就是信任边界，不另加
capability。

完整预算表、失败分类与兼容矩阵见已接受的
[Snapshot 双预算、single-flight 与可选 source revision](proposals/0.5.0/snapshot-resources-revisions.md)。

### job 的异步分支

长流程命令受理即返回 `admission: accepted` + 顶层 `jobId`，controller 在 App 侧继续跑。
CLI 侧 `--wait` 有两条路，取决于 catalog 里有没有 `patchbay.job.wait`：

- **有**——服务端长轮询循环：每轮带 `afterSequence`（已见过的最大事件序号）与 `timeoutMs`
  （剩余预算，单轮夹到 30 秒），收到终态快照即返回，结果标 `waitMode: serverLongPoll`；
- **没有**——退化为按固定间隔轮询 `patchbay.job.get`，结果标 `waitMode: legacyPolling`
  并附一句说明。这是对老 host 的兼容路径，不是推荐形态。

两条路都在总预算耗尽时以 `waitTimeout`（退出码 6）收尾，`details.jobId` 指明是哪个 job。
终态结果里**顶层 `jobId` 是稳定取值位置**——`payload.jobId` 是 App 自己的快照字段，两处都保留，
脚本读顶层那个。job 事件语义与取消的终态规则见[慢事实用 job 表达](#6-慢事实用-job-表达)。

> **`patchbay.job.get|wait|cancel` 是接入方 adapter 的命令，不由这四个 package 注册。**
> 本仓提供 `PatchbayJobRegistry`（账本、预算、取消 callback 语义），把它接成协议命令是接入方的事。
> 没接就没有 job 面，CLI 的 `--wait` 也就无从谈起。

## 为什么需要 App 合作接入

Patchbay 不是 adb 那种对任意 App 生效的外部工具：它要求 App 在组合根花约 30 行接入。
这个代价换来三样外部工具原理上给不了的东西：

1. **类型化**——状态和失败是结构化 DTO，不是从日志反推；
2. **有门禁**——每条命令过声明式的门，权限、启动阶段、业务约束由 App 自己裁决；
3. **有编译期边界**——release 不构造这套调试面，而不是用运行时开关把它“藏起来”；最终产物由
   接入方构建链继续验证。

## 六条设计立场

核心协议约束由仓库测试覆盖；依赖 App 构建链或真机行为的部分，需要接入方在自己的流水线中继续验收。
违反这些立场的改动应先修改设计，而不是静默放宽实现。

### 1. 受理 ≠ 执行

信封只表达桥接受没接受请求（`admission: accepted | rejected`），从不提供
`ok` / `success` / `executed` 这类会被误读成"设备做完了"的外层字段。业务结果进
payload，带自己的证据等级。CLI 退出码同构：`0` 只代表"App 受理且返回非失败结果"，
业务失败是 `6`，两者不混。

**为什么**：调试工具最大的危害不是失败，而是让人误信成功。一条"命令已发送"被读成
"设备已执行"，联调就会在错误的前提上浪费一天。

同一条立场在 payload 内部还要再分一层。"发送"与"设备做完"之间不止两种状态，压成两种就会
把"根本没发出去"和"发出去了但没等到回报"变成同一种失败——而这两件事的下一步动作完全不同。
所以需要表达执行结果的命令在 payload 里用封闭词表说清楚是哪一种：`notSent`、`sentUnconfirmed`、
`unchanged`、`deviceConfirmed`，每种都带自己的事实来源。**退出码仍然只由 job 终态决定**，不看
分类猜成功；分类回答的是"设备那边到底发生了什么"，不是"这条命令算不算成功"。

### 2. 事实来源是封闭词表

每个状态值标明出处：`appRecorded`（App 记账）、`commandEcho`（命令回显）、
`deviceReported`（设备上报）、`uiObserved`（UI 直接观测）、`unknown`。弱来源不允许
被传输层或 CLI 升级——命令回显永远不冒充设备状态。descriptor 声明每条命令可能出现
的来源集合（`factSources`），客户端可以拒绝词表外的值而不是猜。

### 3. 门是声明的，不是散落的

不可省略的基础门之外，每条命令的 descriptor 声明它需要的 consumer 门（启动阶段、
依赖就绪、业务约束）。目录是跨进程真源：CLI 帮助和副作用提示从 descriptor 读取；host 强制 command
name 唯一、invocation wire 合法且 `requestId` 一致。领域 adapter 必须使用生成 decoder 或等价 validator
执行参数、敏感输入和声明门校验，不能把 descriptor 只当展示数据。

core host 与 Flutter UI registry 不合成一个对象，但复用同一 invocation-scoped admission pipeline：catalog、
sensitive input、base gate 与 descriptor gate 由 core 执行；target/generation/lifecycle/occlusion 与动态
operation policy 由 Flutter 追加，再回到 core 做 response validation 与 audit。静态 descriptor gate 对
registry/external 一视同仁，动态 policy 保持注入对象、不伪装成 catalog 静态事实；await 后漂移拒绝而不在
同一次调用重跑新声明。完整阶段与兼容边界见已接受的
[Gate 声明与执行真源](proposals/0.6.0/gate-execution-boundary.md)。

admission stage 只属于 host audit，不进入 invocation envelope；调用方仍按稳定 code、`gateId` 和 details
恢复。reveal audit 也只由 core 从 schema 已校验的 accepted payload 投影有界 steps/container nodeId，
Flutter bridge 不直接写 audit，不把 identifier、坐标、文案或 policy 文本带进审计。

descriptor 也拥有机器输出的渐进披露声明：可选 `outputProjection` 作为松读 catalog sibling 进入 wire，
full 恒等，artifact 先于 brief，canonical CLI façade 复用最终 service command 的声明。brief 沿用 0.5.0
冻结的删除清单而不是改成保留清单；未知字段默认透传，schema 校验与脱敏必须在投影前完成，不能把 brief
当安全边界。每条命令至多一个 `renderedMember`、`payloadBlob` 或 `responseBlob` artifact，人读 summary、
本机路径、命名和覆盖策略仍由 CLI 拥有。老 host 缺声明时只使用冻结的 0.5.0 fallback，新命令不得继续扩
手工规则。完整 wire、顺序与降级见已接受的
[Descriptor 驱动的输出投影](proposals/0.6.0/descriptor-output-projection.md)。

公共 Dart 面按使用者而不是实现文件分层，且每个入口必须**自足**：导出符号的公共签名里引用到的
Patchbay 类型必须由同一入口导出，否则接入方按迁移表改完只会拿到 `undefined_class`。角色分组是种子，
实际导出清单是它的闭包，由 `tool/check_api_closure.dart` 用 analyzer 的 element model 机检。
`patchbay.dart` 是 98 符号的默认 consumer façade；`patchbay_host.dart` 在它之上追加 38 个 host
lifecycle 符号（共 136）；`patchbay_protocol.dart` 是 141 个 raw wire 与 protocol 符号，与前两者有意
重叠。Flutter 默认入口只在 core consumer 上追加 `PatchbayKey`、`PatchbayRoot`、
`PatchbayRootController`、`PatchbayUiRegistry`（共 102），service host、bridge 与 policy 进入显式
`patchbay_flutter_host.dart`（195）。公共 barrel 必须用封闭 `show`，API checker 按 library 展开跨包
re-export，并为每个包记一份 `internal` 清单，使 `lib/src/**` 新增的公共符号必须表态。精确基线集合、
闭包规则与 source 迁移见已接受的
[Core 公共 Dart API 分层](proposals/0.6.0/core-public-api-layers.md)。

### 4. release 必须可裁除

组合根用编译期常量确保 release 不注册扩展、不构造 adapter、不保留运行时重开入口。
`PatchbayKey` 在所有构建模式保持同一种 GlobalKey 语义，release 只裁掉调试声明和登记逻辑，
避免因为 Key 类型变化造成 Widget state 漂移。

通用 package 无法替任意 App 证明最终 AOT 产物。接入方必须在自己的构建链中扫描 release 产物，
确认 host、descriptor、operator 和业务 callback 均不可达。

### 5. UI 操作低侵入、防误击

只读诊断可以观察 Widget / Render / Semantics 树，但写操作不把文案、坐标、树路径或节点顺序当作
稳定身份：只操作带代际信息的 `PatchbayKey` target 或明确选中的 Semantics 节点。每个目标带
代际（generation）：

```mermaid
sequenceDiagram
    participant CLI
    participant Bridge as UI 桥
    participant W as Widget
    CLI->>Bridge: ui text set login.phone gen=1
    Bridge->>Bridge: 解析目标 → 过门（可能 await）
    Note over W: 期间控件重挂载，代际变为 2
    Bridge->>Bridge: 门后二次解析
    Bridge-->>CLI: rejected: uiGenerationStale (current=2)
    Note over CLI: 迟到的操作被围栏拒绝，而不是打在同名新实例上
```

同 ID 多个 mounted 目标一律 fail-closed（歧义拒绝），不按树顺序选。

UI 写命令在 catalog 以封闭的 `interactionModel` 明示语义：注册 text target 是 `directTarget`，成功只证明
consumer 开放的 controller/adapter 操作已应用，不冒充真实用户可达；Semantics、pointer gesture 与 reveal
是 `userLike`，继续执行 generation、遮挡、policy 与门后二次解析。两类之间不自动回退，也不存在 force 或
ignore-occlusion 入口。完整兼容与拒绝形状见已接受的
[UI 可达性与遮挡语义](proposals/0.6.0/ui-reachability-semantics.md)。

`ui.reveal` 的调用参数硬顶与容器 policy 是两层预算：`maxSteps` / `timeoutMs` 的 host 参数域在解析容器前
总是校验；`PatchbayRevealPolicy` 只回答“能否驱动这个容器、这个容器预算多少”，没有容器就不求值。
已曝光且无需滚动可以 `steps: 0` 成功。目标不存在、被遮挡和无可驱动容器分别给出稳定恢复方向；完全剪裁
但可滚动属于 reveal 的正常输入，不归类为遮挡。

CLI 的推荐 UI 写入口是 `ui perform <action> <selector>`；selector 以前缀明示既有 `target:`、`semantics:`
或 `node:` 身份，不扫描、不猜测。只有 tap 同时有 Semantics 与真实 pointer 两条合法通道，因此
`--via semantics|pointer` 必填；其余 action 的通道唯一，拒绝 `auto`、`best` 与失败后 fallback。CLI 在
`localRoute` 报告实际 service command，但不改写 host payload。完整命令表与迁移窗口见已接受的
[任务导向 UI 命令入口](proposals/0.6.0/task-oriented-ui-entry.md)。

**"不做坐标驱动"管的是身份，不是几何。** 一个用稳定 identifier 锚定的目标，其边界内的相对比例
坐标（各轴 `[0,1]`）是允许的——按住方向盘的上半部、从卡片中心往下拖，这些说的都是"这个控件的
哪个部位"，跨设备复现，也仍然经过歧义、代际和门的同一套围栏。被禁的是让**屏幕**坐标充当身份：
它换台设备、换个窗口大小就打在别的东西上。

由此推出一条必须长期守住的边界：局部坐标换算出的全局坐标是**单次调用内的瞬时实现细节**，不进
目录、日志、可复用脚本或调试轨迹。一旦它被持久化，任何"照着记录再跑一遍"的能力就天然有了一个
绝对坐标入口，上面那条红线就只剩字面。

通用 Semantics 写动作同样不得把“当前最新节点”当作围栏。`ui.semantics.actionByIdentifier` 要求调用方
携带先前观察到的 generation，在一次 App 受理内按 identifier 唯一解析、核对该代际、执行 policy/gate，
再以同一 generation 门后二次解析后派发。它只覆盖既有七项公开 action allowlist；缺 generation、换代、
歧义、未知参数或未公开 action 均 fail-closed，不自动重取或重放。CLI canonical path 是
`ui action <identifier> <generation> <action> [text]`；旧 `ui tap` 与 nodeId action 契约保持不变。完整边界见
已接受的 [Identifier action](proposals/0.5.0/semantics-identifier-action.md)。

调试轨迹的事实边界同样以观察者为准：CLI 只持久化自己实际看到的 session、request/response、job、
执行证据和 artifact，不把 App host 内部 audit sink 的事实自动升级为 CLI 已观察事实。M0 原先关于
“共用 emit 点”的结论因 host/CLI 进程边界无法成立，已于 2026-08-18 明示重新接受为：四包不为此新增
跨进程 audit event-stream；host audit 与 CLI trace 共享纯脱敏/分类投影，是否传输仍由显式协议决定。

host audit sink 的投递边界以 ledger sequence 为序：单消费者只有在前一个 sink Future settle 后才启动
下一项，业务 invocation 永不等待 sink。dispatcher 的 capacity 同时计算 active 与 waiting，默认 256；满时
保留已接收前缀并丢最新，以精确 sequence burst 通过既有 error observer 报告，不驱逐旧项伪造连续后缀。
drain 是有预算的 terminal 操作，默认 2 秒；timeout 返回结构化结果并明确 abandoned 数量，不能把迟到
settle 冒充 cooperative cancellation。完整状态机与隐私边界见已接受的
[Audit sink 顺序投递与有界背压](proposals/0.5.0/audit-delivery.md)。

invocation 的等待与停止同样不混：deadline 或 caller disconnect 只证明调用方不再等待；只有完整 pipeline
settle，或 context-aware consumer 明确确认底层已停止且不会再产生副作用，才能释放 host execution slot。
registry/external 共用默认 8 路的 host admission，direct 的 transport processing 门另行计数并可跨 response
关闭继续保留；显式 cancel 走独立 protocol-owned method/endpoint，不伪装成 consumer command，并以专用有界
control slot 保证普通 processing 满载时仍可达。host dispose 先关闭 invocation 受理并形成有预算
终态，再 drain audit，确保取消/放弃事实先进入 ledger。完整 wire、容量、降级与竞速规则见已接受的
[Invocation cooperative cancellation、deadline 与统一受理预算](proposals/0.5.0/invocation-cancellation.md)。

### 6. 慢事实用 job 表达

批处理、同步这类长流程不伪装成即时命令：受理即返回 `jobId`，事件带单调序号与事实
来源，取消 / 超时 / 代际失效都有类型化终态。等待是服务端长轮询（客户端声明预算，
服务端夹紧到上限），不是客户端刷屏轮询。

Job ledger 使用两个独立的有限预算：`maxRunningJobs` 限制正在执行的任务，`retainedJobs` 限制可回读的
已结束任务。取消 callback 也有等待上限；超时只表示取消未被确认，不能据此写入 cancelled 终态。
没有 callback 同样不能写 cancelled；callback 返回是 consumer 对“底层操作已停止”的证明，不只是取消
请求已经发出。

```mermaid
sequenceDiagram
    participant CLI
    participant Host as App host
    participant Ctrl as App controller
    CLI->>Host: exec example.job.run
    Host->>Host: 校验参数 → 过双层门
    Host->>Ctrl: 复用既有 controller（自带并发许可）
    Host-->>CLI: admission: accepted, jobId
    CLI->>Host: job.wait（服务端长轮询，声明等待预算）
    Ctrl-->>Host: 业务终态（成功 / 类型化失败）
    Host-->>CLI: events: running → completed / failed
```

## 协议演进

CLI 与 host **分开部署**：CLI 从终端装，host 跟着某个接入方发布的 App 走。已经有两个接入方，
各自 pin 在不同 tag 上（见[兼容矩阵](compat-matrix.md)），所以「两端同版本」从来不是可依赖的
前提。本节说的是：在不动 `schemaVersion` 的前提下，协议怎么加东西才不打断正在跑的老客户端。

### 两种读面，代价差一个数量级

| 读面 | 谁在读 | 加字段的后果 |
|---|---|---|
| **松读面**——identity / catalog / snapshot 这些逐键读的 map | 客户端手写读取，不认识的键直接忽略 | 安全 |
| **严格解码面**——生成的 `XxxWire.fromJson`，遇未知键即 `FormatException` | 已发布客户端解码请求与信封 | **当场打断老客户端** |

两者在源码里长得一模一样：都是往 `contracts/core_wire.json` 里加一行。所以
`packages/patchbay/test/protocol_surface_golden_test.dart` 把「契约里每个 wire 类型的形状」和
「客户端源码里正在严格解码哪些类型」一起钉成 golden——改动不会被阻止，但一定会在 diff 里现形，
评审时能看出踩的是哪一类。其中 `PatchbayIdentityWire` 另有一条单独断言：一旦有客户端改用生成
解码器读 identity，新 host 对老 CLI 就从「多几个字段」变成「握手直接失败」。

**写方案之前先查那份名单。** golden 里的 `strictlyDecodedByShippedClients` 是从客户端源码里抽出来的
事实，不是一份人工维护的清单，所以它会随客户端改动自己变。它管的后果很具体：名单里的类型加一个
字段、或者往名单里的枚举加一个值，已发布的 CLI 读到就是当场 `FormatException`——不是少认识几个
字段，是这条命令彻底不能用。一个提案如果打算扩展目标描述、artifact 元数据或某个请求形状，第一件事
是确认要改的类型在不在名单里；在，就改设计（换新字段、另起类型、走列表里加字符串），不是改名单。

`schemaVersion` 保持 `1`。它是运行时强校验的兼容边界（对不上即 `schemaVersionMismatch`），只在
**老客户端再也读不懂**时才该动；为加字段升它，等于把所有老客户端一次性踢下线，换一个没人需要
的版本号。

### protocol-owned fields always win

`serverVersion`、`features`、`catalogDigest` 由协议层自己写，不接受 consumer 覆盖——consumer 目录
里的同名键会被 host 覆盖掉。客户端读到 Patchbay 的 identity，就有权假定协议层自己实现的能力是真的；
这条铁律是「能力声明」能被当成承诺来用的全部前提。

### 三件东西，各答一个问题

**`serverVersion`——我在跟哪个构建说话。** host 把自己编译自的 `patchbay` 版本报在 identity 上。
Dart 运行时读不到自己的 `pubspec.yaml`，所以这个数字只能靠随包走的常量（`lib/src/version.dart`），
也因此它是发版时除四包 manifest 与两份 README 之外还要再改的一处；`release_version_parity_test.dart`
把它钉死在四包版本上——常量漂移不是印错一份文档，是**全网 App 谎报自己的构建**，而谎报比不报更糟。

**feature capabilities——按声明降级，不靠猜。** 没有它时，「这条应答里没有 `lifecycleState`」和
「这台 App 的 lifecycle 未知」在客户端眼里一模一样，客户端只能二选一并有一半时间是错的——这正是
[受理 ≠ 执行](#1-受理--执行)要防的「让人误信」在协议演进上的同一副面孔。

它**声明侧封闭、读取侧开放**：host 只能声明 `PatchbayFeature` 枚举里的名字，所以一个能力不会被
consumer 生造、也不会在两个 App 里指两件事；客户端则把它当普通字符串读，遇到没见过的名字必须
降级成「我不用它」，绝不能变成解码失败。这个不对称就是全部机制——读取侧也封闭，就会毁掉它本来
要提供的前向兼容。

一个名字只有在**真的有客户端按它分支**时才配进枚举；声明一堆没人读的能力，等于把握手变成会漂的
文档。反过来，声明了却不兑现比不声明更糟：客户端已经停止把缺字段当「老 host」、开始当数据了，
所以 doctor 把「失约」单列成一条警告，而不是并进正常降级。

**catalog digest——App 声明的能力面变没变。** 手工 diff 两份 catalog 全是噪声（注册顺序、排版
自己会动），所以摘要算在一份规范化形式上：对象键递归排序，条目各自规范化后按字符串排序。

只覆盖 `commands`。`uiTargets` 是**当前挂载**的目标，导航一下就换一批，与 App 声明的能力面无关
——摘要要是跟着翻，消费端只会学会忽略它。`schemaVersion` 因相反的理由排除：协议自己拥有且恒定，
收进来只会让摘要在「什么都没变」的协议升级上动。被拒的 catalog 不带摘要——它根本没有 `commands`，
没有命令面可描述，也就不生造一个。

`covers` 跟着值上路，正是为了 `catalogDigest` 这个名字不许诺它兑现不了的东西：读者被告知哈希的是
哪一块，而不必自己假设；后续版本扩大覆盖面时，也不会有读者在悄悄比两个不同的东西。同理，CLI
**复算**而不是转述——一个消费方验不了的摘要就是个只能信的数字，而「让客户端相信 host 没说过的话」
正是这套东西要防的那一件事。算不动的（算法或覆盖面超出本版认知）报 `unsupported` 而非 `mismatched`：
「我查不了」和「这是错的」是两个答案，只有后者是关于 App 的新消息。

这里有一条容易踩反的边界：**容忍多出来的字段，不容忍读不懂的条目。** 摘要对象上多一个兄弟字段
可以直接忽略——它不改变本版已经认得的那些字段的含义；但 `covers` 数组里混进本版读不懂的条目时，
**整份覆盖必须按畸形处理**，绝不能把那一项悄悄丢掉。丢掉之后剩下的很可能**恰好**就是本版认得的
覆盖面，于是「我只读懂了一部分」被伪装成「我全读懂了」，CLI 会对着一个并非按此口径算出来的值说
`verified`——正是上一段要防的那件事，只是从另一个门溜进来。丢条目把 host 的声明悄悄改窄了，加
字段不会，这就是两者待遇不同的全部理由。同样地，它降级成 `unsupported` 而不是「没有摘要」：host
明明带了，只是本版读不全，说成「没带」会让上层反过来报一条并不存在的能力失约。

### 兼容用例钉的是两个方向

`packages/patchbay_cli/test/protocol_compat_test.dart` 同时钉死：

- **新 CLI ↔ 老 host**——喂**手写冻结**的 v0.2.0 语料（`test/golden/legacy_host_v0_2_0/`）。这些
  文件描述的 host 已经不在本仓任何一行代码里，只在某个接入方已发布的 App 里跑着，所以**任何情况下
  都不要用当前实现「重新生成」它们**：那等于把「新 CLI 还能不能对付老 host」改成「新 CLI 能不能
  对付它自己」，那道闸恒绿且毫无意义。
- **老 CLI ↔ 新 host**——在用例里**复刻** 0.2.0 客户端的读法（逐键读、多余键忽略、`schemaVersion`
  必须是 1），拿它去读当前 host 真的吐出来的东西。复刻而不是 import，是因为要测的正是「当年那份
  代码」的行为，而当年那份代码已经不在树里了。

从 0.3.0 起，发布流程会在 tag 之前由 `release_prep --apply` 把
`packages/patchbay/test/golden/host_surface.json` 中真实 host 生成的 identity / catalog 拆成版本化语料，
写入 `packages/patchbay_cli/test/golden/legacy_host_v<version>/`；RC 与正式版本各有独立目录。兼容测试
枚举这些目录并交给当前 CLI 读取。这里的唯一真源仍是实际 host surface golden，不再手抄一份“应该
长这样”的响应；0.2.0 那份手写历史语料带有明确标记，发布脚本拒绝用当前实现覆写它。

### 本地会话文件是第三个兼容面

wire 面有握手兜底：版本对不上就 `schemaVersionMismatch`，谁都不会误伤谁。**会话目录没有这层保护。**
它是一堆躺在临时目录里的 JSON，任何版本的 CLI 都可以直接读写，而现有 reader 遇到不认识的
`schemaVersion` 会抛，扫描目录时又会把解析失败的文件**删掉**——那是为了不让一个损坏的记录永久
卡住选择。两条行为合起来意味着：给会话记录升一次版本号，实际后果是装着老 CLI 的那台机器会悄悄
删掉新 launcher 刚写下的记录，而操作者只看到「会话不见了」。

所以会话记录的 `schemaVersion` 保持 `1`，新字段一律松读追加，reader 逐键读、不认识的键忽略。要真的
需要一次不兼容的结构变更，先换目录名，让新旧两套记录互不可见，而不是指望老 CLI 认得新版本号。

### SDK 下限是一组实测组合，不是两个独立数字

Flutter release 自带一版精确的 Dart，framework 的 transitive package 也随之精确 pin；因此「最低
Dart」和「最低 Flutter」不是两条可以分别宣称的承诺——两个约束必须在**同一个真实 release** 上同时
成立才算数。PB-050-12 的调查证明了这条教训不是纸上谈兵：仓库曾同时声明 Dart `>=3.11.0` 与 Flutter
`>=3.38.0`，但 Flutter 3.38.x 全系只内置 Dart 3.10.x，两个数字组合起来根本不指向任何一个可安装的
真实版本。详见 [`docs/verification/0.5.0-flutter-sdk-floor.md`](verification/0.5.0-flutter-sdk-floor.md)。

更进一步：**「能装」不等于「能过现有测试」。** 一份组合只要 `pub get` 能解析全部 package 就满足了
「可安装」，但那只证明了依赖图相容，不证明源码在那份更早的 Flutter/Dart 上运行结果与当前开发/CI
使用的版本一致。PB-050-12 的调查里，机检确定的「最早可安装」组合就踩到一个既有测试断言失败——而这
与该组合能否 `pub get` 无关，只有把 `analyze` 和 `test` 也跑一遍才会暴露。下限验证因此必须包含完整的
resolve + analyze + test 链，不能只做依赖解析就宣称「验证过」。

再进一步：**下限不只要「能过测试」，还要「提供本仓安全语义所依赖的框架行为」。** 同一条调查最终把
那次失败归到上游 `af35e77c83d`——在它之前 `Semantics(identifier:)` 不构成语义边界，identifier 会被祖先
节点吸收，`blockUserActions` 因此读不到目标上，`ui.reveal` 的遮挡判定 fail-open。这类差异不是「旧版本
慢一点」，而是**声明的下限根本不满足遮挡准入与 reveal 赖以成立的前提**。所以下限数字的真正判据是
「本仓的安全边界在这个版本上成立」，不是「装得上且碰巧跑绿」；把下限压到一个语义前提不成立的版本，
等于对接入方做一个自己无法兑现的承诺。裁决与落地见
[SDK 下限提升](proposals/0.5.0/sdk-floor-raise.md)。

**验证下限时先清跨 SDK 构建缓存，否则会伪造出并不存在的「release 缺陷」。** 同一条调查一度把两个较新
release 记成「自带与 patchbay 源码无关的引擎资产缺陷」（`ink_sparkle.frag ... Expected 2, got 1`），
复核后证伪：资产 manifest 的 runtime-stages 版本戳由**生成它的那个 SDK** 决定，而缓存留在包目录里不随
SDK 切换失效，下一个 engine 版本读到旧戳就报错。在**已知全绿**的版本上用同样手法可以稳定复现出同一
异常，清掉每个包的 `.dart_tool` 与 `build` 后立即恢复全绿。教训是通用的：在同一棵工作树里跨 SDK 版本
做对比验证，每次切换都必须清构建缓存，否则拿到的失败可能完全是自己制造的——CI 每次是干净容器所以
不受影响，这恰恰让本地复现更容易误判。

同样必须留意平台边界：本地或沙盒环境能跑的验证平台，不一定是实际 CI runner 的平台（例如
macOS 与 Linux、不同 CPU 架构）。跨版本、跨平台都可能出现的差异，只有在目标平台的真实 CI 上跑过
才能定论；本地复现出的失败/通过在写进文档时要明确标注验证平台，不能默认它可以跨平台外推。

## 传输选型

- **主通道 VM Service**：debug/profile 天然存在，零额外监听面，与 DevTools 共用。
- **可选直连 HTTP**（`patchbay_transport`）：为"没有 VM Service 端口转发"的场景准备。
  构造惰性、显式启动、短期 bearer、identity 漂移即关闭；明文、无 TLS，仅限受信网络
  实验用途。选择短连接 HTTP 而非 WebSocket，是因为现有能力都是有界 request/response，
  更小的状态面便于严格限制 body、超时和并发。

## 非目标（红线）

- 不做任意坐标驱动，也不从全树扫描结果猜测稳定写操作目标；
- 不重造 hot reload / DevTools（DevTools 能力走转发，标 `flutterSdkPassthrough` + SDK
  漂移警告）；
- 不支持 release 构建，不建立任何降级通道；
- 装卸包与进程管理不做——那是 adb / xcrun 的地盘；
- **四个 package 不直接操作系统 UI**。系统权限编排由 CLI 通过版本化 driver protocol 调用外部
  companion 完成，App 内代码不获得任何操作系统 UI 的操作能力，release 构建不可达。边界始终是
  App 内不越权、不重造 adb；companion 只是 adb / simctl / hdc 本身的调用方，与“不重造 DevTools，
  能力走转发”同理。

放弃的特性进本节；红线的放宽会改变协议行为或安全边界，记入 [CHANGELOG](../CHANGELOG.md)。
两者都不静默改写。
