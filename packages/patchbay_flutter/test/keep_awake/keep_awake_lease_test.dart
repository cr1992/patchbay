import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/keep_awake_fixtures.dart';

void main() {
  group('keep-awake default', () {
    testWidgets('nothing is engaged and the delegate is never called', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      final Map<String, Object?> payload = payloadOf(
        await bridge.status(requestId: 'status-1'),
      );

      expect(payload['outcome'], 'observed');
      expect(payload['source'], 'appRecorded');
      expect(payload['wired'], isTrue);
      expect(payload['enabled'], isFalse);
      expect(payload['leaseMs'], isNull);
      expect(payload['leaseRemainingMs'], isNull);
      expect(payload['lastRelease'], isNull);
      expect(delegate.calls, isEmpty);
    });

    testWidgets('the request id the caller sent comes back', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge();
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
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      final Map<String, Object?> payload = payloadOf(
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

      await releaseScreen(tester, bridge);
    });

    testWidgets('an explicit lease is the one that is reported and armed', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
      );

      final Map<String, Object?> payload = payloadOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
          requestId: 'on-lease',
        ),
      );

      expect(payload['leaseMs'], 60000);
      expect(payload['leaseRemainingMs'], lessThanOrEqualTo(60000));

      await releaseScreen(tester, bridge);
    });

    testWidgets('a second on renews without a second delegate call', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      await tester.pump(const Duration(seconds: 30));
      final Map<String, Object?> payload = payloadOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
        ),
      );

      expect(payload['outcome'], 'renewed');
      expect(delegate.calls, <bool>[true]);
      expect(payload['leaseRemainingMs'], greaterThan(30000));

      await releaseScreen(tester, bridge);
    });
  });

  group('keep-awake release', () {
    testWidgets('off releases now and names the operator as the reason', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
      );
      final Map<String, Object?> payload = payloadOf(
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
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      final Map<String, Object?> payload = payloadOf(
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
      final RecordingDelegate delegate = RecordingDelegate();
      var resumed = true;
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
        isAppResumed: () => resumed,
      );

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
      );
      resumed = false;
      final Map<String, Object?> payload = payloadOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(payload['outcome'], 'released');
      expect(delegate.calls, <bool>[true, false]);
    });
  });

  group('keep-awake auto-release', () {
    testWidgets('an expired lease releases on its own', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      expect(bridge.enabled, isTrue);

      await tester.pump(const Duration(milliseconds: 1001));
      await drainBridge(tester, bridge);

      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
      final Map<String, Object?> payload = payloadOf(await bridge.status());
      expect(payload['enabled'], isFalse);
      expect(payload['lastRelease'], 'leaseExpired');
      expect(payload['leaseRemainingMs'], isNull);
    });

    testWidgets('reading the state does not extend the lease', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await bridge.status();
      await tester.pump(const Duration(milliseconds: 200));
      await drainBridge(tester, bridge);

      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('an operator release wins over the timer that was queued', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      await tester.pump(const Duration(milliseconds: 2000));
      await drainBridge(tester, bridge);

      expect(delegate.calls, <bool>[true, false]);
      expect(payloadOf(await bridge.status())['lastRelease'], 'operatorRequest');
    });

    testWidgets('host disposal releases a live hold', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      bridge.dispose();
      await tester.pump();

      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
      expect(payloadOf(await bridge.status())['lastRelease'], 'hostDisposed');
    });

    testWidgets('disposal with nothing held asks the delegate for nothing', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      bridge.dispose();
      await tester.pump();

      expect(delegate.calls, isEmpty);
    });

    testWidgets('the bridge disposes with the Flutter bridge that owns it', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        gates: allowAllGates,
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

  group('keep-awake dispose race', () {
    testWidgets('a dispose during an awaited gate cannot engage afterwards', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final Completer<void> gateEntered = Completer<void>();
      final Completer<void> gateHeld = Completer<void>();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
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
      await gateEntered.future;
      bridge.dispose();
      gateHeld.complete();

      expect(rejectionOf(await pending)['code'], 'keepAwakeHostDisposed');
      expect(delegate.calls, isEmpty);
      expect(bridge.enabled, isFalse);
      await tester.pump(PatchbayKeepAwakeBridge.maxLease);
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a dispose while the delegate engages gives the screen back', (
      WidgetTester tester,
    ) async {
      final Completer<void> entered = Completer<void>();
      final Completer<void> engaging = Completer<void>();
      final RecordingDelegate delegate = RecordingDelegate(
        before: (bool enabled) async {
          if (!enabled) return;
          entered.complete();
          await engaging.future;
        },
      );
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      final Future<PatchbayInvocation> pending = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      await entered.future;
      bridge.dispose();
      engaging.complete();

      expect(rejectionOf(await pending)['code'], 'keepAwakeHostDisposed');
      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
      await tester.pump(const Duration(minutes: 2));
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('dispose queues behind an in-flight operator release', (
      WidgetTester tester,
    ) async {
      final Completer<void> releaseEntered = Completer<void>();
      final Completer<void> releaseHeld = Completer<void>();
      var releaseCalls = 0;
      final RecordingDelegate delegate = RecordingDelegate(
        before: (bool enabled) async {
          if (enabled) return;
          releaseCalls += 1;
          if (releaseCalls == 1) {
            releaseEntered.complete();
            await releaseHeld.future;
          }
        },
      );
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      final Future<PatchbayInvocation> pending = bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      await releaseEntered.future;

      bridge.dispose();
      await tester.pump();
      expect(releaseCalls, 1);

      releaseHeld.complete();
      await pending;
      await tester.pump();
      expect(releaseCalls, 1);
      expect(delegate.calls, <bool>[true, false]);
    });

    testWidgets('a request that arrives after teardown is refused outright', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(delegate: delegate);

      bridge.dispose();

      expect(
        rejectionOf(
          await bridge.set(
            const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
          ),
        )['code'],
        'keepAwakeHostDisposed',
      );
      expect(delegate.calls, isEmpty);
      expect(payloadOf(await bridge.status())['enabled'], isFalse);
    });
  });
}
