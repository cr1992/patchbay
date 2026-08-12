import 'dart:async';

enum PatchbayJobPhase { running, completed, failed, cancelled }

final class PatchbayJobEvent {
  const PatchbayJobEvent({
    required this.sequence,
    required this.at,
    required this.phase,
    required this.source,
    this.payload = const <String, Object?>{},
    this.reason,
  });

  final int sequence;
  final DateTime at;
  final PatchbayJobPhase phase;
  final String source;
  final Map<String, Object?> payload;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'sequence': sequence,
    'at': at.toIso8601String(),
    'phase': phase.name,
    'source': source,
    'payload': payload,
    if (reason != null) 'reason': reason,
  };
}

final class PatchbayJobSnapshot {
  const PatchbayJobSnapshot({required this.jobId, required this.events});

  final String jobId;
  final List<PatchbayJobEvent> events;

  bool get terminal =>
      events.isNotEmpty &&
      switch (events.last.phase) {
        PatchbayJobPhase.completed ||
        PatchbayJobPhase.failed ||
        PatchbayJobPhase.cancelled => true,
        PatchbayJobPhase.running => false,
      };

  Map<String, Object?> toJson() => <String, Object?>{
    'jobId': jobId,
    'terminal': terminal,
    'events': events
        .map((PatchbayJobEvent event) => event.toJson())
        .toList(growable: false),
  };
}

typedef PatchbayJobBody = Future<Map<String, Object?>> Function();
typedef PatchbayJobCancellation = FutureOr<void> Function();

/// In-isolate job ledger for operations whose completion cannot be represented
/// honestly by the admission response.
final class PatchbayJobRegistry {
  PatchbayJobRegistry({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, _PatchbayJobRecord> _records =
      <String, _PatchbayJobRecord>{};
  int _nextJob = 0;

  String start({
    required String source,
    required PatchbayJobBody body,
    PatchbayJobCancellation? cancel,
  }) {
    final String jobId = 'patchbay-job-${++_nextJob}';
    final _PatchbayJobRecord record = _PatchbayJobRecord(cancel: cancel);
    _records[jobId] = record;
    _append(record, PatchbayJobPhase.running, source: source);
    unawaited(_run(record, source: source, body: body));
    return jobId;
  }

  PatchbayJobSnapshot? snapshot(String jobId) {
    final _PatchbayJobRecord? record = _records[jobId];
    if (record == null) return null;
    return PatchbayJobSnapshot(
      jobId: jobId,
      events: List<PatchbayJobEvent>.unmodifiable(record.events),
    );
  }

  Future<bool> cancel(String jobId, {String reason = 'cancelled'}) async {
    final _PatchbayJobRecord? record = _records[jobId];
    if (record == null || _terminal(record)) return false;
    await record.cancel?.call();
    if (!_terminal(record)) {
      _append(
        record,
        PatchbayJobPhase.cancelled,
        source: 'appFlow',
        reason: reason,
      );
    }
    return true;
  }

  Future<void> cancelAll({required String reason}) async {
    for (final String jobId in _records.keys.toList(growable: false)) {
      await cancel(jobId, reason: reason);
    }
  }

  Future<void> _run(
    _PatchbayJobRecord record, {
    required String source,
    required PatchbayJobBody body,
  }) async {
    try {
      final Map<String, Object?> payload = await body();
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.completed,
        source: source,
        payload: payload,
      );
    } catch (error) {
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.failed,
        source: source,
        payload: <String, Object?>{'errorType': error.runtimeType.toString()},
        // Exceptions may embed credentials, device identifiers, or vendor
        // response bodies. The generic ledger records only the stable type;
        // consumers may return an explicitly redacted domain reason in a
        // successful payload when that is safe.
        reason: 'operationFailed',
      );
    }
  }

  void _append(
    _PatchbayJobRecord record,
    PatchbayJobPhase phase, {
    required String source,
    Map<String, Object?> payload = const <String, Object?>{},
    String? reason,
  }) {
    record.events.add(
      PatchbayJobEvent(
        sequence: record.events.length + 1,
        at: _now(),
        phase: phase,
        source: source,
        payload: payload,
        reason: reason,
      ),
    );
  }

  static bool _terminal(_PatchbayJobRecord record) =>
      record.events.isNotEmpty &&
      record.events.last.phase != PatchbayJobPhase.running;
}

final class _PatchbayJobRecord {
  _PatchbayJobRecord({required this.cancel});

  final PatchbayJobCancellation? cancel;
  final List<PatchbayJobEvent> events = <PatchbayJobEvent>[];
}
