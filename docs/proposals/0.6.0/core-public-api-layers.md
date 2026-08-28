# 0.6.0 Core 公共 Dart API 分层

> 状态：提案中
>
> 关联：PB-060-02
>
> 设计闸门：DG-060-02

## 问题

`package:patchbay/patchbay.dart` 当前公开 247 个符号，混合 consumer DTO/descriptor、host lifecycle、
invocation internals 与生成 wire 类型；`patchbay_flutter.dart` 又整体 re-export core。API golden 能防止
意外漂移，却不能让普通 App 接入者只看到自己需要的表面。0.6.0 若是 1.0 候选，必须先冻结使用者分层。

## 目标与非目标

### 目标

- 将默认 consumer、host implementer、protocol/wire implementer 的公共入口与符号清单分开冻结。
- 默认 Flutter 接入不再无条件暴露 raw wire 与 host 内部生命周期类型。
- API checker 能对每个入口及跨包 re-export 的真实表面判定增删。

### 非目标

- 不拆第五个运行时 package，不改变 wire、错误码或运行时行为。
- 不建立 `legacy.dart` / `testing.dart` 大口袋，也不公开包内测试 seam。
- 不仅靠文件移动或别名维持两套同等推荐入口。

## 契约

推荐候选保留 `patchbay.dart` 作为默认 consumer façade，新增显式 `patchbay_host.dart` 与
`patchbay_protocol.dart`；三个 library 都使用封闭 `show` 清单。`patchbay_flutter.dart` 只 re-export consumer
façade，并公开 Flutter target/bridge 的 consumer 面；需要注册 VM/direct host 的接入者显式 import host
入口，transport/CLI 只 import protocol 入口。最终符号清单由 Proposal 裁决附录和 API golden 同时冻结。

## 状态、失败与预算

本项只改变 Dart source 可见性，不改变运行时状态、失败、资源上限或稳定 JSON。实现不得引入转发层运行时
开销；library 拆分后的编译依赖方向必须保持 consumer → host/protocol 单向或通过中立类型下沉消除循环。

## 兼容与降级

这是 0.6.0 明示的 source breaking。只使用 CLI/稳定 JSON 的用户不受影响；默认 import 的接入方按迁移表
补显式 host/protocol import。0.5.x package constraint 不会自动选择 0.6.0；git pin consumer 必须编译门禁。
不提供永久兼容 re-export，否则默认 surface 实际没有收窄。

## 安全与隐私

收口不得让 gate evaluator、release compile-time boundary 或 sensitive policy 变成内部不可配置；同时不得
为了迁移方便公开 request token、session store seam、测试时钟或原始 transport credential 类型。

## 验证

- 单元/协议测试：按 library 展开 public surface golden，跨包 re-export 真实展开。
- VM/direct：零运行时变化，复用完整回归矩阵。
- 接入方/真机：两个已知 consumer 换 pin 后编译；CLI-only consumer 无迁移。
- 失败注入：旧 import 编译失败信息与迁移表逐项对应，包内不通过 canonical barrel 自引用。

## 待裁决

- `patchbay.dart` 保留 consumer façade，还是新增 `patchbay_consumer.dart` 后迁移默认入口；推荐前者。
- 三个入口的精确符号清单，以及 `PatchbayServiceHost` 属于 host-only 还是默认高级 consumer 面。
- `patchbay_flutter.dart` 是否继续 re-export任何 core 符号，还是要求双 import；推荐只 re-export consumer 清单。
- API checker 如何展开跨包 export，避免 core 变更静默扩大 Flutter surface。

## 被否决方案

- 只继续冻结现有 247 个符号：冻结复杂度不是收口。
- 新增分层入口但保留默认全量 re-export：不会降低普通接入者的认知与兼容成本。
- 把所有 internals 移到另一个 package：增加发布拓扑而没有必要的运行时边界。
