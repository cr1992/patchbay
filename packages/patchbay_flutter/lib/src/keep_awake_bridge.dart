import 'dart:async';

import 'package:patchbay/patchbay.dart';

import 'lifecycle.dart';

/// The consumer-owned hook that actually holds the screen awake.
///
/// Patchbay's four packages are pure Dart and pure Flutter; none of them may
/// reach a platform channel, and adding a plugin — or a third-party wakelock
/// dependency — to `patchbay_flutter` would change what every consumer's build
/// links against just to gain a debugging switch. So the framework owns the
/// protocol, the bookkeeping and the lease, and the App owns the one line that
/// touches the platform:
///
/// ```dart
/// // Android: FLAG_KEEP_SCREEN_ON, iOS: UIApplication.isIdleTimerDisabled.
/// PatchbayFlutterBridge(
///   gates: gates,
///   keepAwakeDelegate: (bool enabled) => myPlatformChannel.setKeepAwake(enabled),
/// );
/// ```
///
/// The delegate is called with `true` to engage and `false` to release, never
/// twice in a row with the same value: the bridge tracks the state and only
/// calls on an actual transition. Throwing is a legitimate answer — the
/// invocation is refused with `keepAwakeDelegateFailed` rather than recorded as
/// a hold that never happened.
typedef PatchbayKeepAwakeDelegate = FutureOr<void> Function(bool enabled);

/// Opt-in "keep the screen awake" switch with a framework-owned lease.
///
/// **Why this exists.** A device that sleeps mid-session takes the whole UI
/// plane with it: every `ui.*` and `navigation.*` request starts answering
/// `*LifecycleNotResumed`, and after a while the OS freezes the process and the
/// CLI only sees `appUnresponsive`. Android has an external fix that does not
/// touch the App (`adb shell svc power stayon usb`); iOS真机 has none — no
/// `devicectl`, no libimobiledevice equivalent — so on iOS this switch is the
/// only way to keep a long manual session alive.
///
/// **Why it is off by default.** Holding the screen awake changes the behaviour
/// of the App being observed, and screen-off behaviour is itself something a
/// consumer tests. So nothing is engaged until an operator asks, and the ask is
/// bounded: an engagement carries a lease, and when the lease runs out the
/// bridge releases on its own.
///
/// **Why the lease is the disconnect story.** Neither transport gives the App a
/// connection lifecycle — a VM Service extension answers requests and has no
/// idea a CLI died, and a killed terminal sends no goodbye. A hold released
/// only by an explicit `off` would therefore survive every crashed session and
/// keep the device lit until the battery ran out. The lease inverts that: an
/// operator who is still there renews it, and one who is gone stops renewing,
/// so *disconnect* and *lease expiry* are the same event as far as the App can
/// honestly tell. [dispose] covers the other end — the App tearing the debug
/// surface down while a hold is live.
///
/// The reported state is always [PatchbayFactSource.appRecorded]: it says what
/// the App asked the host to do, never that the screen is in fact lit. Only the
/// consumer's own delegate touches the platform, and Patchbay does not read it
/// back.
final class PatchbayKeepAwakeBridge {
  PatchbayKeepAwakeBridge({
    required PatchbayGateEvaluator gates,
    required bool Function() isAppResumed,
    required PatchbayLifecycleStateReader lifecycleState,
    PatchbayKeepAwakeDelegate? delegate,
    Set<String> gateIds = const <String>{},
    String Function()? newRequestId,
  }) : _gates = gates,
       _isAppResumed = isAppResumed,
       _lifecycleState = lifecycleState,
       _delegate = delegate,
       gateIds = Set<String>.unmodifiable(gateIds),
       _newRequestId = newRequestId ?? _defaultRequestId;

  /// The lease an engagement takes when the caller names none.
  ///
  /// Long enough for a stretch of hands-on debugging, short enough that a
  /// session nobody is attending gives the screen back rather than holding it
  /// until the battery is gone.
  static const Duration defaultLease = Duration(minutes: 10);

  /// The longest lease this bridge accepts.
  ///
  /// The bound is what keeps "auto-release" a guarantee instead of a default: a
  /// caller may extend a session but cannot ask for an unbounded hold, and
  /// renewing is always available for a session that really does run longer.
  static const Duration maxLease = Duration(hours: 2);

  final PatchbayGateEvaluator _gates;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final PatchbayKeepAwakeDelegate? _delegate;
  final String Function() _newRequestId;

  /// Consumer gates declared for `ui.keepAwake.set`, published in the catalog.
  final Set<String> gateIds;

  bool _enabled = false;

  /// Set synchronously by [dispose], read back after every await in [_apply].
  ///
  /// [dispose] cannot join the request queue — it is synchronous, and a
  /// teardown that had to wait behind a slow consumer gate would be a teardown
  /// a consumer could stall. So it lands wherever it lands, including in the
  /// middle of an in-flight engagement, and the suspended request is the one
  /// that has to notice.
  bool _disposed = false;

  Duration? _lease;
  DateTime? _leaseDeadline;
  Timer? _leaseTimer;
  PatchbayKeepAwakeReleaseWire? _lastRelease;
  String? _lastReleaseFailure;
  Future<void> _tail = Future<void>.value();

  static int _nextRequest = 0;
  static String _defaultRequestId() => 'patchbay-keep-awake-${++_nextRequest}';

  /// Whether a consumer delegate was injected at the composition root.
  bool get wired => _delegate != null;

  /// Whether the App is currently asking the host to hold the screen awake.
  bool get enabled => _enabled;

  /// Engages, renews or releases the hold.
  ///
  /// Requests are serialised: a gate and a consumer delegate may both await, so
  /// two operators (or an operator and an expiring lease) must not interleave
  /// into a state where the bookkeeping and the platform disagree.
  Future<PatchbayInvocation> set(
    PatchbayKeepAwakeRequestWire request, {
    String? requestId,
  }) {
    final String id = requestId ?? _newRequestId();
    return _enqueue(() => _apply(request, id));
  }

  /// Reads the current state without touching it.
  ///
  /// Deliberately not gated by the consumer gates `set` declares, and
  /// deliberately not refused while the App is not resumed: this is the answer
  /// an operator needs exactly when the device is misbehaving. It is also not a
  /// renewal — a read that extended the lease would make "the hold expires"
  /// depend on how often someone looked.
  Future<PatchbayInvocation> status({String? requestId}) async {
    final String id = requestId ?? _newRequestId();
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(id, gate);
    return _accepted(id, 'observed');
  }

  /// Releases a live hold as the App tears the debug surface down.
  ///
  /// Synchronous like every other `dispose` here, so the release request is
  /// issued but not awaited: a slow consumer implementation must not be able to
  /// hold up host teardown. The delegate call itself is still made before this
  /// returns, and its failure is recorded rather than thrown at a caller that
  /// is on its way out.
  ///
  /// Releasing what is held is only half of it. Nothing is held yet during the
  /// window between a request arriving and its gate returning, so a `dispose`
  /// landing there has nothing to give back — and the danger is entirely on the
  /// other side, in the suspended request that would otherwise resume and
  /// engage a host that no longer exists. [_disposed] is what closes that door;
  /// it is set first, before anything can await.
  void dispose() {
    _disposed = true;
    _cancelLease();
    if (!_enabled) return;
    unawaited(_release(PatchbayKeepAwakeReleaseWire.hostDisposed));
  }

  Future<PatchbayInvocation> _apply(
    PatchbayKeepAwakeRequestWire request,
    String requestId,
  ) async {
    // There is no switch left to operate: the teardown already gave back
    // whatever was held, so a release has nothing to do and an engagement would
    // arm a lease nobody owns.
    if (_disposed) return _hostDisposed(requestId);
    // A release carries no lease: accepting one would leave the caller to guess
    // whether it scheduled a later re-engagement.
    if (!request.enabled && request.leaseMs != null) {
      return _rejected(
        requestId,
        'invalidKeepAwakeArguments',
        details: <String, Object?>{
          'invalid': const <String>['leaseMs'],
          'reason': 'a release carries no lease',
        },
      );
    }
    final int leaseMs = request.leaseMs ?? defaultLease.inMilliseconds;
    if (request.enabled &&
        (leaseMs <= 0 || leaseMs > maxLease.inMilliseconds)) {
      // Which bound was crossed and what the bound is: a plausible number
      // refused without either leaves the caller guessing at both.
      return _rejected(
        requestId,
        'invalidKeepAwakeArguments',
        details: <String, Object?>{
          'invalid': const <String>['leaseMs'],
          'maxLeaseMs': maxLease.inMilliseconds,
        },
      );
    }

    final PatchbayKeepAwakeDelegate? delegate = _delegate;
    if (delegate == null) {
      // The command stays in the catalog even with nothing wired, unlike
      // `ui.capture` and `navigation.*`. An operator reaches for keep-awake
      // precisely when the screen just went dark and every UI request started
      // failing; `commandNotRegistered` would tell them nothing about why, so
      // the answer names the missing wiring instead. `ui.keepAwake.status`
      // reports the same fact as `wired: false` without having to try.
      return _rejected(
        requestId,
        'keepAwakeNotWired',
        notice:
            'This App wired no keep-awake delegate. Pass keepAwakeDelegate to '
            'PatchbayFlutterBridge at the composition root.',
      );
    }

    if (request.enabled && !_isAppResumed()) {
      // Engaging from a paused App would record a hold the platform did not
      // take: iOS ignores `isIdleTimerDisabled` set from the background. The
      // lifecycle state travels along, so the operator is told to wake the
      // device rather than left to bisect. Releasing has no such requirement —
      // giving the screen back must always be possible.
      return _rejected(
        requestId,
        'keepAwakeLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }

    final PatchbayGateRejection? gate = await _gates.evaluate(gateIds);
    if (gate != null) return _gateRejected(requestId, gate);
    // A gate may await, and the host can have been torn down in the meantime.
    // Nothing was held when `dispose` ran, so it returned without releasing
    // anything; resuming here would engage a dead host and leave a lease timer
    // running for up to [maxLease] after the App stopped answering.
    if (_disposed) return _hostDisposed(requestId);
    // The App can also have been backgrounded in the meantime, which is exactly
    // the state the check above refuses.
    if (request.enabled && !_isAppResumed()) {
      return _rejected(
        requestId,
        'keepAwakeLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }

    if (!request.enabled) {
      // Nothing is held, so nothing is asked of the App being observed.
      if (!_enabled) return _accepted(requestId, 'unchanged');
      final String? failure = await _release(
        PatchbayKeepAwakeReleaseWire.operatorRequest,
      );
      return failure == null
          ? _accepted(requestId, 'released')
          : _rejected(
              requestId,
              'keepAwakeDelegateFailed',
              details: <String, Object?>{'failureType': failure},
            );
    }

    final bool wasEnabled = _enabled;
    if (!wasEnabled) {
      try {
        await delegate(true);
      } on Object catch (error) {
        // The type, never the message: a consumer error string is arbitrary App
        // data and this envelope goes over the wire. Nothing is recorded as
        // held, because nothing is known to be held.
        return _rejected(
          requestId,
          'keepAwakeDelegateFailed',
          details: <String, Object?>{
            'failureType': error.runtimeType.toString(),
          },
        );
      }
      // The delegate is the other place this request can be suspended, and the
      // teardown that arrived during it saw `_enabled` still false. Refusing
      // alone would not be enough here: the platform is holding the screen now,
      // so the hold has to be handed back before the caller is answered.
      if (_disposed) {
        _enabled = true;
        await _release(PatchbayKeepAwakeReleaseWire.hostDisposed);
        return _hostDisposed(requestId);
      }
      _enabled = true;
    }
    // Cleared on a renewal too, not just a fresh engagement: after a release
    // that the platform refused, the hold survives and asking again is a
    // renewal — and an operator who deliberately re-engages has settled what
    // that stale failure was there to warn them about.
    _lastReleaseFailure = null;
    _arm(Duration(milliseconds: leaseMs));
    return _accepted(requestId, wasEnabled ? 'renewed' : 'engaged');
  }

  static PatchbayInvocation _hostDisposed(String requestId) => _rejected(
    requestId,
    'keepAwakeHostDisposed',
    notice:
        'The Patchbay debug surface was torn down; any keep-awake hold was '
        'already released.',
  );

  /// Drops the hold and reports the delegate failure type, or null on success.
  ///
  /// **The bookkeeping is committed only after the platform has actually let
  /// go.** Recording the release first reads as though `enabled` merely states
  /// what the App is *asking* for — but it makes a failed release terminal: the
  /// next `off` would find nothing held, answer `unchanged`, and never reach
  /// the platform again, leaving the screen lit with no way left to ask. So a
  /// delegate that throws leaves the hold exactly where it was, still held and
  /// still releasable, with the failure reported alongside it.
  ///
  /// The lease is left armed for the same reason: it is the only thing that
  /// retries on behalf of an operator who is no longer there.
  Future<String?> _release(PatchbayKeepAwakeReleaseWire reason) async {
    final PatchbayKeepAwakeDelegate? delegate = _delegate;
    if (delegate != null) {
      try {
        await delegate(false);
      } on Object catch (error) {
        return _lastReleaseFailure = error.runtimeType.toString();
      }
    }
    _cancelLease();
    _enabled = false;
    _lastRelease = reason;
    _lastReleaseFailure = null;
    return null;
  }

  void _arm(Duration lease) {
    _leaseTimer?.cancel();
    _lease = lease;
    _leaseDeadline = DateTime.now().add(lease);
    _leaseTimer = Timer(lease, () {
      unawaited(
        _enqueue(() async {
          // A release that landed while the timer was queued wins; re-releasing
          // would overwrite `operatorRequest` with a lease that expired on an
          // engagement nobody holds any more.
          if (!_enabled || _disposed) return;
          final String? failure = await _release(
            PatchbayKeepAwakeReleaseWire.leaseExpired,
          );
          // The platform refused to let go and, by construction, nobody is here
          // to type `off` — an unattended session is the whole reason the lease
          // exists. Re-arm so the next attempt comes one lease later: the same
          // cadence the operator opted into, not a retry loop.
          if (failure != null && _enabled && !_disposed) _arm(lease);
        }),
      );
    });
  }

  void _cancelLease() {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _lease = null;
    _leaseDeadline = null;
  }

  int? _leaseRemainingMs() {
    final DateTime? deadline = _leaseDeadline;
    if (deadline == null) return null;
    final int remaining = deadline.difference(DateTime.now()).inMilliseconds;
    return remaining < 0 ? 0 : remaining;
  }

  Future<T> _enqueue<T>(Future<T> Function() body) {
    final Completer<T> result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await body());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  PatchbayInvocation _accepted(String requestId, String outcome) =>
      PatchbayInvocation.accepted(
        requestId: requestId,
        payload: PatchbayKeepAwakeStateWire(
          outcome: outcome,
          source: PatchbayFactSourceWire.appRecorded,
          wired: wired,
          enabled: _enabled,
          leaseMs: _lease?.inMilliseconds,
          leaseRemainingMs: _leaseRemainingMs(),
          lastRelease: _lastRelease,
          lastReleaseFailure: _lastReleaseFailure,
        ).toJson(),
      );

  static PatchbayInvocation _gateRejected(
    String requestId,
    PatchbayGateRejection gate,
  ) => _rejected(
    requestId,
    gate.code,
    notice: gate.notice,
    details: <String, Object?>{'gateId': gate.gateId},
  );

  static PatchbayInvocation _rejected(
    String requestId,
    String code, {
    String? notice,
    Map<String, Object?> details = const <String, Object?>{},
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  );
}
