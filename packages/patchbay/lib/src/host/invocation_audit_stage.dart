// PB-050-38 / DG-060-04：admission pipeline 的 **audit projection 阶段**。
//
// 这一阶段是 pipeline 的出口，也是唯一一处把内部准入事实写成对外可读记录的地方：
// `admissionStage` / `gateDisposition` / `executionDetails` 只进 host-only 的
// `PatchbayAuditEvent`，不进 invocation envelope，也不进 rejection details。
//
// 账本自己持有环形上限、投递序号与 `AuditDispatcher`，因为这三件事必须一起变：
// 序号是投递侧的，环形上限是本地 `auditEvents` 的，而 sink 抛错时的缺陷上报又要
// 拿到刚构造好的那个事件。把它们分开放会让「记了但没投」或「投了但序号错位」变成
// 两个文件之间的约定。
//
// 越界投影的处理在 `audit_execution_details.dart`（PB-050-26），本文件只负责
// 落账与投递。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import '../audit.dart';
import 'audit_dispatcher.dart';
import 'audit_execution_details.dart';

/// host 保留的最近 256 条脱敏命令事实，以及它们的投递。
final class PatchbayInvocationAuditLedger {
  PatchbayInvocationAuditLedger({
    required PatchbayAuditSink? sink,
    required PatchbayAuditSinkErrorHandler? onSinkError,
    required int capacity,
  }) {
    validateAuditQueueCapacity(capacity);
    _dispatcher = sink == null
        ? null
        : AuditDispatcher(sink: sink, capacity: capacity, onError: onSinkError);
  }

  static const int retainedEvents = 256;

  late final AuditDispatcher? _dispatcher;
  Future<PatchbayAuditDrainResult>? _emptyDrain;
  final List<PatchbayAuditEvent> _events = <PatchbayAuditEvent>[];
  var _nextSequence = 1;

  List<PatchbayAuditEvent> get events =>
      List<PatchbayAuditEvent>.unmodifiable(_events);

  Future<PatchbayAuditDrainResult> drain(Duration timeout) {
    final AuditDispatcher? dispatcher = _dispatcher;
    if (dispatcher != null) return dispatcher.drain(timeout);
    final Future<PatchbayAuditDrainResult>? existing = _emptyDrain;
    if (existing != null) return existing;
    validateAuditDrainTimeout(timeout);
    return _emptyDrain = Future<PatchbayAuditDrainResult>.value(
      const PatchbayAuditDrainResult(
        outcome: PatchbayAuditDrainOutcome.drained,
        settledCount: 0,
        overflowDroppedCount: 0,
        abandonedCount: 0,
      ),
    );
  }

  void record({
    required String command,
    required String requestId,
    required Map<String, Object?> arguments,
    required String gateResult,
    required Map<String, Object?> response,
    String admissionStage = 'dispatch',
    String gateDisposition = 'notReached',
  }) {
    final PatchbayAuditEvent event = projectAuditEventAndReportDefects(
      dispatcher: _dispatcher,
      command: command,
      requestId: requestId,
      arguments: arguments,
      gateResult: gateResult,
      response: response,
      admissionStage: admissionStage,
      gateDisposition: gateDisposition,
    );
    if (_events.length == retainedEvents) _events.removeAt(0);
    _events.add(event);
    _dispatcher?.enqueue(event, _nextSequence);
    _nextSequence += 1;
  }
}
