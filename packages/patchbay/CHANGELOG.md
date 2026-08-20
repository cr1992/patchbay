# Changelog

四个包随同一个 tag 定版，变更正文只在仓库根 [CHANGELOG.md][root] 维护一份。本文件由
`release_prep --apply` 从根表派生（已发布版本段原样拷贝，`Unreleased` 段不带过来），
供 pub.dev 的 Changelog tab 展示；**不要手改，改根表后重跑 apply**。

[root]: https://github.com/cr1992/patchbay/blob/main/CHANGELOG.md

## 0.4.0 - 2026-08-20

0.4.0 把调试闭环从“能调用”推进到“可观察、可确认、可复盘”：新增锚定手势、导航与 UI 等待、
执行证据分层、响应 schema、调试轨迹、截图差异、日志与性能画像，并补齐 launcher、会话恢复和
双传输兼容边界。平台权限本版按设备证据收窄为 Android adb 的 capability/status/normalize/reset/fail；
系统弹窗 exercise、iOS 权限自动化、网络画像和 HarmonyOS 可用性保持 fail-closed，不作超出证据的承诺。

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
不能只改 tag 号**，两条迁移路径见本节 Changed 与[发版清单](https://github.com/cr1992/patchbay/blob/main/docs/release-checklist.md)第 8 节。
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
  [使用指南](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#5-保持亮屏可选不接线就没有这个能力)。

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
  repl 的 lifecycle 横幅与[使用指南](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#边界)同源同文。

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
  [协作约定](https://github.com/cr1992/patchbay/blob/main/CONTRIBUTING.md)与[发版清单](https://github.com/cr1992/patchbay/blob/main/docs/release-checklist.md)里写明。

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

  schema 与边界见[使用指南](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#ui-目标声明对账ui-verify-manifest)，示例文件
  [`docs/examples/ui-targets-manifest.json`](https://github.com/cr1992/patchbay/blob/main/docs/examples/ui-targets-manifest.json)。

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
  版本跳跃。设计取舍见 [design.md 协议演进](https://github.com/cr1992/patchbay/blob/main/docs/design.md#协议演进)。

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
  口径见 [docs/release-checklist.md](https://github.com/cr1992/patchbay/blob/main/docs/release-checklist.md) 第 8 节。

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
