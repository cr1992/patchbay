import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  testWidgets('identifier action dispatches with the caller generation fence', (
    tester,
  ) async {
    final List<String> calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Semantics(
          identifier: 'profile.action',
          label: 'Action probe',
          focusable: true,
          onTap: () => calls.add('tap'),
          onFocus: () => calls.add('focus'),
          onScrollUp: () => calls.add('scrollUp'),
          onScrollDown: () => calls.add('scrollDown'),
          onScrollLeft: () => calls.add('scrollLeft'),
          onScrollRight: () => calls.add('scrollRight'),
          onSetText: (String value) => calls.add('setText:$value'),
          child: const SizedBox(width: 20, height: 20),
        ),
      ),
    );
    final PatchbayFlutterBridge bridge = interactiveBridge(
      PatchbayUiRegistry(),
    );
    addTearDown(bridge.dispose);
    final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
    final Map<String, Object?> target = semanticsNodes(tree).singleWhere(
      (Map<String, Object?> node) => node['identifier'] == 'profile.action',
    );
    final int generation = target['generation']! as int;

    for (final PatchbaySemanticsAction action in <PatchbaySemanticsAction>[
      PatchbaySemanticsAction.tap,
      PatchbaySemanticsAction.focus,
      PatchbaySemanticsAction.scrollUp,
      PatchbaySemanticsAction.scrollDown,
      PatchbaySemanticsAction.scrollLeft,
      PatchbaySemanticsAction.scrollRight,
    ]) {
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.invokeIdentifier(
          identifier: 'profile.action',
          generation: generation,
          action: action,
        ),
      );
      expect(result.payload, <String, Object?>{
        'outcome': 'dispatched',
        'source': 'uiObserved',
        'identifier': 'profile.action',
        'nodeId': target['nodeId'],
        'generation': generation,
        'action': action.name,
        'beforeTreeRevision': isA<int>(),
        'afterTreeRevision': isA<int>(),
      });
    }
    final PatchbayInvocation textResult = await pumpUntilComplete(
      tester,
      bridge.semantics.invokeIdentifier(
        identifier: 'profile.action',
        generation: generation,
        action: PatchbaySemanticsAction.setText,
        text: 'private value',
      ),
    );

    expect(calls, <String>[
      'tap',
      'focus',
      'scrollUp',
      'scrollDown',
      'scrollLeft',
      'scrollRight',
      'setText:private value',
    ]);
    expect(textResult.payload['length'], 13);
    expect(textResult.payload, isNot(contains('text')));
    expect(textResult.payload.values, isNot(contains('private value')));
    bridge.dispose();
  });

  testWidgets('stale caller generation cannot select the current instance', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Semantics(
          identifier: 'app.save',
          button: true,
          onTap: () => taps += 1,
          child: const SizedBox(width: 20, height: 20),
        ),
      ),
    );
    final PatchbayFlutterBridge bridge = interactiveBridge(
      PatchbayUiRegistry(),
    );
    addTearDown(bridge.dispose);
    final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
    final Map<String, Object?> target = semanticsNodes(tree).singleWhere(
      (Map<String, Object?> node) => node['identifier'] == 'app.save',
    );

    final PatchbayInvocation result = await pumpUntilComplete(
      tester,
      bridge.semantics.invokeIdentifier(
        identifier: 'app.save',
        generation: (target['generation']! as int) + 1,
        action: PatchbaySemanticsAction.tap,
      ),
    );

    expect(result.rejection?.code, 'uiSemanticsGenerationStale');
    expect(taps, 0);
    bridge.dispose();
  });

  testWidgets('gate-time replacement is rejected without retrying', (
    tester,
  ) async {
    final Completer<PatchbayGateDecision> gate =
        Completer<PatchbayGateDecision>();
    var firstTaps = 0;
    var replacementTaps = 0;
    Widget target(Key key, VoidCallback onTap) => MaterialApp(
      home: Semantics(
        key: key,
        identifier: 'app.replaceable',
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
    addTearDown(bridge.dispose);
    final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
    final int generation =
        semanticsNodes(tree).singleWhere(
              (Map<String, Object?> node) =>
                  node['identifier'] == 'app.replaceable',
            )['generation']!
            as int;
    final Future<PatchbayInvocation> pending = bridge.semantics
        .invokeIdentifier(
          identifier: 'app.replaceable',
          generation: generation,
          action: PatchbaySemanticsAction.tap,
        );
    await tester.pump();

    await tester.pumpWidget(
      target(const ValueKey<String>('replacement'), () => replacementTaps += 1),
    );
    await tester.pump();
    gate.complete(const PatchbayGateDecision.allow());
    final PatchbayInvocation result = await pumpUntilComplete(tester, pending);

    expect(result.rejection?.code, 'uiSemanticsGenerationStale');
    expect(firstTaps, 0);
    expect(replacementTaps, 0);
    bridge.dispose();
  });

  testWidgets('public bridge refuses actions outside the frozen allowlist', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Semantics(
          identifier: 'app.long-press',
          onLongPress: () {},
          child: const SizedBox(width: 20, height: 20),
        ),
      ),
    );
    final PatchbayFlutterBridge bridge = interactiveBridge(
      PatchbayUiRegistry(),
    );
    addTearDown(bridge.dispose);

    final PatchbayInvocation result = await bridge.semantics.invokeIdentifier(
      identifier: 'app.long-press',
      generation: 1,
      action: PatchbaySemanticsAction.longPress,
    );

    expect(result.rejection?.code, 'invalidUiArguments');
  });
}
