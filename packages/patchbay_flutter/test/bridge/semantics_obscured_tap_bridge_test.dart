// PB-050-16 repro: obscured-target tap admission gap.
//
// This test asserts CURRENT DEFECT BEHAVIOR. `ui.semantics.tap` dispatches
// straight through to a Semantics target that is fully covered by an
// opaque, *non-modal* overlay (no BlockSemantics / ModalBarrier involved),
// because the admission check in semantics_bridge.dart (~423-428) only
// rejects on `isInvisible || areUserActionsBlocked`, and
// `areUserActionsBlocked` is only ever set true by BlockSemantics. A real
// pointer at the same on-screen position only reaches the overlay.
//
// Once occlusion-aware admission lands (see DG-050-09), the (a) assertions
// below should flip: `tapIdentifier` must reject with a stable rejection
// code instead of dispatching, and `buttonTaps` must stay 0.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  group('Patchbay semantics tap obscured target (PB-050-16)', () {
    testWidgets('an opaque non-modal overlay does not block ui.semantics.tap, '
        'though it blocks a real pointer at the same position', (tester) async {
      var buttonTaps = 0;
      var overlayTaps = 0;
      const Key overlayKey = ValueKey<String>('obscured.overlay');

      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                child: Semantics(
                  identifier: 'obscured.button',
                  label: 'Hidden button',
                  button: true,
                  onTap: () => buttonTaps += 1,
                  child: const SizedBox(width: 100, height: 100),
                ),
              ),
              // Opaque, non-modal overlay: absorbs real hit-testing but
              // does not use BlockSemantics/ModalBarrier, so it leaves
              // `areUserActionsBlocked` false on the node underneath.
              Positioned(
                left: 0,
                top: 0,
                child: GestureDetector(
                  key: overlayKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: () => overlayTaps += 1,
                  child: Container(
                    width: 100,
                    height: 100,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      // (a) ui.semantics.tap path: dispatches straight to the occluded
      // target's callback. This is the defect this repro pins down - see
      // the file header for the rejected-post-fix expectation.
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'obscured.button'),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(result.payload['outcome'], 'dispatched');
      expect(
        buttonTaps,
        1,
        reason:
            'PB-050-16: ui.semantics.tap punched through the opaque '
            'overlay onto the fully covered target',
      );
      expect(overlayTaps, 0);

      // (b) Real pointer at the same on-screen position: only the
      // overlay is reachable, proving the target is genuinely, visually
      // occluded and not just semantically hidden.
      await tester.tap(find.byKey(overlayKey));
      await tester.pump();

      expect(overlayTaps, 1);
      expect(
        buttonTaps,
        1,
        reason:
            'a real touch at the same position must not reach the '
            'occluded button',
      );

      bridge.semantics.dispose();
    });
  });
}
