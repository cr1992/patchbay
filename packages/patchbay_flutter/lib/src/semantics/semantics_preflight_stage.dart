// PB-050-38：准入管线的**前置围栏阶段**——生命周期复核与 gate 求值。
//
// 两者放在一个文件里，因为它们回答同一件事：这次请求在触碰语义树之前是否还该
// 继续。管线里它们各出现两次（门前一次、声明门与其 await 之后一次），做成可复用
// 的单元正是为了那两处**不可能**写成两套判据——DG-060-04 冻结的顺序里，
// 「声明 gate 的 await 恰恰是现场变化的窗口」，所以门后必须再问一遍。
//
// 两个入口都用 `null 表示放行`：拒绝时返回的是一个已成形的 [PatchbayInvocation]，
// 调用方原样 return 即可，不需要再决定拒绝长什么样。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';

import '../lifecycle.dart';
import 'semantics_evidence.dart';

/// 生命周期围栏。
///
/// 判定与诊断刻意分成两个接缝：[_isAppResumed] 说这次请求是否受理，
/// [_lifecycleState] 只负责说清被拒时 App 处于哪个状态。
final class PatchbaySemanticsLifecycleFence {
  const PatchbaySemanticsLifecycleFence({
    required this._isAppResumed,
    required this._lifecycleState,
  });

  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;

  /// 放行返回 `null`；否则返回已成形的 `uiLifecycleNotResumed` 拒绝。
  PatchbayInvocation? evaluate(String requestId) => _isAppResumed()
      ? null
      : patchbaySemanticsLifecycleRejected(requestId, _lifecycleState);
}

/// gate 围栏：base gate 与 descriptor 声明门共用同一条求值。
///
/// 放行返回 `null`；否则返回已带 `gateId` 的拒绝。
Future<PatchbayInvocation?> patchbaySemanticsGateFence(
  PatchbayGateEvaluator gates, {
  required String requestId,
  required Set<String> gateIds,
}) async {
  final PatchbayGateRejection? gate = await gates.evaluate(gateIds);
  return gate == null ? null : patchbaySemanticsGateRejected(requestId, gate);
}
