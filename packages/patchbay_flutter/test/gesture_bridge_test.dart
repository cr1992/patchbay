import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  test(
    'gesture policy absence removes all gesture commands from catalog',
    () async {
      final PatchbayFlutterBridge disabled = _bridge();
      final PatchbayFlutterBridge enabled = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
      );
      addTearDown(disabled.dispose);
      addTearDown(enabled.dispose);

      final Set<String> disabledNames = await _catalogNames(disabled);
      final Set<String> enabledNames = await _catalogNames(enabled);

      expect(
        disabledNames.where((name) => name.startsWith('ui.gesture.')),
        isEmpty,
      );
      expect(
        enabledNames,
        containsAll(<String>{
          'ui.gesture.pressHold',
          'ui.gesture.drag',
          'ui.gesture.fling',
        }),
      );
    },
  );

  test(
    'VM extension and direct seam use the same gesture dispatcher',
    () async {
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
      );
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.gesture-parity',
        bridge: bridge,
        registrar: (method, handler) => handlers[method] = handler,
      )..register();
      const Map<String, Object?> arguments = <String, Object?>{
        'identifier': 'target',
        'generation': 1,
        'start': <String, Object?>{'x': 2, 'y': 0.5},
      };

      final Map<String, Object?> direct = await host.dispatchInvoke(
        'ui.gesture.pressHold',
        arguments,
        'gesture-parity',
      );
      final ServiceExtensionResponse vm =
          await handlers[PatchbayServiceHost.invokeMethod]!(
            PatchbayServiceHost.invokeMethod,
            <String, String>{
              'command': 'ui.gesture.pressHold',
              'requestId': 'gesture-parity',
              'args': jsonEncode(arguments),
            },
          );

      expect(jsonDecode(vm.result!) as Map<String, Object?>, direct);
      expect(
        (direct['rejection']! as Map<String, Object?>)['code'],
        'uiGesturePointOutOfBounds',
      );
      bridge.dispose();
    },
  );

  test('non-string path keys reject as stable invalid arguments', () async {
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
    );
    addTearDown(bridge.dispose);

    final PatchbayInvocation result = await bridge.gesture.drag(
      identifier: 'gesture.target',
      generation: 1,
      start: const <String, Object?>{'x': 0.2, 'y': 0.2},
      path: <Object?>[
        <Object?, Object?>{'x': 0.4, 'y': 0.4, 7: 'unexpected'},
        const <String, Object?>{'x': 0.8, 'y': 0.8},
      ],
      durationMs: 10,
    );

    expect(result.rejection?.code, 'invalidUiArguments');
  });

  testWidgets(
    'pressHold, drag and fling synthesize bounded pointer sequences',
    (tester) async {
      final List<PointerEvent> events = <PointerEvent>[];
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
        pointerDispatcher: events.add,
        delay: (_) async {},
      );
      await tester.pumpWidget(_target());
      final int generation = await _generation(tester, bridge);

      final PatchbayInvocation hold = await _complete(
        tester,
        bridge.gesture.pressHold(
          identifier: 'gesture.target',
          generation: generation,
          start: const <String, Object?>{'x': 0.5, 'y': 0.5},
          durationMs: 1,
        ),
      );
      expect(events.map((event) => event.runtimeType), <Type>[
        PointerDownEvent,
        PointerUpEvent,
      ]);
      events.clear();

      final PatchbayInvocation drag = await _complete(
        tester,
        bridge.gesture.drag(
          identifier: 'gesture.target',
          generation: generation,
          start: const <String, Object?>{'x': 0.2, 'y': 0.2},
          durationMs: 10,
          path: const <Object?>[
            <String, Object?>{'x': 0.5, 'y': 0.5, 'timeMs': 5},
            <String, Object?>{'x': 0.8, 'y': 0.8, 'timeMs': 10},
          ],
        ),
      );
      expect(events.map((event) => event.runtimeType), <Type>[
        PointerDownEvent,
        PointerMoveEvent,
        PointerMoveEvent,
        PointerUpEvent,
      ]);
      events.clear();

      final PatchbayInvocation fling = await _complete(
        tester,
        bridge.gesture.fling(
          identifier: 'gesture.target',
          generation: generation,
          start: const <String, Object?>{'x': 0.5, 'y': 0.5},
          velocity: const <String, Object?>{'x': 0, 'y': -4},
          durationMs: 20,
        ),
      );
      expect(events.map((event) => event.runtimeType), <Type>[
        PointerDownEvent,
        PointerMoveEvent,
        PointerUpEvent,
      ]);
      for (final PatchbayInvocation result in <PatchbayInvocation>[
        hold,
        drag,
        fling,
      ]) {
        expect(result.admission, PatchbayAdmission.accepted);
        expect(result.payload.keys, <String>{
          'outcome',
          'source',
          'identifier',
          'generation',
          'gesture',
          'layoutChangedDuringGesture',
        });
        expect(
          result.payload.keys.any(
            (key) => key.toLowerCase().contains('global'),
          ),
          isFalse,
        );
      }
      bridge.dispose();
    },
  );

  testWidgets('bounds and consumer-tightened budgets reject before injection', (
    tester,
  ) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(
        maxDurationMs: 10,
        maxPathPoints: 2,
        maxVelocity: 2,
      ),
      pointerDispatcher: events.add,
      delay: (_) async {},
    );
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation outside = await _complete(
      tester,
      bridge.gesture.pressHold(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 1.1, 'y': 0.5},
      ),
    );
    final PatchbayInvocation overBudget = await _complete(
      tester,
      bridge.gesture.fling(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.5, 'y': 0.5},
        velocity: const <String, Object?>{'x': 3, 'y': 0},
      ),
    );

    expect(outside.rejection?.code, 'uiGesturePointOutOfBounds');
    expect(overBudget.rejection?.code, 'uiGestureBudgetExceeded');
    expect(events, isEmpty);
    bridge.dispose();
  });

  testWidgets(
    'missing and ambiguous identifiers fail closed before injection',
    (tester) async {
      final List<PointerEvent> events = <PointerEvent>[];
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
        pointerDispatcher: events.add,
        delay: (_) async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Row(children: <Widget>[_targetBody(), _targetBody()]),
        ),
      );

      final PatchbayInvocation ambiguous = await _complete(
        tester,
        bridge.gesture.pressHold(
          identifier: 'gesture.target',
          generation: 1,
          start: const <String, Object?>{'x': 0.5, 'y': 0.5},
          durationMs: 1,
        ),
      );
      final PatchbayInvocation missing = await _complete(
        tester,
        bridge.gesture.pressHold(
          identifier: 'gesture.absent',
          generation: 1,
          start: const <String, Object?>{'x': 0.5, 'y': 0.5},
          durationMs: 1,
        ),
      );

      expect(ambiguous.rejection?.code, 'uiTargetAmbiguous');
      expect(missing.rejection?.code, 'uiTargetNotFound');
      expect(events, isEmpty);
      bridge.dispose();
    },
  );

  testWidgets('an injection failure cancels the active pointer', (
    tester,
  ) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: events.add,
      delay: (_) => Future<void>.error(StateError('fixture failure')),
    );
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.pressHold(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.5, 'y': 0.5},
        durationMs: 1,
      ),
    );

    expect(result.admission, PatchbayAdmission.accepted);
    expect(result.payload['outcome'], 'failed');
    expect(events.map((event) => event.runtimeType), <Type>[
      PointerDownEvent,
      PointerCancelEvent,
    ]);
    bridge.dispose();
  });

  testWidgets('target is re-resolved after an awaited gate', (tester) async {
    final Completer<PatchbayGateDecision> gate =
        Completer<PatchbayGateDecision>();
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => gate.future,
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(
        gateIds: <String>{'consumer.gesture'},
      ),
      gesturePointerDispatcher: (_) {},
      gestureDelay: (_) async {},
      isAppResumed: () => true,
    );
    await tester.pumpWidget(_target(key: const ValueKey<int>(1)));
    final int generation = await _generation(tester, bridge);
    final Future<PatchbayInvocation> pending = bridge.gesture.pressHold(
      identifier: 'gesture.target',
      generation: generation,
      start: const <String, Object?>{'x': 0.5, 'y': 0.5},
      durationMs: 1,
    );
    await tester.pump();
    await tester.pumpWidget(_target(key: const ValueKey<int>(2)));
    gate.complete(const PatchbayGateDecision.allow());

    final PatchbayInvocation result = await _complete(tester, pending);

    expect(result.rejection?.code, 'uiGenerationStale');
    bridge.dispose();
  });

  testWidgets('layout changes only appear in the terminal payload', (
    tester,
  ) async {
    var moved = false;
    var width = 120.0;
    late StateSetter setLayoutState;
    late PatchbayFlutterBridge bridge;
    bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: (_) {},
      delay: (_) async {
        if (!moved) {
          moved = true;
          setLayoutState(() => width = 180);
        }
      },
    );
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (_, StateSetter setState) {
          setLayoutState = setState;
          return _target(width: width);
        },
      ),
    );
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.pressHold(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.5, 'y': 0.5},
        durationMs: 1,
      ),
    );

    expect(result.admission, PatchbayAdmission.accepted);
    expect(result.payload['layoutChangedDuringGesture'], isTrue);
    bridge.dispose();
  });

  testWidgets('an anchored drag belongs to the inner nested scrollable', (
    tester,
  ) async {
    final ScrollController outer = ScrollController();
    final ScrollController inner = ScrollController();
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      delay: (_) async {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: outer,
          child: Column(
            children: <Widget>[
              const SizedBox(height: 100),
              SizedBox(
                height: 240,
                child: Semantics(
                  identifier: 'gesture.target',
                  container: true,
                  child: ListView.builder(
                    controller: inner,
                    itemExtent: 48,
                    itemCount: 30,
                    itemBuilder: (_, int index) => Text('row $index'),
                  ),
                ),
              ),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.drag(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.5, 'y': 0.8},
        durationMs: 30,
        path: const <Object?>[
          <String, Object?>{'x': 0.5, 'y': 0.5, 'timeMs': 15},
          <String, Object?>{'x': 0.5, 'y': 0.2, 'timeMs': 30},
        ],
      ),
    );
    await tester.pump();

    expect(result.admission, PatchbayAdmission.accepted);
    expect(inner.offset, greaterThan(0));
    expect(outer.offset, 0);
    bridge.dispose();
    outer.dispose();
    inner.dispose();
  });
}

PatchbayFlutterBridge _bridge({
  PatchbayGesturePolicy? policy,
  PatchbayPointerEventDispatcher? pointerDispatcher,
  PatchbayGestureDelay? delay,
}) => PatchbayFlutterBridge(
  gates: PatchbayGateEvaluator(
    baseGate: () => const PatchbayGateDecision.allow(),
    consumerGate: (_) => const PatchbayGateDecision.allow(),
  ),
  gesturePolicy: policy,
  gesturePointerDispatcher: pointerDispatcher,
  gestureDelay: delay,
  isAppResumed: () => true,
);

Widget _target({Key? key, double leftPadding = 0, double width = 120}) =>
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: leftPadding),
          child: Semantics(
            key: key,
            identifier: 'gesture.target',
            container: true,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              child: SizedBox(width: width, height: 80),
            ),
          ),
        ),
      ),
    );

Widget _targetBody() => Semantics(
  identifier: 'gesture.target',
  container: true,
  child: Listener(
    behavior: HitTestBehavior.opaque,
    child: const SizedBox(width: 120, height: 80),
  ),
);

Future<Set<String>> _catalogNames(PatchbayFlutterBridge bridge) async {
  final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
    applicationId: 'dev.patchbay.gesture-test',
    bridge: bridge,
  );
  final Map<String, Object?> catalog = await host.dispatchCatalog();
  return <String>{
    for (final Map<String, Object?> command
        in (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>())
      command['name']! as String,
  };
}

Future<int> _generation(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final PatchbayInvocation snapshot = await _complete(
    tester,
    bridge.semantics.snapshot(),
  );
  return (snapshot.payload['nodes']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .singleWhere(
            (node) => node['identifier'] == 'gesture.target',
          )['generation']!
      as int;
}

Future<T> _complete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 40 && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) throw StateError('gesture operation did not complete');
  return pending;
}
