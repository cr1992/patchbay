// PB-050-38：每一步的**现场读取**阶段——目标观察、容器重解析与进展观察。
//
// 从 `reveal_engine.dart` 拆出来。这一阶段的共同点是「只读语义树、不改任何
// 状态、不产生终态」：三个函数各自回答一个问题，答案再交给引擎去决定终止与否。
//
// 独立出来才拿得到的覆盖：`owner.rootSemanticsNode` 为空、节点被换代、目标零
// 匹配与多匹配、`scrollPosition` 缺失或非有限——这些分支在端到端用例里要摆出
// 一整棵会在特定时刻塌掉的树才能碰到，在这里只需要构造一次调用。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import '../semantics/semantics_bridge.dart';
import '../semantics/semantics_lookup.dart';
import 'reveal_container_facts.dart';

/// 一次目标读取的三态：未挂载、多个挂载实例、唯一挂载。
final class PatchbayRevealTargetView {
  const PatchbayRevealTargetView.absent() : node = null, ambiguous = false;
  const PatchbayRevealTargetView.ambiguous() : node = null, ambiguous = true;
  const PatchbayRevealTargetView.mounted(SemanticsNode this.node)
    : ambiguous = false;

  final SemanticsNode? node;
  final bool ambiguous;
}

/// 一步派发之后观察到的进展。
final class PatchbayRevealProgress {
  const PatchbayRevealProgress({required this.delta, required this.grew});

  final double delta;
  final bool grew;

  bool get moved => delta != 0;
}

/// 目标此刻在树上的样子。
///
/// 分页可能渲染重复项：多个挂载实例一律 fail-closed，不按树顺序选。
PatchbayRevealTargetView patchbayRevealReadTarget({
  required SemanticsOwner owner,
  required String identifier,
}) {
  final SemanticsNode? root = owner.rootSemanticsNode;
  if (root == null) return const PatchbayRevealTargetView.absent();
  final List<SemanticsNode> matches = patchbaySemanticsNodesWithIdentifier(
    root,
    identifier,
  );
  if (matches.isEmpty) return const PatchbayRevealTargetView.absent();
  if (matches.length > 1) return const PatchbayRevealTargetView.ambiguous();
  return PatchbayRevealTargetView.mounted(matches.single);
}

/// 按 pin 重解析当前层的容器节点；解析不出同一块区域就返回 null。
///
/// 显式 `--container` 的容器按 identifier 锚点重解析；来自祖先链的容器没有
/// identifier，按 nodeId + generation 重解析。两条路径都要求 **nodeId 与
/// generation 同时对得上**——换代意味着这已经不是被授权的那块可滚动区域。
SemanticsNode? patchbayRevealResolveLayerNode({
  required SemanticsOwner owner,
  required PatchbaySemanticsBridge semantics,
  required String? anchorIdentifier,
  required int nodeId,
  required int generation,
}) {
  final SemanticsNode? root = owner.rootSemanticsNode;
  if (root == null) return null;
  final SemanticsNode? node = switch (anchorIdentifier) {
    final String anchor => patchbayRevealScrollNodeUnder(root, anchor),
    null => patchbaySemanticsNodeById(root, nodeId),
  };
  if (node == null || node.id != nodeId) return null;
  return semantics.observe(node).generation == generation ? node : null;
}

/// 派发一步之后，容器实际走了多远、内容有没有变多。
///
/// 容器解析不出来时按「零进展」处理而不是报错：那一步的终止判定由调用点根据
/// 停滞规则给出，本函数不替它下结论。非有限位移同样归零——`NaN` / `Infinity`
/// 不是「走了很远」。
PatchbayRevealProgress patchbayRevealObserveProgress({
  required SemanticsOwner owner,
  required int nodeId,
  required double? beforePosition,
  required double? beforeExtentMax,
}) {
  final SemanticsNode? root = owner.rootSemanticsNode;
  final SemanticsNode? node = root == null
      ? null
      : patchbaySemanticsNodeById(root, nodeId);
  if (node == null) {
    return const PatchbayRevealProgress(delta: 0, grew: false);
  }
  final SemanticsData data = node.getSemanticsData();
  final double? after = data.scrollPosition;
  final double delta = (after == null || beforePosition == null)
      ? 0
      : after - beforePosition;
  final double? afterMax = data.scrollExtentMax;
  final bool grew =
      afterMax != null && beforeExtentMax != null && afterMax > beforeExtentMax;
  return PatchbayRevealProgress(delta: delta.isFinite ? delta : 0, grew: grew);
}
