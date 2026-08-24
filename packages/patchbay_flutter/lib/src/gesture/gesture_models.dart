import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

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
    required this.node,
    required this.target,
    required this.transform,
    required this.globalRect,
    required this.anchor,
    required this.viewId,
  }) : code = null,
       details = const <String, Object?>{};

  const GestureResolution.rejected(
    this.code, {
    this.details = const <String, Object?>{},
  }) : node = null,
       target = null,
       transform = null,
       globalRect = Rect.zero,
       anchor = null,
       viewId = 0;

  final SemanticsNode? node;
  final PatchbayGestureTarget? target;
  final Matrix4? transform;
  final Rect globalRect;
  final RenderObject? anchor;
  final int viewId;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => target != null;

  Offset global(GesturePoint point) {
    final Offset local = Offset(
      node!.rect.left + node!.rect.width * point.x,
      node!.rect.top + node!.rect.height * point.y,
    );
    return MatrixUtils.transformPoint(transform!, local);
  }

  bool visible(GesturePoint point, Offset globalPoint) {
    final Offset local = Offset(
      node!.rect.left + node!.rect.width * point.x,
      node!.rect.top + node!.rect.height * point.y,
    );
    final Rect? clip = node!.parentPaintClipRect;
    if (clip != null && !clip.contains(local)) return false;
    final HitTestResult result = HitTestResult();
    GestureBinding.instance.hitTestInView(result, globalPoint, viewId);
    for (final HitTestEntry<HitTestTarget> entry in result.path) {
      if (entry.target case final RenderObject candidate) {
        for (
          RenderObject? current = candidate;
          current != null;
          current = current.parent
        ) {
          if (identical(current, anchor)) return true;
        }
      }
    }
    return false;
  }
}
