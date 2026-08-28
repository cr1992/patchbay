// PB-050-17 / DG-050-10：逐容器授权、三层预算与逐步重评门。
//
// 本文件锁的是「授权一次 reveal 不存在，存在的只有授权驱动这一个容器」这条
// 机制：准入求值、每步重评、升层再授权，以及三层预算只能收紧、且 min 通过
// **拒绝**达成而不是静默夹取。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

void main() {
  setUp(resetRevealCounters);

  group('未注入 reveal policy', () {
    testWidgets('命令不在 catalog，直接调 bridge 得 uiRevealDisabled', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: allowingGates(),
        isAppResumed: () => true,
      );
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      expect(bridge.reveal.enabled, isFalse);
      final Map<String, Object?> catalog = await host.dispatchCatalog();
      final List<Object?> commands = catalog['commands']! as List<Object?>;
      expect(
        commands.cast<Map<String, Object?>>().map(
          (Map<String, Object?> row) => row['name'],
        ),
        isNot(contains('ui.reveal')),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId),
      );
      expect(result.rejection?.code, 'uiRevealDisabled');
    });

    testWidgets('注入之后命令进 catalog', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      expect(bridge.reveal.enabled, isTrue);
      final Map<String, Object?> catalog = await host.dispatchCatalog();
      expect(
        (catalog['commands']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((Map<String, Object?> row) => row['name']),
        contains('ui.reveal'),
      );
      bridge.semantics.dispose();
    });
  });

  group('三层预算只能收紧', () {
    testWidgets('参数 maxSteps 超 policy 上限 ⇒ uiRevealBudgetExceeded，'
        '且一步都没派发（不静默夹取）', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.allow(
          maxSteps: 2,
          maxDurationMs: 9000,
        ),
      );
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
          maxSteps: 40,
          timeoutMs: 5000,
        ),
      );

      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>['maxSteps']);
      expect(controller.offset, 0, reason: '被拒绝的调用不得先滚一点再拒绝');
      expect(showOnScreenCalls, 0);
    });

    testWidgets('参数 timeoutMs 超 policy 上限 ⇒ uiRevealBudgetExceeded', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.allow(
          maxSteps: 40,
          maxDurationMs: 1000,
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 5000),
      );

      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>['timeoutMs']);
    });

    testWidgets('policy 自身越出 host 硬顶 ⇒ uiRevealBudgetExceeded', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.allow(
          maxSteps: 201,
          maxDurationMs: 120001,
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId),
      );

      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>[
        'maxSteps',
        'timeoutMs',
      ]);
      expect(result.rejection?.details['hostMaxSteps'], 200);
      expect(result.rejection?.details['hostMaxDurationMs'], 120000);
    });

    testWidgets('参数比 policy 严 ⇒ 生效预算是参数', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.allow(
          maxSteps: 40,
          maxDurationMs: 120000,
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 2,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['reason'], 'stepBudgetExceeded');
      expect(payload['steps'], 2);
      expectRevealInvariants(payload);
    });

    testWidgets('协议区间由 descriptor 之外的 bridge 再守一次 ⇒ '
        'invalidUiArguments', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      for (final ({int maxSteps, int timeoutMs, String field}) probe
          in <({int maxSteps, int timeoutMs, String field})>[
            (maxSteps: 0, timeoutMs: 5000, field: 'maxSteps'),
            (maxSteps: 201, timeoutMs: 5000, field: 'maxSteps'),
            (maxSteps: 40, timeoutMs: 0, field: 'timeoutMs'),
            (maxSteps: 40, timeoutMs: 120001, field: 'timeoutMs'),
          ]) {
        final PatchbayInvocation result = await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            maxSteps: probe.maxSteps,
            timeoutMs: probe.timeoutMs,
          ),
          dispose: false,
        );
        expect(result.rejection?.code, 'invalidUiArguments', reason: '$probe');
        expect(result.rejection?.details['invalid'], <String>[probe.field]);
      }
      final PatchbayInvocation empty = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: ''),
      );
      expect(empty.rejection?.code, 'invalidUiArguments');
    });
  });

  group('逐容器授权', () {
    testWidgets('policy 拒绝准入容器 ⇒ uiRevealDenied，自定 code 原样透出', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.reject(
          rejectionCode: 'exampleRevealNotHere',
          rejectionNotice: 'this surface is not open',
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId),
      );

      expect(result.rejection?.code, 'exampleRevealNotHere');
      expect(result.rejection?.notice, 'this surface is not open');
    });

    testWidgets('默认拒绝码是 uiRevealDenied', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) => const PatchbayRevealDecision.reject(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId),
      );

      expect(result.rejection?.code, 'uiRevealDenied');
    });

    testWidgets('内层 allow、外层 reject ⇒ containerDenied，containers 只含内层', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (PatchbaySemanticsTarget container, _) =>
            container.identifier == revealNestedContainerId
            ? const PatchbayRevealDecision.allow(
                maxSteps: 200,
                maxDurationMs: 120000,
              )
            : const PatchbayRevealDecision.reject(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_nestedLists()));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            container: revealNestedContainerId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'containerDenied');
      expect(revealContainers(payload), hasLength(1));
      expectRevealInvariants(payload);
    });

    testWidgets('外层 maxDurationMs 小于已冻结时长预算 ⇒ containerBudgetTooSmall', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (PatchbaySemanticsTarget container, _) =>
            container.identifier == revealNestedContainerId
            ? const PatchbayRevealDecision.allow(
                maxSteps: 200,
                maxDurationMs: 120000,
              )
            // 外层只授权 1 秒，本次已冻结的预算是 60 秒：不改写 deadline，停下。
            : const PatchbayRevealDecision.allow(
                maxSteps: 200,
                maxDurationMs: 1000,
              ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_nestedLists()));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            container: revealNestedContainerId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'containerBudgetTooSmall');
      expect(revealContainers(payload), hasLength(1));
      expectRevealInvariants(payload);
    });
  });

  group('逐步授权', () {
    testWidgets('门被调用次数 == steps + 1（准入 1 次 + 每步 1 次）', (
      WidgetTester tester,
    ) async {
      var gateCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            gateCalls += 1;
            return const PatchbayGateDecision.allow();
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 3,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['steps'], 3);
      expect(gateCalls, 4);
      expectRevealInvariants(payload);
    });

    testWidgets('门在第 k 步转为拒绝 ⇒ gateRejected 且 steps == k - 1', (
      WidgetTester tester,
    ) async {
      // 门求值序：#1 准入，#2 第 1 步之前，#3 第 2 步之前，#4 第 3 步之前。
      // 在 #4 拒绝即证明门在派发之前：已派发 2 步。
      var gateCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) {
            gateCalls += 1;
            return gateCalls < 4
                ? const PatchbayGateDecision.allow()
                : const PatchbayGateDecision.reject(
                    code: 'exampleWriteGateClosed',
                    notice: 'closed mid-reveal',
                  );
          },
        ),
        policy: (_, _) => const PatchbayRevealDecision.allow(
          gateIds: <String>{'example.write'},
          maxSteps: 200,
          maxDurationMs: 120000,
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'gateRejected');
      expect(payload['steps'], 2, reason: '那一步没派发出去：$payload');
      expect(payload['gateId'], 'example.write');
      expect(payload['gateCode'], 'exampleWriteGateClosed');
      expectRevealInvariants(payload);
    });

    testWidgets('步间 policy 的 gateIds 漂移 ⇒ policyChanged', (
      WidgetTester tester,
    ) async {
      // policy 求值序：#1 准入、#2 门后复核、#3 第 1 步、#4 第 2 步……
      var policyCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) {
          policyCalls += 1;
          return policyCalls < 4
              ? const PatchbayRevealDecision.allow(
                  maxSteps: 200,
                  maxDurationMs: 120000,
                )
              : const PatchbayRevealDecision.allow(
                  gateIds: <String>{'drifted'},
                  maxSteps: 200,
                  maxDurationMs: 120000,
                );
        },
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'policyChanged');
      expect(payload['steps'], 1);
      expectRevealInvariants(payload);
    });

    testWidgets('步间 App 离开 resumed ⇒ lifecycleNotResumed，如实报告已发生步数', (
      WidgetTester tester,
    ) async {
      var resumedCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        isAppResumed: () {
          resumedCalls += 1;
          return resumedCalls < 5;
        },
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'lifecycleNotResumed');
      expect(payload['steps'], greaterThanOrEqualTo(1));
      expectRevealInvariants(payload);
    });
  });
}

/// 内层横向 + 外层竖直，目标在外层靠后的行上。
Widget _nestedLists() => Semantics(
  identifier: revealContainerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      itemExtent: revealRowExtent,
      itemCount: 40,
      itemBuilder: (BuildContext context, int index) {
        if (index == 1) {
          return Semantics(
            identifier: revealNestedContainerId,
            container: true,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemExtent: revealRowExtent,
              itemCount: 20,
              itemBuilder: (BuildContext context, int column) =>
                  Center(child: Text('cell $column')),
            ),
          );
        }
        if (index == 20) return revealPointerRow(revealTargetId);
        return Center(child: Text('row $index'));
      },
    ),
  ),
);
