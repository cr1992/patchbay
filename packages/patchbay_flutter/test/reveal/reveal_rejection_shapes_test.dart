// PB-050-35 / DG-060-05：`ui.reveal` 准入拒绝的三种恢复方向。
//
// 裁决把一个偏宽的 `uiRevealNoScrollableContainer` 拆成三个码，每个码对应一个
// 调用方**做得出来**的下一步：
//
//   uiRevealTargetNotFound        -> 改 identifier，或显式给一个可授权容器
//   uiRevealTargetObscured        -> 处理 modal / 覆盖层；不要再想着滚过去
//   uiRevealNoScrollableContainer -> 修 / 开放滚动容器
//
// 本文件的每一条用例都只钉一个可独立失败的分类事实，因此三个码的边界是逐条
// 可证伪的，而不是「跑一遍矩阵看总体没红」。特别是两条**否定**用例——目标不
// 存在但有容器、目标完全剪裁但有容器——它们守的是「新码不许吃掉正常输入」：
// 没有它们，把所有拿不到目标的情形一律判成 NotFound 也能让肯定用例全绿。
//
// 边界另一半在受理之后：进入滚动之后才发现的遮挡仍然是 accepted payload 的
// `reason`，不倒退成准入拒绝（见本文件最后一组）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

/// 一行的高度之外，`revealApp` 的视口是 240 逻辑像素高：index 5 的行落在
/// 300..360，因此在 cacheExtent 内被构建（已挂载）却完全在 paint clip 之外
/// （未曝光）。这正是「剪裁不叫遮挡」要区分的那一格。
const int _clippedButMountedIndex = 5;

void main() {
  setUp(resetRevealCounters);

  group('目标零匹配', () {
    testWidgets('无可驱动容器 ⇒ uiRevealTargetNotFound，details 带 matchCount 0', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      // 内容不足一屏：容器在树上，但它没有暴露任何同轴 scroll action。
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

      expect(result.rejection?.code, 'uiRevealTargetNotFound');
      expect(result.rejection?.details['identifier'], revealTargetId);
      expect(result.rejection?.details['matchCount'], 0);
      expect(showOnScreenCalls, 0);
    });

    testWidgets('容器存在但不可驱动 ⇒ 仍是 uiRevealTargetNotFound', (
      WidgetTester tester,
    ) async {
      // 「有一个滚动节点」不等于「有容器可以继续查找」：physics 不让驱动，就
      // 没有任何办法把这个 identifier 找出来，恢复方向仍然是改 identifier。
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

      expect(result.rejection?.code, 'uiRevealTargetNotFound');
      expect(showOnScreenCalls, 0);
    });

    testWidgets('零匹配但有唯一可驱动容器 ⇒ 继续 reveal，不是 NotFound', (
      WidgetTester tester,
    ) async {
      // 否定用例：目标未挂载正是本命令存在的理由。新码若在这里抢答，reveal 就
      // 失去了它唯一的核心场景。
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], greaterThan(0));
      expectRevealInvariants(payload);
    });
  });

  group('已挂载且几何上已曝光', () {
    testWidgets(
      'blockUserActions ⇒ uiRevealTargetObscured，details 带 generation',
      (WidgetTester tester) async {
        final PatchbayFlutterBridge bridge = revealBridge();
        addTearDown(bridge.dispose);
        await tester.pumpWidget(revealApp(_blockedExposedTarget()));

        final PatchbayInvocation result = await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        );

        expect(result.rejection?.code, 'uiRevealTargetObscured');
        expect(result.rejection?.details['identifier'], revealTargetId);
        expect(result.rejection?.details['generation'], isA<int>());
        // 遮挡 details 不暴露坐标、采样点或覆盖层身份。
        expect(result.rejection?.details.keys, <String>[
          'identifier',
          'generation',
        ]);
        expect(showOnScreenCalls, 0, reason: '分类发生在第一次派发之前，不消耗 step 也不驱动任何容器');
      },
    );

    testWidgets('不透明浮层盖住五个采样点 ⇒ uiRevealTargetObscured，且不尝试滚动穿透', (
      WidgetTester tester,
    ) async {
      // 目标在 index 0：已挂载、完全在 viewport 内，而列表本身**有** 40 行、
      // 可驱动。所以这一条同时钉住判定顺序——遮挡分类排在容器解析之前。
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(_coveredExposedTarget(controller: controller)),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          maxSteps: 60,
          timeoutMs: 60000,
        ),
      );

      expect(result.rejection?.code, 'uiRevealTargetObscured');
      expect(controller.offset, 0, reason: '滚动穿不透覆盖层，一步都不许派发');
      expect(showOnScreenCalls, 0);
    });
  });

  group('已挂载但尚未曝光', () {
    testWidgets('完全剪裁 + 容器不可驱动 ⇒ uiRevealNoScrollableContainer', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(
            itemCount: 40,
            targetIndex: _clippedButMountedIndex,
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
      expect(result.rejection?.details['identifier'], revealTargetId);
      expect(
        result.rejection?.details.containsKey('role'),
        isFalse,
        reason: 'role 只在显式锚点拒绝上出现，这里说的是目标',
      );
      expect(showOnScreenCalls, 0);
    });

    testWidgets('完全剪裁 + 祖先链上没有可驱动节点 ⇒ uiRevealNoScrollableContainer', (
      WidgetTester tester,
    ) async {
      // 与上一条的区别是「别处确实有一个可驱动容器」：判据是**目标的祖先链**，
      // 不是全树有没有滚动节点。推那个平级容器不会让目标露出，所以这里仍然是
      // 容器类拒绝，而不是拿邻居的容器凑数。
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(_clippedUnderNonDrivableAncestor()));

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
      );

      expect(result.rejection?.code, 'uiRevealNoScrollableContainer');
      expect(result.rejection?.details['identifier'], revealTargetId);
      expect(showOnScreenCalls, 0);
    });

    testWidgets('完全剪裁但有可驱动容器 ⇒ 继续 reveal，不是遮挡也不是无容器', (
      WidgetTester tester,
    ) async {
      // 否定用例：完全剪裁出 viewport 是 reveal 的正常输入。这一条与上一条只差
      // 一个 physics，因此「剪裁 ≠ 遮挡」是被单独证伪的，不是顺带绿的。
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 40, targetIndex: _clippedButMountedIndex),
        ),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(
            identifier: revealTargetId,
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expectRevealInvariants(payload);
    });
  });

  group('显式容器锚点', () {
    testWidgets('锚点内无可驱动节点 ⇒ uiRevealNoScrollableContainer 且 details 带 '
        'role: container', (WidgetTester tester) async {
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
        bridge.reveal.reveal(
          identifier: revealTargetId,
          container: revealContainerId,
          timeoutMs: 60000,
        ),
      );

      expect(result.rejection?.code, 'uiRevealNoScrollableContainer');
      expect(
        result.rejection?.details['identifier'],
        revealContainerId,
        reason: '显式锚点拒绝说的是容器的 identifier，不是目标的',
      );
      expect(result.rejection?.details['role'], 'container');
      expect(
        result.rejection?.code,
        isNot('uiRevealTargetNotFound'),
        reason: '显式授权容器在场时，零匹配不归 NotFound——它就是"可继续查找"的那个容器',
      );
      expect(showOnScreenCalls, 0);
    });
  });

  group('受理之后不倒退成准入拒绝', () {
    testWidgets('滚动之后才发现的遮挡仍是 accepted payload 的 targetObscured', (
      WidgetTester tester,
    ) async {
      // 目标一开始在 paint clip 之外（准入期判为"未曝光"），滚进来才撞上固定
      // 覆盖层。此时已经派发过 scroll，事实是受理后的，必须留在 payload 里。
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          Stack(
            fit: StackFit.expand,
            children: <Widget>[
              revealList(itemCount: 8, targetIndex: 7),
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      );

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          direction: PatchbayRevealDirection.forward,
          maxSteps: 40,
          timeoutMs: 60000,
        ),
      );

      expect(result.rejection, isNull, reason: '滚动已经发生，不能倒退成准入拒绝');
      final Map<String, Object?> payload = revealPayload(result);
      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'targetObscured');
      expect(payload['steps'], greaterThan(0));
      expectRevealInvariants(payload);
    });
  });

  group('失败注入', () {
    testWidgets('准入期已遮挡 ⇒ 门根本不被求值，门后撤掉浮层也改不了结论', (WidgetTester tester) async {
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
      await tester.pumpWidget(revealApp(_coveredExposedTarget()));

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        dispose: false,
      );

      expect(result.rejection?.code, 'uiRevealTargetObscured');
      expect(gateCalls, 0, reason: '可达性分类在容器解析与门之前，没有容器可授权就不问门');

      // 撤掉浮层并让目标重挂载：分类不缓存，同一个 bridge 的下一次调用按新现场
      // 重新判定。
      await tester.pumpWidget(
        revealApp(
          revealList(
            itemCount: 40,
            targetIndex: 0,
            listKey: const ValueKey<int>(2),
          ),
        ),
      );
      final PatchbayInvocation second = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
      );

      expect(second.rejection, isNull, reason: '浮层撤掉后同一目标应当可达');
      expect(revealPayload(second)['outcome'], 'revealed');
      expect(showOnScreenCalls, 0);
    });

    testWidgets('门 await 期间浮层盖上 ⇒ 受理后事实，不是准入拒绝', (WidgetTester tester) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var opened = false;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            if (opened) return const PatchbayGateDecision.allow();
            opened = true;
            return gate.future;
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      // 准入期：目标在 index 5，被剪裁但有可驱动容器 ⇒ 分类为"未曝光"，放行。
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 40, targetIndex: _clippedButMountedIndex),
        ),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 40,
        timeoutMs: 60000,
      );
      await tester.pump();
      await tester.pump();
      // 门还没放行，覆盖层已经盖上。
      await tester.pumpWidget(
        revealApp(
          Stack(
            fit: StackFit.expand,
            children: <Widget>[
              revealList(itemCount: 40, targetIndex: _clippedButMountedIndex),
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      );
      gate.complete(const PatchbayGateDecision.allow());

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        pending,
      );

      expect(
        result.rejection?.code,
        isNot('uiRevealTargetObscured'),
        reason: '准入边界是第一次派发；门后出现的覆盖层不能改写已经作出的分类',
      );
      expect(showOnScreenCalls, 0);
    });
  });
}

/// 目标在 index 0：已挂载、完全在 viewport 内，但被 `blockUserActions` 屏蔽。
///
/// 列表本身有 40 行且可驱动——用它证明遮挡分类排在容器解析之前。
Widget _blockedExposedTarget() => Semantics(
  identifier: revealContainerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      itemExtent: revealRowExtent,
      itemCount: 40,
      itemBuilder: (BuildContext context, int index) => index == 0
          ? Semantics(
              blockUserActions: true,
              child: revealPointerRow(revealTargetId),
            )
          : Center(child: Text('row $index')),
    ),
  ),
);

/// 目标在 index 0 且被一层铺满视口的不透明层盖住，列表仍可驱动。
Widget _coveredExposedTarget({ScrollController? controller}) => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    revealList(itemCount: 40, targetIndex: 0, controller: controller),
    const Listener(
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(color: Colors.black),
    ),
  ],
);

/// 目标挂在一个**不可驱动**的列表里（被它的 viewport 完全剪掉，但仍在
/// cacheExtent 内因而已挂载），同时另一半是一个可驱动的平级列表。
///
/// 平级容器推不动目标，所以准入判据只看祖先链。
Widget _clippedUnderNonDrivableAncestor() => Column(
  children: <Widget>[
    Expanded(
      child: Semantics(
        identifier: revealOuterContainerId,
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
        identifier: revealContainerId,
        container: true,
        child: ShowOnScreenRecorder(
          child: ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            itemExtent: revealRowExtent,
            itemCount: 40,
            itemBuilder: (BuildContext context, int index) => index == 3
                ? revealPointerRow(revealTargetId)
                : Center(child: Text('right $index')),
          ),
        ),
      ),
    ),
  ],
);
