/// PB-050-17 在 example 上的 scroll-to-reveal 回归。
///
/// 驱动的是 example 真正发货的那个 host、那份 reveal policy 和那道写门
/// （`exampleWriteGate` 的判例一个字都没动）。它证明的是三条只有在真实屏幕上
/// 才成立的事：目标一开始根本不在 Semantics 树上、分页内容是滚过去之后才补进
/// 来的、以及固定栏盖住的行不算露出。
///
/// 本地端到端预检与接入方真机验收都不能由本文件代替：真实分页节奏、真实固定层
/// 与真实控制器语义仍然只有设备能出证据（AGENTS.md「验证分两段」）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';
import 'package:patchbay_flutter_example/example_domain.dart';
import 'package:patchbay_flutter_example/main.dart';

void main() {
  testWidgets('a row several pages down is not mounted, and reveal drives the '
      'list until it is exposed', (WidgetTester tester) async {
    await _withRevealScreen(tester, (
      PatchbayExampleHost host,
      WidgetTester tester,
    ) async {
      // 目标一开始不在树上：只读的 wait 只会等到超时，reveal 才是让它出现的
      // 那条路径。
      final PatchbaySemanticsIdentifierObservation? before = await _pump(
        tester,
        host.bridge.semantics.observeIdentifier(revealTargetSemanticsId),
      );
      expect(before?.matches, isEmpty);

      final PatchbayInvocation result = await _pump(
        tester,
        host.bridge.reveal.reveal(
          identifier: revealTargetSemanticsId,
          container: revealListSemanticsId,
          direction: PatchbayRevealDirection.forward,
          maxSteps: 60,
          timeoutMs: 20000,
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      final Map<String, Object?> payload = result.payload;
      expect(payload['outcome'], 'revealed', reason: '$payload');
      // 目标有指针占位，所以 reachability 如实报告 pointer；是否允许
      // canonical `--via pointer` 仍由独立的 gesture policy 决定。
      expect(payload['reachability'], 'pointer');
      expect(payload['steps'], greaterThan(0));

      final List<Map<String, Object?>> containers =
          (payload['containers']! as List<Object?>)
              .cast<Map<String, Object?>>();
      expect(containers, hasLength(1));
      expect(
        containers.single['extentGrowthSteps'],
        greaterThan(0),
        reason: '分页是滚过去之后才补进来的，这就是懒加载证据：$payload',
      );

      // 返回的 generation 就是紧接着做写命令时该带的那一个。
      final PatchbayInvocation tap = await _pump(
        tester,
        host.bridge.gesture.pressHold(
          identifier: revealTargetSemanticsId,
          generation: payload['generation']! as int,
          start: const <String, Object?>{'x': 0.5, 'y': 0.5},
          durationMs: 60,
        ),
      );
      expect(tap.admission, PatchbayAdmission.rejected);
      // 手势面只开放专用 gesture surface，reveal 出来的行不在其中——这条断言
      // 证明的是 generation 真的被后续写命令接受了（拒绝码是 policy 的，不是
      // `uiGenerationStale`）。
      expect(tap.rejection?.code, 'uiGestureDenied');
    });
  });

  testWidgets('the semantics-only row reveals as semanticsOnly', (
    WidgetTester tester,
  ) async {
    await _withRevealScreen(tester, (
      PatchbayExampleHost host,
      WidgetTester tester,
    ) async {
      final PatchbayInvocation result = await _pump(
        tester,
        host.bridge.reveal.reveal(
          identifier: revealSemanticsOnlyRowId,
          container: revealListSemanticsId,
          direction: PatchbayRevealDirection.forward,
          maxSteps: 60,
          timeoutMs: 20000,
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(
        result.payload['outcome'],
        'revealed',
        reason: '${result.payload}',
      );
      // 没有指针占位：后续必须走 canonical `--via semantics`，选择 pointer
      // 会稳定失败。
      expect(result.payload['reachability'], 'semanticsOnly');
    });
  });

  testWidgets('the reveal policy opens only its own list', (
    WidgetTester tester,
  ) async {
    // 出厂形状：接入方没有为某个可滚动区域写下授权，reveal 就不驱动它。
    expect(
      exampleRevealPolicy(
        _container(gestureListSemanticsId),
        PatchbayRevealDirection.both,
      ).allowed,
      isFalse,
    );
    final PatchbayRevealDecision allowed = exampleRevealPolicy(
      _container(revealListSemanticsId),
      PatchbayRevealDirection.forward,
    );
    expect(allowed.allowed, isTrue);
    expect(allowed.gateIds, <String>{exampleWriteGate});
    // 预算只能相对 host 硬顶收紧。
    expect(allowed.maxSteps, lessThanOrEqualTo(200));
    expect(allowed.maxDurationMs, lessThanOrEqualTo(120000));
  });

  testWidgets('a request above the policy budget is refused, not clamped', (
    WidgetTester tester,
  ) async {
    await _withRevealScreen(tester, (
      PatchbayExampleHost host,
      WidgetTester tester,
    ) async {
      final PatchbayInvocation result = await _pump(
        tester,
        host.bridge.reveal.reveal(
          identifier: revealTargetSemanticsId,
          container: revealListSemanticsId,
          maxSteps: 120,
          timeoutMs: 20000,
        ),
      );

      expect(result.admission, PatchbayAdmission.rejected);
      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>['maxSteps']);
    });
  });
}

PatchbaySemanticsTarget _container(String identifier) =>
    PatchbaySemanticsTarget(
      nodeId: 1,
      generation: 1,
      identifier: identifier,
      label: '',
      flags: const <String>{},
      actions: const <PatchbaySemanticsAction>{
        PatchbaySemanticsAction.scrollUp,
      },
      obscured: false,
    );

Future<void> _withRevealScreen(
  WidgetTester tester,
  Future<void> Function(PatchbayExampleHost host, WidgetTester tester) body,
) async {
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
    await tester.pumpWidget(
      PatchbayExampleApp(
        model: model,
        noteKey: noteKey,
        cardCaptureKey: cardCaptureKey,
        router: router,
      ),
    );
    // 走 example 真正发货的那条导航路径，不在测试里另建一棵 widget 树。
    final PatchbayInvocation navigated = await _pump(
      tester,
      host.bridge.navigation!.go(
        destinationId: revealDestinationId,
        revision: router.revision,
        timeout: const Duration(seconds: 20),
      ),
    );
    expect(navigated.admission, PatchbayAdmission.accepted);
    await tester.pumpAndSettle();

    await body(host, tester);
  } finally {
    host.bridge.semantics.dispose();
    host.dispose();
    model.dispose();
  }
}

Future<T> _pump<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 800 && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) {
    throw StateError('example reveal did not complete in 800 frames');
  }
  return pending;
}
