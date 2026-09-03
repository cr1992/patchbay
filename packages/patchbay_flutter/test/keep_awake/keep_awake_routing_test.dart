import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/keep_awake_fixtures.dart';

void main() {
  group('keep-awake serialisation', () {
    testWidgets('a release queued behind an awaiting engage is not lost', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final Completer<void> gateHeld = Completer<void>();
      final PatchbayKeepAwakeBridge bridge = createKeepAwakeBridge(
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

      expect(payloadOf(await engage)['outcome'], 'engaged');
      expect(payloadOf(await release)['outcome'], 'released');
      expect(delegate.calls, <bool>[true, false]);
      expect(bridge.enabled, isFalse);
    });
  });

  group('keep-awake host routing', () {
    testWidgets('set and status reach the bridge with the request id', (
      WidgetTester tester,
    ) async {
      final RecordingDelegate delegate = RecordingDelegate();
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        gates: allowAllGates,
        keepAwakeDelegate: delegate.call,
        isAppResumed: () => true,
      );
      final PatchbayFlutterServiceHost host = createHost(bridge);

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
      final PatchbayFlutterServiceHost host = createHost(
        PatchbayFlutterBridge(
          gates: allowAllGates,
          keepAwakeDelegate: RecordingDelegate().call,
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
      final PatchbayFlutterServiceHost host = createHost(
        PatchbayFlutterBridge(
          gates: allowAllGates,
          keepAwakeDelegate: RecordingDelegate().call,
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
      final PatchbayFlutterServiceHost host = createHost(
        PatchbayFlutterBridge(
          gates: allowAllGates,
          keepAwakeDelegate: RecordingDelegate().call,
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
