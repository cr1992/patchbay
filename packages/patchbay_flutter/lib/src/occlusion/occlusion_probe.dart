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

  /// 归一化探针点是否落在祖先 `parentPaintClipRect` 之内。
  ///
  /// [probe] 把「被剪裁掉」与「被外来层盖住」合并成同一个
  /// [PatchbayOcclusionState.obstructed]：对遮挡闸而言两者同样 fail-closed，
  /// 合并是对的。但 PB-050-35 / DG-060-05 的 reveal 准入分类必须把两者分开
  /// ——完全剪裁出 viewport 不叫遮挡，它的恢复方向是继续滚动而不是处理浮层
  /// ——所以把 [probe] 的第一道判定单独暴露一次，而不是另起一套几何。
  bool withinPaintClip(double x, double y) {
    final Rect? clip = node.parentPaintClipRect;
    return clip == null || clip.contains(_localOf(x, y));
  }

  /// 对一个归一化探针点求三态判定。
  PatchbayOcclusionState probe(double x, double y) {
    if (!withinPaintClip(x, y)) return PatchbayOcclusionState.obstructed;
    final Offset local = _localOf(x, y);
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

/// 一次固定采样复核的完整结论：通过时保留是哪一态通过的。
///
/// semantics 的准入闸只需要「过 / 不过」（[reason]），PB-050-17 的 reveal 还要
/// 把通过的两态分流成 `reachability`：`reachable` ⇒ 指针通道，
/// `noPointerFootprint` ⇒ 语义通道。两者是同一次采样的两个投影，不是两套判定。
final class PatchbaySampledOcclusion {
  const PatchbaySampledOcclusion.passed(this.state) : reason = null;

  const PatchbaySampledOcclusion.refused(String this.reason)
    : state = PatchbayOcclusionState.obstructed;

  /// 通过时是**最好**的那一态（reachable 优先于 noPointerFootprint）；
  /// 被拒时恒为 [PatchbayOcclusionState.obstructed]。
  final PatchbayOcclusionState state;

  /// 拒绝原因，null 表示通过。
  final String? reason;

  bool get passed => reason == null;
}

/// 固定采样遮挡复核。
///
/// 五点固定采样、**任一点通过即通过**，五点全被挡才拒绝。通过的两态是
/// [PatchbayOcclusionState.reachable] 与
/// [PatchbayOcclusionState.noPointerFootprint]：后者不可省——`Semantics(onTap:)`
/// 包一个不参与命中测试的子树是合法写法，照搬 gesture 的布尔规则会把这些目标
/// 全判成遮挡。
///
/// 采样点之间取**最好**的一态：任一点 `reachable` 即整体 `reachable`。在
/// `reason` 这个投影上这与「命中第一个非 obstructed 就返回」完全等价（两者都
/// 是「存在非 obstructed」），差别只在 reveal 需要的那一档分流上。
///
/// 诚实边界：这是固定采样准入，不是可达性证明。目标只在采样点之外露出窄缝时
/// 会被误拒（fail-closed，与本闸方向一致）；它也只证明调用瞬间目标未被 App 内
/// 可观测的层覆盖，不承诺 App 外部系统窗口，那一面由 `systemUiUnexpected` 表达。
///
/// 全程同步：不请帧、不遍历语义树、不新增 timer，最多 5 次 `hitTestInView`。
PatchbaySampledOcclusion patchbaySampledOcclusion({
  required SemanticsOwner owner,
  required SemanticsNode node,
}) {
  final PatchbayOcclusionResolution resolution =
      patchbayResolveOcclusionGeometry(owner: owner, node: node);
  final PatchbayOcclusionGeometry? geometry = resolution.geometry;
  if (geometry == null) {
    return PatchbaySampledOcclusion.refused(resolution.reason!);
  }
  return patchbaySampleOcclusionGeometry(geometry);
}

/// [patchbaySampledOcclusion] 的第二半：几何已解析时的五点采样。
///
/// 单独暴露只为让调用方复用**同一份**几何——reveal 的准入分类既要采样结论，
/// 又要知道采样点有没有被祖先 paint clip 剪掉，重解析一次几何等于重跑一遍
/// `hitTest`，且两次解析之间的树变化会让两个结论互相矛盾。
PatchbaySampledOcclusion patchbaySampleOcclusionGeometry(
  PatchbayOcclusionGeometry geometry,
) {
  var best = PatchbayOcclusionState.obstructed;
  for (final PatchbayOcclusionProbe probe in patchbaySemanticsProbeSamples) {
    final PatchbayOcclusionState state = geometry.probe(probe.x, probe.y);
    if (state == PatchbayOcclusionState.reachable) {
      return const PatchbaySampledOcclusion.passed(
        PatchbayOcclusionState.reachable,
      );
    }
    if (state == PatchbayOcclusionState.noPointerFootprint) {
      best = PatchbayOcclusionState.noPointerFootprint;
    }
  }
  return best == PatchbayOcclusionState.obstructed
      ? const PatchbaySampledOcclusion.refused(
          PatchbayOcclusionReason.hitTestOrClip,
        )
      : const PatchbaySampledOcclusion.passed(
          PatchbayOcclusionState.noPointerFootprint,
        );
}

/// 固定采样遮挡复核的布尔投影：返回拒绝 `reason`，null 表示通过。
///
/// PB-050-16 的 semantics 准入闸只需要这一投影。判定本身在
/// [patchbaySampledOcclusion]，两族共用同一份。
String? patchbaySampledOcclusionReason({
  required SemanticsOwner owner,
  required SemanticsNode node,
}) => patchbaySampledOcclusion(owner: owner, node: node).reason;
