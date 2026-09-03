import 'dart:async';
import 'dart:collection';

import '../audit.dart';

const Duration _maxAuditDrainTimeout = Duration(seconds: 30);

void validateAuditQueueCapacity(int capacity) {
  if (capacity < 1 || capacity > 4096) {
    throw RangeError.range(capacity, 1, 4096, 'auditQueueCapacity');
  }
}

void validateAuditDrainTimeout(Duration timeout) {
  if (timeout.isNegative || timeout > _maxAuditDrainTimeout) {
    throw RangeError.range(
      timeout.inMicroseconds,
      0,
      _maxAuditDrainTimeout.inMicroseconds,
      'timeout.inMicroseconds',
    );
  }
}

final class AuditDispatcher {
  AuditDispatcher({
    required PatchbayAuditSink sink,
    required int capacity,
    PatchbayAuditSinkErrorHandler? onError,
  }) : _sink = sink,
       _capacity = capacity,
       _onError = onError;

  final PatchbayAuditSink _sink;
  final int _capacity;
  final PatchbayAuditSinkErrorHandler? _onError;
  final ListQueue<_AuditDeliveryItem> _waiting =
      ListQueue<_AuditDeliveryItem>();

  _AuditDeliveryState _state = _AuditDeliveryState.open;
  _AuditDeliveryItem? _active;
  _AuditOverflowBurst? _overflowBurst;
  bool _pumpRunning = false;
  int _settledCount = 0;
  int _overflowDroppedCount = 0;
  Completer<PatchbayAuditDrainResult>? _terminal;
  Timer? _drainTimer;

  int get _pendingCount => (_active == null ? 0 : 1) + _waiting.length;

  void enqueue(PatchbayAuditEvent event, int sequence) {
    if (_state != _AuditDeliveryState.open) {
      _report(
        PatchbayAuditDeliveryClosed(sequence: sequence),
        StackTrace.current,
        event,
      );
      return;
    }
    if (_pendingCount >= _capacity) {
      _overflowDroppedCount += 1;
      final _AuditOverflowBurst? burst = _overflowBurst;
      if (burst == null) {
        _overflowBurst = _AuditOverflowBurst(
          firstEvent: event,
          firstSequence: sequence,
          lastSequence: sequence,
          droppedCount: 1,
        );
      } else {
        burst.lastSequence = sequence;
        burst.droppedCount += 1;
      }
      return;
    }

    _finishOverflowBurst();
    _waiting.addLast(_AuditDeliveryItem(event));
    _startPump();
  }

  Future<PatchbayAuditDrainResult> drain(Duration timeout) {
    final Completer<PatchbayAuditDrainResult>? existing = _terminal;
    if (existing != null) return existing.future;
    validateAuditDrainTimeout(timeout);

    final Completer<PatchbayAuditDrainResult> terminal =
        Completer<PatchbayAuditDrainResult>();
    _terminal = terminal;
    _state = _AuditDeliveryState.draining;
    _finishOverflowBurst();
    if (_pendingCount == 0) {
      _completeDrained();
    } else if (timeout == Duration.zero) {
      _completeTimedOut();
    } else {
      _drainTimer = Timer(timeout, _completeTimedOut);
    }
    return terminal.future;
  }

  void _startPump() {
    if (_pumpRunning) return;
    _pumpRunning = true;
    scheduleMicrotask(() => unawaited(_pump()));
  }

  Future<void> _pump() async {
    while (_waiting.isNotEmpty && _state != _AuditDeliveryState.closed) {
      final _AuditDeliveryItem item = _waiting.removeFirst();
      _active = item;
      try {
        await Future<void>.sync(() => _sink(item.event));
      } on Object catch (error, stackTrace) {
        _report(error, stackTrace, item.event);
      }

      _active = null;
      if (_state == _AuditDeliveryState.closed) {
        _pumpRunning = false;
        return;
      }
      _settledCount += 1;
    }
    _pumpRunning = false;
    if (_state == _AuditDeliveryState.draining && _pendingCount == 0) {
      _completeDrained();
    }
  }

  void _completeDrained() {
    if (_state == _AuditDeliveryState.closed) return;
    _state = _AuditDeliveryState.closed;
    _drainTimer?.cancel();
    _terminal!.complete(
      PatchbayAuditDrainResult(
        outcome: PatchbayAuditDrainOutcome.drained,
        settledCount: _settledCount,
        overflowDroppedCount: _overflowDroppedCount,
        abandonedCount: 0,
      ),
    );
  }

  void _completeTimedOut() {
    if (_state == _AuditDeliveryState.closed) return;
    final int abandonedCount = _pendingCount;
    _state = _AuditDeliveryState.closed;
    _waiting.clear();
    _drainTimer?.cancel();
    _terminal!.complete(
      PatchbayAuditDrainResult(
        outcome: PatchbayAuditDrainOutcome.timedOut,
        settledCount: _settledCount,
        overflowDroppedCount: _overflowDroppedCount,
        abandonedCount: abandonedCount,
      ),
    );
  }

  void _finishOverflowBurst() {
    final _AuditOverflowBurst? burst = _overflowBurst;
    if (burst == null) return;
    _overflowBurst = null;
    _report(
      PatchbayAuditDeliveryOverflow(
        droppedCount: burst.droppedCount,
        firstSequence: burst.firstSequence,
        lastSequence: burst.lastSequence,
        capacity: _capacity,
      ),
      StackTrace.current,
      burst.firstEvent,
    );
  }

  /// Reports a defect through the same observer as delivery failures,
  /// without touching delivery state — the defect is about how [event] was
  /// built (PB-050-26's `executionDetails` projection), not about whether it
  /// reaches the sink.
  void reportProjectionDefect(
    Object error,
    StackTrace stackTrace,
    PatchbayAuditEvent event,
  ) => _report(error, stackTrace, event);

  void _report(Object error, StackTrace stackTrace, PatchbayAuditEvent event) {
    final PatchbayAuditSinkErrorHandler? observer = _onError;
    if (observer == null) return;
    Timer.run(() {
      try {
        observer(error, stackTrace, event);
      } on Object {
        // Audit observer failures cannot alter delivery or command results.
      }
    });
  }
}

enum _AuditDeliveryState { open, draining, closed }

final class _AuditDeliveryItem {
  const _AuditDeliveryItem(this.event);

  final PatchbayAuditEvent event;
}

final class _AuditOverflowBurst {
  _AuditOverflowBurst({
    required this.firstEvent,
    required this.firstSequence,
    required this.lastSequence,
    required this.droppedCount,
  });

  final PatchbayAuditEvent firstEvent;
  final int firstSequence;
  int lastSequence;
  int droppedCount;
}
