// PB-050-38 / DG-060-04：admission pipeline 的 **dispatch 阶段**——handler 调用
// 与其两侧的现场复核。
//
// 这一阶段的实质不是「叫一下 handler」，而是**把 core 已经拿到的准入事实带进
// handler**：registry-owned handler 跑在一个 admission scope 里，scope 告诉它
// base gate 已过、哪些声明门已准入，于是 bridge 不会把同一条门评两遍；反过来，
// handler 侧只在 UI 现场才有的阶段（`uiPreflight` / `operationPolicy`）也经由
// scope 回流进 host-only 审计。
//
// handler 调用前后各复核一次取消冻结：DG-060-04 的「任一 await 后只做一次复核」
// 在这里落成两次，因为 handler 本身就是那个 await。
//
// 三个接缝都注入：registry、外部派发与冻结复核。测试因此可以让 handler 抛、让
// 外部派发超时、让复核在中途返回冻结应答，而不需要一台 host。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:async';

import '../audit.dart';
import '../command_registry.dart';
import '../gate_admission_scope.dart';
import '../invocation_cancellation.dart';
import 'host_models.dart';
import 'invocation_admission_state.dart';

/// dispatch 阶段的结论。
final class PatchbayHandlerDispatch {
  const PatchbayHandlerDispatch.frozen(Map<String, Object?> this.frozenResponse)
    : result = const <String, Object?>{},
      registered = false;

  const PatchbayHandlerDispatch.completed({
    required this.result,
    required this.registered,
  }) : frozenResponse = null;

  /// 取消冻结应答；非空表示这次调用在 handler 之前或之后被取消。
  final Map<String, Object?>? frozenResponse;

  /// handler 交回来的原始信封，尚未过 response validation。
  final Map<String, Object?> result;

  /// 是否由 registry 服务。它决定 response validation 里那条只对 registry
  /// handler 生效的 UI 阶段回填。
  final bool registered;
}

/// 复核 → registry 派发（带 admission scope）→ 外部回退 → 再复核。
Future<PatchbayHandlerDispatch> patchbayDispatchInvocationHandler({
  required PatchbayCommandRegistry registry,
  required String command,
  required Map<String, Object?> forwarded,
  required String requestId,
  required PatchbayInvocationContext context,
  required PatchbayCommandPolicy policy,
  required bool coreGateEvaluated,
  required void Function(String result) onGateResult,
  required Map<String, Object?>? Function() frozenCancellationResponse,
  required Future<Map<String, Object?>> Function() dispatchExternal,
  PatchbayInvocationAuditState? audit,
}) async {
  audit?.admissionStage = 'dispatch';
  final Map<String, Object?>? cancelledBeforeHandler =
      frozenCancellationResponse();
  if (cancelledBeforeHandler != null) {
    return PatchbayHandlerDispatch.frozen(cancelledBeforeHandler);
  }
  final Map<String, Object?>?
  registered = await runInPatchbayGateAdmissionScope<Map<String, Object?>?>(
    skipBase: coreGateEvaluated || !policy.writesSideEffect,
    admittedGateIds: coreGateEvaluated
        ? policy.declaredGates
        : const <String>{},
    onGateResult: onGateResult,
    onGateDisposition: (String value) {
      audit?.gateDisposition = value;
    },
    onAdmissionStage: (String value) {
      audit?.admissionStage = value;
    },
    body: () => registry.tryDispatch(
      command,
      forwarded,
      requestId,
      onGateResult: (String value) {
        // A registration with no legacy `_gate` reports `notDeclared`
        // before entering its handler. Do not let that erase a core
        // result; dynamic handler gates report through the scope above.
        if (!coreGateEvaluated || value == 'passed' || value == 'rejected') {
          onGateResult(value);
          if (audit != null && patchbayAuditGateDispositions.contains(value)) {
            audit.gateDisposition = value;
          }
        }
      },
      context: context,
    ),
  );
  final Map<String, Object?> result;
  if (registered != null) {
    result = registered;
  } else {
    result = await dispatchExternal();
  }
  final Map<String, Object?>? cancelledAfterHandler =
      frozenCancellationResponse();
  if (cancelledAfterHandler != null) {
    return PatchbayHandlerDispatch.frozen(cancelledAfterHandler);
  }
  return PatchbayHandlerDispatch.completed(
    result: result,
    registered: registered != null,
  );
}
