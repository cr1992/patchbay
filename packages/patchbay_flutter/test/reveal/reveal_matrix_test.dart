// PB-050-17 / DG-050-10：`ui.reveal` 的终止条件矩阵。
//
// 每一格都断言 payload 的形状而不只是 outcome：`containers` 的三条不变式由
// [expectRevealInvariants] 统一守住，reason 与 reachability 的 presence /
// absence 逐条断言。整条矩阵还共用一条机检——从未派发 `showOnScreen`。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

void main() {
  setUp(resetRevealCounters);

  group('终止条件矩阵', () {
    testWidgets('进入循环前目标已挂载且露出 ⇒ steps 0、containers 空、一次 '
        'action 也不派发', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 0)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], 0);
      expect(payload['containers'], isEmpty);
      expect(payload['reachability'], 'pointer');
      expectRevealInvariants(payload);
    });

    testWidgets('单容器滚动后露出 ⇒ containers 恰好一个元素', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], greaterThan(0));
      expect(revealContainers(payload), hasLength(1));
      expect(payload['reachability'], 'pointer');
      expectRevealInvariants(payload);
    });

    testWidgets('滚到底仍无目标 ⇒ scrollExhausted，且与 stepBudgetExceeded 可区分', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 12, targetIndex: -1, targetId: 'reveal.absent'),
        ),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'scrollExhausted');
      // 目标从未挂载：nodeId / generation 不得出现。
      expect(payload.containsKey('nodeId'), isFalse);
      expect(payload.containsKey('generation'), isFalse);
      expectRevealInvariants(payload);
    });

    testWidgets('步数预算用完 ⇒ stepBudgetExceeded，steps 恰好等于预算', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
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
            maxSteps: 1,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'stepBudgetExceeded');
      expect(payload['steps'], 1);
      expect(revealContainers(payload).single['steps'], 1);
      expectRevealInvariants(payload);
    });

    testWidgets('懒加载分页：滚动步后 maxScrollExtent 增长 ⇒ extentGrowthSteps > 0 '
        '且 stall 被增长清零', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(const RevealLazyList(targetIndex: 20)));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 80,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'revealed');
      final Map<String, Object?> container = revealContainers(payload).single;
      expect(
        container['extentGrowthSteps'],
        greaterThan(0),
        reason: '补页那一步必须被记成懒加载证据：$payload',
      );
      expectRevealInvariants(payload);
    });

    testWidgets('嵌套：内层不够、升外层后露出 ⇒ containers 由内向外两个元素', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_nested()));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            // 显式锚在**内层**：内层耗尽后必须升到外层才能到达目标。
            container: revealNestedContainerId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'revealed');
      final List<Map<String, Object?>> containers = revealContainers(payload);
      expect(containers, hasLength(2), reason: '$payload');
      expect(
        containers.first['nodeId'],
        isNot(containers.last['nodeId']),
        reason: '两层必须是两个不同的容器：$payload',
      );
      expectRevealInvariants(payload);
    });

    testWidgets('ModalBarrier 盖住已挂载目标 ⇒ targetBlocked，且不再继续滚动', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_blockedAfterOneStep()));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'targetBlocked');
      // 模态屏蔽滚动解决不了：停在发现它的那一步，不把预算耗光。
      expect(payload['steps'], lessThan(40));
      expect(payload['nodeId'], isA<int>());
      expectRevealInvariants(payload);
    });

    testWidgets('deadline 到 ⇒ timeout，如实报告已发生的步数', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 200,
        timeoutMs: 120,
      );
      await tester.pump();
      await tester.pump();
      // 真实墙钟推过 deadline：帧驱动的下一步会在派发之前如实停下。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      final Map<String, Object?> payload = revealPayload(
        await runReveal(tester, bridge, pending),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'timeout');
      expect(payload['steps'], greaterThanOrEqualTo(1));
      expect(payload['steps'], lessThan(200));
      expectRevealInvariants(payload);
    });

    testWidgets('始终被固定层盖住且容器耗尽 ⇒ targetObscured 而不是伪造成功', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          Stack(
            fit: StackFit.expand,
            children: <Widget>[
              revealList(itemCount: 8, targetIndex: 7),
              // 铺满视口的固定层：目标滚进来了、也挂载了，但五个采样点全被挡。
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      // 「找到了但露不出来」与「根本没找到」是两个事实：前者改 UI 层级，
      // 后者改数据或加预算。
      expect(payload['reason'], 'targetObscured');
      expect(payload['nodeId'], isA<int>());
      expectRevealInvariants(payload);
    });

    testWidgets('循环中出现第二个挂载实例 ⇒ targetAmbiguous，且不带 nodeId', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_duplicateAfterScroll()));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'targetAmbiguous');
      expect(payload.containsKey('nodeId'), isFalse);
      expectRevealInvariants(payload);
    });
  });

  group('reachability 两态分流', () {
    testWidgets('普通按钮行 ⇒ pointer', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['reachability'], 'pointer');
      expectRevealInvariants(payload);
    });

    testWidgets('Semantics(onTap:) > SizedBox 行 ⇒ semanticsOnly', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 40, targetIndex: 20, semanticsOnlyTarget: true),
        ),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['reachability'], 'semanticsOnly');
      expectRevealInvariants(payload);
    });
  });

  group('方向与极性', () {
    testWidgets('reverse: true 的列表用 direction: forward 也能到达', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20, reverse: true)),
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

      expect(payload['outcome'], 'revealed', reason: '$payload');
      expect(revealContainers(payload).single['direction'], 'forward');
      expectRevealInvariants(payload);
    });

    testWidgets('Axis.horizontal 的列表用同一个 forward 语义到达', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 40, targetIndex: 20, axis: Axis.horizontal),
        ),
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

      expect(payload['outcome'], 'revealed', reason: '$payload');
      expectRevealInvariants(payload);
    });

    testWidgets('容器停在中段 + 显式方向 ⇒ 至多一次反向探测步，且探测步计入 '
        'steps 并如实标进 direction', (WidgetTester tester) async {
      // 两个同轴 action 都暴露时，极性不能从 SemanticsData 推出，只能观察：
      // 引擎派发一个候选、等一帧、读位移符号，走反了就为该容器翻转映射。
      // 那一步是真实的反向滚动，所以它计入 steps，也把该容器的
      // `direction` 标成 `both`——这是诚实的代价，不是缺陷。
      // 停在中段、目标在内容序**更前面**：引擎的候选步走反了一次，然后翻转
      // 映射继续。请求 backward 才吃得到这一步——请求 forward 时候选恰好是对的。
      final ScrollController controller = ScrollController(
        initialScrollOffset: 1440,
      );
      addTearDown(controller.dispose);
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 40, targetIndex: 5, controller: controller),
        ),
      );
      await tester.pump();

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.backward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'revealed', reason: '$payload');
      expect(
        revealContainers(payload).single['direction'],
        'both',
        reason: '探测步走反了就该如实说走过两个方向：$payload',
      );
      expectRevealInvariants(payload);
    });

    testWidgets('容器停在端点 ⇒ direction: forward 零探测步', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 8)),
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

      expect(payload['outcome'], 'revealed');
      // 每一步都朝内容深处走，没有一步反向：标签因此是纯 forward。
      expect(revealContainers(payload).single['direction'], 'forward');
      expectRevealInvariants(payload);
    });
  });

  group('准入前拒绝', () {
    testWidgets('内容不足一屏 ⇒ uiRevealNoScrollableContainer', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 2, targetIndex: -1, targetId: 'reveal.absent'),
        ),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
      );

      expect(result.rejection?.code, 'uiRevealNoScrollableContainer');
      expect(showOnScreenCalls, 0);
    });

    testWidgets(
      'NeverScrollableScrollPhysics ⇒ uiRevealNoScrollableContainer',
      (WidgetTester tester) async {
        final PatchbayFlutterBridge bridge = revealBridge();
        addTearDown(bridge.dispose);
        await tester.pumpWidget(
          revealApp(
            revealList(
              itemCount: 40,
              targetIndex: -1,
              targetId: 'reveal.absent',
              physics: const NeverScrollableScrollPhysics(),
            ),
          ),
        );

        final PatchbayInvocation result = await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        );

        expect(result.rejection?.code, 'uiRevealNoScrollableContainer');
        expect(showOnScreenCalls, 0);
      },
    );

    testWidgets('两个平级 ListView 且目标未挂载 ⇒ uiRevealContainerAmbiguous，'
        '补 --container 后成功', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_siblings()));

      final PatchbayInvocation ambiguous = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        dispose: false,
      );
      expect(ambiguous.rejection?.code, 'uiRevealContainerAmbiguous');

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            container: revealOuterContainerId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );
      expect(payload['outcome'], 'revealed', reason: '$payload');
      expectRevealInvariants(payload);
    });

    testWidgets('显式 container 未挂载 ⇒ uiSemanticsIdentifierNotFound '
        '且 details 带 role', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          container: 'reveal.missing',
          timeoutMs: 60000,
        ),
      );

      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      expect(result.rejection?.details['role'], 'container');
    });
  });
}

/// 外层竖直列表，第 8 行里嵌一个自己也要滚的横向列表，目标在横向列表尾部之后
/// 的外层行上——内层耗尽后必须升到外层才能到达。
Widget _nested() => Semantics(
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

/// 目标一挂载就被 `BlockSemantics` 屏蔽。
Widget _blockedAfterOneStep() => Semantics(
  identifier: revealContainerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      itemExtent: revealRowExtent,
      itemCount: 40,
      itemBuilder: (BuildContext context, int index) => index == 12
          ? Semantics(
              blockUserActions: true,
              child: revealPointerRow(revealTargetId),
            )
          : Center(child: Text('row $index')),
    ),
  ),
);

/// 同一个 identifier 在两行上，滚动到中段后会同时挂载。
Widget _duplicateAfterScroll() => Semantics(
  identifier: revealContainerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      itemExtent: revealRowExtent,
      itemCount: 40,
      itemBuilder: (BuildContext context, int index) =>
          index == 12 || index == 13
          ? revealPointerRow(revealTargetId)
          : Center(child: Text('row $index')),
    ),
  ),
);

/// 两个平级滚动容器，目标在第二个里、且一开始没挂载。
Widget _siblings() => Column(
  children: <Widget>[
    Expanded(
      child: Semantics(
        identifier: revealContainerId,
        container: true,
        child: ListView.builder(
          itemExtent: revealRowExtent,
          itemCount: 40,
          itemBuilder: (BuildContext context, int index) =>
              Center(child: Text('left $index')),
        ),
      ),
    ),
    Expanded(
      child: Semantics(
        identifier: revealOuterContainerId,
        container: true,
        child: ShowOnScreenRecorder(
          child: ListView.builder(
            itemExtent: revealRowExtent,
            itemCount: 40,
            itemBuilder: (BuildContext context, int index) => index == 20
                ? revealPointerRow(revealTargetId)
                : Center(child: Text('right $index')),
          ),
        ),
      ),
    ),
  ],
);
