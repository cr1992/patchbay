# 0.4.0 调试轨迹持久化

> 状态：已接受
>
> 关联：PB-040-23
>
> 设计闸门：无
>
> M0 修订：2026-08-18 重新接受 audit/trace 跨进程边界；本版不新增 host audit event-stream。

## 问题

Patchbay 能为单条请求提供 requestId、JSON 信封、job events 和 artifact，但一次调试通常跨越多条命令、
断连重连和人工观察。目前这些细节只散落在终端历史、临时 JSON 和 App 内存中，无法回答“一次调试
按什么顺序发生了什么”、无法稳定比较两次回归，也不能把一条已经跑通的操作链安全地沉淀为自动化。

## 目标与非目标

### 目标

- 用一个 `traceId` 关联多条 CLI 命令、session 变化、job events、执行证据、人工标记和 artifact。
- 使用 append-only 事件流持久化，进程崩溃后仍能读取已经写入的部分。
- 提供 `start/mark/stop/show/export/diff/prune`，先把“发生过什么”记录准确。
- 默认脱敏、有限保留，不把 trace 变成凭据仓库或无限增长的日志目录。

### 非目标

- 不录制任意 shell、adb、网络抓包或 App 内部所有日志。
- 不保证 UI 像素、设备物理行为或业务成功；只保存 Patchbay 可证明的事实。
- 不在 0.4.0 提供 scenario 或 replay；回放保留为 PB-040-24，等待 recorder 与平台权限 driver 稳定。

## CLI 体验

```console
$ patchbay trace start --name pairing-debug --activate
traceId: tr_01...

$ patchbay exec pairing.start --json --wait
$ patchbay ui tap pairing.confirm
$ patchbay trace mark "设备未上报，但 UI 已变化"
$ patchbay trace stop

$ patchbay trace show tr_01...
$ patchbay trace export tr_01... --output pairing-debug.patchbay-trace
$ patchbay trace diff tr_before tr_after
```

所有可执行命令增加全局 `--trace <traceId>`；自动化和并行终端应显式传入。`--activate` 只在当前
workspace 建立一个便利指针，并持有排他锁；存在其他活动轨迹时 fail-closed，不按“最新一个”猜。
`stop` 只关闭本次 owner 创建的活动指针，不影响显式指定同一 traceId 的只读查看。

## 存储结构

默认目录为 `~/.patchbay/traces/v1/<traceId>/`，允许用现有配置机制覆盖：

```text
manifest.json
events.ndjson
artifacts/
```

`manifest.json` 保存 trace schema、名称、创建/结束时间、workspace 指纹、CLI 版本、脱敏策略、事件数、
完整性摘要和结束原因。它不保存 wsUri、token 或 sensitive 参数。

`events.ndjson` 每行独立提交，公共字段固定为：

- `schemaVersion`、`traceId`、`sequence`、`eventId`；
- UTC `recordedAt` 与相对起点的单调 `elapsedMs`；
- `type`、`requestId?`、`sessionRef?`、`jobId?`；
- `observer`、可选协议事实 `factSource`、`payload`、`previousEventHash`。`observer` 只表达谁把事件写进
  trace（如 `cliObserved/operatorStated/hostReported`）；`factSource` 只在承载协议事实时使用
  `appRecorded/deviceReported/uiObserved/...`，两套词表不得再共用一个字段。

事件类型**写入侧封闭、读取侧开放**，与 feature capability 的不对称同构：本版 writer 只能产出下列
类型，而 reader 遇到没见过的类型必须保留但不解释、导出时不得丢失。这样后续版本（例如
PB-040-25/26 的权限事件）新增类型时，老 reader 降级成“我不解释它”，而不是解析失败。

首版写入侧封闭表：`trace.started`、`trace.truncated`、`session.observed`、`command.started`、`command.admission`、
`job.event`、`artifact.attached`、`note.added`、`command.finished`、`trace.finished`。

`artifacts/` 使用 sha256 内容寻址，事件只保存摘要、长度、contentType、原 blob 元数据和相对路径。
同一内容不重复落盘；过期 App blob 被导出前必须明确报告缺失，不能留下看似有效的空引用。

## 写入与恢复

- sequence 在单个 trace 内单调递增，append、flush 后才把事件视为已记录。
- manifest 使用临时文件 + 原子 rename 更新；普通只读会把 events 尾部半行标记 `truncatedTail` 并忽略；
  `show/stop` 恢复时先在文件锁内截掉半行、追加 `trace.truncated`，再补写未闭合命令，不能形成只读死角。
- `previousEventHash` 形成轻量 hash chain，用于发现手工截断或重排，不提供身份认证承诺。
- CLI 进程异常退出时，下一次 `show/stop` 将未闭合命令标为 `interrupted`，但不伪造 host 终态。
- launcher 重连后继续使用原 traceId，并新增 `session.observed`，不覆盖旧 session 事实。

## 记录边界与脱敏

- 请求参数按 descriptor 处理：sensitive 字段只记 `{redacted: true, source: stdin}`，不保存值或摘要。
- PB-040-22 响应 schema 只提供结构校验，不把字段自动升级为“可持久化”；本版默认只保存 admission、
  稳定 code、执行证据与字段类型形状。以后若增加逐字段持久化/敏感元数据，再单独扩展值级记录。
- 老 host 的自由 payload 默认只保存 admission、字段名集合、类型形状和 `legacyUnvalidated: true`；必须
  显式 `--include-legacy-payload` 才能保存值，并在终端二次提示。**非 TTY 环境下该标志直接拒绝**，
  需要额外的显式开关才能生效——自动化和 CI 里没有终端可提示，让它静默降级成允许，等于把一条脱敏
  边界建立在一个不会执行的确认上。
- `ui.gesture.*` 只记录局部坐标与 generation，**转换后的全局坐标不落盘**。这条同时是未来回放的一道
  前置闸：轨迹里没有绝对坐标，回放就不可能退化成坐标回放。
- 网络认证头、query、body、wsUri 和本机绝对 workspace 路径永不进入 portable export。
- `trace export` 重新执行脱敏，而不是假定本地 trace 已经适合分享。

## 查看、导出与比较

`trace show` 默认展示命令级时间线，可展开 request/job/artifact。`--json` 输出稳定 trace envelope；
中断或缺失 artifact 必须显式呈现。

portable export 是带 manifest、events 和可选 artifacts 的版本化 bundle，**默认为目录**，打包为可选：
导入 zip 要校验路径穿越，默认目录直接少掉这一整类攻击面。无论哪种形态都保持同一逻辑 schema。
导入时校验路径穿越、大小上限、hash chain 和 schema。

`trace diff` 先按命令名、descriptor digest 和相对顺序对齐，再比较 admission、稳定 code、执行分类、
factSource、耗时区间和 artifact 摘要；不逐字节比较时间戳、requestId 或自由文本。**同名命令按出现
序号配对**，多出来的记为 added/removed，不做模糊匹配——一个会猜的对齐算法会让同两条轨迹的两次
diff 得出不同结果。

## 回放边界

PB-040-24 继续保留在 backlog，但不进入 0.4.0。具体前置与候选边界见
[未来回放 Proposal](../future/trace-replay.md)。0.4 CLI 不注册 `trace replay`，也不提供把历史事件直接
转换成写命令的隐藏入口。

## 预算与生命周期

- 默认最多保留 50 条 trace、30 天、合计 2 GiB，任一上限先到即拒绝新 trace，不自动删除未导出的轨迹。
- `trace prune` 默认只删超过策略且已结束的轨迹，支持 `--dry-run`；活动轨迹和显式 pin 的轨迹不删。
- 单事件编码后最大 256 KiB；单 artifact 沿用 CLI 既有 64 MiB 下载上限；单 bundle 及导入解压后的总
  大小最大 2 GiB。配置只能收紧这些数值，不能放宽。
- trace owner 锁带 PID 与创建时间，但 PID 存活只证明 writer 可能存在；过期锁需显式 recover。

## 兼容与依赖

- PB-040-23 可先记录 0.3.x host，但只得到 legacy payload 形状；稳定语义依赖 PB-040-22。
- session 跨断连延续依赖 PB-040-11；执行分类依赖 PB-040-21。
- 权限状态与系统弹窗只有在 PB-040-25/26 落地后才能形成完整 interruption 事件；此前 trace 必须标记
  `externalInterruptionUnknown`，不能把普通超时当成权限结论。
### M0 裁决修订：audit 与 trace 的跨进程边界（重新接受）

M0 原结论要求 audit 与 trace 共用 emit 点，并可逐条对应。实现前核对进程边界后确认该前提不成立：
audit sink 位于 App host，trace recorder 位于 CLI；若不新增 wire event-stream，二者没有共同 emit 点。
本次明确重新接受以下替代结论，而不是由实现 MR 静默改写：

- 本版不为 host audit 新增跨进程 event-stream wire。trace 的权威输入限定为 CLI 实际观察到的
  session、request/response、job、执行证据和 artifact；只存在于 App host 内的 audit sink 不自动回传。
- 两者共享参数形状脱敏函数、执行分类投影和 contract tests，保证对同一份响应不会得出两种分类；但不能
  宣称每条 host-only audit 都已出现在本机 trace 中。
- VM/direct 写入相同事件 schema；transport 只作为事件字段，不改变命令结果。

## 验证

- 单测覆盖并发 writer、序号、原子 manifest、尾部半行、hash chain、资源上限和 prune dry-run。
- 断言 host audit 与 CLI trace 对同一响应使用同一脱敏/执行分类投影；host-only audit 不会被伪装成
  CLI 已观察事实。
- 断言非 TTY 下 `--include-legacy-payload` 被拒绝，而不是静默按允许处理。
- 断言 trace 唯一写入点递归拒绝绝对坐标字段；!67 汇合后的集成测试另断言手势请求只含局部坐标且响应
  不含坐标，避免把纵深防御误写成手势契约证据。
- 断言 reader 遇到未知事件类型时保留原样且导出不丢失。
- 同名命令重复出现时 diff 结果可复现（同一对轨迹跑两次得同一结果）。
- golden 覆盖 start → 多命令 → job → artifact → stop 的完整 NDJSON 与 portable export。
- 敏感值 mutation 测试证明 stdin、token、wsUri 和 legacy payload 默认不落盘、不进入 export。
- 0.3.x fixture 验证 legacy 形状；0.4 fixture 验证 response schema 与执行证据完整记录。
- launcher 断连/重连后 trace 连续，且 session 变化可见。
- 首个真实业务接入方完成一次跨 session、job、artifact 的真机轨迹导出与 diff，不以 example
  代替；第二接入方再验证同一 portable schema。实际写回放需另做专项真机验收。

## 已裁决预算

- 保留天数、trace 数、总字节、单事件、单 artifact 与 bundle 上限已经在“预算与生命周期”冻结。

## 被否决方案

- 只保存 shell history：没有受理、job、证据、artifact 和版本上下文，也会泄露 sensitive 参数。
- host 侧作为唯一持久化位置：App 重启即丢失，且无法覆盖 session 切换和 CLI 本地失败。
- 默认保存所有自由 payload：在 response schema 和敏感元数据稳定前风险不可接受。
- 原样重放录制请求：旧 generation/session/requestId 会误击或制造假幂等。
- 靠终端二次提示兜住 legacy payload 的脱敏边界：自动化环境里那个提示根本不会执行。
- 事件类型读写两侧都封闭：后续版本加类型会让老 reader 解析失败，而不是降级成不解释。
- 把全局坐标写进手势事件：等于给未来的回放留一个绝对坐标入口。
