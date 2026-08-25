# 问题与特性台账

> 本仓已确认缺陷与待实现特性的**唯一真源**。本文件只维护编号、标题、动机、目标版本、实施状态和
> Proposal 指针；优先级、依赖、验收与技术方案分别由版本计划和 Proposal 维护。完整权责见
> [规划与交付治理](planning.md)。完成后由发布 MR 聚合进 CHANGELOG 对应版本段，并在四包实际发布之后由 finalize 从此处删行。
> `design-gate` 条目未经仓主裁决不得进入实现 MR。
> 已裁决不做的方向见 [design.md 的非目标台账](design.md)，此处不重复、不重提。
>
> 当前排期见 [Patchbay 0.5.0 版本计划](releases/0.5.0.md)。进入版本计划不等于越过设计闸门；
> `待裁决` 条目必须先完成对应裁决，才能进入实现 MR。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| （暂无） | — | — |

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
| PB-040-28 | DevTools 借用：net 脱敏画像 | 阻塞在上游——`vm_service 15.2.0` 的 `getHttpProfile` 在调用方介入前已带 body/headers/cookies 与含 query 值的 URI，RPC 无采集前过滤参数，先收全量再脱敏已被 DG-040-03 否决。0.4.0 交付形态是不发布 capability、稳定返回 `networkProfilingUnavailable` | — | 待排期 | [DevTools 画像](proposals/0.4.0/devtools-profiling.md) 的「net 的实现阻断」；DG-040-03；外部 App 内 observer 实现仅作为调研证据，不解除阻断；解除条件仍是上游开放采集前字段过滤，或接入方提供只产生已脱敏事件的 host collector |
| PB-040-25 | 平台权限状态与规范化：AI 可查询 capability/status，并以 Android adb 的 normalize/reset/fail 建立可复核的权限前置状态 | 原生权限状态具有历史性；不预检就会让同一调试链在首次、已授权、永久拒绝设备上走不同路径 | 0.4.0 | 已验证 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；SC-040-02；SC-040-03；[Android 矩阵](verification/android-permission-matrix.md)；[example 矩阵](verification/example-permission-matrix.md) |
| PB-040-26 | iOS XCUITest 系统权限弹窗 runner 与恢复协议 | Patchbay 只能观察 Flutter UI；真机实践证明“App 触发 + XCTest reset/alert accessibility + 重连复核”可形成不使用坐标或私有 API 的闭环 | 0.4.0 | 已验证 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；SC-040-05；[真机矩阵](verification/ios-permission-xcuitest.md) |
| PB-040-27 | HarmonyOS 兼容验证 spike 与 permission capability 矩阵：OpenHarmony Flutter、VM attach、Semantics/lifecycle、hdc + UiTest/Hypium | 架构可接入，但当前 Flutter 3.44.9 CI 与真机均未覆盖 HarmonyOS，不能直接宣称支持 | 0.4.0 | 实现中 | [平台权限](proposals/0.4.0/platform-permissions.md)；[当前报告](verification/harmonyos-compatibility.md)；已到 SDK/真机阻塞，capability 保持 `unsupported` |
| PB-040-30 | 失效会话的引导式恢复：列出同一应用的可用候选，并在显式确认后完成 prune / reselect / rebind，供 one-shot 与显式选择 `--reconnect` 的 REPL 复用 | 真机长流程伴随进程替换时，既有 `sessionStaleProcess` fail-closed 能防止误连另一设备，但操作员仍需手工拼接恢复步骤；重度 REPL 也已实证 App hot restart 后只能终止并另起进程 | — | 待排期 | 落地前补 Proposal；保持“固定会话不自动改选”，REPL 不得因 `--reconnect` 静默切换 App / device identity |
| PB-040-31 | CLI 长流程状态可视化：持续呈现当前命令、job phase、外部 driver 等待、终态与恢复提示 | CLI 目前适合机器读取最终信封，但操作者在长流程中难以判断是在执行、等待外部系统 UI 还是已经结束；需要一个仍保持结构化输出与脱敏边界的 Patchbay 自有进度面 | — | 待排期 | 与 job 事件和 PB-040-26 恢复阶段共用事实源，不要求接入方 App 提供调试 UI，也不新增第二套状态机 |
| PB-040-32 | 敏感参数的字段级无回显注入：由 descriptor 声明 sensitive 字段，CLI 通过 prompt/provider 合并且不进入 argv、history 或 trace | 现有 `--stdin` 能安全注入整行 JSON，但真实长流程仍需人工组装 payload；字段级输入可降低误回显和结构错误，同时保持自动化入口 | — | 待排期 | 与 PB-040-24 的回放凭据重新注入共用安全边界；落地前补 Proposal |
| PB-040-33 | Android 官方 UiAutomator reference runner 与通用系统弹窗识别 | Android OEM 对权限弹窗结构存在差异；应以 Android 官方 accessibility/resource 能力为基线、逐设备探测并 fail-closed，不把逐 OEM 文案与坐标 matcher 变成核心契约 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-07；由 SC-040-02 延期 |
| PB-040-34 | 权限专用 trace 事件与损坏轨迹下的恢复语义 | 权限状态机需要可复盘，但 trace 写入侧事件类型是封闭表；必须先裁决损坏轨迹是否阻断被观测命令，不能直接把五类权限事件接入 sink | — | 待裁决 | [平台权限](proposals/0.4.0/platform-permissions.md)；DG-040-08 待建立 |
| PB-040-35 | iOS 真机权限 `status/normalize` 的权威事实源 | XCTest 能 reset 与操作系统弹窗，但没有面向任意真机 App 的通用公开授权查询/grant API；不能把 XCTest 命令退出 0 当成设备状态 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；保持 capability unsupported，落地前补 Proposal |
| PB-040-36 | iOS notifications reset 与接入方触发端到端矩阵 | XCTest 没有 notifications 的 protected resource reset，且系统弹窗必须由 App 自己发起；当前 runner 只能处理已出现的弹窗，尚不能形成可重复初始态 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；0.4.0 降级边界见 SC-040-05 |
| PB-040-37 | iOS XCTest reset 后的 debug App 自动重启与 launcher 重附加 | `resetAuthorizationStatus(for:)` 会终止被试 App；launcher 能识别断连但无法自动建立新的 debug isolate，长矩阵需要人工重跑接入方官方 run/attach 工具 | — | 待排期 | [平台权限](proposals/0.4.0/platform-permissions.md)；保持固定 session 不静默改选 |
| PB-050-01 | snapshot provider JSON 边界与冻结读视图 | source 返回非 JSON、非字符串 key、循环引用或过深结构时，canonical 化可能越过 provider 违规边界直接抛错；有效结果又返回 consumer 活对象而非已冻结 revision body | 0.5.0 | 已验证 | [Snapshot provider 边界](proposals/0.5.0/snapshot-provider-boundary.md)；Proposal 接受前只允许失败注入与原型验证 |
| PB-050-02 | snapshot 双预算、single-flight 与可选 source revision | revision 目前只按 32 份计数、没有字节上限；高频 wait 会重复拉取并全量 canonical 编码，consumer 又没有可选的内容 revision 快路径 | 0.5.0 | 待裁决 | [Snapshot 资源与 revision](proposals/0.5.0/snapshot-resources-revisions.md)；DG-050-01 |
| PB-050-03 | invocation catalog policy 热路径与失效协议 | 每次带参数调用都会重建完整 catalog、UI target 与 digest；直接绕过 catalog 又会破坏“任一非法条目使整份目录失效”的 fail-closed 契约 | 0.5.0 | 待裁决 | [Catalog policy 缓存](proposals/0.5.0/catalog-policy-cache.md)；DG-050-02 |
| PB-050-04 | semantics probe 帧放大量测与决策证据 | 每次 probe 都可能主动 `scheduleFrame` 并等待 `endOfFrame`，`ui.wait` 随后还会再等一帧；先量化帧驱动与遍历各自占比，避免在没有事实时优化小头 | 0.5.0 | 已验证 | [量测报告](verification/0.5.0-semantics-probe-benchmark.md)；只交付 instrumentation、benchmark 与建议，不改变请帧、等待、缓存或 generation 行为 |
| PB-050-05 | audit sink 顺序投递与有界背压 | 当前异步 sink 独立启动，完成/持久化顺序无保证，慢 sink 的 pending Future 数量也无上限；审计账本与外部投递缺少一致的丢失报告 | 0.5.0 | 待裁决 | [Audit 有序投递](proposals/0.5.0/audit-delivery.md)；DG-050-03 |
| PB-050-06 | invocation cooperative cancellation、deadline 与统一受理预算 | direct timeout 后保留 slot 是防止卡死 handler 后继续堆积的刻意语义；registry 路径又未纳入 external 的 256 条账本，缺少可证明的取消确认与统一生命周期 | 0.5.0 | 待裁决 | [Invocation 生命周期](proposals/0.5.0/invocation-cancellation.md)；DG-050-04；不改写既有 job cancellation 契约 |
| PB-050-07 | semantics probe 请帧策略与 identifier 索引 | 减少主动请帧或按 tree revision 缓存 identifier 都会改变 `ui.wait` 的观察时机、elapsed/frameRevision 与 generation 边界，不能作为“透明降载”越过默认行为门禁 | 0.5.0 | 待裁决 | [Semantics probe 调度](proposals/0.5.0/semantics-probe-scheduling.md)；DG-050-05；以 PB-050-04 量测为裁决输入 |
| PB-050-08 | REPL 终止错误与单行流契约 | 正常 `--json repl` 已按行输出 compact JSON，但 transport / protocol / session failure 冒到 one-shot `_fail` 后会变成多行 pretty JSON；按行消费方无法把它识别为终止事实，FIFO 写端随后可能在 reader 已退出时挂死 | 0.5.0 | 已验证 | 复用既有 error envelope 与退出码，只修复已承诺的 JSONL 一致性；不在本条加入 reconnect |
| PB-050-09 | CLI 诊断与命令语义可发现性 | 重度使用实证 `sessionDirectoryEmpty` 无恢复指引，已能自动分块落盘的 `capture ... --output` / `blob get ... --output` 未从 raw service 路径就地指向，`text.set` / `text.enter` 的 callback 差异虽已冻结但只在包文档可见，`id` / `identifier` 与 request `limit` / response `length` 的不同事实域也要靠试错辨认 | 0.5.0 | 已排期 | 只改 hint、人读成功摘要、help、文档与回归测试；复用 REPL `describe`，不新增别名/schema 命令，不改 JSON、text 行为或 wire 参数 |
| PB-050-10 | identifier 锚定的通用 semantics action | `ui tap <identifier>` 已有单请求解析与 generation 复核，但非 tap action 仍只能携带快照的 `nodeId + generation`，高变动树上需要调用方自行重取重试 | 0.5.0 | 待裁决 | [Identifier action](proposals/0.5.0/semantics-identifier-action.md)；DG-050-06；新增独立命令，不把 integer `generation` 扩成 `latest` 字符串 |
| PB-050-11 | 结构化日志 event 身份与服务端过滤 | record 只冻结 `message + fields`，接入方可把同一事件名分别放进 `fields.event` 或 message，消费方会漏检；现有 query 只有 level/category/time 过滤 | — | 待排期 | 接入方 log source 先统一映射；核心落地前补 Proposal，联合裁决一等 event 字段、legacy 兼容及 query/tail/export 过滤 |
| PB-050-12 | 最低支持 SDK 组合与 CI 证据 | package 声明 Dart `>=3.11.0`、Flutter `>=3.38.0`，但合入 CI 只跑 Flutter 3.44.9 自带的 Dart；文档下限与两个约束的真实可安装交集尚未被机检证明 | 0.5.0 | 已排期 | 解析并记录最早可安装的 Dart/Flutter 组合，增加最低组合 CI lane；若现有声明无法形成文档承诺的组合，先如实纠正文档，任何提高公开下限的改动另走 Proposal |
| PB-050-13 | CLI 公共 API surface 收口 | 0.4.1 的 canonical CLI library 暴露 203 个符号，包内 47 个文件通过根 barrel 访问实现与测试 seam，API golden 只能冻结漂移，不能证明 launcher/trace/session/doctor 等实现应成为 SDK | 0.5.0 | 待裁决 | [CLI 公共 API 收口](proposals/0.5.0/cli-public-api-surface.md)；DG-050-07；根入口保留 2 个、8 个迁入 opt-in client，其余 193 个彻底退出公共面，本版完成不延期 |
| PB-050-14 | workspace / worktree 级会话亲和性 | session 记录虽保存 `workspacePath`，默认 resolver 仍从全局目录按显式 ID、全局 pin、唯一性选择；在多个 checkout 并行时，旧 pin 可把无 `--session` 的 Agent 命令带到另一工作区的 App | 0.5.0 | 已排期 | 实现前补 Proposal，冻结 canonical workspace/checkout identity、legacy session 迁移、显式跨工作区选择、per-workspace pin 与歧义 fail-closed 语义；不得引入常驻 daemon 或全局 latest |
| PB-050-15 | 锚定式合成 tap（`ui.gesture.tap`） | 手势家族只有 pressHold/drag/fling，最常用的点按缺位；`ui.semantics.tap` 走 performAction 派发，不经指针管线 | 0.5.0 | 已排期 | 裁决见 [0.5.0 版本计划](releases/0.5.0.md)；DG-050-08；[锚定式合成 tap](proposals/0.5.0/anchored-tap.md) |
| PB-050-16 | 点性 semantics 派发的遮挡准入 | `areUserActionsBlocked` 仅在 BlockSemantics 下为真，非模态覆盖层下 performAction 会穿透激活被盖目标，违背防误击立场（`packages/patchbay_flutter/lib/src/semantics/semantics_bridge.dart` 的 423-428 段） | 0.5.0 | 已排期 | 裁决见 [0.5.0 版本计划](releases/0.5.0.md)；DG-050-09；[遮挡准入](proposals/0.5.0/semantics-occlusion-admission.md)；repro 已合入 |
| PB-050-17 | identifier 锚定的 scroll-to-reveal | 懒加载列表中的目标当前无法驱动到可见可达，长列表场景的预检是假覆盖 | 0.5.0 | 已排期 | 裁决见 [0.5.0 版本计划](releases/0.5.0.md)；DG-050-10；Proposal 在途 |
| PB-050-18 | 会话存活判定加进程启动身份 | 存活判据是裸 `kill -0`/`tasklist` 按 PID（`packages/patchbay_cli/lib/src/platform/process_utils.dart` 的 53-76 段），PID 复用会把死会话判成活的 | 0.5.0 | 已排期 | PID+启动时间三元比对；会话记录 additive 字段并冻结兼容语料；老记录行为不变、诊断标注 `identityUnverified` |
| PB-050-19 | 会话记录解析失败改隔离 | `readAll` 解析失败即删文件，自愈同时销毁现场证据，操作者拿不到「这里曾有会话」的痕迹 | 0.5.0 | 已排期 | 移入 `.quarantine` 并由 doctor 报告；临时文件与并发写入语义不变 |
| PB-050-20 | 树类大载荷落 artifact | `ui semantics tree` 等全量进 stdout，大树即数千行；agent 消费方直接吃满上下文，破坏按需展开的信息层级 | 0.5.0 | 已排期 | 超阈值落 artifact、stdout 回校验路径；复用既有 `--output`/blob 形状不新增别名；阈值内输出逐字节不变；落地前补 Proposal |
| PB-050-21 | `--view brief` 瘦 JSON 视图 | `--json` 无分层，机器消费方每次吃全量信封，无法先读决策所需最小事实再选择是否展开 | 0.5.0 | 已排期 | opt-in，默认输出逐字节不变；瘦身字段清单由 Proposal 冻结并 golden 锁定；排 PB-050-08/09 之后 |
| PB-050-22 | gate 出厂默认策略 | `PatchbayGateEvaluator` 生产代码零构造，quick-start 与 example 的基础门是 `allow()`，最短接入路径没有形成“只读默认、写入显式开放”的安全起点 | 0.5.0 | 已排期 | 提供写拒绝带解释 code 的预设门；example 与双语 README 同步 |
| PB-050-23 | error code 注册表 ratchet 测试 | 稳定 code 集合目前靠自觉维护，无全树扫描锁定，新增散装码不会被机检拦截 | 0.5.0 | 已排期 | 全树扫描断言 code 字面量属于封闭注册表；纯测试 MR |
| PB-050-24 | 消费者侧 Skill、INSTALL 与渐进式披露接入漏斗 | 接入与使用路径主要依赖大型 guide，agent 宿主没有从发现、安装、只读起步到按需展开的短漏斗；手写命令示例又会随 CLI 漂移 | 0.5.0 | 实现中 | `skills/use-patchbay/SKILL.md` + `INSTALL.md`；Skill 随 Patchbay tag 版本化，命令示例由 CLI registry 生成或对拍；干净 consumer/Agent 验收 `INSTALL -> SKILL -> identity/catalog/snapshot`，不以预载完整 guide 替代 |

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
| DG-050-01 | snapshot 单份/总保留字节默认值、与 4 MiB/occurrence 硬天花板的对齐、超限失败，以及 consumer revision 的事实来源与兼容形状 | 0.5.0 | 待裁决 | [Snapshot 资源与 revision](proposals/0.5.0/snapshot-resources-revisions.md) |
| DG-050-02 | catalog policy 缓存的失效信号，以及动态目录无 revision 时继续逐次校验还是禁止缓存 | 0.5.0 | 待裁决 | [Catalog policy 缓存](proposals/0.5.0/catalog-policy-cache.md) |
| DG-050-03 | audit 队列满时的保留/丢弃策略、丢失报告与 dispose drain 预算 | 0.5.0 | 待裁决 | [Audit 有序投递](proposals/0.5.0/audit-delivery.md) |
| DG-050-04 | cancellation 的确认事实、legacy handler 降级、deadline 后 slot 释放条件与 host-wide 受理上限 | 0.5.0 | 待裁决 | [Invocation 生命周期](proposals/0.5.0/invocation-cancellation.md) |
| DG-050-05 | semantics owner 已可用时是否仍主动请帧、`ui.wait` 的观察 cadence，以及 identifier cache 的失效与 generation 复核 | 0.5.0 | 待裁决 | [Semantics probe 调度](proposals/0.5.0/semantics-probe-scheduling.md) |
| DG-050-06 | 通用 identifier action 的独立命令形状、CLI canonical path、`strictKeys` 与 unknown key 处置、可选 caller generation 与公开 action allowlist | 0.5.0 | 待裁决 | [Identifier action](proposals/0.5.0/semantics-identifier-action.md) |
| DG-050-07 | CLI 公共 API 收口：canonical 入口保留 2 个、8 个迁入 opt-in client、其余 193 个彻底退出公共面，且不提供 legacy/testing 过渡入口 | 0.5.0 | 待裁决 | [CLI 公共 API 收口](proposals/0.5.0/cli-public-api-surface.md) |
| DG-050-08 | 锚定式合成 tap 的命令形状、指针注入语义与 `ui.semantics.tap` 并存边界 | 0.5.0 | 已裁决 | [锚定式合成 tap](proposals/0.5.0/anchored-tap.md)；裁决记录见 [0.5.0 版本计划](releases/0.5.0.md) |
| DG-050-09 | 点性 semantics 派发的遮挡准入范围、拒绝码与不提供 bypass 的边界 | 0.5.0 | 已裁决 | [遮挡准入](proposals/0.5.0/semantics-occlusion-admission.md)；裁决记录见 [0.5.0 版本计划](releases/0.5.0.md) |
| DG-050-10 | scroll-to-reveal 的写操作定性、Semantics 域实现边界与成功判据 | 0.5.0 | 已裁决 | 裁决记录见 [0.5.0 版本计划](releases/0.5.0.md)；Proposal v1 退回重设计 |

## 维护规则

- 一条一行，动机一句话，证据给指针；不粘贴过程，不在状态或备注中重复版本优先级和依赖。
- 状态只用：`待排期`、`待裁决`、`已排期`、`实现中`、`已验证`；版本计划负责优先级、依赖和退出条件。
- `已验证` 的判据是**验收条件已被机检完全覆盖并跑绿**（CI 门禁、golden、包内测试）。版本计划的退出条件
  点名真机或接入方书面确认的条目，合入后只能记 `实现中`，直到证据到位——绿的单测不代表真机结论。
- `待裁决` 条目必须同时引用 design-gate 和 Proposal；Proposal 状态不代表实施状态。
- 完成 = 移入 CHANGELOG 对应版本段并删行；放弃 = 移入 design.md 非目标台账并写理由。
- 延期 = 通过范围变更 MR 清除目标版本、标回 `待排期`，并保留未满足的证据指针。
- 每个 MR 和发版前运行 `dart run tool/check_planning.dart`。
