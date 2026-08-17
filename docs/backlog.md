# 问题与特性台账

> 本仓已确认缺陷与待实现特性的**唯一真源**。本文件只维护编号、标题、动机、目标版本、实施状态和
> Proposal 指针；优先级、依赖、验收与技术方案分别由版本计划和 Proposal 维护。完整权责见
> [规划与交付治理](planning.md)。完成后随发版移入 CHANGELOG 对应版本段并从此处删行。
> `design-gate` 条目未经仓主裁决不得进入实现 MR。
> 已裁决不做的方向见 [design.md 的非目标台账](design.md)，此处不重复、不重提。
>
> 当前排期见 [Patchbay 0.4.0 版本计划](releases/0.4.0.md)。进入版本计划不等于越过设计闸门；
> `待裁决` 条目必须先完成对应裁决，才能进入实现 MR。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| （暂无已知未修缺陷） | | |

## 特性

| 编号 | 条目 | 动机 / 出处 | 目标版本 | 状态 | Proposal / 备注 |
|---|---|---|---|---|---|
| PB-040-01 | 锚定式手势 `ui.gesture.*`：press-hold / drag 路径 / fling，identifier 锚定 + 相对比例坐标 + 代际围栏 | 接入方真机验证分工：方向盘按压态、小窗拖动只能 adb 坐标打 | 0.4.0 | 待裁决 | [锚定式手势](proposals/0.4.0/anchored-gestures.md)；DG-040-01 |
| PB-040-02 | 定时 capture + golden diff：第 N 帧截取、两帧差异率 | 接入方：首帧变形取证只能 screencap 关键帧对比（Flutter 自绘部分可收编；OS 合成层不做，见非目标） | 0.4.0 | 已排期 | [视觉证据](proposals/0.4.0/visual-evidence.md) |
| PB-040-03 | 屏幕唤醒：会话活跃期间 app 自动 keep-screen-on（Android `FLAG_KEEP_SCREEN_ON` + iOS `isIdleTimerDisabled`，会话静默自动释放，debug-only） | 真机调试息屏即 UI 面全拒（实测），iOS 无系统级 stay-awake；自动会使息屏行为本身的测试失真，需留关闭出口 | 0.4.0 | 待裁决 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md)；DG-040-02 |
| PB-040-04 | host 侧声明 `snapshotSelectors` capability，CLI 据此判定而非猜测失败形态 | 现状是 CLI 捕获 `invalidParams` / `protocolError` 反推“老 host”；feature capabilities 前置已合入（849043a） | 0.4.0 | 已排期 | — |
| PB-040-05 | 统一 CommandRegistry：descriptor+decoder+gate+handler+validator 过同一 dispatcher | 第二 consumer 手写 adapter 的元键坑已实证核心不机检 descriptor 语义的风险 | 0.4.0 | 已排期 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-06 | CLI 注册 / 帮助表改由命令 descriptor 生成 | `packages/patchbay_cli/lib/src/cli.dart` 的手写 switch 臂是 0.3.0 并行开发中最大的一类冲突源 | 0.4.0 | 已排期 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-07 | README / 文档命令参考表由 descriptor / help 输出生成 | 双语 README 与包 README 的命令表靠人肉逐字节核对保持一致 | 0.4.0 | 已排期 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-08 | 幂等 retryPolicy；审计 sink；CLI `describe` | dogfood（`doctor` 已实现） | 0.4.0 | 已排期 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-09 | DevTools 借用剩余两批：perf VM RPC → net 画像 | 第一批 inspect 开关已合入 main；net 画像仍需冻结脱敏口径 | 0.4.0 | 待裁决 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md)；DG-040-03 |
| PB-040-10 | snapshot revision / diff | dogfood（低优先级） | 0.4.0 | 已排期 | [视觉证据](proposals/0.4.0/visual-evidence.md) |
| PB-040-11 | launcher 监督循环与显式 pending session | 首个接入方已落项目级重连监督，第二接入方已集成 session store | 0.4.0 | 已排期 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md) |
| PB-040-12 | `ui verify-manifest` 按 destination 逐屏巡检 | v1 只对账当前挂载态；巡检会驱动导航并改变 App 状态 | 0.4.0 | 已排期 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-13 | `ui verify-manifest` 接受 YAML manifest | v1 只认 JSON；大清单人手维护 YAML 更省事 | 0.4.0 | 已排期 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-14 | `ui verify-manifest` 覆盖 Semantics identifier | catalog `uiTargets` 与 Semantics identifier 是两个命名空间和两套挂载语义 | 0.4.0 | 已排期 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-15 | `ui targets --emit-manifest` 生成 expected-targets manifest 初稿 | 真机验收现在要照着 catalog 手抄清单 | 0.4.0 | 已排期 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-16 | `wire_codegen --write` 顺手刷新协议面 surface golden | golden 重生成与 codegen 分离，0.3.0 聚合时才发现 12 个 wire 类型漂移（7eb6236） | 0.4.0 | 已排期 | — |
| PB-040-17 | `release_prep --apply` 覆盖 `patchbayPackageVersion` 与两份 README 的版本引用 | 0.3.0 定版实撞 apply 后版本引用漂移；host 会据此报告 `serverVersion` | 0.4.0 | 已排期 | — |
| PB-040-18 | `release_prep --apply` 自动冻结本版协议面进兼容语料库 | 旧版语料目前手工冻结，版本过去后不可再生成 | 0.4.0 | 已排期 | — |
| PB-040-19 | command_codegen check 的样例 contract 瘦身 | 208 行样例生成物只为 drift 门禁长期入仓 | 0.4.0 | 已排期 | — |
| PB-040-20 | CHANGELOG 碎片化：每 MR 一文件 + `release_prep` 聚合 | 0.3.0 并行分支持续冲突根 CHANGELOG | 0.4.0 | 实现中 | 规范与 MR 流程已落地，自动聚合待实现 |
| PB-040-21 | 统一执行证据模型：区分未发送、已发送未确认、同值无变化、设备已确认 | DP 同值写入时设备不回报，已造成回归误判 | 0.4.0 | 待裁决 | [命令契约](proposals/0.4.0/command-contracts.md)；DG-040-05 |
| PB-040-22 | command/job 响应 schema | `--json` 只稳定外层信封，自由 `Map` 仍迫使脚本到处判空 | 0.4.0 | 已排期 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-23 | 调试轨迹持久化：以 traceId 记录跨命令 session、请求/响应、job、执行证据、人工标记与 artifact，支持查看、导出和 diff | 一次调试的细节目前散落在终端历史、临时 JSON 和 App 内存中，无法复盘或比较回归 | 0.4.0 | 已排期 | [调试轨迹](proposals/0.4.0/debug-traces.md) |
| PB-040-24 | 从调试轨迹生成 scenario 并受控回放 | 跑通的操作链需要沉淀为自动化，但应等待 recorder、权限 driver 和真实轨迹 schema 稳定 | — | 待排期 | [未来回放](proposals/future/trace-replay.md)；DG-040-06 |
| PB-040-25 | 平台权限状态与规范化：AI 可查询 capability/status，并以 normalize/exercise/fail 策略建立权限前置条件 | 原生权限状态具有历史性；不预检就会让同一调试链在首次、已授权、永久拒绝设备上走不同路径 | 0.4.0 | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07 |
| PB-040-26 | 系统权限弹窗 driver 与恢复协议：Android adb/UiAutomator、iOS simctl/XCUITest，处理后重新握手和解析目标 | Patchbay 只能观察 Flutter UI；系统弹窗会遮挡目标或改变 lifecycle，当前只能超时或等待人工处理 | 0.4.0 | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07 |
| PB-040-27 | HarmonyOS 兼容验证与 permission driver：OpenHarmony Flutter、VM attach、Semantics/lifecycle、hdc + UiTest/Hypium | 架构可接入，但当前 Flutter 3.44.9 CI 与真机均未覆盖 HarmonyOS，不能直接宣称支持 | 0.4.0 | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07 |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| （暂无） | |

## design-gate（需仓主裁决后动工）

| 编号 | 裁决点 | 目标版本 | 状态 | Proposal |
|---|---|---|---|---|
| DG-040-04 | macOS 桌面 lifecycle 闸判定：“失焦但在渲”是否放行 | 0.4.0 | 待裁决 | [Launcher](proposals/0.4.0/launcher-session.md)、[手势](proposals/0.4.0/anchored-gestures.md) |
| DG-040-01 | 锚定式手势：相对比例坐标与“不做坐标定位”的边界 | 0.4.0 | 待裁决 | [锚定式手势](proposals/0.4.0/anchored-gestures.md) |
| DG-040-02 | 自动 keep-screen-on：默认行为、关闭出口与静默释放 | 0.4.0 | 待裁决 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md) |
| DG-040-03 | DevTools net 画像的采集前脱敏口径 | 0.4.0 | 待裁决 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md) |
| DG-040-05 | 执行证据词表、job 终态和 CLI 退出码的边界 | 0.4.0 | 待裁决 | [命令契约](proposals/0.4.0/command-contracts.md) |
| DG-040-06 | 轨迹回放的写操作确认、目标重解析、敏感值重新注入和失败停止语义 | — | 待裁决 | [未来回放](proposals/future/trace-replay.md) |
| DG-040-07 | platform driver 的信任边界、`exercise allow` 确认模型、Android/iOS P0 权限集合与 HarmonyOS 验证基线 | 0.4.0 | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md) |

## 维护规则

- 一条一行，动机一句话，证据给指针；不粘贴过程，不在状态或备注中重复版本优先级和依赖。
- 状态只用：`待排期`、`待裁决`、`已排期`、`实现中`、`已验证`；版本计划负责优先级、依赖和退出条件。
- `待裁决` 条目必须同时引用 design-gate 和 Proposal；Proposal 状态不代表实施状态。
- 完成 = 移入 CHANGELOG 对应版本段并删行；放弃 = 移入 design.md 非目标台账并写理由。
- 延期 = 通过范围变更 MR 清除目标版本、标回 `待排期`，并保留未满足的证据指针。
- 每个 MR 和发版前运行 `dart run tool/check_planning.dart`。
