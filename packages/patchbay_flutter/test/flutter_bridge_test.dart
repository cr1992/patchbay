import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  test('Flutter host forwards redacted audit configuration', () async {
    final List<PatchbayAuditEvent> delivered = <PatchbayAuditEvent>[];
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.audit-test',
      bridge: _allowedBridge(PatchbayUiRegistry()),
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
      bridge: _allowedBridge(PatchbayUiRegistry()),
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
    // Per command, not a blanket rule: `uiObserved` claims Patchbay looked at
    // the live Flutter tree, and only the commands that do may say it.
    // `ui.keepAwake.*` reports what the App asked its host to do and never
    // reads the platform back, so it is `appRecorded` — declaring it
    // `uiObserved` would present bookkeeping as a device observation.
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
        bridge: _allowedBridge(PatchbayUiRegistry()),
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
        bridge: _interactiveBridge(PatchbayUiRegistry()),
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
    await _pumpTextField(tester, key: key, controller: controller);
    final PatchbayFlutterBridge bridge = _interactiveBridge(registry);
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
    final Map<String, Object?> treeResult = await _pumpUntilComplete(
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
    final Map<String, Object?> actionResult = await _pumpUntilComplete(
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

  group('Patchbay semantics tree', () {
    testWidgets('observes standard controls without PatchbayKey', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TextButton(onPressed: () {}, child: const Text('Settings')),
                const TextField(decoration: InputDecoration(labelText: 'Name')),
              ],
            ),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await _semanticsSnapshot(
        tester,
        bridge,
      );
      final List<Map<String, Object?>> nodes = _semanticsNodes(result);
      final Map<String, Object?> settings = nodes.singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Settings',
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(result.payload['source'], 'uiObserved');
      expect(settings['actions'], contains('tap'));
      expect(settings['generation'], isPositive);
      expect(nodes, isNotEmpty);
      bridge.semantics.dispose();
    });

    testWidgets('tap dispatches the existing Flutter callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => Scaffold(
              body: TextButton(
                onPressed: () => setState(() => tapped = true),
                child: Text(tapped ? 'Opened' : 'Settings'),
              ),
            ),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = _semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> node) => node['label'] == 'Settings');

      final PatchbayInvocation result = await _semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.tap,
      );

      expect(result.payload['outcome'], 'dispatched');
      expect(tapped, isTrue);
      expect(find.text('Opened'), findsOneWidget);
      bridge.semantics.dispose();
    });

    testWidgets('wrong generation fails closed before callback', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TextButton(
            onPressed: () => taps += 1,
            child: const Text('Settings'),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = _semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> node) => node['label'] == 'Settings');

      final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
        nodeId: target['nodeId']! as int,
        generation: (target['generation']! as int) + 1,
        action: PatchbaySemanticsAction.tap,
      );
      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(taps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('focus scroll and setText dispatch only declared actions', (
      tester,
    ) async {
      final List<String> calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            label: 'Action probe',
            focusable: true,
            onFocus: () => calls.add('focus'),
            onScrollDown: () => calls.add('scrollDown'),
            onSetText: (String text) => calls.add('setText:$text'),
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = _semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Action probe',
      );

      await _semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.focus,
      );
      await _semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.scrollDown,
      );
      final PatchbayInvocation textResult = await _semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.setText,
        text: 'hello',
      );

      expect(calls, <String>['focus', 'scrollDown', 'setText:hello']);
      expect(textResult.payload['outcome'], 'dispatched');
      expect(textResult.payload, isNot(contains('value')));
      bridge.semantics.dispose();
    });

    testWidgets('late gate continuation cannot act on a replacement node', (
      tester,
    ) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var firstTaps = 0;
      var replacementTaps = 0;
      Widget target(Key key, VoidCallback onTap) => MaterialApp(
        home: Semantics(
          key: key,
          label: 'Replaceable',
          button: true,
          onTap: onTap,
          child: const SizedBox(width: 20, height: 20),
        ),
      );
      await tester.pumpWidget(
        target(const ValueKey<String>('first'), () => firstTaps += 1),
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
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = _semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Replaceable',
      );
      final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
        nodeId: observed['nodeId']! as int,
        generation: observed['generation']! as int,
        action: PatchbaySemanticsAction.tap,
      );
      await tester.pump();

      await tester.pumpWidget(
        target(
          const ValueKey<String>('replacement'),
          () => replacementTaps += 1,
        ),
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        pending,
      );

      expect(
        result.rejection?.code,
        anyOf('uiSemanticsNodeNotFound', 'uiSemanticsGenerationStale'),
      );
      expect(firstTaps, 0);
      expect(replacementTaps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('late gate continuation cannot act after app is paused', (
      tester,
    ) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var resumed = true;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            label: 'Pauseable',
            button: true,
            onTap: () => taps += 1,
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
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
        isAppResumed: () => resumed,
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = _semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Pauseable',
      );
      final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
        nodeId: observed['nodeId']! as int,
        generation: observed['generation']! as int,
        action: PatchbaySemanticsAction.tap,
      );
      await tester.pump();

      resumed = false;
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiLifecycleNotResumed');
      expect(taps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('late sensitive transition still requires stdin', (
      tester,
    ) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var obscured = false;
      String? receivedText;
      late StateSetter updateField;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              updateField = setState;
              return Semantics(
                label: 'Sensitive transition',
                obscured: obscured,
                onSetText: (String text) => receivedText = text,
                child: const SizedBox(width: 20, height: 20),
              );
            },
          ),
        ),
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
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = _semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Sensitive transition',
      );
      final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
        nodeId: observed['nodeId']! as int,
        generation: observed['generation']! as int,
        action: PatchbaySemanticsAction.setText,
        text: 'must-not-dispatch',
      );
      await tester.pump();

      updateField(() => obscured = true);
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'sensitiveInputRequiresStdin');
      expect(receivedText, isNull);
      bridge.semantics.dispose();
    });

    testWidgets('obscured text never appears in the semantics payload', (
      tester,
    ) async {
      final TextEditingController controller = TextEditingController(
        text: 'secret-value',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(controller: controller, obscureText: true),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final String encoded = jsonEncode(tree.toJson());
      final Map<String, Object?> field = _semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) =>
            (node['flags']! as List<Object?>).contains('isObscured'),
      );

      expect(encoded, isNot(contains('secret-value')));
      expect(field['valueRedacted'], isTrue);
      expect(field, isNot(contains('value')));
      bridge.semantics.dispose();
    });

    testWidgets('node limit is explicit instead of silently dropping nodes', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: <Widget>[
              for (var i = 0; i < 5; i++)
                TextButton(onPressed: () {}, child: Text('Item $i')),
            ],
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final Future<PatchbayInvocation> pending = bridge.semantics.snapshot(
        maxNodes: 2,
      );
      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.payload['nodeCount'], 2);
      expect(result.payload['truncated'], isTrue);
      bridge.semantics.dispose();
    });
  });

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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await _pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'login.sumbit'),
      );

      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      // A rejection without details sends the caller back to a full tree dump,
      // which is exactly the round trip this command exists to remove.
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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await _pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await _semanticsSnapshot(tester, bridge);
      final int observed =
          _semanticsNodes(tree).singleWhere(
                (Map<String, Object?> node) =>
                    node['identifier'] == 'login.submit',
              )['generation']!
              as int;

      final PatchbayInvocation result = await _pumpUntilComplete(
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

      // No caller generation: the fence has to come from the pin the bridge
      // takes itself before the gate, not from anything the CLI supplied.
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
      final PatchbayInvocation result = await _pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await _pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = _interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );

      final Map<String, Object?> result = await _pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', <String, Object?>{
          'identifier': 'login.submit',
        }, 'request-tap'),
      );
      final Map<String, Object?> rejected = await _pumpUntilComplete(
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
        await catalogNames(_allowedBridge(PatchbayUiRegistry())),
        isNot(contains('ui.semantics.tap')),
      );
      expect(
        await catalogNames(_interactiveBridge(PatchbayUiRegistry())),
        contains('ui.semantics.tap'),
      );
    });
  });

  group('Patchbay text target', () {
    testWidgets('catalog exposes only mounted public-API operations', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'login.phone',
        registry: registry,
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);

      await _pumpTextField(tester, key: key, controller: controller);

      final PatchbayUiTargetDescriptor descriptor = registry.catalog().single;
      expect(descriptor.id, 'login.phone');
      expect(descriptor.mounted, isTrue);
      expect(descriptor.ambiguous, isFalse);
      expect(descriptor.generation, 1);
      expect(descriptor.operations, <PatchbayUiOperation>{
        PatchbayUiOperation.textSet,
        PatchbayUiOperation.textEnter,
      });
    });

    testWidgets(
      'text set replaces text without formatter or submit callbacks',
      (tester) async {
        final PatchbayUiRegistry registry = PatchbayUiRegistry();
        final PatchbayKey key = PatchbayKey.text(
          'form.code',
          registry: registry,
        );
        final TextEditingController controller = TextEditingController(
          text: 'old',
        );
        addTearDown(controller.dispose);
        var formatterCalls = 0;
        var changedCalls = 0;
        var submittedCalls = 0;
        await _pumpTextField(
          tester,
          key: key,
          controller: controller,
          inputFormatters: <TextInputFormatter>[
            _CountingUpperFormatter(() => formatterCalls += 1),
          ],
          onChanged: (_) => changedCalls += 1,
          onSubmitted: (_) => submittedCalls += 1,
        );
        final PatchbayFlutterBridge bridge = _allowedBridge(registry);
        final int generation = bridge.catalog().single.generation;

        final PatchbayInvocation result = await bridge.setText(
          id: 'form.code',
          generation: generation,
          text: 'abc',
        );
        await tester.pump();

        expect(result.admission, PatchbayAdmission.accepted);
        expect(controller.text, 'abc');
        expect(formatterCalls, 0);
        expect(changedCalls, 0);
        expect(submittedCalls, 0);
        expect(result.payload['value'], 'abc');
      },
    );

    testWidgets(
      'text enter applies formatters then calls only public onChanged',
      (tester) async {
        final PatchbayUiRegistry registry = PatchbayUiRegistry();
        final PatchbayKey key = PatchbayKey.text(
          'form.code',
          registry: registry,
        );
        final TextEditingController controller = TextEditingController(
          text: 'old',
        );
        addTearDown(controller.dispose);
        var formatterCalls = 0;
        final List<String> changed = <String>[];
        final List<String> submitted = <String>[];
        await _pumpTextField(
          tester,
          key: key,
          controller: controller,
          inputFormatters: <TextInputFormatter>[
            _CountingUpperFormatter(() => formatterCalls += 1),
          ],
          onChanged: changed.add,
          onSubmitted: submitted.add,
        );
        final PatchbayFlutterBridge bridge = _allowedBridge(registry);
        final int generation = bridge.catalog().single.generation;

        final PatchbayInvocation result = await bridge.enterText(
          id: 'form.code',
          generation: generation,
          text: 'abc',
        );
        await tester.pump();

        expect(result.admission, PatchbayAdmission.accepted);
        expect(controller.text, 'ABC');
        expect(formatterCalls, 1);
        expect(changed, <String>['ABC']);
        expect(submitted, isEmpty);
        expect(result.payload['value'], 'ABC');
      },
    );

    testWidgets('base and descriptor gates both fail closed', (tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'form.code',
        registry: registry,
        operationGates: const <PatchbayUiOperation, Set<String>>{
          PatchbayUiOperation.textEnter: <String>{'consumer.ready'},
        },
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pumpTextField(tester, key: key, controller: controller);
      final int generation = registry.catalog().single.generation;
      var consumerCalls = 0;
      final PatchbayFlutterBridge baseRejected = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () =>
              const PatchbayGateDecision.reject(code: 'hostDisabled'),
          consumerGate: (_) {
            consumerCalls += 1;
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final PatchbayInvocation baseResult = await baseRejected.enterText(
        id: 'form.code',
        generation: generation,
        text: 'blocked',
      );
      expect(baseResult.rejection?.code, 'hostDisabled');
      expect(consumerCalls, 0);
      expect(controller.text, isEmpty);

      final PatchbayFlutterBridge consumerRejected = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String gateId) => PatchbayGateDecision.reject(
            code: 'consumerNotReady',
            notice: gateId,
          ),
        ),
      );
      final PatchbayInvocation consumerResult = await consumerRejected
          .enterText(id: 'form.code', generation: generation, text: 'blocked');
      expect(consumerResult.rejection?.code, 'consumerNotReady');
      expect(consumerResult.rejection?.details['gateId'], 'consumer.ready');
      expect(controller.text, isEmpty);
    });

    testWidgets('sensitive values require stdin and never echo plaintext', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'login.password',
        sensitive: true,
        registry: registry,
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pumpTextField(tester, key: key, controller: controller);
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
      final int generation = bridge.catalog().single.generation;

      final PatchbayInvocation rejected = await bridge.setText(
        id: 'login.password',
        generation: generation,
        text: 'secret',
      );
      expect(rejected.rejection?.code, 'sensitiveInputRequiresStdin');
      expect(controller.text, isEmpty);

      final PatchbayInvocation accepted = await bridge.setText(
        id: 'login.password',
        generation: generation,
        text: 'secret',
        inputWasStdin: true,
      );
      expect(controller.text, 'secret');
      expect(accepted.payload['valueRedacted'], isTrue);
      expect(accepted.payload.values, isNot(contains('secret')));
    });

    testWidgets('duplicate mounted IDs reject instead of picking tree order', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TextField(key: first, controller: firstController),
                TextField(key: second, controller: secondController),
              ],
            ),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
      final PatchbayUiTargetDescriptor descriptor = bridge.catalog().single;

      expect(descriptor.ambiguous, isTrue);
      expect(descriptor.operations, isEmpty);
      final PatchbayInvocation result = await bridge.setText(
        id: 'form.code',
        generation: descriptor.generation,
        text: 'never applied',
      );
      expect(result.rejection?.code, 'uiTargetAmbiguous');
      expect(firstController.text, isEmpty);
      expect(secondController.text, isEmpty);
    });

    testWidgets('remount assigns a new generation and fences stale calls', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await _pumpTextField(tester, key: first, controller: firstController);
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
      final int oldGeneration = bridge.catalog().single.generation;

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await _pumpTextField(tester, key: second, controller: secondController);
      final int newGeneration = bridge.catalog().single.generation;

      expect(newGeneration, greaterThan(oldGeneration));
      final PatchbayInvocation result = await bridge.setText(
        id: 'form.code',
        generation: oldGeneration,
        text: 'stale',
      );
      expect(result.rejection?.code, 'uiGenerationStale');
      expect(secondController.text, isEmpty);
    });

    testWidgets('late gate continuation cannot target a replacement', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await _pumpTextField(tester, key: first, controller: firstController);
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () => gate.future,
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      final int generation = bridge.catalog().single.generation;
      final Future<PatchbayInvocation> pending = bridge.setText(
        id: 'form.code',
        generation: generation,
        text: 'late',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await _pumpTextField(tester, key: second, controller: secondController);
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pending;

      expect(result.rejection?.code, 'uiGenerationStale');
      expect(secondController.text, isEmpty);
    });
  });

  testWidgets(
    'PatchbayKey keeps ordinary GlobalKey state reparenting semantics',
    (tester) async {
      final PatchbayKey key = PatchbayKey.text(
        'probe.state',
        registry: PatchbayUiRegistry(),
      );

      await tester.pumpWidget(_ReparentHarness(probeKey: key, left: true));
      await tester.tap(find.text('0'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(_ReparentHarness(probeKey: key, left: false));
      expect(find.text('1'), findsOneWidget);
    },
  );
}

PatchbayFlutterBridge _allowedBridge(PatchbayUiRegistry registry) =>
    PatchbayFlutterBridge(
      registry: registry,
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
    );

PatchbayFlutterBridge _interactiveBridge(PatchbayUiRegistry registry) =>
    PatchbayFlutterBridge(
      registry: registry,
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      semanticsActionPolicy: (_, _) =>
          const PatchbaySemanticsActionDecision.allow(),
      isAppResumed: () => true,
    );

Future<PatchbayInvocation> _semanticsSnapshot(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final Future<PatchbayInvocation> pending = bridge.semantics.snapshot();
  return _pumpUntilComplete(tester, pending);
}

Future<PatchbayInvocation> _semanticsInvoke(
  WidgetTester tester,
  PatchbayFlutterBridge bridge, {
  required Map<String, Object?> node,
  required PatchbaySemanticsAction action,
  String? text,
}) async {
  final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
    nodeId: node['nodeId']! as int,
    generation: node['generation']! as int,
    action: action,
    text: text,
  );
  return _pumpUntilComplete(tester, pending);
}

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 20 && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) {
    throw StateError('Patchbay test operation did not complete in 20 frames');
  }
  return pending;
}

List<Map<String, Object?>> _semanticsNodes(PatchbayInvocation result) =>
    (result.payload['nodes']! as List<Object?>).cast<Map<String, Object?>>();

Future<void> _pumpTextField(
  WidgetTester tester, {
  required PatchbayKey key,
  required TextEditingController controller,
  List<TextInputFormatter>? inputFormatters,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TextField(
        key: key,
        controller: controller,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    ),
  ),
);

final class _CountingUpperFormatter extends TextInputFormatter {
  _CountingUpperFormatter(this.onCall);

  final VoidCallback onCall;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    onCall();
    final String text = newValue.text.toUpperCase();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

final class _ReparentHarness extends StatelessWidget {
  const _ReparentHarness({required this.probeKey, required this.left});

  final PatchbayKey probeKey;
  final bool left;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Row(
      children: <Widget>[
        if (left) _CounterProbe(key: probeKey) else const SizedBox(),
        if (left) const SizedBox() else _CounterProbe(key: probeKey),
      ],
    ),
  );
}

final class _CounterProbe extends StatefulWidget {
  const _CounterProbe({super.key});

  @override
  State<_CounterProbe> createState() => _CounterProbeState();
}

final class _CounterProbeState extends State<_CounterProbe> {
  int count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count += 1),
    child: Text('$count'),
  );
}
