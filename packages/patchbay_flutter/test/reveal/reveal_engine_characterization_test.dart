// PB-050-38：`reveal_engine.dart` 按步循环阶段拆分前的**表征网格**。
//
// 表征测试与契约测试的分工：`reveal_matrix_test.dart` / `reveal_policy_test.dart`
// / `reveal_race_test.dart` 已经逐条锁住「什么情况下应该是哪个 reason」，那是
// 契约；本文件不重复它们，只补拆分真正需要的三件事——
//
// 1. **终态 payload 逐字节**（`jsonEncode`，含 `containers[]` 元素的键序）。既有
//    用例断言的是单个字段，字段的**顺序**与「哪些字段不出现」没有被机器盯住，
//    而那恰恰是重排组装代码最容易碰坏的地方。
// 2. **每步的 policy 与门调用次数**。DG-060-04 冻结了「reveal 每一步仍重新取得
//    现场并重评动态 policy/gate，不缓存、不租约化」；调用次数因此是外部可观测
//    语义，把重评提到循环外或多问一次都必须判红。
// 3. **容器记录的条数与顺序**，以及升层在第几步发生。
//
// 网格用 `reveal_engine_fixtures.dart` 的同步假滚动容器，因此每一条 `steps`、
// 帧数与调用次数都是确定整数而不是动画时序的函数：真实 `Scrollable` 的语义滚动
// 是带时长的动画，用它做表征只能把一半数字打成占位符。真实 `ListView` 的那一半
// 覆盖仍由既有四个文件负责。
//
// 覆盖：`PatchbayRevealReason.values` 全部 13 个 reason + 三条 revealed 路径
// （0 步短路、单步、升层后）。穷尽性由末尾一条用例机检。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/reveal/reveal_models.dart';

import 'reveal_engine_fixtures.dart';
import 'reveal_fixtures.dart';

/// 观测到的 reason，末尾据此机检封闭词表被走遍。
final Set<String> _covered = <String>{};

const PatchbayRevealDecision _wide = PatchbayRevealDecision.allow(
  maxSteps: 200,
  maxDurationMs: 120000,
);

/// `containers[]` 元素的逐字节形状——键序在这里钉一次，各用例复用。
String _container(int steps, {String direction = 'forward', int growth = 0}) =>
    '{"nodeId":"<volatile>","generation":"<volatile>","steps":$steps,'
    '"direction":"$direction","extentGrowthSteps":$growth}';

/// `outcome: revealed` 的逐字节形状。
String _revealed({
  required int steps,
  required List<String> containers,
  String reachability = 'pointer',
}) =>
    '{"outcome":"revealed","source":"uiObserved","identifier":"reveal.target",'
    '"steps":$steps,"elapsedMs":"<volatile>","containers":[${containers.join(',')}],'
    '"nodeId":"<volatile>","generation":"<volatile>",'
    '"reachability":"$reachability","beforeTreeRevision":"<volatile>",'
    '"afterTreeRevision":"<volatile>"}';

/// `outcome: failed` 的逐字节形状。
///
/// [mountedTarget] 决定 `nodeId` / `generation` 出不出现——终止时目标已挂载才带，
/// 未挂载就不带，这条「不出现」本身是契约。[tail] 是 reason 之后的附加字段。
String _failed(
  String reason, {
  required int steps,
  required List<String> containers,
  bool mountedTarget = false,
  String tail = '',
}) {
  _covered.add(reason);
  return '{"outcome":"failed","source":"uiObserved","identifier":"reveal.target",'
      '"steps":$steps,"elapsedMs":"<volatile>",'
      '"containers":[${containers.join(',')}],'
      '${mountedTarget ? '"nodeId":"<volatile>","generation":"<volatile>",' : ''}'
      '"beforeTreeRevision":"<volatile>","afterTreeRevision":"<volatile>",'
      '"reason":"$reason"$tail}';
}

Future<RevealRun> _drive(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
  RevealCallLog log,
  Widget tree, {
  String? container,
  int maxSteps = 40,
  int timeoutMs = 60000,
}) async {
  await tester.pumpWidget(revealApp(tree));
  final int before = bridge.frameRevision;
  final PatchbayInvocation result = await runReveal(
    tester,
    bridge,
    bridge.reveal.reveal(
      identifier: revealTargetId,
      container: container,
      direction: PatchbayRevealDirection.forward,
      maxSteps: maxSteps,
      timeoutMs: timeoutMs,
    ),
  );
  return RevealRun(
    result: result,
    frames: bridge.frameRevision - before,
    log: log,
  );
}

void main() {
  setUp(resetRevealCounters);

  group('终态 payload 逐字节', () {
    testWidgets('revealed：进入循环前已露出 ⇒ 0 步、containers 空', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 0)),
      );
      final int frames = bridge.frameRevision;
      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
      );

      expect(
        pinnedRevealPayload(revealPayload(result)),
        _revealed(steps: 0, containers: const <String>[]),
      );
      expect(bridge.frameRevision - frames, 0, reason: '0 步不观察任何帧');
      // 准入一次 + 门后复核一次；引擎的步间重评一次都没发生。
      expect(log.policyContainers, <String>[
        revealContainerId,
        revealContainerId,
      ]);
      expect(log.gateCalls, 1);
      expectRevealInvariants(revealPayload(result));
    });

    testWidgets('revealed：单步露出 ⇒ containers 恰好一个、steps 1', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog(), revealAtDispatch: 1),
      );

      expect(
        run.pinned,
        _revealed(steps: 1, containers: <String>[_container(1)]),
      );
      expect(run.frames, 1, reason: '一步观察一帧');
      expect(run.log.policyCalls, 3, reason: '准入 + 门后复核 + 第 1 步重评');
      expect(run.log.gateCalls, 2, reason: '准入门 + 第 1 步的门');
      expectRevealInvariants(revealPayload(run.result));
    });

    testWidgets('revealed：升层一次后露出 ⇒ containers 由内向外两个', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        byContainer: const <String, PatchbayRevealDecision>{
          revealContainerId: _wide,
        },
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealNestedSyntheticScroll(
          outerLog: RevealSyntheticLog(),
          innerLog: RevealSyntheticLog(),
        ),
        container: revealNestedContainerId,
        maxSteps: 60,
      );

      expect(
        run.pinned,
        _revealed(steps: 3, containers: <String>[_container(2), _container(1)]),
      );
      // 内层停滞两步（stallSteps）后升层，外层一步就把目标推出来。
      expect(run.frames, 3);
      expect(run.log.policyContainers, <String>[
        revealNestedContainerId,
        revealNestedContainerId,
        revealNestedContainerId,
        revealNestedContainerId,
        revealContainerId,
        revealContainerId,
      ], reason: '升层是一次全新授权：外层被独立问过 policy');
      expect(run.log.gateCalls, 5);
      expectRevealInvariants(revealPayload(run.result));
    });

    testWidgets('stepBudgetExceeded：steps 恰好等于预算', (WidgetTester tester) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog()),
        maxSteps: 2,
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.stepBudgetExceeded,
          steps: 2,
          containers: <String>[_container(2)],
        ),
      );
      expect(run.frames, 2);
      expect(run.log.policyCalls, 4);
      expect(run.log.gateCalls, 3);
    });

    testWidgets('scrollExhausted：停滞到阈值、无处可升 ⇒ 不带 nodeId', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog(), stall: true),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.scrollExhausted,
          steps: PatchbayRevealBudget.stallSteps,
          containers: <String>[_container(PatchbayRevealBudget.stallSteps)],
        ),
      );
      expect(run.log.gateCalls, 3);
    });

    testWidgets('scrollActionFailed：details 只写 runtimeType', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog(), throwFromDispatch: 2),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.scrollActionFailed,
          steps: 1,
          containers: <String>[_container(1)],
          tail: ',"failureType":"StateError"',
        ),
      );
      // 抛出的那一步不计入 steps：`steps += 1` 排在 performAction 成功之后。
      expect(run.log.gateCalls, 3);
    });

    testWidgets('targetBlocked：目标已挂载 ⇒ 带 nodeId/generation', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog(), blockedAtDispatch: 1),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.targetBlocked,
          steps: 1,
          containers: <String>[_container(1)],
          mountedTarget: true,
        ),
      );
    });

    testWidgets('targetAmbiguous：多个挂载实例 ⇒ 不带 nodeId', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(
          log: RevealSyntheticLog(),
          ambiguousAtDispatch: 1,
        ),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.targetAmbiguous,
          steps: 1,
          containers: <String>[_container(1)],
        ),
      );
    });

    testWidgets('targetObscured：目标露面却被盖住且无处可升', (WidgetTester tester) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(
          log: RevealSyntheticLog(),
          revealAtDispatch: 1,
          stall: true,
          overlay: true,
        ),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.targetObscured,
          steps: PatchbayRevealBudget.stallSteps,
          containers: <String>[_container(PatchbayRevealBudget.stallSteps)],
          mountedTarget: true,
        ),
      );
    });

    testWidgets('containerChanged：按 pin 重解析落空', (WidgetTester tester) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(log);
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(
          log: RevealSyntheticLog(),
          disappearAtDispatch: 1,
        ),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.containerChanged,
          steps: 1,
          containers: <String>[_container(1)],
        ),
      );
      // 换代在门之前判定：第 2 步的门根本没被问到。
      expect(run.log.gateCalls, 2);
    });

    testWidgets('policyChanged：步间决策漂移', (WidgetTester tester) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        override: (int call) => call >= 4
            ? const PatchbayRevealDecision.allow(
                maxSteps: 199,
                maxDurationMs: 120000,
              )
            : null,
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog()),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.policyChanged,
          steps: 1,
          containers: <String>[_container(1)],
        ),
      );
      // policy 重评排在门之前：改判的那一步不问门。
      expect(run.log.gateCalls, 2);
    });

    testWidgets('gateRejected：带 gateId 与 gateCode', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        decide: (int call) => call >= 3
            ? const PatchbayGateDecision.reject(code: 'appBusy')
            : const PatchbayGateDecision.allow(),
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog()),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.gateRejected,
          steps: 1,
          containers: <String>[_container(1)],
          tail: ',"gateId":"patchbay.base","gateCode":"appBusy"',
        ),
      );
    });

    testWidgets('lifecycleNotResumed：步间离开 resumed', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      var resumed = true;
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        decide: (int call) {
          if (call == 2) resumed = false;
          return const PatchbayGateDecision.allow();
        },
        isAppResumed: () => resumed,
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealSyntheticScroll(log: RevealSyntheticLog()),
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.lifecycleNotResumed,
          steps: 1,
          containers: <String>[_container(1)],
        ),
      );
      // 生命周期闸排在容器重解析之前：第 2 步不再问 policy。
      expect(run.log.policyCalls, 3);
    });

    testWidgets('timeout：门 await 里撞上 deadline', (WidgetTester tester) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        decide: (int call) => call >= 3
            ? Completer<PatchbayGateDecision>().future
            : const PatchbayGateDecision.allow(),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(RevealSyntheticScroll(log: RevealSyntheticLog())),
      );
      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 40,
        timeoutMs: 250,
      );
      for (var attempt = 0; attempt < 40 && log.gateCalls < 3; attempt += 1) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));
      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        pending,
      );

      expect(
        pinnedRevealPayload(revealPayload(result)),
        _failed(
          PatchbayRevealReason.timeout,
          steps: 1,
          containers: <String>[_container(1)],
        ),
      );
    });

    testWidgets('containerDenied：升层容器被 policy 拒 ⇒ containers 只含内层', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        byContainer: const <String, PatchbayRevealDecision>{
          revealContainerId: PatchbayRevealDecision.reject(),
        },
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealNestedSyntheticScroll(
          outerLog: RevealSyntheticLog(),
          innerLog: RevealSyntheticLog(),
        ),
        container: revealNestedContainerId,
        maxSteps: 60,
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.containerDenied,
          steps: PatchbayRevealBudget.stallSteps,
          containers: <String>[_container(PatchbayRevealBudget.stallSteps)],
        ),
      );
      // 被拒的外层不进 containers：元素只在**第一次派发**时追加。
      expect(run.log.policyContainers.last, revealContainerId);
      expect(run.log.gateCalls, 3, reason: '被拒容器不求门');
    });

    testWidgets('containerBudgetTooSmall：外层授权时长比已冻结预算更严', (
      WidgetTester tester,
    ) async {
      final RevealCallLog log = RevealCallLog();
      final PatchbayFlutterBridge bridge = revealRecordingBridge(
        log,
        byContainer: const <String, PatchbayRevealDecision>{
          revealContainerId: PatchbayRevealDecision.allow(
            maxSteps: 200,
            maxDurationMs: 1000,
          ),
        },
      );
      addTearDown(bridge.dispose);
      final RevealRun run = await _drive(
        tester,
        bridge,
        log,
        RevealNestedSyntheticScroll(
          outerLog: RevealSyntheticLog(),
          innerLog: RevealSyntheticLog(),
        ),
        container: revealNestedContainerId,
        maxSteps: 60,
      );

      expect(
        run.pinned,
        _failed(
          PatchbayRevealReason.containerBudgetTooSmall,
          steps: PatchbayRevealBudget.stallSteps,
          containers: <String>[_container(PatchbayRevealBudget.stallSteps)],
        ),
      );
      expect(run.log.gateCalls, 3, reason: '预算不足的容器不求门');
    });
  });

  test('表征网格走遍受理后 reason 的封闭词表', () {
    expect(_covered, PatchbayRevealReason.values);
  });
}
