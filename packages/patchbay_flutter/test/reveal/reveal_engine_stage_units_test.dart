// PB-050-38：reveal 步循环**各阶段的独立失败注入**。
//
// 拆分要成立，必须证明每个阶段真的能单独构造、单独喂坏输入、单独判红——否则
// 「拆开了」只是把同一坨代码换了个位置。本文件按阶段分组，每组至少注入一类
// 失败：
//
//   容器事实   轴一个都不暴露 / 端点信息不足 / 锚点身份被内层容器截断
//   layer      停滞未到阈值 / 到阈值可换向 / 到阈值不可换向；探测步至多一次
//   观察       owner 背后的树被连根拔起 / 节点换代 / 目标零匹配与多匹配
//   重评与派发 deadline 已过 / 门慢于 deadline / performAction 抛出
//   升层       候选已访问 / 候选不可驱动 / 当前层不在目标祖先链上
//   投影       目标未挂载时 nodeId 与 generation 不得出现
//
// 其中若干条在端到端路径上要摆出一棵会在特定时刻塌掉的树才碰得到，拆分之后
// 第一次拿到直接覆盖。
import 'dart:async';
import 'dart:ui' show SemanticsUpdate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/semantics/semantics_lookup.dart';
import 'package:patchbay_flutter/src/reveal/reveal_container_facts.dart';
import 'package:patchbay_flutter/src/reveal/reveal_escalation_stage.dart';
import 'package:patchbay_flutter/src/reveal/reveal_layer.dart';
import 'package:patchbay_flutter/src/reveal/reveal_models.dart';
import 'package:patchbay_flutter/src/reveal/reveal_observation_stage.dart';
import 'package:patchbay_flutter/src/reveal/reveal_outcome_stage.dart';
import 'package:patchbay_flutter/src/reveal/reveal_step_stage.dart';

import 'reveal_engine_fixtures.dart';
import 'reveal_fixtures.dart';

const PatchbayRevealDecision _allow = PatchbayRevealDecision.allow(
  maxSteps: 200,
  maxDurationMs: 120000,
);

/// 摆一棵树、把 owner 交给 [body]，然后**在测试体内**还回语义句柄。
///
/// `flutter_test` 在测试体结束时就核对句柄，早于 `addTearDown`，所以句柄不能
/// 留给 tearDown 释放；仓内既有 semantics 用例是同一个写法。
Future<T> _withOwner<T>(
  WidgetTester tester,
  Widget tree,
  FutureOr<T> Function(SemanticsOwner owner) body,
) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  await tester.pumpWidget(revealApp(tree));
  // `rootPipelineOwner` 那个 owner 不持有 widget 树的语义根，只有 binding
  // 自己的 `pipelineOwner` 才有；仓内既有 reveal 用例走的也是这一个。
  // ignore: deprecated_member_use
  final T result = await body(tester.binding.pipelineOwner.semanticsOwner!);
  handle.dispose();
  return result;
}

Future<SemanticsData> _probeData(WidgetTester tester, RevealAxisProbe probe) =>
    _withOwner(
      tester,
      probe,
      (SemanticsOwner owner) => revealNodeWith(
        owner.rootSemanticsNode!,
        probe.identifier,
      ).getSemanticsData(),
    );

void main() {
  setUp(resetRevealCounters);

  group('阶段：容器只读事实', () {
    testWidgets('一个同轴 action 都不暴露 ⇒ 无轴、不可驱动', (WidgetTester tester) async {
      final SemanticsData data = await _probeData(
        tester,
        const RevealAxisProbe(position: 0, min: 0, max: 600),
      );

      expect(PatchbayRevealAxis.of(data), isNull);
      for (final PatchbayRevealDirection direction
          in PatchbayRevealDirection.values) {
        expect(patchbayRevealDrivable(data, direction), isFalse);
      }
    });

    testWidgets('竖直优先于横向：两轴同时暴露时按竖直判', (WidgetTester tester) async {
      final SemanticsData data = await _probeData(
        tester,
        const RevealAxisProbe(
          up: true,
          down: true,
          left: true,
          right: true,
          position: 100,
          min: 0,
          max: 600,
        ),
      );

      expect(PatchbayRevealAxis.of(data), PatchbayRevealAxis.vertical);
      expect(
        PatchbayRevealAxis.of(data)!.exposedIn(data),
        <PatchbaySemanticsAction>[
          PatchbaySemanticsAction.scrollUp,
          PatchbaySemanticsAction.scrollDown,
        ],
      );
    });

    // 每条用例只摆一棵树：`_withOwner` 用完就把语义句柄还回去，同一个测试体里
    // 摆第二棵树拿不到重新构建的语义节点。
    testWidgets('端点极性：两个都暴露 ⇒ 端点说明不了任何事', (WidgetTester tester) async {
      final SemanticsData both = await _probeData(
        tester,
        const RevealAxisProbe(up: true, down: true, position: 0, min: 0),
      );

      expect(
        patchbayRevealForwardFromEnd(
          both,
          PatchbayRevealAxis.vertical,
          PatchbayRevealAxis.vertical.exposedIn(both),
        ),
        isNull,
      );
    });

    testWidgets('端点极性：scrollPosition 缺失 ⇒ 不得瞎猜', (WidgetTester tester) async {
      final SemanticsData noPosition = await _probeData(
        tester,
        const RevealAxisProbe(down: true),
      );

      expect(
        patchbayRevealForwardFromEnd(
          noPosition,
          PatchbayRevealAxis.vertical,
          <PatchbaySemanticsAction>[PatchbaySemanticsAction.scrollDown],
        ),
        isNull,
      );
    });

    testWidgets('端点极性：min 处暴露的是 forward', (WidgetTester tester) async {
      final SemanticsData atMin = await _probeData(
        tester,
        const RevealAxisProbe(down: true, position: 0, min: 0, max: 600),
      );

      expect(
        patchbayRevealForwardFromEnd(
          atMin,
          PatchbayRevealAxis.vertical,
          <PatchbaySemanticsAction>[PatchbaySemanticsAction.scrollDown],
        ),
        PatchbaySemanticsAction.scrollDown,
      );
    });

    testWidgets('端点极性：max 处暴露的是 backward，另一个才是 forward', (
      WidgetTester tester,
    ) async {
      final SemanticsData atMax = await _probeData(
        tester,
        const RevealAxisProbe(up: true, position: 600, min: 0, max: 600),
      );

      expect(
        patchbayRevealForwardFromEnd(
          atMax,
          PatchbayRevealAxis.vertical,
          <PatchbaySemanticsAction>[PatchbaySemanticsAction.scrollUp],
        ),
        PatchbaySemanticsAction.scrollDown,
      );
    });

    testWidgets('极性未定时不得预判不可驱动：探测步还没跑', (WidgetTester tester) async {
      final SemanticsData middle = await _probeData(
        tester,
        const RevealAxisProbe(
          up: true,
          down: true,
          position: 300,
          min: 0,
          max: 600,
        ),
      );

      expect(
        patchbayRevealDrivable(middle, PatchbayRevealDirection.forward),
        isTrue,
      );
      expect(
        patchbayRevealDrivable(middle, PatchbayRevealDirection.backward),
        isTrue,
      );
    });

    testWidgets('已经滚到那一端 ⇒ 该方向不可驱动', (WidgetTester tester) async {
      final SemanticsData atMax = await _probeData(
        tester,
        const RevealAxisProbe(up: true, position: 600, min: 0, max: 600),
      );

      expect(
        patchbayRevealDrivable(atMax, PatchbayRevealDirection.forward),
        isFalse,
        reason: 'forward 落在已经不暴露的 scrollDown 上',
      );
      expect(
        patchbayRevealDrivable(atMax, PatchbayRevealDirection.backward),
        isTrue,
      );
    });

    testWidgets('容器身份：遇到另一个滚动节点即停，外层锚点不落到内层头上', (WidgetTester tester) async {
      await _withOwner(
        tester,
        RevealNestedSyntheticScroll(
          outerLog: RevealSyntheticLog(),
          innerLog: RevealSyntheticLog(),
        ),
        (SemanticsOwner owner) async {
          final SemanticsNode root = owner.rootSemanticsNode!;
          final SemanticsNode innerAnchor = revealNodeWith(
            root,
            revealNestedContainerId,
          );
          final SemanticsNode innerScroll = patchbaySemanticsScrollNodesIn(
            innerAnchor,
          ).single;

          expect(
            patchbayRevealContainerIdentity(
              innerScroll,
              innerScroll.getSemanticsData(),
            ),
            revealNestedContainerId,
            reason: '内层容器拿的是内层锚点，不是外层的 reveal.list',
          );

          // 外层滚动节点本身也没有 identifier，沿 parent 找到的是外层锚点。
          final SemanticsNode outerAnchor = revealNodeWith(
            root,
            revealContainerId,
          );
          final SemanticsNode outerScroll = patchbaySemanticsScrollNodesIn(
            outerAnchor,
          ).first;
          expect(
            patchbayRevealContainerIdentity(
              outerScroll,
              outerScroll.getSemanticsData(),
            ),
            revealContainerId,
          );
        },
      );
    });
  });

  group('阶段：一层容器的状态机', () {
    PatchbayRevealLayer layerFor(PatchbayRevealDirection requested) =>
        PatchbayRevealLayer(
          anchorIdentifier: null,
          nodeId: 1,
          generation: 1,
          decision: _allow,
          axis: PatchbayRevealAxis.vertical,
          requested: requested,
        );

    test('停滞未到阈值不算耗尽', () {
      final PatchbayRevealLayer layer = layerFor(
        PatchbayRevealDirection.forward,
      );
      for (var step = 1; step < PatchbayRevealBudget.stallSteps; step += 1) {
        expect(layer.noteStallExhausted(), isFalse);
        expect(layer.stall, step);
      }
    });

    test('到阈值且无处可换向 ⇒ 耗尽', () {
      final PatchbayRevealLayer layer = layerFor(
        PatchbayRevealDirection.forward,
      );
      for (var step = 1; step < PatchbayRevealBudget.stallSteps; step += 1) {
        layer.noteStallExhausted();
      }
      expect(layer.noteStallExhausted(), isTrue);
    });

    testWidgets('到阈值且 both 还有没走过的同轴 action ⇒ 换向、stall 归零、不算耗尽', (
      WidgetTester tester,
    ) async {
      final SemanticsData data = await _probeData(
        tester,
        const RevealAxisProbe(
          up: true,
          down: true,
          position: 300,
          min: 0,
          max: 600,
        ),
      );
      final PatchbayRevealLayer layer = layerFor(PatchbayRevealDirection.both);

      final PatchbaySemanticsAction first = layer.actionFor(data)!;
      layer.learnPolarity(first, 0);
      for (var step = 1; step < PatchbayRevealBudget.stallSteps; step += 1) {
        expect(layer.noteStallExhausted(), isFalse);
      }
      expect(layer.noteStallExhausted(), isFalse, reason: '换向成功即未耗尽');
      expect(layer.stall, 0);
      expect(layer.actionFor(data), isNot(first));

      // 两个方向都走过之后再停滞，才真的耗尽。
      layer.learnPolarity(layer.actionFor(data)!, 0);
      for (var step = 1; step < PatchbayRevealBudget.stallSteps; step += 1) {
        expect(layer.noteStallExhausted(), isFalse);
      }
      expect(layer.noteStallExhausted(), isTrue);
    });

    testWidgets('显式方向 + 极性未知 ⇒ 每容器至多一次探测步', (WidgetTester tester) async {
      final SemanticsData data = await _probeData(
        tester,
        const RevealAxisProbe(
          up: true,
          down: true,
          position: 300,
          min: 0,
          max: 600,
        ),
      );
      final PatchbayRevealLayer layer = layerFor(
        PatchbayRevealDirection.forward,
      );

      final PatchbaySemanticsAction probe = layer.actionFor(data)!;
      // 探测步走了却没有位移：极性仍未知，不许再花第二个探测步。
      layer.learnPolarity(probe, 0);
      layer.actionFor(data);
      expect(
        layer.labelFor(probe),
        PatchbayRevealDirection.forward,
        reason: '极性未知时标签退回请求方向',
      );

      final PatchbayRevealLayer second = layerFor(
        PatchbayRevealDirection.forward,
      );
      final PatchbaySemanticsAction reversed = second.actionFor(data)!;
      // 探测步走反了：位移为负 ⇒ 另一个才是 forward，映射当场翻转。
      second.learnPolarity(reversed, -1);
      expect(second.actionFor(data), isNot(reversed));
      expect(second.labelFor(reversed), PatchbayRevealDirection.backward);
    });

    testWidgets('请求方向上的 action 不再暴露 ⇒ 这一步无从派发', (WidgetTester tester) async {
      final SemanticsData atMax = await _probeData(
        tester,
        const RevealAxisProbe(up: true, position: 600, min: 0, max: 600),
      );
      final PatchbayRevealLayer layer = layerFor(
        PatchbayRevealDirection.forward,
      );

      expect(layer.actionFor(atMax), isNull);
    });
  });

  group('阶段：现场读取与目标观察', () {
    testWidgets('目标零匹配 ⇒ absent；多匹配 ⇒ ambiguous（不按树顺序选）', (
      WidgetTester tester,
    ) async {
      await _withOwner(
        tester,
        revealStackedRows(<Widget>[
          revealBoundaryRow(revealTargetId),
          revealBoundaryRow(revealTargetId),
        ]),
        (SemanticsOwner owner) async {
          final PatchbayRevealTargetView ambiguous = patchbayRevealReadTarget(
            owner: owner,
            identifier: revealTargetId,
          );
          expect(ambiguous.ambiguous, isTrue);
          expect(ambiguous.node, isNull);

          final PatchbayRevealTargetView absent = patchbayRevealReadTarget(
            owner: owner,
            identifier: 'reveal.nobody',
          );
          expect(absent.ambiguous, isFalse);
          expect(absent.node, isNull);
        },
      );
    });

    testWidgets('owner 没有语义根 ⇒ 三个读取一律降级，不抛', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        RevealCallLog(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );
      // 一个还没接上任何树的 owner：`rootSemanticsNode` 恒为 null。这一格在端到端
      // 路径上要等语义树被连根拔起才碰得到，拆分之后可以直接构造。
      final SemanticsOwner detached = SemanticsOwner(
        onSemanticsUpdate: (SemanticsUpdate _) {},
      );
      addTearDown(detached.dispose);
      expect(detached.rootSemanticsNode, isNull, reason: '前置条件');

      expect(
        patchbayRevealReadTarget(
          owner: detached,
          identifier: revealTargetId,
        ).node,
        isNull,
      );
      expect(
        patchbayRevealReadTarget(
          owner: detached,
          identifier: revealTargetId,
        ).ambiguous,
        isFalse,
        reason: '「读不到」不得伪装成「多匹配」',
      );
      expect(
        patchbayRevealResolveLayerNode(
          owner: detached,
          semantics: bridge.semantics,
          anchorIdentifier: null,
          nodeId: 1,
          generation: 1,
        ),
        isNull,
      );
      expect(
        patchbayRevealResolveLayerNode(
          owner: detached,
          semantics: bridge.semantics,
          anchorIdentifier: revealContainerId,
          nodeId: 1,
          generation: 1,
        ),
        isNull,
      );
      final PatchbayRevealProgress progress = patchbayRevealObserveProgress(
        owner: detached,
        nodeId: 1,
        beforePosition: 0,
        beforeExtentMax: 0,
      );
      expect(progress.moved, isFalse);
      expect(progress.grew, isFalse);
      expect(
        patchbayRevealNextContainer(
          owner: detached,
          readTarget: () => const PatchbayRevealTargetView.absent(),
          currentNodeId: 1,
          visitedNodeIds: const <int>{},
          direction: PatchbayRevealDirection.forward,
        ),
        isNull,
      );
    });

    testWidgets('容器重解析：nodeId 不存在、generation 不符、锚点内不唯一都判 null', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        RevealCallLog(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );
      final SemanticsOwner owner = (await pumpReveal(
        tester,
        bridge.semantics.ensureOwner(),
      ))!;
      final SemanticsNode scroll = patchbayRevealScrollNodeUnder(
        owner.rootSemanticsNode!,
        revealContainerId,
      )!;
      final int generation = bridge.semantics.observe(scroll).generation;

      expect(
        patchbayRevealResolveLayerNode(
          owner: owner,
          semantics: bridge.semantics,
          anchorIdentifier: null,
          nodeId: scroll.id,
          generation: generation,
        ),
        same(scroll),
        reason: '对照组：pin 完全对得上才解析成功',
      );
      expect(
        patchbayRevealResolveLayerNode(
          owner: owner,
          semantics: bridge.semantics,
          anchorIdentifier: null,
          nodeId: scroll.id,
          generation: generation + 1,
        ),
        isNull,
        reason: '换代即不是被授权的那块区域',
      );
      expect(
        patchbayRevealResolveLayerNode(
          owner: owner,
          semantics: bridge.semantics,
          anchorIdentifier: null,
          nodeId: -1,
          generation: generation,
        ),
        isNull,
      );
      expect(
        patchbayRevealResolveLayerNode(
          owner: owner,
          semantics: bridge.semantics,
          anchorIdentifier: 'reveal.missing',
          nodeId: scroll.id,
          generation: generation,
        ),
        isNull,
        reason: '锚点解析不出唯一滚动节点',
      );
      bridge.semantics.dispose();
    });

    testWidgets('进展观察：before 缺失或非有限位移一律归零，extent 增长单独成立', (
      WidgetTester tester,
    ) async {
      await _withOwner(
        tester,
        const RevealAxisProbe(down: true, position: 300, min: 0, max: 600),
        (SemanticsOwner owner) async {
          final SemanticsNode node = revealNodeWith(
            owner.rootSemanticsNode!,
            revealContainerId,
          );

          expect(
            patchbayRevealObserveProgress(
              owner: owner,
              nodeId: node.id,
              beforePosition: null,
              beforeExtentMax: 600,
            ).delta,
            0,
            reason: 'before 缺失时不得把 after 当成位移',
          );
          expect(
            patchbayRevealObserveProgress(
              owner: owner,
              nodeId: node.id,
              beforePosition: double.nan,
              beforeExtentMax: 600,
            ).moved,
            isFalse,
            reason: 'NaN 不是「走了很远」',
          );
          final PatchbayRevealProgress grew = patchbayRevealObserveProgress(
            owner: owner,
            nodeId: node.id,
            beforePosition: 300,
            beforeExtentMax: 100,
          );
          expect(grew.moved, isFalse);
          expect(grew.grew, isTrue, reason: '位置没动、内容变多也算有效步');
        },
      );
    });
  });

  group('阶段：重评、派发与记账', () {
    test('决策逐项比对：任一项不同即判改判', () {
      expect(patchbayRevealSameDecision(_allow, _allow), isTrue);
      expect(
        patchbayRevealSameDecision(
          _allow,
          const PatchbayRevealDecision.allow(
            maxSteps: 199,
            maxDurationMs: 120000,
          ),
        ),
        isFalse,
      );
      expect(
        patchbayRevealSameDecision(
          _allow,
          const PatchbayRevealDecision.allow(
            maxSteps: 200,
            maxDurationMs: 119999,
          ),
        ),
        isFalse,
      );
      expect(
        patchbayRevealSameDecision(
          _allow,
          const PatchbayRevealDecision.allow(
            gateIds: <String>{'g'},
            maxSteps: 200,
            maxDurationMs: 120000,
          ),
        ),
        isFalse,
      );
      expect(
        patchbayRevealSameDecision(
          _allow,
          const PatchbayRevealDecision.reject(),
        ),
        isFalse,
      );
      expect(
        patchbayRevealSameDecision(
          const PatchbayRevealDecision.allow(gateIds: <String>{'a', 'b'}),
          const PatchbayRevealDecision.allow(gateIds: <String>{'b', 'a'}),
        ),
        isTrue,
        reason: 'gateIds 是集合，顺序不构成改判',
      );
    });

    test('deadline 已过 ⇒ 立刻超时，连 await 都不做', () async {
      final Completer<int> never = Completer<int>();
      final PatchbayRevealTimed<int> timed = await patchbayRevealBeforeDeadline(
        never.future,
        DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(timed.completed, isFalse);
      expect(timed.value, isNull);
      expect(never.isCompleted, isFalse);
    });

    test('future 慢于 deadline ⇒ 超时；「超时」与「完成但值为 null」不折叠', () async {
      final PatchbayRevealTimed<int?> slow = await patchbayRevealBeforeDeadline(
        Completer<int?>().future,
        DateTime.now().add(const Duration(milliseconds: 20)),
      );
      expect(slow.completed, isFalse);

      final PatchbayRevealTimed<int?> nullish =
          await patchbayRevealBeforeDeadline(
            Future<int?>.value(),
            DateTime.now().add(const Duration(seconds: 5)),
          );
      expect(nullish.completed, isTrue);
      expect(nullish.value, isNull);
    });

    testWidgets('performAction 抛出 ⇒ 只回报 runtimeType，不带 message/stack', (
      WidgetTester tester,
    ) async {
      final RevealSyntheticLog log = RevealSyntheticLog();
      await _withOwner(
        tester,
        RevealSyntheticScroll(log: log, throwFromDispatch: 1),
        (SemanticsOwner owner) async {
          final SemanticsNode scroll = patchbayRevealScrollNodeUnder(
            owner.rootSemanticsNode!,
            revealContainerId,
          )!;

          final String? failure = patchbayRevealDispatchScroll(
            owner: owner,
            nodeId: scroll.id,
            action: PatchbaySemanticsAction.scrollDown,
          );

          expect(failure, 'StateError');
          expect(log.dispatches, 1, reason: '抛出之前确实派发过一次');
        },
      );
    });

    testWidgets('派发成功 ⇒ 返回 null（对照组，证明上一条不是恒真）', (WidgetTester tester) async {
      final RevealSyntheticLog log = RevealSyntheticLog();
      await _withOwner(tester, RevealSyntheticScroll(log: log), (
        SemanticsOwner owner,
      ) async {
        final SemanticsNode scroll = patchbayRevealScrollNodeUnder(
          owner.rootSemanticsNode!,
          revealContainerId,
        )!;

        expect(
          patchbayRevealDispatchScroll(
            owner: owner,
            nodeId: scroll.id,
            action: PatchbaySemanticsAction.scrollDown,
          ),
          isNull,
        );
        expect(log.dispatches, 1);
      });
    });

    test('记账：首次派发追加记录，之后只累加；containers 保持派发顺序', () {
      final List<PatchbayRevealContainerRecord> containers =
          <PatchbayRevealContainerRecord>[];
      PatchbayRevealLayer layerAt(int nodeId) => PatchbayRevealLayer(
        anchorIdentifier: null,
        nodeId: nodeId,
        generation: 7,
        decision: _allow,
        axis: PatchbayRevealAxis.vertical,
        requested: PatchbayRevealDirection.forward,
      );

      final PatchbayRevealLayer inner = layerAt(11);
      patchbayRevealRecordDispatch(layer: inner, containers: containers);
      patchbayRevealRecordDispatch(layer: inner, containers: containers);
      final PatchbayRevealLayer outer = layerAt(22);
      patchbayRevealRecordDispatch(layer: outer, containers: containers);

      expect(
        containers.map((PatchbayRevealContainerRecord r) => r.nodeId),
        <int>[11, 22],
        reason: '由内向外，且同一容器不重复追加',
      );
      expect(containers.first.steps, 2);
      expect(containers.last.steps, 1);
      expect(
        containers.every((PatchbayRevealContainerRecord r) => r.steps >= 1),
        isTrue,
        reason: 'containers.isEmpty <=> steps == 0 的另一半',
      );
    });
  });

  group('阶段：升层判定', () {
    test('host 硬顶：越界的 decision 整体非法，而不是被夹到硬顶', () {
      expect(patchbayRevealWithinHostCaps(_allow), isTrue);
      expect(
        patchbayRevealWithinHostCaps(
          const PatchbayRevealDecision.allow(maxSteps: 0),
        ),
        isFalse,
      );
      expect(
        patchbayRevealWithinHostCaps(
          PatchbayRevealDecision.allow(
            maxSteps: PatchbayRevealBudget.maxSteps + 1,
          ),
        ),
        isFalse,
      );
      expect(
        patchbayRevealWithinHostCaps(
          const PatchbayRevealDecision.allow(maxDurationMs: 0),
        ),
        isFalse,
      );
      expect(
        patchbayRevealWithinHostCaps(
          PatchbayRevealDecision.allow(
            maxDurationMs: PatchbayRevealBudget.maxDurationMs + 1,
          ),
        ),
        isFalse,
      );
    });

    testWidgets('候选筛选：已访问的跳过，请求方向上不可驱动的也跳过', (WidgetTester tester) async {
      await _withOwner(
        tester,
        RevealNestedSyntheticScroll(
          outerLog: RevealSyntheticLog(),
          innerLog: RevealSyntheticLog(),
        ),
        (SemanticsOwner owner) async {
          final SemanticsNode root = owner.rootSemanticsNode!;
          final SemanticsNode inner = patchbayRevealScrollNodeUnder(
            root,
            revealNestedContainerId,
          )!;
          final SemanticsNode outer = patchbaySemanticsScrollNodesIn(
            revealNodeWith(root, revealContainerId),
          ).first;

          PatchbayRevealTargetView absent() =>
              const PatchbayRevealTargetView.absent();

          expect(
            patchbayRevealNextContainer(
              owner: owner,
              readTarget: absent,
              currentNodeId: inner.id,
              visitedNodeIds: <int>{inner.id},
              direction: PatchbayRevealDirection.forward,
            ),
            same(outer),
            reason: '对照组：外层是唯一没访问过的可驱动祖先',
          );
          expect(
            patchbayRevealNextContainer(
              owner: owner,
              readTarget: absent,
              currentNodeId: inner.id,
              visitedNodeIds: <int>{inner.id, outer.id},
              direction: PatchbayRevealDirection.forward,
            ),
            isNull,
            reason: '已访问的容器不再构成候选',
          );
          expect(
            patchbayRevealNextContainer(
              owner: owner,
              readTarget: absent,
              currentNodeId: inner.id,
              visitedNodeIds: <int>{inner.id},
              direction: PatchbayRevealDirection.backward,
            ),
            isNull,
            reason: '外层停在 min 处，backward 上不可驱动 ⇒ 跳过',
          );
          expect(
            patchbayRevealNextContainer(
              owner: owner,
              readTarget: absent,
              currentNodeId: -1,
              visitedNodeIds: const <int>{},
              direction: PatchbayRevealDirection.forward,
            ),
            isNull,
            reason: '当前层解析不出来且目标未挂载 ⇒ 没有链可走',
          );
        },
      );
    });

    testWidgets('目标挂载后以目标祖先链为权威', (WidgetTester tester) async {
      final RevealSyntheticLog outerLog = RevealSyntheticLog();
      await _withOwner(
        tester,
        RevealNestedSyntheticScroll(
          outerLog: outerLog..dispatches = 1,
          innerLog: RevealSyntheticLog(),
          revealAtOuterDispatch: 1,
        ),
        (SemanticsOwner owner) async {
          final SemanticsNode root = owner.rootSemanticsNode!;
          final SemanticsNode inner = patchbayRevealScrollNodeUnder(
            root,
            revealNestedContainerId,
          )!;
          final SemanticsNode outer = patchbaySemanticsScrollNodesIn(
            revealNodeWith(root, revealContainerId),
          ).first;
          final SemanticsNode target = revealNodeWith(root, revealTargetId);

          expect(
            patchbayRevealNextContainer(
              owner: owner,
              readTarget: () => PatchbayRevealTargetView.mounted(target),
              currentNodeId: inner.id,
              visitedNodeIds: <int>{inner.id},
              direction: PatchbayRevealDirection.forward,
            ),
            same(outer),
            reason: '目标的祖先链上只有外层，内层根本不在链上',
          );

          // 早停判定：内层不在目标祖先链上，外层在。
          expect(
            patchbayRevealLayerOffTargetChain(
              owner: owner,
              mounted: target,
              layerNodeId: inner.id,
            ),
            isTrue,
          );
          expect(
            patchbayRevealLayerOffTargetChain(
              owner: owner,
              mounted: target,
              layerNodeId: outer.id,
            ),
            isFalse,
          );
          expect(
            patchbayRevealLayerOffTargetChain(
              owner: owner,
              mounted: target,
              layerNodeId: -1,
            ),
            isFalse,
            reason: '解析不出当前层是「无从判断」，不是「不在链上」',
          );
        },
      );
    });
  });

  group('阶段：终态投影', () {
    testWidgets('目标未挂载 ⇒ nodeId 与 generation 一律不出现', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        RevealCallLog(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );
      final SemanticsOwner owner = (await pumpReveal(
        tester,
        bridge.semantics.ensureOwner(),
      ))!;
      final SemanticsNode container = patchbayRevealScrollNodeUnder(
        owner.rootSemanticsNode!,
        revealContainerId,
      )!;

      final PatchbayRevealOutcome absent = patchbayRevealFailedOutcome(
        PatchbayRevealReason.scrollExhausted,
        node: null,
        semantics: bridge.semantics,
      );
      expect(absent.revealed, isFalse);
      expect(absent.reason, PatchbayRevealReason.scrollExhausted);
      expect(absent.nodeId, isNull);
      expect(absent.generation, isNull);
      expect(absent.reachability, isNull);

      final PatchbayRevealOutcome mounted = patchbayRevealFailedOutcome(
        PatchbayRevealReason.gateRejected,
        node: container,
        semantics: bridge.semantics,
        gateId: 'patchbay.base',
        gateCode: 'appBusy',
      );
      expect(mounted.nodeId, container.id);
      expect(
        mounted.generation,
        bridge.semantics.observe(container).generation,
      );
      expect(mounted.gateId, 'patchbay.base');
      expect(mounted.gateCode, 'appBusy');
      expect(mounted.failureType, isNull);
      bridge.semantics.dispose();
    });

    testWidgets('failureType 透传且不携带 message/stack', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        RevealCallLog(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );
      await pumpReveal(tester, bridge.semantics.ensureOwner());

      final PatchbayRevealOutcome outcome = patchbayRevealFailedOutcome(
        PatchbayRevealReason.scrollActionFailed,
        node: null,
        semantics: bridge.semantics,
        failureType: StateError(
          'secret business detail',
        ).runtimeType.toString(),
      );

      expect(outcome.failureType, 'StateError');
      expect(outcome.failureType, isNot(contains('secret')));
      bridge.semantics.dispose();
    });
  });
}
