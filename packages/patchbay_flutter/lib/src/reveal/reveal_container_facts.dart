// PB-050-38：一个容器节点的**只读事实**——轴、极性、可驱动与身份投影。
//
// 从 `reveal_engine.dart` 拆出来的第一层：这里的每个函数都只看
// `SemanticsNode` / `SemanticsData`，不碰步循环的任何可变状态，也不产生终态。
// 因此它们可以脱离一次 reveal 调用单独构造与失败注入——极性推断、可驱动判定
// 与「锚点 identifier 该落在哪个容器头上」这三条规则各有自己的边界情形，混在
// 754 行的引擎里时只能靠端到端用例间接覆盖。
//
// 准入（`reveal_bridge.dart`）与升层（`reveal_escalation_stage.dart`）共用同一
// 份判据，这也是它必须独立于两者的原因。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import '../semantics/semantics_lookup.dart';
import '../semantics/semantics_models.dart';
import 'reveal_models.dart';

/// 容器在 policy 眼里的稳定身份。
///
/// 滚动节点自己几乎从不带 identifier：锚点按惯例包在 `Scrollable` 外层
/// （`Semantics(identifier: ..., child: ListView...)`），identifier 落在锚点节点
/// 上，滚动语义节点是它的后代。若把 `data.identifier` 原样交给 policy，接入方
/// 拿到的永远是空串，「允不允许推这块区域」就无从判断。
///
/// 所以这里取**该容器最内层的锚点 identifier**：沿 `parent` 向外找第一个非空
/// identifier，遇到另一个滚动节点即停——这样外层容器的锚点身份不会被误安到内层
/// 容器头上。这是一条确定的查找规则，不是按尺寸或深度打分的猜测。
String patchbayRevealContainerIdentity(SemanticsNode node, SemanticsData data) {
  if (data.identifier.isNotEmpty) return data.identifier;
  for (
    SemanticsNode? current = node.parent;
    current != null;
    current = current.parent
  ) {
    final SemanticsData ancestor = current.getSemanticsData();
    if (patchbayIsScrollNode(ancestor)) return '';
    if (ancestor.identifier.isNotEmpty) return ancestor.identifier;
  }
  return '';
}

/// 只读容器事实，形状与 `ui.semantics.*` 的 policy 入参同构。
PatchbaySemanticsTarget patchbayRevealTargetOf(
  SemanticsNode node,
  int generation,
  SemanticsData data,
) => PatchbaySemanticsTarget(
  nodeId: node.id,
  generation: generation,
  identifier: patchbayRevealContainerIdentity(node, data),
  label: data.label,
  flags: Set<String>.unmodifiable(data.flagsCollection.toStrings()),
  actions: Set<PatchbaySemanticsAction>.unmodifiable(<PatchbaySemanticsAction>{
    for (final PatchbaySemanticsAction action in PatchbaySemanticsAction.values)
      if (data.hasAction(action.flutterAction)) action,
  }),
  obscured: data.flagsCollection.isObscured,
);

/// 锚点子树内**唯一**的滚动节点；0 个或多于 1 个都返回 null。
SemanticsNode? patchbayRevealScrollNodeUnder(
  SemanticsNode root,
  String anchorIdentifier,
) {
  final List<SemanticsNode> anchors = patchbaySemanticsNodesWithIdentifier(
    root,
    anchorIdentifier,
  );
  if (anchors.length != 1) return null;
  final List<SemanticsNode> scrollables = patchbaySemanticsScrollNodesIn(
    anchors.single,
  );
  return scrollables.length == 1 ? scrollables.single : null;
}

/// 一个容器同轴的两个 scroll action。
///
/// 极性（谁增大 `pixels`）不能从 `SemanticsData` 推出，只能观察：action 名字
/// 描述的是**用户会做的手势**，不是内容序。`reverse: true` 的竖直列表里，朝
/// `maxScrollExtent` 前进的那一个是 `scrollDown`。
final class PatchbayRevealAxis {
  const PatchbayRevealAxis(this.first, this.second);

  final PatchbaySemanticsAction first;
  final PatchbaySemanticsAction second;

  static const PatchbayRevealAxis vertical = PatchbayRevealAxis(
    PatchbaySemanticsAction.scrollUp,
    PatchbaySemanticsAction.scrollDown,
  );
  static const PatchbayRevealAxis horizontal = PatchbayRevealAxis(
    PatchbaySemanticsAction.scrollLeft,
    PatchbaySemanticsAction.scrollRight,
  );

  /// 该节点当前暴露的同轴 action 决定轴；一个都不暴露即不是可驱动容器。
  static PatchbayRevealAxis? of(SemanticsData data) {
    if (data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollDown)) {
      return vertical;
    }
    if (data.hasAction(SemanticsAction.scrollLeft) ||
        data.hasAction(SemanticsAction.scrollRight)) {
      return horizontal;
    }
    return null;
  }

  PatchbaySemanticsAction other(PatchbaySemanticsAction action) =>
      action == first ? second : first;

  List<PatchbaySemanticsAction> exposedIn(SemanticsData data) =>
      <PatchbaySemanticsAction>[
        if (data.hasAction(first.flutterAction)) first,
        if (data.hasAction(second.flutterAction)) second,
      ];
}

/// 事实一：只暴露一个同轴 action 时，`pixels` 处于某一端，极性由端点唯一确定。
///
/// 在 `min` 处暴露的是内容序 forward，在 `max` 处暴露的是 backward。两个都暴露
/// 或端点信息不足时返回 null——那时极性只能靠一次探测步观察出来。
PatchbaySemanticsAction? patchbayRevealForwardFromEnd(
  SemanticsData data,
  PatchbayRevealAxis axis,
  List<PatchbaySemanticsAction> exposed,
) {
  if (exposed.length != 1) return null;
  final double? position = data.scrollPosition;
  if (position == null) return null;
  final double? min = data.scrollExtentMin;
  final double? max = data.scrollExtentMax;
  if (min != null && position <= min) return exposed.single;
  if (max != null && position >= max) return axis.other(exposed.single);
  return null;
}

/// 该节点此刻能否朝请求的方向被驱动。
///
/// 准入与升层用同一个判据：一个同轴 scroll action 都不暴露、或请求方向上的那个
/// action 已经不在容器上（例如已经滚到那一端），都不构成可驱动容器。准入时按
/// `uiRevealNoScrollableContainer` 拒绝，升层时直接跳过——两处都不会走到「一次
/// 都没派发却回一个受理后 failed」的形状上。
bool patchbayRevealDrivable(
  SemanticsData data,
  PatchbayRevealDirection direction,
) {
  final PatchbayRevealAxis? axis = PatchbayRevealAxis.of(data);
  if (axis == null) return false;
  final List<PatchbaySemanticsAction> exposed = axis.exposedIn(data);
  if (exposed.isEmpty) return false;
  if (direction == PatchbayRevealDirection.both) return true;
  final PatchbaySemanticsAction? forward = patchbayRevealForwardFromEnd(
    data,
    axis,
    exposed,
  );
  // 极性还不确定：探测步会把它定下来，此时不能预先判它不可驱动。
  if (forward == null) return true;
  final PatchbaySemanticsAction wanted =
      direction == PatchbayRevealDirection.forward
      ? forward
      : axis.other(forward);
  return exposed.contains(wanted);
}
