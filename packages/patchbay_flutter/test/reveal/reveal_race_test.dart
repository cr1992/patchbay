// PB-050-17 / DG-050-10：`ui.reveal` 的竞态与失败注入矩阵。
//
// reveal_matrix_test.dart / reveal_policy_test.dart 锁的是终止条件与授权矩阵
// 的稳态形状；本文件补的是「事情恰好在两次求值之间发生变化」这一类窗口——
// 门 await 期间 / 步间容器换代、`performAction` 抛出、门本身耗时把 deadline
// 吃掉、owner 背后的树被连根拔起，以及 deadline 恰好落在两个不同位置。
//
// 与既有文件共用一条机检：整条矩阵里 `showOnScreenCalls` 恒为 0。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

void main() {
  setUp(resetRevealCounters);

  group('竞态与失败注入', () {
    testWidgets('门 await 期间容器换代 ⇒ 准入前拒绝', (WidgetTester tester) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () => gate.future,
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          revealList(
            itemCount: 40,
            targetIndex: 20,
            listKey: const ValueKey<int>(1),
          ),
        ),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        timeoutMs: 60000,
      );
      await tester.pump();
      await tester.pump();
      // 门还没放行，容器已经换代：admission 期间 pin 住的 nodeId 不再挂在
      // 树上——换一个 listKey 就换一整棵 ListView 子树，因而换一个滚动
      // SemanticsNode。
      await tester.pumpWidget(
        revealApp(
          revealList(
            itemCount: 40,
            targetIndex: 20,
            listKey: const ValueKey<int>(2),
          ),
        ),
      );
      gate.complete(const PatchbayGateDecision.allow());

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        pending,
      );

      expect(result.rejection?.code, 'uiRevealPolicyChanged');
      expect(showOnScreenCalls, 0);
    });

    testWidgets('步间容器换代 ⇒ 受理后 containerChanged', (WidgetTester tester) async {
      var gateCalls = 0;
      late StateSetter setKeyState;
      Key listKey = const ValueKey<int>(1);
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            gateCalls += 1;
            // #1 准入，#2 第 1 步之前，#3 第 2 步之前，#4 第 3 步之前……
            // 在 #4 换代：此时第 3 步已经用旧节点解析完毕、只是还没派发，
            // 换代要等下一帧才真正生效，所以第 3 步仍然打在旧节点上，
            // 之后某一步的重解析才会撞见新节点——因此不锁死一个精确 steps
            // 值，只断言它已经过了两步。
            if (gateCalls == 4) {
              setKeyState(() => listKey = const ValueKey<int>(2));
            }
            return const PatchbayGateDecision.allow();
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setKeyState = setState;
              return revealList(
                itemCount: 400,
                targetIndex: 380,
                listKey: listKey,
              );
            },
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
            maxSteps: 60,
            timeoutMs: 60000,
          ),
        ),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'containerChanged');
      expect(payload['steps'], greaterThanOrEqualTo(2), reason: '$payload');
      expect(payload['steps'], lessThan(60), reason: '$payload');
      expect(
        revealContainers(payload).single['steps'],
        payload['steps'],
        reason: '单容器场景：容器自己的 steps 应等于顶层 steps：$payload',
      );
      expectRevealInvariants(payload);
    });

    testWidgets(
      'performAction 抛出 ⇒ scrollActionFailed，details 只写 runtimeType',
      (WidgetTester tester) async {
        final PatchbayFlutterBridge bridge = revealBridge();
        addTearDown(bridge.dispose);
        await tester.pumpWidget(revealApp(const _ThrowingScrollContainer()));

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
        expect(payload['reason'], 'scrollActionFailed');
        expect(payload['failureType'], 'StateError');
        // 第一步先真的滚动过一次，失败落在受理之后：steps 恰好是 1。
        expect(payload['steps'], 1, reason: '$payload');
        expect(
          revealContainers(payload).single['steps'],
          1,
          reason: '$payload',
        );
        expect(
          payload.keys.where(
            (String key) =>
                key.toLowerCase().contains('message') ||
                key.toLowerCase().contains('stack'),
          ),
          isEmpty,
          reason: '失败 details 只允许 runtimeType，不得带 message/stack：$payload',
        );
        expectRevealInvariants(payload);
      },
    );

    testWidgets('慢门（每次 evaluate 都可控时长）⇒ 以 timeout 终止，steps 如实小于 '
        'maxSteps，证明门耗时被同一 deadline 吸收', (WidgetTester tester) async {
      var gateCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            gateCalls += 1;
            // #1 准入、#2 第 1 步之前都放行得很快，第 1 步因此真的派发了一
            // 次；#3（第 2 步之前）起挂起不放——它的耗时不靠某次求值主动
            // 拒绝收场，只能靠 deadline 本身。
            return gateCalls <= 2
                ? const PatchbayGateDecision.allow()
                : Completer<PatchbayGateDecision>().future;
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 60,
        timeoutMs: 300,
      );
      for (var attempt = 0; attempt < 20 && gateCalls < 3; attempt += 1) {
        await tester.pump();
      }
      expect(gateCalls, 3, reason: '应已进入第 2 步的门求值并挂起');
      // 门自己没有独立于 deadline 之外的出口：只有把虚拟时钟推过
      // deadline，`_beforeDeadline` 包的 `.timeout()` 才会替它收场。
      await tester.pump(const Duration(milliseconds: 500));

      final Map<String, Object?> payload = revealPayload(
        await runReveal(tester, bridge, pending),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'timeout');
      expect(payload['steps'], greaterThanOrEqualTo(1), reason: '$payload');
      expect(payload['steps'], lessThan(60), reason: '$payload');
      expectRevealInvariants(payload);
    });

    testWidgets('owner 中途消失（语义树被连根拔起）⇒ 稳定失败形态，不崩溃', (
      WidgetTester tester,
    ) async {
      final Completer<PatchbayGateDecision> hang =
          Completer<PatchbayGateDecision>();
      var gateCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            gateCalls += 1;
            // #1 准入、#2 第 1 步之前放行得很快；#3（第 2 步之前）挂起，留出
            // 窗口让测试在它还没放行时把整棵语义树拔掉。
            return gateCalls < 3
                ? const PatchbayGateDecision.allow()
                : hang.future;
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 60,
        timeoutMs: 60000,
      );
      for (var attempt = 0; attempt < 20 && gateCalls < 3; attempt += 1) {
        await tester.pump();
      }
      expect(gateCalls, 3, reason: '应已进入第 2 步的门求值并挂起');
      // owner 这个 Dart 对象还在引擎手里，但它背后的语义树被整体换成一个不产
      // 出任何语义的空 widget：下一次重解析会发现 owner 名下什么都找不到，
      // 模拟 App 在 reveal 进行中把这块 UI 整个拆掉。
      await tester.pumpWidget(const SizedBox.shrink());
      hang.complete(const PatchbayGateDecision.allow());

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        pending,
      );

      expect(
        result.admission,
        PatchbayAdmission.accepted,
        reason: '第 1 步已经真实派发过，失败应落在受理之后：${result.toJson()}',
      );
      final Map<String, Object?> payload = result.payload;
      expect(payload['outcome'], 'failed');
      // 第 2 步的门在树被拔起之后才放行：`performAction` 打在一个 owner 已经
      // 不认识的旧 nodeId 上，框架静默无效（不是异常），所以第 2 步仍然记成
      // 「派发过」；真正拿到「找不到」事实的是第 3 步开头的重解析。
      expect(payload['reason'], 'containerChanged', reason: '$payload');
      expect(payload['steps'], 2, reason: '$payload');
      expect(revealContainers(payload).single['steps'], 2, reason: '$payload');
      expectRevealInvariants(payload);
      expect(showOnScreenCalls, 0);
    });
  });

  group('deadline 落点', () {
    testWidgets('deadline 恰落两步之间 ⇒ timeout，如实报告已发生步数', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 60,
        timeoutMs: 150,
      );
      await tester.pump();
      await tester.pump();
      // 真实墙钟推过 deadline，且这一推恰好落在两次 pump（两步）之间：下一步
      // 顶部的同步预检（`_step` 的检查 a）会在派发之前如实拦下——它不需要
      // 任何 Future 超时机制，纯粹是一次 `DateTime.now()` 比较。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      final Map<String, Object?> payload = revealPayload(
        await runReveal(tester, bridge, pending),
      );

      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'timeout');
      expect(payload['steps'], greaterThanOrEqualTo(1), reason: '$payload');
      expect(payload['steps'], lessThan(60), reason: '$payload');
      expectRevealInvariants(payload);
    });

    testWidgets('deadline 落在门 await 之中（第一步的门）⇒ 准入前拒绝，一步都没派发', (
      WidgetTester tester,
    ) async {
      var gateCalls = 0;
      final PatchbayFlutterBridge bridge = revealBridge(
        gates: PatchbayGateEvaluator(
          baseGate: () {
            gateCalls += 1;
            // 只有准入门放行得快；第一步的门从此再也不放行，deadline 因此
            // 必然落在这次 `_beforeDeadline` 包着的 await 里面。
            return gateCalls == 1
                ? const PatchbayGateDecision.allow()
                : Completer<PatchbayGateDecision>().future;
          },
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 400, targetIndex: 380)),
      );

      final Future<PatchbayInvocation> pending = bridge.reveal.reveal(
        identifier: revealTargetId,
        direction: PatchbayRevealDirection.forward,
        maxSteps: 60,
        timeoutMs: 250,
      );
      for (var attempt = 0; attempt < 20 && gateCalls < 2; attempt += 1) {
        await tester.pump();
      }
      expect(gateCalls, 2, reason: '应已进入第一步的门求值并挂起');
      await tester.pump(const Duration(milliseconds: 500));

      final PatchbayInvocation result = await runReveal(
        tester,
        bridge,
        pending,
      );

      expect(result.admission, PatchbayAdmission.rejected);
      expect(result.rejection?.code, 'uiRevealBudgetExceeded');
      expect(result.rejection?.details['exceeded'], <String>['timeoutMs']);
      expect(showOnScreenCalls, 0);
    });
  });
}

/// 假滚动容器：不依赖真实 `ListView`，`onScrollDown` 完全由测试控制——第二
/// 次调用起直接抛出，用来验证 `performAction` 抛出时的处理路径。真实
/// `ListView` 的滚动 handler 是框架内部实现，测试没有钩子能让它抛出。
final class _ThrowingScrollContainer extends StatefulWidget {
  const _ThrowingScrollContainer();

  @override
  State<_ThrowingScrollContainer> createState() =>
      _ThrowingScrollContainerState();
}

final class _ThrowingScrollContainerState
    extends State<_ThrowingScrollContainer> {
  double _position = 0;
  int _calls = 0;

  void _onScrollDown() {
    _calls += 1;
    if (_calls == 1) {
      // 第一步先真的推进一格：失败因此落在「受理后」而不是准入前。
      setState(() => _position += revealRowExtent);
      return;
    }
    throw StateError('reveal_race_test: injected performAction failure');
  }

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: revealContainerId,
    container: true,
    child: _RawScrollSemantics(
      position: _position,
      max: revealRowExtent * 40,
      onScrollDown: _onScrollDown,
      child: const SizedBox(
        width: revealViewportExtent,
        height: revealViewportExtent,
      ),
    ),
  );
}

/// 手写 `SemanticsConfiguration`：`Semantics` widget 不暴露 `scrollPosition`
/// / `scrollExtentMax` 这类字段，真实 `ListView` 又没有让测试直接控制其滚动
/// handler 抛出的钩子，因此这里绕过两者、直接在 render object 层声明一个假
/// 滚动节点——与 [ShowOnScreenRecorder] 同一种手法。
final class _RawScrollSemantics extends SingleChildRenderObjectWidget {
  const _RawScrollSemantics({
    required this.position,
    required this.max,
    required this.onScrollDown,
    required Widget super.child,
  });

  final double position;
  final double max;
  final VoidCallback onScrollDown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRawScrollSemantics(
        position: position,
        max: max,
        onScrollDown: onScrollDown,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRawScrollSemantics renderObject,
  ) {
    renderObject
      ..position = position
      ..max = max
      ..onScrollDown = onScrollDown;
  }
}

final class _RenderRawScrollSemantics extends RenderProxyBox {
  _RenderRawScrollSemantics({
    required double position,
    required double max,
    required VoidCallback onScrollDown,
  }) : _position = position,
       _max = max,
       _onScrollDown = onScrollDown;

  double _position;
  set position(double value) {
    if (_position == value) return;
    _position = value;
    markNeedsSemanticsUpdate();
  }

  double _max;
  set max(double value) {
    if (_max == value) return;
    _max = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback _onScrollDown;
  set onScrollDown(VoidCallback value) => _onScrollDown = value;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.scrollPosition = _position;
    config.scrollExtentMin = 0;
    config.scrollExtentMax = _max;
    config.onScrollDown = _onScrollDown;
  }
}
