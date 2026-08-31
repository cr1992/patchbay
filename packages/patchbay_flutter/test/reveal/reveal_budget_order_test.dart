// PB-050-36：reveal 预算门与曝光/容器短路的求值顺序——**表征测试，不是契约测试**。
//
// 读之前先看清这一点：本文件断言的是**当前行为**，不是已裁决的期望行为。
// [UI 可达性与遮挡语义](../../../../docs/proposals/0.6.0/ui-reachability-semantics.md)
// 原话是「不得先按直觉改顺序」——DG-060-05 要先有决定性复现才能裁决 policy 上限
// 到底是所有调用的前置参数门，还是只约束真正进入滚动执行的预算。本文件就是那份
// 复现，落点记录在
// [reveal 预算门求值顺序](../../../../docs/verification/0.6.0-reveal-budget-order.md)。
//
// 因此：**裁决之前不要"修正"这里的断言**。如果某条断言开始失败，说明求值顺序在
// 无人裁决的情况下漂移了，那正是本文件要抓的东西。裁决之后，被接受的结论会把对应
// 断言改成契约断言（或按 Proposal 的说法「为接受的结论补失败测试」）。
//
// 三方对照是决定性的关键：同一份越界预算参数，分别落在三条终止路径上。
//
//   有可驱动容器 + 目标屏外   -> _run 可达 -> 预算门生效 -> uiRevealBudgetExceeded
//   无可驱动候选 + 目标已露出 -> _admit 短路成功 -> 预算门**未**求值 -> revealed/steps 0
//   无可驱动候选 + 目标未露出 -> _admit 短路拒绝 -> 预算门**未**求值 -> noScrollableContainer
//
// 第一条此前已被 reveal_policy_test.dart 的预算矩阵覆盖；这里重述它不是冗余，
// 而是因为"缺口只限短路路径"这个结论只有在三条路径同参数并列时才成立——单独看
// 任何一条都读不出顺序。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

/// 一个刻意比 policy 宽的调用参数：仍在命令参数域 1..200 内，但越过下面的 policy。
const int _overPolicyMaxSteps = 40;

/// 同理的时长参数：在 host 硬顶 120000 内，越过下面的 policy。
const int _overPolicyTimeoutMs = 5000;

PatchbayFlutterBridge _tightBudgetBridge() => revealBridge(
  policy: (_, _) =>
      const PatchbayRevealDecision.allow(maxSteps: 2, maxDurationMs: 1000),
);

void main() {
  setUp(resetRevealCounters);

  group('PB-050-36 求值顺序表征：同一越界预算落在三条终止路径上', () {
    testWidgets('有可驱动容器 + 目标屏外 ⇒ 预算门生效（_run 可达）', (WidgetTester tester) async {
      // 对照锚点。它证明"预算门本身是好的"——缺口不在预算门的实现，而在它被求值
      // 的位置。视口 240 / 行高 60 = 一屏 4 行，目标在 380，必须滚动才能露出。
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final PatchbayFlutterBridge bridge = _tightBudgetBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 400, targetIndex: 380, controller: controller),
        ),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          maxSteps: _overPolicyMaxSteps,
          timeoutMs: _overPolicyTimeoutMs,
        ),
      );

      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>[
        'maxSteps',
        'timeoutMs',
      ], reason: '两项都越界时应逐项列出，不只报第一项');
      expect(controller.offset, 0, reason: '被预算门拒绝的调用不得先滚一点再拒绝');
      expect(showOnScreenCalls, 0);
    });

    testWidgets('无可驱动候选 + 目标已露出 ⇒ 短路成功，预算门未求值（当前行为）', (
      WidgetTester tester,
    ) async {
      // 目标在 index 0、内容不足一屏，因此没有可驱动候选而目标已露出，
      // `_admit` 短路成功。越界参数在这条路径上观察不到 uiRevealBudgetExceeded。
      final PatchbayFlutterBridge bridge = _tightBudgetBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 2, targetIndex: 0)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          maxSteps: _overPolicyMaxSteps,
          timeoutMs: _overPolicyTimeoutMs,
        ),
      );

      expect(
        result.rejection,
        isNull,
        reason:
            '当前行为：已露出即短路成功，越界预算参数不被求值。'
            'DG-060-05 裁决前不要把这条改成期望拒绝——先改行为再改断言，'
            '等于让实现自己裁决自己。',
      );
      final Map<String, Object?> payload = revealPayload(result);
      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], 0, reason: '短路成功不消耗步数');
      expectRevealInvariants(payload);
    });

    testWidgets('无可驱动候选 + 目标未露出 ⇒ 短路拒绝容器门，预算门未求值（当前行为）', (
      WidgetTester tester,
    ) async {
      // 目标不在树上且内容不足一屏：没有可驱动候选、也没有露出，`_admit` 按
      // uiRevealNoScrollableContainer 拒绝。越界预算同样不参与判定，因此调用方
      // 拿到的恢复方向是"去查滚动容器与 --container"，而不是"预算越界"。
      final PatchbayFlutterBridge bridge = _tightBudgetBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 2, targetIndex: -1, targetId: 'reveal.absent'),
        ),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          maxSteps: _overPolicyMaxSteps,
          timeoutMs: _overPolicyTimeoutMs,
        ),
      );

      expect(
        result.rejection?.code,
        'uiRevealNoScrollableContainer',
        reason: '当前行为：容器门先于预算门。DG-060-05 裁决前不要改。',
      );
      expect(
        result.rejection?.details.containsKey('exceeded'),
        isFalse,
        reason: '容器门的 details 不携带预算越界信息',
      );
      expect(showOnScreenCalls, 0);
    });
  });

  group('PB-050-36 边界：短路吞掉的是整个预算门，不是某一个字段', () {
    // 若只有 maxSteps 被吞、timeoutMs 仍生效，缺口的形状会完全不同（是字段级遗漏
    // 而非求值位置问题），裁决方向也随之不同。逐字段验一遍把这个可能性排除掉。
    for (final ({String field, int maxSteps, int timeoutMs}) probe
        in <({String field, int maxSteps, int timeoutMs})>[
          (field: 'maxSteps', maxSteps: _overPolicyMaxSteps, timeoutMs: 500),
          (field: 'timeoutMs', maxSteps: 1, timeoutMs: _overPolicyTimeoutMs),
        ]) {
      testWidgets('已露出短路吞掉越界的 ${probe.field}（当前行为）', (
        WidgetTester tester,
      ) async {
        final PatchbayFlutterBridge bridge = _tightBudgetBridge();
        addTearDown(bridge.dispose);
        await tester.pumpWidget(
          revealApp(revealList(itemCount: 2, targetIndex: 0)),
        );

        final PatchbayInvocation result = await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            maxSteps: probe.maxSteps,
            timeoutMs: probe.timeoutMs,
          ),
        );

        expect(result.rejection, isNull, reason: 'field=${probe.field}');
        expect(revealPayload(result)['steps'], 0);
      });
    }
  });
}
