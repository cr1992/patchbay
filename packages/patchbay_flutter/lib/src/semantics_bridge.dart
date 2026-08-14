import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

import 'lifecycle.dart';

/// Stable Patchbay names for the first supported Flutter semantics actions.
enum PatchbaySemanticsAction {
  tap,
  longPress,
  focus,
  dismiss,
  showOnScreen,
  scrollUp,
  scrollDown,
  scrollLeft,
  scrollRight,
  increase,
  decrease,
  expand,
  collapse,
  setText;

  SemanticsAction get flutterAction => switch (this) {
    PatchbaySemanticsAction.tap => SemanticsAction.tap,
    PatchbaySemanticsAction.longPress => SemanticsAction.longPress,
    PatchbaySemanticsAction.focus => SemanticsAction.focus,
    PatchbaySemanticsAction.dismiss => SemanticsAction.dismiss,
    PatchbaySemanticsAction.showOnScreen => SemanticsAction.showOnScreen,
    PatchbaySemanticsAction.scrollUp => SemanticsAction.scrollUp,
    PatchbaySemanticsAction.scrollDown => SemanticsAction.scrollDown,
    PatchbaySemanticsAction.scrollLeft => SemanticsAction.scrollLeft,
    PatchbaySemanticsAction.scrollRight => SemanticsAction.scrollRight,
    PatchbaySemanticsAction.increase => SemanticsAction.increase,
    PatchbaySemanticsAction.decrease => SemanticsAction.decrease,
    PatchbaySemanticsAction.expand => SemanticsAction.expand,
    PatchbaySemanticsAction.collapse => SemanticsAction.collapse,
    PatchbaySemanticsAction.setText => SemanticsAction.setText,
  };

  static PatchbaySemanticsAction? fromWireName(String value) {
    for (final PatchbaySemanticsAction action in values) {
      if (action.name == value) return action;
    }
    return null;
  }
}

/// Read-only target facts supplied to the consumer action policy.
final class PatchbaySemanticsTarget {
  const PatchbaySemanticsTarget({
    required this.nodeId,
    required this.generation,
    required this.identifier,
    required this.label,
    required this.flags,
    required this.actions,
    required this.obscured,
  });

  final int nodeId;
  final int generation;
  final String identifier;
  final String label;
  final Set<String> flags;
  final Set<PatchbaySemanticsAction> actions;
  final bool obscured;
}

/// One currently attached node selected by a stable Semantics identifier.
final class PatchbaySemanticsIdentifierMatch {
  const PatchbaySemanticsIdentifierMatch({
    required this.nodeId,
    required this.generation,
    required this.value,
    required this.obscured,
    required this.invisible,
  });

  final int nodeId;
  final int generation;
  final String value;
  final bool obscured;
  final bool invisible;
}

/// Current result of resolving a Semantics identifier.
final class PatchbaySemanticsIdentifierObservation {
  const PatchbaySemanticsIdentifierObservation({
    required this.treeRevision,
    required this.matches,
  });

  final int treeRevision;
  final List<PatchbaySemanticsIdentifierMatch> matches;
}

/// Consumer-owned decision for one currently observed semantics action.
final class PatchbaySemanticsActionDecision {
  const PatchbaySemanticsActionDecision.allow({
    this.gateIds = const <String>{},
    this.sensitiveInput = false,
  }) : rejectionCode = null,
       rejectionNotice = null;

  const PatchbaySemanticsActionDecision.reject({
    this.rejectionCode = 'uiSemanticsActionDenied',
    this.rejectionNotice,
  }) : gateIds = const <String>{},
       sensitiveInput = false;

  final Set<String> gateIds;
  final bool sensitiveInput;
  final String? rejectionCode;
  final String? rejectionNotice;

  bool get allowed => rejectionCode == null;
}

typedef PatchbaySemanticsActionPolicy =
    PatchbaySemanticsActionDecision Function(
      PatchbaySemanticsTarget target,
      PatchbaySemanticsAction action,
    );

/// Public-API Flutter Semantics observer and action dispatcher.
///
/// A policy is deliberately optional. Without one the tree remains readable,
/// while executable semantics commands stay absent from the host catalog.
final class PatchbaySemanticsBridge {
  PatchbaySemanticsBridge({
    required PatchbayGateEvaluator gates,
    PatchbaySemanticsActionPolicy? actionPolicy,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _gates = gates,
       _actionPolicy = actionPolicy,
       _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _newRequestId = newRequestId ?? _defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsActionPolicy? _actionPolicy;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final String Function() _newRequestId;

  SemanticsHandle? _semanticsHandle;
  SemanticsOwner? _owner;
  final Map<int, _SemanticsEntry> _entries = <int, _SemanticsEntry>{};
  int _nextGeneration = 0;
  int _treeRevision = 0;
  bool _disposed = false;

  static int _nextRequest = 0;
  static String _defaultRequestId() => 'patchbay-semantics-${++_nextRequest}';

  bool get actionsEnabled => _actionPolicy != null;

  /// Resolves a stable Semantics identifier without using labels or paths.
  Future<PatchbaySemanticsIdentifierObservation?> observeIdentifier(
    String identifier,
  ) async {
    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (root == null) return null;
    final List<PatchbaySemanticsIdentifierMatch> matches =
        <PatchbaySemanticsIdentifierMatch>[];

    void visit(SemanticsNode node) {
      final SemanticsData data = node.getSemanticsData();
      if (data.identifier == identifier) {
        final _SemanticsEntry entry = _observe(node);
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
    final SemanticsOwner? owner = await _ensureOwner();
    return owner?.rootSemanticsNode == null ? null : _treeRevision;
  }

  Future<PatchbayInvocation> snapshot({
    int maxDepth = 64,
    int maxNodes = 1000,
    String? requestId,
  }) async {
    final String id = requestId ?? _newRequestId();
    if (maxDepth < 0 || maxNodes < 1 || maxNodes > 10000) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(
          code: 'invalidUiTreeLimits',
          notice:
              'maxDepth must be non-negative and maxNodes must be 1..10000.',
        ),
      );
    }
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(id, gate);
    // A backgrounded engine produces no frames, and building the tree waits for
    // one. Without this the request would never answer at all.
    if (!_isAppResumed()) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: 'uiLifecycleNotResumed',
          details: patchbayLifecycleDetails(_lifecycleState),
        ),
      );
    }

    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnavailable'),
      );
    }

    final _Snapshot snapshot = _buildSnapshot(
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
    // The caller already fenced this target, so there is nothing to pin.
    resolve: (int? _) =>
        _resolve(nodeId: nodeId, generation: generation, action: action),
  );

  /// Resolves a stable Semantics [identifier] and dispatches `tap` in one
  /// admitted request.
  ///
  /// Splitting resolution from dispatch across two round trips makes the
  /// caller carry a `nodeId` that is only meaningful inside the current
  /// SemanticsOwner, and widens the window in which the tree can move under
  /// it. Resolving here removes the round trip without weakening the fence:
  /// the generation observed before the gates is pinned and re-checked after
  /// them, so a remount during an awaited gate still fails closed.
  ///
  /// [expectedGeneration] is the optional caller-side fence. Supplying it
  /// rejects a target that already moved before this request was admitted;
  /// omitting it only accepts whatever is mounted right now, which is why the
  /// pinned re-check after the gates is not optional.
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
      resolve: (int? pinnedGeneration) => _resolveIdentifier(
        identifier: identifier,
        expectedGeneration: pinnedGeneration ?? expectedGeneration,
        action: PatchbaySemanticsAction.tap,
      ),
    );
  }

  /// Shared admission pipeline for every Semantics action.
  ///
  /// [resolve] receives the generation resolved by the first pass, so an
  /// identifier-based resolver can pin the same object across the gates while
  /// a caller-fenced resolver simply ignores it.
  Future<PatchbayInvocation> _dispatch({
    required String requestId,
    required PatchbaySemanticsAction action,
    required Future<_SemanticsResolution> Function(int? pinnedGeneration)
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
    final PatchbayGateRejection? baseGate = await _gates.evaluate(
      const <String>{},
    );
    if (baseGate != null) return _gateRejected(id, baseGate);
    if (!_isAppResumed()) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: 'uiLifecycleNotResumed',
          details: patchbayLifecycleDetails(_lifecycleState),
        ),
      );
    }

    _SemanticsResolution resolution = await resolve(null);
    if (!resolution.resolved) return _resolutionRejected(id, resolution);
    final int pinnedGeneration = resolution.target!.generation;

    PatchbaySemanticsActionDecision decision = policy(
      resolution.target!,
      action,
    );
    if (!decision.allowed) return _policyRejected(id, decision);
    final Set<String> initialGateIds = Set<String>.of(decision.gateIds);
    var sensitive = resolution.target!.obscured || decision.sensitiveInput;
    final bool initialSensitiveInput = decision.sensitiveInput;
    if (action == PatchbaySemanticsAction.setText) {
      if (text == null) {
        return PatchbayInvocation.rejected(
          requestId: id,
          rejection: const PatchbayRejection(code: 'uiSemanticsTextRequired'),
        );
      }
      if (sensitive && !inputWasStdin) {
        return PatchbayInvocation.rejected(
          requestId: id,
          rejection: const PatchbayRejection(
            code: 'sensitiveInputRequiresStdin',
          ),
        );
      }
    } else if (text != null) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnexpectedText'),
      );
    }

    final PatchbayGateRejection? gate = await _gates.evaluate(decision.gateIds);
    if (gate != null) return _gateRejected(id, gate);
    if (!_isAppResumed()) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: 'uiLifecycleNotResumed',
          details: patchbayLifecycleDetails(_lifecycleState),
        ),
      );
    }

    // Both a gate and the consumer policy may observe mutable state. Resolve
    // and decide again so a late continuation cannot target a replacement.
    resolution = await resolve(pinnedGeneration);
    if (!resolution.resolved) return _resolutionRejected(id, resolution);
    decision = policy(resolution.target!, action);
    if (!decision.allowed) return _policyRejected(id, decision);
    if (!setEquals(initialGateIds, decision.gateIds) ||
        initialSensitiveInput != decision.sensitiveInput) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'uiSemanticsPolicyChanged'),
      );
    }
    sensitive = sensitive || resolution.target!.obscured;
    if (action == PatchbaySemanticsAction.setText &&
        sensitive &&
        !inputWasStdin) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: const PatchbayRejection(code: 'sensitiveInputRequiresStdin'),
      );
    }

    final SemanticsOwner owner = resolution.owner!;
    final int nodeId = resolution.target!.nodeId;
    final int generation = resolution.target!.generation;
    final int beforeRevision = _treeRevision;
    try {
      owner.performAction(
        nodeId,
        action.flutterAction,
        action == PatchbaySemanticsAction.setText ? text : null,
      );
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      _refreshOwner();
      return PatchbayInvocation.accepted(
        requestId: id,
        payload: <String, Object?>{
          'outcome': 'dispatched',
          'source': PatchbayFactSource.uiObserved.name,
          'identifier': ?identifier,
          'nodeId': nodeId,
          'generation': generation,
          'action': action.name,
          'beforeTreeRevision': beforeRevision,
          'afterTreeRevision': _treeRevision,
          if (action == PatchbaySemanticsAction.setText)
            if (sensitive) ...<String, Object?>{
              'valueRedacted': true,
              'length': text!.length,
            } else ...<String, Object?>{'length': text!.length},
        },
      );
    } catch (error) {
      return PatchbayInvocation.accepted(
        requestId: id,
        payload: <String, Object?>{
          'outcome': 'failed',
          'source': PatchbayFactSource.uiObserved.name,
          'identifier': ?identifier,
          'nodeId': nodeId,
          'generation': generation,
          'action': action.name,
          'failureType': error.runtimeType.toString(),
        },
      );
    }
  }

  /// Upper bound on the identifiers echoed back in a not-found rejection.
  ///
  /// A rejection has to be actionable, but a full tree dump inside an error is
  /// a second observation surface that never passed the snapshot's own limits.
  static const int _maxReportedIdentifiers = 20;

  /// Resolves one currently mounted node by its stable Semantics identifier.
  ///
  /// Every rejection carries details, because "no" without a reason forces the
  /// caller back into the tree dump this command exists to avoid. Ambiguity is
  /// never broken by tree order: two mounted matches fail closed, exactly as
  /// the registered-target path does.
  Future<_SemanticsResolution> _resolveIdentifier({
    required String identifier,
    required int? expectedGeneration,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return _SemanticsResolution.rejected(
        'uiSemanticsUnavailable',
        details: <String, Object?>{'identifier': identifier},
      );
    }

    final List<SemanticsNode> matches = <SemanticsNode>[];
    final Set<String> mounted = <String>{};
    void visit(SemanticsNode node) {
      final SemanticsData data = node.getSemanticsData();
      if (data.identifier.isNotEmpty) mounted.add(data.identifier);
      if (data.identifier == identifier) matches.add(node);
      node.visitChildren((SemanticsNode child) {
        visit(child);
        return true;
      });
    }

    visit(root);

    if (matches.isEmpty) {
      final List<String> reported = mounted.toList()..sort();
      return _SemanticsResolution.rejected(
        'uiSemanticsIdentifierNotFound',
        details: <String, Object?>{
          'identifier': identifier,
          'treeRevision': _treeRevision,
          'matchCount': 0,
          'mountedIdentifierCount': reported.length,
          'mountedIdentifiers': reported
              .take(_maxReportedIdentifiers)
              .toList(growable: false),
          'mountedIdentifiersTruncated':
              reported.length > _maxReportedIdentifiers,
        },
      );
    }
    if (matches.length > 1) {
      return _SemanticsResolution.rejected(
        'uiSemanticsIdentifierAmbiguous',
        details: <String, Object?>{
          'identifier': identifier,
          'treeRevision': _treeRevision,
          'matchCount': matches.length,
          'candidates': <Object?>[
            for (final SemanticsNode node in matches)
              _candidate(node, node.getSemanticsData()),
          ],
        },
      );
    }

    final SemanticsNode node = matches.single;
    final _SemanticsEntry entry = _observe(node);
    if (expectedGeneration != null && entry.generation != expectedGeneration) {
      return _SemanticsResolution.rejected(
        'uiSemanticsGenerationStale',
        details: <String, Object?>{
          'identifier': identifier,
          'nodeId': node.id,
          'expectedGeneration': expectedGeneration,
          'currentGeneration': entry.generation,
        },
      );
    }
    final SemanticsData data = node.getSemanticsData();
    if (node.isInvisible || node.areUserActionsBlocked) {
      return _SemanticsResolution.rejected(
        'uiSemanticsActionBlocked',
        details: _candidate(node, data),
      );
    }
    if (!data.hasAction(action.flutterAction)) {
      return _SemanticsResolution.rejected(
        'uiSemanticsActionUnavailable',
        details: <String, Object?>{
          ..._candidate(node, data),
          'requestedAction': action.name,
        },
      );
    }
    return _SemanticsResolution.resolved(
      owner,
      _target(node, entry.generation, data),
    );
  }

  /// Bounded, redaction-safe description of one identifier match.
  Map<String, Object?> _candidate(SemanticsNode node, SemanticsData data) {
    final bool obscured = data.flagsCollection.isObscured;
    return <String, Object?>{
      'nodeId': node.id,
      'generation': _observe(node).generation,
      if (obscured) 'labelRedacted': true else 'label': data.label,
      'actions': <String>[
        for (final PatchbaySemanticsAction candidate
            in PatchbaySemanticsAction.values)
          if (data.hasAction(candidate.flutterAction)) candidate.name,
      ]..sort(),
      'invisible': node.isInvisible,
      'userActionsBlocked': node.areUserActionsBlocked,
    };
  }

  Future<_SemanticsResolution> _resolve({
    required int nodeId,
    required int generation,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return const _SemanticsResolution.rejected('uiSemanticsUnavailable');
    }
    final SemanticsNode? node = _findNode(root, nodeId);
    if (node == null) {
      return const _SemanticsResolution.rejected('uiSemanticsNodeNotFound');
    }
    final _SemanticsEntry? entry = _entries[nodeId];
    if (entry == null || entry.node.target == null) {
      return const _SemanticsResolution.rejected('uiSemanticsNodeNotObserved');
    }
    if (entry.generation != generation || !identical(entry.node.target, node)) {
      return _SemanticsResolution.rejected(
        'uiSemanticsGenerationStale',
        details: <String, Object?>{'currentGeneration': entry.generation},
      );
    }
    final SemanticsData data = node.getSemanticsData();
    if (node.isInvisible || node.areUserActionsBlocked) {
      return const _SemanticsResolution.rejected('uiSemanticsActionBlocked');
    }
    if (!data.hasAction(action.flutterAction)) {
      return const _SemanticsResolution.rejected(
        'uiSemanticsActionUnavailable',
      );
    }
    return _SemanticsResolution.resolved(
      owner,
      _target(node, entry.generation, data),
    );
  }

  Future<SemanticsOwner?> _ensureOwner({
    Duration frameTimeout = const Duration(seconds: 2),
  }) async {
    if (_disposed) return null;
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
    SemanticsOwner? owner;
    // Creating the first handle marks semantics dirty. One frame may create
    // the owner and the next populate its root, depending on call timing.
    for (var attempt = 0; attempt < 3; attempt += 1) {
      SchedulerBinding.instance.scheduleFrame();
      try {
        await SchedulerBinding.instance.endOfFrame.timeout(frameTimeout);
      } on TimeoutException {
        // The engine can stop presenting between the lifecycle check and here.
        // Report what already exists rather than waiting for a frame that is
        // not coming; the caller turns a null owner into a typed rejection.
        return _refreshOwner();
      }
      owner = _refreshOwner();
      if (owner?.rootSemanticsNode != null) return owner;
    }
    return owner;
  }

  SemanticsOwner? _refreshOwner() {
    // Each RenderView owns the semantics tree that is sent to its FlutterView.
    // The root PipelineOwner is only the parent of those per-view owners and
    // does not necessarily contain node 0 (notably in widget tests).
    SemanticsOwner? current;
    for (final RenderView view in RendererBinding.instance.renderViews) {
      final SemanticsOwner? candidate = view.owner?.semanticsOwner;
      if (candidate?.rootSemanticsNode != null) {
        current = candidate;
        break;
      }
      current ??= candidate;
    }
    current ??= RendererBinding.instance.rootPipelineOwner.semanticsOwner;
    if (identical(current, _owner)) return current;
    _owner?.removeListener(_onSemanticsChanged);
    _owner = current;
    _owner?.addListener(_onSemanticsChanged);
    _treeRevision += 1;
    _entries.clear();
    return current;
  }

  void _onSemanticsChanged() => _treeRevision += 1;

  _Snapshot _buildSnapshot(
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
      final _SemanticsEntry entry = _observe(node);
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
    return _Snapshot(rootNodeId: root.id, nodes: nodes, truncated: truncated);
  }

  _SemanticsEntry _observe(SemanticsNode node) {
    final _SemanticsEntry? existing = _entries[node.id];
    if (existing != null && identical(existing.node.target, node)) {
      return existing;
    }
    final _SemanticsEntry next = _SemanticsEntry(
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

  static PatchbaySemanticsTarget _target(
    SemanticsNode node,
    int generation,
    SemanticsData data,
  ) => PatchbaySemanticsTarget(
    nodeId: node.id,
    generation: generation,
    identifier: data.identifier,
    label: data.label,
    flags: Set<String>.unmodifiable(data.flagsCollection.toStrings()),
    actions:
        Set<PatchbaySemanticsAction>.unmodifiable(<PatchbaySemanticsAction>{
          for (final PatchbaySemanticsAction action
              in PatchbaySemanticsAction.values)
            if (data.hasAction(action.flutterAction)) action,
        }),
    obscured: data.flagsCollection.isObscured,
  );

  static SemanticsNode? _findNode(SemanticsNode root, int id) {
    if (root.id == id) return root;
    SemanticsNode? found;
    root.visitChildren((SemanticsNode child) {
      found = _findNode(child, id);
      return found == null;
    });
    return found;
  }

  static PatchbayInvocation _gateRejected(
    String requestId,
    PatchbayGateRejection gate,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: gate.code,
      notice: gate.notice,
      details: <String, Object?>{'gateId': gate.gateId},
    ),
  );

  static PatchbayInvocation _resolutionRejected(
    String requestId,
    _SemanticsResolution resolution,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: resolution.code!,
      details: resolution.details,
    ),
  );

  static PatchbayInvocation _policyRejected(
    String requestId,
    PatchbaySemanticsActionDecision decision,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: decision.rejectionCode!,
      notice: decision.rejectionNotice,
    ),
  );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner?.removeListener(_onSemanticsChanged);
    _owner = null;
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _entries.clear();
  }
}

final class _SemanticsEntry {
  const _SemanticsEntry(this.node, this.generation);

  final WeakReference<SemanticsNode> node;
  final int generation;
}

final class _Snapshot {
  const _Snapshot({
    required this.rootNodeId,
    required this.nodes,
    required this.truncated,
  });

  final int rootNodeId;
  final List<PatchbaySemanticsNodeWire> nodes;
  final bool truncated;

  Map<String, Object?> toJson(int revision) => PatchbaySemanticsSnapshotWire(
    outcome: 'observed',
    source: PatchbayFactSourceWire.uiObserved,
    treeRevision: revision,
    rootNodeId: rootNodeId,
    truncated: truncated,
    nodeCount: nodes.length,
    nodes: nodes,
  ).toJson();
}

final class _SemanticsResolution {
  const _SemanticsResolution.resolved(this.owner, this.target)
    : code = null,
      details = const <String, Object?>{};

  const _SemanticsResolution.rejected(
    this.code, {
    this.details = const <String, Object?>{},
  }) : owner = null,
       target = null;

  final SemanticsOwner? owner;
  final PatchbaySemanticsTarget? target;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => owner != null && target != null;
}
