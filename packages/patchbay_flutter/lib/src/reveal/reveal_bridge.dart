// PB-050-17 / DG-050-10：`ui.reveal` 的受理、容器确定与 payload 组装。
//
// 步进循环在 reveal_engine.dart；本文件只做受理边界上的事：参数校验、准入容器
// 的唯一确定、准入授权（policy + 门 + 决策复核）、单一 deadline 的冻结，以及
// 把引擎终态翻成稳定 payload。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

import '../frame_observer.dart';
import '../lifecycle.dart';
import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_lookup.dart';
import 'reveal_engine.dart';
import 'reveal_models.dart';

/// identifier 锚定的 scroll-to-reveal，debug 构建可用。
///
/// **未注入 reveal policy 即不可达，且不进 catalog**：升级 package 不会让任何
/// 现有 App 多出一条命令，接入方必须显式写下 reveal policy 才拿得到它。
/// [enabled] 与 `PatchbayGestureBridge.enabled` 逐字同形；`uiRevealDisabled`
/// 是直接调 bridge 时的防御纵深。
final class PatchbayRevealBridge {
  PatchbayRevealBridge({
    required this._gates,
    required this._semantics,
    required this._frames,
    this._policy,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _newRequestId = newRequestId ?? PatchbaySemanticsBridge.defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsBridge _semantics;
  final PatchbayFrameObserver _frames;
  final PatchbayRevealPolicy? _policy;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final String Function() _newRequestId;

  bool get enabled => !kReleaseMode && _policy != null;

  /// 把 [identifier] 驱动到已挂载且露出，返回后续写命令该带的 `generation`
  /// 与该走哪条 tap 通道的 `reachability`。
  Future<PatchbayInvocation> reveal({
    required String identifier,
    String? container,
    PatchbayRevealDirection direction = PatchbayRevealDirection.both,
    int maxSteps = PatchbayRevealBudget.defaultSteps,
    int timeoutMs = PatchbayRevealBudget.defaultTimeoutMs,
    String? requestId,
  }) async {
    final String id = requestId ?? _newRequestId();
    final DateTime started = DateTime.now();

    final List<String> invalid = <String>[
      if (identifier.isEmpty) 'identifier',
      if (container != null && container.isEmpty) 'container',
      if (maxSteps < 1 || maxSteps > PatchbayRevealBudget.maxSteps) 'maxSteps',
      if (timeoutMs < 1 || timeoutMs > PatchbayRevealBudget.maxDurationMs)
        'timeoutMs',
    ];
    if (invalid.isNotEmpty) {
      return _rejected(
        id,
        'invalidUiArguments',
        notice:
            'identifier must be non-empty, maxSteps must be '
            '1..${PatchbayRevealBudget.maxSteps} and timeoutMs must be '
            '1..${PatchbayRevealBudget.maxDurationMs}.',
        details: <String, Object?>{'invalid': invalid},
      );
    }

    final PatchbayRevealPolicy? policy = _policy;
    if (policy == null) return _rejected(id, 'uiRevealDisabled');
    if (!_isAppResumed()) {
      return _rejected(
        id,
        'uiLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }

    final SemanticsOwner? owner = await _semantics.ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return _rejected(id, 'uiSemanticsUnavailable');
    }
    final int beforeTreeRevision = _semantics.treeRevision;

    final List<SemanticsNode> targets = patchbaySemanticsNodesWithIdentifier(
      root,
      identifier,
    );
    if (targets.length > 1) {
      // 目标未挂载是本命令存在的理由，不是错误；多个挂载实例才是。
      return _rejected(
        id,
        'uiSemanticsIdentifierAmbiguous',
        details: <String, Object?>{
          'identifier': identifier,
          'role': 'target',
          'matchCount': targets.length,
        },
      );
    }
    final SemanticsNode? target = targets.isEmpty ? null : targets.single;

    final _Admission admission = _admit(
      id: id,
      root: root,
      identifier: identifier,
      container: container,
      direction: direction,
      target: target,
      alreadyRevealed: patchbayRevealedNow(
        owner: owner,
        node: target,
        semantics: _semantics,
      ),
    );
    if (admission.rejection case final PatchbayInvocation rejection) {
      return rejection;
    }
    if (admission.shortcut case final PatchbayRevealOutcome shortcut) {
      return _accepted(
        id,
        identifier: identifier,
        outcome: shortcut,
        steps: 0,
        containers: const <PatchbayRevealContainerRecord>[],
        started: started,
        beforeTreeRevision: beforeTreeRevision,
      );
    }

    return _run(
      id: id,
      started: started,
      owner: owner,
      policy: policy,
      anchor: admission.anchor!,
      anchorIdentifier: container,
      identifier: identifier,
      direction: direction,
      maxSteps: maxSteps,
      timeoutMs: timeoutMs,
      beforeTreeRevision: beforeTreeRevision,
    );
  }

  // ------------------------------------------------------------ 准入授权

  Future<PatchbayInvocation> _run({
    required String id,
    required DateTime started,
    required SemanticsOwner owner,
    required PatchbayRevealPolicy policy,
    required PatchbayRevealContainerAnchor anchor,
    required String? anchorIdentifier,
    required String identifier,
    required PatchbayRevealDirection direction,
    required int maxSteps,
    required int timeoutMs,
    required int beforeTreeRevision,
  }) async {
    final PatchbayRevealDecision decision = policy(anchor.target, direction);
    final PatchbayInvocation? denied = _decisionRejection(
      id,
      decision,
      maxSteps: maxSteps,
      timeoutMs: timeoutMs,
    );
    if (denied != null) return denied;

    // 生效预算恒为 min(参数, policy, host)，且这个 min 通过**拒绝**达成而不是
    // 通过夹取——上面的 `_decisionRejection` 已经把越界拒掉，这里的 min 只是
    // 把三层收紧写成一处，不产生静默夹取。
    final int budgetMs = math.min(
      math.min(timeoutMs, decision.maxDurationMs),
      PatchbayRevealBudget.maxDurationMs,
    );
    final DateTime deadline = started.add(Duration(milliseconds: budgetMs));

    final PatchbayGateRejection? gate = await _gates.evaluate(decision.gateIds);
    if (gate != null) return _gateRejected(id, gate);
    if (!_isAppResumed()) {
      return _rejected(
        id,
        'uiLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }

    // 门可能 await：重解析容器并复核决策，否则一次准入可能落在另一块区域上。
    final SemanticsNode? root = owner.rootSemanticsNode;
    final SemanticsNode? node = root == null
        ? null
        : patchbaySemanticsNodeById(root, anchor.nodeId);
    if (node == null ||
        _semantics.observe(node).generation != anchor.generation) {
      return _rejected(id, 'uiRevealPolicyChanged');
    }
    final PatchbayRevealDecision recheck = policy(
      patchbayRevealTargetOf(node, anchor.generation, node.getSemanticsData()),
      direction,
    );
    if (!_sameDecision(decision, recheck)) {
      return _rejected(id, 'uiRevealPolicyChanged');
    }

    final PatchbayRevealEngine engine = PatchbayRevealEngine(
      semantics: _semantics,
      gates: _gates,
      frames: _frames,
      policy: policy,
      isAppResumed: _isAppResumed,
      owner: owner,
      identifier: identifier,
      direction: direction,
      maxSteps: maxSteps,
      deadline: deadline,
      durationBudgetMs: budgetMs,
    );
    // 进入循环之前先做一次目标判定（步数为 0 的那一次）。
    final PatchbayRevealOutcome outcome =
        engine.revealedNow() ??
        await engine.run(
          admission: anchor,
          decision: decision,
          anchorIdentifier: anchorIdentifier,
        );
    if (!outcome.revealed && engine.steps == 0) {
      return _preDispatchRejection(id, identifier, outcome);
    }
    return _accepted(
      id,
      identifier: identifier,
      outcome: outcome,
      steps: engine.steps,
      containers: engine.containers,
      started: started,
      beforeTreeRevision: beforeTreeRevision,
    );
  }

  /// 受理边界是**第一次派发**：一次 scroll action 都没派发出去的失败不是受理后
  /// 事实，按准入拒绝回答。
  ///
  /// 这既守住 payload 不变式（`failed` 的 `containers` 恒非空、
  /// `containers.isEmpty <=> steps == 0`），也守住「滚动已经发生就不撒谎、没发生
  /// 就不冒充受理」的另一半。准入容器在进入循环前已按请求方向判过可驱动，所以
  /// 走到这里的只有准入门与首步门之间那个窗口里发生的变化。
  ///
  /// 裁量点：Proposal 的准入前码表没有为「deadline 落在准入期内」单列一个码。
  /// 这里复用 `uiRevealBudgetExceeded` 并在 details 里指名 `timeoutMs`——它确实
  /// 是一条预算事实，且不发明新的稳定码。
  static PatchbayInvocation _preDispatchRejection(
    String id,
    String identifier,
    PatchbayRevealOutcome outcome,
  ) => switch (outcome.reason) {
    PatchbayRevealReason.gateRejected => PatchbayInvocation.rejected(
      requestId: id,
      rejection: PatchbayRejection(
        code: outcome.gateCode!,
        details: <String, Object?>{'gateId': outcome.gateId},
      ),
    ),
    PatchbayRevealReason.lifecycleNotResumed => _rejected(
      id,
      'uiLifecycleNotResumed',
    ),
    PatchbayRevealReason.policyChanged ||
    PatchbayRevealReason.containerChanged => _rejected(
      id,
      'uiRevealPolicyChanged',
    ),
    PatchbayRevealReason.containerDenied => _rejected(id, 'uiRevealDenied'),
    PatchbayRevealReason.containerBudgetTooSmall => _rejected(
      id,
      'uiRevealBudgetExceeded',
      details: <String, Object?>{
        'exceeded': <String>['timeoutMs'],
      },
    ),
    PatchbayRevealReason.timeout => _rejected(
      id,
      'uiRevealBudgetExceeded',
      notice: 'The reveal deadline expired before any scroll was dispatched.',
      details: <String, Object?>{
        'exceeded': <String>['timeoutMs'],
      },
    ),
    PatchbayRevealReason.targetAmbiguous => _rejected(
      id,
      'uiSemanticsIdentifierAmbiguous',
      details: <String, Object?>{'identifier': identifier, 'role': 'target'},
    ),
    _ => _rejected(
      id,
      'uiRevealNoScrollableContainer',
      notice:
          'The admitted container stopped being drivable before the first '
          'scroll action was dispatched.',
      details: <String, Object?>{'identifier': identifier},
    ),
  };

  PatchbayInvocation? _decisionRejection(
    String id,
    PatchbayRevealDecision decision, {
    required int maxSteps,
    required int timeoutMs,
  }) {
    if (!decision.allowed) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: decision.rejectionCode!,
          notice: decision.rejectionNotice,
        ),
      );
    }
    // policy 自身越出 host 硬顶不是「放宽」，而是让这条 decision 整体非法；
    // 参数越出 policy 上限一步都不派发，也不静默夹取——被夹取后的
    // `stepBudgetExceeded` 会被误读成「列表真的很长」。
    final List<String> exceeded = <String>[
      if (decision.maxSteps < 1 ||
          decision.maxSteps > PatchbayRevealBudget.maxSteps ||
          maxSteps > decision.maxSteps)
        'maxSteps',
      if (decision.maxDurationMs < 1 ||
          decision.maxDurationMs > PatchbayRevealBudget.maxDurationMs ||
          timeoutMs > decision.maxDurationMs)
        'timeoutMs',
    ];
    if (exceeded.isEmpty) return null;
    return _rejected(
      id,
      'uiRevealBudgetExceeded',
      details: <String, Object?>{
        'exceeded': exceeded,
        'hostMaxSteps': PatchbayRevealBudget.maxSteps,
        'hostMaxDurationMs': PatchbayRevealBudget.maxDurationMs,
      },
    );
  }

  // ------------------------------------------------------------ 容器确定

  /// 准入容器按固定顺序确定，每一步都要么唯一，要么拒绝。
  ///
  /// 不按尺寸、深度或可滚动距离给候选打分——那正是 design.md 红线要挡的猜测。
  _Admission _admit({
    required String id,
    required SemanticsNode root,
    required String identifier,
    required String? container,
    required PatchbayRevealDirection direction,
    required SemanticsNode? target,
    required PatchbayRevealOutcome? alreadyRevealed,
  }) {
    if (container != null) {
      return _admitAnchored(id, root, container, direction);
    }
    final List<SemanticsNode> candidates = target == null
        // 目标未挂载：没有祖先链可用，全树只有一个可驱动滚动节点时才用它。
        ? _drivable(patchbaySemanticsScrollNodesIn(root), direction)
        // 目标已挂载：祖先链上最内层的可驱动滚动节点。
        : _drivable(patchbaySemanticsScrollAncestors(target), direction);
    if (candidates.isEmpty) {
      if (alreadyRevealed != null) {
        // 链上没有可驱动容器而目标已经露出：无事可做，直接成功。
        return _Admission.shortcut(alreadyRevealed);
      }
      return _Admission.rejected(
        _rejected(
          id,
          'uiRevealNoScrollableContainer',
          details: <String, Object?>{'identifier': identifier},
          notice: target == null
              ? 'No drivable scroll container is mounted.'
              : 'No drivable scroll container encloses the target.',
        ),
      );
    }
    if (target == null && candidates.length > 1) {
      return _Admission.rejected(
        _rejected(
          id,
          'uiRevealContainerAmbiguous',
          details: <String, Object?>{
            'identifier': identifier,
            'candidateCount': candidates.length,
          },
          notice:
              'Several scroll containers are mounted and the target is not; '
              'name one with --container.',
        ),
      );
    }
    return _Admission.anchor(_anchorOf(candidates.first));
  }

  _Admission _admitAnchored(
    String id,
    SemanticsNode root,
    String container,
    PatchbayRevealDirection direction,
  ) {
    final List<SemanticsNode> anchors = patchbaySemanticsNodesWithIdentifier(
      root,
      container,
    );
    if (anchors.isEmpty) {
      return _Admission.rejected(
        _rejected(
          id,
          'uiSemanticsIdentifierNotFound',
          details: <String, Object?>{
            'identifier': container,
            'role': 'container',
            'matchCount': 0,
          },
        ),
      );
    }
    if (anchors.length > 1) {
      return _Admission.rejected(
        _rejected(
          id,
          'uiSemanticsIdentifierAmbiguous',
          details: <String, Object?>{
            'identifier': container,
            'role': 'container',
            'matchCount': anchors.length,
          },
        ),
      );
    }
    // 锚点通常包在 Scrollable 外层，所以从锚点子树内取**唯一**的滚动节点。
    final List<SemanticsNode> scrollables = patchbaySemanticsScrollNodesIn(
      anchors.single,
    );
    if (scrollables.length > 1) {
      return _Admission.rejected(
        _rejected(
          id,
          'uiRevealContainerAmbiguous',
          details: <String, Object?>{
            'identifier': container,
            'candidateCount': scrollables.length,
          },
        ),
      );
    }
    if (scrollables.isEmpty || _drivable(scrollables, direction).isEmpty) {
      return _Admission.rejected(
        _rejected(
          id,
          'uiRevealNoScrollableContainer',
          details: <String, Object?>{'identifier': container},
          notice:
              'The container anchor encloses no scroll node that currently '
              'exposes a same-axis scroll action.',
        ),
      );
    }
    return _Admission.anchor(_anchorOf(scrollables.single));
  }

  static List<SemanticsNode> _drivable(
    List<SemanticsNode> nodes,
    PatchbayRevealDirection direction,
  ) => <SemanticsNode>[
    for (final SemanticsNode node in nodes)
      if (patchbayRevealDrivable(node.getSemanticsData(), direction)) node,
  ];

  PatchbayRevealContainerAnchor _anchorOf(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    final int generation = _semantics.observe(node).generation;
    return PatchbayRevealContainerAnchor(
      node: node,
      nodeId: node.id,
      generation: generation,
      target: patchbayRevealTargetOf(node, generation, data),
    );
  }

  // ------------------------------------------------------------ payload

  PatchbayInvocation _accepted(
    String id, {
    required String identifier,
    required PatchbayRevealOutcome outcome,
    required int steps,
    required List<PatchbayRevealContainerRecord> containers,
    required DateTime started,
    required int beforeTreeRevision,
  }) => PatchbayInvocation.accepted(
    requestId: id,
    payload: PatchbayRevealResultWire(
      outcome: outcome.revealed ? 'revealed' : 'failed',
      source: PatchbayFactSourceWire.uiObserved,
      identifier: identifier,
      steps: steps,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
      containers: <PatchbayRevealContainerWire>[
        for (final PatchbayRevealContainerRecord record in containers)
          record.toWire(),
      ],
      nodeId: outcome.nodeId,
      generation: outcome.generation,
      reachability: outcome.reachability,
      beforeTreeRevision: beforeTreeRevision,
      afterTreeRevision: _semantics.treeRevision,
      reason: outcome.reason,
      failureType: outcome.failureType,
      gateId: outcome.gateId,
      gateCode: outcome.gateCode,
    ).toJson(),
  );

  static bool _sameDecision(
    PatchbayRevealDecision left,
    PatchbayRevealDecision right,
  ) =>
      left.allowed == right.allowed &&
      setEquals(left.gateIds, right.gateIds) &&
      left.maxSteps == right.maxSteps &&
      left.maxDurationMs == right.maxDurationMs;

  static PatchbayInvocation _rejected(
    String id,
    String code, {
    Map<String, Object?> details = const <String, Object?>{},
    String? notice,
  }) => PatchbayInvocation.rejected(
    requestId: id,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  );

  static PatchbayInvocation _gateRejected(
    String id,
    PatchbayGateRejection gate,
  ) => PatchbayInvocation.rejected(
    requestId: id,
    rejection: PatchbayRejection(
      code: gate.code,
      notice: gate.notice,
      details: <String, Object?>{'gateId': gate.gateId},
    ),
  );
}

/// 准入容器确定的三种结果：拒绝、无需驱动的直接成功、或一个已 pin 的容器。
final class _Admission {
  const _Admission.rejected(PatchbayInvocation this.rejection)
    : shortcut = null,
      anchor = null;
  const _Admission.shortcut(PatchbayRevealOutcome this.shortcut)
    : rejection = null,
      anchor = null;
  const _Admission.anchor(PatchbayRevealContainerAnchor this.anchor)
    : rejection = null,
      shortcut = null;

  final PatchbayInvocation? rejection;
  final PatchbayRevealOutcome? shortcut;
  final PatchbayRevealContainerAnchor? anchor;
}
