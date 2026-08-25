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
- 仓库在任一时期只有一个评审与合并主入口（single head），镜像端只同步主入口已合入的同一代码，
  不双头合并。当前主入口是内网 GitLab，GitHub 为公开镜像；主入口可迁移（例如日后以 GitHub 为
  真源），迁移是治理变更：由仓主宣布、更新本条与 CONTRIBUTING 后生效，切换期间旧入口冻结新
  MR。MR 描述使用中文。
- MR 模板必须写明目标分支、依赖链、验收/回退边界，以及需要真机验证时的责任与证据状态。

## 分支职责

- `main` 是受保护的稳定主线，**只接定版合并**：每个提交都对应一个已发布版本或 hotfix，
  `git log main` 即发布史，tag 与 main 一一对应。禁止直接推送、未完成实现和已知红灯进入 `main`。
- 活跃版本使用临时 `dev/<SemVer>` 开发分支承接整个周期的功能集成与版本级验收。功能分支从该版本分支
  创建，MR 也以该版本分支为目标；堆叠 MR 在父 MR 合入前以父分支为目标。
- **冻结是版本的阶段，不是另一条分支**：版本计划的 `> 状态：` 从 `规划中` 推进到 `RC` 即冻结范围，
  此后只接发布阻断修复。版本通过 CI、兼容和真机门禁后，由一个发布 MR 把 `dev/<SemVer>` 合回 `main`；
  随后同步 GitHub、打 tag 并发布。完成后回收版本分支。
- 紧急修复从 `main` 建 `hotfix/<SemVer>`，验证并合回 `main` 后，再前向合入仍活跃的版本分支。
- 版本分支模型的生效范围可能因版本而异；当前活跃版本的 MR 目标分支以该版本的
  [版本计划](docs/releases/)为准，不在本文件维护。

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
- 验证分两段，顺序不可颠倒：**先**在仓内 example 上跑本地端到端预检，**再**交业务接入方在真机上验收。
  example 预检不过，不算通过初步验证，不进业务验收，也不得据此宣称能力可用。
- example 预检证明的是协议、CLI 与 host 三方接线在真设备/模拟器上确实通；它**不能替代业务验收**——
  真实控制器语义、设备 SDK 确认、真实 UI 的滚动与遮挡、签名真机上的系统弹窗只有接入方能出证据。
- 交接必须给出分支、提交 SHA、实际运行的检查、剩余风险、真机状态和后续依赖。

## 联调姿势

**每个调试任务开始时把 CLI 编一次 AOT，任务期间一律复用那份产物。** 不要在循环里
`dart run bin/patchbay.dart`——它每次调用都重新编译。`tool/example_session.sh` 已按内容指纹实现重编
判定与按检出隔离的产物目录，走它即可，不要另起一套。

诊断面是**类型化答复**而非栈回溯：`--json` 的 `error.code` 与退出码在 AOT / JIT 下一致，因此排障不需要
回到 JIT。只有两种情况例外：要用调试器单步 CLI 自己的代码，以及需要 `assert` 生效
（`dart run --enable-asserts`）。改了 CLI 源码不算例外，重编一次即可。

**被调 App 默认 debug（JIT），不要默认 profile/AOT。** 这不是性能取舍而是覆盖问题：`ui.inspect` 在
非 debug 构建按 `inspectorUnavailable` 拒绝，`ui widget-tree` / `render-tree` / `focus-tree` 依赖只在
debug 注册的 inspector 服务扩展。默认 profile 会让这几项失去实质内容，预检"全过"就不再等于"全覆盖"。

**在 profile 判断诊断树是否可用要看载荷，不能只看退出码**：这三棵树在非 debug 返回的是退 0 配空
`data`，不是拒绝。

**两种模式各有盲区，覆盖面不可互相代替。** debug 会话在原理上看不见只在非 debug 存在的缺陷；
`tool/example_profile_smoke.sh` 跑 profile 会话补这一面，只验答复形态，不求全覆盖。改动涉及构建模式
相关的分支时，两个脚本都要跑。

**只有测性能时才切 profile。** `perf profile` 在 debug 下的帧耗时与 jank 不代表真实表现（JIT + 断言
开启），要那组数就必须用 `--profile` 跑；此时同一条会话拿不到 inspect 与诊断树，报告里要写清模式。

**排障顺序:先证据，后断点。**

1. 用 patchbay 自己的证据面复现并定位：`snapshot`（含 `--path` 与条件等待）、`logs query/tail`、
   `trace` 轨迹、执行证据分类、审计事件。这些是为"不必断点"而存在的。
2. 证据不足时补日志或补一条只读命令，重跑复现。
3. **断点是最后手段**，而且有代价：断在断点上等于把 App 冻住，冻结期间 lifecycle 闸会让 `ui.*` /
   `navigation.*` 全部按 `*LifecycleNotResumed` 拒绝，CLI 随后只看到 `appUnresponsive`。也就是说断点
   会改变现场、掩盖原来的问题。要用就单独起一次会话，不要在预检或验收链里挂断点。

## 安全与维护

- 使用 `apply_patch` 做人工文件编辑；批量生成和格式化使用仓内工具。禁止未经授权的破坏性 Git 或文件操作。
- 不把 token、内部地址、设备标识、绝对路径或敏感 payload 写入代码、文档、日志、fixture 和 MR 描述。
- 不把业务接入方的名称、应用 ID、包名、域名或业务词汇写进仓库任何被 git 追踪的位置。四个包是通用
  工具，仓内只用 `example`、`com.example.*` 这类中性占位符。必须留存的接入方验收证据放进被 gitignore
  的本地目录，不进版本库。
- 发布、打 tag、外部推送、安装依赖或操作设备只在任务明确授权时执行。

