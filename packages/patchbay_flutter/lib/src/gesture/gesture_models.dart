import 'package:flutter/rendering.dart';

import '../occlusion/occlusion_probe.dart';

/// Pointer gesture families supported by the anchored gesture bridge.
enum PatchbayGestureKind { pressHold, drag, fling }

/// Read-only target facts supplied to the independent gesture policy.
final class PatchbayGestureTarget {
  const PatchbayGestureTarget({
    required this.nodeId,
    required this.generation,
    required this.identifier,
    required this.flags,
  });

  final int nodeId;
  final int generation;
  final String identifier;
  final Set<String> flags;
}

/// Consumer decision and optional tighter budgets for one gesture.
final class PatchbayGestureDecision {
  const PatchbayGestureDecision.allow({
    this.gateIds = const <String>{},
    this.maxDurationMs = 30000,
    this.maxPathPoints = 64,
    this.maxVelocity = 20,
  }) : rejectionCode = null,
       rejectionNotice = null;

  const PatchbayGestureDecision.reject({
    this.rejectionCode = 'uiGestureDenied',
    this.rejectionNotice,
  }) : gateIds = const <String>{},
       maxDurationMs = 0,
       maxPathPoints = 0,
       maxVelocity = 0;

  final Set<String> gateIds;
  final int maxDurationMs;
  final int maxPathPoints;
  final double maxVelocity;
  final String? rejectionCode;
  final String? rejectionNotice;

  bool get allowed => rejectionCode == null;
}

typedef PatchbayGesturePolicy =
    PatchbayGestureDecision Function(
      PatchbayGestureTarget target,
      PatchbayGestureKind gesture,
    );
typedef PatchbayPointerEventDispatcher = void Function(PointerEvent event);
typedef PatchbayGestureDelay = Future<void> Function(Duration duration);

final class GesturePoint {
  const GesturePoint(this.x, this.y);
  final double x;
  final double y;
}

final class GesturePathPoint {
  const GesturePathPoint(this.point, this.timeMs);
  final GesturePoint point;
  final int timeMs;
}

final class GestureTargetResolution {
  const GestureTargetResolution.resolved({
    required this.owner,
    required this.node,
    required this.target,
  }) : code = null,
       details = const <String, Object?>{};

  const GestureTargetResolution.rejected(
    this.code, {
    this.details = const <String, Object?>{},
  }) : owner = null,
       node = null,
       target = null;

  final SemanticsOwner? owner;
  final SemanticsNode? node;
  final PatchbayGestureTarget? target;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => target != null;
}

final class GestureResolution {
  const GestureResolution.resolved({
    required PatchbayOcclusionGeometry this.geometry,
    required this.target,
  }) : code = null,
       details = const <String, Object?>{};

  const GestureResolution.rejected(
    this.code, {
    this.details = const <String, Object?>{},
  }) : geometry = null,
       target = null;

  /// 与 semantics 共用的判定几何（PB-050-16 抽出的基元）。
  final PatchbayOcclusionGeometry? geometry;
  final PatchbayGestureTarget? target;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => target != null;

  Rect get globalRect => geometry?.globalRect ?? Rect.zero;

  int get viewId => geometry?.viewId ?? 0;

  Offset global(GesturePoint point) => geometry!.globalOf(point.x, point.y);

  /// gesture 的通过条件保持布尔且只认 [PatchbayOcclusionState.reachable]：
  /// 逐点全过才派发。三态里另外两态在 gesture 侧都算不可见，与抽基元之前
  /// 的判定逐条等价。
  bool visible(GesturePoint point) =>
      geometry!.probe(point.x, point.y) == PatchbayOcclusionState.reachable;
}
