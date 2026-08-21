import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

import '../lifecycle.dart';
import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_models.dart';
import 'gesture_models.dart';

/// Identifier-anchored synthetic pointer gestures for debug builds.
final class PatchbayGestureBridge {
  PatchbayGestureBridge({
    required PatchbayGateEvaluator gates,
    required PatchbaySemanticsBridge semantics,
    PatchbayGesturePolicy? policy,
    PatchbayPointerEventDispatcher? pointerDispatcher,
    PatchbayGestureDelay? delay,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _gates = gates,
       _semantics = semantics,
       _policy = policy,
       _dispatchPointer =
           pointerDispatcher ??
           ((PointerEvent event) {
             GestureBinding.instance.handlePointerEvent(event);
           }),
       _delay = delay ?? Future<void>.delayed,
       _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _newRequestId = newRequestId ?? PatchbaySemanticsBridge.defaultRequestId;

  static const int maxDurationMs = 30000;
  static const int maxPathPoints = 64;
  static const double maxVelocity = 20;
  static int _nextPointer = 1000;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsBridge _semantics;
  final PatchbayGesturePolicy? _policy;
  final PatchbayPointerEventDispatcher _dispatchPointer;
  final PatchbayGestureDelay _delay;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final String Function() _newRequestId;

  bool get enabled => !kReleaseMode && _policy != null;

  Future<PatchbayInvocation> pressHold({
    required String identifier,
    required int generation,
    required Map<String, Object?> start,
    int durationMs = 500,
    String? requestId,
  }) {
    try {
      return _run(
        identifier: identifier,
        generation: generation,
        start: _point(start),
        durationMs: durationMs,
        kind: PatchbayGestureKind.pressHold,
        requestId: requestId,
      );
    } on FormatException {
      return Future<PatchbayInvocation>.value(
        _rejected(requestId ?? _newRequestId(), 'invalidUiArguments'),
      );
    }
  }

  Future<PatchbayInvocation> drag({
    required String identifier,
    required int generation,
    required Map<String, Object?> start,
    required List<Object?> path,
    int durationMs = 300,
    String? requestId,
  }) {
    try {
      return _run(
        identifier: identifier,
        generation: generation,
        start: _point(start),
        durationMs: durationMs,
        kind: PatchbayGestureKind.drag,
        path: _path(path, durationMs),
        requestId: requestId,
      );
    } on FormatException {
      return Future<PatchbayInvocation>.value(
        _rejected(requestId ?? _newRequestId(), 'invalidUiArguments'),
      );
    }
  }

  Future<PatchbayInvocation> fling({
    required String identifier,
    required int generation,
    required Map<String, Object?> start,
    required Map<String, Object?> velocity,
    int durationMs = 100,
    String? requestId,
  }) {
    try {
      return _run(
        identifier: identifier,
        generation: generation,
        start: _point(start),
        durationMs: durationMs,
        kind: PatchbayGestureKind.fling,
        velocity: _velocity(velocity),
        requestId: requestId,
      );
    } on FormatException {
      return Future<PatchbayInvocation>.value(
        _rejected(requestId ?? _newRequestId(), 'invalidUiArguments'),
      );
    }
  }

  Future<PatchbayInvocation> _run({
    required String identifier,
    required int generation,
    required GesturePoint start,
    required int durationMs,
    required PatchbayGestureKind kind,
    List<GesturePathPoint> path = const <GesturePathPoint>[],
    GesturePoint? velocity,
    String? requestId,
  }) async {
    final String id = requestId ?? _newRequestId();
    if (identifier.isEmpty || generation < 0) {
      return _rejected(id, 'invalidUiArguments');
    }
    if (!_inBounds(start) || path.any((point) => !_inBounds(point.point))) {
      return _rejected(id, 'uiGesturePointOutOfBounds');
    }
    if (durationMs < 1 || durationMs > maxDurationMs) {
      return _rejected(id, 'uiGestureBudgetExceeded');
    }
    if (kind == PatchbayGestureKind.drag &&
        (path.length < 2 || path.length > maxPathPoints)) {
      return _rejected(id, 'uiGestureBudgetExceeded');
    }
    if (velocity case final GesturePoint value) {
      final double magnitude = math.sqrt(value.x * value.x + value.y * value.y);
      if (magnitude <= 0 || magnitude > maxVelocity) {
        return _rejected(id, 'uiGestureBudgetExceeded');
      }
    }
    final PatchbayGesturePolicy? policy = _policy;
    if (policy == null) return _rejected(id, 'uiGesturesDisabled');
    if (!_isAppResumed()) return _lifecycleRejected(id);
    GestureTargetResolution target = await _resolveTarget(identifier);
    if (!target.resolved) return _targetRejected(id, target);
    final PatchbayGateRejection? baseGate = await _gates.evaluate(
      const <String>{},
    );
    if (baseGate != null) return _gateRejected(id, baseGate);
    if (!_isAppResumed()) return _lifecycleRejected(id);
    final PatchbayGestureDecision initial = policy(target.target!, kind);
    final PatchbayInvocation? initialRejection = _decisionRejection(
      id,
      initial,
      durationMs: durationMs,
      pathPoints: path.length,
      velocity: velocity,
    );
    if (initialRejection != null) return initialRejection;
    final PatchbayGateRejection? gate = await _gates.evaluate(initial.gateIds);
    if (gate != null) return _gateRejected(id, gate);
    if (!_isAppResumed()) return _lifecycleRejected(id);

    target = await _resolveTarget(identifier, expectedGeneration: generation);
    if (!target.resolved) return _targetRejected(id, target);
    final PatchbayGestureDecision finalDecision = policy(target.target!, kind);
    if (!_sameDecision(initial, finalDecision)) {
      return _rejected(id, 'uiGesturePolicyChanged');
    }
    final PatchbayInvocation? finalRejection = _decisionRejection(
      id,
      finalDecision,
      durationMs: durationMs,
      pathPoints: path.length,
      velocity: velocity,
    );
    if (finalRejection != null) return finalRejection;

    final GestureResolution resolution = _resolveGeometry(target);
    if (!resolution.resolved) return _resolutionRejected(id, resolution);
    for (final GesturePoint point in _dispatchedPoints(
      kind: kind,
      start: start,
      path: path,
      velocity: velocity,
      durationMs: durationMs,
    )) {
      if (!resolution.visible(point, resolution.global(point))) {
        return PatchbayInvocation.rejected(
          requestId: id,
          rejection: const PatchbayRejection(
            code: 'uiGestureTargetObscured',
            details: <String, Object?>{'reason': 'hitTestOrClip'},
          ),
        );
      }
    }
    final Rect beforeRect = resolution.globalRect;
    try {
      await _inject(
        resolution,
        kind: kind,
        start: start,
        path: path,
        velocity: velocity,
        durationMs: durationMs,
      );
      final bool layoutChanged = await _layoutChanged(
        identifier,
        generation,
        beforeRect,
      );
      return PatchbayInvocation.accepted(
        requestId: id,
        payload: <String, Object?>{
          'outcome': 'dispatched',
          'source': PatchbayFactSource.uiObserved.name,
          'identifier': identifier,
          'generation': generation,
          'gesture': kind.name,
          'layoutChangedDuringGesture': layoutChanged,
        },
      );
    } catch (error) {
      final bool layoutChanged = await _layoutChanged(
        identifier,
        generation,
        beforeRect,
      );
      return PatchbayInvocation.accepted(
        requestId: id,
        payload: <String, Object?>{
          'outcome': 'failed',
          'source': PatchbayFactSource.uiObserved.name,
          'identifier': identifier,
          'generation': generation,
          'gesture': kind.name,
          'failureType': error.runtimeType.toString(),
          'layoutChangedDuringGesture': layoutChanged,
        },
      );
    }
  }

  Future<void> _inject(
    GestureResolution resolution, {
    required PatchbayGestureKind kind,
    required GesturePoint start,
    required List<GesturePathPoint> path,
    required GesturePoint? velocity,
    required int durationMs,
  }) async {
    final int pointer = ++_nextPointer;
    final Offset globalStart = resolution.global(start);
    var downDispatched = false;
    var endPosition = globalStart;
    try {
      _dispatchPointer(
        PointerDownEvent(
          pointer: pointer,
          position: globalStart,
          viewId: resolution.viewId,
          kind: PointerDeviceKind.touch,
        ),
      );
      downDispatched = true;
      switch (kind) {
        case PatchbayGestureKind.pressHold:
          await _delay(Duration(milliseconds: durationMs));
          break;
        case PatchbayGestureKind.drag:
          var elapsed = 0;
          for (final GesturePathPoint point in path) {
            final int next = point.timeMs;
            await _delay(Duration(milliseconds: next - elapsed));
            elapsed = next;
            final Offset nextPosition = resolution.global(point.point);
            _dispatchPointer(
              PointerMoveEvent(
                timeStamp: Duration(milliseconds: elapsed),
                pointer: pointer,
                position: nextPosition,
                delta: nextPosition - endPosition,
                viewId: resolution.viewId,
                kind: PointerDeviceKind.touch,
              ),
            );
            endPosition = nextPosition;
          }
          if (elapsed < durationMs) {
            await _delay(Duration(milliseconds: durationMs - elapsed));
          }
          break;
        case PatchbayGestureKind.fling:
          final GesturePoint end = _flingEnd(start, velocity!, durationMs);
          await _delay(Duration(milliseconds: durationMs));
          endPosition = resolution.global(end);
          _dispatchPointer(
            PointerMoveEvent(
              timeStamp: Duration(milliseconds: durationMs),
              pointer: pointer,
              position: endPosition,
              delta: endPosition - globalStart,
              viewId: resolution.viewId,
              kind: PointerDeviceKind.touch,
            ),
          );
          break;
      }
      _dispatchPointer(
        PointerUpEvent(
          timeStamp: Duration(milliseconds: durationMs),
          pointer: pointer,
          position: endPosition,
          viewId: resolution.viewId,
          kind: PointerDeviceKind.touch,
        ),
      );
    } catch (_) {
      if (downDispatched) {
        try {
          _dispatchPointer(
            PointerCancelEvent(
              pointer: pointer,
              position: endPosition,
              viewId: resolution.viewId,
              kind: PointerDeviceKind.touch,
            ),
          );
        } catch (_) {
          // Preserve the original injection error in the accepted terminal.
        }
      }
      rethrow;
    }
  }

  Future<GestureTargetResolution> _resolveTarget(
    String identifier, {
    int? expectedGeneration,
  }) async {
    final SemanticsOwner? owner = await _semantics.ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return const GestureTargetResolution.rejected('uiTargetNotFound');
    }
    final List<SemanticsNode> matches = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (node.getSemanticsData().identifier == identifier) matches.add(node);
      node.visitChildren((SemanticsNode child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    if (matches.isEmpty) {
      return const GestureTargetResolution.rejected('uiTargetNotFound');
    }
    if (matches.length != 1) {
      return const GestureTargetResolution.rejected('uiTargetAmbiguous');
    }
    final SemanticsNode node = matches.single;
    final PatchbaySemanticsEntry entry = _semantics.observe(node);
    if (expectedGeneration != null && entry.generation != expectedGeneration) {
      return GestureTargetResolution.rejected(
        'uiGenerationStale',
        details: <String, Object?>{'currentGeneration': entry.generation},
      );
    }
    return GestureTargetResolution.resolved(
      owner: owner,
      node: node,
      target: PatchbayGestureTarget(
        nodeId: node.id,
        generation: entry.generation,
        identifier: identifier,
        flags: Set<String>.unmodifiable(
          node.getSemanticsData().flagsCollection.toStrings(),
        ),
      ),
    );
  }

  GestureResolution _resolveGeometry(GestureTargetResolution target) {
    final SemanticsNode node = target.node!;
    if (node.isInvisible || node.areUserActionsBlocked) {
      return const GestureResolution.rejected('uiGestureTargetObscured');
    }
    final RenderView? view = RendererBinding.instance.renderViews
        .cast<RenderView?>()
        .firstWhere(
          (RenderView? candidate) =>
              identical(candidate?.owner?.semanticsOwner, target.owner),
          orElse: () => null,
        );
    if (view == null) {
      return const GestureResolution.rejected(
        'uiGestureTargetObscured',
        details: <String, Object?>{'reason': 'viewUnavailable'},
      );
    }
    final RenderObject? anchor = _semanticRenderObject(view, node);
    if (anchor == null) {
      return const GestureResolution.rejected(
        'uiGestureTargetObscured',
        details: <String, Object?>{'reason': 'renderAnchorUnavailable'},
      );
    }
    final double devicePixelRatio = view.flutterView.devicePixelRatio;
    final Matrix4 transform = Matrix4.diagonal3Values(
      1 / devicePixelRatio,
      1 / devicePixelRatio,
      1,
    )..multiply(_transformToRoot(node));
    final Rect globalRect = MatrixUtils.transformRect(transform, node.rect);
    if (globalRect.isEmpty || !globalRect.isFinite) {
      return const GestureResolution.rejected(
        'uiGestureTargetObscured',
        details: <String, Object?>{'reason': 'emptyBounds'},
      );
    }
    return GestureResolution.resolved(
      node: node,
      target: target.target!,
      transform: transform,
      globalRect: globalRect,
      anchor: anchor,
      viewId: view.flutterView.viewId,
    );
  }

  Future<bool> _layoutChanged(
    String identifier,
    int generation,
    Rect beforeRect,
  ) async {
    final GestureTargetResolution target = await _resolveTarget(
      identifier,
      expectedGeneration: generation,
    );
    if (!target.resolved) return true;
    final GestureResolution geometry = _resolveGeometry(target);
    return !geometry.resolved || geometry.globalRect != beforeRect;
  }

  static RenderObject? _semanticRenderObject(
    RenderObject root,
    SemanticsNode node,
  ) {
    for (
      SemanticsNode? candidate = node;
      candidate != null;
      candidate = candidate.parent
    ) {
      RenderObject? match;
      void visit(RenderObject renderObject) {
        if (match != null) return;
        if (identical(renderObject.debugSemantics, candidate)) {
          match = renderObject;
          return;
        }
        renderObject.visitChildren(visit);
      }

      visit(root);
      if (match != null) return match;
    }
    return null;
  }

  static Matrix4 _transformToRoot(SemanticsNode node) {
    var result = Matrix4.identity();
    for (
      SemanticsNode? current = node;
      current != null;
      current = current.parent
    ) {
      if (current.transform case final Matrix4 transform) {
        result = Matrix4.copy(transform)..multiply(result);
      }
    }
    return result;
  }

  PatchbayInvocation? _decisionRejection(
    String requestId,
    PatchbayGestureDecision decision, {
    required int durationMs,
    required int pathPoints,
    required GesturePoint? velocity,
  }) {
    if (!decision.allowed) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: decision.rejectionCode!,
          notice: decision.rejectionNotice,
        ),
      );
    }
    final double speed = velocity == null
        ? 0
        : math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
    if (decision.maxDurationMs < 1 ||
        decision.maxDurationMs > maxDurationMs ||
        decision.maxPathPoints < 2 ||
        decision.maxPathPoints > maxPathPoints ||
        decision.maxVelocity <= 0 ||
        decision.maxVelocity > maxVelocity ||
        durationMs > decision.maxDurationMs ||
        pathPoints > decision.maxPathPoints ||
        speed > decision.maxVelocity) {
      return _rejected(requestId, 'uiGestureBudgetExceeded');
    }
    return null;
  }

  static bool _sameDecision(
    PatchbayGestureDecision left,
    PatchbayGestureDecision right,
  ) =>
      left.allowed == right.allowed &&
      left.rejectionCode == right.rejectionCode &&
      left.rejectionNotice == right.rejectionNotice &&
      setEquals(left.gateIds, right.gateIds) &&
      left.maxDurationMs == right.maxDurationMs &&
      left.maxPathPoints == right.maxPathPoints &&
      left.maxVelocity == right.maxVelocity;

  static PatchbayInvocation _rejected(String id, String code) =>
      PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(code: code),
      );

  static PatchbayInvocation _resolutionRejected(
    String id,
    GestureResolution resolution,
  ) => PatchbayInvocation.rejected(
    requestId: id,
    rejection: PatchbayRejection(
      code: resolution.code!,
      details: resolution.details,
    ),
  );

  static PatchbayInvocation _targetRejected(
    String id,
    GestureTargetResolution target,
  ) => PatchbayInvocation.rejected(
    requestId: id,
    rejection: PatchbayRejection(code: target.code!, details: target.details),
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

  PatchbayInvocation _lifecycleRejected(String id) =>
      PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: 'uiLifecycleNotResumed',
          details: patchbayLifecycleDetails(_lifecycleState),
        ),
      );

  static GesturePoint _point(Map<String, Object?> value) {
    final Object? x = value['x'];
    final Object? y = value['y'];
    if (value.length != 2 || x is! num || y is! num) {
      throw const FormatException('gesture point must contain numeric x/y');
    }
    return GesturePoint(x.toDouble(), y.toDouble());
  }

  static List<GesturePathPoint> _path(List<Object?> values, int durationMs) {
    final List<GesturePathPoint> result = <GesturePathPoint>[];
    var prior = -1;
    for (var index = 0; index < values.length; index += 1) {
      final Object? raw = values[index];
      if (raw is! Map || raw.keys.any((Object? key) => key is! String)) {
        throw const FormatException('gesture path entries must be objects');
      }
      final Map<String, Object?> map = Map<String, Object?>.from(raw);
      final int time = switch (map['timeMs']) {
        final int value => value,
        null => ((index + 1) * durationMs / values.length).round(),
        _ => throw const FormatException('gesture path timeMs must be integer'),
      };
      if (time < 0 || time > durationMs || time < prior) {
        throw const FormatException('gesture path timeMs must be monotonic');
      }
      prior = time;
      result.add(
        GesturePathPoint(
          _point(<String, Object?>{'x': map['x'], 'y': map['y']}),
          time,
        ),
      );
      if (map.keys.any(
        (String key) => key != 'x' && key != 'y' && key != 'timeMs',
      )) {
        throw const FormatException('gesture path entry has unexpected key');
      }
    }
    return result;
  }

  static GesturePoint _velocity(Map<String, Object?> value) {
    final GesturePoint result = _point(value);
    if (!result.x.isFinite || !result.y.isFinite) {
      throw const FormatException('gesture velocity must be finite');
    }
    return result;
  }

  static List<GesturePoint> _dispatchedPoints({
    required PatchbayGestureKind kind,
    required GesturePoint start,
    required List<GesturePathPoint> path,
    required GesturePoint? velocity,
    required int durationMs,
  }) => switch (kind) {
    PatchbayGestureKind.pressHold => <GesturePoint>[start],
    PatchbayGestureKind.drag => <GesturePoint>[
      start,
      for (final GesturePathPoint point in path) point.point,
    ],
    PatchbayGestureKind.fling => <GesturePoint>[
      start,
      _flingEnd(start, velocity!, durationMs),
    ],
  };

  static GesturePoint _flingEnd(
    GesturePoint start,
    GesturePoint velocity,
    int durationMs,
  ) {
    final double seconds = durationMs / 1000;
    return GesturePoint(
      (start.x + velocity.x * seconds).clamp(0, 1).toDouble(),
      (start.y + velocity.y * seconds).clamp(0, 1).toDouble(),
    );
  }

  static bool _inBounds(GesturePoint point) =>
      point.x.isFinite &&
      point.y.isFinite &&
      point.x >= 0 &&
      point.x <= 1 &&
      point.y >= 0 &&
      point.y <= 1;
}
