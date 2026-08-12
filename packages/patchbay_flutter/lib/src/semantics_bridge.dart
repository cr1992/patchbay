import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

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
    String Function()? newRequestId,
  }) : _gates = gates,
       _actionPolicy = actionPolicy,
       _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _newRequestId = newRequestId ?? _defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsActionPolicy? _actionPolicy;
  final bool Function() _isAppResumed;
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

  Future<PatchbayInvocation> snapshot({
    int maxDepth = 64,
    int maxNodes = 1000,
  }) async {
    final String requestId = _newRequestId();
    if (maxDepth < 0 || maxNodes < 1 || maxNodes > 10000) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(
          code: 'invalidUiTreeLimits',
          notice:
              'maxDepth must be non-negative and maxNodes must be 1..10000.',
        ),
      );
    }
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(requestId, gate);

    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnavailable'),
      );
    }

    final _Snapshot snapshot = _buildSnapshot(
      root,
      maxDepth: maxDepth,
      maxNodes: maxNodes,
    );
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: snapshot.toJson(_treeRevision),
    );
  }

  Future<PatchbayInvocation> invoke({
    required int nodeId,
    required int generation,
    required PatchbaySemanticsAction action,
    String? text,
    bool inputWasStdin = false,
  }) async {
    final String requestId = _newRequestId();
    final PatchbaySemanticsActionPolicy? policy = _actionPolicy;
    if (policy == null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsActionsDisabled'),
      );
    }
    final PatchbayGateRejection? baseGate = await _gates.evaluate(
      const <String>{},
    );
    if (baseGate != null) return _gateRejected(requestId, baseGate);
    if (!_isAppResumed()) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiLifecycleNotResumed'),
      );
    }

    _SemanticsResolution resolution = await _resolve(
      nodeId: nodeId,
      generation: generation,
      action: action,
    );
    if (!resolution.resolved) return _resolutionRejected(requestId, resolution);

    PatchbaySemanticsActionDecision decision = policy(
      resolution.target!,
      action,
    );
    if (!decision.allowed) return _policyRejected(requestId, decision);
    final Set<String> initialGateIds = Set<String>.of(decision.gateIds);
    final bool sensitive =
        resolution.target!.obscured || decision.sensitiveInput;
    final bool initialSensitiveInput = decision.sensitiveInput;
    if (action == PatchbaySemanticsAction.setText) {
      if (text == null) {
        return PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(code: 'uiSemanticsTextRequired'),
        );
      }
      if (sensitive && !inputWasStdin) {
        return PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(
            code: 'sensitiveInputRequiresStdin',
          ),
        );
      }
    } else if (text != null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnexpectedText'),
      );
    }

    final PatchbayGateRejection? gate = await _gates.evaluate(decision.gateIds);
    if (gate != null) return _gateRejected(requestId, gate);

    // Both a gate and the consumer policy may observe mutable state. Resolve
    // and decide again so a late continuation cannot target a replacement.
    resolution = await _resolve(
      nodeId: nodeId,
      generation: generation,
      action: action,
    );
    if (!resolution.resolved) return _resolutionRejected(requestId, resolution);
    decision = policy(resolution.target!, action);
    if (!decision.allowed) return _policyRejected(requestId, decision);
    if (!setEquals(initialGateIds, decision.gateIds) ||
        initialSensitiveInput != decision.sensitiveInput) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsPolicyChanged'),
      );
    }

    final SemanticsOwner owner = resolution.owner!;
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
        requestId: requestId,
        payload: <String, Object?>{
          'outcome': 'dispatched',
          'source': PatchbayFactSource.uiObserved.name,
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
        requestId: requestId,
        payload: <String, Object?>{
          'outcome': 'failed',
          'source': PatchbayFactSource.uiObserved.name,
          'nodeId': nodeId,
          'generation': generation,
          'action': action.name,
          'failureType': error.runtimeType.toString(),
        },
      );
    }
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

  Future<SemanticsOwner?> _ensureOwner() async {
    if (_disposed) return null;
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
    SemanticsOwner? owner;
    // Creating the first handle marks semantics dirty. One frame may create
    // the owner and the next populate its root, depending on call timing.
    for (var attempt = 0; attempt < 3; attempt += 1) {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
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
    final List<Map<String, Object?>> nodes = <Map<String, Object?>>[];
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
        _nodeJson(
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

  static Map<String, Object?> _nodeJson(
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
    return <String, Object?>{
      'nodeId': node.id,
      'generation': generation,
      'parentNodeId': parentId,
      'depth': depth,
      'identifier': data.identifier,
      'label': data.label,
      if (obscured) 'valueRedacted': true else 'value': data.value,
      if (data.hint.isNotEmpty) 'hint': data.hint,
      if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
      'flags': flags,
      'actions': actions,
      'invisible': node.isInvisible,
      'userActionsBlocked': node.areUserActionsBlocked,
      'rect': <String, Object?>{
        'left': data.rect.left,
        'top': data.rect.top,
        'width': data.rect.width,
        'height': data.rect.height,
      },
      'rectCoordinateSpace': 'semanticsNodeLocal',
      if (data.transform != null)
        'transformToParent': data.transform!.storage.toList(growable: false),
      if (data.scrollPosition != null) ...<String, Object?>{
        'scrollPosition': data.scrollPosition,
        'scrollExtentMin': data.scrollExtentMin,
        'scrollExtentMax': data.scrollExtentMax,
      },
      if (data.platformViewId != null) 'platformViewId': data.platformViewId,
      'children': childIds,
    };
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
  final List<Map<String, Object?>> nodes;
  final bool truncated;

  Map<String, Object?> toJson(int revision) => <String, Object?>{
    'outcome': 'observed',
    'source': PatchbayFactSource.uiObserved.name,
    'treeRevision': revision,
    'rootNodeId': rootNodeId,
    'truncated': truncated,
    'nodeCount': nodes.length,
    'nodes': nodes,
  };
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
