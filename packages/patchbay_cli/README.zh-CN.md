# Patchbay CLI

[English](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_cli/README.md) | 简体中文

`patchbay_cli` 是 Patchbay 的 consumer-neutral 命令行客户端。它连接运行中的 Dart/Flutter App，
根据 App 实际返回的 catalog 调用命令，不依赖 consumer 代码，也不维护业务命令副本。

协议、生命周期和传输边界见 [`../patchbay/README.zh-CN.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay/README.zh-CN.md)，Flutter UI 控制面见
[`../patchbay_flutter/README.zh-CN.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/README.zh-CN.md)。

## 安装与运行

从 pub.dev 安装 CLI，并与 App 侧使用的版本保持一致：

```console
$ dart pub global activate patchbay_cli 0.4.1
$ export PATH="$PATH":"$HOME/.pub-cache/bin"   # 装进这里，但它默认不在 PATH 上
$ patchbay --help
```

三种安装形态的取舍（含 Release 预编译二进制、启动耗时对比，以及「在接入方仓目录里
`dart run patchbay_cli:patchbay` 会解析到该仓 pin 的版本」这个坑）见
[使用指南的安装节](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#安装)。改 CLI 本身时，`dart run tool/build_cli.dart`
把当前工作树编成 AOT 可执行文件，产物落在 `build/`。

以下示例统一写 `dart run bin/patchbay.dart`（包内开发姿势）；全局安装后可等价替换为 `patchbay`。

## 命令速查

查看帮助不会发现会话、连接 App 或读取 bearer/敏感 stdin：

```text
dart run bin/patchbay.dart --help
dart run bin/patchbay.dart help
dart run bin/patchbay.dart help navigation
dart run bin/patchbay.dart help job
dart run bin/patchbay.dart help ui
dart run bin/patchbay.dart logs --help
dart run bin/patchbay.dart ui widget-tree --help
dart run bin/patchbay.dart help navigation.go     # catalog 里的协议名也是 topic
dart run bin/patchbay.dart help ui.wait           # 多个命令共用一个协议名时列出它们
dart run bin/patchbay.dart help navigate          # 别名拼写，展开到既有路径
```

help topic 接受三种写法：CLI 路径（`ui wait`）、catalog 协议名（`navigation.go`、
`ui.semantics.tap`）、以及别名（`navigate` / `nav` / `wait` / `tap` / `text` / `semantics`，以及
`ui wait <condition>` 形式的 condition 名）。别名只是既有声明的另一种拼写，不新增命令，也不改任何
稳定名；没有任何声明发送的协议名仍是 `unknown help topic`。

<!-- PATCHBAY_COMMAND_REFERENCE:START -->
下表只描述当前 CLI 随包发布的语法。协议命令行来自仓内 descriptor；client / local 行仍来自 CLI 的显式声明。它不是运行时 capability catalog，实际可用性请以 `patchbay catalog` 为准。

| CLI 语法 | 声明来源 | 协议命令 |
|---|---|---|
| `patchbay blob get <blob-id> --output <path>` | client 显式声明 | `blob.metadata` |
| `patchbay blob metadata <blob-id>` | client 显式声明 | `blob.metadata` |
| `patchbay capture diff <before-blob-id> <after-blob-id>` | client 显式声明 | `ui.capture.diff` |
| `patchbay capture root --output <path>` | 协议 descriptor | `ui.capture` |
| `patchbay capture target <target-id> <generation> --output <path>` | 协议 descriptor | `ui.capture` |
| `patchbay catalog` | client 显式声明 | — |
| `patchbay describe <service-command>` | local 显式声明 | — |
| `patchbay doctor` | local 显式声明 | — |
| `patchbay doctor permission` | local 显式声明 | — |
| `patchbay exec <service-command>` | client 显式声明 | — |
| `patchbay identity` | client 显式声明 | — |
| `patchbay job cancel <job-id>` | client 显式声明 | `patchbay.job.cancel` |
| `patchbay job get <job-id>` | client 显式声明 | `patchbay.job.get` |
| `patchbay launch -- <consumer command>` | local 显式声明 | — |
| `patchbay logs export --output <path>` | client 显式声明 | `logs.export` |
| `patchbay logs query` | client 显式声明 | `logs.query` |
| `patchbay logs tail` | client 显式声明 | `logs.tail` |
| `patchbay navigation back [--revision <revision>]` | 协议 descriptor | `navigation.back` |
| `patchbay navigation catalog` | 协议 descriptor | `navigation.catalog` |
| `patchbay navigation current` | 协议 descriptor | `navigation.current` |
| `patchbay navigation go <destination-id> [--revision <revision>]` | 协议 descriptor | `navigation.go` |
| `patchbay navigation push <destination-id> [--revision <revision>]` | 协议 descriptor | `navigation.push` |
| `patchbay net profile` | client 显式声明 | — |
| `patchbay perf profile [--duration-ms <ms>] [--sample-limit <events>]` | client 显式声明 | — |
| `patchbay permission capabilities` | local 显式声明 | — |
| `patchbay permission exercise <permission> --decision <decision>` | local 显式声明 | — |
| `patchbay permission fail <permission> --state <state>` | local 显式声明 | — |
| `patchbay permission normalize <permission> --state <state>` | local 显式声明 | — |
| `patchbay permission reset <permission>` | local 显式声明 | — |
| `patchbay permission status <permission>` | local 显式声明 | — |
| `patchbay repl` | client 显式声明 | — |
| `patchbay session use <session-id> \| --clear` | local 显式声明 | — |
| `patchbay sessions list` | local 显式声明 | — |
| `patchbay sessions prune` | local 显式声明 | — |
| `patchbay snapshot [--path <dot.path>]` | client 显式声明 | — |
| `patchbay snapshot diff --from <revision>` | client 显式声明 | — |
| `patchbay snapshot wait <dot.path> --until <condition> [<json-value>]` | client 显式声明 | — |
| `patchbay trace diff <before-trace-id> <after-trace-id>` | local 显式声明 | — |
| `patchbay trace export <trace-id> --output <directory>` | local 显式声明 | — |
| `patchbay trace mark <note>` | local 显式声明 | — |
| `patchbay trace prune [--dry-run]` | local 显式声明 | — |
| `patchbay trace show <trace-id>` | local 显式声明 | — |
| `patchbay trace start --name <name> [--activate] [--pin]` | local 显式声明 | — |
| `patchbay trace stop [trace-id]` | local 显式声明 | — |
| `patchbay ui focus-tree` | client 显式声明 | — |
| `patchbay ui gesture drag <identifier> <generation> --start <json> --gesture-path <json> [--duration-ms <ms>]` | 协议 descriptor | `ui.gesture.drag` |
| `patchbay ui gesture fling <identifier> <generation> --start <json> --velocity <json> [--duration-ms <ms>]` | 协议 descriptor | `ui.gesture.fling` |
| `patchbay ui gesture press-hold <identifier> <generation> --start <json> [--duration-ms <ms>]` | 协议 descriptor | `ui.gesture.pressHold` |
| `patchbay ui inspect off` | 协议 descriptor | `ui.inspect.select` |
| `patchbay ui inspect on [--ttl-ms <ms>]` | 协议 descriptor | `ui.inspect.select` |
| `patchbay ui inspect status` | 协议 descriptor | `ui.inspect.status` |
| `patchbay ui keep-awake off` | 协议 descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake on [--lease-ms <ms>]` | 协议 descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake status` | 协议 descriptor | `ui.keepAwake.status` |
| `patchbay ui render-tree` | client 显式声明 | — |
| `patchbay ui semantics action <node-id> <generation> <action> [text]` | 协议 descriptor | `ui.semantics.action` |
| `patchbay ui semantics tree` | 协议 descriptor | `ui.semantics.tree` |
| `patchbay ui tap <identifier> [--generation <generation>]` | 协议 descriptor | `ui.semantics.tap` |
| `patchbay ui targets --emit-manifest` | local 显式声明 | — |
| `patchbay ui text enter <target-id> <generation> [text]` | 协议 descriptor | `ui.text.enter` |
| `patchbay ui text set <target-id> <generation> [text]` | 协议 descriptor | `ui.text.set` |
| `patchbay ui verify-manifest <manifest-file> [--navigate] [--continue-on-error] [--restore]` | local 显式声明 | — |
| `patchbay ui wait destination <destination-id>` | 协议 descriptor | `ui.wait` |
| `patchbay ui wait frame-revision <revision>` | 协议 descriptor | `ui.wait` |
| `patchbay ui wait semantics-mounted <identifier>` | 协议 descriptor | `ui.wait` |
| `patchbay ui wait semantics-unmounted <identifier>` | 协议 descriptor | `ui.wait` |
| `patchbay ui wait semantics-value <identifier> <value>` | 协议 descriptor | `ui.wait` |
| `patchbay ui wait tree-revision <revision>` | 协议 descriptor | `ui.wait` |
| `patchbay ui widget-tree` | client 显式声明 | — |
<!-- PATCHBAY_COMMAND_REFERENCE:END -->

由 `flutter run --machine` launcher 启动 App 后，CLI 默认从用户临时目录发现唯一当前会话：

```text
dart run bin/patchbay.dart --json identity
dart run bin/patchbay.dart --json catalog
dart run bin/patchbay.dart --json snapshot
dart run bin/patchbay.dart --json exec <namespace.command>
```

要把启动与恢复收敛成一次有界操作，可由 CLI 启动已接入声明契约的 consumer：

```text
dart run bin/patchbay.dart launch -- flutter run --vmservice-out-file .dart_tool/patchbay/vmservice.txt
dart run bin/patchbay.dart --keep-awake launch -- flutter run ...
PATCHBAY_KEEP_AWAKE=true dart run bin/patchbay.dart launch -- flutter run ...
dart run bin/patchbay.dart --no-keep-awake launch -- flutter run ...
```

child 用 `PatchbayLaunchContext.tryFromEnvironment` 读取 `PATCHBAY_SESSION_DIR`、
`PATCHBAY_LAUNCH_ID`、`PATCHBAY_LAUNCH_OWNER_PID`，再用 `pendingRecord` 写完整 pending 记录，
发现 transport 后用 `withTransport` 更新。launcher 不伪造 application/device metadata，也不解析
stdout 私有帧；child 必须显式传入真实 consumer/App `processId`，不能拿 launcher `ownerPid` 代填。
launcher 只监督 `launchId + ownerPid` 同时匹配的记录；未声明的 child 会在有限预算后以
`sessionNotDeclared` 失败。machine frame 只写 stdout，child 与人读日志转发到 stderr。
稳定 live 会话每 5 秒观测一次；断连后从 200 ms 初始退避重新恢复，每次 identity probe 同时受 child
退出与剩余总预算约束。

亮屏策略默认关闭。全局 `--keep-awake` 或本地 `PATCHBAY_KEEP_AWAKE=true/on/1` 会在 launcher `live`
后申请既有 10 分钟租约，并在半租期借健康观测续租；`--no-keep-awake` 覆盖本地默认。普通 one-shot /
REPL 命令成功后也可按同一策略续租，但显式 `ui keep-awake on|off|status` 不会触发第二次操作。终态和
信号取消尽力 release；断连时 machine frame / JSON 明确写 `releaseUnconfirmed` 或
`renewalUnconfirmed`，App 的租约到期是最终兜底。

上面任何一步不通时先跑体检——它自己拨号，因此拨不通是它的一条 finding，而不是命令终止：

```text
dart run bin/patchbay.dart doctor          # 会话 / 连接 / catalog / lifecycle 逐项
dart run bin/patchbay.dart --json doctor
```

四项按依赖顺序查，每项给「现象 → 可能原因 → 建议动作」，前一项失败时后面标 `skipped`；退出码取
第一处 failed 的类别（会话 / 连接 `3`、catalog `4`、lifecycle `5`），只有 warning 时是 `0`。它还会
读一次 snapshot，扫到为 `true` 的布尔 `active` 就打出路径并劝阻 `force-stop` / `kill`——设备上可能
有正在进行的业务会话。完整语义见 [`../../docs/guide.md`](https://github.com/cr1992/patchbay/blob/main/docs/guide.md)。

多 App 或多 worktree 同时运行时不会按 PID、时间或当前目录猜测。CLI 以
`sessionAmbiguous` fail-closed，并打印不含 URI 的 session ID；调用方须显式选择：

```text
dart run bin/patchbay.dart --session <session-id> --json identity
```

`--ws-uri` 保留为 launcher 记录丢失时的恢复出口：

```text
dart run bin/patchbay.dart --ws-uri <uri> --json identity
dart run bin/patchbay.dart --ws-uri <uri> --json catalog
dart run bin/patchbay.dart --ws-uri <uri> --json snapshot
dart run bin/patchbay.dart --ws-uri <uri> --json exec <namespace.command>
```

`<generation>` 来自最近一次 catalog 或 Semantics tree。目标重挂载后 generation 会变化；写操作携带
旧值时会稳定拒绝，避免命令误打到同名的新实例。

`navigation go|push|back` 省略 `--revision` 时，CLI 先调 `navigation.current` 读当前 revision 再派发，
结果带 `revisionSource: navigation.current`。围栏不变：revision 照样随请求发出，读到与派发之间导航
动过照样被 App 以稳定拒绝挡下。显式 `--revision` 保持原行为——不多读一次，也不带该标记。

`ui wait <子命令>` 与 payload 里的 `condition` 刻意不同名（`semantics-mounted` ↔ `semanticsMounted`、
`destination` ↔ `navigationDestination`）。两种拼写都可直接键入，映射表在 `patchbay help ui wait`；
两边的名字都不会改，它们是 wire 契约。

### 有界 VM 性能画像

`perf profile` 默认对已连接的 VM Service 采样 10 秒，只输出稳定的
`patchbay.performanceProfile.v1` 摘要：build/raster 帧耗时与 16 ms jank 计数、两次 heap 观测、
新/老生代 GC 计数。`--duration-ms` 限 1..60000，`--sample-limit` 限 1..10000；单次最多处理
10000 个事件和 8 MiB 事件数据，任一先到都会明确给 `sampling.truncated=true` 与丢弃数。公开 VM
stream 每批 timeline event 到达即汇总，触顶马上取消订阅；原始事件不保留，也不进入 Patchbay 输出、
日志或 artifact。命令临时启用所需公开 VM timeline stream，
无论成功或失败都会恢复原 stream 集合。

这是 VM 观测（`factSource=uiObserved`），不是 App catalog 命令。direct HTTP 稳定返回
`profilingVmServiceRequired`，不伪造同口径事实；老 VM 缺少所需公开 RPC/stream 时返回
`performanceProfilingUnavailable`。

`net profile` 当前不采集任何数据，稳定返回 `networkProfilingUnavailable`。经核对的
`vm_service 15.2.0` 公开 HTTP profile 在调用方过滤前已经收进 body、header、cookie 和 query 值；
先取回再脱敏违反 Patchbay 的采集时隐私边界，因此只有公开 RPC 能采集前过滤，或接入方注入仅产生
已脱敏事件的 collector 后，才会发布 net capability。

`ui tap <identifier>` 是 `ui semantics tree` + `ui semantics action` 的一步替代：解析、代际校验和派发
都在 App 侧一次完成，CLI 不构造 nodeId，也不给 generation 补默认值。`--generation` 可选，传了就是
调用方自己的前置围栏；不传时围栏由 bridge 在过门前 pin 住的 generation 提供。未命中、多义和代际
过期都是带 details 的稳定拒绝（分别给出已挂载 identifier 清单、候选列表、expected/current），不会用
空拒绝把调用方推回全树 dump。

### UI 目标声明对账

`ui verify-manifest <file>` 读一份接入方维护的 JSON 或 YAML manifest：`catalogTarget` 与 catalog 的
`uiTargets` 对账，`semanticsIdentifier` 与既有 `ui.semantics.tree` 活体快照对账，报
`declaredNotMounted` / `mountedNotDeclared` / `propertyMismatch` 三类偏差。比对完全在 CLI 侧完成：
不新增 wire 命令，只用 catalog；manifest 里出现 `destination` 时额外读一次 `navigation.current`
做范围过滤。schema、字段语义、`destination` 过滤口径与「未挂载 ≠ 丢失」的边界见
[使用指南](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#ui-目标声明对账ui-verify-manifest)，示例文件在
[`docs/examples/ui-targets-manifest.json`](https://github.com/cr1992/patchbay/blob/main/docs/examples/ui-targets-manifest.json)。

全部相符退出 `0`，报告里有任一类偏差退出 `7`——App 侧一切正常应答，所以它既不是拒绝（`5`）也不是
类型化失败（`6`）。manifest 读不了或不合法时 fail-closed 退出 `64`，`--json` 给 `manifestInvalid` /
`manifestUnreadable` 和指到具体位置的 `details.field`。格式只按小写 `.json` / `.yaml` / `.yml`
扩展名选择，不嗅探内容；YAML 关闭恢复并拒绝 alias 与显式 tag。两种格式共享 1 MiB、64 层、200000
节点（含 mapping key）预算，语法错误给一基 `line` / `column` 且不回显文件内容。人读输出直接列出偏差条目；repl 内每行只占
一行，给的是计数。

v2 的两个 namespace 相互独立：`kind` / `sensitive` 只属于 `catalogTarget`，
`semanticsIdentifier` 只持久化稳定 identifier。唯一活体命中会报告本次 `nodeId` / `generation` 与
tree revision；零命中进入 `declaredNotMounted`，多命中以 `uiSemanticsIdentifierAmbiguous`
fail-closed。能力缺失、tree 截断、payload 不完整分别有稳定 protocol code。`ui targets
--emit-manifest` 会在 App 声明 tree capability 时加入唯一活体 identifier；歧义或跨 namespace 同 id
则拒绝生成，不会挑一个代表。

### repl 会话

```text
dart run bin/patchbay.dart --ws-uri <uri> --json repl <<'EOF'
identity
ui semantics tree
ui tap login.submit
EOF
```

repl 建一次连接，然后逐行执行 typed 命令，语法与一次性调用完全相同。每行输出自带 `exitCode`
（`--json` 下是一行一个 JSON 信封，否则是 `[n] exit=<code> <摘要>`）：进程退出码承载不了逐条结果，
会话码只描述会话本身——干净跑完是 `0`，被错误终止则是该错误的类别。

被拒绝或类型化失败的行不终止会话；transport / protocol / session 错误终止，因为它们说明复用的连接或
对端已经不是操作者选定的那个，CLI 不会悄悄重连。

以下在 repl 内 fail-closed，不静默忽略：连接类参数与 `--json`（属于会话，逐行给出只能靠重连兑现）、
`--stdin`（命令流已占住 stdin，没有剩余的 no-echo 通道）、嵌套 `repl`。direct 模式整体不进 repl：
bearer token 会与命令流抢同一个 stdin。空行与 `#` 开头的行跳过，`exit` / `quit` 或 stdin 关闭结束会话。

### 命令声明一致性

`PatchbayFriendlyCommand` 是 CLI 里唯一的命令表：路径解析、参数构造、dispatch 与帮助全部由它派生。
每条声明选择一个 `PatchbayCommandTarget`，`runPatchbayCli` 对该 enum 做无 default 的 switch，因此新增
命令无法只接上执行而漏掉帮助。`exec` 的协议名来自调用方参数；identity / catalog / snapshot 与三棵
诊断树走 transport 方法而非 catalog 命令，这些差异也写在声明里。

所有命令（含 `exec`、`job`、`ui text`、`ui semantics` 与三棵诊断树）都对无关选项 fail-closed：
传入该命令不接受的选项时以退出码 `64` 报 `--<name> is not valid for <command>`，不静默忽略。

friendly command 只是稳定协议名的通用参数映射，不是另一份 capability 清单。CLI 每次执行仍读取
App 当前 catalog；catalog 与 invoke 结果矛盾时返回 `catalogInvocationDrift`（`details` 带上 host 自己
给出的目录违规原因，不必再跑一次 `catalog` 才知道哪条命令名非法），缺失命令仍保留 App 的
`commandNotRegistered` rejection 和退出码 `4`。CLI 从不按命令数量推断能力。完整命令名仍是协议身份，
任意 consumer 命令继续使用 `exec <namespace.command>`。

`describe <namespace.command>` 只读这份 catalog，绝不调用命令。JSON 结果包含完整 command 行、
`schemaMode`，以及封闭取值 `eligible` / `notDeclared` / `notExternal` 的 `retryEligibility`。external 行声明
合法 `retryPolicy` 时，CLI 只在 transport unavailable / timeout 时重试，并为所有 attempt 复用同一个
`requestId`；App 拒绝、协议失败和任意 provider 返回结果都是终局，绝不重试。

每一次 RPC 往返都有预算，默认 30 秒，由 `--transport-timeout-ms` 调整，两条传输都适用；耗尽时以
退出码 `3` 和稳定 code `appUnresponsive` 失败并附处置提示。`--timeout-ms` 是发给 App 的业务等待预算，
声明了它的请求会把本次 RPC 预算放宽成「声明的等待 + 一次往返」，不会被默认预算腰斩。

日志过滤支持 `--cursor`、`--direction`、`--limit`、逗号分隔的 `--levels`/`--categories` 以及
ISO-8601 `--since`/`--until`。capture 支持 `--pixel-ratio`、`--after-frames`（1..120 次 Patchbay
观测到的 Flutter 帧）和 `--timeout-ms`。host 未声明 `captureAfterFrames` 时，CLI 会省略该字段并在结果
标记 `captureMode=legacyImmediate`，不会从错误形状猜支持情况。`capture diff` 只比较宽高和像素格式
相同的两份已保留 capture blob，返回变化像素数、总像素数和比例，不代替调用方判 pass/fail。

所有 artifact 下载先写同目录临时文件，分块校验 blob metadata、offset、base64、总长度与 SHA-256，全部通过后才 rename；已有输出
默认拒绝，只有显式 `--force` 才替换。过期、拒绝、错序、哈希错误和中断不会留下完整输出名的残文件。

## 连接边界

`--ws-uri` 可能含 VM Service 认证信息：

- 只从可信 launcher 输出或当前调试会话取得；
- 不写入脚本、日志、快照和提交物；
- CLI 错误只报告错误类别，不回显完整 URI。

参与声明的 child 会先以原子替换写入 provisional 记录，再由自己的工具链发现 URI 后补齐；launcher 连接并读取
`ext.patchbay.identity` 后才补齐 `appInstanceId` 和 `isolateId`。完整记录绑定 session schema、
`applicationId`、`appInstanceId`、`isolateId`、launcher PID、`wsUri`、build mode、创建时间、worktree
与设备 ID。记录默认位于当前用户的系统临时目录，可用 `PATCHBAY_SESSION_DIR` 覆盖。
`patchbay launch` 将 child stdout/stderr 作为人读日志转发到 stderr，stdout 只保留稳定 machine frame。

PID 存活只表示 launcher 可能仍在，不能证明 App 实例仍相同。PID 不活或 schema/identity 不匹配会使
记录失效；短暂不可达则保留记录并在有限预算内恢复。hot restart 改变 App instance 时 launcher 会在
复用前重新实测并重锚；显式 `--ws-uri` 也执行同一 schema/isolate/appInstance identity 校验。launcher
退出时只删除自己拥有的 pending 记录。POSIX 上目录和
文件分别收紧到 `0700` / `0600`，普通输出、错误和选择列表都不包含 URI/token。

当前命令执行路径自身不调用 ADB。不过在 Android 上，如果 URI 来自 `flutter run`，Flutter 的启动、
安装和端口转发仍可能间接使用 ADB；因此 VM Service 路径不能宣称端到端零 ADB。

CLI 也可连接 consumer 显式启动的 `patchbay_transport` direct host。direct host 不做发现，调用方必须从
可信的带外渠道取得 endpoint、runtime identity 和短期 bearer；token 只能从 no-echo stdin 读取，CLI
不提供 token argv/env/query 入口：

```text
dart run bin/patchbay.dart \
  --direct-endpoint http://192.0.2.10:12345/patchbay/direct/v1 \
  --direct-token-stdin \
  --direct-application-id dev.example.app \
  --direct-app-instance-id <instance-id> \
  --json identity
# CLI 在这里从当前 TTY 读取一行且不回显
```

上例是交互 TTY 形状；不要把 bearer 字面量写进 shell history。CLI 读取 bearer 时会自动关闭 echo。direct
LAN 是实验性的明文 HTTP：bearer 提供认证但不提供机密性，不能防止同网段被动监听和重放，不能称为
secure channel。应只在可信隔离网络和短 TTL 下显式启用；Flutter SDK 的 widget/render/focus diagnostic
extensions 仍只存在于 VM Service 路径。

## 输入与结果

普通结构化参数通过 `--args` 传 JSON object，`--stdin` 从一行 no-echo stdin 读入。两者可以同时使用：
stdin 的 JSON object 与 `--args` 合并，同名键以 stdin 为准，因此可读参数留在命令行、只有密文走
no-echo 通道。只用 `--stdin` 不用 `--args` 仍然合法（合并的退化情形），stdin 内容不是 JSON object
时照旧报错。

descriptor 标记为敏感的参数只能来自 stdin：出现在 `--args` 里时 CLI 以退出码 `64` 拒发，不上线，
错误信息只点名参数不回显值。输出只保留 redacted 元数据。stdin 接管真实 TTY 时 CLI 会临时关闭
terminal echo，读取后恢复；无法关闭回显时以 `terminalEchoControlFailed` fail-closed。管道输入不修改
终端模式。

`admission=accepted` 只表示 App 已受理请求，不代表副作用已完成。长任务会返回 `jobId`：

- `--wait` 持续读取到终态；
- `job get` 读取当前快照；
- `job cancel` 请求取消，但取消结果仍以 App 返回的 job 状态为准。

`jobId` 的稳定取值位置是**响应顶层**：受理信封与 `--wait` 终态结果都在顶层给出这条命令受理的那个
job。`payload.jobId` 是 App job snapshot 自带的字段，两处都保留，脚本读顶层那个。

CLI 为每次 invoke 生成并发送 `requestId`，VM Service 与 direct 两条路径都要求响应回显相同值；不一致
按协议错误退出，避免并发或迟到响应被归到错误命令。显式空 `requestId` 同样 fail-closed。

`--wait` 默认最多等待 60 秒；descriptor/admission 带 `suggestedWaitTimeoutMs` 时采用 consumer 提示的观察窗口。
例如 BLE 配网提示 150 秒，以覆盖其 120 秒激活终态。超时表示 App 已受理但在观察窗口内没有终态，
归为类型化操作失败（退出码 `6`），不是连接失败。

host catalog 有 `patchbay.job.wait` 时，CLI 以 `afterSequence` 做 bounded long-poll，并在结果标记
`waitMode=serverLongPoll`。旧 host 没有该命令时保留 `patchbay.job.get` 兼容轮询，结果明确标记
`waitMode=legacyPolling` 和 `waitNotice`，不冒充服务端等待。`logs tail` 的 `outcome=timedOut` 是一次成功的
长轮询观察结果，退出码仍为 `0`，不会误报 transport error。

JSON 输出保留事实来源、rejection code、job event sequence 和 capability warning。CLI 不把这些字段
升级解释为设备执行成功、像素正确或系统 UI 已操作。

带 `--json` 时 stdout 只有一个 JSON 文档：响应信封，或错误信封

```json
{"error": {"code": "sessionAmbiguous", "details": {"sessions": ["…"]}}}
```

形状与 App 的 rejection 信封一致（稳定 `code` + 自由 `details`）。用法错误的 `code` 是 `usageError`，
句子在 `details.message`；session / protocol / transport / 敏感输入 / `waitTimeout` 用各自的稳定 code，
兜底错误只暴露异常类型名，不回显 URI 或 token。人读文本仍只走 stderr。不带 `--json` 时行为不变。

「一个」是对一次性命令说的。有三条命令是流式输出，脚本要逐行读、而不是当作单个文档解析：`repl`
每行一个信封，`logs tail` 是 NDJSON，`launch` 是 launcher 机器帧。

「一个」也只描述 stdout 本身。人读句子走 stderr；命令外层的包装器（`just`、`npm`、shell 函数）
在命令退非零时打的那行失败提示同样走 stderr。用 `2>&1` 合流，会把这段文本接在一个本来完好的
文档后面，解析器于是报「多余数据」——它读起来像第二个 JSON 文档，其实不是。要留 stderr 就单独
重定向到文件，不要并进正在解析的那个流。

artifact 下载的分块大小取自 catalog 中 `blob.read` 的 `limit` 默认值（与 CLI 默认 64 KiB 取小），
不写死：consumer 调小 `maxChunkBytes` 时下载照常，不会被 `blobInvalidChunkLimit` 拒死。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 请求完成，或 App 返回了可解析的非错误结果 |
| `3` | 会话发现、连接、传输或 VM Service RPC 失败 |
| `4` | schema/identity 不兼容，或目录中没有该命令 |
| `5` | App adapter 或 Flutter bridge 拒绝受理 |
| `6` | 已受理的 operation 返回 `outcome=failed`、job 失败/取消，或等待终态超时 |
| `7` | 本地对账（`ui verify-manifest`）完成，报告里有偏差；App 侧请求全部正常应答 |
| `64` | 命令格式、参数或本地输入不合法（含拒读的 manifest 文件） |

调用方应同时读取 JSON 信封；退出码不承载设备完成性。

## 能力与边界

Widget/Render/Focus 命令是 Flutter SDK 诊断 extension 的只读代理。输出带
`schema=flutterSdkPassthrough`，字段随 Flutter SDK 变化；profile 中对应 extension 不存在时稳定返回
`flutterDiagnosticUnavailable`。稳定自动化应消费 `ui semantics tree` 的 Patchbay schema。

navigation、wait、capture、结构化日志与 direct 仅在运行时 catalog/consumer host 实际注册时可用。CLI
不通过 ADB、坐标点击或 Widget 文本猜测补齐缺失能力，也不会替 App 自动启动 direct listener 或分发
bearer。日志是 consumer 已脱敏的 App 记录；capture 只证明 Flutter repaint boundary 的合成结果，不含
系统权限弹窗，PlatformView 也可能缺失。
三树与 action 的稳定命令、passthrough 边界和退出条件见
[`../patchbay_flutter/doc/ui-inspection-and-actions.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/doc/ui-inspection-and-actions.md)。
