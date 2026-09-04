// PB-050-38：准入管线的 **policy 阶段**与**门后复核阶段**。
//
// 它们是同一个判据的两次求值，所以摆在一起：门前一次决定「要不要放行、声明哪些
// 门、算不算敏感输入」，声明门的 await 之后再求一次，并逐字比对两次结论是否还是
// 同一个——DG-060-04 的 post-await recheck。两次之间只要声明集或 `sensitiveInput`
// 变了，就按 `uiSemanticsPolicyChanged` fail-closed，而不是拿新结论继续派发。
//
// 门前那次把声明集**复制**下来（而不是留住 consumer 的那个 `Set` 对象），复核比的
// 才是「策略换了结论」而不是「同一个对象被就地改了」。
//
// 两个阶段都是**同步纯函数**：它们不 await、不碰语义树、不发代际，因此可以在测试
// 里直接构造目标与策略逐条注入失败。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/foundation.dart';
import 'package:patchbay/patchbay_host.dart';

import 'semantics_evidence.dart';
import 'semantics_models.dart';

/// 门前 policy 阶段的结论。[rejection] 为空表示放行。
final class PatchbaySemanticsPolicyAdmission {
  const PatchbaySemanticsPolicyAdmission.admitted({
    required this.gateIds,
    required this.sensitiveInput,
    required this.sensitive,
  }) : rejection = null;

  const PatchbaySemanticsPolicyAdmission.rejected(
    PatchbayInvocation this.rejection,
  ) : gateIds = const <String>{},
      sensitiveInput = false,
      sensitive = false;

  final PatchbayInvocation? rejection;

  /// 门前声明集的**副本**，供门后复核逐字比对。
  final Set<String> gateIds;

  /// 门前 policy 自报的 `sensitiveInput` 读数，同样只用于复核比对。
  final bool sensitiveInput;

  /// 目标遮蔽或策略声明敏感——两者任一成立即算敏感输入。
  final bool sensitive;

  bool get admitted => rejection == null;
}

/// 门前 policy 与随之而来的文本/敏感输入判据。
///
/// 求值顺序是冻结的：policy 结论 → 声明集与敏感位快照 → `setText` 的文本必备与
/// stdin 要求 → 非 `setText` 不得携带文本。
PatchbaySemanticsPolicyAdmission patchbaySemanticsAdmitPolicy({
  required String requestId,
  required PatchbaySemanticsActionPolicy policy,
  required PatchbaySemanticsTarget target,
  required PatchbaySemanticsAction action,
  required String? text,
  required bool inputWasStdin,
}) {
  final PatchbaySemanticsActionDecision decision = policy(target, action);
  if (!decision.allowed) {
    return PatchbaySemanticsPolicyAdmission.rejected(
      patchbaySemanticsPolicyRejected(requestId, decision),
    );
  }
  final Set<String> initialGateIds = Set<String>.of(decision.gateIds);
  final bool sensitive = target.obscured || decision.sensitiveInput;
  if (action == PatchbaySemanticsAction.setText) {
    if (text == null) {
      return PatchbaySemanticsPolicyAdmission.rejected(
        PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(code: 'uiSemanticsTextRequired'),
        ),
      );
    }
    if (sensitive && !inputWasStdin) {
      return PatchbaySemanticsPolicyAdmission.rejected(
        PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(
            code: 'sensitiveInputRequiresStdin',
          ),
        ),
      );
    }
  } else if (text != null) {
    return PatchbaySemanticsPolicyAdmission.rejected(
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsUnexpectedText'),
      ),
    );
  }
  return PatchbaySemanticsPolicyAdmission.admitted(
    gateIds: initialGateIds,
    sensitiveInput: decision.sensitiveInput,
    sensitive: sensitive,
  );
}

/// 门后复核阶段的结论。[rejection] 为空表示放行。
final class PatchbaySemanticsRevalidation {
  const PatchbaySemanticsRevalidation.admitted({required this.sensitive})
    : rejection = null;

  const PatchbaySemanticsRevalidation.rejected(
    PatchbayInvocation this.rejection,
  ) : sensitive = false;

  final PatchbayInvocation? rejection;

  /// 门前与门后两次读数的并——敏感只会变严，不会因为复核而变松。
  final bool sensitive;

  bool get admitted => rejection == null;
}

/// 声明门 await 之后的二次复核。
///
/// 输入是**重新解析**得到的 [resolution]：这一段刻意不自己去解析，解析是上一个
/// 阶段的职责，复核只负责判断「重新解析出来的现场，还是不是门前那个现场」。
PatchbaySemanticsRevalidation patchbaySemanticsRevalidate({
  required String requestId,
  required PatchbaySemanticsActionPolicy policy,
  required PatchbaySemanticsAction action,
  required PatchbaySemanticsPolicyAdmission admitted,
  required PatchbaySemanticsResolution resolution,
  required bool inputWasStdin,
}) {
  if (!resolution.resolved) {
    return PatchbaySemanticsRevalidation.rejected(
      patchbaySemanticsResolutionRejected(requestId, resolution),
    );
  }
  final PatchbaySemanticsActionDecision decision = policy(
    resolution.target!,
    action,
  );
  if (!decision.allowed) {
    return PatchbaySemanticsRevalidation.rejected(
      patchbaySemanticsPolicyRejected(requestId, decision),
    );
  }
  if (!setEquals(admitted.gateIds, decision.gateIds) ||
      admitted.sensitiveInput != decision.sensitiveInput) {
    return PatchbaySemanticsRevalidation.rejected(
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiSemanticsPolicyChanged'),
      ),
    );
  }
  final bool sensitive = admitted.sensitive || resolution.target!.obscured;
  if (action == PatchbaySemanticsAction.setText &&
      sensitive &&
      !inputWasStdin) {
    return PatchbaySemanticsRevalidation.rejected(
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'sensitiveInputRequiresStdin'),
      ),
    );
  }
  return PatchbaySemanticsRevalidation.admitted(sensitive: sensitive);
}
