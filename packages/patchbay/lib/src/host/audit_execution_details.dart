// PB-050-26 / DG-060-04：host-only `executionDetails` 投影的落点胶水。
//
// `host_invoker.dart` 是结构热点（见 `docs/code-structure.md` 与
// `tool/structure_baseline.json`），本文件把「构建事件 + 在越界时通过既有
// `AuditDispatcher` error observer 报告投影缺陷」的组合逻辑单独放在这里，让
// `_recordAudit` 只多一次函数调用，不在热点文件里堆叠新分支。
import '../audit.dart';
import 'audit_dispatcher.dart';

/// Builds one [PatchbayAuditEvent] and, if PB-050-26's reveal
/// `executionDetails` projection found the response out of a DG-060-04
/// bound, reports the defect through [dispatcher]'s existing error observer.
///
/// [dispatcher] may be `null` — no audit sink configured is a legitimate
/// host setup, and `HostInvokerHandler.auditEvents` must still see accurate
/// events regardless of whether anything is listening for delivery errors.
/// The built event's `executionDetails` is always omitted on a defect either
/// way: this function only decides whether anyone is told why, never
/// whether the block is served truncated.
PatchbayAuditEvent projectAuditEventAndReportDefects({
  required AuditDispatcher? dispatcher,
  required String command,
  required String requestId,
  required Map<String, Object?> arguments,
  required String gateResult,
  required Map<String, Object?> response,
  required String admissionStage,
  required String gateDisposition,
}) {
  String? defectReason;
  final PatchbayAuditEvent event = patchbayProjectAuditEvent(
    command: command,
    requestId: requestId,
    arguments: arguments,
    gateResult: gateResult,
    response: response,
    admissionStage: admissionStage,
    gateDisposition: gateDisposition,
    onExecutionDetailsDefect: (String reason) => defectReason = reason,
  );
  final String? reason = defectReason;
  if (reason != null) {
    dispatcher?.reportProjectionDefect(
      PatchbayAuditExecutionDetailsProjectionDefect(
        command: command,
        requestId: requestId,
        reason: reason,
      ),
      StackTrace.current,
      event,
    );
  }
  return event;
}
