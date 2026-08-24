# 发版检查清单

> 只由 maintainer 执行：版本验收 → 发布 MR 合入 `main` → 同步同一 SHA 到 GitHub → 打 tag → 发布 → 下游按 pin 升级。
> 本清单是发版动作的核对表，不改变 [CONTRIBUTING.md](../CONTRIBUTING.md) 定义的权责边界。

清单分两半：**脚本项**由 `release_prep` 一次跑完并给红绿，不必人肉逐条比对；**人工项**是脚本
永远不代做的四类动作——打 tag、推送、发布、以及需要向仓外核实的口径。

## 0. 聚合 CHANGELOG 碎片

日常行为 MR 只在 [`changelog.d/<version>/`](../changelog.d/README.md) 新增碎片，不直接争写根
CHANGELOG。定版先按碎片规范校验并把目标版本目录聚合为根表的 `## Unreleased` 段，同时只删除
该版本已消费碎片，再进入下面的
`release_prep` 流程。

聚合顺序固定为 `Added → Changed → Deprecated → Removed → Fixed → Security`，同一栏目按文件名升序，
由 `release_prep --check/--apply` 校验和执行；不再保留另一套手工聚合逻辑。

- [ ] 所有版本目录和碎片文件名、change-id、类型、正文符合规范，根目录没有散落碎片
- [ ] 根 CHANGELOG 的 Unreleased 内容与待发布碎片一一对应
- [ ] 目标版本段有一对 `PUB_CHANGELOG` 标记包围的英文 pub.dev 摘要
- [ ] 目标版本碎片在同一发布提交中删除，`README.md` 与其他版本队列保留
- [ ] 没有直接编辑四个包的派生 CHANGELOG

## 1. 脚本项：跑一遍机检

```console
$ dart run packages/patchbay/bin/release_prep.dart --version <SemVer> --check
```

只读、可反复跑；红绿即结论，末尾还会打印发布顺序与人工清单。要它代改文件就把 `--check`
换成 `--apply`（改完自动重跑判定）：apply 只动文件，**不打 tag、不推送、不发布**。

| 判定项 | 硬 | 说的是什么 |
|---|---|---|
| `version-parity` | | 四包 `pubspec.yaml` 的 `version` 都等于目标版本 |
| `version-references` | 硬 | `patchbayPackageVersion` 与当前安装文档的受管版本引用等于目标版本 |
| `documentation-current` | 硬 | 根、包与 example README / guide 无旧安装口径，双语入口、SVG 能力与中性示例完整 |
| `protocol-compat-fixture` | 硬 | 本版 host surface 已冻结成版本化 identity / catalog 兼容语料，且无缺失或漂移 |
| `schema-version-parity` | | `service_host.dart` 与 `invocation.dart` 的 `schemaVersion` 同值 |
| `changelog-release` | | 根 CHANGELOG 的 `## Unreleased` 已落款成 `## X.Y.Z - 日期` 且在表顶 |
| `package-changelog` | 硬 | 四包各自的 `CHANGELOG.md` 已记到目标版本（pub.dev 每个包页读的是包内这份） |
| `example-lock` | 硬 | `example/pubspec.lock` 里 path 源的随版包已跟到目标版本（0.2.0 漏的就是这项） |
| `compat-matrix-row` | 硬 | 兼容矩阵有本 tag 的行、在表顶，且 schema / Flutter 三列与源码一致（0.2.1 漏的就是这项） |
| `compat-matrix-backfill` | 硬 | 已打过 tag 的行不留占位符，SHA 与 peeled tag 一致 |
| `internal-dep-constraints` | 硬 | 四包互相之间的 hosted 约束接纳目标版本 |
| `local-overrides` | 硬 | `pubspec_overrides.yaml` 把随版包指到工作树（少一条，仓内就在测 pub.dev 上的旧版） |
| `publish-switch` | 硬 | 四包已去掉 `publish_to: none`（见第 3 节，仓主决定） |
| `publish-manifest` | 硬 | LICENSE、description、无 path 依赖等 pub 的 error 级项 |
| `publish-advisories` | 硬 | README / CHANGELOG / repository / description 长度等 pub 的 warning 级项 |
| `format-gate` | 硬 | 仓根 `dart format --output=none --set-exit-if-changed .` 零改动 |
| `publish-dry-run` | 硬 | 四包 `dart pub publish --dry-run` 全过 |

「硬」= 不接受降级成提示。`publish-advisories` 与 `format-gate` 同样按硬对待：pub 只要有一条
warning，`--dry-run` 就退 65，和 error 一样发不出去；排版则是 CI 门禁，tag 打完再被拦代价更大。

`--apply` 会代改：四包 version 与随版依赖约束、`patchbayPackageVersion`、README / guide / CLI README
的受管版本引用、版本化协议兼容语料、根 CHANGELOG 落款、四包 CHANGELOG（从根表派生）、
`example/pubspec.lock` 的版本格子、兼容矩阵新行（tag 后才能定的两格留占位符）、缺失的
`pubspec_overrides.yaml`。它不碰 `publish_to: none`（第 3 节），也不代写 CHANGELOG 正文；碎片只从
与 `--version` 精确同名的目录读取。

## 2. 人工项：CI 门禁全绿

脚本只在本地判排版，analyze / test / codegen 仍看 CI。GitLab（`.gitlab-ci.yml`）与 GitHub
Actions（[`ci.yml`](../.github/workflows/ci.yml)）三个 job 一一对应：

- [ ] `dart_packages` —— 排版与规划一致性门禁 + 三个纯 Dart 包 `dart analyze --fatal-infos` + `dart test`
- [ ] `flutter_package` —— `patchbay_flutter` 本体与 `example` 均 `flutter analyze` + `flutter test`
- [ ] `codegen_drift` —— `wire_codegen.dart --check` 同时确认 Dart 与 wire surface golden，
  `command_codegen.dart --check` 按提交形态确认生成物或紧凑快照无漂移
- [ ] 本地 example 端到端预检全绿——CI 三个 job 都跑在无设备的容器里，证明不了「CLI 真的连上了一个跑
  在设备上的 host」。这一项必须在接入方真机验收之前完成，不能用 CI 绿灯代替。
- [ ] GitHub Actions 门禁绿（[`ci.yml`](../.github/workflows/ci.yml)，三个 job 与上面一一对应）
- [ ] 当前文档、双语入口与 SVG 在打 tag 前定稿；`documentation-current` 已绿，不留“发布后再改”事项

本地复跑（`wire_codegen.dart --check` 必须从仓根调用——它的生成物 header 记录仓根相对路径，
进包目录跑会假漂移；`command_codegen.dart --check` 没有这个约束，其 header 记录的是相对生成物
自身的路径）：

```console
$ for p in patchbay patchbay_cli patchbay_transport; do
    (cd "packages/$p" && dart pub get && dart analyze --fatal-infos && dart test)
  done
$ dart run tool/check_planning.dart
$ (cd packages/patchbay_flutter && flutter pub get && flutter analyze && flutter test)
$ (cd packages/patchbay_flutter/example && flutter pub get && flutter test)
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --check
$ dart run packages/patchbay/bin/command_codegen.dart \
    --contract packages/patchbay/contracts/example_commands.json \
    --output packages/patchbay/contracts/example_commands.g.dart --check
```

`example_commands.g.dart` 是完整生成结果的 SHA-256 紧凑快照，不作为源码导入。contract 或
generator 有意变更后，以同一命令把 `--check` 换成 `--write-snapshot` 更新；接入方仍使用
`--write` 生成可编译的完整实现。

## 3. 人工项：开发布开关

四包默认带 `publish_to: none`。删掉它等于宣布这一版对外发布，是仓主的决定，不夹在日常改动里：

- [ ] 确认本版对外发布，再删这一行；开关未开之前 `publish-dry-run` 一直是「跳过」

```console
$ dart run packages/patchbay/bin/release_prep.dart --version X.Y.Z --apply --enable-publish
```

## 4. 人工项：打 tag（`patchbay-vX.Y.Z`）

- [ ] 顺序遵循 CONTRIBUTING.md「发版」：发布 MR 合入 `main` → 同步同一 SHA 到 GitHub → 打 tag
- [ ] tag 名格式 `patchbay-vX.Y.Z`，与第 1 节核过的版本号一致

```console
$ git tag -a patchbay-vX.Y.Z -m 'patchbay X.Y.Z'
$ git push origin patchbay-vX.Y.Z
```

## 5. 人工项：双端推送核对

- [ ] 两个 remote（`github` 与 `origin`）在该 tag 上的 commit SHA 一致

```console
$ git ls-remote --tags github patchbay-vX.Y.Z
$ git ls-remote --tags origin patchbay-vX.Y.Z
```

## 6. 人工项：发布到 pub.dev

`0.3.0` 起四包发布到 pub.dev。顺序由脚本按包间依赖推导（当前为
`patchbay → patchbay_transport → patchbay_cli → patchbay_flutter`），凭据由人提供，脚本只打印命令。

pub points 是发布硬标准。发布前使用 pub.dev 评分页当时显示的 Pana 版本，在包的
临时副本上运行；不允许以「尚未解析同版内部依赖」当成评分结果。因为 pub.dev 会忽略
`pubspec_overrides.yaml` 重做依赖检查，四包按依赖顺序发布：每发一个包，等它实际评分满分
后才继续下一个；未满分立即停止本次发布链。

```console
$ dart pub global activate pana <pub.dev 当前版本>
$ pana packages/patchbay --project-root . --exit-code-threshold 0
$ pana packages/patchbay_transport --project-root . --exit-code-threshold 0
# 上游同版包在 pub.dev 可解析后，依次对 patchbay_cli / patchbay_flutter 执行同一命令。
```

每个包发布后还要在它的 Scores 页核对 `grantedPoints == maxPoints`，不以本地旧 Pana 结果代替站点结果。

- [ ] 四包本地 Pana 报告在可解析同版内部依赖时达到当前满分
- [ ] 四包发布后 Scores API 均满足 `grantedPoints == maxPoints`
- [ ] 从干净的 git 状态发布（pub 会因「有未提交改动」报 warning）
- [ ] 显式指定 host：本机 `PUB_HOSTED_URL` 常指向镜像，不指定会把包发到镜像上

```console
$ (cd packages/patchbay && PUB_HOSTED_URL=https://pub.dev dart pub publish)
```

## 7. 人工项：回填兼容矩阵

`--apply` 生成的新行里有两个占位符，只有 tag 打完、consumer 核实过才能填：

- [ ] commit SHA 列：`git rev-parse patchbay-vX.Y.Z^{}`（annotated tag 必须 peeled）
- [ ] 已知 consumer 列：向对应 consumer 仓核实后再写，本仓不持有该口径
- [ ] 回填后重跑 `--check` 确认 `compat-matrix-backfill` 转绿

## 8. 人工项：consumer 换 pin

- [ ] consumer 仓按新版本更新引用

**0.3.0 起，只改 tag 号是不够的。** 四包互相之间已从 path 依赖改成 hosted 约束
（`patchbay_flutter` 依赖 `patchbay: ^0.3.0`），而 pub 不允许同一个包在一次解析里既来自 git
又来自 hosted。仍用 git pin 的接入方有两条路，二选一：

- 整体改用 pub.dev 版本（推荐）；
- 或在自己仓的**根** pubspec 加 `dependency_overrides`，把四包统一指回同一 git ref。

接入方侧的具体文件与命令（`PATCHBAY_PINS`、双 lock 等）**未在本仓验证**，以该仓自身文档为准。

## 9. 人工项：真机验收

- [ ] 真机跑通新版本下的接入路径（identity / catalog / 至少一条业务命令）；桌面 / CI 门禁全绿
      **不代表**验收通过
- [ ] 参考 [使用指南「边界」](guide.md#边界)：CLI 结果是调试证据，不是产品验收证据——不证明像素
      正确或设备物理行为，真机验收需另行确认

## 10. 人工项：发布收尾（finalize）

**必须在四包实际发布之后执行。** finalize 会把版本计划标为已发布并删除 backlog 行——在包还没上
pub.dev 时执行等于替未发生的事实背书；而四包是按依赖顺序逐个推、可能中途被拒的，先删行再发布
会留下 backlog 已清空、版本却没发出去且无处回滚的悬空状态。

- [ ] 先出计划（只读，不写盘）：

```console
dart run tool/release_finalize.dart X.Y.Z
```

- [ ] 逐条核对三档分类：
      - `ARCHIVE`（`已验证`）：确实随本版发布，可从 backlog 删行；
      - `EVIDENCE_PENDING`（`待真机验收`）：实现已完成但真机 / 接入方证据未闭合，**保留在 backlog
        不删**，需显式 `--allow-evidence-pending` 才放行；
      - `DEFER`：延期条目，清空目标版本退回 `待排期`。`实现中` 不接受批量延期，必须逐条
        `--defer-item PB-XXX-XX` 点名。
- [ ] 核对无误后执行：

```console
dart run tool/release_finalize.dart X.Y.Z --apply
```

- [ ] 复跑 `dart run tool/check_planning.dart`，确认 backlog 与版本计划仍一致
- [ ] finalize 的改动走一个小 MR 合回 `main`（`main` 受保护，不接受直接推送）
