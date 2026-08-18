import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  for (final ({String name, Widget Function() build}) fixture
      in <({String name, Widget Function() build})>[
        (
          name: 'custom paint semantics',
          build: () => Semantics(
            identifier: 'gesture.target',
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
            identifier: 'gesture.target',
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
                  identifier: 'gesture.target',
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
    testWidgets('${fixture.name} is not falsely rejected', (tester) async {
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Center(child: fixture.build())),
      );
      final int generation = await _generation(tester, bridge);

      final PatchbayInvocation result = await _press(
        tester,
        bridge,
        generation,
      );
      bridge.dispose();

      expect(
        result.admission,
        PatchbayAdmission.accepted,
        reason: result.toJson().toString(),
      );
      expect(result.payload['outcome'], 'dispatched');
    });
  }

  testWidgets('a real hit-testing overlay fails closed', (tester) async {
    final PatchbayFlutterBridge bridge = _bridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 120,
            height: 80,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Semantics(
                  identifier: 'gesture.target',
                  container: true,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                ),
                const ColoredBox(color: Colors.black),
              ],
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation result = await _press(tester, bridge, generation);
    bridge.dispose();

    expect(result.rejection?.code, 'uiGestureTargetObscured');
  });

  testWidgets('a point outside an ancestor paint clip fails closed', (
    tester,
  ) async {
    final PatchbayFlutterBridge bridge = _bridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 50,
            child: ClipRect(
              clipper: const _LeftHalfClipper(),
              child: Semantics(
                identifier: 'gesture.target',
                container: true,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  child: const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge);

    final Future<PatchbayInvocation> pending = bridge.gesture.pressHold(
      identifier: 'gesture.target',
      generation: generation,
      start: const <String, Object?>{'x': 0.9, 'y': 0.5},
      durationMs: 1,
    );
    final PatchbayInvocation result = await _pumpUntilComplete(tester, pending);
    bridge.dispose();

    expect(result.rejection?.code, 'uiGestureTargetObscured');
  });

  testWidgets(
    'a drag path point under an overlay rejects before pointer down',
    (tester) async {
      final List<PointerEvent> events = <PointerEvent>[];
      final PatchbayFlutterBridge bridge = _bridge(
        pointerDispatcher: events.add,
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 120,
              height: 80,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Semantics(
                    identifier: 'gesture.target',
                    container: true,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                  const Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: 60,
                    child: ColoredBox(color: Colors.black),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final int generation = await _generation(tester, bridge);

      final PatchbayInvocation result = await _pumpUntilComplete(
        tester,
        bridge.gesture.drag(
          identifier: 'gesture.target',
          generation: generation,
          start: const <String, Object?>{'x': 0.2, 'y': 0.5},
          path: const <Object?>[
            <String, Object?>{'x': 0.4, 'y': 0.5, 'timeMs': 5},
            <String, Object?>{'x': 0.8, 'y': 0.5, 'timeMs': 10},
          ],
          durationMs: 10,
        ),
      );
      bridge.dispose();

      expect(result.rejection?.code, 'uiGestureTargetObscured');
      expect(events, isEmpty);
    },
  );

  testWidgets('a fling endpoint outside a clip rejects before pointer down', (
    tester,
  ) async {
    final List<PointerEvent> events = <PointerEvent>[];
    final PatchbayFlutterBridge bridge = _bridge(pointerDispatcher: events.add);
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 50,
            child: ClipRect(
              clipper: const _LeftHalfClipper(),
              child: Semantics(
                identifier: 'gesture.target',
                container: true,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  child: const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final int generation = await _generation(tester, bridge);

    final PatchbayInvocation result = await _pumpUntilComplete(
      tester,
      bridge.gesture.fling(
        identifier: 'gesture.target',
        generation: generation,
        start: const <String, Object?>{'x': 0.2, 'y': 0.5},
        velocity: const <String, Object?>{'x': 10, 'y': 0},
        durationMs: 100,
      ),
    );
    bridge.dispose();

    expect(result.rejection?.code, 'uiGestureTargetObscured');
    expect(events, isEmpty);
  });
}

PatchbayFlutterBridge _bridge({
  PatchbayPointerEventDispatcher? pointerDispatcher,
}) => PatchbayFlutterBridge(
  gates: PatchbayGateEvaluator(
    baseGate: () => const PatchbayGateDecision.allow(),
    consumerGate: (_) => const PatchbayGateDecision.allow(),
  ),
  gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
  gesturePointerDispatcher: pointerDispatcher,
  gestureDelay: (_) async {},
  isAppResumed: () => true,
);

Future<int> _generation(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final PatchbayInvocation snapshot = await _pumpUntilComplete(
    tester,
    bridge.semantics.snapshot(),
  );
  final Map<String, Object?> node =
      (snapshot.payload['nodes']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .singleWhere(
            (Map<String, Object?> node) =>
                node['identifier'] == 'gesture.target',
          );
  return node['generation']! as int;
}

Future<PatchbayInvocation> _press(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
  int generation,
) => _pumpUntilComplete(
  tester,
  bridge.gesture.pressHold(
    identifier: 'gesture.target',
    generation: generation,
    start: const <String, Object?>{'x': 0.5, 'y': 0.5},
    durationMs: 1,
  ),
);

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 30 && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) throw StateError('gesture operation did not complete');
  return pending;
}

final class _ProbePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

final class _LeftHalfClipper extends CustomClipper<Rect> {
  const _LeftHalfClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}
