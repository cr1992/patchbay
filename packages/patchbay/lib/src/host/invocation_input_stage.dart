// PB-050-38 / DG-060-04：admission pipeline 的 **sensitive input 阶段**。
//
// 它在任何门之前，理由不是效率而是语义：敏感参数走没走 stdin 是**输入形态**的
// 事实，与「这个调用者有没有权限」是两个问题。先问形态，授权判断才不会被一段
// 本就不该进程序的字面量带进来。
//
// 阶段是同步纯函数，且对空参数保持「原样放行、连阶段都不推进」的老行为——
// 没有参数就没有敏感参数可判，推进阶段会让审计谎报 pipeline 走过了一段并不存在
// 的判定。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import '../invocation.dart';
import 'host_models.dart';
import 'invocation_admission_state.dart';
import 'invocation_rejections.dart';

/// sensitive input 阶段的结论。[rejection] 非空表示拒绝。
final class PatchbayInputAdmission {
  const PatchbayInputAdmission.rejected(Map<String, Object?> this.rejection)
    : forwarded = const <String, Object?>{};

  const PatchbayInputAdmission.admitted(this.forwarded) : rejection = null;

  final Map<String, Object?>? rejection;

  /// 实际交给 handler 的参数：UI plane 保留 stdin 出处，domain plane 剥掉。
  final Map<String, Object?> forwarded;

  bool get admitted => rejection == null;
}

/// 判定敏感参数是否越过了 stdin 边界，并决定转发形态。
PatchbayInputAdmission patchbayAdmitInvocationInput({
  required String requestId,
  required PatchbayCommandPolicy policy,
  required Map<String, Object?> arguments,
  PatchbayInvocationAuditState? audit,
}) {
  if (arguments.isEmpty) return PatchbayInputAdmission.admitted(arguments);
  audit?.admissionStage = 'inputPolicy';
  final List<String> violations = policy.sensitiveViolations(arguments);
  if (violations.isNotEmpty) {
    return PatchbayInputAdmission.rejected(
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: 'sensitiveInputRequiresStdin',
          notice: 'Sensitive arguments are accepted only from stdin.',
          details: <String, Object?>{'parameters': violations},
        ),
      ).toJson(),
    );
  }
  return PatchbayInputAdmission.admitted(
    policy.retainsStdinProvenance
        ? arguments
        : patchbayWithoutStdinProvenance(arguments),
  );
}
