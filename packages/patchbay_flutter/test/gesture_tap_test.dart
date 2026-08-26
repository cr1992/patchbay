// PB-050-15 / DG-050-08：指针通道上的点按。
//
// 这份矩阵冻结三件事：
// 1. tap 与家族共用同一条准入管线（点数为 1 的退化情形），遮挡即拒绝、
//    门后复核即比对，没有任何旁路；
// 2. 调用方 generation 在**第一次** resolve 就核对（比既有三条更严），
//    关住"上次观察之后、命令开始之前 identifier 被新节点复用"那个窗口；
// 3. down→up 间隔是内部常数：它压住框架默认长按，但**不担保**手势归属
//    ——接入方更短阈值的 recognizer 赢下竞技场时命令仍如实返回 dispatched。
import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  test('gesture policy presence puts ui.gesture.tap in the catalog', () async {
    final PatchbayFlutterBridge disabled = _bridge();
    final PatchbayFlutterBridge enabled = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
    );
    addTearDown(disabled.dispose);
    addTearDown(enabled.dispose);

    expect(await _catalogNames(disabled), isNot(contains('ui.gesture.tap')));
    expect(await _catalogNames(enabled), contains('ui.gesture.tap'));
  });

  test(
    'VM extension and direct seam share the tap dispatcher byte for byte', //
    () async {
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
      );
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.tap-parity',
        bridge: bridge,
        registrar: (method, handler) => handlers[method] = handler,
      )..register();

      for (final Map<String, Object?> arguments in <Map<String, Object?>>[
        // 越界点：bridge 层拒绝。
        <String, Object?>{
          'identifier': 'target',
          'generation': 1,
          'start': <String, Object?>{'x': 2, 'y': 0.5},
        },
        // durationMs 对 tap 是未知 key：decoder 层拒绝。
        <String, Object?>{
          'identifier': 'target',
          'generation': 1,
          'durationMs': 50,
        },
      ]) {
        final Map<String, Object?> direct = await host.dispatchInvoke(
          'ui.gesture.tap',
          arguments,
          'tap-parity',
        );
        final ServiceExtensionResponse vm =
            await handlers[PatchbayServiceHost.invokeMethod]!(
              PatchbayServiceHost.invokeMethod,
              <String, String>{
                'command': 'ui.gesture.tap',
                'requestId': 'tap-parity',
                'args': jsonEncode(arguments),
              },
            );
        expect(jsonDecode(vm.result!) as Map<String, Object?>, direct);
      }
    },
  );

  test(
    'durationMs and other unknown keys reject before bridge and policy', //
    () async {
      var policyCalls = 0;
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) {
          policyCalls += 1;
          return const PatchbayGestureDecision.allow();
        },
      );
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.tap-strict',
        bridge: bridge,
      );

      for (final Map<String, Object?> arguments in <Map<String, Object?>>[
        <String, Object?>{'identifier': 't', 'generation': 1, 'durationMs': 50},
        <String, Object?>{'identifier': 't', 'generation': 1, 'unknown': true},
        <String, Object?>{
          'identifier': 't',
          'generation': 1,
          'start': <String, Object?>{'x': 0.5, 'y': 0.5, 'z': 0},
        },
        <String, Object?>{
          'identifier': 't',
          'generation': 1,
          'start': <String, Object?>{'x': 'centre', 'y': 0.5},
        },
        <String, Object?>{'identifier': 't', 'generation': -1},
        // 缺 generation：wire 侧省略该 key 即拒绝，不落任何默认值。
        <String, Object?>{'identifier': 't'},
      ]) {
        final Map<String, Object?> outcome = await host.dispatchInvoke(
          'ui.gesture.tap',
          arguments,
          'tap-strict',
        );
        expect(
          (outcome['rejection']! as Map<String, Object?>)['code'],
          'invalidUiArguments',
          reason: jsonEncode(arguments),
        );
      }
      expect(policyCalls, 0);
    },
  );

  testWidgets('a reachable button is really tapped: default start hits the '
      'centre, an explicit start hits the chosen half', (tester) async {
    var leftTaps = 0;
    var rightTaps = 0;
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Semantics(
            identifier: 'tap.target',
            container: true,
            child: SizedBox(
              width: 200,
              height: 80,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => leftTaps += 1,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => rightTaps += 1,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge, 'tap.target');

    // 缺省 start：目标中心落在右半边的最左缘之外——中心 x=0.5 恰好是
    // 两半的分界，Row 布局下 100.0 属于右半的命中区。为了让"默认=中心"
    // 的断言不依赖分界像素的归属，这里对默认值断言总次数，再用显式偏移
    // 分别命中两半。
    final PatchbayInvocation centre = await _completeTimed(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation),
    );
    expect(centre.admission, PatchbayAdmission.accepted);
    expect(centre.payload['outcome'], 'dispatched');
    expect(centre.payload['gesture'], 'tap');
    expect(leftTaps + rightTaps, 1);

    final int afterCentreLeft = leftTaps;
    final PatchbayInvocation left = await _completeTimed(
      tester,
      bridge.gesture.tap(
        identifier: 'tap.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.25, 'y': 0.5},
      ),
    );
    expect(left.payload['outcome'], 'dispatched');
    expect(leftTaps, afterCentreLeft + 1);

    final int afterLeftRight = rightTaps;
    final PatchbayInvocation right = await _completeTimed(
      tester,
      bridge.gesture.tap(
        identifier: 'tap.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.75, 'y': 0.5},
      ),
    );
    expect(right.payload['outcome'], 'dispatched');
    expect(rightTaps, afterLeftRight + 1);

    for (final PatchbayInvocation result in <PatchbayInvocation>[
      centre,
      left,
      right,
    ]) {
      expect(result.payload.keys, <String>{
        'outcome',
        'source',
        'identifier',
        'generation',
        'gesture',
        'layoutChangedDuringGesture',
      });
      expect(
        result.payload.keys.any((key) => key.toLowerCase().contains('global')),
        isFalse,
      );
    }
    bridge.dispose();
  });

  testWidgets(
    'the internal delay stays under the framework long-press timeout',
    (tester) async {
      var taps = 0;
      var longPresses = 0;
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Semantics(
              identifier: 'tap.target',
              container: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps += 1,
                onLongPress: () => longPresses += 1,
                child: const SizedBox(width: 120, height: 80),
              ),
            ),
          ),
        ),
      );
      final int generation = await _generation(tester, bridge, 'tap.target');

      final PatchbayInvocation result = await _completeTimed(
        tester,
        bridge.gesture.tap(identifier: 'tap.target', generation: generation),
      );
      // 断言的是内部常数对框架默认 `kLongPressTimeout` 的关系；up 已在长按
      // 计时器之前出门，之后再流逝多少时间都不该追认长按。
      await tester.pump(const Duration(seconds: 1));

      expect(result.payload['outcome'], 'dispatched');
      expect(taps, 1);
      expect(longPresses, 0);
      bridge.dispose();
    },
  );

  testWidgets('a consumer recognizer with a shorter threshold may win the '
      'arena; the command still reports the injection honestly', (
    tester,
  ) async {
    var taps = 0;
    var longPresses = 0;
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Semantics(
            identifier: 'tap.target',
            container: true,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      TapGestureRecognizer.new,
                      (TapGestureRecognizer recognizer) =>
                          recognizer.onTap = () => taps += 1,
                    ),
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      LongPressGestureRecognizer
                    >(
                      () => LongPressGestureRecognizer(
                        duration: const Duration(milliseconds: 10),
                      ),
                      (LongPressGestureRecognizer recognizer) =>
                          recognizer.onLongPress = () => longPresses += 1,
                    ),
              },
              child: const SizedBox(width: 120, height: 80),
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge, 'tap.target');

    final PatchbayInvocation result = await _completeTimed(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation),
    );

    // 注入序列与用户手指按下 50 ms 完全同构：10 ms 阈值的长按识别器该怎么
    // 认还怎么认。命令不补偿、不改判、不拒绝——这条测试冻结的正是"不担保
    // 手势归属"这个口径，防止后续实现悄悄加一层"确保是 tap"的兜底。
    expect(longPresses, 1);
    expect(taps, 0);
    expect(result.payload['outcome'], 'dispatched');
    bridge.dispose();
  });

  testWidgets('an opaque non-modal overlay rejects the pointer tap and the '
      'semantics tap with two distinct codes', (tester) async {
    var buttonTaps = 0;
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
      gesturePointerDispatcher: events.add,
      gestureDelay: (_) async {},
      semanticsActionPolicy: (_, _) =>
          const PatchbaySemanticsActionDecision.allow(),
      isAppResumed: () => true,
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              child: Semantics(
                identifier: 'tap.obscured',
                button: true,
                onTap: () => buttonTaps += 1,
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(width: 100, height: 100, color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );
    final int generation = await _generation(tester, bridge, 'tap.obscured');

    final PatchbayInvocation pointer = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.obscured', generation: generation),
    );
    final PatchbayInvocation semantics = await _complete(
      tester,
      bridge.semantics.tapIdentifier(identifier: 'tap.obscured'),
    );

    // 一个说"指针打不到"，一个说"无障碍动作被非模态层覆盖"：两个码不合并，
    // 调用方才分得清该换通道还是该先 reveal。
    expect(pointer.rejection?.code, 'uiGestureTargetObscured');
    expect(pointer.rejection?.details['reason'], 'hitTestOrClip');
    expect(semantics.rejection?.code, 'uiSemanticsTargetObscured');
    expect(buttonTaps, 0);
    expect(events, isEmpty);
    bridge.dispose();
  });

  for (final ({String name, Widget Function() build}) fixture
      in <({String name, Widget Function() build})>[
        (
          name: 'custom paint semantics',
          build: () => Semantics(
            identifier: 'tap.target',
            container: true,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              child: CustomPaint(
                size: const Size(120, 80),
                painter: _ProbePainter(),
              ),
            ),
          ),
        ),
        (
          name: 'translucent hit behavior',
          build: () => Semantics(
            identifier: 'tap.target',
            container: true,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (_) {},
              child: const SizedBox(width: 120, height: 80),
            ),
          ),
        ),
        (
          name: 'decorative IgnorePointer overlay',
          build: () => SizedBox(
            width: 120,
            height: 80,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Semantics(
                  identifier: 'tap.target',
                  container: true,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                ),
                const IgnorePointer(
                  child: ColoredBox(color: Color(0x2200FF00)),
                ),
              ],
            ),
          ),
        ),
      ]) {
    testWidgets('${fixture.name} is not falsely rejected by tap', (
      tester,
    ) async {
      final PatchbayFlutterBridge bridge = _bridge(
        policy: (_, _) => const PatchbayGestureDecision.allow(),
        delay: (_) async {},
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Center(child: fixture.build())),
      );
      final int generation = await _generation(tester, bridge, 'tap.target');

      final PatchbayInvocation result = await _complete(
        tester,
        bridge.gesture.tap(identifier: 'tap.target', generation: generation),
      );

      expect(
        result.admission,
        PatchbayAdmission.accepted,
        reason: result.toJson().toString(),
      );
      expect(result.payload['outcome'], 'dispatched');
      bridge.dispose();
    });
  }

  testWidgets('a stale caller generation rejects at the first resolve, '
      'before the base gate runs', (tester) async {
    var gateCalls = 0;
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () {
          gateCalls += 1;
          return const PatchbayGateDecision.allow();
        },
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
      gesturePointerDispatcher: events.add,
      gestureDelay: (_) async {},
      isAppResumed: () => true,
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge, 'tap.target');
    // snapshot 取 generation 时也过了一次基础门：从这里起才是 tap 的计数。
    gateCalls = 0;

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation + 1),
    );

    // 这正是 generation 必填要关住的窗口：调用方观察之后 identifier 被复用，
    // 命令在第一次 resolve 就拒绝，连基础门都不进。
    expect(result.rejection?.code, 'uiGenerationStale');
    expect(gateCalls, 0);
    expect(events, isEmpty);
    bridge.dispose();
  });

  testWidgets('an identifier remounted onto a new node after the caller\'s '
      'observation rejects at the first resolve', (tester) async {
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      delay: (_) async {},
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target(key: const ValueKey<int>(1)));
    final int observed = await _generation(tester, bridge, 'tap.target');
    await tester.pumpWidget(_target(key: const ValueKey<int>(2)));
    await tester.pump();

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: observed),
    );

    expect(result.rejection?.code, 'uiGenerationStale');
    bridge.dispose();
  });

  testWidgets('a remount during the awaited gate rejects after the gate', (
    tester,
  ) async {
    final Completer<PatchbayGateDecision> gate =
        Completer<PatchbayGateDecision>();
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => gate.future,
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(
        gateIds: <String>{'consumer.tap'},
      ),
      gesturePointerDispatcher: (_) {},
      gestureDelay: (_) async {},
      isAppResumed: () => true,
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target(key: const ValueKey<int>(1)));
    final int generation = await _generation(tester, bridge, 'tap.target');
    final Future<PatchbayInvocation> pending = bridge.gesture.tap(
      identifier: 'tap.target',
      generation: generation,
    );
    await tester.pump();
    await tester.pumpWidget(_target(key: const ValueKey<int>(2)));
    gate.complete(const PatchbayGateDecision.allow());

    final PatchbayInvocation result = await _complete(tester, pending);

    expect(result.rejection?.code, 'uiGenerationStale');
    bridge.dispose();
  });

  testWidgets('a policy drift across the awaited gate rejects with no '
      'pointer event dispatched', (tester) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final Completer<PatchbayGateDecision> gate =
        Completer<PatchbayGateDecision>();
    var gateIds = const <String>{'consumer.tap'};
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => gate.future,
      ),
      gesturePolicy: (_, _) => PatchbayGestureDecision.allow(gateIds: gateIds),
      gesturePointerDispatcher: events.add,
      gestureDelay: (_) async {},
      isAppResumed: () => true,
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge, 'tap.target');
    final Future<PatchbayInvocation> pending = bridge.gesture.tap(
      identifier: 'tap.target',
      generation: generation,
    );
    await tester.pump();
    gateIds = const <String>{'consumer.tap', 'consumer.extra'};
    gate.complete(const PatchbayGateDecision.allow());

    final PatchbayInvocation result = await _complete(tester, pending);

    expect(result.rejection?.code, 'uiGesturePolicyChanged');
    expect(events, isEmpty);
    bridge.dispose();
  });

  testWidgets('a policy budget tightened below the internal delay rejects '
      'with no pointer event dispatched', (tester) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(maxDurationMs: 49),
      pointerDispatcher: events.add,
      delay: (_) async {},
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge, 'tap.target');

    final PatchbayInvocation rejected = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation),
    );

    // 内部常数同样受接入方预算约束：不因它不进 wire 就绕过 policy。
    expect(rejected.rejection?.code, 'uiGestureBudgetExceeded');
    expect(events, isEmpty);

    final PatchbayFlutterBridge boundary = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(maxDurationMs: 50),
      pointerDispatcher: events.add,
      delay: (_) async {},
    );
    addTearDown(boundary.dispose);
    final int generationAgain = await _generation(
      tester,
      boundary,
      'tap.target',
    );
    final PatchbayInvocation allowed = await _complete(
      tester,
      boundary.gesture.tap(
        identifier: 'tap.target',
        generation: generationAgain,
      ),
    );
    expect(allowed.payload['outcome'], 'dispatched');
    bridge.dispose();
    boundary.dispose();
  });

  testWidgets('two mounted nodes with the identifier reject as ambiguous', (
    tester,
  ) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: events.add,
      delay: (_) async {},
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Row(children: <Widget>[_targetBody(), _targetBody()])),
    );

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: 0),
    );

    expect(result.rejection?.code, 'uiTargetAmbiguous');
    expect(events, isEmpty);
    bridge.dispose();
  });

  testWidgets('an injection failure cancels the active pointer and reports '
      'an accepted failed terminal without the message', (tester) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: events.add,
      delay: (_) => Future<void>.error(StateError('secret fixture detail')),
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge, 'tap.target');

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation),
    );

    expect(result.admission, PatchbayAdmission.accepted);
    expect(result.payload['outcome'], 'failed');
    expect(result.payload['failureType'], 'StateError');
    expect(jsonEncode(result.toJson()), isNot(contains('secret')));
    expect(events.map((event) => event.runtimeType), <Type>[
      PointerDownEvent,
      PointerCancelEvent,
    ]);
    bridge.dispose();
  });

  testWidgets('a failing cancel compensation keeps the original error as '
      'the terminal fact', (tester) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: (PointerEvent event) {
        events.add(event);
        if (event is PointerCancelEvent) {
          throw ArgumentError('cancel channel is gone');
        }
      },
      delay: (_) => Future<void>.error(StateError('original failure')),
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target());
    final int generation = await _generation(tester, bridge, 'tap.target');

    final PatchbayInvocation result = await _complete(
      tester,
      bridge.gesture.tap(identifier: 'tap.target', generation: generation),
    );

    expect(result.payload['outcome'], 'failed');
    expect(result.payload['failureType'], 'StateError');
    expect(events.map((event) => event.runtimeType), <Type>[
      PointerDownEvent,
      PointerCancelEvent,
    ]);
    bridge.dispose();
  });

  testWidgets('a target unmounted between down and up still completes the '
      'sequence and reports the layout change', (tester) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final Completer<void> midSequence = Completer<void>();
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
      pointerDispatcher: events.add,
      delay: (_) => midSequence.future,
    );
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_target(key: const ValueKey<int>(1)));
    final int generation = await _generation(tester, bridge, 'tap.target');

    final Future<PatchbayInvocation> pending = bridge.gesture.tap(
      identifier: 'tap.target',
      generation: generation,
    );
    // 先把管线泵到 down 真正出门（准入还有 resolve/门等多个 await），
    // 注入停在 down→up 之间：此刻卸载目标。序列不中途取消，up 仍然发出。
    for (var attempt = 0; attempt < 40 && events.isEmpty; attempt += 1) {
      await tester.pump();
    }
    expect(events.single.runtimeType, PointerDownEvent);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    midSequence.complete();
    final PatchbayInvocation result = await _complete(tester, pending);

    expect(result.payload['outcome'], 'dispatched');
    expect(result.payload['layoutChangedDuringGesture'], isTrue);
    expect(events.map((event) => event.runtimeType), <Type>[
      PointerDownEvent,
      PointerUpEvent,
    ]);
    bridge.dispose();
  });

  testWidgets('leaving resumed at each of the three checkpoints rejects '
      'with the lifecycle code', (tester) async {
    // 检查点一：进入管线时就不在 resumed。
    var resumed = false;
    final PatchbayFlutterBridge initial = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
      gesturePointerDispatcher: (_) {},
      gestureDelay: (_) async {},
      isAppResumed: () => resumed,
    );
    addTearDown(initial.dispose);
    await tester.pumpWidget(_target());
    resumed = true;
    final int generation = await _generation(tester, initial, 'tap.target');
    resumed = false;
    final PatchbayInvocation atEntry = await _complete(
      tester,
      initial.gesture.tap(identifier: 'tap.target', generation: generation),
    );
    expect(atEntry.rejection?.code, 'uiLifecycleNotResumed');

    // 检查点二：基础门归来时离开 resumed。armed 开关避免取 generation 的
    // snapshot（它同样过基础门）提前触发翻转。
    var resumedAfterBase = true;
    var armBaseFlip = false;
    final PatchbayFlutterBridge afterBase = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () {
          if (armBaseFlip) resumedAfterBase = false;
          return const PatchbayGateDecision.allow();
        },
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
      gesturePointerDispatcher: (_) {},
      gestureDelay: (_) async {},
      isAppResumed: () => resumedAfterBase,
    );
    addTearDown(afterBase.dispose);
    final int generationTwo = await _generation(
      tester,
      afterBase,
      'tap.target',
    );
    armBaseFlip = true;
    final PatchbayInvocation atBase = await _complete(
      tester,
      afterBase.gesture.tap(
        identifier: 'tap.target',
        generation: generationTwo,
      ),
    );
    expect(atBase.rejection?.code, 'uiLifecycleNotResumed');

    // 检查点三：声明门归来时离开 resumed。
    var resumedAfterGate = true;
    var armGateFlip = false;
    final PatchbayFlutterBridge afterGate = PatchbayFlutterBridge(
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) {
          if (armGateFlip) resumedAfterGate = false;
          return const PatchbayGateDecision.allow();
        },
      ),
      gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(
        gateIds: <String>{'consumer.tap'},
      ),
      gesturePointerDispatcher: (_) {},
      gestureDelay: (_) async {},
      isAppResumed: () => resumedAfterGate,
    );
    addTearDown(afterGate.dispose);
    final int generationThree = await _generation(
      tester,
      afterGate,
      'tap.target',
    );
    armGateFlip = true;
    final PatchbayInvocation atGate = await _complete(
      tester,
      afterGate.gesture.tap(
        identifier: 'tap.target',
        generation: generationThree,
      ),
    );
    expect(atGate.rejection?.code, 'uiLifecycleNotResumed');
    initial.dispose();
    afterBase.dispose();
    afterGate.dispose();
  });

  testWidgets('omitting start over the host wire lands the descriptor '
      'centre default', (tester) async {
    var taps = 0;
    final PatchbayFlutterBridge bridge = _bridge(
      policy: (_, _) => const PatchbayGestureDecision.allow(),
    );
    addTearDown(bridge.dispose);
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.tap-default',
      bridge: bridge,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Semantics(
            identifier: 'tap.target',
            container: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps += 1,
              child: const SizedBox(width: 120, height: 80),
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge, 'tap.target');

    final Future<Map<String, Object?>> pending = host.dispatchInvoke(
      'ui.gesture.tap',
      <String, Object?>{'identifier': 'tap.target', 'generation': generation},
      'tap-default',
    );
    final Map<String, Object?> outcome = await _completeTimed(tester, pending);

    expect(
      (outcome['payload']! as Map<String, Object?>)['outcome'],
      'dispatched',
    );
    expect(taps, 1);
    bridge.dispose();
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

Widget _target({Key? key}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: Semantics(
      key: key,
      identifier: 'tap.target',
      container: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(width: 120, height: 80),
      ),
    ),
  ),
);

Widget _targetBody() => Semantics(
  identifier: 'tap.target',
  container: true,
  child: Listener(
    behavior: HitTestBehavior.opaque,
    child: const SizedBox(width: 120, height: 80),
  ),
);

Future<Set<String>> _catalogNames(PatchbayFlutterBridge bridge) async {
  final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
    applicationId: 'dev.patchbay.tap-test',
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
  String identifier,
) async {
  final PatchbayInvocation snapshot = await _complete(
    tester,
    bridge.semantics.snapshot(),
  );
  return (snapshot.payload['nodes']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((node) => node['identifier'] == identifier)['generation']!
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
  if (!completed) throw StateError('tap operation did not complete');
  return pending;
}

/// 真实 `Future.delayed` 的 50 ms 间隔在测试时钟里只随带时长的 pump 前进，
/// 因此用 10 ms 步进推动，长按计时器（500 ms 或自定义阈值）按真实先后触发。
Future<T> _completeTimed<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 80 && !completed; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!completed) throw StateError('timed tap operation did not complete');
  return pending;
}

final class _ProbePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF2266AA),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
