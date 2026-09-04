// PB-050-38：**升层**判定——下一层容器是谁、它的决定合不合法、当前层是不是
// 已经不在目标的祖先链上。
//
// 从 `reveal_engine.dart` 拆出来。这一阶段只回答「往外走一层的候选是什么」，
// 授权本身（policy + 门 + 预算比对）仍由引擎按 DG-060-04 的顺序执行——升层是
// 一次**全新的完整授权**，不是继承内层的那一次。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import '../semantics/semantics_lookup.dart';
import 'reveal_container_facts.dart';
import 'reveal_models.dart';
import 'reveal_observation_stage.dart';

/// 决定自身是否落在 host 编译期硬顶之内。
///
/// 越顶不是「放宽」而是让这条 decision 整体非法：升层到这样的容器按
/// `containerBudgetTooSmall` 停止，而不是被夹到硬顶继续推。
bool patchbayRevealWithinHostCaps(PatchbayRevealDecision decision) =>
    decision.maxSteps >= 1 &&
    decision.maxSteps <= PatchbayRevealBudget.maxSteps &&
    decision.maxDurationMs >= 1 &&
    decision.maxDurationMs <= PatchbayRevealBudget.maxDurationMs;

/// 下一层：目标挂载时以目标祖先链为权威，否则沿当前层向外。
///
/// [readTarget] 是**活读闭包**而不是一个已经读好的值：拆分前这次读取发生在
/// `rootSemanticsNode` 判空之后，保持闭包就保持了同一个求值时机。
SemanticsNode? patchbayRevealNextContainer({
  required SemanticsOwner owner,
  required PatchbayRevealTargetView Function() readTarget,
  required int currentNodeId,
  required Set<int> visitedNodeIds,
  required PatchbayRevealDirection direction,
}) {
  final SemanticsNode? root = owner.rootSemanticsNode;
  if (root == null) return null;
  final PatchbayRevealTargetView target = readTarget();
  final SemanticsNode? currentNode = patchbaySemanticsNodeById(
    root,
    currentNodeId,
  );
  final List<SemanticsNode> chain = switch (target.node) {
    // 目标挂载之后它的祖先链就是权威的容器栈，比准入时的判断更准。
    final SemanticsNode mounted => patchbaySemanticsScrollAncestors(mounted),
    null =>
      currentNode == null
          ? const <SemanticsNode>[]
          : patchbaySemanticsScrollAncestors(
              currentNode,
            ).skip(1).toList(growable: false),
  };
  for (final SemanticsNode candidate in chain) {
    if (visitedNodeIds.contains(candidate.id)) continue;
    // 请求方向上不可驱动的滚动节点不构成候选容器：跳过。
    if (!patchbayRevealDrivable(candidate.getSemanticsData(), direction)) {
      continue;
    }
    return candidate;
  }
  return null;
}

/// 当前层是否已经不在目标的祖先链上——是则应当早停升层。
///
/// 目标挂载后继续推一个不在其祖先链上的容器只会白花步数预算。解析不出当前层
/// 节点时返回 false：那不是「不在链上」而是「无从判断」，此时按进展判定继续，
/// 与拆分前一致。
bool patchbayRevealLayerOffTargetChain({
  required SemanticsOwner owner,
  required SemanticsNode mounted,
  required int layerNodeId,
}) {
  final SemanticsNode? root = owner.rootSemanticsNode;
  final SemanticsNode? node = root == null
      ? null
      : patchbaySemanticsNodeById(root, layerNodeId);
  return node != null && !patchbaySemanticsIsAncestorOrSelf(mounted, node);
}
