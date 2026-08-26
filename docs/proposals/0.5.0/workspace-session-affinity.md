# 0.5.0 workspace / worktree 级会话亲和性

> 状态：已接受
>
> 关联：PB-050-14
>
> 设计闸门：DG-050-12

## 问题

session 记录已经保存 `workspacePath`，但它目前只用于展示。无 `--session` 的 resolver、`session use`、
doctor 与 trace 都从同一个全局目录读取同一个 `selected-session`，再按全局 pin 或全局唯一性选 App。
因此两个 checkout（尤其是共享 Git common dir 的 worktree）并行时，旧 pin 或“全局恰好只剩一个记录”都可能
把当前 Agent 的写命令送到另一工作区。

这是目标选择契约缺失，不是再加一层“latest”启发式能解决的问题。0.5.0 必须让隐式选择只在当前 checkout
内发生；无法证明归属时宁可拒绝，也不能猜测。

## 目标与非目标

### 目标

- 为每次 CLI 调用计算 host-local、可复刻且能区分 Git worktree 的 workspace identity。
- 无 `--session` 时只读取当前 identity 的 pin 或唯一候选，歧义和未知归属均 fail-closed。
- `--session <id>` 保持为唯一允许跨 workspace 选择的入口，且不读取、创建或改写任何 pin。
- 保持旧 session record 可读，并以一次性的保守迁移退出全局 pin。
- resolver、`session use/list/prune`、doctor 与 trace 共享同一个归属判断，不再各写一套选择逻辑。

### 非目标

- 不引入 daemon、后台索引、全局 latest、最近活跃设备或 fuzzy workspace 匹配。
- 不把 Git common dir、branch 名、remote URL、仓库名或目录末段当 identity；这些都不能唯一标识 checkout。
- 不改变 runtime identity 握手、PID/启动时间探活、pending TTL、transport 选择或 REPL 已持有连接的语义。
- 不保证 0.4.x CLI 获得 workspace 隔离；旧二进制仍按旧规则运行，升级提示必须明确这一点。

## Workspace identity

identity provider 以命令启动时的 cwd 为输入，结果固定为：

```text
kind         = gitWorktree | directory
canonicalRoot = host-local canonical absolute path
workspaceId  = sha256("patchbay-workspace-v1\0" + kind + "\0" + canonicalRoot)
```

1. 优先执行等价于 `git -C <cwd> rev-parse --show-toplevel` 的只读探测；成功时取返回的 worktree 顶层，
   **不得**改取 `--git-common-dir`。探测硬预算为 1 s、无重试；明确报告“不在 Git 仓库”时才走
   `directory`，超时或其他异常都视为 unavailable。
2. 非 Git 目录以启动时 cwd 本身为 root，不按 `pubspec.yaml`、包名或父目录猜项目边界。
3. root 必须绝对化并解析符号链接；Windows 还必须使用平台返回的 canonical drive/separator 形状。同一 host
   上重新计算的结果必须逐字节相等，不能用仅在进程内稳定的 hash。
4. cwd 已删除、realpath 失败、Git 输出非绝对路径或 digest 无法计算时，identity 为 unavailable；所有隐式
   选择与 `session use` 按 `sessionWorkspaceUnavailable` 拒绝。显式 `--session` 不依赖当前 identity。

`canonicalRoot` 是本机定位数据，只写 owner-only session 文件，不进入命令响应、trace、audit 或错误详情。
对外只允许 `workspaceId` 和现有脱敏后的 `workspaceName`。

## Record 与 launch context

session record 的 `schemaVersion` 继续固定为 `1`。新 writer 在既有 `workspacePath`（值改为
`canonicalRoot`）之外松读追加：

| 字段 | 形状 | 规则 |
|---|---|---|
| `workspaceIdentityVersion` | integer | 固定为 `1` |
| `workspaceKind` | `gitWorktree \| directory` | 必须与 identity provider 结果一致 |
| `workspaceId` | `sha256:` + 64 个小写 hex | 必须由 kind 与 canonical path 复算一致 |

三项必须全有或全无；部分存在、格式错误或复算不一致的记录进入既有 quarantine，不参与任何选择。三项全无
是 legacy record，继续可读，不因升级被删。

`patchbay launch` 在启动 child 前只计算一次 identity，并通过 launch context 注入；child 改 cwd 不改变归属。
`PatchbayLaunchContext.pendingRecord` 对新 context 从 context 派生 workspace 字段，不接受调用方另报另一条路径。
为保持源码兼容，既有 `workspacePath` 参数先保留为可选兼容参数；提供时必须与 context 的 canonical root
一致，否则 `sessionWorkspaceMismatch`。旧三字段 context 仍可读取并写 legacy record，新 launcher + 旧 child
也只会产生 legacy record，不伪造新身份。

legacy record 只在其 `workspacePath` 能 realpath，且按当前 provider 规则复算后与当前 identity 完全一致时，
才可作为当前 workspace 的候选。identity 握手成功后，新 CLI 原子补写三项字段；路径不存在、移动、无法解析
或不相等时不迁移、不删除，只能用显式 `--session` 选择。

## 选择与 pin 契约

选择顺序固定如下：

| 调用形状 | 候选范围 | pin 行为 |
|---|---|---|
| 显式 endpoint / direct | 不读 session store | 不读不写 |
| `--session <id>` | 全局 exact id | 不读不写；允许跨 workspace，仍做完整探活与 runtime identity 握手 |
| 无 `--session`，当前有 scoped pin | 只认当前 workspace 中该 id | stale/missing 时拒绝，不回退唯一候选 |
| 无 scoped pin | 当前 workspace 的 live/pending 候选 | 0 个拒绝，1 个解析，多个 `sessionAmbiguous` |

新增稳定错误 `sessionWorkspaceUnavailable`、`sessionWorkspaceEmpty` 与 `sessionWorkspaceMismatch`；既有
`sessionSelectionStale`、`sessionAmbiguous`、`sessionPending`、探活和握手错误继续沿用。choices 只列当前
workspace 候选，不用 foreign session 暗示用户去 pin 错目标。

`session use <id>` 只能把属于当前 workspace 的 live/pending record 写入当前 scoped pin；foreign 或无法证明
归属的 legacy record 以 `sessionWorkspaceMismatch` 拒绝，并提示在单条命令上显式传 `--session`。
`session use --clear` 只清当前 scoped pin。`sessions list` 仍可展示全局 inventory，但 additive 增加
`workspaceAffinity: current | foreign | legacyUnverified`；`selected` 只表示当前 workspace 的 scoped pin。
human 输出继续只显示 workspace 末段，不显示 canonical path。

scoped pin 文件名为 `selected-session-<workspaceId 的 64 位 hex 部分>`（不使用 `.json`，避免被 record
scanner 当 session，也不把 `sha256:` 的冒号带进 Windows 文件名）；
内容包含 `schemaVersion: 1`、`workspaceId` 与 `sessionId`，读时必须交叉校验文件名和当前 identity。写入沿用
owner-only temp + atomic rename。pin/migration/prune 使用 session 目录内的短时文件锁串行化：先清除指向已不存在
record 的 pin，再执行写入；最多保留 256 个 scoped pin，每份最多 1 KiB，清理后仍满则
`sessionSelectionCapacityExceeded`，不得驱逐仍有 record 的其他 workspace pin。

## 全局 pin 的一次性迁移

新 CLI 不把既有 `selected-session` 当常规 pin。第一次发现它时，在同一目录锁内原子改名为
`selected-session.legacy`，之后只做一次保守判断：

- 它指向的 record 能按上一节证明属于**当前** workspace 时，写入当前 scoped pin；
- 其余情况只退役旧文件，不迁移、不按全局唯一性补选，也不删除目标 record。

并发的两个 workspace 只有一个能领取旧文件；未领取者没有 pin，按当前 workspace 唯一性继续。这可能让一个
旧 pin 失效，但不会让命令跨区。`sessions prune` 清理无 record 的 scoped pin 和退役文件；不自动迁移第二次。

## 共享选择内核与状态

resolver 提供一个同步的 workspace classification / candidate-selection 内核，正式连接、local session 命令、
doctor 和 `_traceSessionRef` 都调用它；后两者不得再直接组合 `readAll + readSelection + global unique`。
classification 只决定“允许尝试谁”，连接阶段仍按既有顺序做 process identity、URI 校验和 runtime handshake。

trace 在正式 resolve 前只能记录该内核确定的 session；候选不确定时不填 `sessionRef`，随后照实记录命令失败，
不得为了 trace 完整而放宽选择。doctor 分别报告 current/foreign/legacyUnverified 数量、当前 pin 状态和同一个
稳定 code，但不输出 canonical root。

## 兼容与降级

- 新 reader + 老 record：按 `workspacePath` 保守归属，握手后原子升级；不能证明时仅允许显式选择。
- 老 reader + 新 record：忽略三个 additive 字段，record schemaVersion 仍为 1，不删除文件；但旧 CLI 不具备
  本提案的隔离保证。
- 新 launcher + 老 child、老 launcher + 新 child：都产生 legacy record，走同一保守迁移，不猜 identity。
- scoped pin 不覆盖全局 pin；升级后旧 CLI 看不到新 pin，多个记录时会按旧规则 ambiguous。不得为兼容旧 CLI
  继续双写全局 pin。
- VM Service 与 direct 的 session 解析共用同一内核；显式 direct endpoint 仍完全绕过 session store。

## 安全与隐私

workspace affinity 是本地防误投门，不替代 App/runtime identity 握手。显式 `--session` 只是用户对跨区选择的
明确授权，仍不能绕过 PID、process start time、applicationId、appInstanceId 与 isolateId 校验，也不能留下跨区
pin。目录末段、branch、remote 与 common dir 都不得作为相等依据。

session 目录、record、pin、lock 与临时文件继续 owner-only；所有路径都在进入文件名或 JSON 前做长度和字符
校验，文件名只用定长 digest。错误、JSON、doctor、trace 与 audit 不保存 absolute path。release 裁除和 App
命令注册不受影响，本条不增加移动端权限或网络面。

## 验证

- identity：同 checkout 子目录相同、两个共享 common dir 的 worktree 不同、symlink 收敛、非 Git cwd 精确、
  cwd/realpath/Git 失败均 fail-closed。
- resolver：current scoped pin、current unique、current ambiguous、foreign-only、stale pin、explicit cross-workspace
  与 pending/握手失败矩阵；任何 implicit 路径都不能返回 foreign record。
- 迁移：legacy record 可证明/不可证明、路径移动、全局 pin 指向 current/foreign/missing、两个进程竞领、
  新旧 reader 双向 golden，schemaVersion 始终为 1。
- local/doctor/trace：四者对同一 fixture 给出相同候选与 code；list 只增加 affinity，所有输出不含 absolute path。
- 资源与失败注入：原子 rename 前后崩溃、锁竞争、损坏/超长 pin、256 上限、stale prune，均不丢 session
  record、不回退全局 latest。
- example：从同一 Git 仓库创建两个 worktree，各自启动 Android/iOS 会话；在两个根与子目录交叉执行无
  `--session` 的只读和写命令，证明只命中本 checkout；再用显式 `--session` 证明跨区可用但 pin 未改变。

## 待裁决

1. 接受上述 `gitWorktree | directory` identity 与 SHA-256 host-local key，不使用 common dir 或仓库名。
2. 接受 legacy record 的“路径可证明才懒迁移”与全局 pin 的一次性退役规则。
3. 接受 `session use` 只能写 current scoped pin，显式 `--session` 为唯一跨 workspace 入口。
4. 接受 256 份、每份 1 KiB 的 scoped pin 上限与“不驱逐仍有关联 record 的 pin”策略。

### 裁决结论（DG-050-12，2026-08-26，仓主授权代理裁决）

仓主在会话中授权代理裁决（授权与过程记录于本 MR）。四条待裁决全部接受，无修改：

1. **接受 `gitWorktree | directory` identity 与 SHA-256 host-local key。** 版本计划已冻结「共享
   Git common dir 的不同 worktree 必须区分」；`rev-parse --show-toplevel` 是唯一能区分 worktree 的
   只读探测，common dir / 仓库名恰恰是会把 worktree 合并回同一作用域的候选，已在被否决方案列明。
2. **接受「路径可证明才懒迁移」与全局 pin 一次性退役。** fail-closed 方向与版本计划「不允许退回
   全局 latest」一致；两个 workspace 竞领旧文件只有一个成功的降级后果是「少一个 pin」而不是
   「写命令跨区」，代价方向正确。
3. **接受 `session use` 只写 current scoped pin、显式 `--session` 为唯一跨 workspace 入口。**
   与版本计划 PB-050-14 行逐字一致（「显式 --session 是唯一允许的跨工作区选择……不得改写另一
   工作区的 pin」）。
4. **接受 256 份 × 1 KiB scoped pin 上限与不驱逐仍有 record 的 pin。** 上限远超真实 worktree
   数量级，超限走稳定码 `sessionSelectionCapacityExceeded` 如实拒绝而非静默驱逐，与仓内资源
   有界化惯例一致。

连带说明：四个新增稳定错误码（`sessionWorkspaceUnavailable` / `sessionWorkspaceEmpty` /
`sessionWorkspaceMismatch` / `sessionSelectionCapacityExceeded`）进入封闭注册表（PB-050-23
ratchet），实现 MR 不得再新增本稿之外的码。

## 被否决方案

- 全局 latest / 最近活跃：把时序当身份，最容易把写命令投到错误设备。
- 以 Git common dir 或 remote 标识仓库：同仓 worktree 会再次合并成同一作用域。
- 只比较 `workspacePath` 字符串：symlink、相对路径和子目录会造成假不同；旧 writer 的路径也未声明 canonical。
- 自动把 foreign pin 改写到当前唯一 session：掩盖旧选择失效，使下一条写命令在用户未确认时换目标。
- 为每个 workspace 建独立 session directory：跨 workspace 的显式 `--session` 与全局 inventory 都会消失，
  还会迫使 launcher/consumer 协调另一套目录发现协议。
- 继续双写全局 pin 兼容旧 CLI：会保留本提案要消除的跨 workspace 误投入口。
