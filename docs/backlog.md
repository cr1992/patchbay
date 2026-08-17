# 问题与特性台账

> 本仓已确认缺陷与待实现特性的**唯一真源**。新条目随发现进表，带一句动机与证据指针；
> 完成后随发版移入 CHANGELOG 对应版本段并从此处删行。`design-gate` 条目未经仓主裁决
> 不得进入实现 MR。只记结论与指针，不写过程叙事；裁决理由在对应 MR / note。
> 已裁决不做的方向见 [design.md 的非目标台账](design.md)，此处不重复、不重提。
>
> 当前排期见 [Patchbay 0.4.0 版本计划](releases/0.4.0.md)。进入版本计划不等于越过设计闸门；
> `待裁决` 条目必须先完成对应裁决，才能进入实现 MR。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| （暂无已知未修缺陷） | | |

## 特性

| 编号 | 条目 | 动机 / 出处 | 目标版本 | 状态 / 备注 |
|---|---|---|---|---|
| PB-040-01 | 锚定式手势 `ui.gesture.*`：press-hold / drag 路径 / fling，identifier 锚定 + 相对比例坐标 + 代际围栏 | 接入方真机验证分工：方向盘按压态、小窗拖动只能 adb 坐标打 | 0.4.0 | **待裁决**：DG-040-01 |
| PB-040-02 | 定时 capture + golden diff：第 N 帧截取、两帧差异率 | 接入方：首帧变形取证只能 screencap 关键帧对比（Flutter 自绘部分可收编；OS 合成层不做，见非目标） | 0.4.0 | 已排期（P1） |
| PB-040-03 | 屏幕唤醒：会话活跃期间 app 自动 keep-screen-on（Android `FLAG_KEEP_SCREEN_ON` + iOS `isIdleTimerDisabled`，会话静默自动释放，debug-only） | 真机调试息屏即 UI 面全拒（实测），iOS 无系统级 stay-awake；自动会使息屏行为本身的测试失真，需留关闭出口。同批的 lifecycle 提示与 `patchbay doctor` 已实现 | 0.4.0 | **待裁决**：DG-040-02 |
| PB-040-04 | host 侧声明 `snapshotSelectors` capability，CLI 据此判定而非猜测失败形态 | 现状是 CLI 捕获 `invalidParams` / `protocolError` 反推「老 host」，能给出类型化拒绝但属推断；正路是 host 声明能力 | 0.4.0 | 已排期（P0）；前置已解除：feature capabilities 已合入（849043a） |
| PB-040-05 | 统一 CommandRegistry：descriptor+decoder+gate+handler+validator 过同一 dispatcher | 第二 consumer 手写 adapter 的元键坑已实证核心不机检 descriptor 语义的风险 | 0.4.0 | 已排期（P0） |
| PB-040-06 | CLI 注册 / 帮助表改由命令 descriptor 生成 | `packages/patchbay_cli/lib/src/cli.dart` 的手写 switch 臂是 0.3.0 并行开发中最大的一类冲突源——每支加命令都改同一处 | 0.4.0 | 已排期（P0）；依赖 PB-040-05 |
| PB-040-07 | README / 文档命令参考表由 descriptor / help 输出生成 | 双语 README 与包 README 的命令表靠人肉逐字节核对保持一致 | 0.4.0 | 已排期（P0）；依赖 PB-040-06 |
| PB-040-08 | 幂等 retryPolicy（external 命令按 requestId 去重）；审计 sink（可注入、记脱敏参数形状）；CLI `describe` | dogfood（`doctor` 已实现） | 0.4.0 | 已排期（P1）；依赖 PB-040-05 |
| PB-040-09 | DevTools 借用剩余两批：perf VM RPC → net 画像 | 规划稿已交仓主；第一批 inspect 开关已合入 main | 0.4.0 | perf 已排期（P1）；net **待裁决**：DG-040-03 |
| PB-040-10 | snapshot revision / diff | dogfood（低优先级） | 0.4.0 | 已排期（P2） |
| PB-040-11 | launcher 监督循环收编：把首个接入方项目级的重连监督（退避策略 + machine-frame 生命周期 + 断连判读）抽为 patchbay_cli 通用 `launch` 能力；会话记录 schema 增显式 pending 状态位（现依赖 consumer 侧以自身 PID 通过探活的巧劲，跨仓契约应显式化） | 首个接入方已落项目级实现并真机验证；第二接入方已集成 session store，其启动器必复踩「断连即退」 | 0.4.0 | 已排期（P0）；待首个实现烤稳与第二试点确认形态 |
| PB-040-12 | `ui verify-manifest` 按 destination 逐屏巡检：驱动导航依次落到每个被声明的屏，覆盖非常驻控件 | v1 只对账当前挂载态、`destination` 仅作过滤（已落，见 CHANGELOG）；巡检要驱动导航，改变「只读对账」的性质 | 0.4.0 | 已排期（P1）；依赖 PB-040-14、PB-040-15 |
| PB-040-13 | `ui verify-manifest` 接受 YAML manifest | v1 只认 JSON；大清单人手维护 YAML 更省事，但要引入解析依赖 | 0.4.0 | 已排期（P2） |
| PB-040-14 | `ui verify-manifest` 覆盖 Semantics identifier（`ui tap` 的目标面） | catalog `uiTargets` 只登记 `PatchbayKey` 注册的 text / capture 目标，可点控件的 identifier 不在其中；要取 `ui.semantics.tree`，那是另一个命名空间和另一套挂载语义 | 0.4.0 | 已排期（P1） |
| PB-040-15 | `ui targets --emit-manifest`：从活体 catalog 生成 expected-targets manifest 初稿 | 真机验收现在要照着 catalog 手抄 `ui verify-manifest` 清单 | 0.4.0 | 已排期（P0） |
| PB-040-16 | `wire_codegen --write` 顺手刷新协议面 surface golden | golden 重生成是与 codegen 分离的手工步骤（`PATCHBAY_UPDATE_GOLDENS=1 dart test`），哨兵只在聚合 / rebase 期才触发：0.3.0 四支各自绿、合成才红，一次性补进 12 个 wire 类型（7eb6236） | 0.4.0 | 已排期（P0） |
| PB-040-17 | `release_prep --apply` 覆盖 `patchbayPackageVersion` 与两份 README 的版本引用 | apply 代改四包 version 却不动这两处，只有 `release_version_parity_test` 事后兜住（0.3.0 定版实撞：apply 后测试红）；该常量被 host 当 `serverVersion` 报给客户端，漂移即全网 App 谎报构建 | 0.4.0 | 已排期（P0） |
| PB-040-18 | `release_prep --apply` 时自动冻结本版协议面进兼容语料库 | `packages/patchbay_cli/test/golden/legacy_host_v0_2_0/` 一类的旧版语料是手工冻结的，版本过去后不可再生成 | 0.4.0 | 已排期（P0） |
| PB-040-19 | command_codegen check 的样例 contract 瘦身 | `packages/patchbay/contracts/example_commands.g.dart` 208 行生成物只为喂 drift 门禁而长期入仓，应改由真实命令声明推导 | 0.4.0 | 已排期（P2）；依赖 PB-040-05 |
| PB-040-20 | CHANGELOG 碎片化：`changelog.d/` 每 MR 一文件 + `release_prep` 聚合 | 0.3.0 每对并行分支都在根 CHANGELOG 同一处相撞，是结构性冲突源 | 0.4.0 | 实现中（P0）：规范与 PR 流程已落地，自动聚合待实现 |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| （暂无） | |

## design-gate（需仓主裁决后动工）

| 编号 | 裁决点 | 目标版本 | 状态 |
|---|---|---|---|
| DG-040-04 | macOS 桌面 lifecycle 闸判定：「失焦但在渲」是否放行；桌面端改帧活性判定、移动端维持 `resumed`（方案 A），第二 consumer 有复现环境可验证 | 0.4.0 | 待裁决 |
| DG-040-01 | 锚定式手势：相对比例坐标手势与「不做坐标定位」立场的边界划法 | 0.4.0 | 待裁决 |
| DG-040-02 | 自动 keep-screen-on：默认自动还是手动，以及关闭出口与静默释放语义 | 0.4.0 | 待裁决 |
| DG-040-03 | DevTools net 画像：请求画像的脱敏口径 | 0.4.0 | 待裁决 |

## 维护规则

- 一条一行，动机一句话，证据给指针；不粘贴过程。
- 状态只用：`待排期`、`待裁决`、`已排期`、`实现中`、`已验证`；版本计划负责定义优先级与退出条件。
- 完成 = 移入 CHANGELOG 对应版本段并删行；放弃 = 移入 design.md 非目标台账并写理由。
- 延期 = 通过范围变更 MR 清除目标版本、标回 `待排期`，并保留未满足的证据指针。
- 每次发版前过一遍本表，与 CHANGELOG、兼容矩阵同批核对。
