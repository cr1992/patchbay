# 源码结构规范

> 本文定义"什么时候必须拆分、什么时候不该拆分"，以及门禁如何对应这套判断。
> 结构门禁 `tool/check_structure_ratchet.dart` 是这份规范的机器执行部分，不是规范本身。

## 立场

**拆分的依据是职责边界和依赖方向，不是行数。**

行数只是这两者出问题之后的表征，而且是个很差的表征——它同时会误报和漏报。本仓实测：

- 9 个曾被 600 行阈值判红的文件里，7 个的长度来自"成员多且同构"（24 个 finding 构造函数、
  18 个 `_check*`、25 个 bridge 操作），按行数拆开只会把兄弟成员打散，可读性变差；
- 与此同时，`flutter_service_host.dart`（680 行，在 800 线以下）里藏着一个 **254 行的函数**，
  `command_dispatcher.dart` 里藏着 216 行，`execution_evidence.dart` 里 215 行——
  这些是真正的职责堆叠，而任何文件行数阈值都抓不到它们。

所以：**体积指标一律只作警戒线，不作判红条件**。命中警戒线意味着"这里值得看一眼"，
不意味着"这里必须改"。

## 必须拆分（评审应当打回）

以下是职责边界已经出问题的信号，与文件多长无关：

1. **一个函数串起多个阶段。** 函数体内出现可命名的连续阶段（准备 → 遍历 → 判定 → 汇总 →
   渲染），且各阶段之间只靠局部变量传递。这类函数应按阶段拆成具名步骤，让每一步可以单独读、
   单独测、单独失败。经验阈值 150 行，但依据是"能否说出里面有几段"，不是行数本身。
2. **同一文件里存在两组互不调用、依赖集也不相交的成员。** 这说明文件承载了两个主题，
   应当按主题分文件。
3. **领域目录之间出现反向或循环依赖。** 例如 `output/` 反向依赖 `commands/`。
   这类问题必须通过把共用类型下沉到中立层（如 `support/`）解决，而不是加转发或放宽依赖。
4. **一个类同时承担数据、策略与 IO。** 描述符/数据类应当能被独立构造和断言，
   不应挟带文件读写、进程调用或网络。

## 不该拆分（拆了会变差）

1. **同构成员的集合。** 一组构造同类结果的小函数（检查项目录、finding 家族、错误码映射表、
   声明式 switch），它们的价值就在于摆在一起可以横向对照。拆成多文件后，
   新增一个兄弟成员要改多处，反而更容易漏。
2. **单一职责的内聚类，只是操作多。** 一个 bridge 有 24 个方法但都围绕同一个对象和同一份
   状态，且最大方法不过百余行——这是正常规模，不是坏味道。
3. **为了压行数而制造的结构。** 手写 `part` 碎片、只做转发的空壳类、把私有方法搬到另一个文件
   再 import 回来——这些让行数变好看而依赖关系变差，一律判红。

## 门禁如何对应

`tool/check_structure_ratchet.dart` 严格区分两档：

| 档位 | 内容 | 门禁 | 行为 |
|---|---|---|---|
| **硬规则（判红）** | 跨包 `src/` 私有导入；越出包根的相对导入；领域目录循环依赖 | `check_structure_ratchet.dart` | 退出码 1，阻断 |
| **硬规则（判红）** | 四包每个公开 library 相对 golden 的任何新增或移除，含新增 library 本身 | `check_api_surface.dart` | 退出码 1，阻断 |
| **警戒线（告警）** | 单函数 > 150 行；单文件 > 800 行（测试 > 1000 行）；文件相比基线变长 | `check_structure_ratchet.dart` | 打印后正常退出，不阻断 |

公共 API surface 按 `export` / `show` / `hide` / `part` 展开计算，而不是比对 barrel 文本——
仓库曾出现 barrel 一字未改、符号集合却扩大 45 个的泄漏。有意变更公共面时跑
`dart run tool/check_api_surface.dart --update` 并在 MR 描述里解释。

golden 按**公开 library** 记录：递归 `packages/<pkg>/lib/**.dart` 各一条，只排除顶层
`lib/src/`（pub 的私有约定只覆盖那一个目录——`lib/extra/x.dart` 外部照样能 import，
所以它必须出现在 golden 里）。同名符号不跨 library 折叠，新增一个 library 文件本身就是新增
公共面、默认判红。

`patchbay_cli` 的两个入口是 DG-050-07 冻结的封闭清单（canonical 2 个、
`patchbay_client.dart` 8 个）；`patchbay` 的三个入口与 `patchbay_flutter` 的两个入口是
DG-060-02 冻结的封闭清单（consumer 77、host 121、protocol 129；Flutter 默认 81、
Flutter host 169）。扩表要先改对应 Proposal（[CLI 公共 API 收口](proposals/0.5.0/cli-public-api-surface.md)、
[Core 公共 Dart API 分层](proposals/0.6.0/core-public-api-layers.md)）再改 golden，
不能在实现 MR 里顺手 `--update`。

封闭清单的包额外守一条：无 `show` 子句的 `export 'package:…'` 当场判红，`--update` 也挡——
本工具不展开整库跨包 re-export，所以那一行会把对方包的整张公共面带进本包而 golden diff 恒为 0。
PB-060-02 起**四个发布包全部**采用封闭清单口径：`patchbay_flutter` 过去的整库 re-export 正是
分层要消灭的那一行，现在它改成逐名 `show`，因此每个公开 library 的集合都算得出来。

硬规则挑的都是"评审用肉眼很难稳定抓住、但一旦发生就确定是错"的结构错误。
警戒线挑的是"值得在评审里解释一句"的地方。

**警戒线命中时，MR 描述里要给出判断和理由**（拆 / 不拆、依据本文哪一条）。
门禁不替评审做这个决定。

## 当前已知待拆项

门禁当前列出 14 个超过 150 行的生产函数。以下是已经逐个读过结构、可以给出判断的部分；
其余候选按本文口径在触及它们的 MR 里给出判断即可，门禁不替评审决定。

**应当拆分**（命中「必须拆分」第 1 条：函数串起多个可命名阶段）：

| 位置 | 规模 | 依据 |
|---|---|---|
| `patchbay_cli/.../runners/manifest_runner.dart` 的 `walkUiManifest` | 531 行 | 预检、遍历、逐屏判定、预算控制、报告汇总五段串在一个函数里 |
| `patchbay_cli/lib/src/launcher.dart` 的 `run` | 360 行 | 32 个分支的多阶段编排：参数校验 → 启动 → 监督 → keep-awake → 取消 → 收敛 |
| `patchbay_cli/.../registry/friendly_command_registry.dart` 的 `resolve` | 310 行 | 别名展开、路径规范化、选项校验、规格匹配四件事混在一起 |

**已复核，维持现状**：

- 因文件长度被点过名的 `manifest_parser` / `semantics_bridge` / `gesture_bridge` /
  `artifact_service` / `trace_store` / `doctor_checks` / `release_checker`——
  长度来自同构成员集合与内聚类，属「不该拆分」第 1、2 条；
- `flutter_service_host` 的 `_uiCommandRegistry`（254 行）与 `command_codegen` 的
  `_render`（208 行）——声明式装配与模板拼装，控制流稀疏（前者 254 行只有 7 个 return、
  11 个 if），拆开不会更好读。

## 0.5.0 RC 审计（2026-08-28）

方案 b 口径修订后（体积警戒线是评审义务，不是机器阻断），对 RC 候选 `31a960b6` 上
`tool/check_structure_ratchet.dart --verbose` 报告的全部 20 个 `grew` 警戒线文件（相对 M0
基线变长）逐一给出判断，作为该口径修订的账本。已在上面「已复核，维持现状」出现过的文件直接
复用既有结论，不重复裁决；已在「应当拆分」出现过的文件，其增长落在已判定应拆的函数本体上，
同样复用既有判断，不重复裁决。

| 文件 | 基线→当前 | 判断 | 依据 |
|---|---|---|---|
| `patchbay_flutter/example/lib/main.dart` | 620→1086 行 | 维持 | example 标准结构：`main()` + `PatchbayExampleHost` + 多个自成一体的 `Widget` 类；新增内容是新增 demo 场景对应的独立 Widget/命令注册，同构增量，未产生互不调用的两组主题（「不该拆分」第 1 条） |
| `patchbay_cli/test/permission_platform_adapter_test.dart` | 872→1254 行 | 维持 | 单 `main()` + 17 个 `test()`，同构用例堆叠（新增设备/权限矩阵场景覆盖） |
| `patchbay_cli/test/protocol_compat_test.dart` | 713→987 行 | 维持 | 单 `main()` + 6 个 `group()` + 31 个 `test()`，同构兼容性用例堆叠 |
| `patchbay_flutter/lib/src/flutter_service_host.dart` | 680→949 行 | 维持 | 单一 host 类（`PatchbayFlutterServiceHost`）承载新增 UI command 方法，内聚同类操作；与本文件对 `_uiCommandRegistry` 的既有复核结论同源（「不该拆分」第 2 条） |
| `patchbay_flutter/lib/src/semantics/semantics_bridge.dart` | 738→969 行 | 维持（复用既有结论） | 见上「已复核，维持现状」：长度来自同构成员集合与内聚类，属「不该拆分」第 1、2 条 |
| `patchbay_cli/lib/src/android_permission_adapter.dart` | 606→787 行 | 维持 | 单一 adb 权限适配器类，10 个方法均服务同一驱动流程（探测能力 → 选设备 → 验证应用 → 查状态 → 变更后复核 → 归一化 → 重置 → 执行 → adb 调用封装）；IO 是适配器职责本体，不是「数据类挟带 IO」（「必须拆分」第 4 条不成立） |
| `patchbay_transport/test/direct_transport_test.dart` | 749→908 行 | 维持 | 单 `main()` + 2 个 `group()` + 28 个 `test()`，同构传输层用例堆叠 |
| `patchbay_cli/test/command_registry_test.dart` | 858→1016 行 | 维持 | 单 `main()` + 37 个 `test()`，同构 registry 解析用例堆叠；该文件已越过测试 1000 行长文件警戒线，继续增长时评审可考虑按主题拆多个 test 文件，但当前内容仍同构，不构成「必须拆分」 |
| `patchbay_cli/lib/src/doctor/doctor_checks.dart` | 662→796 行 | 维持（复用既有结论） | 见上「已复核，维持现状」：同构 `_check*`/finding 家族与内聚类 |
| `patchbay_flutter/example/lib/example_domain.dart` | 658→792 行 | 维持 | 同构声明式命令描述符、`PatchbayResponseSchema` 常量与小型 gateway/controller 类的线性累加（新增 `idempotentTouch`/`cooperativeWait`/`unresponsiveWait` 等 demo 命令），未产生互不调用的两组主题 |
| `patchbay_cli/lib/src/cli.dart` | 712→798 行 | 待仓主复核 | 增长集中在入口函数 `runPatchbayCliWithSeams`（本次量得 418 行，未列入上表「应当拆分」）；观察到 parse → 校验 → friendly-target 分支 ×5 → REPL/单命令路由 → 连接 → 执行 → 错误渲染的多阶段结构，具备「函数串起多个阶段」的部分特征，但作为 CLI 唯一入口，拆分需要仔细核对分支间隐式依赖与错误路径等价性，本次审计未做全量核实，如实标待复核，不硬判 |
| `patchbay_cli/lib/src/registry/friendly_command_registry.dart` | 639→695 行 | 该拆（复用既有结论） | 增长落在上表已判定「应当拆分」的 `resolve`（310+ 行）与同文件 `allowedOptions`（180 行）两个函数上，是既有应拆函数的边际累加，拆分工作按既有条目跟踪，不重复裁决 |
| `patchbay/tool/src/release_prep/release_checker.dart` | 683→706 行 | 维持（复用既有结论） | 见上「已复核，维持现状」 |
| `patchbay_cli/test/cross_process_test.dart` | 809→855 行 | 维持 | 单一真实跨进程集成场景，进程与连接状态需要在同一个 `test()` 内延续，拆分会破坏端到端语义或需要重复起真实进程；属集成测试的合理写法，不满足「必须拆分」标准 |
| `patchbay_cli/test/launcher_supervision_test.dart` | 727→747 行 | 维持 | 单 `main()` + 19 个 `test()`，同构监督场景用例堆叠 |
| `patchbay_flutter/lib/src/flutter_bridge.dart` | 606→624 行 | 维持 | 增量小（18 行），`part` 聚合入口新增同构 Key 工厂/`GlobalKey` 子类，未产生跨主题成员组 |
| `patchbay_cli/lib/src/launcher.dart` | 648→658 行 | 该拆（复用既有结论） | 增长落在上表已判定「应当拆分」的 `run` 函数上，是既有应拆函数的边际累加，拆分工作按既有条目跟踪，不重复裁决 |
| `patchbay_cli/test/doctor_test.dart` | 774→786 行 | 维持 | 单 `main()` + 8 个 `group()` + 35 个 `test()`，增量仅 12 行，同构诊断用例堆叠 |
| `patchbay_cli/test/trace_test.dart` | 735→739 行 | 维持 | 单 `main()` + 2 个 `group()` + 17 个 `test()`，增量仅 4 行，同构用例堆叠 |
| `patchbay_cli/test/snapshot_selector_test.dart` | 624→626 行 | 维持 | 单 `main()` + 4 个 `group()` + 23 个 `test()`，增量仅 2 行，同构用例堆叠 |

汇总：17 维持（含 3 项复用既有「已复核」结论）、2 该拆（均是已在「应当拆分」表中判定的函数本体
边际增长，不新增裁决）、1 待仓主复核（`cli.dart` 的 `runPatchbayCliWithSeams`，是否拆分留待仓主
判断）。
