import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await semanticsSnapshot(
        tester,
        bridge,
      );
      final List<Map<String, Object?>> nodes = semanticsNodes(result);
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> node) => node['label'] == 'Settings');

      final PatchbayInvocation result = await semanticsInvoke(
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> node) => node['label'] == 'Settings');

      final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
        nodeId: target['nodeId']! as int,
        generation: (target['generation']! as int) + 1,
        action: PatchbaySemanticsAction.tap,
      );
      final PatchbayInvocation result = await pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> target = semanticsNodes(tree).singleWhere(
        (Map<String, Object?> node) => node['label'] == 'Action probe',
      );

      await semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.focus,
      );
      await semanticsInvoke(
        tester,
        bridge,
        node: target,
        action: PatchbaySemanticsAction.scrollDown,
      );
      final PatchbayInvocation textResult = await semanticsInvoke(
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
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = semanticsNodes(tree).singleWhere(
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
      final PatchbayInvocation result = await pumpUntilComplete(
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
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = semanticsNodes(tree).singleWhere(
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
      final PatchbayInvocation result = await pumpUntilComplete(
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
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> observed = semanticsNodes(tree).singleWhere(
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
      final PatchbayInvocation result = await pumpUntilComplete(
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final String encoded = jsonEncode(tree.toJson());
      final Map<String, Object?> field = semanticsNodes(tree).singleWhere(
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
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final Future<PatchbayInvocation> pending = bridge.semantics.snapshot(
        maxNodes: 2,
      );
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.payload['nodeCount'], 2);
      expect(result.payload['truncated'], isTrue);
      bridge.semantics.dispose();
    });
  });
}
