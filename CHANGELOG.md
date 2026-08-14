# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## Unreleased

诊断完备性批次：等待 App 的路径全部有超时预算并可诊断，拒绝信封不再有空 `details`。

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
