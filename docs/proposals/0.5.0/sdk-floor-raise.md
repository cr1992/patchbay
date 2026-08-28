# 0.5.0 公开 SDK 下限提升至 Flutter 3.44.0 / Dart 3.12.0

> 状态：已接受
>
> 关联：PB-050-12、PB-050-28
>
> 设计闸门：无

## 问题

四个 package 当前声明 `sdk: '>=3.11.0 <4.0.0'`，`packages/patchbay_flutter` 与 `example` 另加
`flutter: '>=3.38.0'`。[0.5.0 版本计划](../../releases/0.5.0.md)对 PB-050-12 写死了一条约束：
**「发布文档必须写真实下限，提高公开下限则先走 Proposal」**。本文就是那份 Proposal。

机检把这条声明拆成了三层事实，一层比一层紧（完整数据见
[SDK 下限调查](../../verification/0.5.0-flutter-sdk-floor.md)）：

**第一层：声明的两条约束不可能同时成立。** Flutter 官方 release 清单显示 3.38.0–3.38.10 全系只内置
Dart 3.10.0–3.10.9。任何一个自称满足 `flutter: '>=3.38.0'` 的安装，其自带 Dart 都无法满足
`sdk: '>=3.11.0'`。也就是说**当前声明的下限数字指向一个不存在的组合**——它从来没有被任何人验证过，
因为它装不出来。

**第二层：最早可安装组合是 Flutter 3.41.0，但它永久红。** 3.41.0 内置 Dart 3.11.0，是官方渠道里
第一个同时满足两条声明约束的版本。它跑不过既有的
`packages/patchbay_flutter/test/reveal/reveal_matrix_test.dart`「ModalBarrier 盖住已挂载目标 ⇒
targetBlocked」——本地 macOS arm64 与 Linux GitLab CI（pipeline 6028 / job 27769）两个平台独立复现，
逐字符一致。PB-050-28 最初把它登记为 reveal 引擎的一帧时序缺口；**根因排查已证伪该假设**：

- 上游提交 `af35e77c83d`（`[framework] Fix Text.semanticsIdentifier being absorbed by ancestor
  nodes`，PR #181795，2026-02-27 合入）把 `RenderSemanticsAnnotations.describeSemanticsConfiguration`
  的 `config.isSemanticBoundary = container;` 改成
  `config.isSemanticBoundary = container || (_properties.identifier != null);`。含该提交的**第一个
  stable release 是 3.44.0**；stable 渠道在 3.41.9 与 3.44.0 之间没有发布过任何版本（3.42 / 3.43 只有
  beta），因此 3.41.x 全系都不含它，也不会再有含它的 3.41.x 补丁。
- `SemanticsConfiguration.absorb` 在两个版本上逐字节相同：它吸收一个 `isBlockingUserActions` 的子
  config 时**只过滤该子 config 的 action handler，从不把 `isBlockingUserActions` 复制给吸收方**。而
  `SemanticsNode._areUserActionsBlocked` 只有 `config.isBlockingUserActions` 一个来源。

两者相乘：在 3.41.x 上 `Semantics(blockUserActions: true) > Semantics(identifier: …)` 两层都不是边界，
一起被并进更上面那个边界节点（`ListView.builder` 行上是 `IndexedSemantics` 建的节点），该节点
`areUserActionsBlocked` 恒为 `false`。插桩矩阵（同一 fixture、同一探针，两版本对照）：

| fixture | 3.41.0 | 3.44.9 |
|---|---|---|
| `ListView` 行：`Semantics(blockUserActions:) > Semantics(identifier:)` | **`false`**（多等 3 帧仍 `false`） | `true` |
| 同上，identifier 一侧加 `container: true` | `true` | `true` |
| 同一 widget 静态构建（不进 `ListView`） | `true` | `true` |

**这不是时序**：多等帧不会让该值变成 `true`，整条祖先链也全是 `false`，且该节点没有子节点——这条信息
根本不在 3.41.x 的语义树里。第三行同时解释了为什么
`test/bridge/semantics_occlusion_admission_test.dart` 的静态用例在 3.41.0 上照常通过：它的外层
`Semantics(blockUserActions: true)` 自己形成了节点，`isBlockingUserActions` 落在它**自己**的 config 上，
不经过 `absorb`。

端到端影响（真实 bridge，两版本对照）：

| 入口 | 3.41.0 | 3.44.9 |
|---|---|---|
| `ui.semantics.tap`，静态被屏蔽目标 | `uiSemanticsActionBlocked`，回调 0 次 | 同左 |
| `ui.semantics.tap`，同一 widget 挂在懒加载列表行上 | **`uiSemanticsActionUnavailable`**，回调 0 次 | `uiSemanticsActionBlocked`，回调 0 次 |
| `ui.reveal`，懒加载列表行上的被屏蔽目标 | **`revealed` + `reachability: pointer`** | `failed` / `targetBlocked` |

防误击闸本身没有被击穿（三种 tap 情形回调都是 0 次，框架掩掉 action 位后 `_dispatch` 的 `hasAction`
复核兜住了）。但两处对外语义在 3.41.x 上是错的：`ui.semantics.*` 用 `uiSemanticsActionUnavailable`
顶替 `uiSemanticsActionBlocked`，正是
[PB-050-16](semantics-occlusion-admission.md) 明令不得串的两个码；`ui.reveal` 契约上不查 action
（`semanticsOnly` 目标本来就允许没有 action），因此没有第二道兜底，直接违反
[PB-050-17](semantics-scroll-reveal.md) 冻结的终止条件矩阵。

**第三层：最早全绿组合是 Flutter 3.44.0。** 初次调查曾记录 3.44.0 / 3.44.1 上三条
`ink_sparkle.frag ... Expected 2, got 1` 失败并推测为 release 缺陷，**该结论已证伪**：那是同一棵工作树
里跨 SDK 切换留下的构建缓存污染（资产 manifest 的 runtime-stages 版本戳由生成它的 SDK 决定，缓存不随
SDK 切换失效）。已在**已知全绿的 3.44.9** 上用同样手法复现出完全相同的异常，清掉 `.dart_tool` /
`build` 后同一个 3.44.9 立刻恢复全绿。清缓存后 3.44.0 自己跑完整 `tool/verify_sdk_floor.sh`：**退出码
0，五个包全部 resolve + analyze + test 通过，共 1498 个测试**。

结论：**「最早全绿」与「最早语义正确」在 3.44.0 上重合**，把下限提到这里没有已知残留阻塞。

## 目标与非目标

### 目标

- 把四个 package 与 `example` 声明的下限改成一个**真实存在、且被机检证明全绿**的组合：
  Flutter `>=3.44.0` / Dart `>=3.12.0`。
- 让 `sdk_floor` CI lane 从「探测性非阻断」转为「已验证下限的守门」：钉 3.44.0，摘掉
  `allow_failure` / `continue-on-error`。
- 把 PB-050-28 按「上游缺陷、经下限提升消解」收尾，不在本仓引入补偿机制。
- 用户可见文档（根 README 双语、`docs/guide.md`）的下限数字与 pubspec 同步。

### 非目标

- **不为 3.41.x 引入任何兼容层。** 详见「被否决方案」。
- 不修改 `areUserActionsBlocked`、`isInvisible` 的既有含义，不动 PB-050-16 的遮挡准入算法，不动
  PB-050-17 的步进循环与终止条件矩阵，不动 PB-050-07 已裁决的请帧策略——本条一行实现代码都不改。
- 不改 wire、`schemaVersion`、descriptor、稳定错误码或任何 JSON 形状。
- 不回填 `docs/compat-matrix.md` 的历史行：已发布 tag 的 `>=3.38.0` 是历史事实，新下限从下一个 tag 的
  新行开始体现（该行由 `release_prep --apply` 按 pubspec 现值生成）。
- 不提高 CI 上界（继续 3.44.9），不改其余三条 lane 的通过标准。

## 契约

**声明下限**（唯一真源是 pubspec，其余文档同步它）：

| 位置 | 旧 | 新 |
|---|---|---|
| `packages/patchbay/pubspec.yaml` | `sdk: '>=3.11.0 <4.0.0'` | `sdk: '>=3.12.0 <4.0.0'` |
| `packages/patchbay_cli/pubspec.yaml` | 同上 | 同上 |
| `packages/patchbay_transport/pubspec.yaml` | 同上 | 同上 |
| `packages/patchbay_flutter/pubspec.yaml` | 同上 + `flutter: '>=3.38.0'` | 同上 + `flutter: '>=3.44.0'` |
| `packages/patchbay_flutter/example/pubspec.yaml` | 同上 + `flutter: '>=3.38.0'` | 同上 + `flutter: '>=3.44.0'` |

两个数字必须成对：Flutter 3.44.0 内置 Dart 3.12.0，这是它们第一次指向同一个真实 release。**今后修改
任一个都必须重新核对官方 release 清单**，不允许再出现「两个数字各自合理、交集为空」的声明。

**`sdk_floor` lane 的语义变更。** 这条 lane 此前的含义是「探测最早可安装组合在真实 CI 上的表现，
跑红不阻断」；本条之后它的含义是**「已验证下限的守门」**——它跑的版本就是 pubspec 声明的下限，跑红
即代表声明下限不再成立，必须阻断。因此 `.gitlab-ci.yml` 的 `allow_failure: true` 与
`.github/workflows/ci.yml` 的 `continue-on-error: true` 在同一提交内摘除，钉的 archive 同步换成
3.44.0（Linux `e1ec95e6…c7d5`）。

**下限与 CI 上界仍是两件事**：下限 3.44.0 是声明承诺并被这条 lane 守住，上界 3.44.9 是
`FLUTTER_VERSION` 实际跑的版本；两者之间未逐版本回归，`docs/compat-matrix.md` 已有的口径不变。

## 状态、失败与预算

本条不引入状态机、超时、重试或资源上限——它没有运行时组件。唯一的"失败模式"是 CI 判定：

- `sdk_floor` 跑红 ⇒ 声明下限不成立，阻断合入。修复方向只有两个：修代码让下限重新成立，或再走一次
  Proposal 调整下限数字。**不允许通过重新挂上 `allow_failure` 来消音。**
- `release_prep --check` 的 `compat-matrix-*` 判定会在定版时比对 `docs/compat-matrix.md` 新行的
  `Flutter（文档最低支持）` 与 `packages/patchbay_flutter/pubspec.yaml` 现值；本条改了 pubspec，
  0.5.0 定版时该行按新值生成，不需要人工回填。

**本地复现纪律（写进 `tool/verify_sdk_floor.sh` 头注释与调查文档）**：在同一棵工作树里切换 Flutter
版本跑测试之前必须删掉每个包的 `.dart_tool` 与 `build`，否则会得到 `ink_sparkle.frag ... Expected 2,
got 1` 这类假失败——「已知问题二」就是这么被误记成 release 缺陷的。CI 每次都是干净容器，不受影响。

## 兼容与降级

- **这是收紧方向的兼容范围变更**，也是本条唯一的用户可见影响：仍停在 Flutter 3.38–3.43 / Dart
  3.10–3.11 的接入方无法解析新版本。诚实说明：**其中 3.38–3.40 段本来就是空的**（那些 Flutter 版本
  的自带 Dart 不满足旧的 `sdk: '>=3.11.0'`，根本装不出可用组合），真正被排除的只有 3.41.x——而
  3.41.x 上 `ui.reveal` 的遮挡判定本来就是错的。因此实际损失的是「一段本来就不该被承诺的支持面」。
- **wire / 协议层完全不变**：`schemaVersion` 不动，descriptor、参数、稳定错误码、JSON 形状逐字节
  不变。老 CLI ↔ 新 host、新 CLI ↔ 老 host 的握手行为不受影响——SDK 下限是构建期约束，不进
  运行时协商。
- **VM Service ↔ direct**：两条传输共享同一实现，本条不触碰任何实现代码，两端行为一致。
- **release 构建**：不新增暴露面，`kReleaseMode` 裁除边界不变。
- 接入方升级路径就是把自己的 Flutter 升到 3.44.0 及以上，无代码改动。

## 安全与隐私

- 本条**修复的正是一处安全边界的对外语义错误**：3.41.x 上 `ui.reveal` 会把被模态屏蔽的目标报成
  `revealed`。提升下限之后该格恢复为 PB-050-17 冻结的 `failed` / `targetBlocked`。
- 不新增声明门、参数或环境变量，不改脱敏边界，不改 release 裁除。
- 不引入 bypass：本条**没有**提供「在 3.41.x 上继续使用但跳过遮挡判定」的开关——那等于把已知
  fail-open 变成可配置项。

## 验证

- **单元/协议测试**：不涉及实现改动，判据是既有全套测试在新下限上全绿。已实测：Flutter 3.44.0
  清缓存后 `tool/verify_sdk_floor.sh` 退出码 0，五包 1498 个测试（490 + 669 + 29 + 290 + 20）全部通过，
  日志中无 `ink_sparkle`。
- **上界回归**：Flutter 3.44.9 上 `patchbay_flutter` 290/290 全绿，`dart format` 无改动，
  `flutter analyze --fatal-infos` `No issues found!`——本条不改实现代码，上界行为逐字节不变。
- **反向证据（下限的必要性）**：Flutter 3.41.0 清缓存后 `+289 -1`，唯一失败是
  「ModalBarrier 盖住已挂载目标」；两版本插桩矩阵与端到端影响面表见「问题」一节。
- **VM/direct**：无实现改动，两端跑同一份既有矩阵。
- **失败注入**：`sdk_floor` lane 摘掉 `allow_failure` 之后，下限跑红即阻断——这条 lane 本身就是本条的
  持续验证装置。
- **接入方/真机**：不需要。本条不改变任何运行时行为，接入方侧的动作只有升级自身 Flutter 版本。

## 待裁决

- 下限提到 3.44.0（含上游修复的第一个 stable）还是直接提到 3.44.9（本次调查最先确认全绿的版本）？
- 是否保留 3.41.x 支持并为它写一个兼容层？

### 裁决结论（2026-08-27，仓主在会话中裁决，授权与过程记录于本 MR）

仓主在会话中裁决采用**口径 A**。三条结论：

1. **下限提至 Flutter `>=3.44.0` / Dart `>=3.12.0`**，取含上游 `af35e77c83d` 的第一个 stable，而不是
   更保守的 3.44.9。理由：3.44.0 已由清缓存后的完整 `verify_sdk_floor.sh` 证明全绿（退出码 0、五包
   1498 测试），再往上加保守余量只会无理由排除 3.44.0–3.44.8 的接入方；「已知问题二」这一顾虑已被
   证伪，不再构成把下限往上推的依据。
2. **`sdk_floor` lane 同一提交内钉 3.44.0 并摘掉 `allow_failure` / `continue-on-error`。** 两件事必须
   同一个提交：先摘 `allow_failure` 会把主线打红（lane 还跑着必然红的 3.41.0），先换版本不摘则这条
   lane 仍然不设防。
3. **不为 3.41.x 写兼容层**，PB-050-28 按「上游缺陷、经下限提升消解」收尾，本仓不引入补偿机制。

## 被否决方案

- **在 `reveal_engine.dart` 里多等一帧再读 `areUserActionsBlocked`**：根因不是时序，多等 3 帧值不变，
  连症状都治不了；即便有效也会给 3.44.9 的每步 cadence 多加一帧，违反 PB-050-17 冻结的「第 i 步恰好
  一帧」，并可观测地改变同一次调用的 `afterTreeRevision` 与 deadline 消耗。
- **版本感知兼容层（检测到 3.41.x 就走另一条判定）**：无物可补。需要的信息不在语义树里，不是晚到——
  目标节点自身与整条祖先链的 `areUserActionsBlocked` 全是 `false`，节点无子节点，`SemanticsData`
  也没有任何字段能区分「action 被掩掉」与「本来就没有该 action」。版本探测之后依然无信号可读。
- **走渲染树恢复该信息**（解析目标的 `RenderObject` 锚点、逐个重新求值
  `describeSemanticsConfiguration` 找 `isBlockingUserActions`）：这是在安全边界内新造机制——重复实现
  框架内部逻辑、依赖 `debugSemantics`（`kReleaseMode` 下为 null，于是 `targetBlocked` 判定会 debug /
  release 分叉），并直接改动 PB-050-16 冻结的「不修改 `areUserActionsBlocked` 的既有含义」。为了兼容
  一个上游已修复的版本段而永久背上这套机制，代价与收益完全不成比例。
- **给测试 fixture 加 `container: true` 让 3.41.0 转绿**：这会让断言通过而缺陷仍在——真实接入方写的
  就是不带 `container: true` 的 `Semantics(identifier:)`，改 fixture 等于把一个真实 fail-open 藏起来。
  仓规也明令不得为让测试通过而放宽安全边界断言。
- **把 `sdk_floor` lane 长期挂 `allow_failure` 并把 3.41.x 记为「可安装但语义不受支持」**（即口径 B）：
  声明下限与实际支持面继续背离，接入方仍会按声明装出一个 `ui.reveal` 判定错误的组合，而 CI 对此
  永久沉默。既然已经有一个被证明全绿的下限，没有理由继续维持这种背离。
- **下限直接提到 3.44.9**：见裁决结论第 1 条——会无理由排除 3.44.0–3.44.8。
- **维持 `flutter: '>=3.38.0'` 只改文档措辞**：那个数字指向的组合装不出来，改措辞不能让它变成真的。
