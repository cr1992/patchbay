// PB-050-17 / DG-050-10：reveal 的公共授权面与包内状态类型。
//
// 只有 [PatchbayRevealDirection]、[PatchbayRevealDecision] 与
// [PatchbayRevealPolicy] 进包的 barrel；其余是拆分产物，不因为被拆出来就成为
// 公共 API（与 gesture/ 下的约定一致）。
import 'package:flutter/rendering.dart';
import 'package:patchbay/patchbay.dart';

import '../semantics/semantics_models.dart';

/// 一次 reveal 请求的**内容序**方向。
///
/// 不是屏幕方向：[forward] 表示朝 `maxScrollExtent` 前进（`pixels` 增大），
/// [backward] 朝 `minScrollExtent`。落到哪个 `SemanticsAction` 由容器当前暴露的
/// action 与观察到的位移符号确定——`reverse: true` 的列表与横向列表因此不需要
/// 调用方先知道布局方向。
///
/// [both] 是默认值，也是唯一零探测步的选择：它只要求把同轴的两个 action 各自
/// 驱动到耗尽，不需要先知道谁增大 `pixels`。
enum PatchbayRevealDirection {
  forward,
  backward,
  both;

  PatchbayRevealDirectionWire get wire => switch (this) {
    PatchbayRevealDirection.forward => PatchbayRevealDirectionWire.forward,
    PatchbayRevealDirection.backward => PatchbayRevealDirectionWire.backward,
    PatchbayRevealDirection.both => PatchbayRevealDirectionWire.both,
  };

  static PatchbayRevealDirection fromWire(PatchbayRevealDirectionWire wire) =>
      switch (wire) {
        PatchbayRevealDirectionWire.forward => PatchbayRevealDirection.forward,
        PatchbayRevealDirectionWire.backward =>
          PatchbayRevealDirection.backward,
        PatchbayRevealDirectionWire.both => PatchbayRevealDirection.both,
      };
}

/// 接入方对**驱动一个滚动容器**的决定，外加可收紧的预算。
///
/// 「授权一次 reveal」不存在，存在的只有「授权驱动这一个容器」：准入容器求值
/// 一次，此后每次升层是一次新的、完整的授权，每一步派发之前还会按同一入参
/// 重问一次并逐项比对决策。
///
/// 预算三层，**只能收紧不能放宽**，且 min 通过**拒绝**达成而不是静默夹取：
/// host 编译期硬顶（[PatchbayRevealBudget.maxSteps] /
/// [PatchbayRevealBudget.maxDurationMs]）→ 本决定 → 命令参数。参数越过本决定的
/// 上限即 `uiRevealBudgetExceeded`，一步都不派发；本决定自身越过 host 硬顶同样
/// 是 `uiRevealBudgetExceeded`，而不是被夹到硬顶。
final class PatchbayRevealDecision {
  const PatchbayRevealDecision.allow({
    this.gateIds = const <String>{},
    this.maxSteps = 40,
    this.maxDurationMs = 30000,
  }) : rejectionCode = null,
       rejectionNotice = null;

  const PatchbayRevealDecision.reject({
    this.rejectionCode = 'uiRevealDenied',
    this.rejectionNotice,
  }) : gateIds = const <String>{},
       maxSteps = 0,
       maxDurationMs = 0;

  /// 该容器上每一步都要重新求值的声明门。
  ///
  /// 逐步重评意味着接入方的 gate 会被问到 `steps` 次。想让「一次确认覆盖整条
  /// reveal」的接入方有两条不需要协议新机制的路径：把 reveal 放在非交互门后、
  /// 把交互确认放到随后的 tap / setText 上；或者在自己的 gate 闭包内 latch。
  /// 协议侧不提供 lease。
  final Set<String> gateIds;

  /// 在**这一个容器**上允许派发的 scroll action 次数上限。
  ///
  /// 与命令参数的全局 `maxSteps` 是两级：嵌套场景里内外层可以有不同的容器级
  /// 预算，而全局预算在任何情况下都不被突破。
  final int maxSteps;

  /// 本次 reveal 允许的总时长上限，用于冻结那唯一一个 deadline。
  ///
  /// 升层到一个 [maxDurationMs] 小于本次已冻结时长预算的容器时，引擎不改写
  /// deadline，而是停止并报 `reason: containerBudgetTooSmall`。
  final int maxDurationMs;

  final String? rejectionCode;
  final String? rejectionNotice;

  bool get allowed => rejectionCode == null;
}

/// 接入方对「允不允许把这块区域往内容深处推」的判断。
///
/// 入参是**容器**而不是目标：reveal 的核心场景里目标根本不存在，唯一存在的、
/// 也是真正被移动的东西是容器。[direction] 是本次调用请求的内容序方向，不是最终
/// 落到的 `SemanticsAction`——否则布局方向知识就要写进 policy 实现。
///
/// `container.identifier` 是**该容器最内层的锚点 identifier**，不一定是滚动语义
/// 节点自己的 identifier：锚点按惯例包在 `Scrollable` 外层，滚动节点自身几乎从不
/// 带 identifier。查找沿 `parent` 向外取第一个非空 identifier，遇到另一个滚动
/// 节点即停，因此外层容器的身份不会被误安到内层容器上；一个锚点都没有的容器给出
/// 空串，接入方应当把它按「未声明的区域」处理。
typedef PatchbayRevealPolicy =
    PatchbayRevealDecision Function(
      PatchbaySemanticsTarget container,
      PatchbayRevealDirection direction,
    );

/// host 侧编译期硬顶与不可参数化常量。
///
/// 全部在 payload 或失败 details 里如实回报，调用方才知道自己撞的是哪一条。
abstract final class PatchbayRevealBudget {
  /// 任何 policy 或参数都不能突破的步数硬顶。
  static const int maxSteps = 200;

  /// 任何 policy 或参数都不能突破的时长硬顶（2 分钟，沿用 snapshot wait
  /// ceiling）。
  static const int maxDurationMs = 120000;

  /// 判定「该方向耗尽」所需的连续无进展步数。
  static const int stallSteps = 2;

  /// 每个容器每次调用至多一次极性探测步。
  static const int maxProbeStepsPerContainer = 1;

  static const int defaultSteps = 40;
  static const int defaultTimeoutMs = 5000;
}

/// 受理后 `reason` 的封闭词表。
///
/// 与准入前的稳定 code 分开：准入前的失败是 `admission: rejected`，这些是已经
/// 派发过至少一次 scroll action 之后的受理内事实。两组字面量都进 PB-050-23 的
/// 封闭注册表。
abstract final class PatchbayRevealReason {
  static const String stepBudgetExceeded = 'stepBudgetExceeded';
  static const String scrollExhausted = 'scrollExhausted';
  static const String targetObscured = 'targetObscured';
  static const String targetBlocked = 'targetBlocked';
  static const String targetAmbiguous = 'targetAmbiguous';
  static const String containerChanged = 'containerChanged';
  static const String containerDenied = 'containerDenied';
  static const String containerBudgetTooSmall = 'containerBudgetTooSmall';
  static const String policyChanged = 'policyChanged';
  static const String gateRejected = 'gateRejected';
  static const String lifecycleNotResumed = 'lifecycleNotResumed';
  static const String timeout = 'timeout';
  static const String scrollActionFailed = 'scrollActionFailed';

  /// 穷尽性测试用的封闭集合。
  static const Set<String> values = <String>{
    stepBudgetExceeded,
    scrollExhausted,
    targetObscured,
    targetBlocked,
    targetAmbiguous,
    containerChanged,
    containerDenied,
    containerBudgetTooSmall,
    policyChanged,
    gateRejected,
    lifecycleNotResumed,
    timeout,
    scrollActionFailed,
  };
}

/// 准入前稳定拒绝码里 reveal 新增的那一组。
abstract final class PatchbayRevealRejection {
  static const String disabled = 'uiRevealDisabled';
  static const String noScrollableContainer = 'uiRevealNoScrollableContainer';
  static const String containerAmbiguous = 'uiRevealContainerAmbiguous';
  static const String denied = 'uiRevealDenied';
  static const String budgetExceeded = 'uiRevealBudgetExceeded';
  static const String policyChanged = 'uiRevealPolicyChanged';

  /// 穷尽性测试用的封闭集合。
  static const Set<String> values = <String>{
    disabled,
    noScrollableContainer,
    containerAmbiguous,
    denied,
    budgetExceeded,
    policyChanged,
  };
}

/// 一个被驱动过的容器在 payload 里的形状。
///
/// 元素只在**第一次在该容器上派发**时追加，因此 `steps >= 1`，因此
/// `containers.isEmpty <=> 顶层 steps == 0`。
final class PatchbayRevealContainerRecord {
  PatchbayRevealContainerRecord({
    required this.nodeId,
    required this.generation,
  });

  final int nodeId;
  final int generation;
  int steps = 0;
  int extentGrowthSteps = 0;

  /// 该容器上**实际驱动过**的方向，不是请求的方向。
  ///
  /// 只朝一个方向推过就是那个方向；真的换过向（含探测步走反）才是 `both`。
  PatchbayRevealDirection? drivenDirection;

  /// 记录这一步实际把内容推向了哪个方向。步数由调用点自己加，因为「派发过」与
  /// 「观察到往哪走」是两个时刻：前者在 `performAction` 之后立刻成立，后者要等
  /// 一帧。
  void note(PatchbayRevealDirection direction) {
    if (drivenDirection == null) {
      drivenDirection = direction;
    } else if (drivenDirection != direction) {
      drivenDirection = PatchbayRevealDirection.both;
    }
  }

  PatchbayRevealContainerWire toWire() => PatchbayRevealContainerWire(
    nodeId: nodeId,
    generation: generation,
    steps: steps,
    direction: (drivenDirection ?? PatchbayRevealDirection.both).wire,
    extentGrowthSteps: extentGrowthSteps,
  );
}

/// 引擎的终态：成功露出，或一个受理后 `reason`。
final class PatchbayRevealOutcome {
  const PatchbayRevealOutcome.revealed({
    required this.nodeId,
    required this.generation,
    required this.reachability,
  }) : reason = null,
       failureType = null,
       gateId = null,
       gateCode = null;

  const PatchbayRevealOutcome.failed(
    String this.reason, {
    this.nodeId,
    this.generation,
    this.failureType,
    this.gateId,
    this.gateCode,
  }) : reachability = null;

  final String? reason;
  final int? nodeId;
  final int? generation;
  final PatchbayRevealReachabilityWire? reachability;
  final String? failureType;
  final String? gateId;
  final String? gateCode;

  bool get revealed => reason == null;
}

/// 准入期解析出的一个候选容器：节点 + 该次 pin 的代际。
final class PatchbayRevealContainerAnchor {
  const PatchbayRevealContainerAnchor({
    required this.node,
    required this.nodeId,
    required this.generation,
    required this.target,
  });

  final SemanticsNode node;
  final int nodeId;
  final int generation;

  /// 交给 policy 的只读容器事实，形状与 `ui.semantics.*` 的 target 同构。
  final PatchbaySemanticsTarget target;
}
