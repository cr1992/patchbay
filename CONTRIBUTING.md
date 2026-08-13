# 协作约定

本仓有两个远端，**同步方向是单向的**，请勿双头推：

- GitHub `cr1992/patchbay` —— 协作与 PR 入口（你在这里干活）；
- GitLab `cloud/mobile/patchbay` —— 主仓，只由 maintainer（cr1992）从 GitHub 合并后回推并打 tag。

## 提交改动

1. 从 `main` 拉分支，改动保持一个可独立评审的单元；
2. 跑绿再提 PR：四包 `dart test` / `flutter test` 全过，`dart analyze` 无问题；
3. 生成物改动跑 `dart run packages/patchbay/bin/wire_codegen.dart … --check`
   （**必须从仓根调用**，进包目录会假漂移——header 记录的是仓根相对路径）；
4. 新增行为必须带测试，且测试要验证过「能红」（打个定向 mutation 确认断言真的红）。

## 设计红线

改协议或 UI 桥之前先读 [docs/design.md](docs/design.md)——六条设计立场（受理≠执行、
事实来源封闭词表、声明式门、release 裁除、低侵入 UI、job 表达慢事实）是评审的硬标准，
违反任何一条的 PR 会被打回。业务/品牌代码不进这四个包。

## 发版

只由 maintainer 操作：GitHub 合并 → 回推 GitLab → 打 `patchbay-vX.Y.Z` tag → 下游按 pin 升级。
