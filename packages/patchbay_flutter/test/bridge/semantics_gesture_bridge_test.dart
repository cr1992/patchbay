import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  group('Patchbay semantics tap', () {
    testWidgets('resolves the identifier and dispatches without a tree read', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'login.submit',
            label: 'Submit',
            button: true,
            onTap: () => taps += 1,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'login.submit'),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(result.payload['outcome'], 'dispatched');
      expect(result.payload['identifier'], 'login.submit');
      expect(result.payload['source'], 'uiObserved');
      expect(result.payload['generation'], isPositive);
      expect(taps, 1);
      bridge.semantics.dispose();
    });

    testWidgets('unknown identifier rejects with the mounted identifiers', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'login.submit',
            button: true,
            onTap: () {},
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'login.sumbit'),
      );

      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      expect(result.rejection?.details, isNotEmpty);
      expect(result.rejection?.details['identifier'], 'login.sumbit');
      expect(result.rejection?.details['matchCount'], 0);
      expect(
        result.rejection?.details['mountedIdentifiers'],
        contains('login.submit'),
      );
      bridge.semantics.dispose();
    });

    testWidgets('duplicate identifiers fail closed instead of tree order', (
      tester,
    ) async {
      var firstTaps = 0;
      var secondTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: <Widget>[
              Semantics(
                identifier: 'row.action',
                label: 'First',
                button: true,
                onTap: () => firstTaps += 1,
                child: const SizedBox(width: 20, height: 20),
              ),
              Semantics(
                identifier: 'row.action',
                label: 'Second',
                button: true,
                onTap: () => secondTaps += 1,
                child: const SizedBox(width: 20, height: 20),
              ),
            ],
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'row.action'),
      );

      expect(result.rejection?.code, 'uiSemanticsIdentifierAmbiguous');
      expect(result.rejection?.details['matchCount'], 2);
      final List<Object?> candidates =
          result.rejection!.details['candidates']! as List<Object?>;
      expect(candidates, hasLength(2));
      expect(
        candidates.cast<Map<String, Object?>>().map(
          (Map<String, Object?> candidate) => candidate['label'],
        ),
        containsAll(<String>['First', 'Second']),
      );
      expect(firstTaps, 0);
      expect(secondTaps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('stale caller generation is refused before the callback', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'login.submit',
            button: true,
            onTap: () => taps += 1,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final int observed =
          semanticsNodes(tree).singleWhere(
                (Map<String, Object?> node) =>
                    node['identifier'] == 'login.submit',
              )['generation']!
              as int;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(
          identifier: 'login.submit',
          expectedGeneration: observed + 1,
        ),
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(result.rejection?.details['expectedGeneration'], observed + 1);
      expect(result.rejection?.details['currentGeneration'], observed);
      expect(taps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('a remount during an awaited gate is fenced by the pin', (
      tester,
    ) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var firstTaps = 0;
      var replacementTaps = 0;
      Widget harness(Key key, VoidCallback onTap) => MaterialApp(
        home: Semantics(
          key: key,
          identifier: 'login.submit',
          button: true,
          onTap: onTap,
          child: const SizedBox(width: 20, height: 20),
        ),
      );
      await tester.pumpWidget(
        harness(const ValueKey<String>('first'), () => firstTaps += 1),
      );
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) => gate.future,
        ),
        semanticsActionPolicy: (_, _) =>
            const PatchbaySemanticsActionDecision.allow(
              gateIds: <String>{'ui.ready'},
            ),
        isAppResumed: () => true,
      );
      addTearDown(bridge.semantics.dispose);

      final Future<PatchbayInvocation> pending = bridge.semantics.tapIdentifier(
        identifier: 'login.submit',
      );
      await tester.pump();
      await tester.pumpWidget(
        harness(
          const ValueKey<String>('replacement'),
          () => replacementTaps += 1,
        ),
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(result.rejection?.details, isNotEmpty);
      expect(firstTaps, 0);
      expect(replacementTaps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('an identifier without a tap action is not promoted', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'settings.title',
            label: 'Settings',
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'settings.title'),
      );

      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      expect(result.rejection?.details['requestedAction'], 'tap');
      expect(result.rejection?.details['actions'], isNot(contains('tap')));
      bridge.semantics.dispose();
    });

    testWidgets('the host routes the command and keeps the requestId', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'login.submit',
            button: true,
            onTap: () => taps += 1,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );

      final Map<String, Object?> result = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', <String, Object?>{
          'identifier': 'login.submit',
        }, 'request-tap'),
      );
      final Map<String, Object?> rejected = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', <String, Object?>{
          'identifier': 'login.submit',
          'unexpected': true,
        }, 'request-bad-args'),
      );

      expect(result['requestId'], 'request-tap');
      expect(
        (result['payload']! as Map<String, Object?>)['outcome'],
        'dispatched',
      );
      expect(taps, 1);
      expect(rejected['requestId'], 'request-bad-args');
      expect(
        (rejected['rejection']! as Map<String, Object?>)['code'],
        'invalidUiArguments',
      );
      bridge.semantics.dispose();
    });

    test('the command is absent until a consumer policy exists', () async {
      Future<Set<Object?>> catalogNames(PatchbayFlutterBridge bridge) async {
        final Map<String, ServiceExtensionHandler> handlers =
            <String, ServiceExtensionHandler>{};
        PatchbayFlutterServiceHost(
          applicationId: 'dev.patchbay.flutter.test',
          bridge: bridge,
          registrar: (String method, ServiceExtensionHandler handler) {
            handlers[method] = handler;
          },
        ).register();
        final ServiceExtensionResponse response =
            await handlers[PatchbayServiceHost.catalogMethod]!(
              PatchbayServiceHost.catalogMethod,
              const <String, String>{},
            );
        final Map<String, Object?> catalog = Map<String, Object?>.from(
          jsonDecode(response.result!) as Map<String, dynamic>,
        );
        return (catalog['commands']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((Map<String, Object?> command) => command['name'])
            .toSet();
      }

      expect(
        await catalogNames(allowedBridge(PatchbayUiRegistry())),
        isNot(contains('ui.semantics.tap')),
      );
      expect(
        await catalogNames(interactiveBridge(PatchbayUiRegistry())),
        contains('ui.semantics.tap'),
      );
    });
  });
}
