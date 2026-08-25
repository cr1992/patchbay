# 0.5.0 树类大载荷落 artifact

> 状态：提案中
>
> 关联：PB-050-20
>
> 设计闸门：无

## 问题

树类命令把全量结果直接写进 stdout，没有任何按需展开的中间层。

`ui.semantics.tree` 的 `maxNodes` 默认 1000、`maxDepth` 默认 64
（`packages/patchbay/lib/src/ui_protocol_commands.dart`），每个 `PatchbaySemanticsNodeWire` 有 22 个字段，
含 `rect`、`transformToParent`、`flags`、`actions`、`scrollExtent*`。一棵满额树的 `--json` 输出经
`JsonEncoder.withIndent('  ')`（`packages/patchbay_cli/lib/src/output/output_formatter.dart`）放大后即数千行。

三棵 Flutter 诊断树更大且完全不受 Patchbay 参数约束：`ui widget-tree` 以
`isSummaryTree/withPreviews/fullDetails` 全开调用 `ext.flutter.inspector.getRootWidgetTree`，
`ui render-tree` / `ui focus-tree` 是整份文本 dump（`packages/patchbay_cli/lib/src/client.dart`）。它们的
体量只取决于被调 App 的界面规模。

CLI 其实已经有一条经过验证的落盘链路：`capture root|target --output`、`blob get --output`、
`logs export --output` 走 `PatchbayArtifactDownloader`——分块 `blob.read`、base64 解码、逐块契约校验、
长度与 SHA-256 校验、临时文件加 `rename`，成功后把 `localArtifact` 并进响应
（`packages/patchbay_cli/lib/src/artifact_download.dart`、`packages/patchbay_cli/lib/src/cli.dart`）。

但这条链路只对 **host blob** 生效。树类命令的载荷从来不是 blob，`--output` 对它们当前直接被拒：
`--output is not valid for this command`（`packages/patchbay_cli/lib/src/registry/friendly_command_registry.dart`）。
于是接入漏斗的第 5 层「完整参考」没有入口，agent 消费方只能一次性把整棵树吃进上下文，
渐进式披露在最需要它的地方失效。

## 目标与非目标

### 目标

- 覆盖命令的输出超过阈值时落本地 artifact，stdout 只保留可校验回执与决策所需的有界事实。
- 阈值内的 stdout 逐字节不变，`--json` 与人读两条渲染路径都不变。
- 复用既有 `--output` / `--force` / `localArtifact` / trace 附件形状，不新增命令、别名或第二套落盘概念。
- 判定完全在 CLI 侧，因此 VM Service 与 direct 两传输的结果一致且无需 host 改动。
- 落盘失败如实报错并非零退出，绝不静默回退成把大载荷内联进 stdout。

### 非目标

- 不改 host、command descriptor、wire 类型、`schemaVersion` 或任何稳定 JSON 的 host 侧形状。
- 不新增 CLI 命令或路径别名（与 0.5.0 版本计划「不再新增 `ui capture` / `--out` 别名」同一立场）。
- 不把阈值判定放进 host（论证见「契约 / 判定位置」）。
- 不解决 direct 传输 `maxResponseBodyBytes` 默认 1 MiB 的应答上限
  （`packages/patchbay_transport/lib/src/direct_client.dart`）；那是本条之前就存在的边界，见「兼容与降级」。
- 不做字段裁剪或瘦视图，那是 PB-050-21。
- 不解析载荷语义、不生成节点统计或结构摘要；CLI 只搬字节。
- 不给未列入覆盖清单的命令增加通用落盘能力。

## 契约

### 判定位置：CLI 侧

阈值判定与落盘全部发生在 CLI，理由是四条，不是偏好：

1. 要解决的问题是 **stdout 与 agent 上下文**，而 stdout 只有 CLI 拥有。
2. 覆盖清单里四条命令有三条**根本不经过 host**：`ui widget-tree` / `render-tree` / `focus-tree` 是
   VM Service SDK 透传，direct 传输上直接 `flutterDiagnosticUnavailable`
   （`packages/patchbay_cli/lib/src/direct_connection.dart`）。host 侧判定对它们在结构上不可能生效。
3. host 侧落 blob 会**同时改变老 CLI 看到的应答**：新 host 对老 CLI 会在原本是树的位置返回 blob 元数据，
   这是一个老 reader 无法感知也无法升级的静默破坏。CLI 侧判定天然按版本 opt-in——只有新 CLI 改变它自己打印的东西。
4. CLI 侧不需要任何 descriptor / wire 变更，因此不触碰
   `protocol_surface_golden_test.dart` 的 `strictlyDecodedByShippedClients` 名单。

由此，VM 与 direct 的一致性是构造性的：host 对 `ui.semantics.tree` 的应答在两个传输上本就相同，
落盘判定发生在应答之后，两传输因此得到同一阈值、同一判定、同一份 stdout 字节。

### 覆盖清单与判据

一条命令进入覆盖清单必须同时满足三条：

1. **结构上无界**——响应体量随被调 App 的界面规模增长，而不是随一组固定字段增长；
2. **只读观察**——落盘不会藏起任何 mutation 的结果；
3. **不是失败诊断本身**——失败与拒绝永远内联（见「状态、失败与预算」）。

0.5.0 的覆盖清单：

| CLI 路径 | 事实来源 | 无界成员（dot path） | artifact 形态 |
|---|---|---|---|
| `ui semantics tree` | `ui.semantics.tree` | `payload.nodes` | JSON 数组 |
| `ui widget-tree` | `ext.flutter.inspector.getRootWidgetTree` 或 `ext.flutter.debugDumpApp` | `data` | JSON 或文本 |
| `ui render-tree` | `ext.flutter.debugDumpRenderTree` | `data` | 文本 |
| `ui focus-tree` | `ext.flutter.debugDumpFocusTree` | `data` | 文本 |

**三棵 SDK 诊断树纳入的论证。** 它们是 CLI 能打印的最大输出，也正是 semantics 树不够用时 agent 会去调的
下一步；把它们排除在外，等于在最坏情况下继续没有漏斗。它们的 SDK schema 不稳定并不构成障碍：CLI 从不
解析 `data` 的内部结构，只测量与搬运字节；包住它的信封
（`source` / `plane` / `schema` / `extension` / `format` / `warnings`）由 CLI 自己构造
（`client.dart` 的 `_diagnosticEnvelope`），是 CLI 拥有的常量，不会随 Flutter SDK 漂移。因此
「无界成员 = `data`」这条指针本身就是 CLI 侧事实。它们同时是「判定必须在 CLI」的决定性论据。

`snapshot`、`catalog`、`doctor`、`sessions list`、`trace show`、`ui verify-manifest` 报告与全部 consumer
domain 命令**不在**覆盖清单内：它们要么字段有界，要么其输出本身就是诊断。

### 声明形状

无界成员按命令声明一条 dot path，沿用 `snapshot --path <dot.path>` 已有的点号路径习惯，也沿用
`PatchbayArtifactDisposition.payloadBlob` 已经在做的「声明式指针」模式——那个枚举值的含义正是
「blob 元数据在 `payload.blob`」。本条只是把同一模式用在渲染层：

```dart
enum PatchbayArtifactDisposition { none, payloadBlob, responseBlob, renderedMember }

abstract interface class PatchbayFriendlyCommandSpec {
  // ...
  /// 该命令响应里唯一无界的成员；`null` 表示不参与落盘。
  String? get spilledMember; // 'payload.nodes' | 'data'
}
```

`spilledMember` 只对覆盖清单四条命令非空。指针必须指向一个**存在的**成员；成员缺失时不落盘、
按内联渲染（等价于 0.4.1 行为）。

### 阈值

**计量对象是这次调用本来要写进 stdout 的那份文档的 UTF-8 字节数**，而不是 wire 应答字节数。四种渲染模式
各自计量自己那份文档：

| 模式 | 被计量的文档 |
|---|---|
| one-shot `--json` | `JsonEncoder.withIndent('  ').convert(response)` + `\n` |
| one-shot 人读 | `patchbayResponseSummary(response)` + `\n` |
| REPL `--json` | `jsonEncode({line, command, exitCode, response})` + `\n` |
| REPL 人读 | `[<n>] exit=<code> <summary>` + `\n` |

这条口径的直接后果是：同一棵树在缩进 JSON 下比在 REPL 紧凑单行下更早越过阈值。这是**正确的**——缩进
JSON 确实更贵，阈值衡量的就是实际占用的上下文。此事必须写进 help，不能让调用方以为两条路径同点触发。

- 默认阈值 `65536` 字节（64 KiB），与 `PatchbayArtifactDownloader.defaultChunkBytes` 同一常量量级。
- 可参数化：`--max-inline-bytes <n>`，只对覆盖清单四条命令合法（进 `friendlyOptions` 与这四条的
  `allowedOptions`）。
- `--max-inline-bytes 0` 表示**不设内联上限**，即完全关闭落盘、逐字节回到 0.4.1 输出。取 nginx
  `client_max_body_size 0` 的读法；「总是落盘」不需要用 0 表达，因为 `--output` 已经就是那个开关。

### `--output` 显式给出时的行为

覆盖清单四条命令的 `--output` / `--force` 从「不合法」变为合法：

- 显式 `--output <path>`：**无条件**把无界成员写到该路径，与阈值无关；stdout 拿到同一份回执。
- `--force`：语义与 `capture` / `blob get` 完全一致；现有 `--force requires --output` 规则不变
  （自动落盘的文件名唯一，不需要 `--force`）。
- 父目录不存在、目标已存在且无 `--force`：复用 `PatchbayArtifactDownloader` 现有的两条
  `FormatException` 文案与 usage 退出码，不新增措辞。
- 非覆盖命令传 `--output` 仍然报 `--output is not valid for this command`，文案不变。

### 落盘路径与命名

自动落盘目录沿用仓内既有的两条目录约定（`PATCHBAY_SESSION_DIR`、`PATCHBAY_TRACE_DIR` 与
`$HOME/.patchbay/traces/v1`）：

1. `PATCHBAY_OUTPUT_DIR` 非空则用它；
2. 否则 `$HOME/.patchbay/outputs/v1`；
3. `HOME` 未设置且未给覆盖变量时，不猜路径，按 `localArtifactWriteFailed` 拒绝。

文件名：`<yyyyMMddTHHmmssZ>-<pid>-<command-slug>-<sha256 前 16 位>.<json|txt>`，
例如 `20260825T101500Z-4211-ui-semantics-tree-3f2a…c19b.json`。它只由时间、进程号、命令路径 slug 与内容
摘要构成，不含 identifier、label、target id、应用名或任何被调 App 的词汇。

写入顺序复用现有落盘链路：`createRestrictedFileSync` 建 0600 临时文件 → 写字节 → flush/close →
**重读文件计算 SHA-256 并与内存字节摘要比对** → `rename` 到最终路径。比对失败即
`localArtifactVerifyFailed`，临时文件删除，不留半份产物。因此回执里的 `verified: true` 与 blob 路径含义
一致：报告的摘要就是磁盘上字节的摘要，调用方可以用 `shasum -a 256` 独立复核。

artifact 内容规则：

- 无界成员是 JSON 值（`payload.nodes`、inspector 的 `data`）→ 写它在**不落盘时本会得到的渲染字节**，
  content type `application/json`，扩展名 `.json`；
- 无界成员是 JSON 字符串（`debugDumpApp` / `debugDumpRenderTree` / `debugDumpFocusTree` 的 `data`）→ 写
  **解码后的文本**，content type `text/plain; charset=utf-8`，扩展名 `.txt`。

第二条不是可选的润色：把一份文本 dump 以 JSON 字符串形式（带引号和 `\n` 转义）落盘，对人和对 `grep`
都不可用，等于落了个假 artifact。

### stdout 回执形状

无界成员被**就地替换**为回执，同时在顶层写入同一个 `localArtifact` 对象（构造上是同一个不可变 map）。
就地替换让「树在哪儿」这个问题在原位就有答案；顶层 `localArtifact` 让既有工具与
`patchbayResponseSummary` 的人读行零改动继续工作。

`ui semantics tree` 超阈值时的 `--json` stdout：

```json
{
  "requestId": "…",
  "admission": "accepted",
  "payload": {
    "outcome": "observed",
    "source": "uiObserved",
    "treeRevision": 87,
    "rootNodeId": 1,
    "truncated": false,
    "nodeCount": 812,
    "nodes": {
      "path": "/…/.patchbay/outputs/v1/20260825T101500Z-4211-ui-semantics-tree-3f2a….json",
      "length": 812345,
      "sha256": "…",
      "contentType": "application/json",
      "origin": "cliRendered",
      "verified": true
    }
  },
  "localArtifact": { "…": "同一对象" }
}
```

字段名与 `PatchbayDownloadedArtifact.toJson()` 完全一致，只有两点差别：新增 `origin`
（`hostBlob` | `cliRendered`）作为判别符；`cliRendered` 没有 `blobId`，因为不存在 host blob——不编造一个。
`origin` 对既有 blob 路径同样写入，使一个 reader 一套判据。两种形态不会出现在同一条命令上：
`capture` / `blob get` / `logs export` 永远是 `hostBlob`，覆盖清单四条永远是 `cliRendered`。

关键性质：`treeRevision`、`rootNodeId`、`nodeCount`、`truncated` 这些**下一步需要的有界事实留在 stdout**。
agent 拿到 stdout 就能决定是展开文件、换 `--path` 精查，还是直接用 `treeRevision` 去派发动作，不必为了
迈出下一步先把整棵树读回上下文。

人读路径无需任何新格式：`patchbayResponseSummary` 命中顶层 `localArtifact` 时已经输出
`artifact=<path> length=<n> verified=true`。

REPL 同样适用：计量整行、落盘无界成员、`line` / `command` / `exitCode` 原样保留在 stdout，
PB-050-08 承诺的「每条结果一行 LF 结尾 compact JSON」不变。

### 与既有 blob 链路的复用点

| 复用点 | 位置 |
|---|---|
| `PatchbayArtifactDisposition` 增第三态，不另起并行概念 | `registry/command_spec.dart` |
| `ArtifactRequest` / `ExecutionResult.artifact` 传递 `--output` / `--force` | `output/output_formatter.dart` |
| 「只有 accepted 才产出 artifact」的判据 | `cli.dart` 现有 artifact 分支 |
| 临时文件 + `rename` + 失败清理、`_DigestSink` 计算摘要 | `artifact_download.dart` |
| `localArtifact` 键、字段名与人读摘要行 | `result.dart` |
| trace 附件：`attachArtifact` 的 `blobId` **已经是可选参数** | `trace/trace_recorder.dart` |
| 单份 artifact 硬顶 64 MiB，与 `maxArtifactBytes` / `patchbayTraceMaxArtifactBytes` 同值 | 同上 |

`blob get --output`、`capture` 与 `logs export` 的行为、JSON 与退出码本条一律不动。

### Skill 与 help 接缝

- `skills/use-patchbay/SKILL.md`（PB-050-24 已合入）现有的
  「If output is large, prefer a CLI-advertised brief, path selection, output file, or artifact flow.」
  就是本条的接缝，**不新增章节**。落地后只需保证这句在语义上覆盖「结果位置 + 下一步」，并且 Skill
  **不写**阈值数字、目录路径或文件名规则——那些是 help / registry 持有的实时事实，写进 Skill 就会漂移。
- Skill 明确不得把 artifact 内容重新内联回上下文；正确的下一步是 `--path` 精查、换更小的
  `maxNodes` / `maxDepth`，或用外部工具读文件。
- CLI help：四条覆盖命令各加一行说明，形状照抄 `command_help.dart` 里 `ui.capture` 已有的
  `_writeDiscoverabilityNotes` 判例（列出安全落盘入口）。阈值数字由常量渲染，不手写。
- help 必须写明「缩进 JSON 与 REPL 紧凑行的触发点不同」，以及 `--max-inline-bytes 0` 是回到旧输出的出口。

## 状态、失败与预算

**只有被 App 接受的响应才落盘。** 判据直接复用现有 artifact 分支的
`patchbayExitCodeFor(response) == PatchbayExitCode.accepted`。拒绝、`outcome: failed`、
`classification: notSent|sentUnconfirmed` 一律**原样内联**：这些响应本来就小，而且它们就是诊断本身，
把诊断藏到文件后面正好是错的方向。

**退出码在落盘之前定。** 先用未落盘的完整响应分类，再落盘，再渲染。落盘因此在任何情况下都不能改变
分类结果。

失败一律显式，全部映射到既有的 `PatchbayArtifactDownloadException` 家族与 `PatchbayExitCode.protocol`
（4）——「artifact 没能产出」今天就是这样分类的（`blobIntegrityMismatch` 等同路），本条不发明新的退出码。
三个新 code 需要进 `error_code_registry_ratchet_test.dart` 的封闭注册表：

| code | 触发 |
|---|---|
| `localArtifactWriteFailed` | 目录不可用（含 `HOME` 未设置）、创建/写入/`rename` 失败 |
| `localArtifactVerifyFailed` | 写后重读的 SHA-256 与内存字节摘要不符 |
| `localArtifactTooLarge` | 无界成员渲染字节超过单份 64 MiB 硬顶 |

任何一种失败都**不得**退化为把大载荷打进 stdout，也不得把它悄悄丢弃后打印一份「成功」的瘦响应。

预算与上限：

- 阈值默认 64 KiB，可由 `--max-inline-bytes` 收紧或关闭；
- 单份 artifact 硬顶 64 MiB；
- 自动落盘目录保留策略：写入前机会性淘汰，保留 7 天以内且总量不超过 128 MiB，**永不删除本次运行写入的
  文件**；显式 `--output` 的路径由调用方拥有，CLI 不淘汰；
- 一次调用最多产出一份 artifact，无重试、无并发、无网络往返——全部字节已经在内存里；
- 落盘不引入新的 host 往返，不改变任何 deadline 或 wait 预算。

## 兼容与降级

- **新 CLI ↔ 老 host**：无影响。CLI 不发送新参数、不读取新字段、不要求任何 capability。
- **老 CLI ↔ 新 host**：无影响。host 侧零改动。
- **VM Service ↔ direct**：`ui.semantics.tree` 的 host 应答在两传输上相同，落盘判定在其之后，因此同阈值
  同判定同字节。三棵诊断树在 direct 上继续 `flutterDiagnosticUnavailable`；那是拒绝，拒绝不落盘，
  两传输的差异因此没有被本条放大。
- **direct 的 1 MiB 应答上限**：`PatchbayDirectClient.maxResponseBodyBytes` 默认 1 MiB，超限在 CLI 拿到
  任何字节之前就是 `responseTooLarge`。CLI 侧落盘**不能**修复这一点，也不假装修复。这是本条之前就存在的
  边界，如实记入非目标与待裁决；真要解决只能走 host 侧 blob，那是独立的 wire 变更与独立闸门。
- **阈值内逐字节不变**：这是硬验收，由 0.4.1 golden 对拍锁定，`--json` 与人读两条路径都锁。
- **超阈值行为变化的回退出口**：`--max-inline-bytes 0` 使输出逐字节回到 0.4.1。这是本条唯一改变默认输出
  的地方，与 PB-050-21 的 brief 为 opt-in 是**有意的差别**：PB-050-20 的验收就是「阈值内不变」，即默认
  行为在超阈值时按设计改变。
- **回退边界**：按 0.5.0 版本计划，PB-050-20 独立回退且不影响既有输出字节；回退只需移除
  `renderedMember` 分支与四条命令的 `spilledMember` 声明，blob 链路与 `blob get --output` 不受牵连。

## 安全与隐私

- artifact 内容与 stdout 内容**同源同脱敏**：本条不新增任何绕过脱敏的路径。semantics 节点 `value` 的
  `valueRedacted` 由 host 决定，CLI 只搬字节；落盘不会让一份原本被脱敏的值变成明文。
- 文件以 `createRestrictedFileSync` 建为 0600，与 session 记录同一等级。
- 文件名只含时间、pid、命令 slug 与内容摘要前缀；不含 identifier、label、target id、应用 ID、包名、
  域名或任何接入方词汇。
- 默认目录在 `$HOME/.patchbay/outputs/v1`，不落在工作目录，避免误入被 git 追踪的路径。
- 回执里的 `path` 是本机绝对路径：**不得**写进 MR 描述、仓内 fixture 或 golden；测试一律用临时目录并对
  路径做占位替换。
- trace 附件复用 `trace export` 既有的再脱敏边界，不新增导出面。
- release 裁除不适用：本条全部代码在 CLI，不进 App 构建。

## 验证

- **单元/协议测试**：
  - 阈值边界三点：`threshold - 1` / `threshold` / `threshold + 1`；前两点必须逐字节等于 0.4.1 golden。
  - 四条覆盖命令各两份 golden：内联与落盘。
  - 落盘后的 stdout 文档必须小于阈值——这条断言防止 `spilledMember` 指错成员。
  - artifact 字节必须等于「不落盘时该成员的渲染字节」；JSON 成员走 `application/json`，字符串成员走
    解码文本与 `text/plain; charset=utf-8`，两种都必须有用例（同一 `ui widget-tree` 命令在
    inspector 可用与仅 `debugDumpApp` 两种路径下分别命中）。
  - 回执 `sha256` 必须等于磁盘字节的摘要（用例自行 `sha256` 复核，不信任 CLI 自报）。
  - `--max-inline-bytes 0` 输出与 0.4.1 golden 逐字节相同。
  - 显式 `--output`：任意大小都落盘；`--force` 覆盖；父目录缺失与已存在无 `--force` 的既有文案不变。
  - 非覆盖命令传 `--output` 仍报既有错误，文案与退出码不变。
  - 拒绝、`outcome: failed`、`notSent` / `sentUnconfirmed` 一律不落盘且退出码不变。
  - `spilledMember` 指向的成员缺失时按内联渲染，不报错。
  - REPL：结果仍是单行 LF 结尾 compact JSON，`line` / `command` / `exitCode` 保留；落盘文件内容为该无界
    成员，PB-050-08 的按行 parser 用例继续全绿。
  - 顶层 `localArtifact` 与就地回执必须是同一对象（golden 断言相等）。
- **VM/direct**：
  - 同一棵 semantics 树经 VM 与 direct 两条连接，落盘判定、artifact 字节与 stdout 逐字节一致。
  - direct 下三棵诊断树仍 `flutterDiagnosticUnavailable`，不产出任何文件。
  - direct 应答超 `maxResponseBodyBytes` 时仍是 `responseTooLarge`，用例明确冻结「本条不修复该边界」。
- **接入方/真机**：
  - `tool/example_precheck.sh` 的 debug 主链跑一次超阈值 `ui semantics tree` 与三棵诊断树，验证 stdout
    明显变短、文件存在且 `shasum -a 256` 与回执对上。
  - `tool/example_profile_smoke.sh` 只验答复形态：profile 下三棵诊断树返回退 0 配空 `data`，因此**不应**
    落盘；用例断言这一点，避免把「空树也落盘」当成覆盖。
  - 业务真机验收在 example 预检通过之后进行，不以预检替代。
- **失败注入**：目录不可创建、写入中途失败、`rename` 失败、写后重读摘要不符、单份超 64 MiB、
  `HOME` 未设置且未给 `PATCHBAY_OUTPUT_DIR`。每一项都必须非零退出，且 stdout 不得出现大载荷、也不得
  出现声称成功的回执。

## 待裁决

1. 默认阈值 `65536` 字节是否合适；是否需要按 `--json` 与人读两条路径给不同默认值。
2. `--max-inline-bytes 0` 读作「不设内联上限」是否接受；若不接受，需要另一个显式关闭开关，
   本 Proposal 不愿意为此新增第二个 flag。
3. 自动落盘目录的保留策略数值（7 天 / 128 MiB），以及是否需要一条 `patchbay outputs prune`
   与 `trace prune` 对齐；本 Proposal 默认建议不加命令，只做写入前机会性淘汰。
4. direct 的 `maxResponseBodyBytes` 是否在本版提高或参数化；默认建议不动，留给独立闸门。
5. 三个新 error code 进封闭注册表与 PB-050-23 的先后顺序（PB-050-23 是纯测试 MR，两者需要约定谁先合）。

## 被否决方案

- **host 侧判定并落 blob**：三棵诊断树根本不经过 host，覆盖不到；且会让新 host 对**老 CLI** 在原本是树的
  位置返回 blob 元数据，构成老 reader 无法感知的静默破坏；还需要新 wire 形状与新失败面。
  它是 direct 1 MiB 上限的唯一正解，但那是另一个问题、另一个闸门。
- **整份响应落盘、stdout 只留回执**：规则最简单，且能保证「文件内容等于旧 stdout」，但 stdout 会同时失去
  `treeRevision` / `rootNodeId` / `nodeCount`——agent 为了迈出下一步必须先把文件读回上下文，正是本条要修的
  漏斗断裂。因此选择就地替换无界成员。
- **对所有命令按大小自动落盘**：不需要维护清单，但会在 `catalog`、`snapshot`、`doctor`、`trace show`
  与全部 consumer domain 命令上无差别改变默认行为，并把诊断藏到文件后面，远超 PB-050-20 的范围。
- **用环境变量控制阈值**：会让 stdout 形状依赖运行环境，golden 从此不可复现；目录位置可以走环境变量
  （已有 `PATCHBAY_SESSION_DIR` / `PATCHBAY_TRACE_DIR` 判例），输出形状不可以。
- **新增 `ui tree dump` / `--out` 之类的落盘专用入口**：与 0.5.0「不再新增同义命令与别名」的既有结论直接
  冲突，也会制造两套并行的落盘概念。
- **CLI 侧截断输出（打印前 N 行并标注 truncated）**：破坏 JSON 有效性，被截掉的部分不可恢复也不可校验，
  等于用一份不完整的证据冒充完整答复。
- **把 `ui.semantics.tree` 的 `maxNodes` 默认值调小**：那改的是 host 的观察语义与既有输出字节，
  是另一类破坏；本条只处理输出层，不动观察层。
