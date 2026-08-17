# CHANGELOG 碎片规范

本目录保存尚未发布、会影响使用者的变更说明。日常行为 MR 各写自己的碎片；定版时统一聚合进仓根
`CHANGELOG.md`，再由 `release_prep` 从根表派生四个包的 `CHANGELOG.md`。

仓根 `CHANGELOG.md` 是已发布历史的唯一真源；本目录只保存待发布输入。四个包当前共享同一份发布
正文，因此碎片不声明 package scope。

## 何时必须写

以下变化必须随 MR 添加碎片：

- 新功能、用户可见行为变化或缺陷修复；
- 公共 API、协议字段、稳定错误码、默认值或资源上限变化；
- 安全边界、兼容范围、安装方式或发布行为变化；
- 已弃用或移除的能力。

以下变化通常不写：

- 只改测试、注释、排版或内部重构，且外部行为不变；
- 版本规划、设计讨论和未落地提案；
- 发布聚合 MR 本身——它消费已有碎片，不为聚合动作再造一条碎片。

无法判断时按“使用者升级后是否需要知道”裁决。选择“不需要碎片”的 MR 必须在 PR 模板中写明理由。

## 文件名

格式：

```text
<change-id>[.<part>].<type>.md
```

`change-id` 使用两种封闭格式：

- 已排期工作：版本计划或 backlog 编号，例如 `PB-040-01`；
- 未排期缺陷：先在 backlog 缺陷表登记，再分配 `BUG-YYYYMMDD-NN`，例如 `BUG-20260817-01`。

同一条目拆成多个独立行为时，用可选的 `part` 区分；`part` 只能使用小写 ASCII 字母、数字和连字符。

```text
PB-040-01.added.md
PB-040-01.cli.added.md
PB-040-05.registry.changed.md
BUG-20260817-01.fixed.md
```

完整文件名必须匹配：

```regex
^(PB-[0-9]{3}-[0-9]{2}|BUG-[0-9]{8}-[0-9]{2})(\.[a-z0-9][a-z0-9-]*)?\.(added|changed|deprecated|removed|fixed|security)\.md$
```

禁止使用 MR 编号作为唯一 ID：创建碎片时 MR 可能尚不存在，同一个计划项也可能跨多个 MR。

## 类型

类型与根 CHANGELOG 的栏目一一对应：

| 后缀 | 聚合栏目 | 使用场景 |
|---|---|---|
| `added` | `Added` | 新增能力 |
| `changed` | `Changed` | 既有行为、API、默认值或兼容范围变化 |
| `deprecated` | `Deprecated` | 仍可使用、但计划移除的能力 |
| `removed` | `Removed` | 已移除能力 |
| `fixed` | `Fixed` | 缺陷修复 |
| `security` | `Security` | 安全修复或安全边界收紧 |

一个文件只属于一个类型。一个 MR 同时包含新增和兼容变化时，写两个碎片，不把两类行为塞进同一条。

## 内容

每个碎片使用 UTF-8，正文只包含一条顶层 Markdown 列表项：

```markdown
- 新增 identifier 锚定的 drag 与 fling，并在目标代际变化时拒绝执行。
```

要求：

- 默认使用中文，公共类型、命令、字段和稳定 code 使用反引号保留原名；
- 从使用者结果写起，说明“新增/改变/修复了什么”，不记录实现过程、提交 SHA 或评审过程；
- 不写标题、版本号、日期、front matter 或空占位；
- 需要补充迁移方法时，可在同一列表项下使用缩进续段；
- 仓内链接以根 `CHANGELOG.md` 为基准，包内绝对链接继续由 `release_prep` 改写；
- 破坏性变化必须以 `**Breaking:**` 开头，并给出迁移路径；
- `security` 不记录可直接复现利用的敏感细节。

例如：

```markdown
- **Breaking:** `PatchbaySessionRecord` 改用显式 `pending` 状态；构造记录时不再用空 URI 表示启动中。
  旧接入方应先升级读取逻辑，再写入新字段。
```

## MR 流程

1. 从版本计划或 backlog 取得 `change-id`；未排期缺陷先登记，design-gate 先裁决。
2. 实现 MR 同时新增碎片，日常 MR 不直接编辑根或四个包的 `CHANGELOG.md`。
3. 作者在 PR 模板填写计划编号、验证证据和碎片文件；无需碎片时填写理由。
4. 评审者核对文件名、类型、用户视角、Breaking 标记，以及文档/测试是否描述同一契约。
5. MR 合入后碎片继续留在本目录，直到对应版本定版；不得在功能合入后提前删除。

一个碎片只由创建它的 MR 修改。后续修正另开碎片，避免多个分支重新争写同一个文件。

## 发布聚合

定版时按以下顺序处理：

1. 校验全部文件名、change-id、类型、非空正文和单一顶层列表项；
2. 按 `Added → Changed → Deprecated → Removed → Fixed → Security` 建立栏目；
3. 同一栏目内按文件名升序聚合，保证重复执行得到相同结果；
4. 将内容写入仓根 `CHANGELOG.md` 的 `## Unreleased` 段；
5. 删除本次已聚合的碎片，保留本 `README.md`；
6. 运行 `release_prep --apply`，把 Unreleased 落款成正式版本并派生四个包的 CHANGELOG；
7. 聚合、删除碎片、版本落款和包内派生必须进入同一个发布提交。

PB-040-20 的自动聚合尚未实现之前，由 maintainer 在发布 MR 中按上述规则手工完成；实现后，
`release_prep --check` 必须负责校验，`--apply` 必须负责稳定聚合和删除碎片。自动化实现 MR 应同步移除
这段过渡说明。

已经推送的 release tag 不回写。遗漏的变更用下一个补丁版本的新碎片补记，不移动 tag，也不修改旧版本段。
