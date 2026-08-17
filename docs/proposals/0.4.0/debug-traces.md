# 0.4.0 调试轨迹持久化

> 状态：提案中
>
> 关联：PB-040-23
>
> 设计闸门：无

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
- `factSource`、`payload`、`previousEventHash`。

事件类型首版封闭为：`trace.started`、`session.observed`、`command.started`、`command.admission`、
`job.event`、`artifact.attached`、`note.added`、`command.finished`、`trace.finished`。未知事件类型在读取侧
保留但不解释，导出时不得丢失。

`artifacts/` 使用 sha256 内容寻址，事件只保存摘要、长度、contentType、原 blob 元数据和相对路径。
同一内容不重复落盘；过期 App blob 被导出前必须明确报告缺失，不能留下看似有效的空引用。

## 写入与恢复

- sequence 在单个 trace 内单调递增，append、flush 后才把事件视为已记录。
- manifest 使用临时文件 + 原子 rename 更新；events 尾部半行在读取时标记 `truncatedTail` 并忽略。
- `previousEventHash` 形成轻量 hash chain，用于发现手工截断或重排，不提供身份认证承诺。
- CLI 进程异常退出时，下一次 `show/stop` 将未闭合命令标为 `interrupted`，但不伪造 host 终态。
- launcher 重连后继续使用原 traceId，并新增 `session.observed`，不覆盖旧 session 事实。

## 记录边界与脱敏

- 请求参数按 descriptor 处理：sensitive 字段只记 `{redacted: true, source: stdin}`，不保存值或摘要。
- PB-040-22 响应 schema 增加可持久化/敏感元数据；未声明字段默认不落盘。
- 老 host 的自由 payload 默认只保存 admission、字段名集合、类型形状和 `legacyUnvalidated: true`；必须
  显式 `--include-legacy-payload` 才能保存值，并在终端二次提示。
- 网络认证头、query、body、wsUri 和本机绝对 workspace 路径永不进入 portable export。
- `trace export` 重新执行脱敏，而不是假定本地 trace 已经适合分享。

## 查看、导出与比较

`trace show` 默认展示命令级时间线，可展开 request/job/artifact。`--json` 输出稳定 trace envelope；
中断或缺失 artifact 必须显式呈现。

portable export 是带 manifest、events 和可选 artifacts 的版本化 bundle，导入时校验路径穿越、大小上限、
hash chain 和 schema。`trace diff` 先按命令名、descriptor digest 和相对顺序对齐，再比较 admission、稳定
code、执行分类、factSource、耗时区间和 artifact 摘要；不逐字节比较时间戳、requestId 或自由文本。

## 回放边界

PB-040-24 继续保留在 backlog，但不进入 0.4.0。具体前置与候选边界见
[未来回放 Proposal](../future/trace-replay.md)。0.4 CLI 不注册 `trace replay`，也不提供把历史事件直接
转换成写命令的隐藏入口。

## 预算与生命周期

- 默认按 trace 数、总字节和最长保留天数三重限制；达到上限先拒绝新 trace，不自动删除未导出的轨迹。
- `trace prune` 默认只删超过策略且已结束的轨迹，支持 `--dry-run`；活动轨迹和显式 pin 的轨迹不删。
- 单事件、单 artifact、单 bundle 和导入解压后的总大小均有硬上限。
- trace owner 锁带 PID 与创建时间，但 PID 存活只证明 writer 可能存在；过期锁需显式 recover。

## 兼容与依赖

- PB-040-23 可先记录 0.3.x host，但只得到 legacy payload 形状；稳定语义依赖 PB-040-22。
- session 跨断连延续依赖 PB-040-11；执行分类依赖 PB-040-21。
- 权限状态与系统弹窗只有在 PB-040-25/26 落地后才能形成完整 interruption 事件；此前 trace 必须标记
  `externalInterruptionUnknown`，不能把普通超时当成权限结论。
- audit sink 与 trace 共用事件投递接口：audit 是脱敏摘要投影，trace 是由操作者显式开启的详细时间线，
  两者不能各自拦截 CLI 再形成两套事实。
- VM/direct 写入相同事件 schema；transport 只作为事件字段，不改变命令结果。

## 验证

- 单测覆盖并发 writer、序号、原子 manifest、尾部半行、hash chain、资源上限和 prune dry-run。
- golden 覆盖 start → 多命令 → job → artifact → stop 的完整 NDJSON 与 portable export。
- 敏感值 mutation 测试证明 stdin、token、wsUri 和 legacy payload 默认不落盘、不进入 export。
- 0.3.x fixture 验证 legacy 形状；0.4 fixture 验证 response schema 与执行证据完整记录。
- launcher 断连/重连后 trace 连续，且 session 变化可见。
- 两个接入方分别完成一次真机轨迹导出与 diff；实际写回放需另做专项真机验收。

## 待裁决

- 默认保留天数、trace 数、总字节、单 artifact 与 bundle 上限。
- portable bundle 使用 zip 还是目录；无论选择哪种都必须保持同一逻辑 schema。

## 被否决方案

- 只保存 shell history：没有受理、job、证据、artifact 和版本上下文，也会泄露 sensitive 参数。
- host 侧作为唯一持久化位置：App 重启即丢失，且无法覆盖 session 切换和 CLI 本地失败。
- 默认保存所有自由 payload：在 response schema 和敏感元数据稳定前风险不可接受。
- 原样重放录制请求：旧 generation/session/requestId 会误击或制造假幂等。
