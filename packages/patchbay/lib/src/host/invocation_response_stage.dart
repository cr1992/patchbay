// PB-050-38 / DG-060-04：admission pipeline 的 **response validation 阶段**。
//
// handler 交回来的信封在这里才被当作数据检查：先解析与结构违规（信封形状、
// schemaVersion、requestId 一致性、admission 与 rejection/payload/jobId 的语义
// 组合），再按目录声明校验 accepted 载荷的 responseSchema 与执行证据契约。
//
// 顺序是冻结的，而且**结构先于内容**：一个连信封都不成立的答复不该先收到字段级
// 的 schema 诊断。`schemaMode` 只有在结构校验全过之后才有意义，因此它只出现在
// 这一阶段末尾的两条路径上。
//
// 阶段是同步纯函数（唯一的外部事实 `nowMs` 以闭包注入，且只在真的要校验执行证据
// 时才求值），所以任意一种越界载荷都可以直接构造并单独断言。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import '../execution_evidence.dart';
import '../generated/core_wire.g.dart';
import '../response_schema.dart';
import 'invocation_admission_state.dart';
import 'invocation_rejections.dart';

/// 校验 handler 的信封并投影最终应答。
///
/// [nowMs] 只在 accepted 且声明了执行证据契约时才被调用——把它做成闭包而不是值，
/// 是为了让「什么时候读时钟」与拆分前逐字一致。
Map<String, Object?> patchbayValidateInvocationResponse({
  required Map<String, Object?> result,
  required String requestId,
  required bool registered,
  required PatchbayResponseSchema? responseSchema,
  required PatchbayExecutionContract? executionContract,
  required int Function() nowMs,
  PatchbayInvocationAuditState? audit,
}) {
  final String? handlerAdmissionStage = audit?.admissionStage;
  final PatchbayInvocationWire wire;
  try {
    audit?.admissionStage = 'responseValidation';
    wire = PatchbayInvocationWire.fromJson(result);
  } on FormatException {
    return patchbayInvalidInvocationEnvelope(requestId, 'malformedEnvelope');
  }
  if (wire.schemaVersion != 1) {
    return patchbayInvalidInvocationEnvelope(
      requestId,
      'schemaVersionMismatch',
    );
  }
  if (wire.requestId != requestId) {
    return patchbayInvalidInvocationEnvelope(requestId, 'requestIdMismatch');
  }
  final String? semanticViolation = patchbayInvocationSemanticViolation(wire);
  if (semanticViolation != null) {
    return patchbayInvalidInvocationEnvelope(requestId, semanticViolation);
  }
  if (registered &&
      wire.admission == PatchbayAdmissionWire.rejected &&
      (handlerAdmissionStage == 'uiPreflight' ||
          handlerAdmissionStage == 'operationPolicy')) {
    audit?.admissionStage = handlerAdmissionStage!;
  }
  PatchbayExecutionValidationResult executionValidation =
      const PatchbayExecutionValidationResult();
  if (wire.admission == PatchbayAdmissionWire.accepted) {
    if (responseSchema != null) {
      final List<PatchbayResponseValidationIssue> issues =
          validatePatchbayResponsePayload(
            responseSchema.accepted,
            wire.payload,
          );
      if (issues.isNotEmpty) {
        return <String, Object?>{
          ...patchbayResponseSchemaViolation(requestId, issues),
          'schemaMode': 'validated',
        };
      }
    }
    if (executionContract != null) {
      executionValidation = validatePatchbayExecutionEvidence(
        executionContract,
        wire.payload,
        nowMs: nowMs(),
      );
      if (executionValidation.issues.isNotEmpty) {
        return <String, Object?>{
          ...patchbayResponseSchemaViolation(
            requestId,
            executionValidation.issues,
          ),
          'schemaMode': responseSchema == null
              ? 'legacyUnvalidated'
              : 'validated',
        };
      }
    }
  }
  return patchbayWithExecutionDetails(<String, Object?>{
    ...result,
    'schemaMode': responseSchema == null ? 'legacyUnvalidated' : 'validated',
  }, executionValidation);
}

/// 信封内部的语义组合违规，`null` 表示无违规。
String? patchbayInvocationSemanticViolation(PatchbayInvocationWire wire) {
  if (wire.requestId.isEmpty) return 'emptyRequestId';
  if (wire.jobId != null && wire.jobId!.isEmpty) return 'emptyJobId';
  switch (wire.admission) {
    case PatchbayAdmissionWire.accepted:
      if (wire.rejection != null) return 'acceptedWithRejection';
    case PatchbayAdmissionWire.rejected:
      final PatchbayRejectionWire? rejection = wire.rejection;
      if (rejection == null) return 'rejectedWithoutRejection';
      if (rejection.code.isEmpty) return 'emptyRejectionCode';
      if (wire.jobId != null) return 'rejectedWithJobId';
      if (wire.payload.isNotEmpty) return 'rejectedWithPayload';
      if (wire.notice != rejection.notice) return 'rejectionNoticeMismatch';
  }
  return null;
}

/// 把「老式 dispatched 与执行证据冲突」这一条事实补进 details。
Map<String, Object?> patchbayWithExecutionDetails(
  Map<String, Object?> response,
  PatchbayExecutionValidationResult validation,
) {
  if (!validation.legacyDispatchedConflict) return response;
  final Object? existing = response['details'];
  return <String, Object?>{
    ...response,
    'details': <String, Object?>{
      if (existing is Map<Object?, Object?>)
        for (final MapEntry<Object?, Object?> entry in existing.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      'legacyDispatchedConflict': true,
    },
  };
}
