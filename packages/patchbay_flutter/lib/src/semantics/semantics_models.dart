import 'package:flutter/rendering.dart';
import 'package:patchbay/patchbay_protocol.dart';

/// Stable Patchbay names for the first supported Flutter semantics actions.
enum PatchbaySemanticsAction {
  tap,
  longPress,
  focus,
  dismiss,
  showOnScreen,
  scrollUp,
  scrollDown,
  scrollLeft,
  scrollRight,
  increase,
  decrease,
  expand,
  collapse,
  setText;

  SemanticsAction get flutterAction => switch (this) {
    PatchbaySemanticsAction.tap => SemanticsAction.tap,
    PatchbaySemanticsAction.longPress => SemanticsAction.longPress,
    PatchbaySemanticsAction.focus => SemanticsAction.focus,
    PatchbaySemanticsAction.dismiss => SemanticsAction.dismiss,
    PatchbaySemanticsAction.showOnScreen => SemanticsAction.showOnScreen,
    PatchbaySemanticsAction.scrollUp => SemanticsAction.scrollUp,
    PatchbaySemanticsAction.scrollDown => SemanticsAction.scrollDown,
    PatchbaySemanticsAction.scrollLeft => SemanticsAction.scrollLeft,
    PatchbaySemanticsAction.scrollRight => SemanticsAction.scrollRight,
    PatchbaySemanticsAction.increase => SemanticsAction.increase,
    PatchbaySemanticsAction.decrease => SemanticsAction.decrease,
    PatchbaySemanticsAction.expand => SemanticsAction.expand,
    PatchbaySemanticsAction.collapse => SemanticsAction.collapse,
    PatchbaySemanticsAction.setText => SemanticsAction.setText,
  };

  static PatchbaySemanticsAction? fromWireName(String value) {
    for (final PatchbaySemanticsAction action in values) {
      if (action.name == value) return action;
    }
    return null;
  }
}

/// Read-only target facts supplied to the consumer action policy.
final class PatchbaySemanticsTarget {
  const PatchbaySemanticsTarget({
    required this.nodeId,
    required this.generation,
    required this.identifier,
    required this.label,
    required this.flags,
    required this.actions,
    required this.obscured,
  });

  final int nodeId;
  final int generation;
  final String identifier;
  final String label;
  final Set<String> flags;
  final Set<PatchbaySemanticsAction> actions;
  final bool obscured;
}

/// One currently attached node selected by a stable Semantics identifier.
final class PatchbaySemanticsIdentifierMatch {
  const PatchbaySemanticsIdentifierMatch({
    required this.nodeId,
    required this.generation,
    required this.value,
    required this.obscured,
    required this.invisible,
  });

  final int nodeId;
  final int generation;
  final String value;
  final bool obscured;
  final bool invisible;
}

/// Current result of resolving a Semantics identifier.
final class PatchbaySemanticsIdentifierObservation {
  const PatchbaySemanticsIdentifierObservation({
    required this.treeRevision,
    required this.matches,
  });

  final int treeRevision;
  final List<PatchbaySemanticsIdentifierMatch> matches;
}

/// Consumer-owned decision for one currently observed semantics action.
final class PatchbaySemanticsActionDecision {
  const PatchbaySemanticsActionDecision.allow({
    this.gateIds = const <String>{},
    this.sensitiveInput = false,
  }) : rejectionCode = null,
       rejectionNotice = null;

  const PatchbaySemanticsActionDecision.reject({
    this.rejectionCode = 'uiSemanticsActionDenied',
    this.rejectionNotice,
  }) : gateIds = const <String>{},
       sensitiveInput = false;

  final Set<String> gateIds;
  final bool sensitiveInput;
  final String? rejectionCode;
  final String? rejectionNotice;

  bool get allowed => rejectionCode == null;
}

typedef PatchbaySemanticsActionPolicy =
    PatchbaySemanticsActionDecision Function(
      PatchbaySemanticsTarget target,
      PatchbaySemanticsAction action,
    );

final class PatchbaySemanticsEntry {
  const PatchbaySemanticsEntry(this.node, this.generation);

  final WeakReference<SemanticsNode> node;
  final int generation;
}

final class PatchbaySemanticsSnapshot {
  const PatchbaySemanticsSnapshot({
    required this.rootNodeId,
    required this.nodes,
    required this.truncated,
  });

  final int rootNodeId;
  final List<PatchbaySemanticsNodeWire> nodes;
  final bool truncated;

  Map<String, Object?> toJson(int revision) => PatchbaySemanticsSnapshotWire(
    outcome: 'observed',
    source: PatchbayFactSourceWire.uiObserved,
    treeRevision: revision,
    rootNodeId: rootNodeId,
    truncated: truncated,
    nodeCount: nodes.length,
    nodes: nodes,
  ).toJson();
}

final class PatchbaySemanticsResolution {
  const PatchbaySemanticsResolution.resolved(this.owner, this.target, this.node)
    : code = null,
      details = const <String, Object?>{};

  const PatchbaySemanticsResolution.rejected(
    this.code, {
    this.details = const <String, Object?>{},
  }) : owner = null,
       target = null,
       node = null;

  final SemanticsOwner? owner;
  final PatchbaySemanticsTarget? target;

  /// 本次解析命中的语义节点本身。
  ///
  /// PB-050-16 的遮挡复核要在同一次 resolve 的结论上做几何判定，不能靠
  /// nodeId 再查一次树——那会引入第二个真源和一次新的漂移窗口。
  final SemanticsNode? node;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => owner != null && target != null;
}
