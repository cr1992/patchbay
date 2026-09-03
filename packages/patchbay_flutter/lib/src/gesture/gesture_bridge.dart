import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay_host.dart';

import '../lifecycle.dart';
import '../occlusion/occlusion_probe.dart';
import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_models.dart';
import 'gesture_models.dart';

/// Identifier-anchored synthetic pointer gestures for debug builds.
final class PatchbayGestureBridge {
  PatchbayGestureBridge({
    required this._gates,
    required this._semantics,
    this._policy,
    PatchbayPointerEventDispatcher? pointerDispatcher,
    PatchbayGestureDelay? delay,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _dispatchPointer =
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

  /// tap 的 down→up 间隔。实现细节：不进 wire、CLI 与 payload，调用方与
  /// 接入方都改不了它（DG-050-08 复核改判）。取值远低于框架默认
  /// `kLongPressTimeout`（500 ms），把"被默认长按识别器认走"压到工程余量之下；
  /// 但对接入方自定义的更短阈值 recognizer 不做任何担保——那是指针真实性的
  /// 固有属性。它仍受 policy 的 `maxDurationMs` 预算约束，收紧到 50 以下即
  /// 整体拒绝，不因常数不进 wire 就绕过 policy。
  static const int _tapDownUpDelayMs = 50;
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

  /// 按下即抬起的最短固定序列；要按住用 [pressHold]，语义写在命令名上而不是
  /// 数值里。`start` 缺省即目标中心，与 descriptor 声明的默认一致。
  Future<PatchbayInvocation> tap({
    required String identifier,
    required int generation,
    Map<String, Object?>? start,
    String? requestId,
  }) {
    try {
      return _run(
        identifier: identifier,
        generation: generation,
        start: _point(start ?? const <String, Object?>{'x': 0.5, 'y': 0.5}),
        durationMs: _tapDownUpDelayMs,
        kind: PatchbayGestureKind.tap,
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
    // tap 在第一次 resolve 就核对调用方 generation（与 PB-050-10 对齐）：
    // 内部 pin 防不住"调用方上次观察之后、本次命令开始之前 identifier 已被
    // 新节点复用"那个窗口，只有调用方手里的 generation 能关上它。既有三条
    // 维持只在门后核对，拒绝时机不动。
    GestureTargetResolution target = await _resolveTarget(
      identifier,
      expectedGeneration: kind == PatchbayGestureKind.tap ? generation : null,
    );
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
      if (!resolution.visible(point)) {
        return PatchbayInvocation.rejected(
          requestId: id,
          rejection: const PatchbayRejection(
            code: 'uiGestureTargetObscured',
            details: <String, Object?>{
              'reason': PatchbayOcclusionReason.hitTestOrClip,
            },
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
        // tap 与 pressHold 的序列同构（down → 延时 → up），差别只在延时来源：
        // pressHold 是调用方参数，tap 是 `_tapDownUpDelayMs`（已在入口写进
        // durationMs）。两者都不发 move：任何位移都会进 touch slop 判定。
        case PatchbayGestureKind.pressHold:
        case PatchbayGestureKind.tap:
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
    final PatchbayOcclusionResolution geometry =
        patchbayResolveOcclusionGeometry(owner: target.owner!, node: node);
    if (!geometry.resolved) {
      return GestureResolution.rejected(
        'uiGestureTargetObscured',
        details: <String, Object?>{'reason': geometry.reason},
      );
    }
    return GestureResolution.resolved(
      geometry: geometry.geometry!,
      target: target.target!,
    );
  }

  Future<bool> _layoutChanged(
    String identifier,
    int generation,
    Rect beforeRect,
  ) async {
    // 手势的**自身效果观察**：注入过程中被标脏的布局要先提交，终止比较才有意义。
    //
    // PB-050-07 之前这一帧是 `ensureOwner()` 的副产品；DG-050-05 结论 1 之后
    // probe 不再请帧，于是把它显式化——语义与预算完全照旧（同样一帧、同样最多
    // 等 2 秒、同样不计入 `frameRevision`），只是不再依赖别人的副作用。这与
    // `ui.semantics.action` 派发后那一帧同类：它不是 probe，是写操作的观察。
    try {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 2),
      );
    } on TimeoutException {
      // 等不到帧就按当前已提交的树比较：宁可少报一次布局变化，也不挂住答复。
    }
    final GestureTargetResolution target = await _resolveTarget(
      identifier,
      expectedGeneration: generation,
    );
    if (!target.resolved) return true;
    final GestureResolution geometry = _resolveGeometry(target);
    return !geometry.resolved || geometry.globalRect != beforeRect;
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
    PatchbayGestureKind.pressHold ||
    PatchbayGestureKind.tap => <GesturePoint>[start],
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
