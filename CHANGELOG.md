# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## 0.5.0 - 2026-08-28

接入成本与入门门槛批次：消费者侧 `SKILL.md` / `INSTALL.md` 渐进式披露入口闭环，瘦输出
`--view brief` 与大载荷落 artifact；host 侧收紧 provider、目录、审计、invocation 四条边界，
新增 identifier 锚定的合成 tap、点性 action 遮挡准入、`ui.reveal` 与外部会话注册命令。
含 Dart source breaking change 与最低 SDK 上调，迁移见下面首屏五条。

- **CLI 公共 Dart API 从 203 个符号收口为 2 + 8 个封闭清单**（PB-050-13）：`patchbay_cli.dart`
  只保留 `runPatchbayCli` / `PatchbayExitCode`，新增 opt-in `patchbay_client.dart` 只保留
  Proposal 冻结的 8 个符号（见 [CLI 公共 API 收口](docs/proposals/0.5.0/cli-public-api-surface.md)）；
  只用可执行文件 + `--json` 的接入方不受影响，直接 `import` 内部 library 或依赖被移除符号的
  接入方需要改法。
- **最低支持版本上调为 Flutter `>=3.44.0`、Dart `>=3.12.0`**（PB-050-12）：低于此版本的 App 侧
  依赖解析会直接失败，升级前先核对自己工具链版本；这是已验证下限并由阻断性 CI lane 守门
  （裁决见 [SDK 下限提升](docs/proposals/0.5.0/sdk-floor-raise.md)）。
- **domain 写命令的 `gates` 从目录展示变为 host 受理段强制求值**（PB-050-25）：`sideEffect`
  非 `none` 的命令声明了 `gates` 却没有配 evaluator 时，现在以 `consumerGateRejected`
  （`reason: gateEvaluatorUnavailable`）稳定拒绝，不再只是在 catalog 里展示；升级前确认
  `PatchbayServiceHost(domainGates: ...)` 或 `PatchbayFlutterServiceHost` 已经接好 evaluator。
- **不带 `--session` 的会话选择改为按 Git worktree/checkout 亲和**（PB-050-14）：不带
  `--session` 的命令现在只在当前 checkout 的会话记录里选，跨 checkout 需要显式 `--session`；
  依赖旧全局选择行为的脚本需要更新（升级说明见[使用指南「会话选择」](docs/guide.md#会话选择)）。
- **接入方迁移指引**：(1) 依赖换 pin——四包已按 hosted 约束互相依赖，git pin 的接入方不能只改
  单包：要么整体改用 pub.dev 版本，要么用 `dependency_overrides` 把四包统一指回 git
  （见[发版检查清单](docs/release-checklist.md)「consumer 换 pin」一节）；(2) 不经
  `patchbay launch` 启动 App 的接入方，把自建会话记录迁移到 `patchbay session register` /
  `session unregister`（PB-050-27，见[使用指南「自己起 App 的会话」](docs/guide.md#自己起-app-的会话register--unregister)）。

<!-- PUB_CHANGELOG:START -->
Patchbay 0.5.0 is the onboarding and progressive-disclosure release: a minimal
consumer entry that scales from read-only diagnostics to the full command
surface, thin `--view brief` output with artifact spill for large payloads,
hardened host boundaries, and new identifier-anchored UI capabilities.

### Highlights

- BREAKING: the CLI public Dart API narrows from 203 symbols to a frozen 2 + 8
  surface (`patchbay_cli.dart` plus opt-in `patchbay_client.dart`); consumers
  using the executable with `--json` are unaffected.
- BREAKING: minimum SDK floors raise to Flutter >=3.44.0 / Dart >=3.12.0 — a
  verified floor guarded by a blocking CI lane.
- Identifier-anchored pointer tap (`ui.gesture.tap`), occlusion admission for
  point actions, and `ui.reveal` driving lazily built lists with per-container
  authorization and tighten-only budgets.
- Domain-plane write commands now enforce their declared gates at host
  admission; session selection is workspace-affine, and externally launched
  apps register via `patchbay session register` / `session unregister`.
- Snapshot provider boundary hardened: non-JSON values, cycles, depth and byte
  budgets fail closed as `providerProtocolViolation`; audit delivery is
  strictly ordered and bounded; REPL terminal errors are line-delimited JSON.
- Session liveness upgraded to a three-state process-identity comparison with
  timezone-independent, payload-validated signatures; malformed records are
  quarantined instead of silently deleted.
<!-- PUB_CHANGELOG:END -->

### Added

- 新增可选的 `PatchbayVersionedSnapshotSource`：source 返回 `PatchbaySnapshotSample(contentRevision, body)`，host 在 revision 未前进时直接复用上次冻结视图、不读取新 body，并把答复标记为 `revisionSource: consumerReported`；revision 前进即使内容相同也递增 host `snapshotRevision`，倒退或负数返回 `providerProtocolViolation` 的 `revisionRegressed`。既有 `PatchbaySnapshotSource` 无需修改即可继续使用，仍返回 `revisionSource: hostObserved`；两种 source 互斥，由 host 构造期选定。

- 新增 `PatchbayCatalogProvider`、`PatchbayCatalogSample` 与对应 ServiceHost/Flutter host 构造入口，接入方可用单调 `commandsRevision` 显式失效 invocation catalog policy 缓存。

- 新增 invocation cooperative cancellation：context-aware handler 可区分 deadline、调用方断开、显式取消与 host dispose，并在底层停止后确认释放容量；VM Service 与 direct HTTP 提供同构 cancel 控制面。

- 新增 `ui.semantics.actionByIdentifier` 与 `patchbay ui action`，要求调用方携带已观察的 generation，并在一次受理内按稳定 Semantics identifier 解析、过门和二次复核后派发公开 action。

- 新增 `ui.gesture.tap`（CLI：`patchbay ui gesture tap <identifier> <generation> [--start <json>]`）：identifier 锚定、经真实指针管线的点按。注入真 `PointerDownEvent`/`PointerUpEvent`（异常路径补 `PointerCancelEvent`），复用 gesture 家族的逐点 clip/hit-test 准入与门后二次复核，被遮挡即 `uiGestureTargetObscured`；down→up 间隔是内部固定常数（不进 wire，仍受 policy `maxDurationMs` 预算约束）；`start` 缺省为目标中心且默认值声明在 catalog descriptor 上；调用方 `generation` 必填并在第一次解析即核对。与 `ui.semantics.tap` 并存：前者证明「真实指针可达并能触发」，后者驱动「声明了语义 action 的目标（含指针不可达者）」，两条 help 按调用目的互相指引。零新增稳定错误码。

- 新增 `ui.reveal <identifier>`：以稳定 Semantics identifier 锚定目标，在一次 App 受理内把懒加载列表里
  尚未挂载的目标驱动到**已挂载且露出**，并返回后续写命令该带的 `generation` 与该走哪条 tap 通道的
  `reachability`。CLI 语法 `patchbay ui reveal <identifier> [--container <identifier>]
  [--direction <forward|backward|both>] [--max-steps <n>] [--timeout-ms <ms>]`。
  - **未注入 reveal policy 即不进 catalog**：升级 package 不会让任何现有 App 多出一条命令。接入方要
    显式写下新的 `PatchbayRevealPolicy`（新公共类型 `PatchbayRevealDecision` /
    `PatchbayRevealDirection`，注入点是 `PatchbayFlutterBridge` 的可选具名参数 `revealPolicy`）才拿得到
    它；直接调 bridge 得 `uiRevealDisabled`。
  - **机制唯一**：只派发 `scrollUp/scrollDown/scrollLeft/scrollRight`，从不派发
    `SemanticsAction.showOnScreen`——那是一条接入方在快照与 policy 入参里都看不见、因此拒不掉的驱动
    通道。**不引入任何坐标入参**，也不按尺寸/深度给滚动容器打分：候选多于一个就拒绝并指引
    `--container`。
  - **逐容器授权、每步重评**：policy 的入参是被驱动的**容器**而不是目标；每次由内向外升层都是一次
    新的完整授权，每一步派发之前还会重解析容器、重跑 policy 并重评声明门。逐步重评意味着交互式 gate
    会被问到 `steps` 次——需要「一次确认覆盖整条 reveal」的接入方在自己的 gate 闭包内 latch，协议侧
    不提供 lease。
  - **三层预算只能收紧**：host 硬顶（200 步 / 2 分钟）→ policy → 命令参数，且 min 通过**拒绝**达成而
    不是静默夹取（越界即 `uiRevealBudgetExceeded`，一步都不派发）。单一 deadline 在受理时算一次，帧
    驱动推进、无墙钟 sleep；升层到一个时长授权更严的容器时不改写 deadline，而是停下并报
    `containerBudgetTooSmall`。
  - **`direction` 是内容序不是屏幕方向**：`forward` 朝 `maxScrollExtent`，落到哪个 `SemanticsAction`
    由容器当前暴露的 action 与观察到的位移符号确定，因此 `reverse: true` 与横向列表都不要求调用方先
    知道布局方向。请求显式方向且容器停在中段时，第一步可能是一次朝反方向的探测步（每容器至多一次，
    计入 `steps`）；用默认的 `both` 可以避免它。
  - **payload**：`revealed` 带 `nodeId` / `generation` / `reachability`（`pointer` ⇒ 随后走
    `ui gesture tap`；`semanticsOnly` ⇒ 随后走 `ui tap`）；`failed` 带封闭的 `reason`
    （`stepBudgetExceeded` / `scrollExhausted` / `targetObscured` / `targetBlocked` /
    `targetAmbiguous` / `containerChanged` / `containerDenied` / `containerBudgetTooSmall` /
    `policyChanged` / `gateRejected` / `lifecycleNotResumed` / `timeout` / `scrollActionFailed`）。
    两者都带复数 `containers`（每项 `nodeId` / `generation` / `steps` / `direction` /
    `extentGrowthSteps`），按被驱动的先后顺序由内向外排列；不存在任何单数 container 字段。观察到的
    滚动位置与 extent **只以计数形式**出现，不回显像素值、坐标、rect 或探针点。
  - **露出判据复用 PB-050-16 的固定采样基建**：按目标 rect 取中心与四象限五点，任一点未被挡即通过。
    诚实边界不变——这是固定采样准入，不是可达性证明，也不承诺下一帧仍然如此（那由返回的
    `generation` 兜住）。
  - 新增稳定拒绝码 `uiRevealDisabled` / `uiRevealNoScrollableContainer` /
    `uiRevealContainerAmbiguous` / `uiRevealDenied` / `uiRevealBudgetExceeded` /
    `uiRevealPolicyChanged`。老 CLI 读到 `outcome: 'failed'` 仍按既有映射得到 `typedFailure` 退出码。
  - 不受影响的部分：`ui.wait`、`ui.semantics.*`、`ui.gesture.*` 的 wire、CLI 与失败码逐字节不变；
    `PatchbaySemanticsActionPolicy` / `PatchbaySemanticsActionDecision` 一个字节不动，现存接入方代码
    无需改动即可编译。

- 新增树类命令的大载荷自动落 artifact：`ui semantics tree`、`ui widget-tree`、`ui render-tree`、`ui focus-tree` 在 stdout 文档超过 64 KiB（可用 `--max-inline-bytes` 调整，`0` 关闭）时自动把无界成员写入本地文件，stdout 就地换成带 `path`/`length`/`sha256`/`verified` 的校验回执，并在顶层附上同一份 `localArtifact`；`treeRevision`/`nodeCount` 等有界事实继续留在 stdout。落盘的文件同时按内容寻址进当前 trace（`artifact.attached`），与既有 blob 下载一致。无界成员为空或 `null` 时（例如非 debug 构建下的三棵诊断树）不自动落盘、按原样内联，避免用一份「已校验」的回执掩盖「本来就没有内容」。这四条命令的 `--output`/`--force` 从「不合法」变为合法（`--output` 仍可选）。同时，`capture`/`blob get`/`logs export` 的 `localArtifact` 回执新增 `origin` 键（既有下载路径为 `hostBlob`，树类落盘为 `cliRendered`），使一个 reader 用一套判据区分两种来源；这是 additive 改动，既有键的名字、位置与值都不变，逐键读取的老 reader 不受影响。阈值内、不带 `--view` 的输出逐字节不变。

- 新增全局 `--view brief`（默认 `full`，必须与 `--json` 同时使用；repl 内可按行覆盖会话默认值）：对受理成功的响应按封闭的删除表投影出决策事实，删掉的字段路径逐条列在追加的 `localView.omitted` 里，删除是保守的 deny-list，不认识的字段一律原样保留。已冻结投影的命令族：`catalog`（每条命令的 `parameters`/`responseSchema`/`executionContract`/`retryPolicy`；`summary` 保留，它是 `describe` 之前判断命令用途的唯一线索）、`ui semantics tree`（`payload.nodes`）、`ui widget-tree`/`render-tree`/`focus-tree`（`data`）、`logs query`（`payload.records`），以及作用于所有响应的 `notice` 通用规则。字段为空或 `null` 时一律不删也不登记，因此「App 给了空的」与「brief 删掉了」始终可分辨。不带 `--view` 的默认输出逐字节不变。

- 新增面向消费者与 AI agent 的 Patchbay Skill 和安装入口，以只读诊断为默认起点，按任务逐层发现 live catalog、命令帮助与专项说明，并由 CLI registry 机检 Skill 中的起步命令不发生漂移。

- 新增 `patchbay session register --ws-uri <uri> --application-id <id> --device-id <id>
  --process-id <pid> [<session-id>]` 与 `patchbay session unregister <session-id>`：给不经
  `patchbay launch` 监督、由接入方自己启动的 App 登记一条本地会话记录，此后同一 checkout
  内的命令不带 `--session` 也能自动发现它。两条命令都不连 App，只读写会话目录：`--ws-uri`
  在这里是被记录的传输地址而不是被拨号的；记录复用既有 pending 语义与字段，不新增记录字段，
  `applicationId` 与 launcher 声明的记录一样等第一条真正连上的命令去对账。`--process-id`
  是本机持有该会话的进程，`sessions list` 的状态与 `sessions prune` 都按它的存活判定；
  `--build-mode` 默认 `debug`。记录归属执行命令的 checkout，因此自动获得 workspace 亲和性，
  别的 checkout 看不见它。省略 `<session-id>` 时由 CLI 命名并在输出中报出；同名记录已存在
  以 `sessionAlreadyRegistered` 拒绝而不覆盖。`unregister` 同时清掉指向该记录的固定项，
  记录已不存在时正常退出并报告 `removed: false`，便于放进退出清理路径。输出走既有 JSON
  信封：`register` 返回一个 `session` 对象，`unregister` 返回 `sessionId` 与 `removed`。

### Changed

- Snapshot provider 返回值现在会在 host 边界内按严格 JSON 规则有界验证并冻结；非法类型、非字符串 key、非有限数、循环、过深或过大的结构统一返回 `providerProtocolViolation`，有效响应、selector、revision 与 diff 共用同一份不可变读视图。

- Snapshot revision retention 现在同时受份数、单份 canonical UTF-8 字节和累计 retained 字节三个 host 内预算约束（默认 32 份 / 1 MiB / 8 MiB，可用 `PatchbaySnapshotRetentionLimits` 在 1..128 份、64 KiB..4 MiB、不小于单份上限且不超过 32 MiB 的范围内配置）；单份超出运行预算返回新的稳定 code `snapshotPayloadTooLarge`（details 只含 `encodedBytesAtLeast`/`maxSnapshotBytes`），超出 4 MiB 契约天花板仍是 `providerProtocolViolation`，两者都不改写 latest 或已保留的 revision。返回 metadata 在既有松读面新增 `retainedByteLimit` 与 `snapshotBytes`，因累计预算淘汰 baseline 后的 diff 继续返回 `snapshotRevisionUnavailable` 并附带 `retainedByteLimit`。同一时刻的并发 snapshot 读现在共享一次 provider 采样，各调用者的 selection、diff 与 wait 预算仍相互独立。

- invocation 现在对空参数及 registry 命令同样执行整份 catalog fail-closed 校验；legacy catalog source 仅合并并发读取，versioned provider 则按 commands revision 复用已验证 policy。

- `PatchbayServiceHost` 的 `auditSink` 改为按账本顺序单消费者投递，并新增有界队列、溢出/关闭错误及 `drainAudit` / `dispose` 终态统计；sink 迟延或失败仍不改写命令结果。

- invocation 统一受 host-wide 并发预算约束，默认最多 8 条、可配置 1～256；legacy handler 在 deadline 或取消后明确返回 `cancellation: unsupported`，且仍保留容量直到 handler settle。

- Semantics probe 不再为已就绪的 owner 主动请帧：`ui.semantics.tree`、identifier 观察与解析、`ui.gesture.*`、`ui.reveal` 读取的是命令开始时已提交的语义树，不再额外刷新一帧；`ui.wait` 每一轮未满足的条件因此只驱动一帧而不是两帧，空闲 App 不再被只读探测按显示帧率驱动。
  - 观察语义随之明确：one-shot 命令答复的是当前已 flush 的树，不承诺「命令后下一帧」的状态；要等某个变化发生请用 `ui.wait`。
  - `ui.wait` 的 `frameRevision` 计入本次调用实际驱动的**所有**帧，包括 owner 尚不可用时的有界恢复帧（最多三帧，单帧仍最多等 2 秒），并且这些恢复帧用的是调用方自己的 `timeoutMs` 预算，不额外延长。同一次观察的 `elapsedMs` 与 `frameRevision` 可能比旧版本更小，`schemaVersion`、命令形状与稳定 code 均不变。

- 改进 CLI 可发现性：空会话给出 launcher 与 `--ws-uri` 恢复路径，raw artifact help 指向自动分块校验下载命令，并明确文本输入 callback、身份字段及 blob 长度字段的语义。

- `sessionDirectoryEmpty` 的 hint 补上第三条恢复路径：App 已经以自有方式启动、不经 `patchbay launch`
  的场景，现在可以直接提示改用 `patchbay session register` 登记该会话，不必再套用只适用于
  `patchbay launch` 或手动 `--ws-uri` 场景的另外两条建议。

- 新增非阻断的 `sdk_floor` CI lane（GitLab 与 GitHub 两边）：机检定位出满足现有 `pubspec.yaml` 声明约束（Dart `>=3.11.0`、`patchbay_flutter`/`example` 的 Flutter `>=3.38.0`）的最早可安装组合是 Flutter 3.41.0（内置 Dart 3.11.0）——原声明的 `flutter: '>=3.38.0'` 与 Dart 下限其实互斥（Flutter 3.38.x 全系只内置 Dart 3.10.x），已如实记录在 `docs/verification/0.5.0-flutter-sdk-floor.md`；该最早组合目前还未全绿（一条既有 reveal 测试断言在本地复现下失败，且未在 Linux CI 上复核），因此这条 lane 先非阻断跑，不改变现有三条 lane 的通过标准，也不改动任何 package 声明的 SDK 下限数字。

- **最低支持的 SDK 组合提升为 Flutter `>=3.44.0` / Dart `>=3.12.0`**（四个 package 与 `example` 的 `pubspec.yaml` 同步收紧）：旧声明的 Flutter `>=3.38.0` + Dart `>=3.11.0` 指向一个装不出来的组合（Flutter 3.38.x 全系只内置 Dart 3.10.x），而真正能装出来的 Flutter 3.41.x 缺少上游提交 `af35e77c83d`——在它之前 `Semantics(identifier:)` 不构成语义边界，`blockUserActions` 会被祖先节点吸收而读不到目标上，导致 `ui.reveal` 把被模态屏蔽的目标误报成 `revealed`，`ui.semantics.*` 也会用 `uiSemanticsActionUnavailable` 顶替 `uiSemanticsActionBlocked`；含该修复的第一个 stable 就是 Flutter 3.44.0，其五个 package 已实测全绿。运行时行为、wire `schemaVersion`、descriptor 与稳定错误码均不变，接入方升级路径只是把自身 Flutter 升到 3.44.0 及以上；`sdk_floor` CI lane 同步钉到 3.44.0 并转为阻断门禁，声明下限此后由 CI 持续守门。

- **Breaking:** `patchbay_cli` 的 Dart 源码入口收口为两个封闭清单，其余符号退出公共面。
  `package:patchbay_cli/patchbay_cli.dart` 只导出 `runPatchbayCli` 与 `PatchbayExitCode`，
  且 `runPatchbayCli` 收窄为 `Future<int> runPatchbayCli(List<String> arguments)`；
  新增 opt-in 的 `package:patchbay_cli/patchbay_client.dart`，只导出 `PatchbayClient`、
  `PatchbaySnapshotDiffClient`、`PatchbayRuntimeIdentity`、`PatchbayProtocolException`、
  `PatchbayTransportException`、`PatchbaySnapshotRequest`，以及新的
  `connectPatchbayVmService` / `connectPatchbayDirect` 两个连接 factory。迁移：
  - 只执行安装后的 `patchbay` 与 permission 可执行文件的，无需任何迁移——命令、退出码、
    stdout/stderr、稳定 JSON、wire 与 VM Service / direct 语义都不变；
  - 调用 `runPatchbayCli(arguments)` 的，import 与调用都不变；给它传 `connect` /
    `replInput` / `output` / `errorOutput` / `permissionCommands` / `environment` 的，
    这些是包内测试与进程注入 seam，不再对外承诺；
  - 用 `PatchbayClient` 或 VM/direct 连接类的，改 import `patchbay_client.dart` 并改用
    两个 factory，连接类本身不再公开；
  - 用 `PatchbayErrorEnvelope` 读失败的，改按 `--json` 输出的 error envelope 解析——
    字节契约不变，只是不再有对应的 Dart 类；
  - 用 launcher / session / trace / doctor / repl / manifest / permission adapter 实现，
    以及测试时钟、随机数、sleep、starter、factory、目录与上限常量的，没有 Dart 替代：
    改走 CLI 命令加稳定 JSON（外部启动的 App 会话见 `patchbay session register`），
    或在自己的包里实现外部进程协议。
  不提供 `legacy.dart` / `testing.dart` 过渡入口，也不提供兼容别名。pub 的 `^0.4.1`
  约束不会自动选到 0.5.0；用 git / tag pin 的接入方必须显式换 pin 并重新编译验证。

- 不带 `--session` 的会话选择收紧到当前工作区（checkout）之内：CLI 每次调用计算一次
  host-local 的 workspace identity（Git worktree 顶层，非 Git 目录取 cwd 本身；共享 Git
  common dir 的两个 worktree 判为不同），固定项改为按 workspace 分别保存，`session use`
  只能固定属于当前 checkout 的记录，`sessions list` / `doctor` / `trace` 与解析器共用同一
  套归属判断；跨工作区选择只保留显式 `--session <id>` 一个入口，它仍完成完整探活与 runtime
  identity 握手且不改写任何一边的固定项。新增四个稳定码：当前 checkout 无候选
  `sessionWorkspaceEmpty`、判不出当前 checkout `sessionWorkspaceUnavailable`、固定别处记录
  `sessionWorkspaceMismatch`、按 workspace 的固定项超过 256 份
  `sessionSelectionCapacityExceeded`。会话记录新增 additive 的
  `workspaceIdentityVersion` / `workspaceKind` / `workspaceId` 三字段，`schemaVersion` 仍为
  1，老 reader 忽略这三项照常读取；旧记录不删不改，路径可复算证明属于当前 checkout 时在握手
  后原子补写身份，证明不了则只能用显式 `--session` 选择；升级后遗留的全局 `selected-session`
  被一次性退役，只有它指向的记录能证明属于当前 checkout 时才转成该 checkout 的固定项，其余
  情况只丢固定项、不迁移也不删除记录。0.4.x 旧 CLI 不具备本条隔离保证。

- `patchbay session use --clear` 在判不出当前工作区（checkout）时按 `sessionWorkspaceUnavailable`
  拒绝并退 3，与 `session use <session-id>` 一致；此前这种情况下它会打印「没有固定项」并正常退出，
  而该工作区的固定项其实原封不动留在磁盘上，后续不带 `--session` 的命令仍会用它。判得出工作区时
  语义不变，仍然只清除当前 checkout 自己的固定项。

- **Breaking:**（仅 Dart source 层面）`PatchbayGestureKind` 追加枚举值 `tap`（追加在末尾，既有值 index 不变，payload 使用 `kind.name`）。对 gesture policy 里写穷尽 `switch` 的接入方，升级后会得到分析器错误，需为 `tap` 显式补一个分支（允许、拒绝或收紧预算）；写了 `default` 分支的接入方将由既有默认分支替 `tap` 做决定，建议升级后复核该分支对点按是否符合预期。未注入 `PatchbayGesturePolicy` 的接入方不受影响：整个 gesture 家族不进 catalog。

- 收紧 `ui.semantics.*` 的准入：点性 action（当前公开 allowlist 内即 `tap`）在派发前会复核目标是否被
  非模态覆盖层挡住，全被挡时以新的稳定码 `uiSemanticsTargetObscured` 拒绝，不再穿透激活一个真实指针
  够不到的目标。此前只有 `BlockSemantics`／`ModalBarrier` 会拦下这类调用。
  - 判定是**固定采样准入**而不是可达性证明：按目标边界取中心与四象限共五个采样点，任一点未被挡即放行，
    五点全被挡才拒绝；目标只在采样点之外露出窄缝时会被保守拒绝（fail-closed）。
  - 拒绝 `details` 固定为 `reason`（`hitTestOrClip`／`emptyBounds`／`viewUnavailable`／
    `renderAnchorUnavailable`）、`nodeId`、`generation`，identifier 锚定入口另带 `identifier`；
    不含坐标、rect、探针点，也不回显覆盖层的身份。
  - 没有 bypass、force 或 `ignoreOcclusion` 开关。确需穿透覆盖层的动作属 domain command 领域，由接入方
    自己的 policy 与 gate 负责。
  - 不受影响的部分：目标可达时 valid/rejection 回包逐字节不变；`focus`、`scroll*`、`showOnScreen`、
    `setText` 等非点性 action 行为不变；`uiSemanticsActionBlocked`、`isInvisible`、
    `areUserActionsBlocked` 的含义不变；descriptor、CLI 语法与 catalog digest 不变。老 CLI 读到新码时按
    既有 `admission` 分类落到 `rejected` 退出码，不会解析失败。

- 面向升级到 0.5.0 的接入方明确 `ui.reveal` 的 opt-in 边界：需要在构造 `PatchbayFlutterBridge` 时显式
  传入具名参数 `revealPolicy`；未注入时 `PatchbayRevealBridge.enabled`（`!kReleaseMode && policy !=
  null`）为假，命令不进 catalog，直调 bridge 得 `uiRevealDisabled`。这与 0.4.0 引入的 `gesturePolicy`
  同款——两者的 `enabled` 判定与直调拒绝路径逐字同形；`inspectPolicy`（0.3.0 起）同样遵循「未注入不进
  catalog」的既有约定，但直调时给的是 `commandNotRegistered` 而非专属 `*Disabled` 码。升级后不注入
  `revealPolicy` 不会让任何现有 App 多出 `ui.reveal` 命令。

- 会话存活判定收紧为 PID + 进程启动身份三元比对：POSIX 用 `ps -o lstart=`、Windows 用 PowerShell
  `Get-Process` 的 `StartTime`，两者都经现有 `ProcessRunner` seam；PID 存活但启动身份不匹配（PID
  复用）现在判定为会话已死。会话记录新增 additive 的 `processStartTime` 字段，没有该字段的旧记录
  行为完全不变，仍按纯 PID 判定；无论是旧记录还是本次启动身份采集失败，`patchbay sessions list`
  的人读与 `--json` 输出都会额外标注 `identityUnverified`，绝不会因为核实不了就 fail-closed 杀掉一
  个其实还活着的会话。

- 会话记录扫描不再对解析失败的 `.json` 文件静默删除：改为原地重命名为 `<原文件名>.quarantine-<pid>-<时间戳>`
  隔离保留，作为「记录为什么消失」的证据；隔离后的文件不再以 `.json` 结尾，之后的扫描不会重复处理。
  `PatchbaySessionStore` 新增 `quarantinedFiles()` 枚举隔离文件供诊断消费；隔离动作本身失败（例如目录
  权限受限）不会阻断本次 `readAll` 读取其余正常记录。临时文件 temp+rename 与并发写入语义不变。

- `patchbay_flutter` example 与四份 README 的 quick-start 注册代码段不再使用 `allow()` 空壳门：
  示范预设门改为「只读命令默认放行、写类命令默认拒绝并带 `notice` 说明」，且写明「按需在此放行」的
  显式放行范例；example 里 `ui.capture`/`ui.capture.diff`（`sideEffect: none`）与 `blob.*`/`logs.*`
  （`mode: readOnly`）不再挂在写门下，`ui.text.set`/`ui.text.enter`（`sideEffect: appState`）则补上了
  此前缺失的写门声明。这是示例与文档层面的默认姿态调整，不改变任何包公共 API。

- 收敛 CLI 一次性命令、`repl` 与 `launch` 的工作流指引，根 README 不再复制完整命令表，并修复发版时 AOT 安装示例中的下载、校验与移动文件名可能版本不一致的问题。

- **Breaking:** `plane: domain` 的写命令（`sideEffect` 为 `appState` / `external`）现在由 host 在受理段
  强制评估 descriptor 声明的 `gates`，此前 `gates` 对 domain 命令只进目录、不进派发。升级后有四条行为变化，
  接入方必须逐条对照：
  1. **不可省略的基础门开始覆盖 domain 写命令。** 此前它们完全跳过 `PatchbayGateEvaluator`。基础门恒定
     放行的接入方观察不到差异；基础门带条件（如「依赖未就绪时拒绝」）的接入方，会看到 domain 写命令在
     这些窗口内开始被拒。只读 domain 命令（`sideEffect: none`）逐字节不变，连基础门都不跑。
  2. **descriptor 的 `gates` 从展示字段变为强制字段。** 写命令声明的门按 gateId 字典序求值、首个拒绝即
     返回，与 `ui.*` / `navigation.*` 完全同一套语义；空 `gates` 表示「只跑基础门」。注意声明一个
     `consumerGate` 未接线的门等于拒绝而不是放行，迁移中途的半成品状态是 fail-closed 的。
  3. **审计事件 `gateResult` 对 domain 写命令从 `notEvaluated` 变为 `passed` / `rejected`。** 取值词表未
     扩展，只读命令仍为 `notEvaluated`。
  4. **声明了 `gates` 但 host 没有门求值器的组合会被拒绝**，答复是既有的 `consumerGateRejected` 加
     `details.reason: gateEvaluatorUnavailable`。这是一条本来就无法满足的声明，不新增稳定错误码。

  迁移：`package:patchbay_flutter` 的 host 自动复用 `PatchbayFlutterBridge` 已持有的门求值器，无需接线；
  直接使用 `package:patchbay` 的 host 传入新的可选具名参数 `PatchbayServiceHost(domainGates: ...)`。想让
  「只读默认开放、写入显式开放」落到 domain 面，给每条 `sideEffect != none` 的 descriptor 加上自己的写门
  ID 并在 `consumerGate` 中处置它即可；不迁移的接入方只会遇到上面第 1 条。

  拒绝形状复用既有 rejection 信封与退出码 `5`，wire、catalog / descriptor 稳定 JSON 与稳定错误码词表均未
  变化。门在 external requestId 去重与 replay 之前求值，因此重发一个已被受理过的 requestId 在门关闭后会
  拿到门拒绝而不是重放；此时 `details.priorRequestObserved` 为 `true`，提示该次写此前确已发生，不要换一个
  requestId 重试。门可以 `await`，等待期间若动态目录改写了该命令的 `gates` 或 `sideEffect`，答复是
  `providerProtocolViolation` 加 `details.reason: catalogGateDrift`，由调用方重发。

- 迁移提醒：`plane: domain` 的写命令（`sideEffect` 非 `none`）被 host 强制求值门拒绝时，
  `rejection.details` 携带的门标识键固定为 `gateId`（[domain-gate-enforcement](docs/proposals/0.5.0/domain-gate-enforcement.md)
  冻结的契约）。只读 domain 命令（`sideEffect: none`）host 不加闸；接入方若在自己的 adapter 里另行
  实现了同名门检查，其拒绝 `details` 的键形由该接入方自定，不受 host 约束——同一个 `rejection.code`
  在写/读命令上 `details` 形状可能不同。迁移中的接入方判断拒绝原因请按 `code` 分支，不要依赖
  `details` 的键名在读/写命令间保持一致。

- 会话记录的 `processStartTime` 改用带 scheme 前缀、与时区和 locale 无关的启动身份签名：Linux 直接读
  `/proc/<pid>/stat` 的 `starttime` 配 `/proc/sys/kernel/random/boot_id`（内核原值，不派生子进程），
  procfs 不可用时回退 `ps -o lstart=` 并把 `TZ=UTC` 与 `LC_ALL=C` 钉进子进程环境，Windows 先
  `ToUniversalTime()` 再按 `"o"` 格式化。此前签名是按**读取方**环境渲染的字符串，同一个活着的进程在
  不同 shell、cron、CI 容器或跨一次 DST 切换下读出的两个签名并不相等，会被判成 PID 复用，于是
  `patchbay` 删掉一条其实还活着的会话记录、后续命令一律退 `sessionStaleProcess`。签名比对同时收敛为
  三态：两侧 scheme 不同、或签名没有可识别的 scheme（0.5.0 开发期写下的记录属于此类），一律降级为
  `identityUnverified`，绝不判死；同一 scheme 下签名不等仍照旧判定为 PID 复用并清理记录。

### Fixed

- 修复 `doctor` 对孤儿 pin（已删除的固定会话）在 session 阶段误报通过的问题：直接在 session 阶段 fail-closed 并输出 `patchbay session use --clear` 的直接清理建议。（补记：该行为随 0.4.0 发布，因原碎片在 0.4.0 定版聚合后才创建、未被 release_prep 消费，当时的发布说明遗漏了这条记录，现补记。）

- 修复 Android 权限 `status` / `capabilities` 把「已声明但设备尚未物化运行时记录」误判为 `notDeclaredByApp` 的问题：`dumpsys package` 的 `runtime permissions:` 小节是懒物化的，权限声明过但从未被请求/授予/拒绝过时不会出现对应行，此前据此误判为「没声明」并连带在 capabilities preflight 里把 normalize/reset 的动作集收窄成只剩 `status`。现在改为先读 `requested permissions:` 小节判定声明，已声明无记录时 `status` 返回 `state: notDetermined`、新增的 `platformState: noRuntimeRecord`，`supportedActions` 恢复完整动作集。

- 修复 Android 权限 `status`/`normalize`/`reset` 把刚被授予、还没有任何标记的运行时权限误判为「无运行时记录」的问题：Android 在权限当前没有任何标记（USER_SET / USER_FIXED / ONE_TIME / REVOKE_WHEN_REQUESTED 等）时会整段省略 `dumpsys package` 里的 `, flags=[...]` 小节，而不是打印成 `flags=[]`；解析这段输出的正则此前把该小节写成必需，导致这类行永远匹配不上，`normalize granted` / `reset` 因此可能在权限已经生效之后仍误报 `permissionStateMismatch`。写后复核同时对读取新增有界指数退避重试（100ms 起，总窗口不超过 5 秒，计入既有单次写操作超时预算），不重发 grant/revoke，用于吸收更少见的设备侧最终一致性窗口；重试窗口内仍未观测到目标状态时，照旧如实报告 `permissionStateMismatch`，语义与响应信封形状不变。

- 修复没有 `procps` 的 Linux 主机上每条会话记录都被判死并删除的问题：存活判定此前把「`kill` 不在 `PATH` 上、根本没能启动探测工具」和「OS 回答说进程不在」压成同一个结论，而 Debian/Ubuntu `-slim`、distroless 和绝大多数语言基镜像（含 `dart:stable`）都不带 `procps`，`kill` 与 `ps` 都不是可执行文件，于是这些主机上任何 `--session-dir` 自动发现都退 `sessionStaleProcess`，记录被删，App 全程活着也连不上。现在存活判定区分「问到了，进程不在」与「根本没问到」：后者降级为 `identityUnverified`，与启动身份探测早已采用的策略一致，绝不因为探测工具缺失把活会话判死；Linux 上改为直接读 `/proc/<pid>` 作答，不再为此派生子进程，procfs 不可用或明显不属于本 PID namespace 时才回落 `kill`/`tasklist`。PID 复用仍照旧判死，明确的「进程不在」也仍照旧判死并清理记录。
  同时修正一条会绕圈的提示：被 pin 的会话连不上、且当前主机根本无法判断其进程是否存活时，不再建议 `patchbay sessions prune`——这种记录按设计判定为存活，prune 不会删它，照做等于白跑一次；改为说明原因，并指向 `patchbay session use --clear` 配显式 `--ws-uri <uri>`，或重新用 `patchbay launch` 启动。

- 会话启动身份签名的比对现在也校验载荷本身，而不只是它自称的 scheme：一条被截断或损坏的
  `processStartTime`（例如 `v2-linux:` 后面跟着的不是 `<boot_id>:<tick 数>`、`v2-posix:` 后面不是完整的
  `Www Mmm D HH:MM:SS YYYY`、`v2-win:` 后面少了小数秒或带的是本地时区偏移而不是 UTC）
  此前会与一条完好的探针比出「同 scheme、
  签名不等」，被判成 PID 复用，于是 `patchbay` 删掉一条 App 其实还活着的会话记录、后续命令一律退
  `sessionStaleProcess`。现在这类无法解读的签名与没有 scheme 的旧记录同等对待，降级为
  `identityUnverified` 并保留记录；两侧签名都合法且同属一个 scheme 时不等仍照旧判定为 PID 复用并清理。

- 修复 snapshot single-flight 在 provider 采样永不返回时把整个 App 的 snapshot 面拖死的问题：挂死的采样
  会被永久登记为「进行中」，此后 direct 与 VM Service 两侧所有 snapshot 读——完整读、路径选择、
  `fromRevision` diff 与带 `timeoutMs` 的 wait——都并入这条死采样并永不答复，连 wait 自己声明的
  `timeoutMs` 预算也被吞掉。现在**加入他人采样的调用者以自己的剩余预算为上限等待**，预算耗尽即按既有
  `snapshotWaitTimeout` 答复；这条采样既不取消也不摘除，因此持续挂死下 provider source 恰好被调用一次、
  不因任何调用者放弃等待而重开，晚到的答复仍照常提交恰好一次 revision，此后一切读恢复正常。发起采样的
  调用者与不带预算的纯读（完整读、路径选择、diff）行为不变，仍等自己的 source 读完、再由预算裁决那份
  答复是否还算数，源永不返回时依旧由传输层预算兜底。相应地，`snapshotWaitTimeout` 的 `details` 在一次
  轮询都没有完成时不再给出 `observed`（此时 `polls` 为 `0`），避免把「App 始终没有答复」写成「字段
  不存在」；既有能完成轮询的答复逐键不变。

- 修复 `--json repl` 在 transport、protocol 或 session 错误终止时输出多行 pretty JSON 的问题；终止答复现在保持为单个 LF 结尾的 compact JSON error envelope，便于按行消费者读取完整流。

- `--max-inline-bytes` 现在在命令执行前完成校验：非法值按用法错误退出且不再发出任何 RPC；`ui semantics tree` 的 usage 行与生成命令表同步宣告 `--output` / `--force` / `--max-inline-bytes` 三个已生效选项。

- 修复 `repl` 会话中本地落盘/下载失败会连带终止整个会话的问题：`ui semantics tree`/`ui widget-tree`/
  `ui render-tree`/`ui focus-tree` 的 PB-050-20 自动落 artifact 写入失败、或该行显式传了
  `--output`/`--force` 却写盘失败，现在与其它行内错误一样只报告并终止那一行，session 保持存活并继续
  消费后续行；`--json` 下该行的 `error` 携带与会话级终止错误一致的 `{code, details}` 形状。这也相应
  收窄了 `capture`/`blob get` 等既有 blob 下载命令在 repl 内的失败半径：以前它们的下载失败与连接失联
  一样终止整个会话，现在同样只终止那一行。

## 0.4.1 - 2026-08-24

0.4.1 是 0.4 系列的内部质量与架构解耦版本，全面完成 Core Host、Flutter Host、CLI 领域服务与大型测试套件的模块化分层治理，建立源码体积预算门禁（生产 ≤ 800 行、测试 ≤ 1000 行）、Pana 满分评分门禁与两阶段发布收尾自动化。

<!-- PUB_CHANGELOG:START -->
Patchbay 0.4.1 is an internal quality and architectural modularization release,
decoupling high-churn core host, Flutter host, and CLI subsystems into focused
domains while establishing strict structure ratchet budgets and release gates.

### Highlights

- Modularized core `ServiceHost`, Flutter semantics/gesture bridges, CLI runners,
  and large test suites into clean domain directories.
- Introduced automated structure ratchet enforcement (`tool/check_structure_ratchet.dart`)
  capping production files at 800 lines and test files at 1,000 lines.
- Extracted `PlatformProcessUtils` abstraction for unified cross-platform process
  detection across macOS, Linux, and Windows.
- Added reproducible Pana scoring budget verification and release finalize automation.
<!-- PUB_CHANGELOG:END -->

### Added

- 提取跨平台进程与底层系统调用抽象 `PlatformProcessUtils` 与 `ProcessRunner`，统一 macOS、Linux 和 Windows 平台上的 PID 探测与进程管理。

- 新增架构与测试单文件体积预算门禁 `tool/check_structure_ratchet.dart`，严格限制生产单文件 ≤ 800 行、测试单文件 ≤ 1000 行并消除手写 `part` 碎片与跨包私有依赖。

- 新增 pub.dev 评分预算门禁 `tool/check_pana_budget.dart`：对四个发布包实跑当期 pana，逐 section 要求满分，并支持 `--published` 核对 pub.dev Scores API 的 `grantedPoints == maxPoints`；取不到真实分数一律 fail-closed，不再以本地启发式代替评分。

- 新增两阶段发布收尾工具 `tool/release_finalize.dart`：计划分「已发布 / 仅缺证据 / 已延期」三档，欠真机验收证据的条目需显式 `--allow-evidence-pending` 且保留在 backlog 不归档，「实现中」条目必须逐条 `--defer-item` 点名才能延期。

- 新增公共 API surface 门禁 `tool/check_api_surface.dart` 与 golden `tool/api_surface.json`：按 `export` / `show` / `hide` / `part` 展开计算四包从入口可见的符号集合，任何新增或移除都判红。barrel 文本不变并不代表公共面不变，这道门禁看的是符号集合本身。

### Changed

- 建立源码结构规范 `docs/code-structure.md`：拆分依据是职责边界与依赖方向而非行数。结构门禁只对四类结构错误判红（手写 `part` 碎片、跨包 `src/` 私有导入、越出包根的相对导入、领域目录循环依赖），函数与文件体积改为不阻断的警戒线，并新增比文件长度更有信号的函数长度检查；检查范围扩展到 `tool/` 与 `example/`。

### Fixed

- 修复 `release_prep` 的文档阶段门禁假绿：定版前 README 提前宣称已发布到 pub.dev 现在会硬失败；受管文档改为只陈述可随 tag 固化的当前版本事实，不再要求尚未发生的发布结果。

- 修复 `patchbay` 包缺少 `analysis_options.yaml` 导致本地 `dart analyze` 与 pub.dev 评分口径脱节的问题：`patchbay` 与 `patchbay_transport` 现按 `package:lints/core.yaml` 分析，并修正两处触发 pana 扣分的流程控制写法，四包 pub.dev 静态分析恢复满分。

- 修复模块化拆分意外扩大公共 API 面的问题：拆分产物（gesture / semantics / trace / doctor / manifest / registry 等领域类型与内部 helper）不再随兼容 wrapper 整库导出，`PatchbayUiRegistry` 的内部注册与解析入口恢复为私有；同时补回被拆分挪走而从公共面消失的 `patchbaySnapshotSelectorUnsupportedCode`。四包公共符号集合与 0.4.0 完全一致。

## 0.4.0 - 2026-08-20

0.4.0 把调试闭环从“能调用”推进到“可观察、可确认、可复盘”：新增锚定手势、导航与 UI 等待、
执行证据分层、响应 schema、调试轨迹、截图差异、日志与性能画像，并补齐 launcher、会话恢复和
双传输兼容边界。平台权限本版按设备证据收窄为 Android adb 的 capability/status/normalize/reset/fail；
系统弹窗 exercise、iOS 权限自动化、网络画像和 HarmonyOS 可用性保持 fail-closed，不作超出证据的承诺。

<!-- PUB_CHANGELOG:START -->
Patchbay 0.4.0 completes the observable automation loop for running Dart and
Flutter applications while preserving explicit admission, lifecycle, and
generation boundaries.

### Highlights

- Added identifier-anchored press, drag, and fling gestures; navigation and UI
  waits; frame-aware capture and image diffs; snapshot revisions; bounded log
  and performance evidence; and durable, redacted debugging traces.
- Added generated command registration, strict request and response schemas,
  execution-evidence classifications, idempotent retries, and compatibility
  fixtures for 0.3 clients and hosts.
- Added supervised launcher sessions, Android permission state normalization,
  and an iOS XCUITest reference runner with fail-closed capability discovery.
- Expanded the example application and device precheck so protocol, CLI, host,
  direct transport, and Flutter bridge wiring are validated before consumer
  acceptance testing.
<!-- PUB_CHANGELOG:END -->

### Added

- 新增 identifier 锚定的 press-hold、drag 与 fling：使用必填 Semantics generation、目标内归一坐标、独立 gesture policy，并对遮挡与裁剪 fail-closed。

- 新增 `capture --after-frames` 与 `capture diff`：可在第 N 次 Patchbay 观测到的 Flutter 帧取证，并对同规格截图返回变化像素数和差异比例；结果明确资源上限与 Flutter 渲染层边界，不代替调用方判定 pass/fail。

- CLI 与 launcher 新增默认关闭、可显式覆盖的亮屏租约策略：仅在 live 或命令成功后续租，并在退出、失败和信号取消时尽力归还且明确报告无法确认的结果。

- 新增 `snapshotSelectors` host capability，并让 CLI 在发送 snapshot selector 或 wait 前按声明稳定降级，避免再从传输错误形态猜测旧 host。

- 外部命令可选择有界幂等重试、`requestId` 去重和脱敏 host 审计，并可通过 CLI `describe` 检查声明。

- 新增 `perf profile` 的 VM Service 有界性能摘要，稳定输出帧耗时、jank、heap 与 GC 计数；direct 明确返回 `profilingVmServiceRequired`，网络画像在无法采集前脱敏时返回 `networkProfilingUnavailable`。

- snapshot 新增会话内 `hostObserved` revision 与 `snapshot diff --from <revision>`；保留最近 32 个变化版本，基线淘汰或差异超限时返回稳定拒绝，老 host 明示降级为全量 snapshot。

- 新增 `patchbay launch -- <consumer command>` 有界监督与显式 pending session 声明契约；仅接管匹配 `launchId + ownerPid` 的记录，并在 App restart 后重新校验、重锚运行实例。

- `ui verify-manifest --navigate` 新增按清单顺序的有界逐屏巡检，输出部分完成与稳定失败证据，并支持显式继续和尽力恢复起始屏。

- `ui verify-manifest` 新增有界安全的 YAML 输入，与 JSON 归一到同一 manifest 模型，并按扩展名 fail-closed 选择格式及报告无内容泄漏的语法位置。

- manifest v2 新增独立的 `semanticsIdentifier` 命名空间，按既有活体 Semantics tree 核对挂载、歧义与 generation，并让草稿安全收录唯一 identifier。

- 新增 `ui targets --emit-manifest`，可从当前已稳定 destination 的活体 catalog 生成稳定的 v2 manifest 初稿，并以 `coverage: mountedOnly` 明示只覆盖当前挂载目标。

- 新增统一执行证据契约，稳定区分未发送、已发送未确认、同值无变化与设备已确认；descriptor 会约束确认预算和同值证据时效，host、job ledger 与 CLI 共同拒绝来源、终态或时间证据不一致的 payload，并保留 0.3 遗留降级路径。

- 新增逐命令 `responseSchema` 与 `schemaMode`；host 与 CLI 会复核受理 payload，绑定原始 `CommandRegistry` 的 job ledger 从 async dispatch scope 捕获 exact registration identity，并在落盘前复核、脱敏替换违规终态 payload；dispatch 外 adapter 必须显式使用 `startBoundToCommand`；CLI 等待 job 时再次复核，统一拒绝缺失、空值、错类型、未知变体及未声明字段；老 host 与未绑定 job 的 payload 保持原样并标记为 `legacyUnvalidated`。

- 新增 CLI 调试轨迹持久化：可记录 session、命令、job、执行证据、标记和 artifact，并安全查看、导出、比较与清理。

- 新增平台无关权限协议、显式外部 driver 发现与 fail-closed 的 `permission` CLI 基础闭环，所有 Dart/Flutter package 均不直接操作系统 UI。

- 增加 Android adb/UiAutomator 与 iOS simctl/XCUITest 外部权限 driver 源码适配、`permission reset`、`doctor permission`，并在系统弹窗处理后共享总预算完成 App resume、session 重连、catalog 刷新和目标代际重解析。

- 新增 HarmonyOS 兼容性六步验证报告、versioned capability schema 与 fail-closed fixture；example 仅作构建预检，接入方真机未验证项保持 `unsupported`。

- 仓内 example 现在覆盖 patchbay 的全部可注入面（语义动作、锚定手势、inspect、keep-awake、导航、
  capture/blob/logs、域命令与 job、执行证据四路径、responseSchema、幂等重试、审计、可选 direct 面），
  并新增 `tool/example_precheck.sh`：在一台真实 Android 设备上逐条打通 41 步命令面并给出每步退出码，
  作为业务验收前的必过预检。

- 本地 example 预检新增 Android 权限真实路径：逐权限 capability/status、`normalize granted`、幂等
  重放、不可达 denied 的无副作用拒绝，以及 `reset` 后状态复核；此前只能验证缺少 driver 时的
  fail-closed 答复。

- 新增会话声明器参考实现 `patchbay_cli/bin/patchbay_reference_launcher.dart`：在 `patchbay launch` 下
  先声明 pending 会话记录、取到 VM Service URI 后补传输，交由监督循环判定 live。权限写操作只接受
  `--session`，此前仓内没有任何可跑的载体；接入方也可照它实现自己的 launcher。

### Changed

- 统一协议自有命令的 descriptor、请求解码、门与 handler 注册源，确保目录和执行分发不再漂移。

- `navigation.*` 的 CLI 注册、参数绑定与帮助信息改由 core command descriptor 的非 wire `cliSyntax` 元数据生成，并新增生成物漂移门禁；既有命令路径、参数和退出码保持不变。

- UI 协议命令的 CLI 注册、参数解析与帮助改由 core descriptor 的非 wire `cliSyntax` 生成；Flutter host 同样直接组合 canonical descriptor，只覆盖运行时 gate 与策略默认值，并保留已公开 enum 常量作为兼容 façade。

- README 中英文命令参考改由协议 descriptor 与 CLI 显式声明统一生成，并在 GitLab / GitHub CI 中 fail-closed 检查漂移。

- `wire_codegen --write` 现在一次同步生成 Dart wire DTO 与协议面 golden；`--check` 对任一生成物
  缺失或漂移都会失败，协议测试不再提供独立的环境变量改写路径。

- `release_prep --apply` 现在会同步 `patchbayPackageVersion` 与中英文 README 的受管版本引用；`--check` 会阻止这些引用带着旧版本定版。

- `release_prep --apply` 现在会把本版 host 的实际协议面原子冻结为版本化兼容语料，RC 与正式版本均可重复生成，并由 `--check` 检出缺失或漂移。

- `release_prep` 判定「已发布版本的兼容语料」改用语料 README 里的机读标记 `patchbay:frozen-corpus`，
  并补上 0.3.0 语料缺失的声明：`--check` 不再把已发布协议面报成漂移，`--apply` 不会用当前 host 覆写
  它；新增仓内门禁，根 CHANGELOG 里已发布的版本若有语料目录而漏标记即失败。

- `command_codegen` 仓库门禁改为由最小真实 contract 生成 SHA-256 紧凑快照，不再长期保存仅供漂移检查的完整样例生成物。

- 发布协作入口改为内网主仓 MR；合入后将同一 `main` SHA 单向同步到 GitHub，避免双端重复合并。

- CHANGELOG 碎片改按目标版本隔离，`release_prep` 只消费指定版本队列并保留其他版本。

- CLI 仅在 payload 含类型化 `execution` 时才让执行证据覆盖遗留 `dispatched` 位；无执行证据的 `dispatched: false` 继续稳定返回失败，弱确认完成策略仅允许 job 命令声明。

- Android 权限能力矩阵改为逐权限逐 decision 的**设备探测**，不再由「配置了 runner 路径」推断：
  `exercise` 与 allow / deny / allowOnce 只在 runner 确实注册在该设备上时宣布，读写动作只对目标应用
  **声明过**的权限宣布，`allowOnce` 只给系统提供「仅这一次」的权限（相机 / 麦克风 / 位置，不含通知）。
  同时：应用未声明的权限现在返回可读状态 `unsupported` 与 `platformState: notDeclaredByApp`，而不是
  笼统的 `permissionUnsupported` 拒绝；`granted` 且带 `ONE_TIME` 标记的授权读回 `allowOnce`；
  `normalize --state denied` 在 Android 上按 `permissionStateUnreachable` **先拒绝再不动设备**，并指向
  `exercise --decision deny`——此前它会先撤销权限（连带被系统终止应用）再报状态不符。

- 设计红线收窄了管辖层级：原「系统权限弹窗不做」改为「四个 package 不直接操作系统 UI」。系统权限
  编排改由 CLI 通过版本化 driver protocol 调用外部 companion 完成，App 内代码仍不获得任何操作系统
  UI 的操作能力，release 构建仍不可达。装卸包与进程管理继续不做。本条只放宽设计边界，能力本身随
  `PB-040-25` / `PB-040-26` 实现后才可用。

- 收窄 0.4.0 权限能力的发布承诺：本版以真机证据验收 Android adb 的
  `capabilities/status/normalize/reset/fail`；系统权限弹窗 `exercise`、`allowOnce` decision、iOS
  `status/normalize/exercise`、Android/iOS reference runner 与权限专用 trace 事件延期。公共命令与 wire
  保留，但没有逐设备证据时 capability 必须保持 unavailable/unsupported，不能把源码 adapter、fake
  driver 或已配置路径表述成可用能力。

- HarmonyOS capability schema、fixture、文档与测试统一使用接入方中性命名（`consumerApp` /
  `consumerDeviceAcceptance`），不再出现任何业务接入方标识；识别性真机取证材料改为写入被 gitignore
  的 `.local/verification/`，仓内只保留中性结论与 capability 状态。

### Fixed

- CLI 校验 `unchanged` 执行证据时，改用 App 自己上报的 `observedAtMs` 作为计龄基准（缺失时才回退本机
  时钟），与 job 事件路径同口径：此前用工作站时钟比对设备产生的时间戳，设备时钟只要略快就会把一份合法
  证据报成 `providerProtocolViolation`，把时钟偏移归责成 App 违反协议。

- `ui.capture`（`capture root` 与注册目标）在 profile 构建下不再必然失败：绘制就绪判据此前无条件
  读取 debug-only 的 `RenderObject.debugNeedsPaint`，而 profile 与 release 会剥掉为它赋值的断言，读取
  即抛 `LateInitializationError`，并在 capture 给出类型化拒绝之前逃逸成 `transportError`。该判据现在
  只在 debug 生效；其余构建模式下未绘制的目标仍按 `captureEncodingFailed` 拒绝，不会静默产出空图。

- 修复轨迹里"保存老 host 自由 payload 值"这道确认闸的三处失真：`--allow-non-tty-legacy-payload`
  现在无论 stdin 被判成哪种形态都生效（此前它只在 `stdin.hasTerminal` 为假的分支里被读取，而 macOS
  把 `</dev/null` 判成 terminal，于是自动化里这个开关不可达）；把 `--include-legacy-payload` 用在本地
  `trace` 子命令上会按用法错误拒绝，不再静默接受一个不会生效的开关；交互提示读到输入末尾与
  "stdin 本来就不可交互"现在报各自的原因，不再共用一句消息。默认行为不变：不给显式开关时仍然只
  记录字段形状，不保存值。

- Android 权限状态答复的 `requiresRestart` 改为按当前状态推导，不再固定回 `false`：撤销一个**已授予**的
  运行时权限会让 Android 终止应用进程，因此 `granted` 状态下任何变更都需要重新拉起 App。此前该字段恒为
  `false`，监督循环无法区分「瞬时断连」与「进程已被系统终止」，只能在重连窗口里等到超时。

- 修复 iOS `permission capabilities` 把 Simulator 专用的 `reset` 能力误报给物理真机；显式设备不是
  booted Simulator 时现在 fail-closed 返回 `platformDeviceUnavailable`。

## 0.3.0 - 2026-08-17

发布批次：四包首次发到 pub.dev，随版依赖从 path 改成 hosted 约束——**仍用 git pin 的接入方
不能只改 tag 号**，两条迁移路径见本节 Changed 与[发版清单](docs/release-checklist.md)第 8 节。
功能面围绕「App 不配合时也问得出话来」：保持亮屏开关与 repl 的 lifecycle 横幅（息屏即 UI 面
全拒的解法）、snapshot 字段选择与领域条件等待、widget inspector 开关、体检命令 `doctor`、
会话粘性、UI 目标声明对账 `ui verify-manifest`。协议侧补齐演进套件（`serverVersion` /
feature capabilities / catalog digest / 跨版本兼容 golden），工程侧补上定版脚本 `release_prep`
与 tag 触发的 CLI 二进制发布流水线。含行为变更：`PatchbayDirectSnapshotSource` 的构造签名，
迁移说明见本节 Changed。

### Added

- **跨平台「保持亮屏」开关 `patchbay ui keep-awake on|off|status`（`ui.keepAwake.set` /
  `ui.keepAwake.status`）。** 设备中途息屏会把整个 UI 面带走：`ui.*` / `navigation.*` 全部开始回
  `*LifecycleNotResumed`，随后系统冻结进程、CLI 只看得到 `appUnresponsive`。Android 有不碰 App 的
  外部解法（`adb shell svc power stayon usb`），**iOS 真机没有**——这条命令是长时间手动联调 iOS
  真机时唯一能让设备别睡的杠杆。

  **默认关、显式开、会话断开自动还原。** 押住屏幕会改变被观察 App 的行为（息屏行为本身也是接入方
  要测的东西），所以没人开口就什么都不做。两种 transport 都不给 App 连接生命周期——VM Service
  扩展不知道 CLI 死没死，终端被杀也不会道别——所以每次开启都带一条租约（默认 10 分钟，上限 2 小时，
  `--lease-ms` 可显式给），到期由 App 自己释放：人还在就续租，人走了就不再续，**断开**和**租约到期**
  因此是同一件事。App 销毁 debug 面时也归还。`on` / `off` 是同一条协议命令的两种拼法，`enabled` 由
  敲的词决定而不是参数，`off` 不可能被多余的 flag 变成一次开启；`--lease-ms` 只属于 `on`。

  **`patchbay_flutter` 仍是纯 Flutter 包**：不转 plugin，也不引第三方 wakelock 依赖——那会改变每个
  接入方 release 构建链接的东西。碰平台的那一行由接入方在组合根注入
  `PatchbayFlutterBridge(keepAwakeDelegate: ...)`（Android `FLAG_KEEP_SCREEN_ON`、iOS
  `UIApplication.isIdleTimerDisabled`），框架只拿协议、记账和租约。**没接线时命令仍留在 catalog 里**
  ——与 `ui.capture` / `navigation.*` 的「没注入就不出现」相反，因为操作者伸手找它正是在屏幕刚黑、
  UI 面刚开始全拒的时候，此刻回 `commandNotRegistered` 等于什么都没说；改回 `keepAwakeNotWired`
  并点名缺的参数，`status` 用 `wired: false` 报同一件事。

  响应 `source` 恒为 `appRecorded`：它说的是 App 让宿主做了什么，Patchbay 不回读平台，绝不宣称
  屏幕确实亮着。delegate 抛异常是合法回答——开启时以 `keepAwakeDelegateFailed` 拒绝且不记成 hold；
  **释放失败时 hold 不落账、保持可重试**：平台没松手就把 `enabled` 记成 `false`，会让下一次 `off`
  变成 `unchanged` 空转、再也不碰平台，屏幕永久亮着且没有补救入口。所以记账只在 delegate 成功后
  才落，失败时 `enabled` 保持 `true`、`lastReleaseFailure` 带失败类型，再敲一次 `off` 会真的重试；
  租约也不撤，到期释放失败会在一个租约之后再试（没人在场时它是唯一会重试的东西）。
  后台 `on` 以 `keepAwakeLifecycleNotResumed` 拒绝并带 `lifecycleState`（iOS 在后台设
  `isIdleTimerDisabled` 无效，记下来等于记一件没发生的事），`off` 永远允许。debug 面销毁后 `set`
  以 `keepAwakeHostDisposed` 拒绝——`dispose()` 是同步的、无法排进请求队列，可能落在一次进行中的
  开启中间，此时尚无 hold 可归还，风险全在「挂起的请求随后把已销毁的宿主重新点亮」那一侧；
  gate 与 delegate 两个挂起点恢复后都重查销毁态，delegate 已经拿到 hold 的那种情况先归还再拒绝。
  `doctor` 的 lifecycle 解法在 iOS 一侧改为指向这条命令。接法与语义见
  [使用指南](docs/guide.md#5-保持亮屏可选不接线就没有这个能力)。

- **snapshot 的字段选择与领域条件等待：`snapshot --path <dot.path>` 与
  `snapshot wait <dot.path> --until exists|absent|equals [<json>]`。** 此前盯一个状态字段只能整树
  反复拉，每轮一次完整往返；现在选择在 App 侧完成，等待也在 App 侧完成（长轮询，间隔 100ms，
  第一次探测不等待，故条件已成立即刻返回）。响应新增 `selection: {path, found, value|miss}`，
  等待另带 `wait: {outcome, condition, timeoutMs, elapsedMs, pollIntervalMs, polls}`。取到的值
  **原样返回**（叶子或整棵子树），不重塑不汇总——会重塑的调试读没人能据以推理。

  **寻址根是 App 交出来的快照本身**，不是响应信封：协议自己盖的 `schemaVersion` 不可寻址，否则
  host 字段会冒充 App 状态。App 自己在快照里套的层级仍属路径的一部分——那是接入方的键，host 不
  替谁拆包（拆了平铺的接入方就全取不到）。路径第一段就不存在时，超时拒绝的 `details` 会带
  `availableKeys`（顶层键，排序），把「路径写错」与「字段还没来」分开。

  打到**不认识选择器的老 App** 时答稳定的 `snapshotSelectionUnsupportedByHost` 拒绝（退出码
  `5`），notice 给退路（整树 `snapshot`，或升级 App 侧 patchbay）；此前是裸 `transportError`
  （退出码 `3`），会把版本错配读成连接故障。

  **取不到不是失败，等不到才是。** `found: false` 退出码仍是 `0`，并带 `missingKey` /
  `nullValue` / `notAnObject` 说明原因——「字段还没来」与「这条路径与快照形状矛盾」是两种答案，
  合并会让写错的路径报成功，`--until absent` 同理不吃 `notAnObject`。等待超时以
  `snapshotWaitTimeout` 拒绝（退出码 `5`，与 `ui wait` 同口径），`details` 带最后一次解析结果。
  预算是**对答案的硬顶**：条件成立但拿到它的那次读取已越过预算时，答复仍是超时——超预算才拿到
  的成功，调用方已经不在等它了。快照回调本身慢过预算时，`details.elapsedMs` 会明显大于
  `timeoutMs`，这是「慢的是快照源」的读法。

  条件是**闭合词表**而非表达式语言：三条覆盖等待的全部用途，再多就是在 host 里塞进第二个没人
  测过的求值器。`equals` 按 **JSON 结构相等**比较，命令行上的比较值按 JSON 字面量读（字符串要
  写成 `'"ready"'`，裸词会被拒绝并把该加的引号写出来；`null` 不接受，那是 `absent` 的事）。
  等待预算 `--timeout-ms` 默认 5000、上限 2 分钟（`ui.wait` 家族同一上限），且会自动加进 CLI 的
  RPC 预算，不必另调 `--transport-timeout-ms`。

  **一律答复，不抛出。** 非法选择器答 `invalidSnapshotRequest`；App 的 snapshot 回调抛错答
  `providerProtocolViolation` + `details.reason: snapshotSourceFailed`，只带异常类型不带消息
  （consumer 的错误串是 App 数据，不跟着信封出去）。CLI 能先判的（路径语法、条件名、值形状）
  在本地就以用法错误 `64` 挡下，不发请求。

- 协议新增 `PatchbaySnapshotRequest` / `PatchbaySnapshotSelection` /
  `PatchbaySnapshotCondition` / `PatchbaySnapshotMiss` 与对应 wire 类型，
  `patchbaySnapshotWaitCeiling` / `patchbaySnapshotPollInterval` 两个常量，以及结构化 JSON 比较
  `patchbayJsonEquals`。`PatchbayServiceHost.dispatchSnapshot` 与
  `PatchbayFlutterServiceHost.dispatchSnapshot` 接受可选的原始 wire 请求；VM Service 侧新增
  `PatchbayServiceHost.snapshotRequestKey`（`request`，一个 JSON 编码的对象参数）。
  `PatchbayClient.snapshot` / `PatchbayDirectClient.snapshot` 增加可选具名参数。

- **widget inspector 开关 `patchbay ui inspect on|off|status`（DevTools 借用第一批）。** 用 CLI 开关
  Flutter 自带的设备端 widget inspector 选择模式，即 DevTools 上「圈一下看这块是什么 widget」那个。
  `on` / `off` 是同一条协议命令 `ui.inspect.select` 的两种拼法，`status` 是只读的
  `ui.inspect.status`。开着时点按被 inspector 吃掉、不再抵达 App，所以按 `sideEffect: appState`
  声明——这是改 App 状态，不是一次观察。

  **默认关，接入方显式 opt-in**：不注入 `PatchbayInspectPolicy` 时两条命令不进 catalog，调用得
  `commandNotRegistered`（与 `PatchbaySemanticsActionPolicy` 同一口径）。policy 声明的
  `defaultLease` 就是 catalog 里 `ttlMs` 的 `default`，`maxLease` 是请求带了也不许超过的上限。

  **每次启用带租约，到期自动还原。** 两条传输都是请求/响应，App 侧观察不到断连，所以「断开还原」
  在 App 侧只能表达成「静默还原」：租约走完没人续，桥把开关放回接手前的值；`dispose()` 同样还原。
  续租不会把 Patchbay 自己装上去的 `true` 当成新基线。还原是有条件的——只在开关仍是 Patchbay 装的
  那个值时回退，不掀 DevTools 期间别人拨的开关；显式 `off` 则照关不误。

  **非 debug 构建如实拒绝。** overlay 由 `WidgetsApp` 在一句 `assert` 里注入，只有 debug 成立；
  profile / release 下标志位写得进读得回却永不渲染。桥在动手前先判构建能力，命中即以
  `inspectorUnavailable` 拒绝（`details.reason` 为 `notDebugBuild` / `rootInspectorExcluded`），
  **不写标志位、也不问 consumer gate**。响应 `source` 恒为 `appRecorded`：写标志位只排了一次重建，
  不冒充「带 overlay 的那帧到过屏幕」。

  **销毁竞态同样拒绝**（`details.reason` 为 `hostDisposed`）：请求卡在 consumer gate 里等待时 host
  被销毁，gate 返回后不再继续开启——否则会留下一个开着的 inspector 和一个无人持有的租约，设备从此
  吞掉每一次点击。gate 恢复点重查 disposed，命中即拒绝且完全不碰 binding 标志位；销毁后再发的调用
  （含只读的 `status`）按同一 reason 拒绝。

  wire 新增 `PatchbayInspectSelectRequestWire` / `PatchbayInspectStateWire` 与
  `PatchbayInspectUnavailableWire` / `PatchbayInspectReleaseWire`；`patchbay_flutter` 公共 API 新增
  `PatchbayInspectPolicy` / `PatchbayInspectBridge` / `PatchbayInspectorSurface`（后者可注入，
  用于在不切构建模式的前提下测试拒绝路径）。perf VM RPC 与 net 画像是后两批，不在本次范围内。

- **体检命令 `patchbay doctor`。** 「连不上 / 没反应 / 命令全被拒」时一次把四件事按依赖顺序查完
  ——会话目录、连接与 identity 握手、catalog、App lifecycle——每项给「现象 → 可能原因 → 建议动作」。
  **它自己拨号**：拨不通正是它被问的那个问题，所以连接失败在它这里是一条 finding 而不是命令终止；
  前一项失败时后面标 `skipped`，会话目录判定失败时连拨都不拨。lifecycle 一项发一条只读 UI 探针
  （`ui.semantics.tree`，`maxDepth 0 / maxNodes 1`），未 resumed 时报出 `lifecycleState` 并给
  Android / iOS / 桌面三条解法。iOS 那条把「屏幕黑着」和「App 掉到后台」分开写：前者只能手动唤醒
  （没有系统级电源命令），后者在已配对且已解锁的设备上用
  `xcrun devicectl device process launch --device <udid> <bundle-id>` 就能拉回前台（真机实测）。
  repl 的 lifecycle 横幅与[使用指南](docs/guide.md#边界)同源同文。

  **退出码不另立**：取第一处 failed 检查项的类别（会话 / 连接 `3`、catalog `4`、lifecycle `5`），
  即「换成普通命令撞上这一项时会拿到的那个码」；只有 warning（会话不唯一、门未开、App 没注册任何
  命令）时是 `0`。`--json` 输出为 `{"doctor": {"verdict", "checks", "warnings"}}`，每条 check 带
  稳定的 `check` / `verdict` 与机读 `details`。doctor 只读：不改会话目录、不删记录、不重连。

- **活跃业务会话警示。** doctor 读一次 snapshot，扫各领域里为 `true` 的布尔 `active`（自顶层域起
  最多五层、最多报八条），命中就打出**路径原样**并劝阻 `force-stop` / `kill` / 卸载——真机上强杀
  正在通话或配网中的 App，代价远大于等它。这是结构化读法，CLI 不认识任何 consumer 的业务名词；
  接入方把布尔 `active` 放在会话对象上即可被认出（如 `snapshot.call.session.active`）。App 连不上
  或 snapshot 读不到时这条警示照样出，措辞换成「查不出，按不安全对待」——恰恰是那一刻最容易顺手
  强杀进程。

- **repl 会说出 App 未 resumed。** 息屏 / 后台 / 桌面失焦时每行 UI 命令都以 `*LifecycleNotResumed`
  被拒，仅凭 code 猜不出该干什么。会话在**第一条**这样的拒绝之后把分平台解法打到 stderr，一个会话
  只打一次（`--json` 的 stdout 仍只有命令结果）。提示是从 App 已经给出的拒绝里读的，会话**不为此
  额外发命令**：唯一受 lifecycle 闸管的只读命令会 `ensureSemantics()` 并催帧，等于替操作者改了被
  观测的 App；`doctor` 可以这么做（是点名要的体检），一条只是打开的会话不行。

- CLI 公共 API 增加 `PatchbayDoctorReport` / `PatchbayDoctorFinding` / `PatchbayDoctorWarning`、
  `runPatchbayDoctor` 与各项纯判定函数，以及 `dialPatchbayUnderBudget` / `closePatchbayQuietly`
  （原为 `cli.dart` 私有，doctor 要用同一套拨号与静默关闭，故上提到 `rpc_timeout.dart`）。

- **会话粘性：`patchbay sessions list|prune` 与 `patchbay session use <id>|--clear`。** 双设备并连
  （Android + iOS 同时跑）时会话不唯一，此前每条命令都要显式敲长 `--session <id>`。现在可以固定
  一条会话，之后不带 `--session` 的命令都用它。选择是三级优先级链，不混用：显式 `--session` 最高
  （且不改动固定项）→ 已固定的会话 → 唯一会话；三级都不成立时仍以 `sessionAmbiguous` 拒绝，并在
  候选清单后附一句「可用 `session use` 固定」。

  **固定项失效时 fail-closed，不回退。** 被固定的记录不见了、进程已死或连不上时，命令以自己的稳定
  code 失败（新增 `sessionSelectionStale`，另有既有的 `sessionStaleProcess` / `sessionUnreachable`）
  并附处置提示，**不会改用目录里另一条会话**——在双设备台上那意味着命令打到了另一台设备。CLI 也不
  自行清掉固定项：清掉等于让下一条命令重新开始猜。`sessions prune` 只在它删掉的记录正是被固定的
  那条时才顺带取消固定。

  这三条命令**不连 App、不读 catalog**，只读写本地会话目录（`--session-dir`），因此在「CLI 选不出
  会话」时照样可用；它们在 repl 内不可用（那条连接已经选定）。`sessions list` 的 `status` 是本地
  判定而非一次往返：`live` / `pending` / `stale`，列 N 台设备不会变成 N 次连接尝试。记录里的
  VM Service URI 带认证 token，列表只打印 `scheme://host:port`，路径一律不出，`--json` 的
  `endpoint` 字段同样已打码。

- `PatchbaySessionException.hint`：会话类错误可带一句处置提示，人读时跟在 stderr 的 code 之后，
  `--json` 时进 `details.hint`（与 `appUnresponsive` 的 hint 同一口径）。
- CLI 公共 API 增加 `PatchbaySessionStatus`、`PatchbaySessionListing`、`PatchbaySessionPruneResult`，
  以及 `PatchbaySessionStore.readSelection/writeSelection/clearSelection` 与
  `PatchbaySessionResolver.inventory/prune/select/selection`；启动器可据此自建会话面板。
- `session` ↔ `sessions` 互为别名拼写（`session list` 与 `sessions list` 等价）。别名只增加拼写，
  不新增命令，也不改任何既有命令名。
- 排版门禁：CI 的 `dart_packages` job 增加一步仓根 `dart format --output=none --set-exit-if-changed .`
  （GitLab 与 GitHub Actions 两边同步）。此前排版没有门禁，main 自身也不统一——87 个 Dart 文件里有
  17 个不合仓库 pin 的 dart_style（Dart 3.12.2）。同批已按该基准机械重排全仓，仅换行/缩进/尾逗号，
  无语义改动。门禁从仓根跑一次即覆盖四包与 example，`flutter_package` 内不重复。

- **`command_codegen` 进 `codegen_drift` 门禁。** 此前只有 `wire_codegen` 有零漂移检查，
  `command_codegen` 只被单测按临时 fixture 跑过——而它恰恰是接入方直接消费的那个生成器，
  输出漂移在本仓无人察觉，要等接入方升级 pin、重新生成、diff 炸开才暴露。现在仓内带一份样例
  contract 与其生成物（`packages/patchbay/contracts/example_commands.{json,g.dart}`），
  GitLab 与 GitHub 两边的 codegen job 都对它跑 `--check`，`dart test` 里也有同一条断言。
  样例本身是中性词表，不描述任何接入方的业务；它同时充当 command contract 唯一的可跑示例。

  **这条 `--check` 没有 cwd 约束**：`command_codegen` 生成物 header 记录的路径改为相对生成物
  自身，而不是调用者当时敲的那个字符串，所以从仓根还是包目录调用都得到同一份输出。
  `wire_codegen` 的老约束（必须从仓根调用，否则假漂移）未改动，两者的差异在 CI 注释、
  [协作约定](CONTRIBUTING.md)与[发版清单](docs/release-checklist.md)里写明。

- 周期性 Android emulator 冒烟（`.github/workflows/android-emulator-smoke.yml`，每周一 + 手动触发）：
  在真实 Android 上装起 example 并跑通 `identity` → `catalog` → `snapshot` / `ui semantics tree`
  的 CLI 往返。既有门禁全跑在 Ubuntu 上，覆盖不到「App 真的装进设备、VM Service 真的可连」这段；
  它不是 PR 必过项，失败只表示平台链路有信号要查。example 的 Android 工程由 CI 临时生成，仓内
  仍不带平台目录。

- **`patchbay ui verify-manifest <file>`：UI 目标「声明 ↔ 运行时挂载」对账。** 接入方把「这个 App
  应该开放哪些 UI 目标」写成一份 JSON manifest（`id` / `kind` / `sensitive` / `destination`），CLI
  连上运行中的 App 与 catalog 的 `uiTargets` 对一遍，报三类偏差：`declaredNotMounted`、
  `mountedNotDeclared`、`propertyMismatch`（逐字段给 `declared` / `runtime`）。**纯 CLI 侧比对：不新增
  wire 命令，App 侧零改动。** `kind` 的取值直接由 catalog 自己的 `PatchbayUiTargetKindWire` 解码，
  不另立一份会漂移的词表。

  **对账范围是当前挂载态**，所以「未挂载」如实报成「当前未挂载」（`runtime` 区分 `absent` 与
  `unmounted`），不替调用方判成缺失——非常驻控件不在当前屏本来就不该挂载。`destination` 在本版只做
  过滤：manifest 里出现它时 CLI 先读一次 `navigation.current`，只对账未 scope 和 scope 到当前屏的
  条目，其余计入 `stats.skippedOutOfScope`；逐屏自动巡检要驱动导航，不在本版内。同一 ID 同时挂载
  多个实例不算偏差，但会进 `notices`——桥对这种目标拒绝一切操作。

  人读输出直接列出偏差条目，`--json` 给三组数组 + `stats`。**新增退出码 `7`**：对账跑完且报告里有
  偏差，此时 App 侧每个请求都正常应答，因此既不是拒绝（`5`）也不是类型化失败（`6`）。manifest 读
  不了或不合法时 fail-closed 退到 `64`，稳定 code `manifestInvalid` / `manifestUnreadable`，
  `details.field` 指到具体位置（形如 `$.targets[2].kind`）；文件内容本身不进信封。

  **读文件在拨号之前。** manifest 是本地输入，写错与设备连不连得上无关，所以离线机器上写 manifest
  照样拿到文件本身的错，不会被 `sessionDirectoryEmpty` 之类的会话错盖过——那句话是真的，但说的
  不是作者此刻能改的那件事。repl 内不受影响：那条连接已经建好，这一行没有拨号可言。

  schema 与边界见[使用指南](docs/guide.md#ui-目标声明对账ui-verify-manifest)，示例文件
  [`docs/examples/ui-targets-manifest.json`](docs/examples/ui-targets-manifest.json)。

- **CLI 的 AOT 构建入口 `packages/patchbay_cli/tool/build_cli.dart`。** CLI 每条命令起一个进程，
  启动开销按条计费；`dart run` 每次都要做一遍 pub 新鲜度检查再 JIT 预热。AOT 产物两样都不付，
  同机同链路对同一个 example host 实测：启动 + 一次 `catalog` 往返由 `dart run bin/patchbay.dart`
  的 540 ms 降到 45 ms，纯 `--help` 由 463 ms 降到 21 ms（macOS arm64，各 8 次中位数）。产物落在
  已 gitignore 的 `packages/patchbay_cli/build/`，编一次约 1.6 秒、7 MiB，放上 PATH 即可任意目录
  直跑。脚本从脚本位置而非 cwd 解析路径，仓根与包内调用等价；新 clone 缺 package config 时自己
  先跑 `dart pub get`。

- **tag 触发的 CLI 二进制发布流水线 `.github/workflows/release.yml`。** `patchbay-v*` tag 推送后，
  在 macOS / Linux / Windows 三个 runner 上经同一个 `tool/build_cli.dart` 编出
  `macos-arm64` / `linux-x64` / `windows-x64` 产物，附 `checksums.txt` 挂到对应 GitHub Release；
  产物名带版本与平台后缀。产物自带运行时，**目标机器不需要 Dart SDK**。Release 已存在时只补
  产物不覆盖正文。首次真实运行在 `0.3.0` tag。

- **协议演进套件：`serverVersion` / feature capabilities / catalog digest / 跨版本兼容 golden。**
  CLI 与 host 分开部署（CLI 从终端装，host 跟着别人发布的 App 走），已有两个接入方 pin 在不同
  tag 上，「两端同版本」从来不是可依赖的前提。四件东西都是 `schemaVersion` 仍为 `1` 之内的
  **加字段**——identity / catalog 是客户端逐键读的松读面，老客户端忽略不认识的键——不是协议
  版本跳跃。设计取舍见 [design.md 协议演进](docs/design.md#协议演进)。

  - **`serverVersion`（identity）**：host 报出自己编译自的 `patchbay` 版本。Dart 运行时读不到
    自己的 `pubspec.yaml`，所以它是随包走的常量（`patchbayPackageVersion`），也因此成为发版时除
    四包 manifest 与两份 README 之外还要再改的一处；`release_version_parity_test.dart` 已把它钉死在
    四包版本上——常量漂移不是印错一份文档，是全网 App 谎报自己的构建。
  - **feature capabilities（identity `features`）**：host 声明自己支持的能力，客户端**按声明降级
    而不是猜**。`catalogDigest` 由协议层无条件声明，`lifecycleState` 由持有 lifecycle 门的 Flutter
    host 声明。**声明侧封闭、读取侧开放**：host 只能声明 `PatchbayFeature` 枚举里的名字，客户端把
    它当普通字符串读，遇到没见过的名字降级成「我不用它」而不是解码失败。缺这个键（老 host）与
    `[]`（声明为空）是两个答案，全链路不得抹平。
  - **`catalogDigest`（catalog）**：`commands` 的稳定摘要（sha256，对象键递归排序 + 条目排序），
    用于回答「App 声明的能力面变没变」。只覆盖 `commands`：`uiTargets` 是当前挂载态，导航一下就换
    一批，摘要跟着翻消费端只会学会忽略它。自带 `algorithm` / `covers`，读者被告知哈希的是哪一块
    而不是自己假设。协议自己写，consumer 目录里的同名键会被覆盖。读取端**容忍多出来的字段，但不
    容忍读不懂的条目**：`covers` 里混进本版读不懂的条目时整份覆盖按畸形处理、降级为不可复算，绝不
    把那一项丢掉后接着算——丢完剩下的可能恰好就是本版认得的覆盖面，那样「只读懂一部分」会被伪装成
    「全读懂了」，对着一个并非按此口径算出来的值说 `verified`。它降级成「验不了」而非「没有摘要」，
    否则上层会反过来报一条并不存在的能力失约。
  - **跨版本兼容 golden**：`patchbay_cli/test/protocol_compat_test.dart` 双向钉死——新 CLI 拿
    **手写冻结**的 v0.2.0 语料（缺上述全部字段）跑完整 doctor；老 CLI 的读法在用例里**复刻**后去读
    当前 host 真的吐出来的东西。`patchbay/test/protocol_surface_golden_test.dart` 另把「契约 wire 面」
    与「客户端正在严格解码哪些类型」一起钉成 golden：往松读面加字段安全，往生成的
    `XxxWire.fromJson` 解码面加字段会当场打断已发布的老 CLI，两者在源码里长得一模一样，golden 让
    它在 diff 里现形。

- **doctor 报出 host 版本、能力与摘要核验。** `connection` 一项打出 `serverVersion` 与 `features`
  ——CLI 与 host 版本错配解释掉的故障比其它任何一项都多；老 host 明说「不报自己的 patchbay 版本」，
  不留空让人猜。`catalog` 一项**自己复算**摘要再给 `catalogDigestCheck`（`verified` / `mismatched` /
  `unsupported`）：摘要要是消费方验不了，那就是个只能信的数字。算不动的报 `unsupported` 而不是
  `mismatched`——「我查不了」和「这是错的」是两个答案；覆盖面里有读不懂的条目时另附
  `catalogDigestCoversUnreadable`，说明同处打印的 `catalogDigestCovers` 只是能读懂的那部分、比 host
  声明的窄。`lifecycle` 一项新增 `lifecycleStateSource`
  （`hostReported` / `featureUndeclared` / `capabilityNotHonoured`），此前三种情况一律印
  `lifecycleState=unknown`，读起来像是关于设备的结论，而它只在中间那种情况下为真。host 声明了能力
  却不兑现，单列 `capabilityNotHonoured` 警告——要归档的 host bug，不是停止调试的理由，退出码仍是 `0`。

- **定版脚本 `release_prep`（`dart run packages/patchbay/bin/release_prep.dart`）。** 把定版四件套
  ——四包 `version` 一致 bump、根 CHANGELOG 落款、`example/pubspec.lock` 刷版本、兼容矩阵新行
  ——加上 pub 发布链的静态门，做成两个模式：`--check` 只读幂等、红绿即结论，`--apply` 只改文件、
  **不打 tag、不推送、不发布**，改完自动重跑判定并打印人工清单与按包间依赖推导出的发布顺序。

  硬检查是有来历的：`example/pubspec.lock` 是 `0.2.0` 定版漏刷的那一项，兼容矩阵行是 `0.2.1`
  打完 tag 忘了回填的那一项，两项都不降级成提示。pub 侧各项按实测定级——`dart pub publish
  --dry-run` **只要有一条 warning 就退 65**，所以缺 README / CHANGELOG / repository、
  description 不在 60–180 字符，一律按「挡发布」对待。发布开关 `publish_to: none` 单列一项，
  默认不动，只有显式 `--apply --enable-publish` 才删。

- **四包各留一份 `CHANGELOG.md` 与 `LICENSE`。** pub.dev 每个包页的 Changelog tab 读的是包内那份，
  仓根这份它看不到。包内 CHANGELOG 由 `release_prep --apply` 从本文件派生（已发布版本段原样拷贝，
  `Unreleased` 段不带过来），正文仍只在本文件维护一份，不要手改包内那份。

### Changed

- **`PatchbayDirectSnapshotSource` 改为接受一个可选位置参数**（`Future<Map<String, Object?>>
  Function([Map<String, Object?>? request])`），用于把 snapshot 选择器原样交给 App 侧。**自建
  direct host 的接入方要改这一处**：`snapshot: () async => …` 写成 `snapshot: ([_]) async => …`；
  不改则在此处编译失败，不会静默改变行为。`PatchbayDirectHost` 只校验选择器是不是 JSON 对象，
  不解释其内容——选择器的形状是协议包的规则，传输层再解一遍就是第二个可以与 VM Service 路径
  各说各话的解码器。snapshot 消息多出的 `request` 是唯一可选键，其余未知键照旧 fail-closed。

- **`0.3.0` 起四包发布到 pub.dev（`0.x` 语义：`^0.3.0` 接纳 `0.3.x`，不跨 minor）。** 为此四包
  互相之间的 path 依赖改成 hosted 约束（`patchbay_flutter` 依赖 `patchbay: ^0.x.y`），仓内解析
  靠随包提交的 `pubspec_overrides.yaml` 落到工作树——两处一致由 `release_prep` 的
  `internal-dep-constraints` / `local-overrides` 兜住，`pubspec_overrides.yaml` 因此从
  `.gitignore` 里放了出来（它不会进发布包）。

  **对仍用 git pin 的接入方是破坏性变化**：pub 不允许同一个包在一次解析里既来自 git 又来自
  hosted，所以「四包全用 git ref pin」在 `0.3.0` 上会直接版本求解失败。两条路二选一——整体改用
  pub.dev 版本，或在自己仓的**根** pubspec 加 `dependency_overrides` 把四包统一指回同一 git ref。
  口径见 [docs/release-checklist.md](docs/release-checklist.md) 第 8 节。

- **安装文档改按形态组织（`docs/guide.md` 安装节）。** 原来只给一条 `dart pub global activate`
  命令，漏掉了两件每个新用户都会踩的事：`$HOME/.pub-cache/bin` 默认不在 PATH 上（装完了
  `patchbay` 找不到）；以及在**接入方仓目录**里 `dart run patchbay_cli:patchbay` 按当前目录所属
  的包解析，拿到的是该仓 pin 的那个 tag 而不是手上的 CLI——表现为新命令「不存在」的用法错误
  （退出码 `64`），容易被误读成 CLI 有 bug。现在三种形态（Release 二进制 / `pub global activate` /
  仓内 `dart run`）带耗时对比与适用场景并列，坑单独成块。

  同时记入：`dart pub global activate --source path` 每次调用都重新解析依赖，pub 把
  `Resolving dependencies…` 打在 **stdout** 上，破坏「`--json` 时 stdout 只有一个 JSON 文档」
  的约定，下游解析器会失败——需要工作树即时生效又要读 `--json` 时，用 AOT 产物或仓内
  `dart run`，不要用 path 模式。

- **退出码一节写明判定口径（`docs/guide.md` 退出码）。** 原来只有一句「脚本应同时读 JSON 信封」，
  没点出最容易把失败读成成功的那个写法：`patchbay --json … | jq …` 之后的 `$?` 是 `jq` 的码，
  patchbay 判红也照样是 `0`。现在明确：脚本与 agent 判定结果读 `--json` 的结构化字段或 patchbay
  自己的退出码；确实要在管道里拿真码，用 `set -o pipefail`（或 bash 的 `${PIPESTATUS[0]}`），
  否则先把输出接到变量再解析。

### Fixed

- README 的项目状态与安装 tag 跟上四包 `0.2.1`，并新增版本一致性测试，后续四包 version、README
  状态或两处 Git ref 任一漏改都会在 CI 判红；同时澄清 `PatchbayKey` 必须缓存、release 组合边界与
  generation 围栏适用范围，架构图补双向请求/响应和 direct loopback 边界。
- `patchbay help <group>` 的可用性说明改为按组内各命令推导，不再对每个组一律打印「Availability is
  still decided by the running App catalog」。`ui` 组因此同时说明 SDK passthrough 那一半，`sessions`
  组说明它根本不需要 App。

## 0.2.1 - 2026-08-14

诊断完备性批次：等待 App 的路径全部有超时预算并可诊断，拒绝信封不再有空 `details`；
文档按开源仓标准整治。含行为变更：`--transport-timeout-ms` 默认 60s→30s 且两传输通用，
迁移说明见本节 Changed。

### Changed

- CLI `--transport-timeout-ms` 从「仅 direct 传输的 socket 预算、其他路径静默忽略」改为**两条传输
  通用的单次 RPC 预算**，默认 `60000` → `30000`；连接握手（会话发现 + identity）也纳入预算。
  它与 `--timeout-ms` 是两个量，不要混用：后者是请求 App 自己等多久（`ui wait`、`logs tail`、
  `navigation go|push|back`、`capture`），仍随请求发到 App 侧。**声明了等待预算的请求，其 RPC 预算
  自动放宽成「声明的等待 + 一次往返」**，所以 `ui wait --timeout-ms 120000` 与 `--wait` 的 job 长轮询
  都不会被默认预算腰斩。

  **迁移：** 依赖旧的 60 秒 direct 预算、或依赖「VM Service 路径永不超时」的脚本，需要显式传
  `--transport-timeout-ms`。direct 传输原先的 `timeout` 错误码统一成 `appUnresponsive`（见下）。

### Fixed

- **CLI 等待 App 应答的路径原先没有超时预算**（VM Service 路径完全没有，direct 只有自己那份）。
  Android 真机实测：息屏后系统冻结 App 进程，对端停止应答，CLI 要等底层 socket 自己死掉（>120 秒）
  才以裸 `HttpException` 收场，看上去与「卡住」无法区分。现在每次 RPC 往返都有预算（见上），
  耗尽时以退出码 `3` 和稳定 code `appUnresponsive` 失败，并附一句处置提示（冻结 / 息屏 / 挂起 →
  亮屏解锁或检查进程；`--json` 时在 `details.hint`）。direct 传输自己的 `timeout` 码归一到同一个
  `appUnresponsive`，脚本对「对端不应答」只需认一个码。

  一条命令对不应答的对端只花**一个**预算，不按 RPC 段数叠加：第一次没等到应答就结束整条命令，
  后面的往返不会发出。对端**已死**（端口无人监听）走另一条路——内核立刻拒绝，毫秒级以
  `transportError` 失败，不等预算。
- **CLI 进程在判决作出后仍可能挂住。** 预算判完、`appUnresponsive` 也打印了，进程却不退出：被放弃的
  VM Service WebSocket 握手仍注册在事件循环上，`main` 返回后 VM 会一直等它，而冻结对端的握手永远
  不会完成、也无法从调用方取消。Android 真机实测 **178 秒**（30 秒预算早已判完并打印），直到系统把
  App 杀掉、TCP 断开才结束。现在 `bin/patchbay.dart` 在命令结果产出后冲刷 stdio 并显式 `exit(code)`
  ——判决即结果，进程随之结束；命令要落盘的东西（artifact、stdout 响应）在 `runPatchbayCli` 返回前
  都已 await 完成。同时 `runPatchbayCli` 不再遗留被放弃的连接（迟到成功的拨号会被关掉），连接释放
  本身也有上界，不会成为新的挂起点。同一场景复测：178s → **30.5s**（30s 预算 + 进程启动）。
- CLI `catalogInvocationDrift` 不再吞掉 host 已经给出的目录违规原因。host 目录违规时会在 invoke
  应答的 `rejection.details.catalog` 里说明哪条命令名非法或重名，CLI 原先只抛一个裸码，操作者还得
  再跑一次 `patchbay catalog` 才能知道刚才那次应答已经说过的话。现在原样透传到错误信封的
  `details.catalog`，并附 `details.command` / `rejection` / `reason`；invoke 未重复时回退到 catalog
  读到的那份。
- `invalidUiArguments` 不再是裸码。九处 UI 参数校验路径的 `details` 现在指名：`missing`（声明为
  必填却缺席）、`unexpected`（命令未声明的键，只在真正执行白名单的调用点计算）、`invalid`（类型或
  枚举取值不符），全部从 host 已经在发布的 descriptor 推导，不是另抄一份命令形状。`ui.wait` 的
  条件相关形状规则（`semanticsValue` 要有 `value`、revision 等待不许带 identifier）不是任何单个键
  能表达的，额外由 `details.reason` 承载。**只走参数名等协议词汇，调用方的值不进信封。**
- 同一类的三个越界拒绝也补上 details：`invalidCaptureArguments`、`invalidNavigationArguments` 与
  `invalidUiTreeLimits` 现在以 `details.invalid` 指名越界的是哪个参数，前两个还附上被越过的上界
  （`maxTimeoutMs` / `maxPixelRatio`）。此前一个合理但超限的数字被拒时，调用方既不知道是哪个参数
  也不知道界在哪。
- `uiLifecycleNotResumed` / `uiWaitLifecycleNotResumed` / `navigationLifecycleNotResumed` /
  `captureLifecycleNotResumed` 带上 `details.lifecycleState`。此前四个码都不带 details，操作者只知道
  闸关了，分不清设备睡了、窗口只是失焦、还是 App 正在退出——而三种的处置完全不同。

### Added

- `PatchbayLifecycleStateReader` 与 `patchbayLifecycleReaderFor` / `patchbayLifecycleDetails`：
  生命周期状态的**诊断接缝**，判定权仍在 `isAppResumed`。`PatchbayFlutterBridge` 及四个桥新增可选
  `lifecycleState` 参数；不传时 reader 跟随判定接缝——默认判定读 binding，被覆写的判定如实报
  `unknown`，避免出现「拒绝说没 resumed、details 说 resumed」的自相矛盾信封。既有接入方不受影响。
- `patchbay_cli` 导出 `patchbayDefaultRpcTimeout` / `patchbayRpcBudget` / `awaitPatchbayRpc` /
  `PatchbayTimeoutClient` / `patchbayAppUnresponsiveCode` / `patchbayAppUnresponsiveHint`；
  `PatchbayProtocolException` 增加 `details`，由错误信封原样输出。

## 0.2.0 - 2026-08-14

四包同步定版（tag `patchbay-v0.2.0`）。含协议正确性批次、repl 会话与 `ui tap` 直达、
Job 资源控制、`inputWasStdin` 框架层收编、CLI 契约六项与 catalog 校验失败结构化上报；
双 consumer 验证（Android 真机 + macOS/iOS E2E）。升级前必读本节各迁移说明
（命令名 kebab 禁用、手写 adapter 两步迁移）。

### Changed

- 命令名语法收紧为 `^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$`：每段以小写字母开头，段内只允许
  字母和数字，**段内连字符不再合法**。canonical 命令名是这道校验的目的，不放宽。

  **迁移：升级 pin 前先扫一遍自己 descriptor 的 `name`。** kebab 段名（如 `auth.switch-tenant`）
  改写成点分段（如 `auth.tenant.switch`）。改名是破坏性的：CLI 调用、脚本和文档要同步改，旧名
  调用会得到 `commandNotRegistered`。catalog 里只要有一条非法名，**整个目录**就不可用（见下），
  不是只跳过那一条。

- CLI `--stdin` 与 `--args` 由「整体替换」改为「合并，stdin 覆盖同名键」。原先「stdin 提供全量
  参数」的用法成为 `--args` 缺席时的退化情形，行为不变；stdin 内容仍必须是 JSON object。
  同时新增 fail-closed：catalog 声明 `sensitive: true` 的参数若出现在 `--args`，CLI 直接以退出码
  `64` 拒发，不再依赖 App 侧兜底，错误信息不回显值。
- CLI `--json` 时一切错误也输出到 stdout 的稳定 JSON 错误信封
  `{"error":{"code":...,"details":{...}}}`，字段与 rejection 信封同形；人读文本仍只走 stderr。
  无 `--json` 行为不变。
- CLI `navigation go|push|back` 省略 `--revision` 时自动先读 `navigation.current` 再派发，结果带
  `revisionSource`。revision 围栏本身不变，读到与派发之间导航动过仍被 App 拒绝；显式
  `--revision` 行为不变。
- CLI `patchbay help <topic>` 接受 catalog 协议名（`navigation.go`、`ui.semantics.tap`、`ui.wait`）
  与别名拼写（`navigate` / `nav` / `wait` / `tap` / `text` / `semantics`、`ui wait <condition>`）。
  别名只增加拼写，不新增命令，也不改任何既有命令名或 condition 名。
- `PatchbayArtifactDownloader.chunkBytes` 由静态常量改为实例字段（常量更名
  `defaultChunkBytes`）；CLI 按 catalog 中 `blob.read` 的 `limit` 默认值与之取小。
- `inputWasStdin` 由框架层收编。host 在把 arguments 交给 consumer 之前按 descriptor 的
  `sensitive` 声明完成校验（任一 sensitive 参数带非空值却缺少该标记时，以
  `sensitiveInputRequiresStdin` 拒绝，`details.parameters` 列出违规参数名），随后把这个元键剥掉：
  `domainInvoke` 收到的 arguments 永远不含它。`plane: flutterUi` 的命令例外——其敏感性是目标级
  而非参数级，元键仍交给 `patchbay_flutter` 的 bridge。command codegen 同步不再豁免、也不再校验
  该键。catalog 是这条策略的唯一真源，读不到时带参调用 fail-closed
  （`providerProtocolViolation` / `catalogUnavailable`）。

  **迁移：手写 adapter 升级 pin 后必做两步。**① 删掉 arguments 白名单里对 `inputWasStdin` 的
  豁免（**不删无害**，只是死代码）；② 删掉 adapter 自实现的 stdin 强制检查（**不删必炸**——host
  剥键后该判断恒为假，所有合法的敏感调用都会被 App 侧误拒）。规范表述：host 已接管
  sensitivePolicy 校验，手写 invoke 不得再依赖 `inputWasStdin` 键。用 codegen 的接入方升级 pin
  后重新生成即可；停留在旧 pin 的接入方不受影响，旧 host 与旧生成代码在旧语义下自洽。

### Fixed

- CLI `--wait` 的终态结果在响应顶层回填 `jobId`，与受理信封口径一致；`payload.jobId` 保留为 App
  job snapshot 字段。人读摘要对终态 job 输出 `jobId=… terminal=true phase=…`，不再吞掉 outcome。
- CLI 下载 artifact 时不再写死 64 KiB 分块：host 把 `maxChunkBytes` 调小于该值时，原先每个
  `blob.read` 都会被 `blobInvalidChunkLimit` 拒绝，下载完全不可用。
- `blob.read` 的 `limit` 与 descriptor 对齐：wire 允许缺省，host 补上 catalog 声明的同一个默认值
  （`PatchbayMemoryBlobStore.maxChunkBytes`）。此前 descriptor 标了默认值但 wire 必填，声明与实际
  不符。
- `schemaVersion` 改为 host 保留字段，consumer catalog / snapshot 回调不能覆盖。
- catalog 校验失败不再是未处理异常，改为结构化协议错误。此前非法命名 / 重名 / 缺名会让
  `handleCatalog` 抛 `StateError`；异常在 VM Service 和 direct HTTP 上都变不成回复，调用方表现为
  **无限挂起**，连带拖住依赖 catalog 的路径（CLI `exec` 的命令解析先读 catalog）。现在整个 catalog
  调用返回拒绝信封：`admission: rejected` + `rejection.code = providerProtocolViolation`，
  `details.reason` 取 `invalidCatalogCommands` / `commandsNotAnArray` / `catalogSourceFailed`。
  `invalidCatalogCommands` 的 `details.violations` 逐条给出 `index`、`name` 和 `reason`
  （`invalidCommandName` / `duplicateCommandName` / `missingCommandName`；没有可回显的名字时只给
  `index`），并附 `details.commandNamePattern`；三类一次全报，不是报完第一条就停。命令名是协议
  词汇不是接入方数据，直接指名。违规目录**不带 `commands` 字段**——静默跳过坏条目等于把接入方的
  bug 藏成「App 少了个能力」。带参数的 `invoke` 同样 fail-closed（`providerProtocolViolation` /
  `catalogUnavailable`），`details.catalog` 带上目录本身的违规原因。接入方 catalog 回调自己抛异常
  时走同一条路（`reason: catalogSourceFailed`，`details.error` 只给异常类型名，不回显消息）。
- host 严格验证 invocation wire、协议版本和 `requestId`；provider 返回非法信封时转换为
  `providerProtocolViolation`，不把不相关响应交给调用方。
- VM Service 与 direct 两条路径都拒绝空 `requestId`；invocation 同时校验 admission、rejection、payload
  与 jobId 的条件不变量。
- Flutter text / Semantics operator 沿用调用方 `requestId`，VM Service 与 direct client 同时验证响应相关性。
- `retainedJobs` 按已结束任务计数，并在任务进入终态时立即执行淘汰。
- `cancelAll()` 并行发起全部运行中 job 的取消：每个回调各自受 `cancellationTimeout` 约束，一个卡死或
  抛错的回调不再阻塞后续 job，也不再中断整批取消。

### Added

- `ui.semantics.tap`：按稳定 Semantics identifier 一步完成解析、代际校验与派发，取代
  `ui.semantics.tree` + `ui.semantics.action` 两跳；CLI 侧为 `patchbay ui tap <identifier>`，
  `--generation` 可选。解析出的 generation 在过门前 pin 住，门后二次解析必须命中同一 generation；
  未命中、多义与代际过期都是带 details 的稳定拒绝。与 `ui.semantics.action` 共用 action policy，
  没有 consumer policy 时不进 catalog、不可派发。
- `patchbay repl`：一次连接内从 stdin 逐行执行 typed 命令，语法与一次性调用相同。每行结果自带
  `exitCode`，会话退出码只描述会话本身。连接类参数、`--json` 与 `--stdin` 在会话内逐行 fail-closed；
  direct HTTP 传输不支持 repl（bearer token 会与命令流共用 stdin）。
- `runPatchbayCli` 增加 `connect` / `replInput` / `output` / `errorOutput` 测试接缝参数；新增公共
  `PatchbayReplSession`、`tokenizePatchbayReplLine` 与 `patchbayResponseSummary`。
- `PatchbayJobRegistry.maxRunningJobs`，默认 `32`；达到上限时同步抛出
  `PatchbayJobCapacityExceeded`，任务 body 不会启动。
- `PatchbayJobRegistry.cancellationTimeout`，默认 `5s`；取消回调超时会保留 running 状态，
  不谎报底层操作已经停止。
- 没有 cancellation callback 的 job 不再被标记为 cancelled；`cancel()` 返回 `false` 并保留 running。
- Job registry 提供 `runningJobs`、`settledJobs` 和 `totalJobs` 只读计数。
- `PatchbayJobCancelOutcome`；`cancelAll()` 改为返回逐 job 结果（`cancelled` / `notCancellable` /
  `timedOut` / `callbackFailed` / `alreadySettled`），不用单个结论概括全批，超时、抛错和无回调的 job
  仍如实保持 running。
