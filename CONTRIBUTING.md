# 协作约定

本仓有两个远端，任一时期只有一个是评审与合并主入口（single head），**同步方向是单向的**，
请勿双头推：

- 内网主仓 —— 当前主入口：协作与 MR 入口，版本功能先进入对应 release 分支，验收后再合入稳定 `main`；
- GitHub `cr1992/patchbay` —— 当前为公开镜像，只接受 maintainer（cr1992）从主入口同步的同一提交，
  不在两端重复合并，流程见[发版](#发版)。

主入口可迁移（例如日后以 GitHub 为真源）。迁移由 maintainer 宣布并更新本节与 AGENTS.md 后生效，
切换期间旧入口冻结新 MR；无论主入口在哪，单向同步与「不双头合并」始终成立。

## 提交改动

1. 从 MR 的目标分支拉分支：版本功能目标是对应 `dev/<SemVer>`，hotfix 和仓库治理从 `main` 拉。
   MR 保持一个可独立评审、验收和回退的交付单元，具体颗粒度见[规划与交付治理](docs/planning.md)；
2. 跑绿再提 MR：仓根运行 `dart run tool/repo_tasks.dart check`；它从 pub workspace 读取四包清单，
   统一执行 format、planning、根私有工具与四包/example 的 analyze/test 以及 codegen 零漂移；
3. 生成物改动仍由同一个 `codegen-drift` 任务检查；它保证 `wire_codegen.dart` 从仓根调用，
   package-relative 工具在各自目录运行。任务与发版命令见[发版清单](docs/release-checklist.md)；
4. 新增行为必须带测试，且测试要验证过「能红」（打个定向 mutation 确认断言真的红）。
5. 公共 API、协议字段、默认资源上限或安全行为有变化时，同步更新 README / 对应专题文档，并按
   [CHANGELOG 碎片规范](changelog.d/README.md)新增碎片；日常 MR 不直接修改根或包内 CHANGELOG，
   文档、测试与实现必须描述同一契约。
6. 本仓公开：文档与注释不记录内网域名、内部项目与业务线名。需要指代时写「内网主仓」
   「接入方」；内网地址走 CI 变量或 remote 名，不写字面值。

## 规划与技术方案

[backlog](docs/backlog.md)、版本计划和 [Proposal](docs/proposals/README.md) 分别维护事项、排期和技术
契约，不重复维护同一字段。范围或方案 MR 必须遵循[规划与交付治理](docs/planning.md)：涉及公共 API、
协议/JSON、状态机、跨包边界、默认安全行为或 design-gate 的条目，正式实现前必须有已接受 Proposal。

台账条目是 [`docs/backlog.d/`](docs/backlog.d/README.md) 下一条目一个的碎片文件，和 `changelog.d/`
同一惯例：**实现 MR 只改自己条目的碎片**，不要重新引入入库的总表。要看全表按需现渲：

```console
$ dart run tool/check_planning.dart      # 结构 + 跨文档一致性
$ dart run tool/backlog_render.dart      # 只读总表，不提交
```

CI 会阻止 backlog 与版本范围不一致、碎片字段/状态非法、悬空 Proposal/design-gate，以及待裁决条目
没有方案入口。实现偏离已接受 Proposal 时，先修改方案并重新评审，不能只在实现 MR 中口头解释。

## CHANGELOG 碎片

会影响使用者的 MR 必须在 `changelog.d/<target-version>/` 新增一个独占碎片，文件名绑定版本计划/backlog 编号和
`added|changed|deprecated|removed|fixed|security` 类型。纯测试、注释、排版或无外部行为变化的
内部重构可以不写，但要在 MR 模板说明理由。

碎片在功能 MR 合入后继续保留，正式发布时才聚合进根 [CHANGELOG.md](CHANGELOG.md) 并删除；四个包的
CHANGELOG 仍由根表统一派生，不是独立真源。完整命名、内容、评审和发布规则见
[changelog.d/README.md](changelog.d/README.md)。

## 设计红线

改协议或 UI 桥之前先读 [docs/design.md](docs/design.md)——六条设计立场（受理≠执行、
事实来源封闭词表、声明式门、release 裁除、低侵入 UI、job 表达慢事实）是评审的硬标准，
违反任何一条的 MR 会被打回。业务/品牌代码不进这四个包。

## 源码结构

拆分依据是职责边界与依赖方向，不是行数——完整口径见
[docs/code-structure.md](docs/code-structure.md)。结构门禁只对四类结构错误判红
（手写 `part` 碎片、跨包 `src/` 私有导入、越出包根的相对导入、领域目录循环依赖）；
函数与文件体积一律只是警戒线。命中警戒线的地方，MR 描述里给出拆或不拆的理由即可。

## 发版

只由 maintainer 操作：在 `dev/<SemVer>` 上完成 RC 与真机验收 →
发布 MR 合入 `main` → 将同一 `main` SHA 同步到 GitHub → 打 `patchbay-vX.Y.Z` tag → 下游按 pin 升级。
