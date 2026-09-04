// PB-050-17 / DG-050-10：reveal 的步进循环。
//
// 独立于 `PatchbaySemanticsBridge._dispatch`（结构警戒线：不新增 long-function
// 警戒线）。入参是容器解析原语、policy、门与帧观察者，出参是终态；bridge 只做
// 受理、payload 组装与拒绝码映射。
//
// PB-050-38 之后本文件只留**编排**：一步的固定顺序、升层的时机与终态的选择。
// 每个阶段各自成文件，可以单独构造、单独失败注入、单独回退：
//
//   `reveal_container_facts.dart`     容器只读事实（轴 / 极性 / 可驱动 / 身份）
//   `reveal_layer.dart`               一层容器的可变状态机（极性、换向、停滞）
//   `reveal_observation_stage.dart`   现场读取（目标、容器重解析、进展）
//   `reveal_step_stage.dart`          一步内的重评、派发与记账
//   `reveal_escalation_stage.dart`    升层候选与早停判定
//   `reveal_outcome_stage.dart`       终态投影
//
// 拆分零外部语义变化：payload、reason、错误码、预算门顺序、policy / 门的调用
// 次数与 await 位置全部保持不变，由 `reveal_engine_characterization_test.dart`
// 与 `reveal_engine_microtask_depth_test.dart` 在拆分前后各跑一次钉住。
//
// 机制唯一：整个 reveal 只派发 `SemanticsAction.scrollUp|scrollDown|scrollLeft|
// scrollRight`，**从不派发 `showOnScreen`**——它是一条接入方在快照里看不见、在
// 任何 policy 入参里也见不到的驱动通道，逐容器授权模型按构造容不下它。唯一的
// `performAction` 调用点在 `reveal_step_stage.dart`。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';
import 'package:patchbay/patchbay.dart';

import '../frame_observer.dart';
import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_models.dart';
import 'reveal_admission.dart';
import 'reveal_container_facts.dart';
import 'reveal_escalation_stage.dart';
import 'reveal_layer.dart';
import 'reveal_models.dart';
import 'reveal_observation_stage.dart';
import 'reveal_outcome_stage.dart';
import 'reveal_step_stage.dart';

// 容器只读事实随引擎一起交付：`reveal_bridge.dart` 在准入期用的
// `patchbayRevealDrivable` / `patchbayRevealTargetOf` 与引擎在步间用的是同一份
// 判据，不该因为拆分变成两个 import 入口。其余阶段只有引擎与各自的单测用，
// 不再往外转出。
export 'reveal_container_facts.dart';

/// 一次 reveal 调用的步进循环。每次调用构造一个实例，不跨调用复用。
final class PatchbayRevealEngine {
  PatchbayRevealEngine({
    required this._semantics,
    required this._gates,
    required this._frames,
    required this._policy,
    required this._isAppResumed,
    required this._owner,
    required this.identifier,
    required this.direction,
    required this.maxSteps,
    required this.deadline,
    required this.durationBudgetMs,
  });

  final PatchbaySemanticsBridge _semantics;
  final PatchbayGateEvaluator _gates;
  final PatchbayFrameObserver _frames;
  final PatchbayRevealPolicy _policy;
  final bool Function() _isAppResumed;
  final SemanticsOwner _owner;

  final String identifier;
  final PatchbayRevealDirection direction;
  final int maxSteps;

  /// 单一 deadline，受理时刻算一次，此后不再改写。
  final DateTime deadline;

  /// 已冻结的时长预算，用于判断升层容器是否授权了这么长的驱动。
  final int durationBudgetMs;

  /// 已派发的 scroll action 次数。门在第 k 步拒绝时它等于 `k - 1`。
  int steps = 0;

  /// 按被驱动的先后顺序（由内向外）排列的容器记录。
  final List<PatchbayRevealContainerRecord> containers =
      <PatchbayRevealContainerRecord>[];

  final Set<int> _visitedNodeIds = <int>{};
  PatchbayRevealLayer? _layer;

  /// 目标此刻是否已挂载且露出。
  PatchbayRevealOutcome? revealedNow() => patchbayRevealedNow(
    owner: _owner,
    node: _readTarget().node,
    semantics: _semantics,
  );

  /// 驱动准入容器，必要时由内向外升层，直到终止。
  Future<PatchbayRevealOutcome> run({
    required PatchbayRevealContainerAnchor admission,
    required PatchbayRevealDecision decision,
    String? anchorIdentifier,
  }) async {
    _enter(admission, decision, anchorIdentifier: anchorIdentifier);
    while (true) {
      final PatchbayRevealOutcome? terminal = await _step();
      if (terminal != null) return terminal;
    }
  }

  void _enter(
    PatchbayRevealContainerAnchor anchor,
    PatchbayRevealDecision decision, {
    String? anchorIdentifier,
  }) {
    _visitedNodeIds.add(anchor.nodeId);
    _layer = PatchbayRevealLayer(
      anchorIdentifier: anchorIdentifier,
      nodeId: anchor.nodeId,
      generation: anchor.generation,
      decision: decision,
      axis: PatchbayRevealAxis.of(anchor.node.getSemanticsData()),
      requested: direction,
    );
  }

  // ---------------------------------------------------------------- 一步

  /// 一步的固定序列，顺序不可颠倒。返回非 null 即终止。
  Future<PatchbayRevealOutcome?> _step() async {
    final PatchbayRevealLayer layer = _layer!;
    // a/b：全局预算先于容器级预算，两者都在派发之前。
    if (!DateTime.now().isBefore(deadline)) {
      return _failed(PatchbayRevealReason.timeout);
    }
    if (steps >= maxSteps) {
      return _failed(PatchbayRevealReason.stepBudgetExceeded);
    }
    // c：该层耗尽（同步判定点记下的，或该容器自己的步数预算用完）⇒ 升层。
    final PatchbayRevealContainerRecord? record = layer.record;
    if (layer.exhausted ||
        (record != null && record.steps >= layer.decision.maxSteps)) {
      return _escalate();
    }
    if (!_isAppResumed()) {
      return _failed(PatchbayRevealReason.lifecycleNotResumed);
    }

    // e：按 pin 重解析容器。换代意味着这已经不是被授权的那块可滚动区域。
    final SemanticsNode? node = patchbayRevealResolveLayerNode(
      owner: _owner,
      semantics: _semantics,
      anchorIdentifier: layer.anchorIdentifier,
      nodeId: layer.nodeId,
      generation: layer.generation,
    );
    if (node == null) return _failed(PatchbayRevealReason.containerChanged);
    final SemanticsData data = node.getSemanticsData();

    // f：重跑 policy 并逐项比对决策。
    final PatchbayRevealDecision current = _policy(
      patchbayRevealTargetOf(node, layer.generation, data),
      direction,
    );
    if (!patchbayRevealSameDecision(layer.decision, current)) {
      return _failed(PatchbayRevealReason.policyChanged);
    }

    // 该方向的 action 现在还暴露吗？不暴露就无从派发——这既是「到底了」的边界
    // 信号，也是唯一不消耗步数、不求门的分支。
    final PatchbaySemanticsAction? action = layer.actionFor(data);
    if (action == null) return _stalledSync(layer);

    // g：每一步重评门（含基础门），受同一个 deadline 约束。
    final PatchbayRevealTimed<PatchbayGateRejection?> gated =
        await patchbayRevealBeforeDeadline(
          _gates.evaluate(layer.decision.gateIds),
          deadline,
        );
    if (!gated.completed) return _failed(PatchbayRevealReason.timeout);
    if (gated.value case final PatchbayGateRejection gate) {
      return _failed(
        PatchbayRevealReason.gateRejected,
        gateId: gate.gateId,
        gateCode: gate.code,
      );
    }

    // h：门与派发之间没有任何 await/yield，用同一次解析得到的 owner / nodeId；
    // `patchbayRevealDispatchScroll` 因此是同步的。
    final double? beforePosition = data.scrollPosition;
    final double? beforeExtentMax = data.scrollExtentMax;
    final String? failureType = patchbayRevealDispatchScroll(
      owner: _owner,
      nodeId: layer.nodeId,
      action: action,
    );
    if (failureType != null) {
      return _failed(
        PatchbayRevealReason.scrollActionFailed,
        failureType: failureType,
      );
    }
    steps += 1;
    patchbayRevealRecordDispatch(layer: layer, containers: containers);

    // i：帧驱动推进，不引入固定墙钟 sleep。本步已计入 steps。
    if (!await _frames.nextFrameBefore(deadline)) {
      return _failed(PatchbayRevealReason.timeout);
    }
    return _afterStep(layer, action, beforePosition, beforeExtentMax);
  }

  /// 派发并等到一帧之后的判定：极性、目标、进展。
  PatchbayRevealOutcome? _afterStep(
    PatchbayRevealLayer layer,
    PatchbaySemanticsAction action,
    double? beforePosition,
    double? beforeExtentMax,
  ) {
    final PatchbayRevealProgress progress = patchbayRevealObserveProgress(
      owner: _owner,
      nodeId: layer.nodeId,
      beforePosition: beforePosition,
      beforeExtentMax: beforeExtentMax,
    );
    layer.learnPolarity(action, progress.delta);
    layer.record!.note(layer.labelFor(action));

    // j：目标判定。
    final PatchbayRevealTargetView target = _readTarget();
    if (target.ambiguous) {
      return _failed(PatchbayRevealReason.targetAmbiguous);
    }
    if (target.node case final SemanticsNode mounted) {
      if (mounted.areUserActionsBlocked) {
        // 模态屏蔽，滚动解决不了：不再继续滚动。
        return _failed(PatchbayRevealReason.targetBlocked);
      }
      final PatchbayRevealOutcome? revealed = mounted.isInvisible
          ? null
          : patchbayRevealedNow(
              owner: _owner,
              node: mounted,
              semantics: _semantics,
            );
      if (revealed != null) return revealed;
      // 早停：目标挂载后，当前层若不在目标的祖先链上，继续推它不会让目标露出，
      // 只会白白花掉步数预算。授权模型不变：升层照样要过 policy 与门。
      if (patchbayRevealLayerOffTargetChain(
        owner: _owner,
        mounted: mounted,
        layerNodeId: layer.nodeId,
      )) {
        return _escalateSync();
      }
    }

    // k/l：进展判定与该方向耗尽。
    //
    // `extentGrowthSteps` 是「该容器上观察到 scrollExtentMax 增长的步数」这条
    // 懒加载证据本身，所以它按增长计数，与位置有没有同时变化无关；stall 的
    // 判据仍然是两者取或——位置变了，或者内容刚补进来，都算有效步。
    if (progress.grew) layer.record!.extentGrowthSteps += 1;
    if (progress.moved || progress.grew) {
      // 增长清零 stall，但**不追加步数预算**：`maxSteps` 是任何情况下都不被
      // 突破的唯一硬上限，无限流也不会把一次调用变成无界循环。
      layer.stall = 0;
      return null;
    }
    return _stalledSync(layer);
  }

  /// stall + 1，达到阈值即换向或升层。
  PatchbayRevealOutcome? _stalledSync(PatchbayRevealLayer layer) =>
      layer.noteStallExhausted() ? _escalateSync() : null;

  // ---------------------------------------------------------------- 升层

  /// 由内向外换一层。返回非 null 即终止；null 表示新一层已进入。
  ///
  /// 升层的门求值发生在 [_escalate] 的异步路径上；从同步判定点（早停、stall）
  /// 触发时先把待升层记下来，由下一次 [_step] 完成——这样门求值仍然只在带
  /// deadline 的 await 里发生，也不会插进「门与 performAction 之间」。
  PatchbayRevealOutcome? _escalateSync() {
    _layer!.exhausted = true;
    return null;
  }

  Future<PatchbayRevealOutcome?> _escalate() async {
    final PatchbayRevealLayer layer = _layer!;
    final SemanticsNode? next = patchbayRevealNextContainer(
      owner: _owner,
      readTarget: _readTarget,
      currentNodeId: layer.nodeId,
      visitedNodeIds: _visitedNodeIds,
      direction: direction,
    );
    if (next == null) {
      final PatchbayRevealTargetView target = _readTarget();
      return _failed(
        target.node == null
            ? PatchbayRevealReason.scrollExhausted
            : PatchbayRevealReason.targetObscured,
      );
    }

    final SemanticsData data = next.getSemanticsData();
    final int generation = _semantics.observe(next).generation;
    final PatchbaySemanticsTarget target = patchbayRevealTargetOf(
      next,
      generation,
      data,
    );
    final PatchbayRevealDecision decision = _policy(target, direction);
    if (!decision.allowed) {
      return _failed(PatchbayRevealReason.containerDenied);
    }
    if (!patchbayRevealWithinHostCaps(decision) ||
        decision.maxDurationMs < durationBudgetMs) {
      // 外层授权的时长比本次已冻结的预算更严：那个容器的接入方没有授权这么长
      // 的驱动，继续推它就是越权。deadline 不改写，停止并如实报告。
      return _failed(PatchbayRevealReason.containerBudgetTooSmall);
    }

    final PatchbayRevealTimed<PatchbayGateRejection?> gated =
        await patchbayRevealBeforeDeadline(
          _gates.evaluate(decision.gateIds),
          deadline,
        );
    if (!gated.completed) return _failed(PatchbayRevealReason.timeout);
    if (gated.value case final PatchbayGateRejection gate) {
      return _failed(
        PatchbayRevealReason.gateRejected,
        gateId: gate.gateId,
        gateCode: gate.code,
      );
    }

    _enter(
      PatchbayRevealContainerAnchor(
        node: next,
        nodeId: next.id,
        generation: generation,
        target: target,
      ),
      decision,
    );
    return null;
  }

  // ---------------------------------------------------------- 解析与判定

  PatchbayRevealTargetView _readTarget() =>
      patchbayRevealReadTarget(owner: _owner, identifier: identifier);

  /// 终止时目标已挂载就带 nodeId/generation，未挂载就不带。
  PatchbayRevealOutcome _failed(
    String reason, {
    String? failureType,
    String? gateId,
    String? gateCode,
  }) => patchbayRevealFailedOutcome(
    reason,
    node: _readTarget().node,
    semantics: _semantics,
    failureType: failureType,
    gateId: gateId,
    gateCode: gateCode,
  );
}
