// PB-050-17 / DG-050-10：reveal 的步进循环。
//
// 独立于 `PatchbaySemanticsBridge._dispatch`（结构警戒线：不新增 long-function
// 警戒线）。入参是容器解析原语、policy、门与帧观察者，出参是终态；bridge 只做
// 受理、payload 组装与拒绝码映射。
//
// 机制唯一：本文件只派发 `SemanticsAction.scrollUp|scrollDown|scrollLeft|
// scrollRight`，**从不派发 `showOnScreen`**——它是一条接入方在快照里看不见、在
// 任何 policy 入参里也见不到的驱动通道，逐容器授权模型按构造容不下它。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';

import '../frame_observer.dart';
import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_lookup.dart';
import '../semantics/semantics_models.dart';
import 'reveal_admission.dart';
import 'reveal_models.dart';

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
  _Layer? _layer;

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
    _layer = _Layer(
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
    final _Layer layer = _layer!;
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
    final SemanticsNode? node = _resolveLayerNode(layer);
    if (node == null) return _failed(PatchbayRevealReason.containerChanged);
    final SemanticsData data = node.getSemanticsData();

    // f：重跑 policy 并逐项比对决策。
    final PatchbayRevealDecision current = _policy(
      patchbayRevealTargetOf(node, layer.generation, data),
      direction,
    );
    if (!_sameDecision(layer.decision, current)) {
      return _failed(PatchbayRevealReason.policyChanged);
    }

    // 该方向的 action 现在还暴露吗？不暴露就无从派发——这既是「到底了」的边界
    // 信号，也是唯一不消耗步数、不求门的分支。
    final PatchbaySemanticsAction? action = layer.actionFor(data);
    if (action == null) return _stalledSync(layer);

    // g：每一步重评门（含基础门），受同一个 deadline 约束。
    final _Timed<PatchbayGateRejection?> gated = await _beforeDeadline(
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

    // h：门与 performAction 之间没有任何 await/yield，用同一次解析得到的
    // owner / nodeId。
    final double? beforePosition = data.scrollPosition;
    final double? beforeExtentMax = data.scrollExtentMax;
    try {
      _owner.performAction(layer.nodeId, action.flutterAction);
    } catch (error) {
      return _failed(
        PatchbayRevealReason.scrollActionFailed,
        failureType: error.runtimeType.toString(),
      );
    }
    steps += 1;
    _recordDispatch(layer);

    // i：帧驱动推进，不引入固定墙钟 sleep。本步已计入 steps。
    if (!await _frames.nextFrameBefore(deadline)) {
      return _failed(PatchbayRevealReason.timeout);
    }
    return _afterStep(layer, action, beforePosition, beforeExtentMax);
  }

  /// 派发并等到一帧之后的判定：极性、目标、进展。
  PatchbayRevealOutcome? _afterStep(
    _Layer layer,
    PatchbaySemanticsAction action,
    double? beforePosition,
    double? beforeExtentMax,
  ) {
    final _Progress progress = _observe(layer, beforePosition, beforeExtentMax);
    layer.learnPolarity(action, progress.delta);
    layer.record!.note(layer.labelFor(action));

    // j：目标判定。
    final _TargetView target = _readTarget();
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
          : _revealedFor(mounted);
      if (revealed != null) return revealed;
      // 早停：目标挂载后，当前层若不在目标的祖先链上，继续推它不会让目标露出，
      // 只会白白花掉步数预算。授权模型不变：升层照样要过 policy 与门。
      final SemanticsNode? node = _owner.rootSemanticsNode == null
          ? null
          : patchbaySemanticsNodeById(_owner.rootSemanticsNode!, layer.nodeId);
      if (node != null && !patchbaySemanticsIsAncestorOrSelf(mounted, node)) {
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
  PatchbayRevealOutcome? _stalledSync(_Layer layer) {
    layer.stall += 1;
    if (layer.stall < PatchbayRevealBudget.stallSteps) return null;
    if (layer.flipIfPossible()) return null;
    return _escalateSync();
  }

  void _recordDispatch(_Layer layer) {
    final PatchbayRevealContainerRecord? existing = layer.record;
    if (existing != null) {
      existing.steps += 1;
      return;
    }
    // 元素只在第一次在该容器上派发时追加，因此 steps >= 1，因此
    // containers.isEmpty <=> 顶层 steps == 0。
    final PatchbayRevealContainerRecord record = PatchbayRevealContainerRecord(
      nodeId: layer.nodeId,
      generation: layer.generation,
    )..steps = 1;
    layer.record = record;
    containers.add(record);
  }

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
    final _Layer layer = _layer!;
    final SemanticsNode? next = _nextContainer(layer);
    if (next == null) {
      final _TargetView target = _readTarget();
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
    if (!_withinHostCaps(decision) ||
        decision.maxDurationMs < durationBudgetMs) {
      // 外层授权的时长比本次已冻结的预算更严：那个容器的接入方没有授权这么长
      // 的驱动，继续推它就是越权。deadline 不改写，停止并如实报告。
      return _failed(PatchbayRevealReason.containerBudgetTooSmall);
    }

    final _Timed<PatchbayGateRejection?> gated = await _beforeDeadline(
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

  /// 下一层：目标挂载时以目标祖先链为权威，否则沿当前层向外。
  SemanticsNode? _nextContainer(_Layer layer) {
    final SemanticsNode? root = _owner.rootSemanticsNode;
    if (root == null) return null;
    final _TargetView target = _readTarget();
    final SemanticsNode? currentNode = patchbaySemanticsNodeById(
      root,
      layer.nodeId,
    );
    final List<SemanticsNode> chain = switch (target.node) {
      // 目标挂载之后它的祖先链就是权威的容器栈，比准入时的判断更准。
      final SemanticsNode mounted => patchbaySemanticsScrollAncestors(mounted),
      null =>
        currentNode == null
            ? const <SemanticsNode>[]
            : patchbaySemanticsScrollAncestors(
                currentNode,
              ).skip(1).toList(growable: false),
    };
    for (final SemanticsNode candidate in chain) {
      if (_visitedNodeIds.contains(candidate.id)) continue;
      // 请求方向上不可驱动的滚动节点不构成候选容器：跳过。
      if (!patchbayRevealDrivable(candidate.getSemanticsData(), direction)) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  // ---------------------------------------------------------- 解析与判定

  SemanticsNode? _resolveLayerNode(_Layer layer) {
    final SemanticsNode? root = _owner.rootSemanticsNode;
    if (root == null) return null;
    final SemanticsNode? node = switch (layer.anchorIdentifier) {
      // 显式 --container 的容器按 identifier 锚点重解析；来自祖先链的容器没有
      // identifier，按 nodeId + generation 重解析。
      final String anchor => patchbayRevealScrollNodeUnder(root, anchor),
      null => patchbaySemanticsNodeById(root, layer.nodeId),
    };
    if (node == null || node.id != layer.nodeId) return null;
    return _semantics.observe(node).generation == layer.generation
        ? node
        : null;
  }

  _TargetView _readTarget() {
    final SemanticsNode? root = _owner.rootSemanticsNode;
    if (root == null) return const _TargetView.absent();
    final List<SemanticsNode> matches = patchbaySemanticsNodesWithIdentifier(
      root,
      identifier,
    );
    if (matches.isEmpty) return const _TargetView.absent();
    // 分页可能渲染重复项：多个挂载实例一律 fail-closed，不按树顺序选。
    if (matches.length > 1) return const _TargetView.ambiguous();
    return _TargetView.mounted(matches.single);
  }

  PatchbayRevealOutcome? _revealedFor(SemanticsNode node) =>
      patchbayRevealedNow(owner: _owner, node: node, semantics: _semantics);

  /// 终止时目标已挂载就带 nodeId/generation，未挂载就不带。
  PatchbayRevealOutcome _failed(
    String reason, {
    String? failureType,
    String? gateId,
    String? gateCode,
  }) {
    final SemanticsNode? node = _readTarget().node;
    return PatchbayRevealOutcome.failed(
      reason,
      nodeId: node?.id,
      generation: node == null ? null : _semantics.observe(node).generation,
      failureType: failureType,
      gateId: gateId,
      gateCode: gateCode,
    );
  }

  _Progress _observe(
    _Layer layer,
    double? beforePosition,
    double? beforeExtentMax,
  ) {
    final SemanticsNode? root = _owner.rootSemanticsNode;
    final SemanticsNode? node = root == null
        ? null
        : patchbaySemanticsNodeById(root, layer.nodeId);
    if (node == null) return const _Progress(delta: 0, grew: false);
    final SemanticsData data = node.getSemanticsData();
    final double? after = data.scrollPosition;
    final double delta = (after == null || beforePosition == null)
        ? 0
        : after - beforePosition;
    final double? afterMax = data.scrollExtentMax;
    final bool grew =
        afterMax != null &&
        beforeExtentMax != null &&
        afterMax > beforeExtentMax;
    return _Progress(delta: delta.isFinite ? delta : 0, grew: grew);
  }

  static bool _withinHostCaps(PatchbayRevealDecision decision) =>
      decision.maxSteps >= 1 &&
      decision.maxSteps <= PatchbayRevealBudget.maxSteps &&
      decision.maxDurationMs >= 1 &&
      decision.maxDurationMs <= PatchbayRevealBudget.maxDurationMs;

  /// 与 gesture 的 `_decisionEquals` 同构：四项逐项相等才继续。
  static bool _sameDecision(
    PatchbayRevealDecision left,
    PatchbayRevealDecision right,
  ) =>
      left.allowed == right.allowed &&
      setEquals(left.gateIds, right.gateIds) &&
      left.maxSteps == right.maxSteps &&
      left.maxDurationMs == right.maxDurationMs;

  static Future<_Timed<T>> _beforeDeadline<T>(
    Future<T> future,
    DateTime deadline,
  ) async {
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return _Timed<T>.timeout();
    try {
      return _Timed<T>.completed(await future.timeout(remaining));
    } on TimeoutException {
      return _Timed<T>.timeout();
    }
  }
}

/// 容器在 policy 眼里的稳定身份。
///
/// 滚动节点自己几乎从不带 identifier：锚点按惯例包在 `Scrollable` 外层
/// （`Semantics(identifier: ..., child: ListView...)`），identifier 落在锚点节点
/// 上，滚动语义节点是它的后代。若把 `data.identifier` 原样交给 policy，接入方
/// 拿到的永远是空串，「允不允许推这块区域」就无从判断。
///
/// 所以这里取**该容器最内层的锚点 identifier**：沿 `parent` 向外找第一个非空
/// identifier，遇到另一个滚动节点即停——这样外层容器的锚点身份不会被误安到内层
/// 容器头上。这是一条确定的查找规则，不是按尺寸或深度打分的猜测。
String patchbayRevealContainerIdentity(SemanticsNode node, SemanticsData data) {
  if (data.identifier.isNotEmpty) return data.identifier;
  for (
    SemanticsNode? current = node.parent;
    current != null;
    current = current.parent
  ) {
    final SemanticsData ancestor = current.getSemanticsData();
    if (patchbayIsScrollNode(ancestor)) return '';
    if (ancestor.identifier.isNotEmpty) return ancestor.identifier;
  }
  return '';
}

/// 只读容器事实，形状与 `ui.semantics.*` 的 policy 入参同构。
PatchbaySemanticsTarget patchbayRevealTargetOf(
  SemanticsNode node,
  int generation,
  SemanticsData data,
) => PatchbaySemanticsTarget(
  nodeId: node.id,
  generation: generation,
  identifier: patchbayRevealContainerIdentity(node, data),
  label: data.label,
  flags: Set<String>.unmodifiable(data.flagsCollection.toStrings()),
  actions: Set<PatchbaySemanticsAction>.unmodifiable(<PatchbaySemanticsAction>{
    for (final PatchbaySemanticsAction action in PatchbaySemanticsAction.values)
      if (data.hasAction(action.flutterAction)) action,
  }),
  obscured: data.flagsCollection.isObscured,
);

/// 锚点子树内**唯一**的滚动节点；0 个或多于 1 个都返回 null。
SemanticsNode? patchbayRevealScrollNodeUnder(
  SemanticsNode root,
  String anchorIdentifier,
) {
  final List<SemanticsNode> anchors = patchbaySemanticsNodesWithIdentifier(
    root,
    anchorIdentifier,
  );
  if (anchors.length != 1) return null;
  final List<SemanticsNode> scrollables = patchbaySemanticsScrollNodesIn(
    anchors.single,
  );
  return scrollables.length == 1 ? scrollables.single : null;
}

/// 一个容器同轴的两个 scroll action。
///
/// 极性（谁增大 `pixels`）不能从 `SemanticsData` 推出，只能观察：action 名字
/// 描述的是**用户会做的手势**，不是内容序。`reverse: true` 的竖直列表里，朝
/// `maxScrollExtent` 前进的那一个是 `scrollDown`。
final class PatchbayRevealAxis {
  const PatchbayRevealAxis(this.first, this.second);

  final PatchbaySemanticsAction first;
  final PatchbaySemanticsAction second;

  static const PatchbayRevealAxis vertical = PatchbayRevealAxis(
    PatchbaySemanticsAction.scrollUp,
    PatchbaySemanticsAction.scrollDown,
  );
  static const PatchbayRevealAxis horizontal = PatchbayRevealAxis(
    PatchbaySemanticsAction.scrollLeft,
    PatchbaySemanticsAction.scrollRight,
  );

  /// 该节点当前暴露的同轴 action 决定轴；一个都不暴露即不是可驱动容器。
  static PatchbayRevealAxis? of(SemanticsData data) {
    if (data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollDown)) {
      return vertical;
    }
    if (data.hasAction(SemanticsAction.scrollLeft) ||
        data.hasAction(SemanticsAction.scrollRight)) {
      return horizontal;
    }
    return null;
  }

  PatchbaySemanticsAction other(PatchbaySemanticsAction action) =>
      action == first ? second : first;

  List<PatchbaySemanticsAction> exposedIn(SemanticsData data) =>
      <PatchbaySemanticsAction>[
        if (data.hasAction(first.flutterAction)) first,
        if (data.hasAction(second.flutterAction)) second,
      ];
}

/// 事实一：只暴露一个同轴 action 时，`pixels` 处于某一端，极性由端点唯一确定。
///
/// 在 `min` 处暴露的是内容序 forward，在 `max` 处暴露的是 backward。两个都暴露
/// 或端点信息不足时返回 null——那时极性只能靠一次探测步观察出来。
PatchbaySemanticsAction? patchbayRevealForwardFromEnd(
  SemanticsData data,
  PatchbayRevealAxis axis,
  List<PatchbaySemanticsAction> exposed,
) {
  if (exposed.length != 1) return null;
  final double? position = data.scrollPosition;
  if (position == null) return null;
  final double? min = data.scrollExtentMin;
  final double? max = data.scrollExtentMax;
  if (min != null && position <= min) return exposed.single;
  if (max != null && position >= max) return axis.other(exposed.single);
  return null;
}

/// 该节点此刻能否朝请求的方向被驱动。
///
/// 准入与升层用同一个判据：一个同轴 scroll action 都不暴露、或请求方向上的那个
/// action 已经不在容器上（例如已经滚到那一端），都不构成可驱动容器。准入时按
/// `uiRevealNoScrollableContainer` 拒绝，升层时直接跳过——两处都不会走到「一次
/// 都没派发却回一个受理后 failed」的形状上。
bool patchbayRevealDrivable(
  SemanticsData data,
  PatchbayRevealDirection direction,
) {
  final PatchbayRevealAxis? axis = PatchbayRevealAxis.of(data);
  if (axis == null) return false;
  final List<PatchbaySemanticsAction> exposed = axis.exposedIn(data);
  if (exposed.isEmpty) return false;
  if (direction == PatchbayRevealDirection.both) return true;
  final PatchbaySemanticsAction? forward = patchbayRevealForwardFromEnd(
    data,
    axis,
    exposed,
  );
  // 极性还不确定：探测步会把它定下来，此时不能预先判它不可驱动。
  if (forward == null) return true;
  final PatchbaySemanticsAction wanted =
      direction == PatchbayRevealDirection.forward
      ? forward
      : axis.other(forward);
  return exposed.contains(wanted);
}

/// 一层容器在循环中的可变状态。
final class _Layer {
  _Layer({
    required this.anchorIdentifier,
    required this.nodeId,
    required this.generation,
    required this.decision,
    required this._axis,
    required this.requested,
  });

  final String? anchorIdentifier;
  final int nodeId;
  final int generation;
  final PatchbayRevealDecision decision;
  final PatchbayRevealAxis? _axis;
  final PatchbayRevealDirection requested;

  PatchbayRevealContainerRecord? record;
  int stall = 0;

  /// 由同步判定点（早停 / stall 达阈值）记下的「该层耗尽」。
  bool exhausted = false;

  /// 已知的极性：内容序 forward 落到的那个 action。null 表示还没观察到。
  PatchbaySemanticsAction? _forward;

  /// 当前正在驱动的 action；null 表示还没选定。
  PatchbaySemanticsAction? _active;
  final Set<PatchbaySemanticsAction> _driven = <PatchbaySemanticsAction>{};
  bool _probeSpent = false;

  /// 本步要派发的 action，null 表示这一步无从派发。
  PatchbaySemanticsAction? actionFor(SemanticsData data) {
    final PatchbayRevealAxis? axis = _axis;
    if (axis == null) return null;
    final List<PatchbaySemanticsAction> exposed = axis.exposedIn(data);
    if (exposed.isEmpty) return null;

    // 事实一：只暴露一个同轴 action 时，`pixels` 处于某一端，极性由端点唯一
    // 确定——在 min 处暴露的是 forward，在 max 处暴露的是 backward。零成本。
    _inferFromEnd(data, exposed);

    final PatchbaySemanticsAction? active = _active;
    if (active != null) return exposed.contains(active) ? active : null;

    if (requested == PatchbayRevealDirection.both) {
      // `both` 不需要极性：两个 action 各自驱动到耗尽，顺序不影响结果；极性只
      // 用于给 containers[].direction 打标签，而每一步都会观察位移符号。
      for (final PatchbaySemanticsAction candidate in exposed) {
        if (_driven.contains(candidate)) continue;
        _active = candidate;
        return candidate;
      }
      return null;
    }

    final PatchbaySemanticsAction? mapped = _mappedFor(requested);
    if (mapped != null) {
      if (!exposed.contains(mapped)) return null;
      _active = mapped;
      return mapped;
    }
    // 两个同轴 action 都暴露且请求方向是显式的：需要一步探测步。它计入 steps
    // 与 containers[].steps，每容器每次调用至多一次，且发生在门与 policy 复核
    // 之后——它本身也是一次完整授权下的驱动。
    if (_probeSpent) return null;
    _probeSpent = true;
    _active = exposed.first;
    return _active;
  }

  void _inferFromEnd(
    SemanticsData data,
    List<PatchbaySemanticsAction> exposed,
  ) {
    _forward ??= patchbayRevealForwardFromEnd(data, _axis!, exposed);
  }

  PatchbaySemanticsAction? _mappedFor(PatchbayRevealDirection wanted) {
    final PatchbaySemanticsAction? forward = _forward;
    if (forward == null) return null;
    return wanted == PatchbayRevealDirection.forward
        ? forward
        : _axis!.other(forward);
  }

  /// 派发一步之后由位移符号确定极性。
  ///
  /// 探测步走反了就为该容器翻转映射并继续：`_active` 换成正确的那一个。
  void learnPolarity(PatchbaySemanticsAction action, double delta) {
    _driven.add(action);
    if (delta == 0) return;
    _forward ??= delta > 0 ? action : _axis!.other(action);
    if (requested == PatchbayRevealDirection.both) return;
    final PatchbaySemanticsAction? mapped = _mappedFor(requested);
    if (mapped != null && mapped != _active) {
      _active = mapped;
      stall = 0;
    }
  }

  /// 该 action 这一步实际把内容推向了哪个方向。
  PatchbayRevealDirection labelFor(PatchbaySemanticsAction action) {
    final PatchbaySemanticsAction? forward = _forward;
    if (forward == null) return requested;
    return action == forward
        ? PatchbayRevealDirection.forward
        : PatchbayRevealDirection.backward;
  }

  /// `both` 且该容器还有没走过的同轴 action ⇒ 换向、stall 归零。
  bool flipIfPossible() {
    final PatchbayRevealAxis? axis = _axis;
    if (axis == null || requested != PatchbayRevealDirection.both) return false;
    final PatchbaySemanticsAction? active = _active;
    if (active == null) return false;
    final PatchbaySemanticsAction other = axis.other(active);
    if (_driven.contains(other)) return false;
    _active = other;
    stall = 0;
    return true;
  }
}

final class _Progress {
  const _Progress({required this.delta, required this.grew});

  final double delta;
  final bool grew;

  bool get moved => delta != 0;
}

final class _TargetView {
  const _TargetView.absent() : node = null, ambiguous = false;
  const _TargetView.ambiguous() : node = null, ambiguous = true;
  const _TargetView.mounted(SemanticsNode this.node) : ambiguous = false;

  final SemanticsNode? node;
  final bool ambiguous;
}

final class _Timed<T> {
  const _Timed.completed(T this.value) : completed = true;
  const _Timed.timeout() : completed = false, value = null;

  final bool completed;
  final T? value;
}
