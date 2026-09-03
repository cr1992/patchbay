// PB-050-16 repro, flipped: obscured-target tap admission.
//
// Before DG-050-09 landed this test asserted the DEFECT: `ui.semantics.tap`
// dispatched straight through to a Semantics target that is fully covered by
// an opaque, *non-modal* overlay (no BlockSemantics / ModalBarrier involved),
// because admission only rejected on `isInvisible || areUserActionsBlocked`
// and `areUserActionsBlocked` is only ever set true by BlockSemantics. A real
// pointer at the same on-screen position only reaches the overlay.
//
// The (a) assertions below are now the post-fix expectation: `tapIdentifier`
// rejects with `uiSemanticsTargetObscured` and `buttonTaps` stays 0. The (b)
// assertions are unchanged - they are the independent evidence that the
// target really is visually occluded and not merely semantically hidden.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  group('Patchbay semantics tap obscured target (PB-050-16)', () {
    testWidgets('an opaque non-modal overlay blocks ui.semantics.tap, '
        'exactly as it blocks a real pointer at the same position', (
      tester,
    ) async {
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

      // (a) ui.semantics.tap path: the fixed-sample occlusion admission
      // finds every probe point absorbed by the overlay and fails closed
      // before `performAction`.
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'obscured.button'),
      );

      expect(result.admission, PatchbayAdmission.rejected);
      expect(result.rejection?.code, 'uiSemanticsTargetObscured');
      expect(result.rejection?.details['reason'], 'hitTestOrClip');
      expect(result.rejection?.details['identifier'], 'obscured.button');
      expect(
        buttonTaps,
        0,
        reason:
            'PB-050-16: ui.semantics.tap must not punch through the opaque '
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
        0,
        reason:
            'a real touch at the same position must not reach the '
            'occluded button',
      );

      bridge.semantics.dispose();
    });
  });
}
