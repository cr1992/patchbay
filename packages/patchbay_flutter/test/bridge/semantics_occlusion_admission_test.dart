// PB-050-16 / DG-050-09：点性 semantics 派发的遮挡准入矩阵。
//
// 缺陷本身的翻转 repro 在 semantics_obscured_tap_bridge_test.dart；判定基元的
// 三态与 fail-closed reason 在 ../occlusion_probe_test.dart。本文件锁的是
// `_dispatch` 这一个闸点的端到端行为：谁被拒、谁必须原样放行、拒绝 details
// 的形状，以及闸与既有准入序列的先后。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/flutter_bridge_fixtures.dart';

const String _targetId = 'occluded.target';

void main() {
  group('occlusion matrix', () {
    testWidgets('a partial overlay with one reachable quadrant is admitted', (
      tester,
    ) async {
      // 覆盖左 60：中心与左上采样被挡，右侧两个象限露着。五点任一命中即通过。
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[
          _pointerTarget(),
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 60,
            child: ColoredBox(color: Colors.black),
          ),
        ]),
      );

      expect(outcome.result.payload['outcome'], 'dispatched');
      expect(outcome.taps, 1);
    });

    testWidgets('a target left exposed only outside the fixed samples is '
        'refused, and that is the declared cost', (tester) async {
      // 诚实边界：本闸是**固定采样准入**，不是可达性证明。目标右侧还露着
      // 10px 的窄缝，真实用户点得到，五个采样点却全被挡——于是拒绝。这是
      // fail-closed 的已声明代价（Proposal「差异一」），不是缺陷；要修它就要
      // 改采样集合，回 Proposal 改判定，而不是在实现里放宽语义。
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[
          _pointerTarget(),
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 90,
            child: ColoredBox(color: Colors.black),
          ),
        ]),
      );

      expect(outcome.result.rejection?.code, 'uiSemanticsTargetObscured');
      expect(outcome.result.rejection?.details['reason'], 'hitTestOrClip');
      expect(outcome.taps, 0);
    });

    testWidgets('an IgnorePointer overlay does not obscure', (tester) async {
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[
          _pointerTarget(),
          const IgnorePointer(child: ColoredBox(color: Color(0xFF000000))),
        ]),
      );

      expect(outcome.result.payload['outcome'], 'dispatched');
      expect(outcome.taps, 1);
    });

    testWidgets('a translucent overlay that leaves the target in the hit '
        'chain does not obscure', (tester) async {
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[
          _pointerTarget(),
          // 上色的三种常见写法里，`ColoredBox` 与 `DecoratedBox` 都自己参与
          // 命中测试（前者 behavior 就是 opaque，后者按 decoration 形状
          // hitTestSelf），`CustomPainter.hitTest` 默认也返回 true。要真的测
          // translucent，画笔必须显式让开，否则测的其实是 opaque。
          Listener(
            behavior: HitTestBehavior.translucent,
            child: CustomPaint(painter: _WashPainter()),
          ),
        ]),
      );

      expect(outcome.result.payload['outcome'], 'dispatched');
      expect(outcome.taps, 1);
    });

    testWidgets('a self-painted CustomPaint target is admitted', (
      tester,
    ) async {
      // `CustomPainter.hitTest` 默认返回 true，所以自绘目标自己就在命中链里
      // （reachable）。无指针占位那一格由下面的 SizedBox 用例覆盖。
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[
          _target(
            CustomPaint(size: const Size(100, 100), painter: _ProbePainter()),
          ),
        ]),
      );

      expect(outcome.result.payload['outcome'], 'dispatched');
      expect(outcome.taps, 1);
    });

    testWidgets('an uncovered Semantics(onTap:) > SizedBox is admitted', (
      tester,
    ) async {
      // 仓内既有绿灯判例。照搬 gesture 的布尔规则会把它判成遮挡，
      // noPointerFootprint 这一态就是为它存在的。
      final _Outcome outcome = await _tap(
        tester,
        _stack(<Widget>[_target(const SizedBox(width: 100, height: 100))]),
      );

      expect(outcome.result.payload['outcome'], 'dispatched');
      expect(outcome.taps, 1);
    });

    testWidgets('a target scrolled outside its own viewport is refused', (
      tester,
    ) async {
      var taps = 0;
      final _Outcome outcome = await _tapWidget(
        tester,
        SizedBox(
          width: 100,
          height: 50,
          child: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                const SizedBox(width: 100, height: 300),
                Semantics(
                  identifier: _targetId,
                  button: true,
                  onTap: () => taps += 1,
                  child: const Listener(
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        () => taps,
      );

      expect(outcome.result.rejection?.code, 'uiSemanticsTargetObscured');
      expect(outcome.result.rejection?.details['reason'], 'hitTestOrClip');
      expect(outcome.taps, 0);
    });

    testWidgets('a blocked target keeps reporting uiSemanticsActionBlocked', (
      tester,
    ) async {
      // 「语义被屏蔽」与「视觉被覆盖」补救方式不同，两个码不合并：即使同一屏
      // 位置还压着一层不透明浮层，blockUserActions 仍然先接手。
      var taps = 0;
      final _Outcome outcome = await _tapWidget(
        tester,
        SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Semantics(
                blockUserActions: true,
                child: Semantics(
                  identifier: _targetId,
                  button: true,
                  onTap: () => taps += 1,
                  child: const Listener(
                    behavior: HitTestBehavior.opaque,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
        () => taps,
      );

      expect(outcome.result.rejection?.code, 'uiSemanticsActionBlocked');
      expect(outcome.taps, 0);
    });
  });

  group('point-like classification', () {
    testWidgets('the point-like set is exactly {tap, longPress}', (
      tester,
    ) async {
      // 封闭集合断言：同一个被全覆盖的目标上，只有点性 action 被本闸拒绝，
      // 其余每一个都必须原样派发。枚举新增值会自动进入这个循环——它既没有
      // 处理器（uiSemanticsActionUnavailable）也没有分类，测试会红。
      final Set<PatchbaySemanticsAction> refused = <PatchbaySemanticsAction>{};
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(
        _app(
          _stack(<Widget>[
            const _AllActionsTarget(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
            const Listener(
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(color: Colors.black),
            ),
          ]),
        ),
      );

      for (final PatchbaySemanticsAction action
          in PatchbaySemanticsAction.values) {
        final Map<String, Object?> node = await _node(tester, bridge);
        final PatchbayInvocation result = await semanticsInvoke(
          tester,
          bridge,
          node: node,
          action: action,
          text: action == PatchbaySemanticsAction.setText ? 'value' : null,
        );
        if (result.rejection?.code == 'uiSemanticsTargetObscured') {
          refused.add(action);
          continue;
        }
        expect(
          result.payload['outcome'],
          'dispatched',
          reason: '$action: ${result.toJson()}',
        );
      }
      bridge.semantics.dispose();

      expect(refused, <PatchbaySemanticsAction>{
        PatchbaySemanticsAction.tap,
        PatchbaySemanticsAction.longPress,
      });
    });
  });

  group('rejection shape', () {
    testWidgets('every anchoring entry answers the same code and the same '
        'details shape', (tester) async {
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(_app(_occludedStack()));
      final Map<String, Object?> node = await _node(tester, bridge);

      final PatchbayInvocation byNodeId = await semanticsInvoke(
        tester,
        bridge,
        node: node,
        action: PatchbaySemanticsAction.tap,
      );
      final PatchbayInvocation byIdentifier = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: _targetId),
      );
      bridge.semantics.dispose();

      // PB-050-10 的 invokeIdentifier 会走同一个 `_dispatch`，因此按构造落在
      // identifier 那一格；它落地时不需要在这里再加一条分支。
      expect(byNodeId.rejection?.code, 'uiSemanticsTargetObscured');
      expect(byIdentifier.rejection?.code, byNodeId.rejection?.code);
      expect(byNodeId.rejection?.details, <String, Object?>{
        'reason': 'hitTestOrClip',
        'nodeId': node['nodeId'],
        'generation': node['generation'],
      });
      expect(byIdentifier.rejection?.details, <String, Object?>{
        'reason': 'hitTestOrClip',
        'nodeId': node['nodeId'],
        'generation': node['generation'],
        'identifier': _targetId,
      });
    });

    testWidgets('the rejection carries no geometry and no occluder identity', (
      tester,
    ) async {
      final _Outcome outcome = await _tap(tester, _occludedStack());
      final Map<String, Object?> details = outcome.result.rejection!.details;

      // DG-040-01：转换后的全局坐标是一次调用内的瞬时实现细节，不进 payload、
      // 日志与 trace。裁决同时否掉了 occluderIdentifier——稳定错误面不顺带
      // 泄露另一个节点的身份。
      expect(details.keys.toSet(), <String>{
        'reason',
        'nodeId',
        'generation',
        'identifier',
      });
      expect(
        outcome.result.toJson().toString(),
        isNot(
          matches(
            RegExp(
              'rect|devicePixelRatio|viewId|probe|offset|dx|dy|'
              'occluder|label|tooltip|hint',
              caseSensitive: false,
            ),
          ),
        ),
      );
    });
  });

  group('reachable targets are byte-for-byte unchanged', () {
    testWidgets('an admitted tap answers the pre-gate envelope', (
      tester,
    ) async {
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          _stack(<Widget>[
            Semantics(
              identifier: _targetId,
              button: true,
              onTap: () => taps += 1,
              child: const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ]),
        ),
      );
      final Map<String, Object?> node = await _node(tester, bridge);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(
          identifier: _targetId,
          requestId: 'tap-golden',
        ),
      );
      bridge.semantics.dispose();

      final Map<String, Object?> payload =
          result.toJson()['payload']! as Map<String, Object?>;
      // 树版本随帧推进，取自被测响应本身；其余每一个键与值都在这里钉死，
      // 多一个键、少一个键或改一个值都会红。
      expect(result.toJson(), <String, Object?>{
        'schemaVersion': PatchbayInvocation.schemaVersion,
        'requestId': 'tap-golden',
        'admission': 'accepted',
        'notice': null,
        'jobId': null,
        'rejection': null,
        'payload': <String, Object?>{
          'outcome': 'dispatched',
          'source': 'uiObserved',
          'identifier': _targetId,
          'nodeId': node['nodeId'],
          'generation': node['generation'],
          'action': 'tap',
          'beforeTreeRevision': payload['beforeTreeRevision'],
          'afterTreeRevision': payload['afterTreeRevision'],
        },
      });
      expect(payload['beforeTreeRevision'], isA<int>());
      expect(payload['afterTreeRevision'], isA<int>());
      expect(taps, 1);
    });
  });

  group('admission order', () {
    testWidgets('a policy that denies an occluded target still answers '
        'uiSemanticsActionDenied', (tester) async {
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
        semanticsActionPolicy: (_, _) =>
            const PatchbaySemanticsActionDecision.reject(),
        isAppResumed: () => true,
      );
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(_app(_occludedStack()));

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: _targetId),
      );
      bridge.semantics.dispose();

      expect(result.rejection?.code, 'uiSemanticsActionDenied');
    });

    testWidgets('a policy that drifts on an occluded target still answers '
        'uiSemanticsPolicyChanged', (tester) async {
      var calls = 0;
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
        semanticsActionPolicy: (_, _) {
          calls += 1;
          return calls == 1
              ? const PatchbaySemanticsActionDecision.allow(
                  gateIds: <String>{'ui.ready'},
                )
              : const PatchbaySemanticsActionDecision.allow();
        },
        isAppResumed: () => true,
      );
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(_app(_occludedStack()));

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: _targetId),
      );
      bridge.semantics.dispose();

      expect(result.rejection?.code, 'uiSemanticsPolicyChanged');
    });

    test('nothing awaits between the re-check and performAction', () {
      // 复核结论只对这一次派发有效。一个 await 落在这两步之间，结论就可能
      // 在派发前失效，而本闸没有 bypass 可救。这条断言是结构性的，因为
      // 「门后没有让步点」用行为测试造不出确定性的反例。
      //
      // PB-050-38 把管线拆成阶段之后，这段「无让步点」跨了两个文件，于是断言
      // 也拆成三段：桥里从遮挡准入调用到派发调用、遮挡准入本身是同步的、派发
      // 阶段从函数体开始到 performAction。三段合起来仍然覆盖原来那一段。
      final String bridge = File(
        'lib/src/semantics/semantics_bridge.dart',
      ).readAsStringSync();
      final int revalidate = bridge.indexOf('patchbaySemanticsRevalidate(');
      final int fence = bridge.indexOf('patchbaySemanticsOcclusionFence(');
      final int perform = bridge.indexOf('patchbaySemanticsPerformAction(');
      expect(revalidate, greaterThan(0));
      expect(fence, greaterThan(revalidate));
      expect(perform, greaterThan(fence));
      final String orchestration = bridge.substring(fence, perform);
      expect(orchestration, isNot(contains('await ')));
      expect(orchestration, isNot(contains('yield ')));

      final String stage = File(
        'lib/src/semantics/semantics_dispatch_stage.dart',
      ).readAsStringSync();
      final int fenceBody = stage.indexOf(
        'PatchbayInvocation? patchbaySemanticsOcclusionFence(',
      );
      final int performBody = stage.indexOf(
        'Future<PatchbayInvocation> patchbaySemanticsPerformAction(',
      );
      final int dispatch = stage.indexOf('owner.performAction(');
      expect(fenceBody, greaterThan(0));
      expect(performBody, greaterThan(fenceBody));
      expect(dispatch, greaterThan(performBody));
      // 遮挡准入必须是同步函数：它的整段声明里不得出现 await。
      expect(
        stage.substring(fenceBody, performBody),
        isNot(contains('await ')),
      );
      final String between = stage.substring(performBody, dispatch);
      expect(between, isNot(contains('await ')));
      expect(between, isNot(contains('yield ')));
    });
  });

  group('TOCTOU across the declared gate', () {
    testWidgets('an overlay raised while the gate awaits is refused', (
      tester,
    ) async {
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var taps = 0;
      final PatchbayFlutterBridge bridge = _gatedBridge(gate);
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(
        _app(_toctou(overlay: false, onTap: () => taps++)),
      );

      final Future<PatchbayInvocation> pending = bridge.semantics.tapIdentifier(
        identifier: _targetId,
      );
      await tester.pump();
      await tester.pumpWidget(
        _app(_toctou(overlay: true, onTap: () => taps++)),
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );
      bridge.semantics.dispose();

      expect(result.rejection?.code, 'uiSemanticsTargetObscured');
      expect(taps, 0);
    });

    testWidgets('an overlay removed while the gate awaits is admitted', (
      tester,
    ) async {
      // 不引入「曾经被盖」这种记忆状态：门后这一次说了算。
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      var taps = 0;
      final PatchbayFlutterBridge bridge = _gatedBridge(gate);
      addTearDown(bridge.semantics.dispose);
      await tester.pumpWidget(
        _app(_toctou(overlay: true, onTap: () => taps++)),
      );

      final Future<PatchbayInvocation> pending = bridge.semantics.tapIdentifier(
        identifier: _targetId,
      );
      await tester.pump();
      await tester.pumpWidget(
        _app(_toctou(overlay: false, onTap: () => taps++)),
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );
      bridge.semantics.dispose();

      expect(result.payload['outcome'], 'dispatched');
      expect(taps, 1);
    });
  });

  group('audit', () {
    testWidgets('an obscured tap is not recorded as a gate rejection', (
      tester,
    ) async {
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(_app(_toctou(overlay: true, onTap: () {})));

      final Map<String, Object?> obscured = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', <String, Object?>{
          'identifier': _targetId,
        }, 'request-obscured'),
      );
      await tester.pumpWidget(_app(_toctou(overlay: false, onTap: () {})));
      final Map<String, Object?> reachable = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', <String, Object?>{
          'identifier': _targetId,
        }, 'request-reachable'),
      );
      bridge.semantics.dispose();

      expect(
        (obscured['rejection']! as Map<String, Object?>)['code'],
        'uiSemanticsTargetObscured',
      );
      expect(
        (reachable['payload']! as Map<String, Object?>)['outcome'],
        'dispatched',
      );

      // 本闸不是 domain gate：它在门后、派发之前，所以审计里的 gateResult 与
      // 同一命令上一次可达派发完全一致，不冒充门禁拒绝。
      final PatchbayAuditEvent refused = _event(host, 'request-obscured');
      final PatchbayAuditEvent admitted = _event(host, 'request-reachable');
      expect(refused.command, 'ui.semantics.tap');
      expect(refused.gateResult, admitted.gateResult);
      expect(refused.executionClassification, isNull);
    });
  });
}

PatchbayAuditEvent _event(PatchbayFlutterServiceHost host, String requestId) =>
    host.auditEvents.singleWhere(
      (PatchbayAuditEvent event) => event.requestId == requestId,
    );

typedef _Outcome = ({PatchbayInvocation result, int taps});

Widget _app(Widget child) => MaterialApp(home: Center(child: child));

Widget _stack(List<Widget> children) => SizedBox(
  width: 100,
  height: 100,
  child: Stack(fit: StackFit.expand, children: children),
);

Widget _occludedStack() => _stack(<Widget>[
  _pointerTarget(),
  const Listener(
    behavior: HitTestBehavior.opaque,
    child: ColoredBox(color: Colors.black),
  ),
]);

int _taps = 0;

Widget _pointerTarget() => _target(
  const Listener(
    behavior: HitTestBehavior.opaque,
    child: ColoredBox(color: Colors.blue),
  ),
);

Widget _target(Widget child) => Semantics(
  identifier: _targetId,
  button: true,
  onTap: () => _taps += 1,
  child: child,
);

/// 覆盖层用 [Listener] 而不是 `GestureDetector`：它不产生语义节点，所以加上/
/// 撤走只改变命中测试，不动目标的代际——否则 TOCTOU 用例会被
/// `uiSemanticsGenerationStale` 抢答。
Widget _toctou({required bool overlay, required VoidCallback onTap}) =>
    _stack(<Widget>[
      Semantics(
        identifier: _targetId,
        button: true,
        onTap: onTap,
        child: const Listener(
          behavior: HitTestBehavior.opaque,
          child: ColoredBox(color: Colors.blue),
        ),
      ),
      if (overlay)
        const Listener(
          behavior: HitTestBehavior.opaque,
          child: ColoredBox(color: Colors.black),
        ),
    ]);

PatchbayFlutterBridge _gatedBridge(Completer<PatchbayGateDecision> gate) =>
    PatchbayFlutterBridge(
      registry: PatchbayUiRegistry(),
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => gate.future,
      ),
      semanticsActionPolicy: (_, _) =>
          const PatchbaySemanticsActionDecision.allow(
            gateIds: <String>{'ui.ready'},
          ),
      isAppResumed: () => true,
    );

Future<_Outcome> _tap(WidgetTester tester, Widget target) async {
  _taps = 0;
  final _Outcome outcome = await _tapWidget(tester, target, () => _taps);
  return outcome;
}

Future<_Outcome> _tapWidget(
  WidgetTester tester,
  Widget target,
  int Function() taps,
) async {
  final PatchbayFlutterBridge bridge = interactiveBridge(PatchbayUiRegistry());
  addTearDown(bridge.semantics.dispose);
  await tester.pumpWidget(_app(target));
  final PatchbayInvocation result = await pumpUntilComplete(
    tester,
    bridge.semantics.tapIdentifier(identifier: _targetId),
  );
  bridge.semantics.dispose();
  return (result: result, taps: taps());
}

Future<Map<String, Object?>> _node(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final PatchbayInvocation snapshot = await semanticsSnapshot(tester, bridge);
  return semanticsNodes(
    snapshot,
  ).singleWhere((Map<String, Object?> node) => node['identifier'] == _targetId);
}

/// 一个把全部 [PatchbaySemanticsAction] 都声明出来的目标。
///
/// `Semantics` widget 没有 `onShowOnScreen`，所以封闭集合用例自己写一个
/// render object，把 14 个动作一次挂全。
final class _AllActionsTarget extends SingleChildRenderObjectWidget {
  const _AllActionsTarget({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAllActionsTarget();
}

final class _RenderAllActionsTarget extends RenderProxyBox {
  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..identifier = _targetId
      ..onTap = _noop
      ..onLongPress = _noop
      ..onFocus = _noop
      ..onDismiss = _noop
      ..onShowOnScreen = _noop
      ..onScrollUp = _noop
      ..onScrollDown = _noop
      ..onScrollLeft = _noop
      ..onScrollRight = _noop
      ..onIncrease = _noop
      ..onDecrease = _noop
      ..onExpand = _noop
      ..onCollapse = _noop
      ..onSetText = _setText;
  }
}

void _noop() {}

void _setText(String value) {}

/// 一层只上色、显式不参与命中测试的画笔。
final class _WashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x22000000),
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

final class _ProbePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
