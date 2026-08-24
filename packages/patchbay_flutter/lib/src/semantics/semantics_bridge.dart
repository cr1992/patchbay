import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

import '../lifecycle.dart';
import 'semantics_models.dart';

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
       _newRequestId = newRequestId ?? defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsActionPolicy? _actionPolicy;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final String Function() _newRequestId;

  SemanticsHandle? _semanticsHandle;
  SemanticsOwner? _owner;
  final Map<int, PatchbaySemanticsEntry> _entries =
      <int, PatchbaySemanticsEntry>{};
  int _nextGeneration = 0;
  int _treeRevision = 0;
  bool _disposed = false;

  static int _nextRequest = 0;
  static String defaultRequestId() => 'patchbay-semantics-${++_nextRequest}';

  bool get actionsEnabled => _actionPolicy != null;

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
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
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
    resolve: (int? _) =>
        _resolve(nodeId: nodeId, generation: generation, action: action),
  );

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
      resolve: (int? pinnedGeneration) => _resolveIdentifier(
        identifier: identifier,
        expectedGeneration: pinnedGeneration ?? expectedGeneration,
        action: PatchbaySemanticsAction.tap,
      ),
    );
  }

  /// Shared admission pipeline for every Semantics action.
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

    PatchbaySemanticsResolution resolution = await resolve(null);
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

  static const int _maxReportedIdentifiers = 20;

  Future<PatchbaySemanticsResolution> _resolveIdentifier({
    required String identifier,
    required int? expectedGeneration,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return PatchbaySemanticsResolution.rejected(
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
      return PatchbaySemanticsResolution.rejected(
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
      return PatchbaySemanticsResolution.rejected(
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
    final PatchbaySemanticsEntry entry = observe(node);
    if (expectedGeneration != null && entry.generation != expectedGeneration) {
      return PatchbaySemanticsResolution.rejected(
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
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionBlocked',
        details: _candidate(node, data),
      );
    }
    if (!data.hasAction(action.flutterAction)) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionUnavailable',
        details: <String, Object?>{
          ..._candidate(node, data),
          'requestedAction': action.name,
        },
      );
    }
    return PatchbaySemanticsResolution.resolved(
      owner,
      _target(node, entry.generation, data),
    );
  }

  Map<String, Object?> _candidate(SemanticsNode node, SemanticsData data) {
    final bool obscured = data.flagsCollection.isObscured;
    return <String, Object?>{
      'nodeId': node.id,
      'generation': observe(node).generation,
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

  Future<PatchbaySemanticsResolution> _resolve({
    required int nodeId,
    required int generation,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsUnavailable',
      );
    }
    final SemanticsNode? node = _findNode(root, nodeId);
    if (node == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsNodeNotFound',
      );
    }
    final PatchbaySemanticsEntry? entry = _entries[nodeId];
    if (entry == null || entry.node.target == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsNodeNotObserved',
      );
    }
    if (entry.generation != generation || !identical(entry.node.target, node)) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsGenerationStale',
        details: <String, Object?>{'currentGeneration': entry.generation},
      );
    }
    final SemanticsData data = node.getSemanticsData();
    if (node.isInvisible || node.areUserActionsBlocked) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionBlocked',
      );
    }
    if (!data.hasAction(action.flutterAction)) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionUnavailable',
      );
    }
    return PatchbaySemanticsResolution.resolved(
      owner,
      _target(node, entry.generation, data),
    );
  }

  Future<SemanticsOwner?> ensureOwner({
    Duration frameTimeout = const Duration(seconds: 2),
  }) async {
    if (_disposed) return null;
    _semanticsHandle ??= SemanticsBinding.instance.ensureSemantics();
    SemanticsOwner? owner;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      SchedulerBinding.instance.scheduleFrame();
      try {
        await SchedulerBinding.instance.endOfFrame.timeout(frameTimeout);
      } on TimeoutException {
        return _refreshOwner();
      }
      owner = _refreshOwner();
      if (owner?.rootSemanticsNode != null) return owner;
    }
    return owner;
  }

  SemanticsOwner? _refreshOwner() {
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
    PatchbaySemanticsResolution resolution,
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
