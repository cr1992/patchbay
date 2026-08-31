# 0.6.0 Descriptor 驱动的输出投影

> 状态：已接受
>
> 关联：PB-050-40
>
> 设计闸门：DG-060-03（已裁决）

## 问题

`--view brief`、树类大载荷落 artifact 与完整输出已经证明同一事实需要多层投影，但字段选择分散在 CLI 的
brief rule、artifact disposition、friendly command、help 与 golden。新增一种大响应必须在多处重复登记，
descriptor 不知道自己的稳定机器投影，声明真源与呈现真源分离。

## 目标与非目标

### 目标

- 由 descriptor 声明 full、brief 与 artifact-safe 机器投影；CLI/REPL/one-shot 使用同一解释器。
- 新协议命令只登记一次投影事实，不再同时扩 CLI brief 表、artifact disposition 与路径特例。
- 对同一份 0.5.x descriptor-less 输入保持有效 brief 输出逐字节不变，并给老 host 稳定 fallback。

### 非目标

- 不把人读文案冻结成稳定协议，不改变 consumer payload 的事实值。
- 不让 descriptor 指定任意本机输出路径、模板代码或可执行 formatter。
- 不移除现有大小、SHA-256、分块、原子写和覆盖写保护。
- 不把 brief 当作脱敏或授权边界；可投影响应必须先通过既有 schema 校验与脱敏边界。

## 裁决摘要

1. `outputProjection` 作为 command descriptor 的**可选松读字段进入 catalog wire**，`schemaVersion`
   仍为 `1`。老 reader 忽略它；VM Service 与 direct 返回同一声明。
2. brief 沿用 0.5.0 已冻结的**删除清单**，不改成保留清单。删除清单由 descriptor 携带，未来字段默认
   保留；安全与隐私由投影前的 schema/脱敏负责，不能借 brief 补救未校验响应。
3. 每条命令至多声明一个 artifact。artifact 只允许 `renderedMember`、`payloadBlob`、`responseBlob`
   三种既有语义；不允许多 artifact、任意路径、模板或 formatter。
4. full 是恒等投影；artifact 在 brief 之前执行；brief 只裁 accepted 响应，拒绝、typed failure 与本地
   error 保留完整事实。
5. 人读 summary 继续由 CLI 自由渲染，不进入 wire，也不是稳定 JSON。

## Wire 契约

`PatchbayCommandDescriptor.toJson()` 可追加下列对象；字段缺失表示 descriptor-less legacy，不表示空投影：

```json
{
  "outputProjection": {
    "brief": {
      "id": "ui.semantics.tree",
      "omit": ["$.payload.nodes"]
    },
    "artifact": {
      "kind": "renderedMember",
      "member": "$.payload.nodes",
      "encoding": "json",
      "mediaType": "application/json",
      "extension": "json",
      "automaticSpill": true
    }
  }
}
```

`outputProjection` 只允许 `brief`、`artifact` 两个键，二者都可省略，但对象不能两者都省略。对象与嵌套
对象上的未知键、错误类型、空字符串、重复规则或非法组合都会使整份 catalog 按 provider 违规失效，不能
只丢坏字段后继续调用。

### brief

- `id` 是 1 至 64 个 ASCII 小写字母、数字、点或连字符组成的稳定投影名；进入既有
  `localView.projection`。
- `omit` 为 1 至 32 条互不重复的受限路径，每条最长 256 字节。路径从最终 stdout document 根开始，
  语法只允许 `$` 后接一个或多个 `.field`，中间字段可带 `[]` 遍历数组中的 map；`field` 必须匹配
  `[A-Za-z][A-Za-z0-9_]*`。例如 `$.commands[].parameters`、`$.payload.nodes`。
- 规则只删除存在且非空的叶成员；容器缺失、类型不符、叶缺失或值为 `null`/空字符串/空 list/空 map
  都是 no-op。实际发生删除的规则按声明顺序进入 `localView.omitted`，因此 0.5.0 的既有 pattern 与顺序
  可以逐字节复刻。
- `$.notice` 仍是 accepted response envelope 的全局规则，由统一解释器固定执行，不在每个 descriptor
  重复声明。它与命令级规则共同构成一次 brief 投影。

选择删除清单是兼容裁决，不是把安全改成 fail-open。0.5.0 已把未知兄弟字段默认透传和
`localView.omitted` 的字面 pattern 冻结成稳定 JSON；改为保留清单会在相同输入上改变这个契约。任何不应
出现在响应里的敏感事实必须在 schema/脱敏边界拒绝，不能先让它进入 full 再指望 brief 隐藏。

### artifact

`kind` 是封闭枚举：

| kind | 数据源 | 允许的附加字段 | 行为 |
|---|---|---|---|
| `renderedMember` | `member` 指向最终响应中的一个成员 | `member`、`encoding`、`mediaType`、`extension`、`automaticSpill` 全部必填 | 对 accepted 响应按现有 inline 字节阈值或显式 `--output` 落本地 artifact |
| `payloadBlob` | 固定为 `$.payload.blob` 的 host blob metadata | 无 | 显式 `--output` 后按既有 blob.read、大小与摘要协议下载 |
| `responseBlob` | 固定为 `$.payload` 的 host blob metadata | 无 | 显式 `--output` 后按既有 blob.read、大小与摘要协议下载 |

`renderedMember.member` 使用与 brief 相同的受限路径，但禁止 `[]`，只能指向一个成员；缺成员或类型不符时
不生造结构、不落盘，保持响应原样。`encoding` 只允许 `json` 或 `utf8Text`：前者要求成员可 JSON 编码，
后者要求成员为 String。`mediaType` 只允许 `application/json` 或 `text/plain; charset=utf-8`，并必须与
encoding 对应；`extension` 只允许对应的 `json` 或 `txt`。`automaticSpill` 在本版必须为 `true`，其含义
只是沿用现有“渲染后文档超过本地阈值才自动落盘”；显式 `--output` 仍无条件尝试写成员。

一条命令不得声明多个 artifact，也不得让 descriptor 携带本机输出路径、命名模板、大小上限或覆盖策略。
这些继续由本地 writer 与 CLI 选项拥有。`payloadBlob`/`responseBlob` 的内容类型、长度和摘要继续来自经过
校验的 host metadata，不由 descriptor 重复声明。

## 非协议命令的同一声明类型

`catalog` 和三棵 Flutter diagnostic tree 不是普通 service descriptor 路径，但仍要使用同一个
`PatchbayOutputProjection` 值类型与解释器。它们的声明落在 CLI-local command registry，不进入 host
catalog；这不是第二套投影模型，只是非协议命令没有可承载 wire descriptor。CLI-local 声明必须进入与
protocol descriptor 相同的 codegen/check 和 golden 对账，不能退回 `_familyFor` 或命令名 if/else。

canonical `ui perform` 只是 CLI route：最终按已接受的 DG-060-01 映射到既有 service command，因此读取
该 service descriptor 的投影，不为每个 façade spelling 复制一份声明。`localRoute` 是 CLI-local 事实，
在 host 投影之后追加，不反向进入 descriptor。

## 求值顺序、状态与失败

固定顺序如下：

1. host 完成 admission、consumer 调用与 response schema 校验；
2. CLI 先按 artifact 声明下载 host blob 或将 rendered member 落盘，并把成员替换为既有 receipt；
3. CLI 再对 accepted 响应执行 brief；已经被 receipt 替换的成员不再删除，`localArtifact` 保留；
4. CLI 追加 `localView` / `localRoute` 等本地投影事实并渲染 stdout 或人读 summary。

full 不执行字段删除，但显式 artifact 下载仍按命令语义运行。brief 对非 accepted 响应不删除任何字段，只
追加 `projection: null`、空 `omitted` 的既有 `localView`。artifact 写入失败沿用本地 typed error，不改 host
admission 或原响应；超限、摘要不符与覆盖冲突继续沿用现有错误码。

## 兼容与降级

- **新 CLI → 老 host**：descriptor 缺 `outputProjection` 时使用 0.5.0 冻结 fallback；它只覆盖 0.5.0
  已存在的命令与 CLI-local family，内容、规则顺序和 `localView` 逐字节不变。fallback 进入只读兼容区，
  不得为 0.6.0 新协议命令继续扩表。
- **老 CLI → 新 host**：command descriptor 是逐键松读 catalog，老 CLI 忽略
  `outputProjection` 并继续自己的 0.5.0 投影。新字段会作为 additive catalog 事实出现在老 CLI 的 full
  输出；“逐字节不变”只承诺相同 descriptor-less 输入的投影结果，不虚假承诺新 host 的 catalog 不增加
  字段。
- **新 CLI → 新 host**：descriptor 有声明就只使用声明，不与 legacy command rule 合并；descriptor
  无声明的 consumer external command 保持 legacy passthrough（仅执行全局 notice 规则，
  `localView.projection` 为 null），不能按响应形状猜命令族。
- `outputProjection` 属于松读 catalog sibling，不进入 shipped client 严格解码的 request/envelope，也不
  增加 feature capability 或提高 `schemaVersion`。catalog digest 按既有“commands 全对象”口径自然覆盖
  该字段。

0.6.0 实现完成后 fallback 只允许删除已经不再支持的历史版本分支，不允许继续新增规则；是否在 1.0 后
保留由兼容矩阵另行裁决。

## 安全与隐私

descriptor 只能选择已经过脱敏和 schema 校验的响应成员。投影不得读取网络、跟随引用、执行模板、解释
本机路径或合成 consumer 未返回的成功值；artifact 路径只由本地 writer 决定。无效 projection 使 catalog
整体不可用，避免 provider 用畸形声明让不同客户端各自猜测。

`localView.omitted` 只能回显 descriptor 中的静态规则字面量，不能把运行时 map key、target id、session、
路径或 consumer 文本拼进去。artifact receipt 继续只包含既有 path/length/SHA-256/contentType/origin
事实；trace 按既有 content-addressed 机制附加，不扩大 host audit。

## 实施与回退边界

PB-050-40 作为一个实现 MR 完成声明类型、descriptor wire、CLI-local 声明、统一解释器、fallback 冻结与
codegen/golden 迁移；拆成“只加 wire”和“只换 CLI”会产生两份同时可写的真源，不能独立验收或回退。
回退时整项撤回，恢复 0.5.0 手工表；不保留一半声明、一半特例的长期状态。

实现前 PB-060-06 的畸形载荷 harness 必须先合入，并把 `outputProjection` 的未知键、错类型、超长、重复、
非法组合与 catalog 整体拒绝加入固定 seed 语料。

## 验证

- 单元/协议：声明边界、受限路径、缺字段 no-op、brief/full/artifact、invalid catalog 与冻结 fallback。
- golden：0.5.0 descriptor-less full/brief 对逐字节不变；0.6.0 catalog additive diff、localView 顺序、三个
  artifact kind 与 canonical façade/service descriptor 复用。
- VM/direct：同一 catalog 声明、catalog digest 与输出逐字节对账；老 reader 忽略 additive 字段。
- example：debug 会话覆盖 semantics tree、三棵 diagnostic tree、capture、logs.query 与普通小响应；profile
  会话验证空 diagnostic data 不被落盘或误报省略。
- 失败注入：超限、缺成员、错类型、JSON 编码失败、artifact 写失败、摘要不符、老 host 与目录漂移。
- consumer 真机只验证真实大响应和本地 artifact 链；它不能替代协议/CLI 投影的确定性测试。

## 被否决方案

- brief 改用保留清单：与 0.5.0 冻结的未知字段透传和 `localView.omitted` 稳定语义冲突；脱敏也不应依赖
  操作者是否选择 brief。
- 继续在 CLI 为每个命令加 rule：重复事实和漂移问题不变。
- 让 descriptor 携带 formatter/template、本机路径或多 artifact：扩大执行、注入和资源预算面。
- 新 CLI 遇到老 host 禁用 brief/artifact：会破坏 0.5.0 已有能力。
