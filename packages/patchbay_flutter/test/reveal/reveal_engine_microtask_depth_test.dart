// PB-050-38：reveal 步循环的**让步结构**探针。
//
// 拆分不得改变一次 reveal 在完成前让出多少个微任务。这不是性能洁癖：每一个让步
// 窗口都是别的代码能插进来的地方，而 reveal 的授权模型正建立在「哪些事之间没有
// 窗口」上——`reveal_engine.dart` 的注释把它写成硬约束：「门与 performAction 之
// 间没有任何 await/yield，用同一次解析得到的 owner / nodeId」。多一个窗口，被
// 授权的那块区域就可能在门放行之后、派发之前换掉。
//
// 三种量法，都在拆分前的实现上实测得到，拆分只需复现同一组数：
//
// 1. **无帧路径的微任务深度**：整条调用在完成前让出了几轮。`await null` 恰好让出
//    一轮，因此这是一个相对但完全确定的整数（与 core 侧
//    `host_invoker_microtask_depth_test.dart` 同一手法）。只有不等帧的路径能这么
//    量——`PatchbayFrameObserver` 是 `final class`，测试没法替换掉帧等待，
//    帧驱动路径的 `await` 必须靠 `tester.pump()` 才会推进。
// 2. **门放行到派发之间的让步轮次**：把门做成手工 completer，放行之后数到假容器
//    的 `performAction` 落地为止。这条直接守住上面那句硬约束，且对每一步都成立。
// 3. **policy 与门之间没有微任务边界**：policy 回调里排一个微任务，门回调里检查
//    它有没有跑过。跑过就说明两次求值之间被切开了。
//
// 帧驱动路径（单步成功 / 升层一次 / 预算耗尽）另以**引擎自己观察到的帧数**加上
// policy / 门调用次数钉住，见 `reveal_engine_characterization_test.dart`：那三个
// 数一起变化才可能掩盖一次多余的等待。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import 'reveal_engine_fixtures.dart';
import 'reveal_fixtures.dart';

/// 数出 [pending] 在完成前让出了多少个微任务轮次。
///
/// 上界只用来防止判据写错时死循环；它不参与断言。
Future<int> revealMicrotaskDepth(
  Future<PatchbayInvocation> pending, {
  int bound = 64,
}) async {
  var settled = false;
  unawaited(pending.then<void>((PatchbayInvocation _) => settled = true));
  var depth = 0;
  while (!settled && depth < bound) {
    depth += 1;
    await null;
  }
  await pending;
  return depth;
}

void main() {
  setUp(resetRevealCounters);

  group('无帧路径的微任务深度', () {
    testWidgets('revealedAtStepZero：不进循环，只让出准入门那一段', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 0)),
      );

      expect(
        await revealMicrotaskDepth(
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
        2,
      );
      bridge.semantics.dispose();
    });

    testWidgets('policyChangedAtFirstStep：第 1 步的 policy 改判，门不再被问', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final RevealSyntheticLog synthetic = RevealSyntheticLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        override: (int call) => call >= 3
            ? const PatchbayRevealDecision.allow(
                maxSteps: 199,
                maxDurationMs: 120000,
              )
            : null,
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(RevealSyntheticScroll(log: synthetic)));

      expect(
        await revealMicrotaskDepth(
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
        3,
      );
      expect(synthetic.dispatches, 0, reason: '一步都没派发');
      bridge.semantics.dispose();
    });

    testWidgets('gateRejectedAtFirstStep：多走一次门的 await', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final RevealSyntheticLog synthetic = RevealSyntheticLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        decide: (int call) => call >= 2
            ? const PatchbayGateDecision.reject(code: 'appBusy')
            : const PatchbayGateDecision.allow(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(RevealSyntheticScroll(log: synthetic)));

      expect(
        await revealMicrotaskDepth(
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
        3,
      );
      expect(synthetic.dispatches, 0);
      bridge.semantics.dispose();
    });

    testWidgets('lifecycleNotResumedAtFirstStep：生命周期闸在容器重解析之前', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final RevealSyntheticLog synthetic = RevealSyntheticLog();
      var resumed = true;
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        // 第 2 次 policy 是 bridge 在门后的复核，排在 bridge 自己的生命周期闸
        // 之后：此刻翻掉 resumed，第 1 步才会撞在引擎的那道闸上。
        override: (int call) {
          if (call == 2) resumed = false;
          return null;
        },
        isAppResumed: () => resumed,
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(RevealSyntheticScroll(log: synthetic)));

      expect(
        await revealMicrotaskDepth(
          bridge.reveal.reveal(
            identifier: revealTargetId,
            direction: PatchbayRevealDirection.forward,
            maxSteps: 40,
            timeoutMs: 60000,
          ),
        ),
        3,
      );
      expect(synthetic.dispatches, 0);
      bridge.semantics.dispose();
    });
  });

  group('步内让步点', () {
    testWidgets('门放行到 performAction 之间恰好一轮微任务，逐步成立', (
      WidgetTester tester,
    ) async {
      final List<Completer<PatchbayGateDecision>> gates =
          <Completer<PatchbayGateDecision>>[];
      final RevealSyntheticLog synthetic = RevealSyntheticLog();
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () {
            final Completer<PatchbayGateDecision> pending =
                Completer<PatchbayGateDecision>();
            gates.add(pending);
            return pending.future;
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
        revealPolicy: (_, _) => const PatchbayRevealDecision.allow(
          maxSteps: 200,
          maxDurationMs: 120000,
        ),
        isAppResumed: () => true,
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(RevealSyntheticScroll(log: synthetic)));

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 3,
        timeoutMs: 60000,
      );

      Future<void> awaitGate(int count) async {
        for (var attempt = 0; attempt < 64 && gates.length < count; attempt++) {
          await null;
        }
        expect(gates.length, greaterThanOrEqualTo(count));
      }

      // #1 是准入门，放行之后引擎才进第 1 步。
      await awaitGate(1);
      gates[0].complete(const PatchbayGateDecision.allow());

      for (final int step in <int>[1, 2]) {
        await awaitGate(step + 1);
        final int before = synthetic.dispatches;
        gates[step].complete(const PatchbayGateDecision.allow());
        var depth = 0;
        while (synthetic.dispatches == before && depth < 64) {
          depth += 1;
          await null;
        }
        expect(
          depth,
          1,
          reason:
              '第 $step 步：门放行与 performAction 之间只有 `_beforeDeadline` '
              '那一次 await，不得再多一个窗口',
        );
        // 派发之后引擎要等一帧，下一步的门才会出现。
        for (
          var attempt = 0;
          attempt < 40 && gates.length < step + 2;
          attempt++
        ) {
          await tester.pump();
        }
      }

      for (final Completer<PatchbayGateDecision> gate in gates) {
        if (!gate.isCompleted) {
          gate.complete(const PatchbayGateDecision.allow());
        }
      }
      await pumpReveal(tester, pending);
      bridge.semantics.dispose();
    });

    testWidgets('policy 与门之间没有微任务边界', (WidgetTester tester) async {
      final RevealSyntheticLog synthetic = RevealSyntheticLog();
      var crossedSincePolicy = false;
      final List<bool> observedAtGate = <bool>[];
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () {
            observedAtGate.add(crossedSincePolicy);
            return const PatchbayGateDecision.allow();
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
        revealPolicy: (_, _) {
          crossedSincePolicy = false;
          scheduleMicrotask(() => crossedSincePolicy = true);
          return const PatchbayRevealDecision.allow(
            maxSteps: 200,
            maxDurationMs: 120000,
          );
        },
        isAppResumed: () => true,
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(revealApp(RevealSyntheticScroll(log: synthetic)));

      await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(
          identifier: revealTargetId,
          direction: PatchbayRevealDirection.forward,
          maxSteps: 3,
          timeoutMs: 60000,
        ),
      );

      // 准入门 + 三步的门；每一次都发生在最近一次 policy 之后、且中间没有让步。
      expect(observedAtGate, <bool>[false, false, false, false]);
    });
  });
}
