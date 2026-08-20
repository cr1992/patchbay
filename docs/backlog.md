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
| BUG-20260819-02：`ui.capture` 在 profile 构建必然失败 | `capture_bridge.dart` 无条件读 debug-only `debugNeedsPaint`；profile 剥断言后该 getter 抛 `LateInitializationError`，在类型化拒绝之前逃逸成 `transportError`。与 `PatchbayRoot` 在 `!kReleaseMode` 即包裹 root boundary 的意图矛盾；`tool/example_session.sh` 只跑 `--debug`，预检从未覆盖该路径 | 已验证 |
| BUG-20260820-01：iOS 权限 capability 把 Simulator `reset` 虚报给物理真机 | `PatchbayIosPermissionAdapter` 只检查本机存在 `simctl` 就静态发布四项 `reset`，未先证明显式 `deviceId` 是 booted Simulator；物理 iPhone 真机实测出现 capability 接受、`status` 却按 `permissionUnsupported` 拒绝的不一致 | 已验证 |
| BUG-20260820-05：`doctor` 在孤儿 pin 场景下 session 检查误报通过 | 当 pinned session 文件已从磁盘删除时，`doctor` 的 session 阶段漏检判 ok，延迟至 connection 阶段才报 `sessionSelectionStale`；现改为 session 阶段直接 fail-closed 并输出 `patchbay session use --clear` 清理建议 | 已验证 |

## 特性

| 编号 | 条目 | 动机 / 出处 | 目标版本 | 状态 | Proposal / 备注 |
|---|---|---|---|---|---|
| PB-040-01 | 锚定式手势 `ui.gesture.*`：press-hold / drag 路径 / fling，identifier 锚定 + 相对比例坐标 + 代际围栏 | 接入方真机验证分工：方向盘按压态、小窗拖动只能 adb 坐标打 | 0.4.0 | 已验证 | [锚定式手势](proposals/0.4.0/anchored-gestures.md)；DG-040-01 |
| PB-040-02 | 定时 capture + golden diff：第 N 帧截取、两帧差异率 | 接入方：首帧变形取证只能 screencap 关键帧对比（Flutter 自绘部分可收编；OS 合成层不做，见非目标） | 0.4.0 | 实现中 | [视觉证据](proposals/0.4.0/visual-evidence.md) |
| PB-040-03 | 屏幕唤醒：会话活跃期间 app 自动 keep-screen-on（Android `FLAG_KEEP_SCREEN_ON` + iOS `isIdleTimerDisabled`，会话静默自动释放，debug-only） | 真机调试息屏即 UI 面全拒（实测），iOS 无系统级 stay-awake；自动会使息屏行为本身的测试失真，需留关闭出口 | 0.4.0 | 实现中 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md)；DG-040-02 |
| PB-040-04 | host 侧声明 `snapshotSelectors` capability，CLI 据此判定而非猜测失败形态 | 现状是 CLI 捕获 `invalidParams` / `protocolError` 反推“老 host”；feature capabilities 前置已合入（849043a） | 0.4.0 | 已验证 | — |
| PB-040-05 | 统一 CommandRegistry：descriptor+decoder+gate+handler+validator 过同一 dispatcher | 第二 consumer 手写 adapter 的元键坑已实证核心不机检 descriptor 语义的风险 | 0.4.0 | 已验证 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-06 | CLI 注册 / 帮助表改由命令 descriptor 生成 | `packages/patchbay_cli/lib/src/cli.dart` 的手写 switch 臂是 0.3.0 并行开发中最大的一类冲突源 | 0.4.0 | 已验证 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-07 | README / 文档命令参考表由 descriptor / help 输出生成 | 双语 README 与包 README 的命令表靠人肉逐字节核对保持一致 | 0.4.0 | 已验证 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-08 | 幂等 retryPolicy；审计 sink；CLI `describe` | dogfood（`doctor` 已实现） | 0.4.0 | 已验证 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-09 | DevTools 借用：perf VM RPC 有界摘要 | 帧耗时、jank、heap 与 GC 计数此前只能开 DevTools 人眼看，CLI 拿不到可机读摘要 | 0.4.0 | 实现中 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md)；net 已拆出为 PB-040-28；待接入方书面确认 perf 口径 |
| PB-040-10 | snapshot revision / diff | dogfood（低优先级） | 0.4.0 | 已验证 | [视觉证据](proposals/0.4.0/visual-evidence.md) |
| PB-040-11 | launcher 监督循环与显式 pending session | 首个接入方已落项目级重连监督，第二接入方已集成 session store | 0.4.0 | 已验证 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md) |
| PB-040-12 | `ui verify-manifest` 按 destination 逐屏巡检 | v1 只对账当前挂载态；巡检会驱动导航并改变 App 状态 | 0.4.0 | 实现中 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-13 | `ui verify-manifest` 接受 YAML manifest | v1 只认 JSON；大清单人手维护 YAML 更省事 | 0.4.0 | 已验证 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-14 | `ui verify-manifest` 覆盖 Semantics identifier | catalog `uiTargets` 与 Semantics identifier 是两个命名空间和两套挂载语义 | 0.4.0 | 实现中 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-15 | `ui targets --emit-manifest` 生成 expected-targets manifest 初稿 | 真机验收现在要照着 catalog 手抄清单 | 0.4.0 | 已验证 | [Manifest 与巡检](proposals/0.4.0/manifest-navigation.md) |
| PB-040-16 | `wire_codegen --write` 顺手刷新协议面 surface golden | golden 重生成与 codegen 分离，0.3.0 聚合时才发现 12 个 wire 类型漂移（7eb6236） | 0.4.0 | 已验证 | — |
| PB-040-17 | `release_prep --apply` 覆盖 `patchbayPackageVersion` 与两份 README 的版本引用 | 0.3.0 定版实撞 apply 后版本引用漂移；host 会据此报告 `serverVersion` | 0.4.0 | 已验证 | — |
| PB-040-18 | `release_prep --apply` 自动冻结本版协议面进兼容语料库 | 旧版语料目前手工冻结，版本过去后不可再生成 | 0.4.0 | 已验证 | — |
| PB-040-19 | command_codegen check 的样例 contract 瘦身 | 208 行样例生成物只为 drift 门禁长期入仓 | 0.4.0 | 已验证 | — |
| PB-040-20 | CHANGELOG 碎片化：每 MR 一文件 + `release_prep` 聚合 | 0.3.0 并行分支持续冲突根 CHANGELOG | 0.4.0 | 已验证 | 规范与 MR 流程已落地，自动聚合待实现 |
| PB-040-21 | 统一执行证据模型：区分未发送、已发送未确认、同值无变化、设备已确认 | DP 同值写入时设备不回报，已造成回归误判 | 0.4.0 | 实现中 | [命令契约](proposals/0.4.0/command-contracts.md)；DG-040-05 |
| PB-040-22 | command/job 响应 schema | `--json` 只稳定外层信封，自由 `Map` 仍迫使脚本到处判空 | 0.4.0 | 已验证 | [命令契约](proposals/0.4.0/command-contracts.md) |
| PB-040-23 | 调试轨迹持久化：以 traceId 记录 CLI 实际观察到的跨命令 session、请求/响应、job、执行证据、人工标记与 artifact，支持查看、导出和 diff；host-only audit 不自动回传 | 一次调试的细节目前散落在终端历史、临时 JSON 和 App 内存中，无法复盘或比较回归 | 0.4.0 | 实现中 | [调试轨迹](proposals/0.4.0/debug-traces.md) |
| PB-040-24 | 从调试轨迹生成 scenario 并受控回放 | 跑通的操作链需要沉淀为自动化，但应等待 recorder、权限 driver 和真实轨迹 schema 稳定 | — | 待排期 | [未来回放](proposals/future/trace-replay.md)；DG-040-06 |
| PB-040-29 | example 覆盖全部可注入面 + 本地端到端预检 `tool/example_precheck.sh` | CI 三个 job 全在无设备容器里跑，证明不了「CLI 真的连上了设备上的 host」；example 此前只接 0.3.0 时代的面，0.4.0 能力在设备上一条都打不到 | 0.4.0 | 已验证 | 预检门禁见 [发版清单](release-checklist.md) 第 2 节；SC-040-04 |
| PB-040-28 | DevTools 借用：net 脱敏画像 | 阻塞在上游——`vm_service 15.2.0` 的 `getHttpProfile` 在调用方介入前已带 body/headers/cookies 与含 query 值的 URI，RPC 无采集前过滤参数，先收全量再脱敏已被 DG-040-03 否决。0.4.0 交付形态是不发布 capability、稳定返回 `networkProfilingUnavailable` | — | 待排期 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md) 的「net 的实现阻断」；DG-040-03；解除条件是上游开放采集前字段过滤，或接入方提供只产生已脱敏事件的 host collector |
| PB-040-25 | 平台权限状态与规范化：AI 可查询 capability/status，并以 Android adb 的 normalize/reset/fail 建立可复核的权限前置状态 | 原生权限状态具有历史性；不预检就会让同一调试链在首次、已授权、永久拒绝设备上走不同路径 | 0.4.0 | 已验证 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；SC-040-02；SC-040-03；[Android 矩阵](verification/android-permission-matrix.md)；[example 矩阵](verification/example-permission-matrix.md) |
| PB-040-26 | iOS XCUITest 系统权限弹窗 runner 与恢复协议 | Patchbay 只能观察 Flutter UI；真机实践证明“App 触发 + XCTest reset/alert accessibility + 重连复核”可形成不使用坐标或私有 API 的闭环 | 0.4.0 | 已验证 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；SC-040-05；[真机矩阵](verification/ios-permission-xcuitest.md) |
| PB-040-27 | HarmonyOS 兼容验证 spike 与 permission capability 矩阵：OpenHarmony Flutter、VM attach、Semantics/lifecycle、hdc + UiTest/Hypium | 架构可接入，但当前 Flutter 3.44.9 CI 与真机均未覆盖 HarmonyOS，不能直接宣称支持 | 0.4.0 | 实现中 | [平台权限](proposals/0.4.0/platform-permissions.md)；[当前报告](verification/harmonyos-compatibility.md)；已到 SDK/真机阻塞，capability 保持 `unsupported` |
| PB-040-30 | 失效会话的引导式恢复：列出同一应用的可用候选，并在显式确认后完成 prune / reselect / rebind | 真机长流程伴随进程替换时，既有 `sessionStaleProcess` fail-closed 能防止误连另一设备，但操作员仍需手工拼接恢复步骤；需要在不静默回退固定会话的前提下降低恢复成本 | — | 待排期 | 落地前补 Proposal；保持“固定会话不自动改选”的既有安全边界 |
| PB-040-31 | CLI 长流程状态可视化：持续呈现当前命令、job phase、外部 driver 等待、终态与恢复提示 | CLI 目前适合机器读取最终信封，但操作者在长流程中难以判断是在执行、等待外部系统 UI 还是已经结束；需要一个仍保持结构化输出与脱敏边界的 Patchbay 自有进度面 | — | 待排期 | 与 job 事件和 PB-040-26 恢复阶段共用事实源，不要求接入方 App 提供调试 UI，也不新增第二套状态机 |
| PB-040-32 | 敏感参数的字段级无回显注入：由 descriptor 声明 sensitive 字段，CLI 通过 prompt/provider 合并且不进入 argv、history 或 trace | 现有 `--stdin` 能安全注入整行 JSON，但真实长流程仍需人工组装 payload；字段级输入可降低误回显和结构错误，同时保持自动化入口 | — | 待排期 | 与 PB-040-24 的回放凭据重新注入共用安全边界；落地前补 Proposal |
| PB-040-33 | Android 官方 UiAutomator reference runner 与通用系统弹窗识别 | Android OEM 对权限弹窗结构存在差异；应以 Android 官方 accessibility/resource 能力为基线、逐设备探测并 fail-closed，不把逐 OEM 文案与坐标 matcher 变成核心契约 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；由 SC-040-02 延期 |
| PB-040-34 | 权限专用 trace 事件与损坏轨迹下的恢复语义 | 权限状态机需要可复盘，但 trace 写入侧事件类型是封闭表；必须先裁决损坏轨迹是否阻断被观测命令，不能直接把五类权限事件接入 sink | — | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-08 待建立 |
| PB-040-35 | iOS 真机权限 `status/normalize` 的权威事实源 | XCTest 能 reset 与操作系统弹窗，但没有面向任意真机 App 的通用公开授权查询/grant API；不能把 XCTest 命令退出 0 当成设备状态 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；保持 capability unsupported，落地前补 Proposal |
| PB-040-36 | iOS notifications reset 与接入方触发端到端矩阵 | XCTest 没有 notifications 的 protected resource reset，且系统弹窗必须由 App 自己发起；当前 runner 只能处理已出现的弹窗，尚不能形成可重复初始态 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；0.4.0 降级边界见 SC-040-05 |
| PB-040-37 | iOS XCTest reset 后的 debug App 自动重启与 launcher 重附加 | `resetAuthorizationStatus(for:)` 会终止被试 App；launcher 能识别断连但无法自动建立新的 debug isolate，长矩阵需要人工重跑接入方官方 run/attach 工具 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；保持固定 session 不静默改选 |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| （暂无） | |

## design-gate（需仓主裁决后动工）

| 编号 | 裁决点 | 目标版本 | 状态 | Proposal |
|---|---|---|---|---|
| DG-040-04 | macOS 桌面 lifecycle 闸判定：“失焦但在渲”是否放行 | 0.4.0 | 已裁决 | [Launcher](proposals/0.4.0/launcher-session.md)、[手势](proposals/0.4.0/anchored-gestures.md) |
| DG-040-01 | 锚定式手势：相对比例坐标与“不做坐标定位”的边界 | 0.4.0 | 已裁决 | [锚定式手势](proposals/0.4.0/anchored-gestures.md) |
| DG-040-02 | 自动 keep-screen-on：默认行为、关闭出口与静默释放 | 0.4.0 | 已裁决 | [Launcher 与唤醒租约](proposals/0.4.0/launcher-session.md) |
| DG-040-03 | DevTools net 画像的采集前脱敏口径 | 0.4.0 | 已裁决 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md) |
| DG-040-05 | 执行证据词表、job 终态和 CLI 退出码的边界 | 0.4.0 | 已裁决 | [命令契约](proposals/0.4.0/command-contracts.md) |
| DG-040-06 | 轨迹回放的写操作确认、目标重解析、敏感值重新注入和失败停止语义 | — | 待裁决 | [未来回放](proposals/future/trace-replay.md) |
| DG-040-07 | platform driver 的信任边界、`exercise allow` 确认模型、Android/iOS P0 权限集合与 HarmonyOS 验证基线 | 0.4.0 | 已裁决 | [平台权限](proposals/0.4.0/platform-permissions.md) |
| DG-040-08 | 损坏轨迹的恢复与阻断语义，以及权限专用事件扩展写入侧封闭表的前置条件 | — | 待裁决 | [调试轨迹](proposals/0.4.0/debug-traces.md) |

## 维护规则

- 一条一行，动机一句话，证据给指针；不粘贴过程，不在状态或备注中重复版本优先级和依赖。
- 状态只用：`待排期`、`待裁决`、`已排期`、`实现中`、`已验证`；版本计划负责优先级、依赖和退出条件。
- `已验证` 的判据是**验收条件已被机检完全覆盖并跑绿**（CI 门禁、golden、包内测试）。版本计划的退出条件
  点名真机或接入方书面确认的条目，合入后只能记 `实现中`，直到证据到位——绿的单测不代表真机结论。
- `待裁决` 条目必须同时引用 design-gate 和 Proposal；Proposal 状态不代表实施状态。
- 完成 = 移入 CHANGELOG 对应版本段并删行；放弃 = 移入 design.md 非目标台账并写理由。
- 延期 = 通过范围变更 MR 清除目标版本、标回 `待排期`，并保留未满足的证据指针。
- 每个 MR 和发版前运行 `dart run tool/check_planning.dart`。
