// PB-050-38：semantics 准入管线的**表征测试**——按状态机阶段拆分之前先把外部形状钉住。
//
// 这份文件不表达任何新期望。它逐字记录 `PatchbaySemanticsBridge` 当前对外产出的
// 稳定拒绝码、`details` 的键序与取值，以及 accepted 载荷的键序与取值。拆分 MR 必须
// 让它在拆分**前后同样绿**——否则那次拆分就不是零语义变化。
//
// 断言口径是 `jsonEncode` 而不是 `Map` 相等：稳定 JSON 的键序也是契约的一部分，
// `Map` 相等看不见键序漂移。动态取值（nodeId / generation / treeRevision）由本次
// 快照读出后回填进期望串，因此比对的是「同一次运行里的逐字节相同」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/semantics/semantics_bridge.dart'
    show debugPatchbaySemanticsOwnerSource;

import '../fixture/flutter_bridge_fixtures.dart';

const String _requestId = 'characterization-request';

PatchbaySemanticsActionDecision _allowAll(
  PatchbaySemanticsTarget target,
  PatchbaySemanticsAction action,
) => const PatchbaySemanticsActionDecision.allow();

PatchbaySemanticsBridge _bridge({
  PatchbayGateDecision Function()? baseGate,
  FutureOr<PatchbayGateDecision> Function(String gateId)? consumerGate,
  PatchbaySemanticsActionPolicy? policy = _allowAll,
  bool resumed = true,
  bool Function()? isAppResumed,
}) => PatchbaySemanticsBridge(
  gates: PatchbayGateEvaluator(
    baseGate: baseGate ?? () => const PatchbayGateDecision.allow(),
    consumerGate: consumerGate ?? (_) => const PatchbayGateDecision.allow(),
  ),
  actionPolicy: policy,
  isAppResumed: isAppResumed ?? () => resumed,
  newRequestId: () => _requestId,
);

String _json(Object? value) => jsonEncode(value);

/// 键序也是契约：把键按出现顺序拼成一行，比对失败时的 diff 也读得懂。
String _keys(Map<String, Object?> map) => map.keys.join(',');

Future<List<Map<String, Object?>>> _nodes(
  WidgetTester tester,
  PatchbaySemanticsBridge bridge,
) async {
  final PatchbayInvocation tree = await pumpUntilComplete(
    tester,
    bridge.snapshot(),
  );
  expect(tree.admission, PatchbayAdmission.accepted, reason: '$tree');
  return (tree.payload['nodes']! as List<Object?>).cast<Map<String, Object?>>();
}

Future<Map<String, Object?>> _nodeWithIdentifier(
  WidgetTester tester,
  PatchbaySemanticsBridge bridge,
  String identifier,
) async => (await _nodes(
  tester,
  bridge,
)).singleWhere((Map<String, Object?> node) => node['identifier'] == identifier);

Widget _target({
  String identifier = 'characterization.target',
  String label = 'Target',
  VoidCallback? onTap,
  ValueChanged<String>? onSetText,
  bool obscured = false,
  bool blocked = false,
}) => MaterialApp(
  home: Semantics(
    blockUserActions: blocked,
    child: Semantics(
      identifier: identifier,
      label: label,
      obscured: obscured,
      textField: onSetText != null,
      onTap: onTap,
      onSetText: onSetText,
      child: const SizedBox(width: 40, height: 40),
    ),
  ),
);

void main() {
  group('snapshot 阶段的表征', () {
    testWidgets('越界的 maxDepth/maxNodes 逐字报告 invalid 列表', (tester) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.snapshot(maxDepth: -1, maxNodes: 0),
      );

      expect(result.requestId, _requestId);
      expect(result.rejection?.code, 'invalidUiTreeLimits');
      expect(
        result.rejection?.notice,
        'maxDepth must be non-negative and maxNodes must be 1..10000.',
      );
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'invalid': <String>['maxDepth', 'maxNodes'],
        }),
      );
      bridge.dispose();
    });

    testWidgets('base gate 拒绝时带 patchbay.base 的 gateId', (tester) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge(
        baseGate: () => const PatchbayGateDecision.reject(
          code: 'hostNotConnected',
          notice: 'no host',
        ),
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.snapshot(),
      );

      expect(result.rejection?.code, 'hostNotConnected');
      expect(result.rejection?.notice, 'no host');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'gateId': 'patchbay.base'}),
      );
      bridge.dispose();
    });

    testWidgets('非 resumed 时报告 lifecycleState', (tester) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge(resumed: false);
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.snapshot(),
      );

      expect(result.rejection?.code, 'uiLifecycleNotResumed');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'lifecycleState': 'unknown'}),
      );
      bridge.dispose();
    });

    testWidgets('owner 缺失时按 uiSemanticsUnavailable 拒绝且不带 details', (
      tester,
    ) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      addTearDown(() => debugPatchbaySemanticsOwnerSource = null);
      debugPatchbaySemanticsOwnerSource = () => null;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.snapshot(),
      );

      expect(result.rejection?.code, 'uiSemanticsUnavailable');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      debugPatchbaySemanticsOwnerSource = null;
      bridge.dispose();
    });

    testWidgets('accepted 快照的顶层键序与节点键序冻结', (tester) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation tree = await pumpUntilComplete(
        tester,
        bridge.snapshot(),
      );

      expect(
        _keys(tree.payload),
        'outcome,source,treeRevision,rootNodeId,truncated,nodeCount,nodes',
      );
      expect(tree.payload['outcome'], 'observed');
      expect(tree.payload['source'], 'uiObserved');
      expect(tree.payload['truncated'], isFalse);
      final Map<String, Object?> node =
          (tree.payload['nodes']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .singleWhere(
                (Map<String, Object?> n) =>
                    n['identifier'] == 'characterization.target',
              );
      expect(
        _keys(node),
        'nodeId,generation,parentNodeId,depth,identifier,label,value,flags,actions,invisible,userActionsBlocked,rect,rectCoordinateSpace,children',
      );
      expect(node['rectCoordinateSpace'], 'semanticsNodeLocal');
      bridge.dispose();
    });
  });

  group('参数与 policy 存在性阶段的表征', () {
    testWidgets('没有 action policy 时按 uiSemanticsActionsDisabled 拒绝', (
      tester,
    ) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge(policy: null);
      addTearDown(bridge.dispose);

      expect(bridge.actionsEnabled, isFalse);
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'uiSemanticsActionsDisabled');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      bridge.dispose();
    });

    testWidgets('invokeIdentifier 的三项参数校验按固定顺序汇报', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: '',
          generation: -1,
          action: PatchbaySemanticsAction.dismiss,
        ),
      );

      expect(result.rejection?.code, 'invalidUiArguments');
      expect(
        result.rejection?.notice,
        'identifier must be non-empty, generation non-negative, and '
        'action publicly declared.',
      );
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'invalid': <String>['identifier', 'generation', 'action'],
        }),
      );
      bridge.dispose();
    });

    testWidgets('tapIdentifier 的参数校验回显入参且省略 null 代际', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation omitted = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: ''),
      );
      final PatchbayInvocation negative = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'x', expectedGeneration: -3),
      );

      expect(omitted.rejection?.code, 'invalidUiArguments');
      expect(
        omitted.rejection?.notice,
        'identifier must be non-empty and generation non-negative.',
      );
      expect(
        _json(omitted.rejection?.details),
        _json(<String, Object?>{'identifier': ''}),
      );
      expect(
        _json(negative.rejection?.details),
        _json(<String, Object?>{'identifier': 'x', 'expectedGeneration': -3}),
      );
      bridge.dispose();
    });
  });

  group('resolve target 阶段的表征', () {
    testWidgets('identifier 未挂载时报告已挂载清单与截断标记', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _nodes(tester, bridge);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.missing'),
      );

      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'identifier': 'characterization.missing',
          'treeRevision': bridge.treeRevision,
          'matchCount': 0,
          'mountedIdentifierCount': 1,
          'mountedIdentifiers': <String>['characterization.target'],
          'mountedIdentifiersTruncated': false,
        }),
      );
      bridge.dispose();
    });

    testWidgets('已挂载 identifier 超过 20 个时排序取前 20 并置位截断', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              for (var i = 0; i < 25; i += 1)
                Semantics(
                  identifier: 'id.${i.toString().padLeft(2, '0')}',
                  label: 'n$i',
                  child: const SizedBox(width: 1, height: 1),
                ),
            ],
          ),
        ),
      );
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'id.99'),
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      expect(details['mountedIdentifierCount'], 25);
      expect(details['mountedIdentifiersTruncated'], isTrue);
      expect(
        _json(details['mountedIdentifiers']),
        _json(<String>[
          for (var i = 0; i < 20; i += 1) 'id.${i.toString().padLeft(2, '0')}',
        ]),
      );
      expect(
        _keys(details),
        'identifier,treeRevision,matchCount,mountedIdentifierCount,mountedIdentifiers,mountedIdentifiersTruncated',
      );
      bridge.dispose();
    });

    testWidgets('identifier 歧义时逐个列出候选事实', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              for (var i = 0; i < 2; i += 1)
                Semantics(
                  identifier: 'dup.target',
                  label: 'Dup',
                  onTap: () {},
                  child: const SizedBox(width: 10, height: 10),
                ),
            ],
          ),
        ),
      );
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'dup.target'),
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsIdentifierAmbiguous');
      expect(_keys(details), 'identifier,treeRevision,matchCount,candidates');
      expect(details['matchCount'], 2);
      final List<Object?> candidates = details['candidates']! as List<Object?>;
      expect(candidates, hasLength(2));
      for (final Object? candidate in candidates) {
        expect(
          _keys(candidate! as Map<String, Object?>),
          'nodeId,generation,label,actions,invisible,userActionsBlocked',
        );
      }
      bridge.dispose();
    });

    testWidgets('identifier 路径的代际漂移带 identifier 与两个代际', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );
      final int generation = node['generation']! as int;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(
          identifier: 'characterization.target',
          expectedGeneration: generation + 1,
        ),
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'identifier': 'characterization.target',
          'nodeId': node['nodeId'],
          'expectedGeneration': generation + 1,
          'currentGeneration': generation,
        }),
      );
      bridge.dispose();
    });

    testWidgets('nodeId 路径的代际漂移不带 identifier', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );
      final int generation = node['generation']! as int;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invoke(
          nodeId: node['nodeId']! as int,
          generation: generation + 1,
          action: PatchbaySemanticsAction.tap,
        ),
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'nodeId': node['nodeId'],
          'expectedGeneration': generation + 1,
          'currentGeneration': generation,
        }),
      );
      bridge.dispose();
    });

    testWidgets('nodeId 不在树上与未被观察是两个不同的裸码', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge observer = _bridge();
      addTearDown(observer.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        observer,
        'characterization.target',
      );

      final PatchbayInvocation missing = await pumpUntilComplete(
        tester,
        observer.invoke(
          nodeId: 987654,
          generation: 1,
          action: PatchbaySemanticsAction.tap,
        ),
      );
      expect(missing.rejection?.code, 'uiSemanticsNodeNotFound');
      expect(_json(missing.rejection?.details), _json(<String, Object?>{}));
      observer.dispose();

      final PatchbaySemanticsBridge fresh = _bridge();
      addTearDown(fresh.dispose);
      final PatchbayInvocation unobserved = await pumpUntilComplete(
        tester,
        fresh.invoke(
          nodeId: node['nodeId']! as int,
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.tap,
        ),
      );
      expect(unobserved.rejection?.code, 'uiSemanticsNodeNotObserved');
      expect(_json(unobserved.rejection?.details), _json(<String, Object?>{}));
      fresh.dispose();
    });

    testWidgets('被屏蔽的节点自报候选事实', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}, blocked: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsActionBlocked');
      expect(
        _keys(details),
        'nodeId,generation,label,actions,invisible,userActionsBlocked',
      );
      expect(details['userActionsBlocked'], isTrue);
      expect(details['label'], 'Target');
      bridge.dispose();
    });

    testWidgets('缺少所需 action 的节点在候选事实上追加 requestedAction', (tester) async {
      await tester.pumpWidget(_target());
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      expect(
        _keys(details),
        'nodeId,generation,label,actions,invisible,userActionsBlocked,requestedAction',
      );
      expect(details['requestedAction'], 'tap');
      expect(_json(details['actions']), _json(<String>[]));
      bridge.dispose();
    });

    testWidgets('遮蔽节点的候选事实用 labelRedacted 顶替 label', (tester) async {
      await tester.pumpWidget(_target(obscured: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      expect(
        _keys(details),
        'nodeId,generation,labelRedacted,actions,invisible,userActionsBlocked,requestedAction',
      );
      expect(details['labelRedacted'], isTrue);
      expect(details.containsKey('label'), isFalse);
      bridge.dispose();
    });
  });

  group('policy / gate / 敏感输入阶段的表征', () {
    testWidgets('policy 拒绝时透传 code 与 notice 且不带 details', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) => const PatchbaySemanticsActionDecision.reject(
          rejectionCode: 'consumerSaidNo',
          rejectionNotice: 'not in this screen',
        ),
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'consumerSaidNo');
      expect(result.rejection?.notice, 'not in this screen');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      bridge.dispose();
    });

    testWidgets('声明门拒绝时带声明的 gateId', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
          gateIds: <String>{'app.destructive'},
        ),
        consumerGate: (String gateId) =>
            const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'consumerGateRejected');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'gateId': 'app.destructive'}),
      );
      bridge.dispose();
    });

    testWidgets('setText 缺 text 与非 setText 多带 text 是两个裸码', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}, onSetText: (_) {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation missingText = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: 'characterization.target',
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.setText,
        ),
      );
      expect(missingText.rejection?.code, 'uiSemanticsTextRequired');
      expect(_json(missingText.rejection?.details), _json(<String, Object?>{}));

      final PatchbayInvocation extraText = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: 'characterization.target',
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.tap,
          text: 'unexpected',
        ),
      );
      expect(extraText.rejection?.code, 'uiSemanticsUnexpectedText');
      expect(_json(extraText.rejection?.details), _json(<String, Object?>{}));
      bridge.dispose();
    });

    testWidgets('遮蔽目标的 setText 不走 stdin 时按 sensitiveInputRequiresStdin 拒绝', (
      tester,
    ) async {
      await tester.pumpWidget(_target(onSetText: (_) {}, obscured: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: 'characterization.target',
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.setText,
          text: 'secret',
        ),
      );

      expect(result.rejection?.code, 'sensitiveInputRequiresStdin');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      bridge.dispose();
    });

    testWidgets('门后 policy 改变声明集时按 uiSemanticsPolicyChanged 拒绝', (
      tester,
    ) async {
      await tester.pumpWidget(_target(onTap: () {}));
      var calls = 0;
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) {
          calls += 1;
          return calls <= 1
              ? const PatchbaySemanticsActionDecision.allow()
              : const PatchbaySemanticsActionDecision.allow(
                  gateIds: <String>{'app.late'},
                );
        },
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'uiSemanticsPolicyChanged');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      bridge.dispose();
    });
  });

  group('遮挡准入与派发阶段的表征', () {
    testWidgets('点性 action 被不透明覆盖层挡住时报告 reason/nodeId/generation', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                child: Semantics(
                  identifier: 'characterization.target',
                  label: 'Covered',
                  button: true,
                  onTap: () => taps += 1,
                  child: const SizedBox(width: 100, height: 100),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Container(
                    width: 100,
                    height: 100,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'uiSemanticsTargetObscured');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{
          'reason': 'hitTestOrClip',
          'nodeId': node['nodeId'],
          'generation': node['generation'],
          'identifier': 'characterization.target',
        }),
      );
      expect(taps, 0);
      bridge.dispose();
    });

    testWidgets('派发成功的载荷键序与取值冻结（identifier 路径）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );
      final int before = bridge.treeRevision;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(taps, 1);
      expect(
        _json(result.payload),
        _json(<String, Object?>{
          'outcome': 'dispatched',
          'source': 'uiObserved',
          'identifier': 'characterization.target',
          'nodeId': node['nodeId'],
          'generation': node['generation'],
          'action': 'tap',
          'beforeTreeRevision': before,
          'afterTreeRevision': bridge.treeRevision,
        }),
      );
      bridge.dispose();
    });

    testWidgets('nodeId 路径的派发载荷省略 identifier 键', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invoke(
          nodeId: node['nodeId']! as int,
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.tap,
        ),
      );

      expect(taps, 1);
      expect(
        _keys(result.payload),
        'outcome,source,nodeId,generation,action,beforeTreeRevision,afterTreeRevision',
      );
      bridge.dispose();
    });

    testWidgets('setText 的载荷按遮蔽与否给出 length 或 valueRedacted+length', (
      tester,
    ) async {
      final List<String> plain = <String>[];
      await tester.pumpWidget(_target(onSetText: plain.add));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: 'characterization.target',
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.setText,
          text: 'plain text',
        ),
      );

      expect(plain, <String>['plain text']);
      expect(
        _keys(result.payload),
        'outcome,source,identifier,nodeId,generation,action,beforeTreeRevision,afterTreeRevision,length',
      );
      expect(result.payload['length'], 'plain text'.length);
      expect(result.payload.containsKey('valueRedacted'), isFalse);
      bridge.dispose();
    });

    testWidgets('遮蔽目标经 stdin 派发时只报长度并置 valueRedacted', (tester) async {
      final List<String> secrets = <String>[];
      await tester.pumpWidget(_target(onSetText: secrets.add, obscured: true));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.invokeIdentifier(
          identifier: 'characterization.target',
          generation: node['generation']! as int,
          action: PatchbaySemanticsAction.setText,
          text: 'top secret',
          inputWasStdin: true,
        ),
      );

      expect(secrets, <String>['top secret']);
      expect(
        _keys(result.payload),
        'outcome,source,identifier,nodeId,generation,action,beforeTreeRevision,afterTreeRevision,valueRedacted,length',
      );
      expect(result.payload['valueRedacted'], isTrue);
      expect(result.payload['length'], 'top secret'.length);
      bridge.dispose();
    });

    testWidgets('handler 抛出时受理成 failed 并只报异常类型', (tester) async {
      await tester.pumpWidget(
        _target(onTap: () => throw StateError('characterization boom')),
      );
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(
        _json(result.payload),
        _json(<String, Object?>{
          'outcome': 'failed',
          'source': 'uiObserved',
          'identifier': 'characterization.target',
          'nodeId': node['nodeId'],
          'generation': node['generation'],
          'action': 'tap',
          'failureType': 'StateError',
        }),
      );
      bridge.dispose();
    });
  });

  group('dispatch 路径的门前围栏表征', () {
    testWidgets('base gate 拒绝在 dispatch 路径上同样带 patchbay.base', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(
        baseGate: () => const PatchbayGateDecision.reject(
          code: 'hostNotConnected',
          notice: 'no host',
        ),
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'hostNotConnected');
      expect(result.rejection?.notice, 'no host');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'gateId': 'patchbay.base'}),
      );
      expect(taps, 0);
      bridge.dispose();
    });

    testWidgets('非 resumed 在 dispatch 路径上同样报告 lifecycleState', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(resumed: false);
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(result.rejection?.code, 'uiLifecycleNotResumed');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'lifecycleState': 'unknown'}),
      );
      expect(taps, 0);
      bridge.dispose();
    });
  });

  group('声明门 await 之后的复核表征', () {
    testWidgets('门后生命周期复核失败：拒绝形状与门前那次逐字相同', (tester) async {
      var taps = 0;
      var resumed = true;
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
          gateIds: <String>{'app.declared'},
        ),
        consumerGate: (_) => gate.future,
        isAppResumed: () => resumed,
      );
      addTearDown(bridge.dispose);

      final Future<PatchbayInvocation> pending = bridge.tapIdentifier(
        identifier: 'characterization.target',
      );
      await tester.pump();
      resumed = false;
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiLifecycleNotResumed');
      expect(
        _json(result.rejection?.details),
        _json(<String, Object?>{'lifecycleState': 'unknown'}),
      );
      expect(taps, 0);
      bridge.dispose();
    });

    testWidgets('门后目标消失：二次解析的拒绝原样透传', (tester) async {
      var taps = 0;
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) => const PatchbaySemanticsActionDecision.allow(
          gateIds: <String>{'app.declared'},
        ),
        consumerGate: (_) => gate.future,
      );
      addTearDown(bridge.dispose);

      final Future<PatchbayInvocation> pending = bridge.tapIdentifier(
        identifier: 'characterization.target',
      );
      await tester.pump();
      await tester.pumpWidget(
        _target(identifier: 'characterization.moved', onTap: () => taps += 1),
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );

      final Map<String, Object?> details = result.rejection!.details;
      expect(result.rejection?.code, 'uiSemanticsIdentifierNotFound');
      expect(details['treeRevision'], isA<int>());
      expect(
        _json(details),
        _json(<String, Object?>{
          'identifier': 'characterization.target',
          // treeRevision 由本次运行读出后回填：钉的是键序与其余取值。
          'treeRevision': details['treeRevision'],
          'matchCount': 0,
          'mountedIdentifierCount': 1,
          'mountedIdentifiers': <String>['characterization.moved'],
          'mountedIdentifiersTruncated': false,
        }),
      );
      expect(taps, 0);
      bridge.dispose();
    });

    testWidgets('门后 policy 转为拒绝：透传新 code 与 notice，不报 policyChanged', (
      tester,
    ) async {
      var taps = 0;
      var calls = 0;
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) {
          calls += 1;
          return calls <= 1
              ? const PatchbaySemanticsActionDecision.allow(
                  gateIds: <String>{'app.declared'},
                )
              : const PatchbaySemanticsActionDecision.reject(
                  rejectionCode: 'consumerRevokedMidFlight',
                  rejectionNotice: 'screen left',
                );
        },
        consumerGate: (_) => gate.future,
      );
      addTearDown(bridge.dispose);

      final Future<PatchbayInvocation> pending = bridge.tapIdentifier(
        identifier: 'characterization.target',
      );
      await tester.pump();
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        pending,
      );

      expect(calls, 2);
      expect(result.rejection?.code, 'consumerRevokedMidFlight');
      expect(result.rejection?.notice, 'screen left');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      expect(taps, 0);
      bridge.dispose();
    });

    testWidgets('只有 sensitiveInput 变了、声明集没变：仍按 policyChanged 拒绝', (
      tester,
    ) async {
      var taps = 0;
      var calls = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge(
        policy: (_, _) {
          calls += 1;
          return calls <= 1
              ? const PatchbaySemanticsActionDecision.allow(
                  gateIds: <String>{'app.declared'},
                )
              : const PatchbaySemanticsActionDecision.allow(
                  gateIds: <String>{'app.declared'},
                  sensitiveInput: true,
                );
        },
      );
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(calls, 2);
      expect(result.rejection?.code, 'uiSemanticsPolicyChanged');
      expect(_json(result.rejection?.details), _json(<String, Object?>{}));
      expect(taps, 0);
      bridge.dispose();
    });
  });

  group('只读投影与生命周期入口的表征', () {
    testWidgets('observeIdentifier 命中与未命中的字段逐个冻结', (tester) async {
      await tester.pumpWidget(_target(obscured: true, onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final Map<String, Object?> node = await _nodeWithIdentifier(
        tester,
        bridge,
        'characterization.target',
      );

      final PatchbaySemanticsIdentifierObservation? hit =
          await pumpUntilComplete(
            tester,
            bridge.observeIdentifier('characterization.target'),
          );
      final PatchbaySemanticsIdentifierObservation? miss =
          await pumpUntilComplete(
            tester,
            bridge.observeIdentifier('characterization.missing'),
          );

      expect(hit, isNotNull);
      expect(hit!.treeRevision, bridge.treeRevision);
      expect(hit.matches, hasLength(1));
      final PatchbaySemanticsIdentifierMatch match = hit.matches.single;
      expect(match.nodeId, node['nodeId']);
      expect(match.generation, node['generation']);
      expect(match.value, '');
      expect(match.obscured, isTrue);
      expect(match.invisible, isFalse);
      // 只读观察不重排也不截断：未命中给的是空清单，不是 null 匹配。
      expect(miss?.matches, isEmpty);
      expect(miss?.treeRevision, bridge.treeRevision);
      // 观察本身不请帧，因此两次读数与同步读数一致。
      expect(
        await pumpUntilComplete(tester, bridge.observeTreeRevision()),
        bridge.treeRevision,
      );
      bridge.dispose();
    });

    testWidgets('owner 缺失时两个只读入口都返回 null 而不是编造读数', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      addTearDown(() => debugPatchbaySemanticsOwnerSource = null);
      debugPatchbaySemanticsOwnerSource = () => null;

      expect(
        await pumpUntilComplete(
          tester,
          bridge.observeIdentifier('characterization.target'),
        ),
        isNull,
      );
      expect(
        await pumpUntilComplete(tester, bridge.observeTreeRevision()),
        isNull,
      );

      debugPatchbaySemanticsOwnerSource = null;
      bridge.dispose();
    });

    testWidgets('actionsEnabled 只由 policy 的有无决定', (tester) async {
      await tester.pumpWidget(_target(onTap: () {}));
      final PatchbaySemanticsBridge without = _bridge(policy: null);
      addTearDown(without.dispose);
      final PatchbaySemanticsBridge with_ = _bridge();
      addTearDown(with_.dispose);

      expect(without.actionsEnabled, isFalse);
      expect(with_.actionsEnabled, isTrue);
      // 门与生命周期都不参与这个读数：它说的是「有没有策略」，不是「这次准不准」。
      final PatchbaySemanticsBridge closed = _bridge(
        baseGate: () =>
            const PatchbayGateDecision.reject(code: 'hostNotConnected'),
        resumed: false,
      );
      addTearDown(closed.dispose);
      expect(closed.actionsEnabled, isTrue);

      without.dispose();
      with_.dispose();
      closed.dispose();
    });

    testWidgets('dispose 之后的调用按 uiSemanticsUnavailable 拒绝，不抛异常', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(_target(onTap: () => taps += 1));
      final PatchbaySemanticsBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _nodes(tester, bridge);
      bridge.dispose();

      final PatchbayInvocation snapshot = await pumpUntilComplete(
        tester,
        bridge.snapshot(),
      );
      final PatchbayInvocation tap = await pumpUntilComplete(
        tester,
        bridge.tapIdentifier(identifier: 'characterization.target'),
      );

      expect(snapshot.rejection?.code, 'uiSemanticsUnavailable');
      expect(_json(snapshot.rejection?.details), _json(<String, Object?>{}));
      expect(tap.rejection?.code, 'uiSemanticsUnavailable');
      expect(
        _json(tap.rejection?.details),
        _json(<String, Object?>{'identifier': 'characterization.target'}),
      );
      expect(
        await pumpUntilComplete(
          tester,
          bridge.observeIdentifier('characterization.target'),
        ),
        isNull,
      );
      expect(
        await pumpUntilComplete(tester, bridge.observeTreeRevision()),
        isNull,
      );
      expect(taps, 0);
      // 重复 dispose 是幂等的。
      bridge.dispose();
    });
  });
}
