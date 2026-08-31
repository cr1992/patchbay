// PB-050-36：reveal 的两层预算契约——调用级硬顶 vs 容器级 policy 预算。
//
// DG-060-05 已裁决（[UI 可达性与遮挡语义](../../../../docs/proposals/0.6.0/ui-reachability-semantics.md)
// 已接受）：**保持两层预算，不前移容器 policy**。
//
//   host 调用级硬顶（`maxSteps 1..200` / `timeoutMs 1..120000`）在容器解析前**总是**求值；
//   `PatchbayRevealPolicy` 回答"是否驱动这个容器、以及这个容器的预算"，
//   只在已选出将被驱动的容器之后求值。
//
// 因此"目标已曝光"与"无可驱动容器"两条终止路径上，越过 policy 上限的参数**不构成拒绝**——
// 那里不存在容器可以问 policy，裁决明确不给它传 nullable/伪造容器，也不新增第三层调用 policy。
//
// 本文件原为 PB-050-36 的表征测试（记录当时行为以供裁决）；裁决落地后转为**契约测试**：
// 下列断言现在是被接受的长期契约，任何一条失败都意味着实现偏离了 DG-060-05，而不是"顺序漂移
// 待确认"。取证过程与三方对照的原始记录留在
// [reveal 预算门求值顺序](../../../../docs/verification/0.6.0-reveal-budget-order.md)。
//
// 三条终止路径的契约：
//
//   有可驱动容器 + 目标屏外   -> 容器已选出 -> policy 预算求值 -> uiRevealBudgetExceeded
//   无可驱动候选 + 目标已露出 -> 无容器可问 policy -> revealed / steps 0
//   无可驱动候选 + 目标未露出 -> 无容器可问 policy -> 容器/目标类拒绝
//
// 三方并列不是冗余：只有同一份越界参数同时落在三条路径上，"两层预算"才是可验证的断言，
// 而不是一句可以各自解释的描述。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

/// 一个刻意比 policy 宽的调用参数：仍在调用级硬顶 1..200 内，但越过下面的 policy。
const int _overPolicyMaxSteps = 40;

/// 同理的时长参数：在调用级硬顶 1..120000 内，越过下面的 policy。
const int _overPolicyTimeoutMs = 5000;

PatchbayFlutterBridge _tightBudgetBridge() => revealBridge(
  policy: (_, _) =>
      const PatchbayRevealDecision.allow(maxSteps: 2, maxDurationMs: 1000),
);

void main() {
  setUp(resetRevealCounters);

  group('PB-050-36 两层预算契约：同一越界参数落在三条终止路径上', () {
    testWidgets('有可驱动容器 + 目标屏外 ⇒ 容器级 policy 预算求值并拒绝', (
      WidgetTester tester,
    ) async {
      // 容器被选出，因此 policy 被问到，其预算生效。视口 240 / 行高 60 = 一屏 4 行，
      // 目标在 380，必须滚动才能露出。
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

    testWidgets('无可驱动候选 + 目标已露出 ⇒ steps 0 成功，不问容器 policy', (
      WidgetTester tester,
    ) async {
      // 目标在 index 0、内容不足一屏：没有可驱动候选而目标已露出。裁决明确此时允许
      // steps: 0 成功，且不用一个并不存在的容器去调用 policy。
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
            'DG-060-05 契约：容器级 policy 只约束真正被驱动的容器，'
            '已曝光路径上越界参数不构成拒绝',
      );
      final Map<String, Object?> payload = revealPayload(result);
      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], 0, reason: '无需驱动时不消耗步数');
      expectRevealInvariants(payload);
    });

    testWidgets('无可驱动候选 + 目标未露出 ⇒ 容器类拒绝，不问容器 policy', (
      WidgetTester tester,
    ) async {
      // 目标不在树上且内容不足一屏：没有可驱动候选、也没有露出。裁决要求这里返回
      // 目标/容器类拒绝而不是预算拒绝——调用方需要的恢复方向是查容器与 identifier。
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
        isNot('uiRevealBudgetExceeded'),
        reason: 'DG-060-05 契约：无容器路径不评估容器级 policy 预算',
      );
      expect(
        result.rejection?.details.containsKey('exceeded'),
        isFalse,
        reason: '容器/目标类拒绝的 details 不携带预算越界信息',
      );
      expect(showOnScreenCalls, 0);
    });
  });

  group('PB-050-36 调用级硬顶与容器无关，总是求值', () {
    // 契约的另一半：硬顶不是"容器被选出后才生效"的东西。同一条已曝光路径上，
    // 越过硬顶的参数必须被拒——否则"总是求值"这句话没有执行位置。
    for (final ({String field, int maxSteps, int timeoutMs}) probe
        in <({String field, int maxSteps, int timeoutMs})>[
          (field: 'maxSteps', maxSteps: 201, timeoutMs: 5000),
          (field: 'maxSteps', maxSteps: 0, timeoutMs: 5000),
          (field: 'timeoutMs', maxSteps: 40, timeoutMs: 120001),
          (field: 'timeoutMs', maxSteps: 40, timeoutMs: 0),
        ]) {
      testWidgets('已曝光路径上越过调用级硬顶的 ${probe.field}'
          '（${probe.maxSteps}/${probe.timeoutMs}）仍被拒', (
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

        expect(
          result.rejection,
          isNotNull,
          reason:
              '调用级硬顶在容器解析前求值，已曝光短路不能吞掉它'
              '（field=${probe.field}）',
        );
        expect(showOnScreenCalls, 0);
      });
    }
  });

  group('PB-050-36 容器级 policy 越界在两条短路路径上都不拒绝', () {
    // 逐字段各验一次，排除"只有 maxSteps 被 policy 层跳过"的读法：两个字段的
    // 容器级上限都只在容器被驱动时求值，因此这是分层结论而非字段级遗漏。
    for (final ({String field, int maxSteps, int timeoutMs}) probe
        in <({String field, int maxSteps, int timeoutMs})>[
          (field: 'maxSteps', maxSteps: _overPolicyMaxSteps, timeoutMs: 500),
          (field: 'timeoutMs', maxSteps: 1, timeoutMs: _overPolicyTimeoutMs),
        ]) {
      testWidgets('已曝光路径上越过容器级 policy 的 ${probe.field} 不构成拒绝', (
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
