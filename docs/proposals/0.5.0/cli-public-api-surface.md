# 0.5.0 CLI 公共 API surface 收口

> 状态：提案中
>
> 关联：PB-050-13
>
> 设计闸门：DG-050-07

## 问题

`patchbay_cli` 的 canonical library `package:patchbay_cli/patchbay_cli.dart` 当前导出 23 个实现文件，
0.4.1 API golden 共记录 203 个公共符号。它们混合了四种不同责任：CLI 进程入口、可选的 Dart client、
可执行程序内部的 launcher/session/trace/doctor/manifest 实现，以及为单元测试注入的
`Clock` / `Delay` / `Random` / `Starter` / `Factory` seam。

仓内事实表明，公共面主要被包自己的组织方式放大，而不是被 package 间依赖需要：

- `packages/patchbay_cli` 内有 47 个 Dart 文件从 canonical library 导入；
- 其他三个 package 没有任何文件导入 `package:patchbay_cli/patchbay_cli.dart`；
- 203 个符号中有 95 个小写顶层函数/常量，至少 29 个名称直接表现为测试或进程 seam；
- `bin/`、`tool/` 和 package 自己的测试本可精确导入 `src/`，却通过根 barrel 访问实现，迫使这些实现
  被误当成公共兼容面；
- 当前 API golden 能发现新增/移除，却不能说明符号面向谁、为什么必须稳定。

0.5.0 已经是公共契约与兼容治理版本。若本版只分类而不收口，后续每个版本仍要为 203 个符号承担兼容
成本，并继续让测试便利决定产品 API。因此 PB-050-13 在 0.5.0 直接完成 breaking 收口，不延期到后续版本。

## 目标与非目标

### 目标

- canonical library 只保留 CLI 嵌入所需的 2 个符号；
- 新增一个显式 opt-in client library，只保留 8 个与连接、identity、snapshot 直接相关的符号；
- `bin/`、`tool/`、example 和单元测试按职责精确导入 `src/`，仅公共契约测试导入两个公开 library；
- API 门禁按 library 分别冻结符号，并对任何新增执行默认拒绝、逐 PB 放行；
- 两个已知内部接入方完成源码 import 扫描，发现使用时提供迁移编译证据；
- CLI 命令、退出码、stdout/stderr、稳定 JSON、wire、VM Service/direct 语义和 AOT 产物入口保持不变。

### 非目标

- 不在本版拆出第五个 `patchbay_client` package；
- 不清理 `patchbay`、`patchbay_flutter` 或 `patchbay_transport` 的公共面；
- 不发布 `testing.dart`、`legacy.dart` 或其他继续暴露实现 seam 的过渡 library；
- 不把 trace/session/doctor/repl/ui manifest 的 Dart 实现升级成 SDK；它们继续通过 CLI 命令和稳定 JSON
  对外；
- 不借 API 收口重写 CLI 调度、连接、权限或持久化行为。

## 契约

### canonical CLI library

`package:patchbay_cli/patchbay_cli.dart` 在 0.5.0 只导出：

```dart
export 'src/cli.dart' show runPatchbayCli;
export 'src/result.dart' show PatchbayExitCode;
```

公开函数签名收窄为：

```dart
Future<int> runPatchbayCli(List<String> arguments);
```

现有 `connect`、`replInput`、`output`、`errorOutput`、`permissionCommands`、`environment` 参数是包内测试与
进程注入 seam，不再属于公开函数。实现可以保留一个 `src/` 内部入口承接这些参数，但名称和形状不构成
公共契约。

`PatchbayExitCode` 的既有常量和值保持不变。`PatchbayErrorEnvelope` 退出 Dart 公共面；`--json` 的 error
envelope 字节契约不变，脚本继续按 JSON 读取，不依赖 Dart 实现类。

### opt-in client library

新增 `package:patchbay_cli/patchbay_client.dart`，其公共面严格限定为：

1. `PatchbayClient`
2. `PatchbaySnapshotDiffClient`
3. `PatchbayRuntimeIdentity`
4. `PatchbayProtocolException`
5. `PatchbayTransportException`
6. `PatchbaySnapshotRequest`（从 `patchbay` 精确 re-export）
7. `connectPatchbayVmService`
8. `connectPatchbayDirect`

两个 factory 的契约为：

```dart
Future<PatchbayClient> connectPatchbayVmService(
  Uri serviceUri, {
  PatchbayRuntimeIdentity? expectedIdentity,
});

PatchbayClient connectPatchbayDirect({
  required Uri endpoint,
  required String bearerToken,
  required int schemaVersion,
  required String applicationId,
  required String appInstanceId,
  Duration timeout = const Duration(seconds: 60),
});
```

factory 复用现有 `PatchbayConnection.connect` 与 `PatchbayDirectConnection`，不新增连接状态机、重试或降级。
具体 connection 类、profiling 实现、artifact helper、timeout wrapper 和 request-id 生成器均留在 `src/`。

### 不再公开的面

除上述 10 个符号外，0.4.1 `patchbay_cli` golden 中的其他符号全部退出公开 library，包括：

- launcher、session、trace、doctor、REPL、manifest 的模型、store、runner 与 helper；
- Android/iOS permission adapter、platform process runner 与权限编排实现；外部 driver 的稳定边界仍是
  JSON Lines 进程协议，wire DTO 继续由 `patchbay` 提供；
- command parser/registry/help renderer、artifact downloader、performance profiler 与 keep-awake policy；
- 所有测试时钟、随机数、sleep、starter、factory、probe、目录、预算和上限常量。

不创建兼容别名。若 consumer 扫描证明某个被删除符号承担真实、通用且无法由上述入口表达的生产需求，
必须在 DG-050-07 接受前修改本 Proposal 的精确清单；不能在实现 MR 临时多导出一个。

### API 门禁

`check_api_surface` 从“每 package 一份扁平数组”升级为按公开 library 记录。0.5.0 对 CLI 的 golden 必须
恰好包含上面 2 + 8 个符号；同名符号不会跨 library 折叠。任何新增 library 或符号默认判红，只有 Proposal
与版本计划明确列出的 PB allowlist 才能更新 golden。

## 状态、失败与预算

本提案不新增运行时状态、异步 job、超时、取消、重试或资源预算。

唯一新增失败面是 Dart 编译期：旧源码从 `package:patchbay_cli/patchbay_cli.dart` 引用被删除符号时无法
解析。它不得在运行时静默 fallback，也不提供 `dynamic`、`noSuchMethod` 或 legacy library 绕过。

公共面预算是封闭值：canonical library 2 个、client library 8 个。实现过程中若 factory 必须暴露新的参数
类型，应先重塑 factory 隐藏实现类型；不能以“编译需要”为由扩大预算。

## 兼容与降级

0.5.0 对 Dart source API 是明确的 breaking release：

| 0.4.1 用法 | 0.5.0 迁移 |
|---|---|
| 只执行安装后的 `patchbay` / permission binaries | 无源码迁移，命令与输出不变 |
| `runPatchbayCli(arguments)` | import 保持 canonical library，调用保持不变 |
| 为测试传入 `runPatchbayCli` 可选 seam | 仅包内测试改用 `src/` 内部入口；外部 seam 不再承诺 |
| `PatchbayClient` / VM/direct connection | 改用 `patchbay_client.dart` 与两个公开 factory |
| trace/session/doctor/repl/manifest/permission adapter 实现 | 无 Dart 替代；改走 CLI + 稳定 JSON，或在自己的包实现外部进程协议 |

pub 的 `^0.4.1` 约束不会自动选择 0.5.0；git/tag pin 接入方必须显式换 pin 并完成编译验证。发布说明必须
在 breaking changes 首段列出入口清单和迁移表，不能只在 API golden diff 中体现。

这项 Dart 编译期收口不改变协议部署组合：新 CLI ↔ 老 host、老 CLI ↔ 新 host、VM Service ↔ direct
继续使用既有兼容矩阵和失败语义。0.4.1 CLI 二进制不会因为 0.5 host 的 library export 变化而受影响。

## 安全与隐私

本提案不改变 App 门禁、release 裁除、敏感参数、bearer、会话文件或输出脱敏。

收口后 permission driver 仍以独立进程 JSONL 为信任边界；不因移除 Dart adapter export 而把平台命令、
设备 identity 或敏感 payload 搬进 core package。consumer 扫描证据只记录 import 的中性符号集合与编译
结论，不把接入方名称、路径、应用 ID 或仓库地址写入本仓。

## 验证

- 单元/协议测试：
  - `patchbay_cli.dart` 编译 fixture 只能访问 `runPatchbayCli` 与 `PatchbayExitCode`；
  - `patchbay_client.dart` fixture 逐个构造/引用 8 个允许符号；第 9 个未授权符号必须编译失败或被 surface
    checker 拒绝；
  - 包内除公共 API fixture 外，不再 import `package:patchbay_cli/patchbay_cli.dart`；
  - 四包 API golden、command docs/codegen、analyze 与全部测试全绿；
  - AOT 编译 `bin/patchbay.dart`、Android/iOS permission binaries 与 reference launcher。
- VM/direct：两个新 factory 复用现有实现；identity、catalog、snapshot、invoke、requestId mismatch、timeout
  与 direct bearer 的现有跨进程测试逐字节不变。
- 接入方/真机：两个已知接入方先做 import 扫描；换 pin 后至少通过各自编译门禁。API 收口不新增真机
  行为，仍随 0.5.0 固定候选 SHA 完成既有 example/真机退出条件。
- 失败注入：旧 root import 的代表性 launcher/trace/session 符号进入负向 fixture，证明不会被转发或别名
  泄漏；`runPatchbayCli` 的 JSON error、usage、transport、protocol 与 REPL 终止语料保持不变。

## 待裁决

- 接受 canonical library 恰好 2 个、client library 恰好 8 个符号的封闭清单；
- 接受 0.5.0 在 root 保留 2 个、把 8 个迁入 opt-in client，并让其余 193 个彻底退出公共面；不提供
  `legacy.dart` / `testing.dart` 过渡入口；
- 接受外部源码若依赖 executable internals 必须迁移到 CLI JSON 或自有实现，不为未知使用扩大稳定 SDK。

DG-050-07 接受前必须附两个内部接入方的中性 import 扫描结论。若证据要求调整清单，先更新本 Proposal
并重新裁决，不能让实现 MR 代替设计决定。

## 被否决方案

- **0.5.0 只分类、后续版本再删除**：继续让 203 个符号参与整个 0.5 周期，与本版 API 治理目标冲突。
- **新增 `legacy.dart` 或 `testing.dart` 暂存全部旧面**：Dart 的任意 `lib/*.dart` 都是公开 library，只是把
  爆炸换一个入口，package 仍承担相同兼容成本。
- **给 203 个符号逐个 `@Deprecated` 再等一个版本**：迁移方向只有 2 + 8 个符号，不需要用一整个版本
  保留测试 seam；`^0.4.1` 也不会自动跨入 0.5.0。
- **本版拆出第五个 package**：会同时改变发布拓扑、依赖与安装口径，超出一次 surface 收口的必要范围。
- **canonical library 完全不提供 client 能力**：会迫使确有嵌入需求的调用方导入 `src/`；保留小型 opt-in
  client library 比把 VM/direct 实现重新泄漏进根入口更可控。
