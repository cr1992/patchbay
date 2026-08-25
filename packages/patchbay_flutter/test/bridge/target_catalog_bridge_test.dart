import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  test('Flutter host forwards versioned domain catalog semantics', () async {
    final PatchbayFlutterBridge bridge = allowedBridge(PatchbayUiRegistry());
    addTearDown(bridge.dispose);
    final _CountingCatalogProvider provider = _CountingCatalogProvider();
    final PatchbayFlutterServiceHost host =
        PatchbayFlutterServiceHost.withDomainCatalogProvider(
          applicationId: 'dev.patchbay.flutter.provider-test',
          bridge: bridge,
          domainCatalogProvider: provider,
          domainInvoke: (_, _, requestId) async =>
              PatchbayInvocation.accepted(requestId: requestId).toJson(),
        );

    await host.dispatchInvoke(
      'device.status',
      const <String, Object?>{},
      'provider-1',
    );
    await host.dispatchInvoke(
      'device.status',
      const <String, Object?>{},
      'provider-2',
    );
    expect(provider.reads, 1);

    expect(await host.dispatchCatalog(), contains('uiTargets'));
    expect(await host.dispatchCatalog(), contains('uiTargets'));
    expect(provider.reads, 3);

    await host.dispatchInvoke(
      'device.status',
      const <String, Object?>{},
      'provider-3',
    );
    expect(provider.reads, 3);
  });

  test('Flutter host forwards redacted audit configuration', () async {
    final List<PatchbayAuditEvent> delivered = <PatchbayAuditEvent>[];
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.audit-test',
      bridge: allowedBridge(PatchbayUiRegistry()),
      domainCatalog: () async => <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      },
      domainInvoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
      auditSink: delivered.add,
    );

    await host.dispatchInvoke('device.status', const <String, Object?>{
      'token': 'do-not-log',
    }, 'flutter-audit');
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1));
    expect(host.auditEvents, delivered);
    expect(delivered.single.toJson().toString(), isNot(contains('do-not-log')));
  });

  test('service catalog declares UI command fact sources', () async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.test',
      bridge: allowedBridge(PatchbayUiRegistry()),
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
    )..register();
    expect(host.appInstanceId, isNotEmpty);

    final ServiceExtensionResponse response =
        await handlers[PatchbayServiceHost.catalogMethod]!(
          PatchbayServiceHost.catalogMethod,
          const <String, String>{},
        );
    final Map<String, Object?> catalog = Map<String, Object?>.from(
      jsonDecode(response.result!) as Map<String, dynamic>,
    );
    final List<Object?> commands = catalog['commands']! as List<Object?>;
    final Set<Object?> names = commands
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> command) => command['name'])
        .toSet();
    expect(names, contains('ui.semantics.tree'));
    expect(names, isNot(contains('ui.semantics.action')));
    expect(
      <Object?, Object?>{
        for (final Map<String, Object?> command
            in commands.cast<Map<String, Object?>>())
          command['name']: command['factSources'],
      },
      <String, List<String>>{
        'ui.text.set': <String>['uiObserved'],
        'ui.text.enter': <String>['uiObserved'],
        'ui.semantics.tree': <String>['uiObserved'],
        'ui.wait': <String>['uiObserved'],
        'ui.keepAwake.set': <String>['appRecorded'],
        'ui.keepAwake.status': <String>['appRecorded'],
      },
    );
  });

  test(
    'every published UI descriptor is owned by the same dispatcher',
    () async {
      final List<String> externalCalls = <String>[];
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.registry-test',
        bridge: allowedBridge(PatchbayUiRegistry()),
        domainCatalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'device.status'},
          ],
        },
        domainInvoke: (command, arguments, requestId) async {
          externalCalls.add(command);
          return PatchbayInvocation.accepted(requestId: requestId).toJson();
        },
      );
      final Map<String, Object?> catalog = await host.dispatchCatalog();
      final List<String> protocolCommands = <String>[
        for (final Map<String, Object?> command
            in (catalog['commands']! as List<Object?>)
                .cast<Map<String, Object?>>())
          if ((command['name']! as String).startsWith('ui.'))
            command['name']! as String,
      ];

      for (final String command in protocolCommands) {
        await host.dispatchInvoke(command, const <String, Object?>{
          '__registryProbe': true,
        }, 'probe-$command');
      }
      expect(externalCalls, isEmpty);

      final Map<String, Object?> unavailable = await host.dispatchInvoke(
        'ui.capture',
        const <String, Object?>{},
        'unavailable-protocol-probe',
      );
      expect(
        unavailable['rejection'],
        containsPair('code', 'commandNotRegistered'),
      );
      expect(externalCalls, isEmpty);

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'external-probe',
      );
      expect(externalCalls, <String>['device.status']);
    },
  );

  test(
    'runtime UI catalog specializes only gates and policy defaults',
    () async {
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
        keepAwakeGates: const <String>{'consumer.keepAwake'},
        inspectPolicy: const PatchbayInspectPolicy(
          gates: <String>{'consumer.inspect'},
          defaultLease: Duration(minutes: 3),
        ),
      );
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.canonical-catalog',
        bridge: bridge,
      );
      final Map<String, Object?> catalog = await host.dispatchCatalog();
      final Map<String, Map<String, Object?>> actual =
          <String, Map<String, Object?>>{
            for (final Map<String, Object?> descriptor
                in (catalog['commands']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              descriptor['name']! as String: descriptor,
          };
      final List<PatchbayCommandDescriptor> expected =
          <PatchbayCommandDescriptor>[
            patchbayUiTextSetCommandDescriptor,
            patchbayUiTextEnterCommandDescriptor,
            patchbayUiSemanticsTreeCommandDescriptor,
            patchbayUiWaitCommandDescriptor,
            patchbayUiKeepAwakeSetCommandDescriptor.withRuntimeOverrides(
              gates: const <String>{'consumer.keepAwake'},
              parameterDefaults: <String, Object?>{
                'leaseMs': PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
              },
            ),
            patchbayUiKeepAwakeStatusCommandDescriptor,
            patchbayUiInspectStatusCommandDescriptor,
            patchbayUiInspectSelectCommandDescriptor.withRuntimeOverrides(
              gates: const <String>{'consumer.inspect'},
              parameterDefaults: <String, Object?>{
                'ttlMs': Duration(minutes: 3).inMilliseconds,
              },
            ),
          ];

      expect(
        actual.keys,
        expected.map((descriptor) => descriptor.name).toSet(),
      );
      for (final PatchbayCommandDescriptor canonical in expected) {
        expect(
          actual[canonical.name],
          canonical.toJson(),
          reason: canonical.name,
        );
      }
    },
  );

  test(
    'service catalog exposes semantics action only with consumer policy',
    () async {
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: interactiveBridge(PatchbayUiRegistry()),
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
      final Set<Object?> names = (catalog['commands']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((Map<String, Object?> command) => command['name'])
          .toSet();

      expect(names, contains('ui.semantics.action'));
    },
  );

  testWidgets('service host preserves requestId across Flutter bridges', (
    tester,
  ) async {
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    await pumpTextField(tester, key: key, controller: controller);
    final PatchbayFlutterBridge bridge = interactiveBridge(registry);
    addTearDown(bridge.dispose);
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.test',
      bridge: bridge,
    );
    final int generation = bridge.catalog().single.generation;

    final Map<String, Object?> textResult = await host.dispatchInvoke(
      'ui.text.set',
      <String, Object?>{
        'id': 'form.code',
        'generation': generation,
        'text': 'caller-owned',
      },
      'request-text',
    );
    final Map<String, Object?> enterResult = await host.dispatchInvoke(
      'ui.text.enter',
      <String, Object?>{
        'id': 'form.code',
        'generation': generation,
        'text': 'entered',
      },
      'request-enter',
    );
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: TextButton(
          onPressed: () => tapped = true,
          child: const Text('Action target'),
        ),
      ),
    );
    final Future<Map<String, Object?>> treePending = host.dispatchInvoke(
      'ui.semantics.tree',
      const <String, Object?>{},
      'request-tree',
    );
    final Map<String, Object?> treeResult = await pumpUntilComplete(
      tester,
      treePending,
    );
    final Map<String, Object?> treePayload =
        treeResult['payload']! as Map<String, Object?>;
    final Map<String, Object?> actionTarget =
        (treePayload['nodes']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere(
              (Map<String, Object?> node) => node['label'] == 'Action target',
            );
    final Future<Map<String, Object?>> actionPending = host
        .dispatchInvoke('ui.semantics.action', <String, Object?>{
          'nodeId': actionTarget['nodeId'],
          'generation': actionTarget['generation'],
          'action': 'tap',
        }, 'request-action');
    final Map<String, Object?> actionResult = await pumpUntilComplete(
      tester,
      actionPending,
    );

    expect(textResult['requestId'], 'request-text');
    expect(enterResult['requestId'], 'request-enter');
    expect(treeResult['requestId'], 'request-tree');
    expect(actionResult['requestId'], 'request-action');
    expect(controller.text, 'entered');
    expect(tapped, isTrue);
    bridge.dispose();
  });
}

final class _CountingCatalogProvider implements PatchbayCatalogProvider {
  int reads = 0;

  @override
  int get commandsRevision => 0;

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    reads += 1;
    return const PatchbayCatalogSample(
      commandsRevision: 0,
      catalog: <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      },
    );
  }
}
