import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  group('keep-awake default', () {
    testWidgets('nothing is engaged and the delegate is never called', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      final Map<String, Object?> payload = _payload(
        await bridge.status(requestId: 'status-1'),
      );

      expect(payload['outcome'], 'observed');
      // Never `uiObserved`: this is what the App asked its host to do, not a
      // reading of the screen.
      expect(payload['source'], 'appRecorded');
      expect(payload['wired'], isTrue);
      expect(payload['enabled'], isFalse);
      expect(payload['leaseMs'], isNull);
      expect(payload['leaseRemainingMs'], isNull);
      expect(payload['lastRelease'], isNull);
      // The whole point of "default off": an App that nobody asked has had
      // nothing done to it.
      expect(delegate.calls, isEmpty);
    });

    testWidgets('the request id the caller sent comes back', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge();
      final Map<String, Object?> response = (await bridge.status(
        requestId: 'status-echo',
      )).toJson();

      expect(response['requestId'], 'status-echo');
    });
  });

  group('keep-awake engage', () {
    testWidgets('on engages once and reports the default lease', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
          requestId: 'on-1',
        ),
      );

      expect(payload['outcome'], 'engaged');
      expect(payload['enabled'], isTrue);
      expect(
        payload['leaseMs'],
        PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
      );
      expect(delegate.calls, <bool>[true]);

      await _release(tester, bridge);
    });

    testWidgets('an explicit lease is the one that is reported and armed', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
      );

      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
          requestId: 'on-lease',
        ),
      );

      expect(payload['leaseMs'], 60000);
      expect(payload['leaseRemainingMs'], lessThanOrEqualTo(60000));

      await _release(tester, bridge);
    });

    testWidgets('a second on renews without a second delegate call', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      await tester.pump(const Duration(seconds: 30));
      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
        ),
      );

      expect(payload['outcome'], 'renewed');
      // The platform is already holding; asking twice would make a consumer
      // implementation responsible for being idempotent.
      expect(delegate.calls, <bool>[true]);
      expect(payload['leaseRemainingMs'], greaterThan(30000));

      await _release(tester, bridge);
    });
  });

  group('keep-awake release', () {
    testWidgets('off releases now and names the operator as the reason', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
      );
      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(payload['outcome'], 'released');
      expect(payload['enabled'], isFalse);
      expect(payload['leaseMs'], isNull);
      expect(payload['leaseRemainingMs'], isNull);
      expect(payload['lastRelease'], 'operatorRequest');
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('off with nothing held is unchanged and touches nothing', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(payload['outcome'], 'unchanged');
      expect(payload['lastRelease'], isNull);
      expect(delegate.calls, isEmpty);
    });

    testWidgets('releasing is allowed even while the App is backgrounded', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      var resumed = true;
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        isAppResumed: () => resumed,
      );

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
      );
      resumed = false;
      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      // Giving the screen back must never be the thing that is refused.
      expect(payload['outcome'], 'released');
      expect(delegate.calls, <bool>[true, false]);
    });
  });

  group('keep-awake auto-release', () {
    testWidgets('an expired lease releases on its own', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      expect(bridge.enabled, isTrue);

      // No `off` is ever sent: this is the operator whose terminal died, and
      // neither transport tells the App about that.
      await tester.pump(const Duration(milliseconds: 1001));
      await _drain(tester, bridge);

      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
      final Map<String, Object?> payload = _payload(await bridge.status());
      expect(payload['enabled'], isFalse);
      expect(payload['lastRelease'], 'leaseExpired');
      expect(payload['leaseRemainingMs'], isNull);
    });

    testWidgets('reading the state does not extend the lease', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await bridge.status();
      await tester.pump(const Duration(milliseconds: 200));
      await _drain(tester, bridge);

      // A polling operator must not be able to hold the screen forever by
      // watching it.
      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('an operator release wins over the timer that was queued', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      await tester.pump(const Duration(milliseconds: 2000));
      await _drain(tester, bridge);

      // The delegate is not asked to release twice, and the recorded reason
      // stays the one that actually happened.
      expect(delegate.calls, <bool>[true, false]);
      expect(_payload(await bridge.status())['lastRelease'], 'operatorRequest');
    });

    testWidgets('host disposal releases a live hold', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      bridge.dispose();
      await tester.pump();

      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
      expect(_payload(await bridge.status())['lastRelease'], 'hostDisposed');
    });

    testWidgets('disposal with nothing held asks the delegate for nothing', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      bridge.dispose();
      await tester.pump();

      expect(delegate.calls, isEmpty);
    });

    testWidgets('the bridge disposes with the Flutter bridge that owns it', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        gates: _allowAll,
        keepAwakeDelegate: delegate.call,
        isAppResumed: () => true,
      );

      await bridge.keepAwake.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      bridge.dispose();
      await tester.pump();

      expect(delegate.calls, <bool>[true, false]);
    });
  });

  // `dispose()` is synchronous and cannot join the request queue, so it can
  // land in the middle of an in-flight engage. At that instant nothing is held
  // yet, so there is nothing for `dispose` itself to release — the danger is
  // entirely on the other side: the suspended request resuming afterwards and
  // engaging a host that no longer exists.
  group('keep-awake dispose race', () {
    testWidgets('a dispose during an awaited gate cannot engage afterwards', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final Completer<void> gateEntered = Completer<void>();
      final Completer<void> gateHeld = Completer<void>();
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) async {
            gateEntered.complete();
            await gateHeld.future;
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final Future<PatchbayInvocation> pending = bridge.set(
        PatchbayKeepAwakeRequestWire(
          enabled: true,
          leaseMs: PatchbayKeepAwakeBridge.maxLease.inMilliseconds,
        ),
      );
      // `set` is queued, so waiting for the gate to actually be entered is what
      // puts the teardown inside this window rather than in front of it.
      await gateEntered.future;
      // Nothing is held yet, so the teardown has nothing to give back and
      // returns immediately — the request is still suspended behind the gate.
      bridge.dispose();
      gateHeld.complete();

      expect(_rejection(await pending)['code'], 'keepAwakeHostDisposed');
      // The screen must never be taken by a host that is already gone.
      expect(delegate.calls, isEmpty);
      expect(bridge.enabled, isFalse);
      // A surviving lease would also be a timer outliving the host; pumping
      // past the longest one it could have armed proves none was.
      await tester.pump(PatchbayKeepAwakeBridge.maxLease);
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a dispose while the delegate engages gives the screen back', (
      WidgetTester tester,
    ) async {
      final Completer<void> entered = Completer<void>();
      final Completer<void> engaging = Completer<void>();
      final _RecordingDelegate delegate = _RecordingDelegate(
        before: (bool enabled) async {
          if (!enabled) return;
          entered.complete();
          await engaging.future;
        },
      );
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      final Future<PatchbayInvocation> pending = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      // `set` is queued, so the teardown has to wait until the request is
      // genuinely suspended inside the delegate — otherwise it just beats the
      // request to the entry check and proves nothing about this window.
      await entered.future;
      bridge.dispose();
      engaging.complete();

      expect(_rejection(await pending)['code'], 'keepAwakeHostDisposed');
      // This one did reach the platform, so refusing is not enough: the hold
      // it took has to be handed back before the request is answered.
      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
      await tester.pump(const Duration(minutes: 2));
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('a request that arrives after teardown is refused outright', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      bridge.dispose();

      expect(
        _rejection(
          await bridge.set(
            const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
          ),
        )['code'],
        'keepAwakeHostDisposed',
      );
      expect(delegate.calls, isEmpty);
      // Reading stays available: it is the answer that explains the refusal.
      expect(_payload(await bridge.status())['enabled'], isFalse);
    });
  });

  group('keep-awake not wired', () {
    testWidgets('set is refused by name instead of vanishing from the API', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge();

      final Map<String, Object?> response = (await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        requestId: 'unwired-1',
      )).toJson();

      expect(response['admission'], 'rejected');
      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'keepAwakeNotWired');
      // The operator reaches for this exactly when the UI plane went quiet, so
      // the answer has to say what to do about it.
      expect(rejection['notice'], contains('keepAwakeDelegate'));
      expect(bridge.wired, isFalse);
    });

    testWidgets('status answers honestly rather than refusing', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge();

      final Map<String, Object?> payload = _payload(await bridge.status());

      expect(payload['wired'], isFalse);
      expect(payload['enabled'], isFalse);
    });

    testWidgets('the command stays in the catalog with nothing wired', (
      WidgetTester tester,
    ) async {
      final Set<Object?> names = await _catalogNames(
        PatchbayFlutterBridge(gates: _allowAll, isAppResumed: () => true),
      );

      // Unlike `ui.capture` and `navigation.*`, absence here would read as
      // `commandNotRegistered` — a worse answer than "this App wired nothing".
      expect(names, contains('ui.keepAwake.set'));
      expect(names, contains('ui.keepAwake.status'));
    });
  });

  group('keep-awake argument bounds', () {
    testWidgets('a release carries no lease', (WidgetTester tester) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
      );

      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: 1000),
        ),
      );

      expect(rejection['code'], 'invalidKeepAwakeArguments');
      final Map<String, Object?> details =
          rejection['details']! as Map<String, Object?>;
      expect(details['invalid'], <String>['leaseMs']);
      expect(details['reason'], isNotNull);
    });

    testWidgets('a lease past the ceiling is refused and names the ceiling', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
      );

      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          PatchbayKeepAwakeRequestWire(
            enabled: true,
            leaseMs: PatchbayKeepAwakeBridge.maxLease.inMilliseconds + 1,
          ),
        ),
      );

      final Map<String, Object?> details =
          rejection['details']! as Map<String, Object?>;
      expect(details['invalid'], <String>['leaseMs']);
      expect(
        details['maxLeaseMs'],
        PatchbayKeepAwakeBridge.maxLease.inMilliseconds,
      );
      expect(bridge.enabled, isFalse);
    });

    testWidgets('a non-positive lease is refused', (WidgetTester tester) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
      );

      expect(
        _rejection(
          await bridge.set(
            const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 0),
          ),
        )['code'],
        'invalidKeepAwakeArguments',
      );
      expect(bridge.enabled, isFalse);
    });

    testWidgets('the ceiling itself is accepted', (WidgetTester tester) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
      );

      final Map<String, Object?> payload = _payload(
        await bridge.set(
          PatchbayKeepAwakeRequestWire(
            enabled: true,
            leaseMs: PatchbayKeepAwakeBridge.maxLease.inMilliseconds,
          ),
        ),
      );

      expect(payload['outcome'], 'engaged');

      await _release(tester, bridge);
    });
  });

  group('keep-awake lifecycle and gates', () {
    testWidgets('engaging from a backgrounded App is refused with the state', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        isAppResumed: () => false,
        lifecycleState: () => AppLifecycleState.paused,
      );

      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeLifecycleNotResumed');
      expect(rejection['details'], containsPair('lifecycleState', 'paused'));
      // iOS ignores `isIdleTimerDisabled` set from the background, so recording
      // a hold here would be recording something that did not happen.
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a background arriving during an awaited gate still refuses', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final Completer<void> gateHeld = Completer<void>();
      var resumed = true;
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) async {
            await gateHeld.future;
            return const PatchbayGateDecision.allow();
          },
        ),
        isAppResumed: () => resumed,
      );

      final Future<PatchbayInvocation> pending = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
      );
      resumed = false;
      gateHeld.complete();

      expect(_rejection(await pending)['code'], 'keepAwakeLifecycleNotResumed');
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a closed consumer gate refuses set and names the gate', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) =>
              const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
        ),
      );

      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'consumerGateRejected');
      expect(
        rejection['details'],
        containsPair('gateId', 'consumer.keepAwake'),
      );
      expect(delegate.calls, isEmpty);
    });

    testWidgets('status is not held behind the gates set declares', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) =>
              const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
        ),
      );

      // Reading the switch is exactly what an operator needs when the consumer
      // gate is the thing that is misbehaving.
      expect(_payload(await bridge.status())['outcome'], 'observed');
    });

    testWidgets('a closed base gate still refuses status', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(),
        gates: PatchbayGateEvaluator(
          baseGate: () =>
              const PatchbayGateDecision.reject(code: 'baseGateRejected'),
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );

      expect(_rejection(await bridge.status())['code'], 'baseGateRejected');
    });

    testWidgets('the declared gate ids reach the catalog descriptor', (
      WidgetTester tester,
    ) async {
      final Map<String, Object?> descriptor = await _catalogCommand(
        PatchbayFlutterBridge(
          gates: _allowAll,
          keepAwakeDelegate: _RecordingDelegate().call,
          keepAwakeGates: const <String>{'consumer.keepAwake'},
          isAppResumed: () => true,
        ),
        'ui.keepAwake.set',
      );

      expect(descriptor['plane'], 'flutterUi');
      expect(descriptor['mode'], 'immediate');
      expect(descriptor['sideEffect'], 'appState');
      expect(descriptor['factSources'], <String>['appRecorded']);
      expect(descriptor['gates'], <String>['consumer.keepAwake']);
      final List<Object?> parameters =
          descriptor['parameters']! as List<Object?>;
      expect(
        <Object?, Object?>{
          for (final Map<String, Object?> parameter
              in parameters.cast<Map<String, Object?>>())
            parameter['name']: parameter['required'],
        },
        <String, bool>{'enabled': true, 'leaseMs': false},
      );
      final Map<String, Object?> lease = parameters
          .cast<Map<String, Object?>>()
          .firstWhere((Map<String, Object?> p) => p['name'] == 'leaseMs');
      // The default lives in the descriptor so no second copy has to be kept
      // in step CLI-side.
      expect(
        lease['default'],
        PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
      );
      expect(lease['summary'], isNotNull);
    });

    testWidgets('the read command declares no side effect', (
      WidgetTester tester,
    ) async {
      final Map<String, Object?> descriptor = await _catalogCommand(
        PatchbayFlutterBridge(gates: _allowAll, isAppResumed: () => true),
        'ui.keepAwake.status',
      );

      expect(descriptor['mode'], 'readOnly');
      expect(descriptor['sideEffect'], 'none');
      expect(descriptor['parameters'], isEmpty);
    });
  });

  group('keep-awake delegate failure', () {
    testWidgets('a throwing engage records nothing as held', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: _RecordingDelegate(failOn: true),
      );

      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeDelegateFailed');
      // The type only: a consumer error string is App data and this envelope
      // goes over the wire.
      expect(
        rejection['details'],
        containsPair('failureType', '_KeepAwakeDelegateFailure'),
      );
      expect(bridge.enabled, isFalse);
      expect(_payload(await bridge.status())['enabled'], isFalse);
    });

    testWidgets('a throwing release leaves the hold retryable, not dropped', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      final Map<String, Object?> rejection = _rejection(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeDelegateFailed');
      // The platform did not let go, so the App is still holding it. Recording
      // the release as done would make the next `off` an `unchanged` no-op and
      // strand the screen lit with no way left to ask again.
      final Map<String, Object?> payload = _payload(await bridge.status());
      expect(payload['enabled'], isTrue);
      expect(payload['lastRelease'], isNull);
      expect(payload['lastReleaseFailure'], '_KeepAwakeDelegateFailure');

      delegate.failOn = null;
      final Map<String, Object?> retried = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(retried['outcome'], 'released');
      expect(retried['enabled'], isFalse);
      expect(retried['lastRelease'], 'operatorRequest');
      expect(retried['lastReleaseFailure'], isNull);
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('an expiry whose release fails retries a lease later', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await tester.pump(const Duration(milliseconds: 1001));
      await _drain(tester, bridge);

      // Nobody is here to type `off` — this is exactly the unattended session
      // the lease exists for, so a failed release cannot be the last attempt.
      expect(bridge.enabled, isTrue);
      expect(
        _payload(await bridge.status())['lastReleaseFailure'],
        '_KeepAwakeDelegateFailure',
      );

      delegate.failOn = null;
      await tester.pump(const Duration(milliseconds: 1001));
      await _drain(tester, bridge);

      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
      expect(_payload(await bridge.status())['lastRelease'], 'leaseExpired');
    });

    testWidgets('a later clean engage clears the stale failure', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = _bridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      delegate.failOn = null;
      // The hold survived the failed release, so asking again is a renewal —
      // and an operator who deliberately re-engages has made the stale
      // "the last release failed" no longer their problem.
      final Map<String, Object?> payload = _payload(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
        ),
      );

      expect(payload['outcome'], 'renewed');
      expect(payload['lastReleaseFailure'], isNull);
      expect(_payload(await bridge.status())['lastReleaseFailure'], isNull);

      await _release(tester, bridge);
    });
  });

  group('keep-awake serialisation', () {
    testWidgets('a release queued behind an awaiting engage is not lost', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final Completer<void> gateHeld = Completer<void>();
      final PatchbayKeepAwakeBridge bridge = _bridge(
        delegate: delegate,
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) async {
            if (!gateHeld.isCompleted) await gateHeld.future;
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final Future<PatchbayInvocation> engage = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      final Future<PatchbayInvocation> release = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      gateHeld.complete();

      expect(_payload(await engage)['outcome'], 'engaged');
      expect(_payload(await release)['outcome'], 'released');
      // Interleaving would have left the bookkeeping and the platform
      // disagreeing about whether anything is held.
      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
    });
  });

  group('keep-awake host routing', () {
    testWidgets('set and status reach the bridge with the request id', (
      WidgetTester tester,
    ) async {
      final _RecordingDelegate delegate = _RecordingDelegate();
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        gates: _allowAll,
        keepAwakeDelegate: delegate.call,
        isAppResumed: () => true,
      );
      final PatchbayFlutterServiceHost host = _host(bridge);

      final Map<String, Object?> engaged = await host.dispatchInvoke(
        'ui.keepAwake.set',
        <String, Object?>{'enabled': true, 'leaseMs': 60000},
        'host-on',
      );
      expect(engaged['requestId'], 'host-on');
      expect(
        (engaged['payload']! as Map<String, Object?>)['outcome'],
        'engaged',
      );

      final Map<String, Object?> observed = await host.dispatchInvoke(
        'ui.keepAwake.status',
        const <String, Object?>{},
        'host-status',
      );
      expect((observed['payload']! as Map<String, Object?>)['enabled'], isTrue);

      await host.dispatchInvoke('ui.keepAwake.set', const <String, Object?>{
        'enabled': false,
      }, 'host-off');
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('an undeclared key is named rather than guessed at', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterServiceHost host = _host(
        PatchbayFlutterBridge(
          gates: _allowAll,
          keepAwakeDelegate: _RecordingDelegate().call,
          isAppResumed: () => true,
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.keepAwake.set',
        const <String, Object?>{'enabled': true, 'minutes': 5},
        'host-bad-key',
      );

      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'invalidUiArguments');
      expect(
        rejection['details'],
        containsPair('unexpected', <String>['minutes']),
      );
    });

    testWidgets('a missing required argument is named', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterServiceHost host = _host(
        PatchbayFlutterBridge(
          gates: _allowAll,
          keepAwakeDelegate: _RecordingDelegate().call,
          isAppResumed: () => true,
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.keepAwake.set',
        const <String, Object?>{'leaseMs': 1000},
        'host-missing',
      );

      expect(
        (response['rejection']! as Map<String, Object?>)['details'],
        containsPair('missing', <String>['enabled']),
      );
    });

    testWidgets('status takes no arguments at all', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterServiceHost host = _host(
        PatchbayFlutterBridge(
          gates: _allowAll,
          keepAwakeDelegate: _RecordingDelegate().call,
          isAppResumed: () => true,
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.keepAwake.status',
        const <String, Object?>{'enabled': true},
        'host-status-args',
      );

      expect(
        (response['rejection']! as Map<String, Object?>)['code'],
        'invalidUiArguments',
      );
    });
  });
}

/// A delegate that records the transitions it was asked to make.
///
/// [failOn] names the one transition that throws, so a test can fail an engage
/// and a release independently.
final class _RecordingDelegate {
  _RecordingDelegate({this.failOn, this.before});

  final List<bool> calls = <bool>[];
  bool? failOn;

  /// Awaited before the transition is applied, so a test can suspend the
  /// delegate mid-call and land a `dispose()` inside that window.
  final Future<void> Function(bool enabled)? before;

  Future<void> call(bool enabled) async {
    await before?.call(enabled);
    if (enabled == failOn) throw const _KeepAwakeDelegateFailure();
    calls.add(enabled);
  }
}

final class _KeepAwakeDelegateFailure implements Exception {
  const _KeepAwakeDelegateFailure();
}

const PatchbayGateEvaluator _allowAll = PatchbayGateEvaluator(
  baseGate: _allow,
  consumerGate: _allowConsumer,
);

PatchbayGateDecision _allow() => const PatchbayGateDecision.allow();

PatchbayGateDecision _allowConsumer(String _) =>
    const PatchbayGateDecision.allow();

PatchbayKeepAwakeBridge _bridge({
  _RecordingDelegate? delegate,
  PatchbayGateEvaluator gates = _allowAll,
  Set<String> gateIds = const <String>{},
  bool Function()? isAppResumed,
  AppLifecycleState? Function()? lifecycleState,
}) => PatchbayKeepAwakeBridge(
  gates: gates,
  delegate: delegate?.call,
  gateIds: gateIds,
  isAppResumed: isAppResumed ?? () => true,
  lifecycleState: lifecycleState ?? () => AppLifecycleState.resumed,
);

Map<String, Object?> _payload(PatchbayInvocation invocation) {
  final Map<String, Object?> response = invocation.toJson();
  expect(response['admission'], 'accepted', reason: jsonEncode(response));
  return response['payload']! as Map<String, Object?>;
}

Map<String, Object?> _rejection(PatchbayInvocation invocation) {
  final Map<String, Object?> response = invocation.toJson();
  expect(response['admission'], 'rejected', reason: jsonEncode(response));
  return response['rejection']! as Map<String, Object?>;
}

/// Gives the screen back so no armed lease timer outlives the test.
Future<void> _release(
  WidgetTester tester,
  PatchbayKeepAwakeBridge bridge,
) async {
  await bridge.set(
    const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
  );
  await tester.pump();
}

/// Lets a lease expiry queued by the timer finish before the state is read.
Future<void> _drain(WidgetTester tester, PatchbayKeepAwakeBridge bridge) async {
  await tester.pump();
  await bridge.status();
  await tester.pump();
}

PatchbayFlutterServiceHost _host(PatchbayFlutterBridge bridge) =>
    PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.test',
      bridge: bridge,
      registrar: (String method, ServiceExtensionHandler handler) {},
    );

Future<List<Map<String, Object?>>> _catalogCommands(
  PatchbayFlutterBridge bridge,
) async {
  final Map<String, Object?> catalog = await _host(bridge).dispatchCatalog();
  return (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>();
}

Future<Set<Object?>> _catalogNames(PatchbayFlutterBridge bridge) async =>
    (await _catalogCommands(
      bridge,
    )).map((Map<String, Object?> command) => command['name']).toSet();

Future<Map<String, Object?>> _catalogCommand(
  PatchbayFlutterBridge bridge,
  String name,
) async => (await _catalogCommands(
  bridge,
)).firstWhere((Map<String, Object?> command) => command['name'] == name);
