import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/keep_awake_fixtures.dart';

void main() {
  group('keep-awake not wired', () {
    testWidgets('set is refused by name instead of vanishing from the API', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge();

      final Map<String, Object?> response = (await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        requestId: 'unwired-1',
      )).toJson();

      expect(response['admission'], 'rejected');
      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'keepAwakeNotWired');
      expect(rejection['notice'], contains('keepAwakeDelegate'));
      expect(bridge.wired, isFalse);
    });

    testWidgets('status answers honestly rather than refusing', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge();

      final Map<String, Object?> payload = payloadOf(await bridge.status());

      expect(payload['wired'], isFalse);
      expect(payload['enabled'], isFalse);
    });

    testWidgets('the command stays in the catalog with nothing wired', (
      WidgetTester tester,
    ) async {
      final Set<Object?> names = await catalogNamesOf(
        PatchbayFlutterBridge(gates: allowAllGates, isAppResumed: () => true),
      );

      expect(names, contains('ui.keepAwake.set'));
      expect(names, contains('ui.keepAwake.status'));
    });
  });

  group('keep-awake argument bounds', () {
    testWidgets('a release carries no lease', (WidgetTester tester) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
      );

      final Map<String, Object?> rejection = rejectionOf(
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
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
      );

      final Map<String, Object?> rejection = rejectionOf(
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
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
      );

      expect(
        rejectionOf(
          await bridge.set(
            const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 0),
          ),
        )['code'],
        'invalidKeepAwakeArguments',
      );
      expect(bridge.enabled, isFalse);
    });

    testWidgets('the ceiling itself is accepted', (WidgetTester tester) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
      );

      final Map<String, Object?> payload = payloadOf(
        await bridge.set(
          PatchbayKeepAwakeRequestWire(
            enabled: true,
            leaseMs: PatchbayKeepAwakeBridge.maxLease.inMilliseconds,
          ),
        ),
      );

      expect(payload['outcome'], 'engaged');

      await releaseScreen(tester, bridge);
    });
  });

  group('keep-awake lifecycle and gates', () {
    testWidgets('engaging from a backgrounded App is refused with the state', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
        isAppResumed: () => false,
        lifecycleState: () => AppLifecycleState.paused,
      );

      final Map<String, Object?> rejection = rejectionOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeLifecycleNotResumed');
      expect(rejection['details'], containsPair('lifecycleState', 'paused'));
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a background arriving during an awaited gate still refuses', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final Completer<void> gateHeld = Completer<void>();
      var resumed = true;
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
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

      expect(
        rejectionOf(await pending)['code'],
        'keepAwakeLifecycleNotResumed',
      );
      expect(delegate.calls, isEmpty);
    });

    testWidgets('a closed consumer gate refuses set and names the gate', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) =>
              const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
        ),
      );

      final Map<String, Object?> rejection = rejectionOf(
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
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
        gateIds: const <String>{'consumer.keepAwake'},
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) =>
              const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
        ),
      );

      expect(payloadOf(await bridge.status())['outcome'], 'observed');
    });

    testWidgets('a closed base gate still refuses status', (
      WidgetTester tester,
    ) async {
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(),
        gates: PatchbayGateEvaluator(
          baseGate: () =>
              const PatchbayGateDecision.reject(code: 'baseGateRejected'),
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );

      expect(rejectionOf(await bridge.status())['code'], 'baseGateRejected');
    });

    testWidgets('the declared gate ids reach the catalog descriptor', (
      WidgetTester tester,
    ) async {
      final Map<String, Object?> descriptor = await catalogCommandOf(
        PatchbayFlutterBridge(
          gates: allowAllGates,
          keepAwakeDelegate: RecordingDelegate().call,
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
      expect(
        lease['default'],
        PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
      );
      expect(lease['summary'], isNotNull);
    });

    testWidgets('the read command declares no side effect', (
      WidgetTester tester,
    ) async {
      final Map<String, Object?> descriptor = await catalogCommandOf(
        PatchbayFlutterBridge(gates: allowAllGates, isAppResumed: () => true),
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
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: RecordingDelegate(failOn: true),
      );

      final Map<String, Object?> rejection = rejectionOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeDelegateFailed');
      expect(
        rejection['details'],
        containsPair('failureType', 'KeepAwakeDelegateFailure'),
      );
      expect(bridge.enabled, isFalse);
      expect(payloadOf(await bridge.status())['enabled'], isFalse);
    });

    testWidgets('a throwing release leaves the hold retryable, not dropped', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
      );

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      final Map<String, Object?> rejection = rejectionOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
        ),
      );

      expect(rejection['code'], 'keepAwakeDelegateFailed');
      final Map<String, Object?> payload = payloadOf(await bridge.status());
      expect(payload['enabled'], isTrue);
      expect(payload['lastRelease'], isNull);
      expect(payload['lastReleaseFailure'], 'KeepAwakeDelegateFailure');

      delegate.failOn = null;
      final Map<String, Object?> retried = payloadOf(
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
      final RecordingDelegate delegate = RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
      );

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 1000),
      );
      await tester.pump(const Duration(milliseconds: 1001));
      await drainBridge(tester, bridge);

      expect(bridge.enabled, isTrue);
      expect(
        payloadOf(await bridge.status())['lastReleaseFailure'],
        'KeepAwakeDelegateFailure',
      );

      delegate.failOn = null;
      await tester.pump(const Duration(milliseconds: 1001));
      await drainBridge(tester, bridge);

      expect(bridge.enabled, isFalse);
      expect(delegate.calls, <bool>[true, false]);
      expect(payloadOf(await bridge.status())['lastRelease'], 'leaseExpired');
    });

    testWidgets('a later clean engage clears the stale failure', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate(failOn: false);
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
        delegate: delegate,
      );

      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
      );
      await bridge.set(
        const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
      );
      delegate.failOn = null;
      final Map<String, Object?> payload = payloadOf(
        await bridge.set(
          const PatchbayKeepAwakeRequestWire(enabled: true, leaseMs: 60000),
        ),
      );

      expect(payload['outcome'], 'renewed');
      expect(payload['lastReleaseFailure'], isNull);
      expect(payloadOf(await bridge.status())['lastReleaseFailure'], isNull);

      await releaseScreen(tester, bridge);
    });
  });
}
