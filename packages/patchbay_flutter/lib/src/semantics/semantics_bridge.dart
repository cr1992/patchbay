// `ui.semantics.*` 的公共门面与准入管线编排。
//
// PB-050-38：这个文件只留三件事——对外的命令入口、语义树的采样与代际账本、以及
// 把准入阶段按冻结顺序串起来。每个阶段本身住在自己的文件里，可以脱离本桥单独
// 构造、单独失败注入、单独回退：
//
// - `semantics_resolve_stage.dart`：identifier / nodeId 两条路径的目标解析；
// - `semantics_preflight_stage.dart`：生命周期围栏与 gate 求值；
// - `semantics_policy_stage.dart`：门前 policy 与门后二次复核；
// - `semantics_dispatch_stage.dart`：遮挡准入与实际派发；
// - `semantics_evidence.dart`：拒绝 `details` 与 accepted 载荷的投影；
// - `semantics_action_taxonomy.dart`：两处封闭的 action 分类。
//
// 阶段顺序是 DG-060-04 冻结的口径，`_dispatch` 只负责按那个顺序走一遍，不再自己
// 决定任何一步长什么样。
import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

import '../frame_observer.dart';
import '../lifecycle.dart';
import 'semantics_action_taxonomy.dart';
import 'semantics_dispatch_stage.dart';
import 'semantics_evidence.dart';
import 'semantics_models.dart';
import 'semantics_policy_stage.dart';
import 'semantics_preflight_stage.dart';
import 'semantics_resolve_stage.dart';

/// 读取「当前 semantics owner」的来源。见 [debugPatchbaySemanticsOwnerSource]。
typedef PatchbaySemanticsOwnerSource = SemanticsOwner? Function();

/// **仅 debug 生效**的 owner 来源覆写，用于构造「root 尚不可用」这一状态。
///
/// PB-050-07 的有界恢复路径在 widget test 里天然不可达：Flutter 3.44 的语义重构
/// 会在 `SemanticsBinding.ensureSemantics()` 时同步建好树，`rootSemanticsNode`
/// 立刻可用。于是「owner 恢复最多三帧、且这些帧计入 `frameRevision`」——
/// DG-050-05 结论 2 要冻结的正是它——就没有别的办法在单元层证伪。
///
/// 读取点包在 `assert` 里，profile/release 构造上剥掉，生产路径永远是 render
/// views / root pipeline owner。本符号不出现在包的 barrel 里，不构成公共 API。
@visibleForTesting
PatchbaySemanticsOwnerSource? debugPatchbaySemanticsOwnerSource;

/// PB-050-07 / DG-050-05 冻结的 owner 状态。
///
/// `ready` 是唯一允许 one-shot 就地 probe 的状态；`awaitingFrame` 表示已有一个
/// 恢复 flight 在跑，新调用方加入它而不是各请各的帧；`disposed` 之后永不恢复。
enum _OwnerState { unknown, ready, awaitingFrame, disposed }

/// Public-API Flutter Semantics observer and action dispatcher.
///
/// A policy is deliberately optional. Without one the tree remains readable,
/// while executable semantics commands stay absent from the host catalog.
final class PatchbaySemanticsBridge {
  PatchbaySemanticsBridge({
    required this._gates,
    this._actionPolicy,
    PatchbayFrameObserver? frames,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _frames = frames ?? PatchbayFrameObserver(),
       _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _newRequestId = newRequestId ?? defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsActionPolicy? _actionPolicy;

  /// 与 `ui.wait`、reveal、navigation 共用的**同一个**帧计数器。
  ///
  /// PB-050-07 / DG-050-05 结论 2：owner 恢复驱动的帧也是实际驱动的帧，必须计入
  /// `frameRevision`。把观察器注进来而不是让本桥自己 `scheduleFrame`，就是为了
  /// 让「驱了帧」和「报告了帧」在构造上无法分开。
  final PatchbayFrameObserver _frames;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final String Function() _newRequestId;

  /// 生命周期围栏阶段。桥只提供两个接缝，判据住在阶段里。
  late final PatchbaySemanticsLifecycleFence _fence =
      PatchbaySemanticsLifecycleFence(
        isAppResumed: _isAppResumed,
        lifecycleState: _lifecycleState,
      );

  /// 目标解析阶段。owner、代际账本与树版本号都以接缝注入，阶段自己不持有状态。
  late final PatchbaySemanticsTargetResolver _resolver =
      PatchbaySemanticsTargetResolver(
        ensureOwner: () => ensureOwner(),
        observe: observe,
        entryFor: (int nodeId) => _entries[nodeId],
        treeRevision: () => _treeRevision,
      );

  SemanticsHandle? _semanticsHandle;
  SemanticsOwner? _owner;
  final Map<int, PatchbaySemanticsEntry> _entries =
      <int, PatchbaySemanticsEntry>{};
  int _nextGeneration = 0;
  int _treeRevision = 0;
  bool _disposed = false;
  _OwnerState _ownerState = _OwnerState.unknown;
  Future<SemanticsOwner?>? _ownerFlight;

  /// 主动恢复的帧上限。DG-050-05 明确不放宽本提案之前的三轮上限。
  static const int _maxOwnerRecoveryFrames = 3;

  static int _nextRequest = 0;
  static String defaultRequestId() => 'patchbay-semantics-${++_nextRequest}';

  bool get actionsEnabled => _actionPolicy != null;

  /// 本桥发布的语义树版本号的**同步**读数。
  ///
  /// 与 `snapshot` 的 `treeRevision`、`observeIdentifier` 的
  /// [PatchbaySemanticsIdentifierObservation.treeRevision] 是同一个计数器，只是
  /// 不请帧：PB-050-17 的 reveal 要在受理与终止两端各取一次，而终止那一端可能
  /// 正好落在 deadline 上，不能再为读一个计数器多等一帧。
  int get treeRevision => _treeRevision;

  /// Resolves a stable Semantics identifier without using labels or paths.
  Future<PatchbaySemanticsIdentifierObservation?> observeIdentifier(
    String identifier,
  ) async {
    final SemanticsOwner? owner = await ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (root == null) return null;
    final List<PatchbaySemanticsIdentifierMatch> matches =
        <PatchbaySemanticsIdentifierMatch>[];

    void visit(SemanticsNode node) {
      final SemanticsData data = node.getSemanticsData();
      if (data.identifier == identifier) {
        final PatchbaySemanticsEntry entry = observe(node);
        matches.add(
          PatchbaySemanticsIdentifierMatch(
            nodeId: node.id,
            generation: entry.generation,
            value: data.value,
            obscured: data.flagsCollection.isObscured,
            invisible: node.isInvisible,
          ),
        );
      }
      node.visitChildren((SemanticsNode child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    return PatchbaySemanticsIdentifierObservation(
      treeRevision: _treeRevision,
      matches: List<PatchbaySemanticsIdentifierMatch>.unmodifiable(matches),
    );
  }

  Future<int?> observeTreeRevision() async {
    final SemanticsOwner? owner = await ensureOwner();
    return owner?.rootSemanticsNode == null ? null : _treeRevision;
  }

  Future<PatchbayInvocation> snapshot({
    int maxDepth = 64,
    int maxNodes = 1000,
    String? requestId,
  }) async {
    final String id = requestId ?? _newRequestId();
    final List<String> outOfRange = <String>[
      if (maxDepth < 0) 'maxDepth',
      if (maxNodes < 1 || maxNodes > 10000) 'maxNodes',
    ];
    if (outOfRange.isNotEmpty) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: 'invalidUiTreeLimits',
          notice:
              'maxDepth must be non-negative and maxNodes must be 1..10000.',
          details: <String, Object?>{'invalid': outOfRange},
        ),
      );
    }
    final PatchbayInvocation? gate = await patchbaySemanticsGateFence(
      _gates,
      requestId: id,
      gateIds: const <String>{},
    );
    if (gate != null) return gate;
    final PatchbayInvocation? lifecycle = _fence.evaluate(id);
    if (lifecycle != null) return lifecycle;

    final SemanticsOwner? owner = await ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnavailable'),
      );
    }

    final PatchbaySemanticsSnapshot snapshot = _buildSnapshot(
      root,
      maxDepth: maxDepth,
      maxNodes: maxNodes,
    );
    return PatchbayInvocation.accepted(
      requestId: id,
      payload: snapshot.toJson(_treeRevision),
    );
  }

  Future<PatchbayInvocation> invoke({
    required int nodeId,
    required int generation,
    required PatchbaySemanticsAction action,
    String? text,
    bool inputWasStdin = false,
    String? requestId,
  }) => _dispatch(
    requestId: requestId ?? _newRequestId(),
    action: action,
    text: text,
    inputWasStdin: inputWasStdin,
    resolve: (int? _) => _resolver.byNodeId(
      nodeId: nodeId,
      generation: generation,
      action: action,
    ),
  );

  /// Resolves a stable Semantics [identifier] and dispatches one public
  /// [action] while preserving the caller's required [generation] fence.
  Future<PatchbayInvocation> invokeIdentifier({
    required String identifier,
    required int generation,
    required PatchbaySemanticsAction action,
    String? text,
    bool inputWasStdin = false,
    String? requestId,
  }) {
    final String id = requestId ?? _newRequestId();
    final List<String> invalid = <String>[
      if (identifier.isEmpty) 'identifier',
      if (generation < 0) 'generation',
      if (!action.isPublicIdentifierAction) 'action',
    ];
    if (invalid.isNotEmpty) {
      return Future<PatchbayInvocation>.value(
        PatchbayInvocation.rejected(
          requestId: id,
          rejection: PatchbayRejection(
            code: 'invalidUiArguments',
            notice:
                'identifier must be non-empty, generation non-negative, and '
                'action publicly declared.',
            details: <String, Object?>{'invalid': invalid},
          ),
        ),
      );
    }
    return _dispatch(
      requestId: id,
      action: action,
      identifier: identifier,
      text: text,
      inputWasStdin: inputWasStdin,
      resolve: (int? pinnedGeneration) => _resolver.byIdentifier(
        identifier: identifier,
        expectedGeneration: pinnedGeneration ?? generation,
        action: action,
      ),
    );
  }

  /// Resolves a stable Semantics [identifier] and dispatches `tap` in one
  /// admitted request.
  Future<PatchbayInvocation> tapIdentifier({
    required String identifier,
    int? expectedGeneration,
    String? requestId,
  }) {
    final String id = requestId ?? _newRequestId();
    if (identifier.isEmpty || (expectedGeneration ?? 0) < 0) {
      return Future<PatchbayInvocation>.value(
        PatchbayInvocation.rejected(
          requestId: id,
          rejection: PatchbayRejection(
            code: 'invalidUiArguments',
            notice: 'identifier must be non-empty and generation non-negative.',
            details: <String, Object?>{
              'identifier': identifier,
              'expectedGeneration': ?expectedGeneration,
            },
          ),
        ),
      );
    }
    return _dispatch(
      requestId: id,
      action: PatchbaySemanticsAction.tap,
      identifier: identifier,
      resolve: (int? pinnedGeneration) => _resolver.byIdentifier(
        identifier: identifier,
        expectedGeneration: pinnedGeneration ?? expectedGeneration,
        action: PatchbaySemanticsAction.tap,
      ),
    );
  }

  /// Shared admission pipeline for every Semantics action.
  ///
  /// 顺序是冻结的，本方法只做编排：policy 存在性 → base gate → 生命周期围栏 →
  /// 解析目标 → 门前 policy（含文本与敏感输入判据）→ 声明门 → 生命周期围栏 →
  /// **再解析一次** → 门后复核 → 遮挡准入 → 派发。
  ///
  /// 「再解析、再决策」不是冗余：声明门的 `await` 是现场唯一能变的窗口，门前的
  /// 结论过了那个窗口就不再权威。
  Future<PatchbayInvocation> _dispatch({
    required String requestId,
    required PatchbaySemanticsAction action,
    required Future<PatchbaySemanticsResolution> Function(int? pinnedGeneration)
    resolve,
    String? identifier,
    String? text,
    bool inputWasStdin = false,
  }) async {
    final String id = requestId;
    final PatchbaySemanticsActionPolicy? policy = _actionPolicy;
    if (policy == null) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'uiSemanticsActionsDisabled'),
      );
    }
    final PatchbayInvocation? baseGate = await patchbaySemanticsGateFence(
      _gates,
      requestId: id,
      gateIds: const <String>{},
    );
    if (baseGate != null) return baseGate;
    final PatchbayInvocation? preflight = _fence.evaluate(id);
    if (preflight != null) return preflight;

    PatchbaySemanticsResolution resolution = await resolve(null);
    if (!resolution.resolved) {
      return patchbaySemanticsResolutionRejected(id, resolution);
    }
    final int pinnedGeneration = resolution.target!.generation;

    final PatchbaySemanticsPolicyAdmission admission =
        patchbaySemanticsAdmitPolicy(
          requestId: id,
          policy: policy,
          target: resolution.target!,
          action: action,
          text: text,
          inputWasStdin: inputWasStdin,
        );
    if (!admission.admitted) return admission.rejection!;

    final PatchbayInvocation? declaredGate = await patchbaySemanticsGateFence(
      _gates,
      requestId: id,
      gateIds: admission.gateIds,
    );
    if (declaredGate != null) return declaredGate;
    final PatchbayInvocation? postGateFence = _fence.evaluate(id);
    if (postGateFence != null) return postGateFence;

    resolution = await resolve(pinnedGeneration);
    final PatchbaySemanticsRevalidation revalidated =
        patchbaySemanticsRevalidate(
          requestId: id,
          policy: policy,
          action: action,
          admitted: admission,
          resolution: resolution,
          inputWasStdin: inputWasStdin,
        );
    if (!revalidated.admitted) return revalidated.rejection!;

    final SemanticsOwner owner = resolution.owner!;
    final int nodeId = resolution.target!.nodeId;
    final int generation = resolution.target!.generation;
    // 复核与派发之间**不得存在任何 await/yield**：遮挡准入是同步的，
    // `patchbaySemanticsPerformAction` 的 `performAction` 在第一个 `await` 之前，
    // 因此两者与上面这次 resolve 处在同一个微任务里。
    final PatchbayInvocation? obscured = patchbaySemanticsOcclusionFence(
      requestId: id,
      action: action,
      owner: owner,
      node: resolution.node!,
      nodeId: nodeId,
      generation: generation,
      identifier: identifier,
    );
    if (obscured != null) return obscured;

    return patchbaySemanticsPerformAction(
      requestId: id,
      owner: owner,
      action: action,
      nodeId: nodeId,
      generation: generation,
      sensitive: revalidated.sensitive,
      treeRevision: () => _treeRevision,
      refreshOwner: _refreshOwner,
      identifier: identifier,
      text: text,
    );
  }

  /// PB-050-07 / DG-050-05：owner 获取的两个内部操作之一——**同步、不请帧**。
  ///
  /// 只读当前 render views / root pipeline owner，并处理 listener 的摘挂与 owner
  /// 变更。one-shot semantics 命令先走这一步；owner 带 root 时就地 probe。
  SemanticsOwner? _refreshOwnerNow() {
    if (_disposed) return null;
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
    final SemanticsOwner? owner = _refreshOwner();
    _ownerState = owner?.rootSemanticsNode == null
        ? _OwnerState.unknown
        : _OwnerState.ready;
    return owner;
  }

  /// owner 获取的第二个内部操作：**有界的主动恢复**。
  ///
  /// 仅在当前没有带 root 的 owner 时请帧并等待 `endOfFrame`，最多
  /// [_maxOwnerRecoveryFrames] 轮、单轮 timeout 沿用 [frameTimeout]。
  ///
  /// 同一时刻最多一个 flight：并发的 VM / direct 调用共享同一次 owner 建立结果。
  /// 调用方各自的 deadline 由上层预算（transport deadline、`ui.wait` 的总
  /// timeout）夹住——短调用方放弃等待**不取消**本 flight，也不影响其他等待者。
  Future<SemanticsOwner?> _awaitOwner(Duration frameTimeout) {
    if (_ownerState == _OwnerState.disposed) {
      return Future<SemanticsOwner?>.value();
    }
    final Future<SemanticsOwner?>? inFlight = _ownerFlight;
    if (inFlight != null) return inFlight;
    return _ownerFlight = _runOwnerFlight(frameTimeout);
  }

  Future<SemanticsOwner?> _runOwnerFlight(Duration frameTimeout) async {
    _ownerState = _OwnerState.awaitingFrame;
    try {
      SemanticsOwner? owner = _owner;
      for (var attempt = 0; attempt < _maxOwnerRecoveryFrames; attempt += 1) {
        // 恢复帧走共享的帧观察器：驱动与计入 frameRevision 是同一个动作。
        final bool observed = await _frames.nextFrameBefore(
          DateTime.now().add(frameTimeout),
        );
        if (_disposed) return null;
        owner = _refreshOwner();
        if (!observed || owner?.rootSemanticsNode != null) break;
      }
      _ownerState = owner?.rootSemanticsNode == null
          ? _OwnerState.unknown
          : _OwnerState.ready;
      return owner;
    } finally {
      _ownerFlight = null;
    }
  }

  /// 取一个可用于 probe 的 owner。
  ///
  /// PB-050-07 / DG-050-05 结论 1：**owner/root 已可用时零额外帧**。读到的是调用
  /// 开始时 engine 已提交的 semantics tree，不承诺再刷新一帧——响应与文档都不得
  /// 把它说成「命令后下一帧的树」。首次启用 semantics、owner 被替换或 root 缺失
  /// 时才进入有界恢复。
  Future<SemanticsOwner?> ensureOwner({
    Duration frameTimeout = const Duration(seconds: 2),
  }) {
    if (_ownerState == _OwnerState.disposed) {
      return Future<SemanticsOwner?>.value();
    }
    final SemanticsOwner? ready = _refreshOwnerNow();
    if (_ownerState == _OwnerState.ready) {
      return Future<SemanticsOwner?>.value(ready);
    }
    return _awaitOwner(frameTimeout);
  }

  SemanticsOwner? _refreshOwner() {
    final SemanticsOwner? current = _currentOwnerFromBindings();
    if (identical(current, _owner)) return current;
    _owner?.removeListener(_onSemanticsChanged);
    _owner = current;
    _owner?.addListener(_onSemanticsChanged);
    _treeRevision += 1;
    _entries.clear();
    return current;
  }

  static SemanticsOwner? _currentOwnerFromBindings() {
    PatchbaySemanticsOwnerSource? override;
    // `assert` 在 profile/release 被整体剥掉，因此覆写在非 debug 构造上不可达。
    assert(() {
      override = debugPatchbaySemanticsOwnerSource;
      return true;
    }());
    if (override != null) return override!();
    SemanticsOwner? current;
    for (final RenderView view in RendererBinding.instance.renderViews) {
      final SemanticsOwner? candidate = view.owner?.semanticsOwner;
      if (candidate?.rootSemanticsNode != null) {
        current = candidate;
        break;
      }
      current ??= candidate;
    }
    return current ?? RendererBinding.instance.rootPipelineOwner.semanticsOwner;
  }

  void _onSemanticsChanged() => _treeRevision += 1;

  PatchbaySemanticsSnapshot _buildSnapshot(
    SemanticsNode root, {
    required int maxDepth,
    required int maxNodes,
  }) {
    final List<PatchbaySemanticsNodeWire> nodes = <PatchbaySemanticsNodeWire>[];
    final Set<int> observedIds = <int>{};
    var truncated = false;

    void visit(SemanticsNode node, int? parentId, int depth) {
      if (nodes.length >= maxNodes || depth > maxDepth) {
        truncated = true;
        return;
      }
      observedIds.add(node.id);
      final PatchbaySemanticsEntry entry = observe(node);
      final SemanticsData data = node.getSemanticsData();
      final List<int> childIds = <int>[];
      node.visitChildren((SemanticsNode child) {
        childIds.add(child.id);
        return true;
      });
      nodes.add(
        _nodeWire(
          node,
          entry.generation,
          data,
          parentId: parentId,
          depth: depth,
          childIds: childIds,
        ),
      );
      if (depth == maxDepth && childIds.isNotEmpty) {
        truncated = true;
        return;
      }
      node.visitChildren((SemanticsNode child) {
        if (nodes.length >= maxNodes) {
          truncated = true;
          return false;
        }
        visit(child, node.id, depth + 1);
        return true;
      });
    }

    visit(root, null, 0);
    _entries.removeWhere((int id, _) => !observedIds.contains(id));
    return PatchbaySemanticsSnapshot(
      rootNodeId: root.id,
      nodes: nodes,
      truncated: truncated,
    );
  }

  PatchbaySemanticsEntry observe(SemanticsNode node) {
    final PatchbaySemanticsEntry? existing = _entries[node.id];
    if (existing != null && identical(existing.node.target, node)) {
      return existing;
    }
    final PatchbaySemanticsEntry next = PatchbaySemanticsEntry(
      WeakReference<SemanticsNode>(node),
      ++_nextGeneration,
    );
    _entries[node.id] = next;
    return next;
  }

  static PatchbaySemanticsNodeWire _nodeWire(
    SemanticsNode node,
    int generation,
    SemanticsData data, {
    required int? parentId,
    required int depth,
    required List<int> childIds,
  }) {
    final bool obscured = data.flagsCollection.isObscured;
    final List<String> flags = data.flagsCollection.toStrings()..sort();
    final List<String> actions = <String>[
      for (final PatchbaySemanticsAction action
          in PatchbaySemanticsAction.values)
        if (data.hasAction(action.flutterAction)) action.name,
    ]..sort();
    return PatchbaySemanticsNodeWire(
      nodeId: node.id,
      generation: generation,
      parentNodeId: parentId,
      depth: depth,
      identifier: data.identifier,
      label: data.label,
      value: obscured ? null : data.value,
      valueRedacted: obscured ? true : null,
      hint: data.hint.isEmpty ? null : data.hint,
      tooltip: data.tooltip.isEmpty ? null : data.tooltip,
      flags: flags,
      actions: actions,
      invisible: node.isInvisible,
      userActionsBlocked: node.areUserActionsBlocked,
      rect: PatchbaySemanticsRectWire(
        left: data.rect.left,
        top: data.rect.top,
        width: data.rect.width,
        height: data.rect.height,
      ),
      rectCoordinateSpace: 'semanticsNodeLocal',
      transformToParent: data.transform?.storage.toList(growable: false),
      scrollPosition: data.scrollPosition,
      scrollExtentMin: data.scrollPosition == null
          ? null
          : data.scrollExtentMin,
      scrollExtentMax: data.scrollPosition == null
          ? null
          : data.scrollExtentMax,
      platformViewId: data.platformViewId,
      children: childIds,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ownerState = _OwnerState.disposed;
    _ownerFlight = null;
    _owner?.removeListener(_onSemanticsChanged);
    _owner = null;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _entries.clear();
  }
}
