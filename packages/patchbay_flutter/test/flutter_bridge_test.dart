import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
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
    for (final Map<String, Object?> command
        in commands.cast<Map<String, Object?>>()) {
      expect(command['factSources'], <String>['uiObserved']);
    }
  });

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

    testWidgets('text set bypasses formatter and onChanged', (tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController(
        text: 'old',
      );
      addTearDown(controller.dispose);
      var formatterCalls = 0;
      var changedCalls = 0;
      await _pumpTextField(
        tester,
        key: key,
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          _CountingUpperFormatter(() => formatterCalls += 1),
        ],
        onChanged: (_) => changedCalls += 1,
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
    });

    testWidgets('text enter applies formatters then calls public onChanged', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController(
        text: 'old',
      );
      addTearDown(controller.dispose);
      var formatterCalls = 0;
      final List<String> changed = <String>[];
      await _pumpTextField(
        tester,
        key: key,
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          _CountingUpperFormatter(() => formatterCalls += 1),
        ],
        onChanged: changed.add,
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
      expect(result.payload['value'], 'ABC');
    });

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
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TextField(
        key: key,
        controller: controller,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
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
