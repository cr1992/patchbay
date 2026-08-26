// PB-050-16 / DG-050-09：gesture 与 semantics 两族共用的遮挡判定基元。
//
// 这份文件是从 `gesture/gesture_models.dart` 与 `gesture/gesture_bridge.dart`
// 原样抽出的判定管线：语义节点 → RenderObject 锚点 → `parentPaintClip` 包含 →
// `hitTestInView` → 命中链上溯。抽出的目的只是让 semantics 侧复用同一份判定，
// 不改变 gesture 的任何拒绝语义、`reason` 词表与 details 形状。
//
// 两族的差别只在**怎么用**这份基元，不在基元本身：
//
// - gesture 探调用方给出的每一个点，要求全部 [PatchbayOcclusionState.reachable]；
// - semantics 没有坐标入参，探 [patchbaySemanticsProbeSamples] 五个固定采样点，
//   任一点非 [PatchbayOcclusionState.obstructed] 即通过。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

/// 单个探针点的三态判定结果。
///
/// 布尔不够用：`Semantics(onTap:)` 包一个不参与命中测试的子树（`SizedBox`、
/// 纯 `CustomPaint`、离屏文本）是完全合法的无障碍写法，仓内现有绿灯用例就是
/// `Semantics(onTap:) > SizedBox`。把「目标自己没有指针占位」和「有外来层挡在
/// 前面」区分开，才能既补上遮挡闸又不误伤这些目标。
enum PatchbayOcclusionState {
  /// 命中链中存在条目可沿 `parent` 上溯到锚点。gesture 的通过条件。
  reachable,

  /// 锚点不在命中链中，且链中最前一条是锚点的祖先：目标本身没有指针占位，
  /// 但也没有任何外来层挡在前面。
  ///
  /// `RenderView.hitTest` 恒把自己追加到链尾，所以「没有覆盖层且目标没有
  /// 占位」的命中链最前一条必然是锚点的祖先——这正是把两种情形分开的锚。
  noPointerFootprint,

  /// 锚点不在命中链中，且最前一条既不是锚点也不是锚点的祖先（即外来子树），
  /// 或该点落在 `parentPaintClip` 之外。
  obstructed,
}

/// 遮挡拒绝 `details.reason` 的封闭词表，gesture 与 semantics 共用。
///
/// 词表本身不是稳定 code：稳定 code 是 `uiGestureTargetObscured` /
/// `uiSemanticsTargetObscured`，`reason` 落在自由 details 内。
abstract final class PatchbayOcclusionReason {
  /// 探针点被前景层吸走，或落在祖先 `parentPaintClip` 之外。
  static const String hitTestOrClip = 'hitTestOrClip';

  /// 目标全局 rect 为空或非有限。
  static const String emptyBounds = 'emptyBounds';

  /// 找不到承载该 `SemanticsOwner` 的 `RenderView`。
  static const String viewUnavailable = 'viewUnavailable';

  /// 语义节点找不到对应的 `RenderObject` 锚点。
  static const String renderAnchorUnavailable = 'renderAnchorUnavailable';
}

/// 目标 rect 内的一个归一化探针点（两轴各 0..1）。
final class PatchbayOcclusionProbe {
  const PatchbayOcclusionProbe(this.x, this.y);

  final double x;
  final double y;
}

/// semantics 侧的五点固定采样集合：几何中心 + 四象限。
///
/// 诚实命名：这是**固定采样准入**，不是可达性证明。目标只在五个采样点之外
/// 露出窄缝时，采样会全部被挡而误拒（fail-closed，与本闸方向一致）。
const List<PatchbayOcclusionProbe> patchbaySemanticsProbeSamples =
    <PatchbayOcclusionProbe>[
      PatchbayOcclusionProbe(0.5, 0.5),
      PatchbayOcclusionProbe(0.25, 0.25),
      PatchbayOcclusionProbe(0.75, 0.25),
      PatchbayOcclusionProbe(0.25, 0.75),
      PatchbayOcclusionProbe(0.75, 0.75),
    ];

/// 一次判定所需的全部几何：语义节点、渲染锚点、到全局的变换与视图。
///
/// 结论只对拿到它的那一次派发有效：不缓存、不跨调用复用。
final class PatchbayOcclusionGeometry {
  const PatchbayOcclusionGeometry({
    required this.node,
    required this.anchor,
    required this.transform,
    required this.globalRect,
    required this.viewId,
  });

  final SemanticsNode node;
  final RenderObject anchor;
  final Matrix4 transform;
  final Rect globalRect;
  final int viewId;

  /// 把归一化探针点映射到全局坐标。
  ///
  /// 全局坐标是一次调用内的瞬时实现细节（DG-040-01）：不进 payload、日志与
  /// trace。
  Offset globalOf(double x, double y) =>
      MatrixUtils.transformPoint(transform, _localOf(x, y));

  /// 对一个归一化探针点求三态判定。
  PatchbayOcclusionState probe(double x, double y) {
    final Offset local = _localOf(x, y);
    final Rect? clip = node.parentPaintClipRect;
    if (clip != null && !clip.contains(local)) {
      return PatchbayOcclusionState.obstructed;
    }
    final HitTestResult result = HitTestResult();
    GestureBinding.instance.hitTestInView(
      result,
      MatrixUtils.transformPoint(transform, local),
      viewId,
    );
    RenderObject? frontmost;
    for (final HitTestEntry<HitTestTarget> entry in result.path) {
      if (entry.target case final RenderObject candidate) {
        frontmost ??= candidate;
        for (
          RenderObject? current = candidate;
          current != null;
          current = current.parent
        ) {
          if (identical(current, anchor)) {
            return PatchbayOcclusionState.reachable;
          }
        }
      }
    }
    if (frontmost != null && _isAnchorAncestor(frontmost)) {
      return PatchbayOcclusionState.noPointerFootprint;
    }
    return PatchbayOcclusionState.obstructed;
  }

  Offset _localOf(double x, double y) => Offset(
    node.rect.left + node.rect.width * x,
    node.rect.top + node.rect.height * y,
  );

  bool _isAnchorAncestor(RenderObject candidate) {
    for (
      RenderObject? current = anchor.parent;
      current != null;
      current = current.parent
    ) {
      if (identical(current, candidate)) return true;
    }
    return false;
  }
}

/// [patchbayResolveOcclusionGeometry] 的结果：几何，或一个 fail-closed 的
/// `reason`。
final class PatchbayOcclusionResolution {
  const PatchbayOcclusionResolution.resolved(
    PatchbayOcclusionGeometry this.geometry,
  ) : reason = null;

  const PatchbayOcclusionResolution.rejected(String this.reason)
    : geometry = null;

  final PatchbayOcclusionGeometry? geometry;
  final String? reason;

  bool get resolved => geometry != null;
}

/// 由语义节点解析出判定几何。
///
/// 三条失败路径都是 fail-closed：找不到 `RenderView`、找不到渲染锚点、全局
/// rect 为空或非有限。
PatchbayOcclusionResolution patchbayResolveOcclusionGeometry({
  required SemanticsOwner owner,
  required SemanticsNode node,
}) {
  final RenderView? view = RendererBinding.instance.renderViews
      .cast<RenderView?>()
      .firstWhere(
        (RenderView? candidate) =>
            identical(candidate?.owner?.semanticsOwner, owner),
        orElse: () => null,
      );
  if (view == null) {
    return const PatchbayOcclusionResolution.rejected(
      PatchbayOcclusionReason.viewUnavailable,
    );
  }
  final RenderObject? anchor = patchbaySemanticRenderObject(view, node);
  if (anchor == null) {
    return const PatchbayOcclusionResolution.rejected(
      PatchbayOcclusionReason.renderAnchorUnavailable,
    );
  }
  final double devicePixelRatio = view.flutterView.devicePixelRatio;
  final Matrix4 transform = Matrix4.diagonal3Values(
    1 / devicePixelRatio,
    1 / devicePixelRatio,
    1,
  )..multiply(patchbayTransformToRoot(node));
  final Rect globalRect = MatrixUtils.transformRect(transform, node.rect);
  if (globalRect.isEmpty || !globalRect.isFinite) {
    return const PatchbayOcclusionResolution.rejected(
      PatchbayOcclusionReason.emptyBounds,
    );
  }
  return PatchbayOcclusionResolution.resolved(
    PatchbayOcclusionGeometry(
      node: node,
      anchor: anchor,
      transform: transform,
      globalRect: globalRect,
      viewId: view.flutterView.viewId,
    ),
  );
}

/// 由语义节点向上找到第一个匹配的 `RenderObject` 锚点。
///
/// 依赖 `debugSemantics`（`kReleaseMode` 下为 null），与 gesture 现有实现同源。
RenderObject? patchbaySemanticRenderObject(
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

/// 把语义节点的局部坐标累积成到根的变换。
Matrix4 patchbayTransformToRoot(SemanticsNode node) {
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
