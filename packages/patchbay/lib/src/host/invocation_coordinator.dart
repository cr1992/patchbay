import 'dart:async';
import 'dart:collection';

import '../invocation.dart';
import '../invocation_cancellation.dart';

typedef PatchbayInvocationPipeline =
    Future<Map<String, Object?>> Function(PatchbayInvocationContext context);

final class InvocationCoordinator {
  InvocationCoordinator({
    required int maxConcurrentInvocations,
    required Duration confirmationTimeout,
    PatchbayMonotonicClock? clock,
  }) : _maxConcurrentInvocations = maxConcurrentInvocations,
       _confirmationTimeout = confirmationTimeout,
       _clock = clock ?? patchbayMonotonicNow {
    if (maxConcurrentInvocations < 1 || maxConcurrentInvocations > 256) {
      throw RangeError.range(
        maxConcurrentInvocations,
        1,
        256,
        'maxConcurrentInvocations',
      );
    }
    validateConfirmationTimeout(confirmationTimeout);
  }

  /// PB-050-38：这个数与 `PatchbayExternalInvocationLedger.slotCapacity`
  /// **同为 256** 是一条隐式耦合。正因为相等，第 257 次并发调用总是先撞上这里的
  /// `invocationRecordCapacityExceeded`，账本的 `requestLedgerFull` 才在整条 host
  /// 上端到端不可达（它只在账本阶段单测里直接构造出来）。
  /// 若两者不再相等，`requestLedgerFull` 变为可达，须补端到端测试。
  static const int activeOwnerCapacity = 256;
  static const int settledTombstoneCapacity = 256;
  static const Duration maximumDeadline = Duration(minutes: 5);

  final int _maxConcurrentInvocations;
  final Duration _confirmationTimeout;
  final PatchbayMonotonicClock _clock;
  final Map<(String, String), _InvocationOwner> _owners =
      <(String, String), _InvocationOwner>{};
  final ListQueue<_InvocationTombstone> _tombstones =
      ListQueue<_InvocationTombstone>();
  int _running = 0;
  bool _accepting = true;
  Future<PatchbayInvocationDrainResult>? _drainFuture;

  int get running => _running;
  int get activeOwners => _owners.length;

  PatchbayHostInvocationHandle start({
    required String command,
    required String requestId,
    required String? ownerToken,
    required Duration? deadline,
    required bool contextAware,
    required PatchbayInvocationPipeline pipeline,
    void Function(Map<String, Object?> response)? onCancellationResponse,
  }) {
    if (deadline != null &&
        (deadline <= Duration.zero || deadline > maximumDeadline)) {
      throw RangeError.range(
        deadline.inMilliseconds,
        1,
        maximumDeadline.inMilliseconds,
        'deadline.inMilliseconds',
      );
    }
    final String token = ownerToken ?? patchbayGenerateOwnerToken();
    if (!isValidPatchbayOwnerToken(token)) {
      throw ArgumentError.value(ownerToken, 'ownerToken', 'invalid token');
    }
    if (!_accepting) {
      return _immediate(
        _cancellationEnvelope(
          requestId,
          PatchbayInvocationCancellationReason.hostDisposed,
          'unsupported',
        ),
      );
    }
    final (String, String) key = (command, requestId);
    final _InvocationOwner? existing = _owners[key];
    if (existing != null) {
      return _immediate(
        _rejection(
          requestId,
          existing.ownerToken == token
              ? 'duplicateRequestId'
              : 'requestIdConflict',
        ),
      );
    }
    if (_owners.length >= activeOwnerCapacity) {
      return _immediate(
        _rejection(
          requestId,
          'invocationRecordCapacityExceeded',
          <String, Object?>{
            'limit': activeOwnerCapacity,
            'running': _owners.length,
          },
        ),
      );
    }
    if (_running >= _maxConcurrentInvocations) {
      return _immediate(
        _rejection(requestId, 'invocationCapacityExceeded', <String, Object?>{
          'limit': _maxConcurrentInvocations,
          'running': _running,
        }),
      );
    }

    late final _InvocationOwner owner;
    final PatchbayInvocationCancellationController cancellation =
        PatchbayInvocationCancellationController(
          requestId: requestId,
          clock: _clock,
          deadline: deadline,
          onConfirmed: () => _releaseExecution(owner),
        );
    owner = _InvocationOwner(
      command: command,
      requestId: requestId,
      ownerToken: token,
      contextAware: contextAware,
      cancellation: cancellation,
      onCancellationResponse: onCancellationResponse,
    );
    _owners[key] = owner;
    _running += 1;
    if (deadline != null) {
      owner.deadlineTimer = Timer(
        deadline,
        () => _requestCancellation(
          owner,
          PatchbayInvocationCancellationReason.callerDeadlineExceeded,
        ),
      );
    }
    Future<Map<String, Object?>>.sync(
      () => pipeline(cancellation.context),
    ).then<void>(
      (Map<String, Object?> value) => _settle(owner, value),
      onError: (Object error, StackTrace stackTrace) =>
          _settleError(owner, error, stackTrace),
    );
    return PatchbayHostInvocationHandle(
      response: owner.response.future,
      lifecycle: owner.lifecycle.future,
    );
  }

  Future<PatchbayInvocationCancellationResult> cancel({
    required String command,
    required String requestId,
    required String ownerToken,
    PatchbayInvocationCancellationReason reason =
        PatchbayInvocationCancellationReason.explicitRequest,
  }) async {
    if (!isValidPatchbayOwnerToken(ownerToken)) {
      return _unknown(command, requestId);
    }
    final _InvocationOwner? owner = _owners[(command, requestId)];
    if (owner == null || owner.ownerToken != ownerToken) {
      for (final _InvocationTombstone tombstone in _tombstones) {
        if (tombstone.command == command &&
            tombstone.requestId == requestId &&
            tombstone.ownerToken == ownerToken) {
          return PatchbayInvocationCancellationResult(
            command: command,
            requestId: requestId,
            outcome: PatchbayInvocationCancellationOutcome.settled,
          );
        }
      }
      return _unknown(command, requestId);
    }
    _requestCancellation(owner, reason);
    final PatchbayInvocationCancellationReason frozenReason =
        owner.cancellation.signal.reason!;
    if (!owner.contextAware) {
      return PatchbayInvocationCancellationResult(
        command: command,
        requestId: requestId,
        outcome: PatchbayInvocationCancellationOutcome.unsupported,
        reason: frozenReason,
      );
    }
    final PatchbayInvocationConfirmationState? state = await owner.cancellation
        .observe(_confirmationTimeout);
    if (state == null) {
      return PatchbayInvocationCancellationResult(
        command: command,
        requestId: requestId,
        outcome: PatchbayInvocationCancellationOutcome.confirmed,
        reason: frozenReason,
      );
    }
    return PatchbayInvocationCancellationResult(
      command: command,
      requestId: requestId,
      outcome: PatchbayInvocationCancellationOutcome.unconfirmed,
      reason: frozenReason,
      confirmation: state,
    );
  }

  Future<PatchbayInvocationDrainResult> drain(Duration timeout) {
    final Future<PatchbayInvocationDrainResult>? existing = _drainFuture;
    if (existing != null) return existing;
    validateConfirmationTimeout(timeout);
    _accepting = false;
    final List<_InvocationOwner> snapshot = _owners.values.toList(
      growable: false,
    );
    for (final _InvocationOwner owner in snapshot) {
      _requestCancellation(
        owner,
        PatchbayInvocationCancellationReason.hostDisposed,
      );
    }
    return _drainFuture = _finishDrain(snapshot, timeout);
  }

  Future<PatchbayInvocationDrainResult> _finishDrain(
    List<_InvocationOwner> owners,
    Duration timeout,
  ) async {
    if (owners.isNotEmpty && timeout != Duration.zero) {
      try {
        await Future.wait<void>(
          owners.map((_InvocationOwner owner) => owner.lifecycle.future),
        ).timeout(timeout);
      } on TimeoutException {
        // The immutable accounting below records the remaining owners.
      }
    }
    var settled = 0;
    var confirmed = 0;
    var abandoned = 0;
    for (final _InvocationOwner owner in owners) {
      if (owner.settled) {
        settled += 1;
      } else if (owner.cancellation.isConfirmed) {
        confirmed += 1;
      } else {
        abandoned += 1;
      }
    }
    return PatchbayInvocationDrainResult(
      outcome: abandoned == 0
          ? PatchbayInvocationDrainOutcome.drained
          : PatchbayInvocationDrainOutcome.timedOut,
      settledCount: settled,
      confirmedCount: confirmed,
      abandonedCount: abandoned,
    );
  }

  void _requestCancellation(
    _InvocationOwner owner,
    PatchbayInvocationCancellationReason reason,
  ) {
    owner.cancellation.request(reason);
    if (!owner.response.isCompleted) {
      final String state = !owner.contextAware
          ? 'unsupported'
          : owner.cancellation.isConfirmed
          ? 'confirmed'
          : 'requested';
      final Map<String, Object?> response = _cancellationEnvelope(
        owner.requestId,
        owner.cancellation.signal.reason!,
        state,
      );
      owner.frozenResponse = response;
      owner.response.complete(response);
      owner.onCancellationResponse?.call(response);
    }
  }

  Map<String, Object?>? frozenCancellationResponse(
    String command,
    String requestId,
  ) => _owners[(command, requestId)]?.frozenCancellationResponse;

  void _releaseExecution(_InvocationOwner owner) {
    if (owner.executionReleased) return;
    owner.executionReleased = true;
    _running -= 1;
    if (!owner.lifecycle.isCompleted) owner.lifecycle.complete();
  }

  void _settle(_InvocationOwner owner, Map<String, Object?> value) {
    if (!owner.response.isCompleted) owner.response.complete(value);
    _finishOwner(owner);
  }

  void _settleError(
    _InvocationOwner owner,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!owner.response.isCompleted) {
      owner.response.completeError(error, stackTrace);
    }
    _finishOwner(owner);
  }

  void _finishOwner(_InvocationOwner owner) {
    if (owner.settled) return;
    owner.settled = true;
    owner.deadlineTimer?.cancel();
    _releaseExecution(owner);
    _owners.remove((owner.command, owner.requestId));
    _tombstones.addLast(
      _InvocationTombstone(
        command: owner.command,
        requestId: owner.requestId,
        ownerToken: owner.ownerToken,
      ),
    );
    if (_tombstones.length > settledTombstoneCapacity) {
      _tombstones.removeFirst();
    }
  }

  static PatchbayHostInvocationHandle _immediate(Map<String, Object?> value) =>
      PatchbayHostInvocationHandle(
        response: Future<Map<String, Object?>>.value(value),
        lifecycle: Future<void>.value(),
      );

  static PatchbayInvocationCancellationResult _unknown(
    String command,
    String requestId,
  ) => PatchbayInvocationCancellationResult(
    command: command,
    requestId: requestId,
    outcome: PatchbayInvocationCancellationOutcome.unknown,
  );

  static Map<String, Object?> _cancellationEnvelope(
    String requestId,
    PatchbayInvocationCancellationReason reason,
    String cancellation,
  ) => _rejection(
    requestId,
    switch (reason) {
      PatchbayInvocationCancellationReason.callerDeadlineExceeded =>
        'invocationDeadlineExceeded',
      PatchbayInvocationCancellationReason.callerDisconnected =>
        'invocationCallerDisconnected',
      PatchbayInvocationCancellationReason.explicitRequest =>
        'invocationCancelled',
      PatchbayInvocationCancellationReason.hostDisposed => 'hostDisposed',
    },
    <String, Object?>{'reason': reason.name, 'cancellation': cancellation},
  );

  static Map<String, Object?> _rejection(
    String requestId,
    String code, [
    Map<String, Object?> details = const <String, Object?>{},
  ]) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, details: details),
  ).toJson();
}

void validateConfirmationTimeout(Duration timeout) {
  if (timeout.isNegative || timeout > const Duration(seconds: 30)) {
    throw RangeError.range(
      timeout.inMicroseconds,
      0,
      const Duration(seconds: 30).inMicroseconds,
      'timeout.inMicroseconds',
    );
  }
}

final class _InvocationOwner {
  _InvocationOwner({
    required this.command,
    required this.requestId,
    required this.ownerToken,
    required this.contextAware,
    required this.cancellation,
    required this.onCancellationResponse,
  });

  final String command;
  final String requestId;
  final String ownerToken;
  final bool contextAware;
  final PatchbayInvocationCancellationController cancellation;
  final void Function(Map<String, Object?> response)? onCancellationResponse;
  final Completer<Map<String, Object?>> response =
      Completer<Map<String, Object?>>();
  final Completer<void> lifecycle = Completer<void>();
  Timer? deadlineTimer;
  bool executionReleased = false;
  bool settled = false;
  Map<String, Object?>? frozenResponse;

  Map<String, Object?>? get frozenCancellationResponse => frozenResponse;
}

final class _InvocationTombstone {
  const _InvocationTombstone({
    required this.command,
    required this.requestId,
    required this.ownerToken,
  });

  final String command;
  final String requestId;
  final String ownerToken;
}
