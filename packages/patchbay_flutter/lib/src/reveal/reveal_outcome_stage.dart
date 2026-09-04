// PB-050-38：受理后**终态的投影**。
//
// 从 `reveal_engine.dart` 拆出来。引擎决定「因为什么停下」，本文件决定「停下
// 时那条 reason 该带哪些字段」——终止时目标已挂载就带 nodeId / generation，
// 未挂载就不带，这条「不出现」本身是 payload 契约，由
// `reveal_engine_characterization_test.dart` 逐字节钉住。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import '../semantics/semantics_bridge.dart';
import 'reveal_models.dart';

/// 把一个受理后 [reason] 投影成终态。
///
/// [node] 是终止那一刻目标在树上的样子（未挂载即 null）；generation 只在挂载
/// 时才问 [semantics]，因为未挂载的节点没有可 pin 的代际。
PatchbayRevealOutcome patchbayRevealFailedOutcome(
  String reason, {
  required SemanticsNode? node,
  required PatchbaySemanticsBridge semantics,
  String? failureType,
  String? gateId,
  String? gateCode,
}) => PatchbayRevealOutcome.failed(
  reason,
  nodeId: node?.id,
  generation: node == null ? null : semantics.observe(node).generation,
  failureType: failureType,
  gateId: gateId,
  gateCode: gateCode,
);
