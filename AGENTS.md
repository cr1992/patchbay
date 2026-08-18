# Patchbay Agent 工作约定

本文件是仓内 Agent 指令的唯一入口。所有宿主都读取本文件；`CLAUDE.md` 只允许引用本文件，禁止复制规则。
需要修改 Agent 行为时只改这里。领域事实仍以对应专题文档为准，不在本文件复制技术方案。

## 开工前

- 先读 [`docs/planning.md`](docs/planning.md) 判断文档权责、Proposal 门禁、MR 颗粒度和分支目标。
- 改公共 API、wire、命令 descriptor、稳定 JSON、状态机、安全边界或兼容语义前，先读已接受的
  [`docs/proposals/`](docs/proposals/README.md) 与 [`docs/design.md`](docs/design.md)。不得用实现 MR
  静默改写已接受结论。
- 查符号、调用链和影响面优先使用 CodeGraph；查字面文本才使用 `rg`。CodeGraph 未初始化时先询问是否运行
  `codegraph init -i`。
- 尊重已有工作树和未提交改动。不要改写、删除或接管不属于当前任务的修改；需要隔离时按
  `manage-worktrees` 规范创建可追踪 worktree。

## 交付单元与 MR

- 一个 MR 是一个可独立评审、验收和回退的交付单元，不要求机械等于一个 PB 编号。
- 同一公共契约、同一热点调用链、必须联合验收或拆开后任一半不可用的改动，应合为一个 MR；只有在依赖、
  验收和回退都真正独立时才拆分。
- 堆叠 MR 默认最多三层。存在共同底座时先合底座；三个及以上并行分支会修改同一热点时，先改为共同分支或
  顺序推进，不继续制造兄弟分支。
- 集成候选分支只用于固定 SHA 的联合验收，不作为功能 MR 或长期开发分支。语义冲突必须回到来源分支修复，
  不在候选分支拼接两套实现。
- GitLab 是唯一 MR/评审入口，MR 描述使用中文。GitHub 只同步已经在 GitLab 合入的同一代码，不双头合并。
- MR 模板必须写明目标分支、依赖链、验收/回退边界，以及需要真机验证时的责任与证据状态。

## 分支职责

- `main` 是受保护、随时可构建和可发布的稳定主线；禁止直接推送、未完成实现和已知红灯进入 `main`。
- 活跃版本使用临时 `release/<SemVer>` 分支承接功能集成、RC 修复和版本级验收。功能分支从该版本分支创建，
  MR 也以该版本分支为目标；堆叠 MR 在父 MR 合入前以父分支为目标。
- RC 阶段冻结范围，只接发布阻断修复。版本通过 CI、兼容和真机门禁后，由一个发布 MR 把
  `release/<SemVer>` 合回 `main`；随后同步 GitHub、打 tag 并发布。完成后回收版本分支。
- 紧急修复从 `main` 建 `hotfix/<SemVer>`，验证并合回 `main` 后，再前向合入仍活跃的版本分支。

完整规则和范围变更流程见 [`docs/planning.md`](docs/planning.md)。

## CHANGELOG

- 用户可见行为随实现 MR 写入 `changelog.d/<target-version>/` 下的独占碎片；不同版本不得共享目录。
- 一个碎片只由创建它的 MR 修改。不要提前聚合成共享版本文件，也不要直接编辑根或包内 `CHANGELOG.md`。
- `release_prep --version X.Y.Z` 只消费 `changelog.d/X.Y.Z/`，其他版本队列必须保留；根目录散落碎片是硬错误。
- 文件名、内容、无需碎片的条件与发布流程以 [`changelog.d/README.md`](changelog.d/README.md) 为准。

## 实现与验证

- 新行为先补能失败的测试，再实现并跑绿；测试应覆盖契约边界，而不是只覆盖快乐路径。
- 修改范围内运行 format、analyze、test 和相应 codegen/check。不要把未运行的检查或真机步骤写成已通过。
- VM Service 与 direct 共享能力必须验证语义一致；兼容改动必须保留老 reader/host 的复刻测试。
- 真机验收统一使用 moii app 作为业务宿主；example 只能做构建或协议预检，不能替代业务验收。
- 交接必须给出分支、提交 SHA、实际运行的检查、剩余风险、真机状态和后续依赖。

## 安全与维护

- 使用 `apply_patch` 做人工文件编辑；批量生成和格式化使用仓内工具。禁止未经授权的破坏性 Git 或文件操作。
- 不把 token、内部地址、设备标识、绝对路径或敏感 payload 写入代码、文档、日志、fixture 和 MR 描述。
- 发布、打 tag、外部推送、安装依赖或操作设备只在任务明确授权时执行。

