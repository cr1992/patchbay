/// PB-050-16 在 example 上的遮挡回归。
///
/// 驱动的是 example 真正发货的那个 host、那份 semantics 策略和那道写门
/// （`exampleWriteGate` 的判例一个字都没动），只在真实 App 之上盖一层非模态
/// 浮层——`tool/example_precheck.sh` 在设备上要复现的正是这一幕：被浮层盖住的
/// `ui.semantics.tap` 必须拒绝，浮层撤走后同一 identifier 必须成功。
///
/// 本地端到端预检与接入方真机验收都不能由本文件代替：它证明的是接线与判定在
/// 仓内 example 上成立，真实控制器语义、签名真机的系统浮层仍然只有设备能出
/// 证据（AGENTS.md「验证分两段」）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';
import 'package:patchbay_flutter_example/main.dart';

void main() {
  testWidgets('a non-modal overlay refuses the increment tap, and removing '
      'it admits the same identifier again', (WidgetTester tester) async {
    final ExampleCounterModel model = ExampleCounterModel();
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey noteKey = PatchbayKey.text(
      noteTargetId,
      registry: registry,
    );
    final PatchbayKey cardCaptureKey = PatchbayKey.capture(
      cardCaptureTargetId,
      registry: registry,
    );
    final ExampleRouter router = ExampleRouter();
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      router: router,
      isAppResumed: () => true,
    );
    try {
      Widget harness({required bool overlay}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PatchbayExampleApp(
              model: model,
              noteKey: noteKey,
              cardCaptureKey: cardCaptureKey,
              router: router,
            ),
            // 非模态：没有 BlockSemantics / ModalBarrier，所以按钮节点的
            // `areUserActionsBlocked` 仍然是 false，只有遮挡准入拦得住它。
            // 用 `Listener` 而不是 `GestureDetector`，浮层本身不产生语义节点，
            // 撤走前后按钮的代际不变。
            if (overlay)
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Color(0xFF101010)),
              ),
          ],
        ),
      );

      await tester.pumpWidget(harness(overlay: true));
      final PatchbayInvocation refused = await _pumpUntilComplete(
        tester,
        host.bridge.semantics.tapIdentifier(identifier: incrementSemanticsId),
      );

      expect(refused.admission, PatchbayAdmission.rejected);
      expect(refused.rejection?.code, 'uiSemanticsTargetObscured');
      expect(refused.rejection?.details['reason'], 'hitTestOrClip');
      expect(refused.rejection?.details['identifier'], incrementSemanticsId);
      expect(model.value, 0);
      expect(find.text('Count: 0'), findsOneWidget);

      await tester.pumpWidget(harness(overlay: false));
      final PatchbayInvocation admitted = await _pumpUntilComplete(
        tester,
        host.bridge.semantics.tapIdentifier(identifier: incrementSemanticsId),
      );

      expect(admitted.admission, PatchbayAdmission.accepted);
      expect(admitted.payload['outcome'], 'dispatched');
      expect(model.value, 1);
      await tester.pump();
      expect(find.text('Count: 1'), findsOneWidget);
    } finally {
      host.dispose();
      model.dispose();
    }
  });
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
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (!completed) {
    throw StateError(
      'Patchbay example operation did not complete in 20 frames',
    );
  }
  return pending;
}
