// PB-050-38：准入管线**每个阶段各自**的失败注入。
//
// 表征测试（`semantics_pipeline_characterization_test.dart`）证明的是「整条管线
// 对外的形状没变」；这份文件证明的是拆分真的拆开了——每个阶段都能脱离
// `PatchbaySemanticsBridge` 单独构造，被单独注入失败，并给出**类型化**的结论。
// 拆完了却只能整条跑，那就只是把私有方法搬了个文件。
//
// 每组的最后一格把阶段结论和整条管线的最终拒绝码对上：阶段说 A、桥答 B 是最容易
// 在重构里发生、又最难在端到端测试里看见的错。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/semantics/semantics_action_taxonomy.dart';
import 'package:patchbay_flutter/src/semantics/semantics_dispatch_stage.dart';
import 'package:patchbay_flutter/src/semantics/semantics_evidence.dart';
import 'package:patchbay_flutter/src/semantics/semantics_lookup.dart';
import 'package:patchbay_flutter/src/semantics/semantics_models.dart'
    show PatchbaySemanticsResolution;
import 'package:patchbay_flutter/src/semantics/semantics_policy_stage.dart';
import 'package:patchbay_flutter/src/semantics/semantics_preflight_stage.dart';
import 'package:patchbay_flutter/src/semantics/semantics_resolve_stage.dart';

import '../fixture/flutter_bridge_fixtures.dart';

const String _targetId = 'stage.target';

/// 代际账本的替身：与桥的 `observe` 同构，但由测试完全掌握发号顺序。
final class _Ledger {
  final Map<int, PatchbaySemanticsEntry> _entries =
      <int, PatchbaySemanticsEntry>{};
  int _next = 0;

  PatchbaySemanticsEntry observe(SemanticsNode node) {
    final PatchbaySemanticsEntry? existing = _entries[node.id];
    if (existing != null && identical(existing.node.target, node)) {
      return existing;
    }
    final PatchbaySemanticsEntry next = PatchbaySemanticsEntry(
      WeakReference<SemanticsNode>(node),
      ++_next,
    );
    _entries[node.id] = next;
    return next;
  }

  PatchbaySemanticsEntry? entryFor(int nodeId) => _entries[nodeId];
}

PatchbaySemanticsBridge _bridge({
  PatchbaySemanticsActionPolicy? policy,
  PatchbayGateDecision Function(String gateId)? consumerGate,
}) => PatchbaySemanticsBridge(
  gates: PatchbayGateEvaluator(
    baseGate: () => const PatchbayGateDecision.allow(),
    consumerGate: consumerGate ?? (_) => const PatchbayGateDecision.allow(),
  ),
  actionPolicy:
      policy ?? (_, _) => const PatchbaySemanticsActionDecision.allow(),
  isAppResumed: () => true,
  newRequestId: () => 'stage-request',
);

/// 拿一棵真的语义树：阶段的接缝可以是替身，语义树不能。
Future<SemanticsOwner> _owner(
  WidgetTester tester,
  PatchbaySemanticsBridge bridge,
) async {
  final SemanticsOwner? owner = await pumpUntilComplete(
    tester,
    bridge.ensureOwner(),
  );
  expect(owner?.rootSemanticsNode, isNotNull);
  return owner!;
}

Widget _scene({
  int copies = 1,
  VoidCallback? onTap,
  ValueChanged<String>? onSetText,
  bool obscured = false,
  bool overlay = false,
}) => MaterialApp(
  home: Stack(
    children: <Widget>[
      for (var i = 0; i < copies; i += 1)
        Positioned(
          left: 0,
          top: 0,
          child: Semantics(
            identifier: _targetId,
            label: 'Target',
            obscured: obscured,
            textField: onSetText != null,
            onTap: onTap,
            onSetText: onSetText,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      if (overlay)
        Positioned(
          left: 0,
          top: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(width: 80, height: 80, color: Colors.black),
          ),
        ),
    ],
  ),
);

void main() {
  group('resolve target 阶段单独失败注入', () {
    testWidgets('owner 接缝注入 null：两条路径给出不同的 details', (tester) async {
      final _Ledger ledger = _Ledger();
      final PatchbaySemanticsTargetResolver resolver =
          PatchbaySemanticsTargetResolver(
            ensureOwner: () async => null,
            observe: ledger.observe,
            entryFor: ledger.entryFor,
            treeRevision: () => 7,
          );

      final PatchbaySemanticsResolution byIdentifier = await resolver
          .byIdentifier(
            identifier: _targetId,
            expectedGeneration: null,
            action: PatchbaySemanticsAction.tap,
          );
      final PatchbaySemanticsResolution byNodeId = await resolver.byNodeId(
        nodeId: 1,
        generation: 1,
        action: PatchbaySemanticsAction.tap,
      );

      expect(byIdentifier.resolved, isFalse);
      expect(byIdentifier.code, 'uiSemanticsUnavailable');
      expect(byIdentifier.details, <String, Object?>{'identifier': _targetId});
      expect(byNodeId.code, 'uiSemanticsUnavailable');
      expect(byNodeId.details, isEmpty);
    });

    testWidgets('歧义注入：阶段结论与桥的最终拒绝码一致', (tester) async {
      await tester.pumpWidget(_scene(copies: 2, onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final _Ledger ledger = _Ledger();
      final PatchbaySemanticsTargetResolver resolver =
          PatchbaySemanticsTargetResolver(
            ensureOwner: () async => owner,
            observe: ledger.observe,
            entryFor: ledger.entryFor,
            treeRevision: () => 7,
          );

      final PatchbaySemanticsResolution staged = await resolver.byIdentifier(
        identifier: _targetId,
        expectedGeneration: null,
        action: PatchbaySemanticsAction.tap,
      );
      final PatchbayInvocation piped = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: _targetId),
      );

      expect(staged.code, 'uiSemanticsIdentifierAmbiguous');
      expect(staged.details['matchCount'], 2);
      // treeRevision 走的是注入的接缝，不是桥的计数器。
      expect(staged.details['treeRevision'], 7);
      expect(piped.rejection?.code, staged.code);
      expect(
        (piped.rejection!.details['candidates']! as List<Object?>).length,
        (staged.details['candidates']! as List<Object?>).length,
      );
      bridge.dispose();
    });

    testWidgets('代际漂移注入：账本发几号，拒绝就报几号', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final _Ledger ledger = _Ledger();
      final PatchbaySemanticsTargetResolver resolver =
          PatchbaySemanticsTargetResolver(
            ensureOwner: () async => owner,
            observe: ledger.observe,
            entryFor: ledger.entryFor,
            treeRevision: () => 7,
          );
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;

      final PatchbaySemanticsResolution stale = await resolver.byIdentifier(
        identifier: _targetId,
        expectedGeneration: 99,
        action: PatchbaySemanticsAction.tap,
      );

      expect(stale.code, 'uiSemanticsGenerationStale');
      expect(stale.details, <String, Object?>{
        'identifier': _targetId,
        'nodeId': node.id,
        'expectedGeneration': 99,
        'currentGeneration': 1,
      });
      bridge.dispose();
    });

    testWidgets('账本缺条目注入：nodeId 在树上但未被观察', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;
      final _Ledger ledger = _Ledger();
      final PatchbaySemanticsTargetResolver resolver =
          PatchbaySemanticsTargetResolver(
            ensureOwner: () async => owner,
            observe: ledger.observe,
            entryFor: (_) => null,
            treeRevision: () => 7,
          );

      final PatchbaySemanticsResolution unobserved = await resolver.byNodeId(
        nodeId: node.id,
        generation: 1,
        action: PatchbaySemanticsAction.tap,
      );
      final PatchbaySemanticsResolution missing = await resolver.byNodeId(
        nodeId: 987654,
        generation: 1,
        action: PatchbaySemanticsAction.tap,
      );

      expect(unobserved.code, 'uiSemanticsNodeNotObserved');
      expect(missing.code, 'uiSemanticsNodeNotFound');
      bridge.dispose();
    });
  });

  group('preflight fence 阶段单独失败注入', () {
    test('生命周期围栏：判定与诊断是两个接缝', () {
      const PatchbaySemanticsLifecycleFence open =
          PatchbaySemanticsLifecycleFence(
            isAppResumed: _alwaysResumed,
            lifecycleState: _pausedState,
          );
      const PatchbaySemanticsLifecycleFence closed =
          PatchbaySemanticsLifecycleFence(
            isAppResumed: _neverResumed,
            lifecycleState: _pausedState,
          );

      expect(open.evaluate('r'), isNull);
      final PatchbayInvocation? rejected = closed.evaluate('r');
      expect(rejected?.requestId, 'r');
      expect(rejected?.rejection?.code, 'uiLifecycleNotResumed');
      expect(rejected?.rejection?.details, <String, Object?>{
        'lifecycleState': 'paused',
      });
    });

    test('gate 围栏：放行返回 null，拒绝带声明的 gateId', () async {
      final PatchbayGateEvaluator allowing = PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      );
      final PatchbayGateEvaluator refusing = PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) =>
            const PatchbayGateDecision.reject(code: 'stageGateRejected'),
      );

      expect(
        await patchbaySemanticsGateFence(
          allowing,
          requestId: 'r',
          gateIds: const <String>{'app.declared'},
        ),
        isNull,
      );
      final PatchbayInvocation? rejected = await patchbaySemanticsGateFence(
        refusing,
        requestId: 'r',
        gateIds: const <String>{'app.declared'},
      );
      expect(rejected?.rejection?.code, 'stageGateRejected');
      expect(rejected?.rejection?.details, <String, Object?>{
        'gateId': 'app.declared',
      });
    });

    testWidgets('阶段拒绝码与桥的最终拒绝码一致', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
          gateIds: <String>{'app.declared'},
        ),
        consumerGate: (_) =>
            const PatchbayGateDecision.reject(code: 'stageGateRejected'),
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation piped = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: _targetId),
      );

      expect(piped.rejection?.code, 'stageGateRejected');
      expect(piped.rejection?.details, <String, Object?>{
        'gateId': 'app.declared',
      });
      bridge.dispose();
    });
  });

  group('policy 阶段单独失败注入', () {
    test('拒绝、缺文本、多文本与敏感输入各自给出类型化结论', () {
      const PatchbaySemanticsTarget plain = PatchbaySemanticsTarget(
        nodeId: 1,
        generation: 1,
        identifier: _targetId,
        label: 'Target',
        flags: <String>{},
        actions: <PatchbaySemanticsAction>{},
        obscured: false,
      );
      const PatchbaySemanticsTarget obscured = PatchbaySemanticsTarget(
        nodeId: 1,
        generation: 1,
        identifier: _targetId,
        label: 'Target',
        flags: <String>{},
        actions: <PatchbaySemanticsAction>{},
        obscured: true,
      );

      final PatchbaySemanticsPolicyAdmission denied =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: (_, _) => const PatchbaySemanticsActionDecision.reject(
              rejectionCode: 'stagePolicyDenied',
            ),
            target: plain,
            action: PatchbaySemanticsAction.tap,
            text: null,
            inputWasStdin: false,
          );
      expect(denied.admitted, isFalse);
      expect(denied.rejection?.rejection?.code, 'stagePolicyDenied');

      final PatchbaySemanticsPolicyAdmission missingText =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: _allow,
            target: plain,
            action: PatchbaySemanticsAction.setText,
            text: null,
            inputWasStdin: false,
          );
      expect(missingText.rejection?.rejection?.code, 'uiSemanticsTextRequired');

      final PatchbaySemanticsPolicyAdmission extraText =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: _allow,
            target: plain,
            action: PatchbaySemanticsAction.tap,
            text: 'x',
            inputWasStdin: false,
          );
      expect(extraText.rejection?.rejection?.code, 'uiSemanticsUnexpectedText');

      final PatchbaySemanticsPolicyAdmission needsStdin =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: _allow,
            target: obscured,
            action: PatchbaySemanticsAction.setText,
            text: 'secret',
            inputWasStdin: false,
          );
      expect(
        needsStdin.rejection?.rejection?.code,
        'sensitiveInputRequiresStdin',
      );

      final PatchbaySemanticsPolicyAdmission admitted =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: _allow,
            target: obscured,
            action: PatchbaySemanticsAction.setText,
            text: 'secret',
            inputWasStdin: true,
          );
      expect(admitted.admitted, isTrue);
      expect(admitted.sensitive, isTrue);
      expect(admitted.sensitiveInput, isFalse);
    });

    test('声明集是副本：consumer 事后改自己的 Set 改不动复核基线', () {
      final Set<String> live = <String>{'app.one'};
      const PatchbaySemanticsTarget target = PatchbaySemanticsTarget(
        nodeId: 1,
        generation: 1,
        identifier: _targetId,
        label: 'Target',
        flags: <String>{},
        actions: <PatchbaySemanticsAction>{},
        obscured: false,
      );

      final PatchbaySemanticsPolicyAdmission admitted =
          patchbaySemanticsAdmitPolicy(
            requestId: 'r',
            policy: (_, _) =>
                PatchbaySemanticsActionDecision.allow(gateIds: live),
            target: target,
            action: PatchbaySemanticsAction.tap,
            text: null,
            inputWasStdin: false,
          );
      live.add('app.two');

      expect(admitted.gateIds, <String>{'app.one'});
    });
  });

  group('post-gate revalidation 阶段单独失败注入', () {
    testWidgets('目标在门后消失：复核直接透传解析阶段的拒绝', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final _Ledger ledger = _Ledger();
      final PatchbaySemanticsTargetResolver resolver =
          PatchbaySemanticsTargetResolver(
            ensureOwner: () async => owner,
            observe: ledger.observe,
            entryFor: ledger.entryFor,
            treeRevision: () => 7,
          );
      final PatchbaySemanticsResolution gone = await resolver.byIdentifier(
        identifier: 'stage.gone',
        expectedGeneration: null,
        action: PatchbaySemanticsAction.tap,
      );

      final PatchbaySemanticsRevalidation revalidated =
          patchbaySemanticsRevalidate(
            requestId: 'r',
            policy: _allow,
            action: PatchbaySemanticsAction.tap,
            admitted: _admission(),
            resolution: gone,
            inputWasStdin: false,
          );

      expect(revalidated.admitted, isFalse);
      expect(
        revalidated.rejection?.rejection?.code,
        'uiSemanticsIdentifierNotFound',
      );
      bridge.dispose();
    });

    testWidgets('声明集或敏感位在门后变了：uiSemanticsPolicyChanged', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final PatchbaySemanticsResolution resolved = await _resolve(
        tester,
        bridge,
      );

      final PatchbaySemanticsRevalidation gateDrift =
          patchbaySemanticsRevalidate(
            requestId: 'r',
            policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
              gateIds: <String>{'app.late'},
            ),
            action: PatchbaySemanticsAction.tap,
            admitted: _admission(),
            resolution: resolved,
            inputWasStdin: false,
          );
      final PatchbaySemanticsRevalidation sensitiveDrift =
          patchbaySemanticsRevalidate(
            requestId: 'r',
            policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
              sensitiveInput: true,
            ),
            action: PatchbaySemanticsAction.tap,
            admitted: _admission(),
            resolution: resolved,
            inputWasStdin: false,
          );
      final PatchbaySemanticsRevalidation steady = patchbaySemanticsRevalidate(
        requestId: 'r',
        policy: _allow,
        action: PatchbaySemanticsAction.tap,
        admitted: _admission(),
        resolution: resolved,
        inputWasStdin: false,
      );

      expect(gateDrift.rejection?.rejection?.code, 'uiSemanticsPolicyChanged');
      expect(
        sensitiveDrift.rejection?.rejection?.code,
        'uiSemanticsPolicyChanged',
      );
      expect(steady.admitted, isTrue);
      expect(steady.sensitive, isFalse);
      bridge.dispose();
    });

    testWidgets('门前不敏感、门后目标变遮蔽：敏感只会变严', (tester) async {
      await tester.pumpWidget(_scene(onSetText: (_) {}, obscured: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final PatchbaySemanticsResolution resolved = await _resolve(
        tester,
        bridge,
        action: PatchbaySemanticsAction.setText,
      );

      final PatchbaySemanticsRevalidation revalidated =
          patchbaySemanticsRevalidate(
            requestId: 'r',
            policy: _allow,
            action: PatchbaySemanticsAction.setText,
            // 门前那次读到的是「不敏感」。
            admitted: _admission(),
            resolution: resolved,
            inputWasStdin: false,
          );

      expect(resolved.target?.obscured, isTrue);
      expect(
        revalidated.rejection?.rejection?.code,
        'sensitiveInputRequiresStdin',
      );
      bridge.dispose();
    });
  });

  group('dispatch 阶段单独失败注入', () {
    testWidgets('遮挡准入只对点性 action 生效', (tester) async {
      await tester.pumpWidget(_scene(onTap: () {}, overlay: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;

      final PatchbayInvocation? pointLike = patchbaySemanticsOcclusionFence(
        requestId: 'r',
        action: PatchbaySemanticsAction.tap,
        owner: owner,
        node: node,
        nodeId: node.id,
        generation: 3,
        identifier: _targetId,
      );
      final PatchbayInvocation? dragLike = patchbaySemanticsOcclusionFence(
        requestId: 'r',
        action: PatchbaySemanticsAction.scrollUp,
        owner: owner,
        node: node,
        nodeId: node.id,
        generation: 3,
        identifier: _targetId,
      );

      expect(pointLike?.rejection?.code, 'uiSemanticsTargetObscured');
      expect(pointLike?.rejection?.details, <String, Object?>{
        'reason': 'hitTestOrClip',
        'nodeId': node.id,
        'generation': 3,
        'identifier': _targetId,
      });
      expect(dragLike, isNull, reason: '滚动的对应物是拖动，部分覆盖也应可滚动');
      bridge.dispose();
    });

    testWidgets('派发成功：treeRevision 前后各读一次，refreshOwner 只调一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_scene(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;
      var revision = 41;
      var refreshed = 0;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        patchbaySemanticsPerformAction(
          requestId: 'r',
          owner: owner,
          action: PatchbaySemanticsAction.tap,
          nodeId: node.id,
          generation: 3,
          sensitive: false,
          treeRevision: () => revision++,
          refreshOwner: () => refreshed += 1,
          identifier: _targetId,
        ),
      );

      expect(taps, 1);
      expect(refreshed, 1);
      expect(result.payload['beforeTreeRevision'], 41);
      expect(result.payload['afterTreeRevision'], 42);
      bridge.dispose();
    });

    testWidgets('派发抛出：受理不变，只换执行结论', (tester) async {
      await tester.pumpWidget(
        _scene(onTap: () => throw StateError('stage boom')),
      );
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;
      var refreshed = 0;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        patchbaySemanticsPerformAction(
          requestId: 'r',
          owner: owner,
          action: PatchbaySemanticsAction.tap,
          nodeId: node.id,
          generation: 3,
          sensitive: false,
          treeRevision: () => 41,
          refreshOwner: () => refreshed += 1,
          identifier: _targetId,
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(result.payload['outcome'], 'failed');
      expect(result.payload['failureType'], 'StateError');
      expect(refreshed, 0, reason: '抛出发生在等帧之前，owner 没有被刷新');
      bridge.dispose();
    });
  });

  group('evidence 投影阶段', () {
    testWidgets('遮蔽节点的候选事实不带 label，只带 labelRedacted', (tester) async {
      await tester.pumpWidget(_scene(obscured: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final SemanticsOwner owner = await _owner(tester, bridge);
      final SemanticsNode node = patchbaySemanticsNodesWithIdentifier(
        owner.rootSemanticsNode!,
        _targetId,
      ).single;

      final Map<String, Object?> evidence = patchbaySemanticsCandidateEvidence(
        node,
        node.getSemanticsData(),
        generation: 12,
      );

      expect(evidence['generation'], 12);
      expect(evidence['labelRedacted'], isTrue);
      expect(evidence.containsKey('label'), isFalse);
      bridge.dispose();
    });

    test('setText 载荷按敏感与否切换 valueRedacted', () {
      final Map<String, Object?> plain = patchbaySemanticsDispatchedPayload(
        action: PatchbaySemanticsAction.setText,
        nodeId: 1,
        generation: 2,
        beforeTreeRevision: 3,
        afterTreeRevision: 4,
        sensitive: false,
        text: 'abcd',
      );
      final Map<String, Object?> secret = patchbaySemanticsDispatchedPayload(
        action: PatchbaySemanticsAction.setText,
        nodeId: 1,
        generation: 2,
        beforeTreeRevision: 3,
        afterTreeRevision: 4,
        sensitive: true,
        text: 'abcd',
      );
      final Map<String, Object?> failed = patchbaySemanticsFailedPayload(
        action: PatchbaySemanticsAction.tap,
        nodeId: 1,
        generation: 2,
        error: ArgumentError('never surfaced'),
      );

      expect(plain['length'], 4);
      expect(plain.containsKey('valueRedacted'), isFalse);
      expect(secret['valueRedacted'], isTrue);
      expect(secret['length'], 4);
      expect(plain.containsValue('abcd'), isFalse);
      expect(secret.containsValue('abcd'), isFalse);
      expect(failed['failureType'], 'ArgumentError');
      expect(failed.containsKey('identifier'), isFalse);
    });
  });

  group('action 分类阶段', () {
    test('点性与 identifier 公开集是两份互不覆盖的封闭清单', () {
      expect(
        <PatchbaySemanticsAction>[
          for (final PatchbaySemanticsAction action
              in PatchbaySemanticsAction.values)
            if (action.isPointLike) action,
        ],
        <PatchbaySemanticsAction>[
          PatchbaySemanticsAction.tap,
          PatchbaySemanticsAction.longPress,
        ],
      );
      expect(
        <PatchbaySemanticsAction>[
          for (final PatchbaySemanticsAction action
              in PatchbaySemanticsAction.values)
            if (action.isPublicIdentifierAction) action,
        ],
        <PatchbaySemanticsAction>[
          PatchbaySemanticsAction.tap,
          PatchbaySemanticsAction.focus,
          PatchbaySemanticsAction.scrollUp,
          PatchbaySemanticsAction.scrollDown,
          PatchbaySemanticsAction.scrollLeft,
          PatchbaySemanticsAction.scrollRight,
          PatchbaySemanticsAction.setText,
        ],
      );
    });
  });
}

bool _alwaysResumed() => true;

bool _neverResumed() => false;

AppLifecycleState? _pausedState() => AppLifecycleState.paused;

PatchbaySemanticsActionDecision _allow(
  PatchbaySemanticsTarget target,
  PatchbaySemanticsAction action,
) => const PatchbaySemanticsActionDecision.allow();

/// 门前那次「允许、不声明门、不敏感」的结论。
PatchbaySemanticsPolicyAdmission _admission() =>
    const PatchbaySemanticsPolicyAdmission.admitted(
      gateIds: <String>{},
      sensitiveInput: false,
      sensitive: false,
    );

Future<PatchbaySemanticsResolution> _resolve(
  WidgetTester tester,
  PatchbaySemanticsBridge bridge, {
  PatchbaySemanticsAction action = PatchbaySemanticsAction.tap,
}) async {
  final SemanticsOwner? owner = await pumpUntilComplete(
    tester,
    bridge.ensureOwner(),
  );
  final _Ledger ledger = _Ledger();
  final PatchbaySemanticsTargetResolver resolver =
      PatchbaySemanticsTargetResolver(
        ensureOwner: () async => owner,
        observe: ledger.observe,
        entryFor: ledger.entryFor,
        treeRevision: () => 7,
      );
  final PatchbaySemanticsResolution resolution = await resolver.byIdentifier(
    identifier: _targetId,
    expectedGeneration: null,
    action: action,
  );
  expect(resolution.resolved, isTrue, reason: '${resolution.code}');
  return resolution;
}
