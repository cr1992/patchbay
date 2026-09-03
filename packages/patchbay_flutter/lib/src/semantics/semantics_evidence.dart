// PB-050-38：准入管线的**投影阶段**——把内部结论投影成对外的稳定形状。
//
// 拒绝的 `details`、accepted 的载荷键序、候选事实里 `enabled` 的三态口径、遮蔽
// 目标用 `labelRedacted` 顶替 `label`、`setText` 载荷只报长度不报内容——这些都是
// 稳定 JSON，任何一处漂移都是兼容事故。拆到这里是为了它们可以脱离一整条 dispatch
// 单独构造与断言，而不是只能靠跑通全链路才发现形状变了。
//
// 本文件**只做投影**：不读 owner、不请帧、不做任何准入判定，也不持有状态。
// 它不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:patchbay/patchbay_host.dart';

import '../lifecycle.dart';
import 'semantics_models.dart';

/// 一个候选节点的公开事实。
///
/// [generation] 由调用阶段从代际账本读出后传入——本文件不发代际，也不触碰账本，
/// 否则「投影」就会变成第二个有副作用的真源。
Map<String, Object?> patchbaySemanticsCandidateEvidence(
  SemanticsNode node,
  SemanticsData data, {
  required int generation,
}) {
  final bool obscured = data.flagsCollection.isObscured;
  return <String, Object?>{
    'nodeId': node.id,
    'generation': generation,
    if (obscured) 'labelRedacted': true else 'label': data.label,
    'actions': <String>[
      for (final PatchbaySemanticsAction candidate
          in PatchbaySemanticsAction.values)
        if (data.hasAction(candidate.flutterAction)) candidate.name,
    ]..sort(),
    // Only nodes that declare an enabled state carry the key: a plain label
    // has no such fact, and inventing `true` for it would let a caller read
    // "enabled" where Flutter never said so.
    if (data.flagsCollection.isEnabled != Tristate.none)
      'enabled': data.flagsCollection.isEnabled == Tristate.isTrue,
    'invisible': node.isInvisible,
    'userActionsBlocked': node.areUserActionsBlocked,
  };
}

/// 交给 consumer action policy 的只读目标事实。
///
/// 与 [patchbaySemanticsCandidateEvidence] 是同一份 `SemanticsData` 的两个投影：
/// 一个给策略当输入，一个给调用方当拒绝证据；两者都不发代际，代际由调用阶段传入。
PatchbaySemanticsTarget patchbaySemanticsTargetOf(
  SemanticsNode node,
  SemanticsData data, {
  required int generation,
}) => PatchbaySemanticsTarget(
  nodeId: node.id,
  generation: generation,
  identifier: data.identifier,
  label: data.label,
  flags: Set<String>.unmodifiable(data.flagsCollection.toStrings()),
  actions: Set<PatchbaySemanticsAction>.unmodifiable(<PatchbaySemanticsAction>{
    for (final PatchbaySemanticsAction action in PatchbaySemanticsAction.values)
      if (data.hasAction(action.flutterAction)) action,
  }),
  obscured: data.flagsCollection.isObscured,
);

/// 目标被遮挡时的 `details`。[identifier] 为空的 nodeId 路径不写这个键。
Map<String, Object?> patchbaySemanticsObscuredEvidence({
  required String reason,
  required int nodeId,
  required int generation,
  String? identifier,
}) => <String, Object?>{
  'reason': reason,
  'nodeId': nodeId,
  'generation': generation,
  'identifier': ?identifier,
};

PatchbayInvocation patchbaySemanticsGateRejected(
  String requestId,
  PatchbayGateRejection gate,
) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: gate.code,
    notice: gate.notice,
    details: <String, Object?>{'gateId': gate.gateId},
  ),
);

PatchbayInvocation patchbaySemanticsResolutionRejected(
  String requestId,
  PatchbaySemanticsResolution resolution,
) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: resolution.code!,
    details: resolution.details,
  ),
);

PatchbayInvocation patchbaySemanticsPolicyRejected(
  String requestId,
  PatchbaySemanticsActionDecision decision,
) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: decision.rejectionCode!,
    notice: decision.rejectionNotice,
  ),
);

PatchbayInvocation patchbaySemanticsLifecycleRejected(
  String requestId,
  PatchbayLifecycleStateReader lifecycleState,
) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: 'uiLifecycleNotResumed',
    details: patchbayLifecycleDetails(lifecycleState),
  ),
);

/// 派发成功的载荷。
///
/// [sensitive] 为真时只报长度、不报内容：`valueRedacted` 与 `length` 一起出现，
/// 顺序与键集都是稳定 JSON 的一部分。
Map<String, Object?> patchbaySemanticsDispatchedPayload({
  required PatchbaySemanticsAction action,
  required int nodeId,
  required int generation,
  required int beforeTreeRevision,
  required int afterTreeRevision,
  required bool sensitive,
  String? identifier,
  String? text,
}) => <String, Object?>{
  'outcome': 'dispatched',
  'source': PatchbayFactSource.uiObserved.name,
  'identifier': ?identifier,
  'nodeId': nodeId,
  'generation': generation,
  'action': action.name,
  'beforeTreeRevision': beforeTreeRevision,
  'afterTreeRevision': afterTreeRevision,
  if (action == PatchbaySemanticsAction.setText)
    if (sensitive) ...<String, Object?>{
      'valueRedacted': true,
      'length': text!.length,
    } else ...<String, Object?>{'length': text!.length},
};

/// 派发本身抛出时的载荷：**只报异常类型**，不报 message、不报栈。
Map<String, Object?> patchbaySemanticsFailedPayload({
  required PatchbaySemanticsAction action,
  required int nodeId,
  required int generation,
  required Object error,
  String? identifier,
}) => <String, Object?>{
  'outcome': 'failed',
  'source': PatchbayFactSource.uiObserved.name,
  'identifier': ?identifier,
  'nodeId': nodeId,
  'generation': generation,
  'action': action.name,
  'failureType': error.runtimeType.toString(),
};
