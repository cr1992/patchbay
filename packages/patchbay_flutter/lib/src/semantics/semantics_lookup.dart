// PB-050-17：语义树上的只读查找原语。
//
// 这份文件只做「在一棵已经拿到的语义树上找节点」，不持有 owner、不发代际、不
// 请帧——owner 由 `PatchbaySemanticsBridge.ensureOwner()` 给，代际由
// `PatchbaySemanticsBridge.observe()` 给，reveal 不复制第二套代际账本。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

/// 按稳定 identifier 收集当前挂载的全部匹配节点（按前序遍历顺序）。
///
/// 不以 label / value 兜底，也不按树顺序挑一个：歧义由调用方 fail-closed 处理。
List<SemanticsNode> patchbaySemanticsNodesWithIdentifier(
  SemanticsNode root,
  String identifier,
) {
  final List<SemanticsNode> matches = <SemanticsNode>[];
  patchbayVisitSemantics(root, (SemanticsNode node) {
    if (node.getSemanticsData().identifier == identifier) matches.add(node);
  });
  return matches;
}

/// 按 nodeId 找回节点；找不到返回 null。
SemanticsNode? patchbaySemanticsNodeById(SemanticsNode root, int nodeId) {
  if (root.id == nodeId) return root;
  SemanticsNode? found;
  root.visitChildren((SemanticsNode child) {
    found = patchbaySemanticsNodeById(child, nodeId);
    return found == null;
  });
  return found;
}

/// 前序遍历整棵子树。
void patchbayVisitSemantics(
  SemanticsNode node,
  void Function(SemanticsNode node) visit,
) {
  visit(node);
  node.visitChildren((SemanticsNode child) {
    patchbayVisitSemantics(child, visit);
    return true;
  });
}

/// 「滚动节点」的判据：`SemanticsData.scrollPosition != null`。
///
/// 这是既有快照字段而不是新概念——Flutter 只在 `position.haveDimensions` 时写
/// 这三个字段（`_RenderScrollSemantics.describeSemanticsConfiguration`）。
bool patchbayIsScrollNode(SemanticsData data) => data.scrollPosition != null;

/// 子树内的全部滚动节点，按由外向内的前序顺序。
List<SemanticsNode> patchbaySemanticsScrollNodesIn(SemanticsNode root) {
  final List<SemanticsNode> found = <SemanticsNode>[];
  patchbayVisitSemantics(root, (SemanticsNode node) {
    if (patchbayIsScrollNode(node.getSemanticsData())) found.add(node);
  });
  return found;
}

/// 从 [node] 起沿 `parent` 链向外的滚动节点，**由内向外**排列。
///
/// [node] 自己若是滚动节点也算在内：目标恰好就是可滚动容器时，它就是最内层。
List<SemanticsNode> patchbaySemanticsScrollAncestors(SemanticsNode node) {
  final List<SemanticsNode> chain = <SemanticsNode>[];
  for (
    SemanticsNode? current = node;
    current != null;
    current = current.parent
  ) {
    if (patchbayIsScrollNode(current.getSemanticsData())) chain.add(current);
  }
  return chain;
}

/// [candidate] 是否在 [node] 的祖先链上（含 [node] 自己）。
bool patchbaySemanticsIsAncestorOrSelf(
  SemanticsNode node,
  SemanticsNode candidate,
) {
  for (
    SemanticsNode? current = node;
    current != null;
    current = current.parent
  ) {
    if (identical(current, candidate)) return true;
  }
  return false;
}
