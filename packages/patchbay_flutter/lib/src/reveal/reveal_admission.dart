// PB-050-35 / DG-060-05：`ui.reveal` 在**第一次 scroll 派发前**对目标做的可达性
// 分类。
//
// 它回答的是一个比「露出了没有」更细的问题：目标没露出时，调用方该往哪个方向
// 恢复。裁决把三个恢复方向冻结成三种准入拒绝（见
// `docs/proposals/0.6.0/ui-reachability-semantics.md` 的裁决结论），而这三者只
// 有一个共同前提——分类发生在派发之前，因此**不消耗 step**，也不产生受理后的
// `failed` payload。
//
// 关键区分是「剪裁」与「遮挡」：
//
// - 目标完全剪裁出 viewport、`isInvisible` 或零可见面积，**不叫遮挡**。滚动正是
//   为它存在的，所以有可驱动容器就继续 reveal，没有才归容器类拒绝。
// - 目标几何上已曝光（五个采样点全部落在祖先 paint clip 之内）却仍被
//   `blockUserActions` 或五点采样判为 obstructed，才是遮挡：滚动穿不透它，
//   恢复方向是处理 modal / 覆盖层。
//
// 遮挡判定本身**不新造**：复用 `occlusion/occlusion_probe.dart` 那份 gesture 与
// semantics 共用的五点采样，只是多问它一次「采样点有没有被剪掉」。同一份几何
// 解析用于两个投影，避免两次 `hitTest` 之间的树变化让结论互相矛盾。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/semantics.dart';
import 'package:patchbay/patchbay.dart';

import '../occlusion/occlusion_probe.dart';
import '../semantics/semantics_bridge.dart';
import 'reveal_models.dart';

/// 准入期目标分类的封闭三态。
enum PatchbayRevealTargetState {
  /// 已挂载、几何上已曝光、未被屏蔽也未被盖住：无需驱动即可成功。
  revealed,

  /// 已挂载且几何上已曝光，但被 `blockUserActions` 或五点采样判为 obstructed。
  /// 滚动穿不透，按 `uiRevealTargetObscured` 拒绝。
  obscured,

  /// 尚未曝光：完全或部分剪裁出祖先 paint clip、`isInvisible`、零可见面积，
  /// 或几何压根解析不出来。这是 reveal 的正常输入，不是遮挡。
  notExposed,
}

/// 一次准入期分类的结果。[outcome] 非空当且仅当 [state] 是
/// [PatchbayRevealTargetState.revealed]。
final class PatchbayRevealTargetAdmission {
  const PatchbayRevealTargetAdmission.revealed(
    PatchbayRevealOutcome this.outcome,
  ) : state = PatchbayRevealTargetState.revealed;

  const PatchbayRevealTargetAdmission.obscured()
    : state = PatchbayRevealTargetState.obscured,
      outcome = null;

  const PatchbayRevealTargetAdmission.notExposed()
    : state = PatchbayRevealTargetState.notExposed,
      outcome = null;

  final PatchbayRevealTargetState state;

  /// 无需驱动的成功终态，只在 [PatchbayRevealTargetState.revealed] 时非空。
  final PatchbayRevealOutcome? outcome;

  bool get obscured => state == PatchbayRevealTargetState.obscured;
}

/// 对一个**已唯一挂载**的目标求准入期分类。
///
/// 求值顺序是裁决口径的直译，不能重排：
///
/// 1. `isInvisible` 与几何不可解析（空 rect / 非有限 / 找不到锚点或 view）先归
///    [PatchbayRevealTargetState.notExposed]——它们是「屏外」的各种写法，不是
///    遮挡。
/// 2. 五点采样通过且未被 `blockUserActions` 屏蔽 ⇒ 已露出。
/// 3. 剩下的情形里，只有**五个采样点全部在祖先 paint clip 之内**才算「几何上
///    已曝光」，才判遮挡；任何一点被剪掉都说明目标还没完全进到可视区，恢复方向
///    仍是滚动。
///
/// 第 3 条同时守住一个容易踩的回归：目标只露出半截时（常见于滚到边缘的那一
/// 帧），采样会因为剪裁而全灭，若不区分就会把「再滚一点就好」误报成遮挡。
PatchbayRevealTargetAdmission patchbayRevealTargetAdmission({
  required SemanticsOwner owner,
  required SemanticsNode node,
  required PatchbaySemanticsBridge semantics,
}) {
  if (node.isInvisible) return const PatchbayRevealTargetAdmission.notExposed();
  final PatchbayOcclusionResolution resolution =
      patchbayResolveOcclusionGeometry(owner: owner, node: node);
  final PatchbayOcclusionGeometry? geometry = resolution.geometry;
  if (geometry == null) {
    return const PatchbayRevealTargetAdmission.notExposed();
  }

  final PatchbaySampledOcclusion occlusion = patchbaySampleOcclusionGeometry(
    geometry,
  );
  if (occlusion.passed && !node.areUserActionsBlocked) {
    return PatchbayRevealTargetAdmission.revealed(
      PatchbayRevealOutcome.revealed(
        nodeId: node.id,
        generation: semantics.observe(node).generation,
        reachability: switch (occlusion.state) {
          PatchbayOcclusionState.reachable =>
            PatchbayRevealReachabilityWire.pointer,
          PatchbayOcclusionState.noPointerFootprint =>
            PatchbayRevealReachabilityWire.semanticsOnly,
          // 通过的两态只有上面两个；obstructed 由 `passed` 挡在外面。
          PatchbayOcclusionState.obstructed => throw StateError(
            'obstructed cannot pass the sampled occlusion admission',
          ),
        },
      ),
    );
  }

  final bool exposed = patchbaySemanticsProbeSamples.every(
    (PatchbayOcclusionProbe probe) =>
        geometry.withinPaintClip(probe.x, probe.y),
  );
  return exposed
      ? const PatchbayRevealTargetAdmission.obscured()
      : const PatchbayRevealTargetAdmission.notExposed();
}

/// 目标此刻已挂载且露出时的成功终态，否则 null。
///
/// 进入循环之前的那一次判定（步数为 0 的那一次）只认这一个终态：被模态屏蔽、
/// 被裁剪、被盖住都不是 0 步终态——受理后的 `failed` payload 要求 `containers`
/// 恒非空，而一次都没派发时它必然是空的。
///
/// 它现在是 [patchbayRevealTargetAdmission] 的一个投影：引擎在步间只关心「露出
/// 了没有」，恢复方向的分辨只发生在受理边界上。
PatchbayRevealOutcome? patchbayRevealedNow({
  required SemanticsOwner owner,
  required SemanticsNode? node,
  required PatchbaySemanticsBridge semantics,
}) => node == null
    ? null
    : patchbayRevealTargetAdmission(
        owner: owner,
        node: node,
        semantics: semantics,
      ).outcome;
