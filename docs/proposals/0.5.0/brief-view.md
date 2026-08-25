# 0.5.0 `--view brief` 瘦 JSON 视图

> 状态：提案中
>
> 关联：PB-050-21
>
> 设计闸门：无（opt-in 与「本版不翻转默认输出」已由 0.5.0 版本计划「能力批裁决记录」的附带小裁决
> 冻结；本文只补齐字段清单、投影规则与门禁，不重新裁决定性）

## 问题

`--json` 目前只有一个层级。`OutputFormatter.writeOutput` 对每条命令都用
`JsonEncoder.withIndent('  ')` 打印**完整响应信封**，`PatchbayReplSession._writeResult` 对每行都
`jsonEncode` 完整 `response`。机器消费方没有第二个选项：要么拿全量，要么不用 `--json`。

这在三处直接产生成本：

- `ui semantics tree` 的 payload 是 `PatchbaySemanticsSnapshotWire`，`nodes` 是整棵树的节点数组，
  每个节点带 `rect` / `transformToParent` / `flags` / `actions` / `children` 等 22 个键；
- `ui widget-tree` / `render-tree` / `focus-tree` 走 `_diagnosticEnvelope`，`data` 是 Flutter SDK 原样
  透传的诊断树，规模由 SDK 决定，CLI 侧没有任何裁剪；
- `catalog` 的 `commands[]` 是每条 descriptor 的完整 JSON（`summary` / `parameters` /
  `responseSchema` / `executionContract` / `retryPolicy`），而调用方在"要不要调这条命令"这一步
  只需要名字、模式、副作用和门。

Agent 消费方每次都要把这些整份读进上下文，然后才发现自己只需要"受理了没有、失败在哪一类、
下一步该带哪个围栏值"。0.5.0 的渐进式披露契约把 brief 定为**默认优先选择的观察层**，完整视图
留给"确实需要展开"的那一步；没有 brief，这条链在最后一跳断掉：Skill 说了"先读小的"，CLI 却只
提供大的。

同时，`--json` 是已经被脚本依赖的稳定输出。任何"顺手把默认变瘦"的做法都会静默改写既有消费方的
解析结果，因此本条只能是 opt-in，且默认路径必须逐字节不变。

## 目标与非目标

### 目标

- 新增全局 `--view full|brief`，`full` 为默认；不带 `--view` 与 `--view full` 的 stdout 逐字节相同。
- brief 是 `--json` 的**视图变体**，不是第二种输出格式：保留下来的每个键，键名、嵌套位置、类型和
  值的字节都与 full 相同；brief 只做删除，外加一个 CLI 自有的 `localView` 标记。
- 冻结一张封闭的**投影表**（删哪些路径、哪条命令族适用），并以成对 golden 锁定 full 与 brief。
- 让 brief 的缺字段**可分辨**：被删的路径在 `localView.omitted` 里逐条列名，读到的人不会把"被瘦身"
  误读成"App 没给"。
- REPL 单行契约不变；`--view` 可按行覆盖，使"展开完整视图"不需要另起一次连接。
- 与 PB-050-20 的大载荷 artifact 落盘形成明确先后关系，不产生两套"内容去哪了"的说法。

### 非目标

- 不翻转默认输出，不在本版把 brief 变成默认，也不提供环境变量把它变成本机默认。
- 不新增 `--brief` / `--short` / `--summary` 等别名，不新增 `--jsonl`，不新增第二套 schema 命令。
- 不改变 wire、host、descriptor、退出码、trace 记录、audit 投影、artifact 下载与校验。
- 不做"前 N 条"式数组截断：截断会让 `nodeCount` / `length` / `records` 之间互相说谎，而 patchbay
  已经有 `limit` / `nextCursor` / `truncated` 表达"还有更多"。
- 不做按字节阈值的动态裁剪。规模阈值属于 PB-050-20；brief 的删除必须是声明式、可复算、可 golden 的。
- 不在 brief 里重新汇总、改名、合并或计算任何 App 事实。人读摘要
  （`patchbayResponseSummary`）继续是唯一做"归纳"的地方，且不受本条影响。
- 不新增 `patchbay_cli` 的公共 Dart 符号：投影实现留在 `src/`，不进入 PB-050-13 / DG-050-07 冻结的
  2 + 8 清单。

## 契约

### 1. 语法位置：全局 option

`--view` 与 `--json` 同级，是**全局 option**，不是 per-command 参数：

```dart
..addOption(
  'view',
  allowed: <String>['full', 'brief'],
  defaultsTo: 'full',
  help: 'JSON view: full keeps every field, brief keeps the decision facts.',
)
```

理由：投影是"这次调用想看多少"，与命令语义无关；做成 per-command 会让同一个概念在每条命令的
descriptor 里各写一份，并且必须进 wire（host 并不需要知道 CLI 打印了多少）。`allowed` 让未知取值
在 `ArgParser.parse` 阶段抛 `FormatException`，沿既有路径变成 `usageError` / 退出码 64，无需新增
校验分支。

**`--view brief` 必须与 `--json` 同时出现**，否则是用法错误（`usageError`，退出 64）。人读摘要不是
brief 的另一种渲染；静默忽略会让调用方以为自己拿到了瘦视图。`--view full` 在无 `--json` 时是默认
值，不报错。

### 2. 投影门：只有成功的响应才允许瘦身

brief 只在**这条命令的退出码是 `PatchbayExitCode.accepted`（0）** 时投影；其余一律 identity
（等于 full，另加一个 `omitted` 为空的 `localView`）。判据直接取 CLI 已经算出的
`Outcome.exitCode` / `PatchbayReplOutcome.exitCode`，不重新推导。

这条门一次性覆盖所有"出事了"的路径，并且是本提案最重要的诚实边界：

- `admission == "rejected"`：`rejection.code` / `notice` / `details` 全保留。拒绝信封本来就是最小
  事实，`details` 里的 `sessions` / `oldestAvailableRevision` / `expected` 正是下一步要读的东西。
- `payload.outcome == "failed"`、`execution.classification` 为 `notSent` / `sentUnconfirmed`、
  job 终态 `failed` / `cancelled`：证据全保留。
- CLI 侧错误信封 `{"error":{"code","details"}}`：identity。它已经是最小形状。
- `localKeepAwake` 把退出码翻成 `typedFailure` 时：identity。

一句话：**brief 只敢瘦"这条命令成功了"的响应。**

### 3. brief 的两种删除操作

投影表里每条规则只允许两种操作，两种都是"删掉一个具名路径上的键"：

- **prune**：删除对象的某个键，包括数组元素内部的键（例如 `$.commands[].parameters`）。数组长度
  不变、元素顺序不变、其余键的值逐字节不变。
- **elide**：删除整个键（例如 `$.payload.nodes`）。不留空数组、不改类型、不放占位对象。

两种操作都**只对表中明确列出的路径生效**（deny-list，不是 white-list）。未在表中的键——包括老 host
返回的 legacy 字段、接入方自有 payload、未来协议新增字段——一律原样保留。白名单会让"App 明明给了
这个字段"变成"brief 里没有"，且调用方无法区分是被删还是没给；deny-list 的节省上限更低，但它不会
撒谎。

投影表的选择键是 **CLI 自己知道的 service command / 本地 target**
（`PatchbayFriendlyCommandRegistry.specFor(rest)`），不是"从 payload 形状猜"。`result.dart` 里
`patchbayResponseSummary` 对 `selection` 做形状匹配时已经留下判例：consumer 可以发布任何键名，
按形状猜会让一份 consumer JSON 冒充协议结构。

### 4. `localView` 标记

brief 文档在**顶层末尾**追加一个 CLI 自有对象，键集合恒定为四个：

```json
"localView": {
  "view": "brief",
  "projection": "ui.semantics.tree",
  "omitted": ["$.notice", "$.payload.nodes"],
  "expand": "--view full"
}
```

- `view` 恒为 `"brief"`；full 视图**不含** `localView`（默认输出逐字节不变的前提）。
- `projection` 是本次命中的规则集 id，未命中任何命令族规则时为 `null`。
- `omitted` 只登记**本次实际删除**的路径模式，按投影表中的固定顺序；空数组表示这份 brief 与 full
  只差 `localView` 本身。
- `omitted` 里写的是表中的**固定字面路径模式**，不是从实例解析出的具体路径。这既让它可 golden，
  也保证它永远不会把 consumer 的键名、目标 id 或会话信息带进输出。
- `expand` 恒为 `"--view full"`，不拼接完整命令行（那会把 `--ws-uri`、`--session` 带进 stdout）。

命名沿用 `localArtifact` / `localKeepAwake` 已有的 `local*` 约定：顶层的 CLI 自有字段用这个前缀
和 App 发布的状态区分。

`localView` 追加在末尾、其余键保持 full 的插入顺序，因此 brief 的字节是确定的、可 golden 的。

### 5. 冻结的投影表（0.5.0 范围）

表分两部分：一条对所有 App 响应信封生效的通用规则，加上按命令族的规则集。**本表即冻结清单，
新增任何一条都必须先改本 Proposal。**

#### 5.1 通用信封规则（`projection` 之外始终评估）

| 路径 | 操作 | 理由 |
|---|---|---|
| `$.notice` | prune | host 的人读句子。accepted 时决策事实已经在 `payload` 的类型化字段里；拒绝路径不走投影门，`rejection.notice` 一定保留 |

`schemaVersion` / `requestId` / `admission` / `jobId` / `payload` / `localArtifact` / `localKeepAwake`
**全部保留**：`requestId` 是与 trace、audit 对账的连接键；`jobId` 是下一条 `job get` 的入参；
`localArtifact` 是取件路径；`localKeepAwake` 能改变退出码。顶层本来就不胖，谎称在这里省了很多不诚实。

#### 5.2 `catalog`（`PatchbayFriendlyCommand.catalog`）

| 路径 | 操作 |
|---|---|
| `$.commands[].summary` | prune |
| `$.commands[].parameters` | prune |
| `$.commands[].responseSchema` | prune |
| `$.commands[].executionContract` | prune |
| `$.commands[].retryPolicy` | prune |

保留 `name` / `plane` / `mode` / `sideEffect` / `factSources` / `gates`：这六项回答"这条命令存在吗、
是不是写操作、要不要 `--wait`、过不过得了门"，正是"要不要调"这一步的最小事实。参数与响应 schema
的展开入口是既有的 `describe <service-command>`（PB-050-09 已保证它在 REPL 内也可用），不需要
brief 再复制一份。

`$.uiTargets[]` **不投影**：单行小，且 `generation` / `mounted` / `ambiguous` / `operationGates` /
`sensitivePolicy` 每一项都是写操作的前置事实，删任何一项都会让调用方少一次围栏。
`$.catalogDigest` 保留。

#### 5.3 `ui.semantics.tree`

| 路径 | 操作 |
|---|---|
| `$.payload.nodes` | elide |

保留 `outcome` / `source` / `treeRevision` / `rootNodeId` / `truncated` / `nodeCount`。
`nodeCount` 说明规模，`treeRevision` 说明这次观察的代际——它同时是"展开时重跑是否可比"的判据。

#### 5.4 Flutter 诊断树透传（`ui widget-tree` / `render-tree` / `focus-tree`）

这三条走 `PatchbayVmServiceClient._diagnosticEnvelope`，顶层文档是
`{source, plane, schema, extension, format, data, warnings}`，不是受理信封。

| 路径 | 操作 |
|---|---|
| `$.data` | elide |

保留 `source` / `plane` / `schema` / `extension` / `format` / `warnings`。
`warnings` 里那句"Flutter 诊断字段会随 SDK 变化"必须留着——它正是调用方决定要不要展开时该读到的。

**这一族有一个必须写清的坑**：非 debug 构建下这三棵树返回的是退 0 配**空 `data`**，不是拒绝。因此
`data` 为空与 `data` 被 elide 在 brief 里必须可分辨，而 `localView.omitted` 是唯一分辨手段：
elide 时路径在列表里，空 `data` 时不在。

#### 5.5 `logs.query`

| 路径 | 操作 |
|---|---|
| `$.payload.records` | elide |

保留 `outcome` / `source` / `nextCursor` / `currentCursor` / `truncated` / `truncation` / `elapsedMs`。
展开路径是既有的 cursor 翻页或 `logs export --output`，不是重跑一次 brief。

`logs.tail` **不投影**：它是 NDJSON 流，每一行就是调用方明确要的那条记录；把 `records` 删掉等于把
命令删掉。`logs.export` **不投影**：它的 payload 已经是 blob 元数据。

#### 5.6 明确冻结为"不投影"的命令族

以下不是遗漏，是裁决结果：

- **snapshot 家族**（`snapshot` / `snapshot --path` / `snapshot wait` / `snapshot diff`）：payload 就是
  被观察的状态本身，brief 无权替调用方决定哪部分状态与决策无关。规模问题由既有 `--path`（已经是
  一个精确的瘦身入口）与 PB-050-20 的阈值负责。
- **identity / describe**：identity 本来就小；`describe` 就是展开层，瘦它等于取消它。
- **job 事件**（`exec --wait` / `job get`）：版本计划已明确"现有每个 job 为 running 加一个终态"，
  `events` 有界且小；且它是失败诊断的第一现场。
- **UI 写操作与等待**（`ui text set|enter` / `ui tap` / `ui semantics action` / `ui gesture *` /
  `ui wait`）：payload 是 `targetId` / `generation` / `operation` / `length` / `dispatched` /
  `execution` 一类的定长事实，已经是 brief。
- **navigation 家族 / capture 家族 / blob 家族 / `perf profile` / `net profile` / `ui inspect` /
  `ui keep-awake`**：payload 定长或已由 host 汇总（`perf profile` 返回的是 `frames` / `heap` / `gc`
  的统计对象，不是事件流）。
- **本地文档**（`doctor` / `sessions list` / `session use` / `trace *` / `ui targets` /
  `ui verify-manifest` / `launch` 的 launcher 帧）：它们不是 App 响应，规模由本地保留策略决定。
  把它们纳入本表会让"brief 是响应视图"这条定义失焦；确有需要时另立条目。

### 6. REPL 下的行为

`--json repl` 的单行契约（PB-050-08）完全不变：每条结果仍是一个 LF 结尾的 compact JSON object，
终止错误仍走既有 error envelope 与退出码，stderr 仍只做人读诊断。

- 行包装键 `line` / `command` / `exitCode` / `response` **永不投影**：它们是行契约本身。
- 投影只作用于 `response`，`localView` 出现在 `response` 内部。
- `_writeFailure` 产生的 `{"line","command","exitCode","error"}` 是 identity（已经最小）。
- **`view` 不加入 `patchbayReplSessionOptions`**：那个集合的成立理由是"选择或配置传输"，per-line
  给了就只能靠重连兑现。`--view` 不碰传输，每行文档仍然独立可解析，因此允许按行覆盖。
- 两级默认：`patchbay --json --view brief ... repl` 设定本次会话的默认视图，行内 `--view full`
  覆盖单行。**这就是"何时展开完整视图"的实现路径**——展开不需要另起连接，也就不会改变会话所观察
  的那个 App 实例。

### 7. 与 PB-050-20 的接缝

两条命令族（semantics 树、Flutter 诊断树）会同时落在 brief 与 PB-050-20 的大载荷 artifact 上。
顺序冻结为：**先 PB-050-20 的阈值判定与落盘，再 brief 投影。**

- 超阈值时，PB-050-20 已经把大载荷换成校验路径（复用既有 `--output` / blob 形状）。brief 随后投影，
  **不得删除任何 artifact 指针键**（`localArtifact` 及 PB-050-20 冻结的等价字段）。此时
  `localView.omitted` 里不会出现 `$.payload.nodes` / `$.data`——因为它们已经不在文档里，登记它们
  等于报告一次没有发生的删除。
- 未超阈值时，brief 自己 elide。此时内容**没有**落盘，展开方式只有重跑 `--view full`
  （必要时配 `--output`）。这一点必须在 `--help` 和 Skill 里说清楚：重跑意味着重新观测，
  `treeRevision` / `generation` 可能已经变；brief 保留这两个围栏值正是为了让调用方能判断重跑是否可比。
- brief 不触发落盘、不改变 PB-050-20 的阈值、不改变 artifact 的 SHA-256 与长度校验。
- 两条独立回退：先回退哪一条，另一条都仍然成立。PB-050-20 尚未有 Proposal；本节是本条对它的接缝
  要求，需在 PB-050-20 的 Proposal 中对齐同一顺序，不得各写一套。

### 8. Skill 措辞接缝（PB-050-24）

`skills/use-patchbay/SKILL.md` 已经有一行"If output is large, prefer a CLI-advertised brief… Expand the
full payload only when the task requires it."。本条落地后，Skill 只需要保证三句事实，**不得复制字段
清单**（清单是本 Proposal 与 `--help` 的事实，复制就会漂移，也违反 planning.md 对 SKILL.md 的权责）：

1. 机器消费默认先取 `--json --view brief`；
2. brief 里少掉的字段一定在 `localView.omitted` 里列名，缺字段不等于 App 没给；
3. 需要完整内容时用 `--view full`（REPL 内可按行覆盖），并意识到重跑是一次新的观测。

Skill 的 starter command 生成块由 `command_docs --check` 对拍，`--view` 的拼写从 CLI registry 来，
不手写。

## 状态、失败与预算

本提案**不新增运行时状态、异步 job、超时、取消、重试或租约**。投影是一个纯函数：输入是 CLI 已经
持有的 `Map<String, Object?>` 与已经算出的退出码，输出是一个新 Map。

必须成立的不变量（全部可机检）：

1. **投影在退出码之后**。退出码由完整响应算出，投影不参与分类。
2. **投影不影响任何副作用**：trace 记录的是 CLI 收到的响应而不是打印的视图；audit 投影
   （`patchbayAuditExecutionClassification`）、artifact 下载与校验、keep-awake 续租、job 轮询
   全部发生在投影之前，且读的是完整响应。
3. **投影是纯删除**：brief 的键集合 ⊆ full 的键集合 ∪ `{localView}`；任何共有键的值 `jsonEncode`
   后逐字节相同。
4. **投影是全函数**：任何输入都不抛异常。遇到类型与预期不符的节点（例如 `commands` 不是数组），
   该规则**放弃删除**并如实不登记，不做任何猜测性改写。
5. **投影不删脱敏标记**：`redaction` / `valueRedacted` / `sensitive*` 一族的键不得出现在投影表中。
   这条由 ratchet 测试对表本身断言，不是靠人看。
6. **投影表是封闭常量**：表里每条规则都必须有对应 golden 对；每个 golden 对里出现的删除都必须能在
   表中找到依据。双向断言，新增删除无法只改代码。

预算：本条不引入内存或时间预算。投影一次遍历已解码的 Map，规模与它本来就要编码的文档同阶。

编码器策略：brief **复用当前视图的编码器**——one-shot 仍是 `JsonEncoder.withIndent('  ')`，REPL 仍是
compact `jsonEncode`。`--view` 只改字段投影，不改文档编码；把两件事绑在一个开关上会让"默认输出
逐字节不变"的验收多一个自由度（见「待裁决」）。

结构门禁：投影表与投影函数落在新文件 `packages/patchbay_cli/lib/src/output/brief_view.dart`，
按 `docs/code-structure.md` 属于"同构成员的集合"，应当摆在一起；`cli.dart` 与 `repl.dart` 各只增加
一处调用，不新增长函数、不抬高既有警戒线。

## 兼容与降级

**默认路径**：不带 `--view` 的所有输出逐字节不变。`--view` 是新增全局 option，`defaultsTo: 'full'`，
不改变任何既有参数解析、命令路径、退出码或 stderr 行为。老脚本零影响——它们连这个 option 存在
都不需要知道。

**新 CLI ↔ 老 host**：完全成立。brief 是纯 CLI 侧投影，host 不知道 `--view`，wire 上没有新增字段。
老 host 返回的 legacy payload 若不含表中路径，deny-list 自然不删；若含同名路径但类型不符，按不变量
4 放弃删除。0.4.1 复刻 reader 读 `--view full` 输出时看到的字节与今天相同。

**老 CLI ↔ 新 host**：不适用，本条不碰 host。

**VM Service ↔ direct**：投影发生在两条传输汇合之后（`Outcome` 层），两者共享同一份投影结果；
测试矩阵要求同一命令在两条传输上的 brief 逐字节一致。

**降级**：没有隐式降级。`--view brief` 在任何情况下都不会静默变回 full——不命中规则时它仍然输出
`localView` 且 `omitted` 为空，调用方能看出"这条命令本版没有瘦身规则"。反过来也没有隐式升级：
brief 不会因为文档小就省掉 `localView`。

## 安全与隐私

- brief **只删不增**，唯一新增的 `localView` 四个键全部是 CLI 自有的固定字面量：`"brief"`、
  规则集 id、表中固定路径模式、`"--view full"`。没有一处来自 App 响应、consumer 键名、URI、token、
  会话 id、设备标识或本地路径。
- `omitted` 刻意登记**路径模式**而不是实例路径，正是为了让"从未知数据构造输出"这条风险不存在。
- 投影表禁止包含脱敏标记键（不变量 5）。删掉 `valueRedacted` 会让一个被脱敏的值看起来像原值，
  这是本条唯一可能制造的安全退化，因此在表层面禁止，而不是在评审时提醒。
- `--view` 不改变 gate、声明门、sensitive stdin、release 裁除或 audit 记录。审计与 trace 看到的
  始终是完整响应。
- brief 不降低"证据"的等级：退出码、artifact SHA-256/长度校验、execution classification 都在投影
  之前确定，brief 只是少打印几个键。

## 验证

- **单元/协议测试**：
  - `--view` 缺省、`--view full`、`--view brief` 三种取值的解析；非法取值以 `usageError` / 64 退出；
    `--view brief` 无 `--json` 时以 `usageError` / 64 退出，`--view full` 无 `--json` 时不报错。
  - **默认不变**：对每条纳入 golden 的命令，断言不带 `--view` 与 `--view full` 的 stdout 逐字节
    相同，且与 0.4.1 语料相同。
  - **成对 golden**：`packages/patchbay_cli/test/golden/view_brief/<rule-set>.{full,brief}.json`。
    测试断言 (a) brief 键集合 ⊆ full 键集合 ∪ `{localView}`；(b) 共有键的值逐字节相同；
    (c) 键顺序与 full 一致、`localView` 在末尾；(d) `omitted` 恰好等于本次实际删除的路径模式集合。
  - **表 ↔ golden 双向 ratchet**：表中每条规则都有 golden 覆盖；golden 中每处删除都能在表中定位。
  - **表自身断言**：表中不出现 `redaction` / `valueRedacted` / `sensitive*` 键；不出现顶层
    `admission` / `requestId` / `jobId` / `rejection` / `localArtifact` / `localKeepAwake`。
  - **投影门**：rejection、`payload.outcome == "failed"`、`execution.classification` 为 `notSent` /
    `sentUnconfirmed`、job 终态 `failed` / `cancelled`、`localKeepAwake` 失败翻码、CLI 错误信封，
    每一类都断言 brief ≡ full + 空 `omitted` 的 `localView`。
  - **全函数**：畸形 / legacy / consumer payload（`commands` 不是数组、`payload` 不是对象、
    `nodes` 是字符串、未知顶层键）都不抛异常，且未列入表的键一个不少。
  - **不投影族**：snapshot 四种形态、identity、describe、job、UI 写操作、navigation、capture、blob、
    perf、本地文档，逐条断言 brief 与 full 只差 `localView`。
  - **REPL**：`patchbay --json --view brief ... repl` 的每行仍是一个 LF 结尾 compact JSON object，
    以逐行 `jsonDecode` 读到 EOF；行内 `--view full` 覆盖成功；`--view` 不被
    `_rejectSessionScopedOptions` 拒绝；usage 失败行仍是既有四键形状。
  - **副作用不变**：同一响应在 brief 与 full 下的退出码、trace 记录、audit classification、
    `localArtifact` 的 SHA-256 与长度完全相同。
- **VM/direct**：同一命令在 VM Service 与 direct 两条传输上的 brief 输出逐字节一致；
  跨进程测试各跑一遍 brief。
- **接入方/真机**：`tool/example_precheck.sh` 的 debug 主链增加一次 `--view brief` 的
  semantics 树与 catalog 读取，证明 brief 的 `nodeCount` / `treeRevision` 与同一会话内
  `--view full` 的值一致；`tool/example_profile_smoke.sh` 在 profile 下断言三棵诊断树
  **空 `data`** 与 **elided `data`** 在 brief 里可分辨（前者 `omitted` 不含 `$.data`）。
  本条不需要额外真机能力，随 0.5.0 固定候选 SHA 完成既有退出条件。
- **失败注入**：传输中断、protocol 错误、session 歧义、job 等待超时、artifact 下载失败——
  每一类都断言 brief 路径与 full 路径产生同样的错误信封、同样的退出码，且错误信封不带 `localView`。

## 待裁决

1. **brief 是否改用 compact 编码器**。本文建议**不改**：`--view` 只投影字段，编码策略保持
   one-shot pretty / REPL compact。若仓主认为 one-shot brief 也应 compact（缩进在大文档上确实是
   真实占比），需要接受"一个开关改两件事"，并在 golden 中额外冻结编码形态。
2. **`$.notice` 是否该删**。它是本表唯一一条通用规则，收益小；保留它可以让"通用层不做任何删除、
   一切删除都属于某个命令族"这条规则更干净。两种都可接受，请裁决。
3. **`catalog` 的 `$.commands[].summary` 是否保留**。删掉最省字节，但 `summary` 是 Agent 在没有
   `describe` 之前判断"这条命令是干什么的"的唯一线索。若仓主认为 catalog brief 应当仍然可读，
   把 `summary` 移出投影表。
4. **是否需要为本条新开一个 DG**。本文认为不需要：opt-in 与不翻默认已由版本计划附带小裁决冻结，
   剩下的都是清单粒度问题。若仓主希望字段清单本身走正式闸门，请给号并同步 backlog。

## 被否决方案

- **把 brief 做成默认，`--view full` 用于展开**：直接违反"默认输出逐字节不变"，会静默改写所有既有
  `--json` 消费方的解析结果。
- **白名单式投影（只保留清单内的键）**：省得最多，但会把老 host 的 legacy 字段、接入方自有 payload
  和未来协议新增字段一起吞掉，且调用方无法区分"被删"与"没给"。brief 的正确性判据是不撒谎，不是最小。
- **数组截断（保留前 N 条 + `truncated: true`）**：会让 `nodeCount` / `length` / `records.length`
  互相说谎，并与既有 `limit` / `nextCursor` / `truncated` 语义重叠——同一个词在同一份文档里会有两种
  含义。
- **按字节阈值动态裁剪**：结果随运行数据漂移，无法 golden，也与 PB-050-20 的阈值职责重叠，
  会产生两套"内容去哪了"的说法。
- **brief 输出一份 CLI 自有的封闭信封（重命名、重组、只留摘要）**：那是第二套格式。两套格式意味着
  两套 schema、两套 reader、两份兼容承诺，与"不造第二套输出"的既定口径冲突；也会让"brief 里的值
  是不是 App 说的"变成一个需要查文档才能回答的问题。
- **per-command 的 `--brief` 参数或 descriptor 声明**：会把一个纯输出关注点写进 wire 与每条
  descriptor，host 因此需要知道 CLI 打印了多少；而且每条命令各写一份，必然漂移。
- **新增 `--summary` / `--short` / `--jsonl` 一类别名**：版本计划已明确不新增 `--jsonl`，也不维持
  两套同义命令；`--view` 一个 option 承载全部取值即可。
- **在 REPL 里把 `--view` 也做成会话级不可覆盖**：会让"展开完整视图"必须另起一次连接，
  而换连接就是换一次观测，正好毁掉 brief 想保住的可比性。
