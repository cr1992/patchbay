import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// The first transport or host fact that asked one invocation to stop.
enum PatchbayInvocationCancellationReason {
  callerDeadlineExceeded,
  callerDisconnected,
  explicitRequest,
  hostDisposed,
}

/// Stable result of the protocol-owned cancel operation.
enum PatchbayInvocationCancellationOutcome {
  confirmed,
  unconfirmed,
  unsupported,
  settled,
  unknown,
}

/// Why a requested cancellation was not confirmed inside its observation budget.
enum PatchbayInvocationConfirmationState { pending, callbackFailed, timedOut }

/// Host-local monotonic time source used by invocation deadlines.
typedef PatchbayMonotonicClock = Duration Function();

/// Consumer proof that cancellation has stopped the underlying operation.
typedef PatchbayCancellationConfirmation =
    Future<void> Function(PatchbayInvocationCancellationReason reason);

typedef PatchbayContextCommandHandler<T> =
    FutureOr<Map<String, Object?>> Function(
      T request,
      String requestId,
      PatchbayInvocationContext context,
    );

final Stopwatch _patchbayMonotonicStopwatch = Stopwatch()..start();

Duration patchbayMonotonicNow() => _patchbayMonotonicStopwatch.elapsed;

/// A host-local deadline view. It never exposes wall-clock time.
final class PatchbayInvocationDeadline {
  const PatchbayInvocationDeadline._(this._target, this._clock);

  final Duration _target;
  final PatchbayMonotonicClock _clock;

  Duration get remaining {
    final Duration value = _target - _clock();
    return value.isNegative ? Duration.zero : value;
  }

  bool get isExpired => remaining == Duration.zero;
}

/// Read-only cancellation signal exposed to a context-aware consumer.
final class PatchbayInvocationCancellationSignal {
  PatchbayInvocationCancellationSignal._();

  bool _requested = false;
  PatchbayInvocationCancellationReason? _reason;
  Duration? _whenRequested;

  bool get isRequested => _requested;
  PatchbayInvocationCancellationReason? get reason => _reason;
  Duration? get whenRequested => _whenRequested;
}

/// Additive per-invocation context for cooperative consumers.
final class PatchbayInvocationContext {
  PatchbayInvocationContext._({
    required this.requestId,
    required this.deadline,
    required this.cancellation,
    required void Function(PatchbayCancellationConfirmation callback) register,
  }) : _register = register;

  final String requestId;
  final PatchbayInvocationDeadline? deadline;
  final PatchbayInvocationCancellationSignal cancellation;
  final void Function(PatchbayCancellationConfirmation callback) _register;

  /// Registers the invocation's single stop-confirmation callback.
  void registerCancellationConfirmation(
    PatchbayCancellationConfirmation callback,
  ) => _register(callback);
}

/// Immutable control-plane answer. It never includes the owner token.
final class PatchbayInvocationCancellationResult {
  const PatchbayInvocationCancellationResult({
    required this.command,
    required this.requestId,
    required this.outcome,
    this.reason,
    this.confirmation,
  });

  final String command;
  final String requestId;
  final PatchbayInvocationCancellationOutcome outcome;
  final PatchbayInvocationCancellationReason? reason;
  final PatchbayInvocationConfirmationState? confirmation;

  Map<String, Object?> toJson() => <String, Object?>{
    'command': command,
    'requestId': requestId,
    'outcome': outcome.name,
    if (reason != null) 'reason': reason!.name,
    if (confirmation != null) 'confirmation': confirmation!.name,
  };
}

enum PatchbayInvocationDrainOutcome { drained, timedOut }

/// Frozen terminal accounting for invocations present when drain began.
final class PatchbayInvocationDrainResult {
  const PatchbayInvocationDrainResult({
    required this.outcome,
    required this.settledCount,
    required this.confirmedCount,
    required this.abandonedCount,
  });

  final PatchbayInvocationDrainOutcome outcome;
  final int settledCount;
  final int confirmedCount;
  final int abandonedCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome.name,
    'settledCount': settledCount,
    'confirmedCount': confirmedCount,
    'abandonedCount': abandonedCount,
  };
}

/// Internal controller shared by the host coordinator and public context.
///
/// Exported package barrels deliberately omit this type.
final class PatchbayInvocationCancellationController {
  PatchbayInvocationCancellationController({
    required this.requestId,
    required PatchbayMonotonicClock clock,
    Duration? deadline,
    void Function()? onConfirmed,
  }) : _clock = clock,
       _onConfirmed = onConfirmed,
       signal = PatchbayInvocationCancellationSignal._(),
       deadline = deadline == null
           ? null
           : PatchbayInvocationDeadline._(clock() + deadline, clock) {
    context = PatchbayInvocationContext._(
      requestId: requestId,
      deadline: this.deadline,
      cancellation: signal,
      register: _register,
    );
  }

  final String requestId;
  final PatchbayMonotonicClock _clock;
  final void Function()? _onConfirmed;
  final PatchbayInvocationCancellationSignal signal;
  final PatchbayInvocationDeadline? deadline;
  late final PatchbayInvocationContext context;

  PatchbayCancellationConfirmation? _callback;
  Future<void>? _callbackFuture;
  bool _callbackFailed = false;
  bool _confirmed = false;
  final Completer<void> _stateChanged = Completer<void>();

  bool get supportsConfirmation => _callback != null;
  bool get isConfirmed => _confirmed;
  bool get callbackFailed => _callbackFailed;

  void _register(PatchbayCancellationConfirmation callback) {
    if (_callback != null) {
      throw StateError(
        'registerCancellationConfirmation may be called only once',
      );
    }
    _callback = callback;
    final PatchbayInvocationCancellationReason? reason = signal.reason;
    if (reason != null) _startCallback(callback, reason);
  }

  bool request(PatchbayInvocationCancellationReason reason) {
    if (signal._requested) return false;
    signal
      .._requested = true
      .._reason = reason
      .._whenRequested = _clock();
    final PatchbayCancellationConfirmation? callback = _callback;
    if (callback != null) _startCallback(callback, reason);
    return true;
  }

  void _startCallback(
    PatchbayCancellationConfirmation callback,
    PatchbayInvocationCancellationReason reason,
  ) {
    if (_callbackFuture != null) return;
    _callbackFuture = Future<void>.sync(() => callback(reason)).then<void>(
      (_) {
        _confirmed = true;
        _onConfirmed?.call();
        if (!_stateChanged.isCompleted) _stateChanged.complete();
      },
      onError: (Object _, StackTrace _) {
        _callbackFailed = true;
        if (!_stateChanged.isCompleted) _stateChanged.complete();
      },
    );
  }

  Future<PatchbayInvocationConfirmationState?> observe(Duration timeout) async {
    if (_confirmed) return null;
    if (_callbackFailed) {
      return PatchbayInvocationConfirmationState.callbackFailed;
    }
    if (_callback == null) return PatchbayInvocationConfirmationState.pending;
    if (timeout == Duration.zero) {
      return PatchbayInvocationConfirmationState.timedOut;
    }
    try {
      await _stateChanged.future.timeout(timeout);
    } on TimeoutException {
      return PatchbayInvocationConfirmationState.timedOut;
    }
    if (_confirmed) return null;
    return _callbackFailed
        ? PatchbayInvocationConfirmationState.callbackFailed
        : PatchbayInvocationConfirmationState.pending;
  }
}

/// A response may freeze before the underlying invocation lifecycle releases.
final class PatchbayHostInvocationHandle {
  const PatchbayHostInvocationHandle({
    required this.response,
    required this.lifecycle,
  });

  final Future<Map<String, Object?>> response;
  final Future<void> lifecycle;
}

final RegExp _patchbayOwnerToken = RegExp(r'^[A-Za-z0-9_-]{22}$');

bool isValidPatchbayOwnerToken(String value) =>
    _patchbayOwnerToken.hasMatch(value);

String patchbayGenerateOwnerToken() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(
    16,
    (_) => random.nextInt(256),
    growable: false,
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}
