# 协作约定

本仓有两个远端，**同步方向是单向的**，请勿双头推：

- 内网主仓 —— 协作与 MR 入口，所有变更先在这里合入 `main`；
- GitHub `cr1992/patchbay` —— 公开镜像，只接受 maintainer（cr1992）从内网主仓同步的同一提交，
  不在两端重复合并，流程见[发版](#发版)。

## 提交改动

1. 从 `main` 拉分支，改动保持一个可独立评审的单元；
2. 跑绿再提 MR：仓根 `dart format --output=none --set-exit-if-changed .` 零改动，
   四包 `dart test` / `flutter test` 全过，`dart analyze` 无问题；
3. 生成物改动跑两个 `--check`：`wire_codegen.dart`（**必须从仓根调用**，进包目录会假漂移
   ——header 记录的是仓根相对路径）与 `command_codegen.dart`（从哪个目录调用都一样，
   header 记录的是相对生成物自身的路径）；完整两条命令见
   [发版清单](docs/release-checklist.md)；
4. 新增行为必须带测试，且测试要验证过「能红」（打个定向 mutation 确认断言真的红）。
5. 公共 API、协议字段、默认资源上限或安全行为有变化时，同步更新 README / 对应专题文档，并按
   [CHANGELOG 碎片规范](changelog.d/README.md)新增碎片；日常 MR 不直接修改根或包内 CHANGELOG，
   文档、测试与实现必须描述同一契约。
6. 本仓公开：文档与注释不记录内网域名、内部项目与业务线名。需要指代时写「内网主仓」
   「接入方」；内网地址走 CI 变量或 remote 名，不写字面值。

## CHANGELOG 碎片

会影响使用者的 MR 必须在 `changelog.d/` 新增一个独占碎片，文件名绑定版本计划/backlog 编号和
`added|changed|deprecated|removed|fixed|security` 类型。纯测试、注释、排版或无外部行为变化的
内部重构可以不写，但要在 MR 模板说明理由。

碎片在功能 MR 合入后继续保留，正式发布时才聚合进根 [CHANGELOG.md](CHANGELOG.md) 并删除；四个包的
CHANGELOG 仍由根表统一派生，不是独立真源。完整命名、内容、评审和发布规则见
[changelog.d/README.md](changelog.d/README.md)。

## 设计红线

改协议或 UI 桥之前先读 [docs/design.md](docs/design.md)——六条设计立场（受理≠执行、
事实来源封闭词表、声明式门、release 裁除、低侵入 UI、job 表达慢事实）是评审的硬标准，
违反任何一条的 MR 会被打回。业务/品牌代码不进这四个包。

## 发版

只由 maintainer 操作：内网主仓 MR 合并 → 将同一 `main` SHA 同步到 GitHub →
打 `patchbay-vX.Y.Z` tag → 下游按 pin 升级。
