import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay.dart';

/// Consumer opt-in for the widget inspector select-mode switch.
///
/// The switch is off until a consumer constructs one of these and hands it to
/// `PatchbayFlutterBridge`. Absent it, `ui.inspect.*` never enters the catalog
/// and an invocation answers `commandNotRegistered` — the same shape as the
/// semantics action policy and the navigation adapter, so "the App did not open
/// this" and "the App refused this request" stay different answers.
final class PatchbayInspectPolicy {
  const PatchbayInspectPolicy({
    this.gates = const <String>{},
    this.defaultLease = const Duration(minutes: 5),
    this.maxLease = const Duration(minutes: 30),
  });

  /// Consumer gate IDs the descriptor declares and every enable/disable passes.
  final Set<String> gates;

  /// Lease granted when the request omits `ttlMs`.
  final Duration defaultLease;

  /// Ceiling the App enforces on a requested `ttlMs`.
  final Duration maxLease;
}

/// The Flutter-SDK side of the switch, isolated so it can be faked in tests.
///
/// Everything build-mode dependent lives behind this interface. The default
/// implementation is the only place that touches `WidgetsBinding`, which is
/// what lets a test exercise the "this build cannot show the inspector"
/// rejection without building in profile mode.
abstract interface class PatchbayInspectorSurface {
  /// `null` when the on-device inspector can actually be shown.
  ///
  /// Only the build-mode reasons come from here
  /// ([PatchbayInspectUnavailableWire.notDebugBuild],
  /// [PatchbayInspectUnavailableWire.rootInspectorExcluded]).
  /// [PatchbayInspectUnavailableWire.hostDisposed] is a bridge-lifecycle fact
  /// the bridge answers on its own; a surface never reports it.
  PatchbayInspectUnavailableWire? get unavailableReason;

  bool get selectMode;

  set selectMode(bool value);

  /// Whether a tap on the device is interpreted as a widget selection.
  ///
  /// Read-only here: it is the consumer's own switch, and reporting it is what
  /// keeps "select mode is on but tapping does nothing" from looking like a
  /// Patchbay failure.
  bool get selectionOnTap;
}

/// The real switch: `WidgetsBinding.debugShowWidgetInspectorOverride`.
///
/// `WidgetsApp` injects the inspector overlay from inside an `assert`, so the
/// flag is only load-bearing in a debug build; in profile it can be written and
/// read back while nothing is ever rendered. `debugExcludeRootWidgetInspector`
/// is the second way the overlay never appears — a consumer that injects its
/// own `WidgetInspector` sets it. Both are reported as unavailable rather than
/// answered with a flag that proves nothing.
final class PatchbayBindingInspectorSurface
    implements PatchbayInspectorSurface {
  const PatchbayBindingInspectorSurface();

  @override
  PatchbayInspectUnavailableWire? get unavailableReason {
    if (!kDebugMode) return PatchbayInspectUnavailableWire.notDebugBuild;
    if (WidgetsBinding.instance.debugExcludeRootWidgetInspector) {
      return PatchbayInspectUnavailableWire.rootInspectorExcluded;
    }
    return null;
  }

  @override
  bool get selectMode =>
      WidgetsBinding.instance.debugShowWidgetInspectorOverride;

  @override
  set selectMode(bool value) {
    WidgetsBinding.instance.debugShowWidgetInspectorOverride = value;
    // The SDK's own `ext.flutter.inspector.show` setter clears the selection
    // when it turns the mode off. Skipping that would leave a highlighted
    // element behind, ready to reappear the next time the mode comes back.
    if (!value) WidgetInspectorService.instance.selection.clear();
  }

  @override
  bool get selectionOnTap =>
      WidgetsBinding.instance.debugWidgetInspectorSelectionOnTapEnabled.value;
}

/// Turns the on-device widget inspector's select mode on, off, or reports it.
///
/// The mode is App state, not an observation: while it is on, taps are consumed
/// by the inspector instead of the App, so a session that dies with the switch
/// left on leaves the device unusable. Every enable therefore carries a lease;
/// when the lease runs out without a renewal the bridge puts the flag back the
/// way it found it. The App cannot observe a disconnect on either transport —
/// both are request/response — so "restore on disconnect" is expressed as
/// "restore on silence", which is the only version of it the App can prove.
///
/// Nothing here claims `uiObserved`. Writing the flag schedules a rebuild; it
/// is not proof that a frame carrying the overlay reached the screen, so every
/// answer is `appRecorded` — the App's own record of what it set.
final class PatchbayInspectBridge {
  PatchbayInspectBridge({
    required PatchbayGateEvaluator gates,
    PatchbayInspectPolicy policy = const PatchbayInspectPolicy(),
    PatchbayInspectorSurface? surface,
  }) : _gates = gates,
       _policy = policy,
       _surface = surface ?? const PatchbayBindingInspectorSurface() {
    if (policy.defaultLease <= Duration.zero ||
        policy.maxLease <= Duration.zero ||
        policy.defaultLease > policy.maxLease) {
      throw ArgumentError(
        'Inspect leases must be positive and defaultLease <= maxLease.',
      );
    }
  }

  final PatchbayGateEvaluator _gates;
  final PatchbayInspectPolicy _policy;
  final PatchbayInspectorSurface _surface;

  Timer? _lease;
  Duration? _leaseGranted;
  DateTime? _leaseExpiry;
  bool? _restoresTo;
  PatchbayInspectReleaseWire? _lastRelease;
  bool _disposed = false;

  /// The opt-in the consumer supplied; the catalog descriptor is derived from
  /// it, so the declared gates and the declared `ttlMs` default are the ones
  /// this bridge actually enforces.
  PatchbayInspectPolicy get policy => _policy;

  /// Gate IDs the catalog descriptor declares for `ui.inspect.select`.
  Set<String> get gateIds => _policy.gates;

  /// Whether Patchbay currently owns the flag and holds a live lease.
  bool get managed => _restoresTo != null;

  /// Why the switch cannot be used right now, or `null` when it can.
  ///
  /// A disposed bridge outranks the build question: there is no longer anyone
  /// to hold a lease, so the honest answer is "this bridge is gone" rather than
  /// a report about the build mode.
  PatchbayInspectUnavailableWire? get _unavailableNow => _disposed
      ? PatchbayInspectUnavailableWire.hostDisposed
      : _surface.unavailableReason;

  Future<PatchbayInvocation> status({required String requestId}) async {
    if (_unavailableNow case final PatchbayInspectUnavailableWire unavailable) {
      return _unavailable(requestId, unavailable);
    }
    // Read-only, so only the non-optional base gate applies; the consumer gates
    // belong to the write.
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(requestId, gate);
    if (_unavailableNow case final PatchbayInspectUnavailableWire after) {
      return _unavailable(requestId, after);
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: _state(outcome: 'observed').toJson(),
    );
  }

  Future<PatchbayInvocation> select({
    required PatchbayInspectSelectRequestWire request,
    required String requestId,
  }) async {
    if (_unavailableNow case final PatchbayInspectUnavailableWire unavailable) {
      return _unavailable(requestId, unavailable);
    }

    final int? ttlMs = request.ttlMs;
    if (!request.enabled && ttlMs != null) {
      // A lease is the thing that expires *while the mode is on*; asking for
      // one while turning the mode off states two intents at once, so it is
      // refused rather than silently dropped.
      return _reject(
        requestId,
        'invalidInspectArguments',
        details: <String, Object?>{
          'invalid': const <String>['ttlMs'],
          'reason': 'ttlMs applies only when enabled is true',
        },
      );
    }
    if (ttlMs != null &&
        (ttlMs <= 0 || ttlMs > _policy.maxLease.inMilliseconds)) {
      return _reject(
        requestId,
        'invalidInspectArguments',
        details: <String, Object?>{
          'invalid': const <String>['ttlMs'],
          'maxTtlMs': _policy.maxLease.inMilliseconds,
        },
      );
    }

    final PatchbayGateRejection? gate = await _gates.evaluate(_policy.gates);
    if (gate != null) return _gateRejected(requestId, gate);
    // A gate may await, and two things can change underneath it: a consumer
    // that injects its own inspector can make the overlay unavailable, and the
    // host can be torn down entirely. Resuming into a disposed bridge would
    // turn the flag on with nobody left holding a lease to put it back —
    // the device would keep swallowing taps. So the whole availability
    // question is asked again on this side of the wait rather than assumed.
    if (_unavailableNow case final PatchbayInspectUnavailableWire after) {
      return _unavailable(requestId, after);
    }

    final bool previous = _surface.selectMode;
    if (request.enabled) {
      // Baseline is captured once per managed span: renewing a lease must not
      // rewrite "what it was before Patchbay touched it" with the value
      // Patchbay itself installed. A new span also drops the previous span's
      // release reason, which would otherwise read as an explanation of a
      // switch that is currently on.
      if (_restoresTo == null) {
        _restoresTo = previous;
        _lastRelease = null;
      }
      _surface.selectMode = true;
      _arm(
        ttlMs == null ? _policy.defaultLease : Duration(milliseconds: ttlMs),
      );
    } else {
      // Explicit off means off, even when the baseline was on: the operator
      // asked for this one, unlike the lease, which only undoes what Patchbay
      // did.
      _release(PatchbayInspectReleaseWire.explicitOff, restore: false);
      _surface.selectMode = false;
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: _state(
        outcome: 'applied',
        previousSelectMode: previous,
      ).toJson(),
    );
  }

  /// Drops the lease and puts the flag back, for a host that is shutting down.
  ///
  /// The bridge stays disposed: a request already parked in a gate resumes into
  /// a bridge that refuses rather than one that installs a switch nobody is
  /// left to release. Idempotent.
  void dispose() {
    _disposed = true;
    _release(PatchbayInspectReleaseWire.disposed);
  }

  void _arm(Duration lease) {
    _lease?.cancel();
    _leaseGranted = lease;
    _leaseExpiry = DateTime.now().add(lease);
    _lease = Timer(lease, () {
      _release(PatchbayInspectReleaseWire.leaseExpired);
    });
  }

  /// Ends the managed span, optionally restoring the pre-Patchbay value.
  ///
  /// The restore is conditional on the flag still holding the value Patchbay
  /// installed: DevTools writes the same flag, and an expiring Patchbay lease
  /// must not reach over and undo a switch somebody else flipped in between.
  void _release(PatchbayInspectReleaseWire reason, {bool restore = true}) {
    _lease?.cancel();
    _lease = null;
    _leaseGranted = null;
    _leaseExpiry = null;
    final bool? restoresTo = _restoresTo;
    _restoresTo = null;
    if (restoresTo == null) return;
    _lastRelease = reason;
    if (restore && _surface.selectMode) _surface.selectMode = restoresTo;
  }

  PatchbayInspectStateWire _state({
    required String outcome,
    bool? previousSelectMode,
  }) {
    final int? remaining = _leaseExpiry
        ?.difference(DateTime.now())
        .inMilliseconds
        .clamp(0, _policy.maxLease.inMilliseconds);
    return PatchbayInspectStateWire(
      outcome: outcome,
      // Not `uiObserved`: this is the flag the App holds, not a frame anyone
      // watched arrive.
      source: PatchbayFactSourceWire.appRecorded,
      selectMode: _surface.selectMode,
      selectionOnTap: _surface.selectionOnTap,
      managed: managed,
      previousSelectMode: previousSelectMode,
      restoresTo: _restoresTo,
      leaseMs: _leaseGranted?.inMilliseconds,
      leaseRemainingMs: remaining,
      lastRelease: _lastRelease,
    );
  }

  PatchbayInvocation _unavailable(
    String requestId,
    PatchbayInspectUnavailableWire reason,
  ) => _reject(
    requestId,
    'inspectorUnavailable',
    notice: switch (reason) {
      PatchbayInspectUnavailableWire.notDebugBuild =>
        'The on-device widget inspector exists only in a debug build.',
      PatchbayInspectUnavailableWire.rootInspectorExcluded =>
        'This App excludes the root widget inspector, so the flag renders '
            'nothing.',
      PatchbayInspectUnavailableWire.hostDisposed =>
        'The Patchbay host was torn down, so the select-mode switch has no '
            'owner left to release it.',
    },
    details: <String, Object?>{'reason': reason.toJson()},
  );

  static PatchbayInvocation _gateRejected(
    String requestId,
    PatchbayGateRejection gate,
  ) => _reject(
    requestId,
    gate.code,
    notice: gate.notice,
    details: <String, Object?>{'gateId': gate.gateId},
  );

  static PatchbayInvocation _reject(
    String requestId,
    String code, {
    String? notice,
    Map<String, Object?> details = const <String, Object?>{},
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  );
}
