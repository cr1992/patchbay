import 'dart:async';

import 'facts.dart';
import 'generated/core_wire.g.dart';

enum PatchbayJobPhase { running, completed, failed, cancelled }

final class PatchbayJobEvent {
  const PatchbayJobEvent({
    required this.sequence,
    required this.at,
    required this.phase,
    required this.source,
    this.operation,
    this.payload = const <String, Object?>{},
    this.reason,
  });

  final int sequence;
  final DateTime at;
  final PatchbayJobPhase phase;
  final PatchbayFactSource source;
  final String? operation;
  final Map<String, Object?> payload;
  final String? reason;

  PatchbayJobEventWire _toWire() => PatchbayJobEventWire(
    sequence: sequence,
    at: at.toIso8601String(),
    phase: switch (phase) {
      PatchbayJobPhase.running => PatchbayJobPhaseWire.running,
      PatchbayJobPhase.completed => PatchbayJobPhaseWire.completed,
      PatchbayJobPhase.failed => PatchbayJobPhaseWire.failed,
      PatchbayJobPhase.cancelled => PatchbayJobPhaseWire.cancelled,
    },
    source: _factSourceWire(source),
    operation: operation,
    payload: payload,
    reason: reason,
  );

  Map<String, Object?> toJson() => _toWire().toJson();
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

  Map<String, Object?> toJson() => PatchbayJobSnapshotWire(
    jobId: jobId,
    terminal: terminal,
    events: events.map((event) => event._toWire()).toList(growable: false),
  ).toJson();

  PatchbayJobSnapshotWire _toWire() =>
      PatchbayJobSnapshotWire.fromJson(toJson());
}

enum PatchbayJobWaitOutcome { changed, timedOut }

final class PatchbayJobWaitResult {
  const PatchbayJobWaitResult({required this.outcome, required this.snapshot});

  final PatchbayJobWaitOutcome outcome;
  final PatchbayJobSnapshot snapshot;

  Map<String, Object?> toJson() => PatchbayJobWaitResultWire(
    outcome: switch (outcome) {
      PatchbayJobWaitOutcome.changed => PatchbayJobWaitOutcomeWire.changed,
      PatchbayJobWaitOutcome.timedOut => PatchbayJobWaitOutcomeWire.timedOut,
    },
    snapshot: snapshot._toWire(),
  ).toJson();
}

PatchbayFactSourceWire _factSourceWire(PatchbayFactSource value) =>
    switch (value) {
      PatchbayFactSource.appRecorded => PatchbayFactSourceWire.appRecorded,
      PatchbayFactSource.commandEcho => PatchbayFactSourceWire.commandEcho,
      PatchbayFactSource.deviceReported =>
        PatchbayFactSourceWire.deviceReported,
      PatchbayFactSource.uiObserved => PatchbayFactSourceWire.uiObserved,
      PatchbayFactSource.unknown => PatchbayFactSourceWire.unknown,
    };

typedef PatchbayJobBody = Future<Map<String, Object?>> Function();
typedef PatchbayJobCancellation = FutureOr<void> Function();

/// A consumer-observed domain failure whose payload is already redacted.
///
/// Generic exceptions are deliberately reduced to `errorType`. Consumers may
/// throw this only when they have a stable reason and a payload that is safe to
/// cross the debug protocol boundary.
final class PatchbayJobFailure implements Exception {
  const PatchbayJobFailure({required this.reason, this.payload = const {}});

  final String reason;
  final Map<String, Object?> payload;
}

/// A consumer-observed domain cancellation whose payload is already redacted.
final class PatchbayJobCancellationSignal implements Exception {
  const PatchbayJobCancellationSignal({
    required this.reason,
    this.payload = const {},
  });

  final String reason;
  final Map<String, Object?> payload;
}

/// In-isolate job ledger for operations whose completion cannot be represented
/// honestly by the admission response.
final class PatchbayJobRegistry {
  PatchbayJobRegistry({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, _PatchbayJobRecord> _records =
      <String, _PatchbayJobRecord>{};
  int _nextJob = 0;

  String start({
    required PatchbayFactSource source,
    String? operation,
    required PatchbayJobBody body,
    PatchbayJobCancellation? cancel,
  }) {
    final String jobId = 'patchbay-job-${++_nextJob}';
    final _PatchbayJobRecord record = _PatchbayJobRecord(
      cancel: cancel,
      operation: operation,
    );
    _records[jobId] = record;
    _append(
      record,
      PatchbayJobPhase.running,
      source: source,
      operation: operation,
    );
    unawaited(_run(record, source: source, operation: operation, body: body));
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

  /// Waits without polling for a terminal state or an event strictly after
  /// [afterSequence]. A timeout is a typed result, while an unknown job stays
  /// `null` so consumers can return `jobNotFound` honestly.
  Future<PatchbayJobWaitResult?> waitForChange(
    String jobId, {
    required int afterSequence,
    required Duration timeout,
  }) async {
    if (afterSequence < 0 || timeout <= Duration.zero) {
      throw ArgumentError(
        'afterSequence must be non-negative and timeout positive.',
      );
    }
    final _PatchbayJobRecord? record = _records[jobId];
    if (record == null) return null;
    PatchbayJobSnapshot current() => PatchbayJobSnapshot(
      jobId: jobId,
      events: List<PatchbayJobEvent>.unmodifiable(record.events),
    );
    final PatchbayJobSnapshot initial = current();
    final int latestSequence = initial.events.isEmpty
        ? 0
        : initial.events.last.sequence;
    if (initial.terminal || latestSequence > afterSequence) {
      return PatchbayJobWaitResult(
        outcome: PatchbayJobWaitOutcome.changed,
        snapshot: initial,
      );
    }

    final Completer<void> waiter = Completer<void>();
    record.waiters.add(waiter);
    final PatchbayJobSnapshot afterRegistration = current();
    final int sequenceAfterRegistration = afterRegistration.events.isEmpty
        ? 0
        : afterRegistration.events.last.sequence;
    if (afterRegistration.terminal ||
        sequenceAfterRegistration > afterSequence) {
      record.waiters.remove(waiter);
      return PatchbayJobWaitResult(
        outcome: PatchbayJobWaitOutcome.changed,
        snapshot: afterRegistration,
      );
    }
    final Completer<bool> timedOut = Completer<bool>();
    final Timer timer = Timer(timeout, () => timedOut.complete(false));
    try {
      final bool changed = await Future.any<bool>(<Future<bool>>[
        waiter.future.then((_) => true),
        timedOut.future,
      ]);
      final PatchbayJobSnapshot result = current();
      final int resultSequence = result.events.isEmpty
          ? 0
          : result.events.last.sequence;
      return PatchbayJobWaitResult(
        outcome: changed || result.terminal || resultSequence > afterSequence
            ? PatchbayJobWaitOutcome.changed
            : PatchbayJobWaitOutcome.timedOut,
        snapshot: result,
      );
    } finally {
      timer.cancel();
      record.waiters.remove(waiter);
    }
  }

  Future<bool> cancel(String jobId, {String reason = 'cancelled'}) async {
    final _PatchbayJobRecord? record = _records[jobId];
    if (record == null || _terminal(record)) return false;
    await record.cancel?.call();
    if (!_terminal(record)) {
      _append(
        record,
        PatchbayJobPhase.cancelled,
        source: PatchbayFactSource.appRecorded,
        operation: record.operation,
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
    required PatchbayFactSource source,
    String? operation,
    required PatchbayJobBody body,
  }) async {
    try {
      final Map<String, Object?> payload = await body();
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.completed,
        source: source,
        operation: operation,
        payload: payload,
      );
    } on PatchbayJobCancellationSignal catch (cancellation) {
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.cancelled,
        source: source,
        operation: operation,
        payload: cancellation.payload,
        reason: cancellation.reason,
      );
    } on PatchbayJobFailure catch (failure) {
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.failed,
        source: source,
        operation: operation,
        payload: failure.payload,
        reason: failure.reason,
      );
    } catch (error) {
      if (_terminal(record)) return;
      _append(
        record,
        PatchbayJobPhase.failed,
        source: source,
        operation: operation,
        payload: <String, Object?>{'errorType': error.runtimeType.toString()},
        // Exceptions may embed credentials, device identifiers, or vendor
        // response bodies. The generic ledger records only the stable type;
        // consumers may throw PatchbayJobFailure with an explicitly redacted
        // domain reason and payload when that is safe.
        reason: 'operationFailed',
      );
    }
  }

  void _append(
    _PatchbayJobRecord record,
    PatchbayJobPhase phase, {
    required PatchbayFactSource source,
    String? operation,
    Map<String, Object?> payload = const <String, Object?>{},
    String? reason,
  }) {
    record.events.add(
      PatchbayJobEvent(
        sequence: record.events.length + 1,
        at: _now(),
        phase: phase,
        source: source,
        operation: operation,
        payload: payload,
        reason: reason,
      ),
    );
    for (final Completer<void> waiter in record.waiters.toList(
      growable: false,
    )) {
      if (!waiter.isCompleted) waiter.complete();
    }
    record.waiters.clear();
  }

  static bool _terminal(_PatchbayJobRecord record) =>
      record.events.isNotEmpty &&
      record.events.last.phase != PatchbayJobPhase.running;
}

final class _PatchbayJobRecord {
  _PatchbayJobRecord({required this.cancel, required this.operation});

  final PatchbayJobCancellation? cancel;
  final String? operation;
  final List<PatchbayJobEvent> events = <PatchbayJobEvent>[];
  final Set<Completer<void>> waiters = <Completer<void>>{};
}
