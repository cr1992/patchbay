# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## Unreleased

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

### Changed

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
