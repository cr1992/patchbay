// PB-050-38：`PatchbayFlutterServiceHost` 的**表征测试**——按职责阶段拆分之前先把
// 外部形状钉住。
//
// 这份文件不表达任何新期望。它逐字记录 host 今天对外产出的四样东西：
//
// 1. **目录**：命令名与出场顺序、每条 descriptor 的键序、参数名序与声明默认值，
//    `interactionModel` / `outputProjection` / `responseSchema` 三个键分别出现在
//    哪几条命令上，以及 capture / keepAwake / inspect 的运行期覆写。
// 2. **descriptor ↔ handler 的配对**：注册表靠「第 N 个 descriptor 配第 N 个
//    handler」的位置约定，错位不报错、只会让命令悄悄由别的桥应答。这里给每条命令
//    一组「形状合法但现场不存在」的参数，用它自己那座桥的稳定拒绝码钉住配对。
// 3. **参数校验**：`invalidUiArguments` 的 `details` 键序与三类指名、形状规则的
//    `reason` 与 `notice`，以及 handler 里那几个字面缺省值（64/1000、500/300/100）。
// 4. **门面**：`features`、审计事件形状（含 `admissionStage` / `gateDisposition`）、
//    未注册命令的兜底拒绝、`drain*` / `cancelInvocation` 的结果形状。
//
// 断言口径是 `jsonEncode` 而不是 `Map` 相等：稳定 JSON 的键序也是契约的一部分。
// 随运行变化的值（catalogDigest、observedAt、leaseRemainingMs）只钉键序不钉取值。
//
// 拆分 MR 必须让这份文件在拆分**前后同样绿**——否则那次拆分就不是零语义变化。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import 'fixture/flutter_bridge_fixtures.dart';

final PatchbayGateEvaluator _gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

final class _NavigationState {
  String destination = 'home';
  int revision = 1;

  PatchbayNavigationObservation observe() => PatchbayNavigationObservation(
    revision: revision,
    destinationId: destination,
  );
}

/// 钉住 `withDomainCatalogProvider` 那条路径的 domain provider。
final class _RecordingCatalogProvider implements PatchbayCatalogProvider {
  _RecordingCatalogProvider(this.revision, this.catalog);

  final int revision;
  final Map<String, Object?> catalog;
  int reads = 0;

  @override
  int get commandsRevision => revision;

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    reads += 1;
    return PatchbayCatalogSample(commandsRevision: revision, catalog: catalog);
  }
}

/// gesture 每一段的等待时长——handler 里 `durationMs ?? …` 的观测口。
final List<Duration> _gestureDelays = <Duration>[];

/// 所有可选能力都接上的桥：目录里应当出现全部 UI 命令。
PatchbayFlutterBridge _wiredBridge({
  Set<String> captureGates = const <String>{'app.capture'},
  Set<String> keepAwakeGates = const <String>{'app.awake'},
  PatchbayInspectPolicy inspectPolicy = const PatchbayInspectPolicy(),
  PatchbayUiRegistry? registry,
}) => _owned(
  PatchbayFlutterBridge(
    registry: registry ?? PatchbayUiRegistry(),
    gates: _gates,
    semanticsActionPolicy: (_, _) =>
        const PatchbaySemanticsActionDecision.allow(),
    gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
    gestureDelay: (Duration duration) async => _gestureDelays.add(duration),
    gesturePointerDispatcher: (PointerEvent _) {},
    revealPolicy: (_, _) => const PatchbayRevealDecision.allow(),
    navigationAdapter: PatchbayNavigationAdapter(
      destinations: () => <PatchbayNavigationDestination>[
        PatchbayNavigationDestination(id: 'home', go: () {}),
      ],
      current: _NavigationState().observe,
    ),
    inspectPolicy: inspectPolicy,
    artifacts: PatchbayArtifactService(
      blobs: PatchbayMemoryBlobStore(),
      gates: _gates,
    ),
    captureGates: captureGates,
    keepAwakeGates: keepAwakeGates,
    isAppResumed: () => true,
  ),
);

/// 接入方什么可选能力都没注入：目录只剩总是注册的那几条。
PatchbayFlutterBridge _bareBridge() => _owned(
  PatchbayFlutterBridge(
    registry: PatchbayUiRegistry(),
    gates: _gates,
    isAppResumed: () => true,
  ),
);

final List<PatchbayFlutterBridge> _live = <PatchbayFlutterBridge>[];
PatchbayFlutterBridge _owned(PatchbayFlutterBridge bridge) {
  _live.add(bridge);
  return bridge;
}

/// 桥持有 SemanticsHandle 与两个租约计时器，必须在用例体内归还：`testWidgets` 的
/// 句柄/计时器校验发生在 `tearDown` **之前**，`addTearDown` 来不及。
void _release() {
  for (final PatchbayFlutterBridge bridge in _live) {
    bridge.dispose();
  }
  _live.clear();
}

PatchbayFlutterServiceHost _host(PatchbayFlutterBridge bridge) =>
    PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.characterization',
      bridge: bridge,
    );

Future<Map<String, Object?>> _catalog(PatchbayFlutterServiceHost host) =>
    host.dispatchCatalog();
Future<List<Map<String, Object?>>> _commands(
  PatchbayFlutterServiceHost host,
) async => ((await _catalog(host))['commands']! as List<Object?>)
    .cast<Map<String, Object?>>();

List<String> _names(List<Map<String, Object?>> commands) => <String>[
  for (final Map<String, Object?> command in commands)
    command['name']! as String,
];

/// 一条 descriptor 压成一行「键序 :: 参数名序 :: 声明默认值」，失败的 diff 就直接
/// 说得出是哪条命令的哪一段变了。
String _shape(Map<String, Object?> command) {
  final List<Map<String, Object?>> parameters =
      (command['parameters']! as List<Object?>).cast<Map<String, Object?>>();
  final String defaults = jsonEncode(<String, Object?>{
    for (final Map<String, Object?> parameter in parameters)
      if (parameter.containsKey('default'))
        parameter['name']! as String: parameter['default'],
  });
  return '${command.keys.join('|')} :: '
      '${parameters.map((Map<String, Object?> p) => p['name']).join('|')} :: '
      '$defaults';
}

/// `testWidgets` 的包装：用例体一结束就归还桥。
void _hostTest(String description, Future<void> Function(WidgetTester) body) =>
    testWidgets(description, (WidgetTester tester) async {
      try {
        await body(tester);
      } finally {
        _release();
      }
    });

void main() {
  setUp(_gestureDelays.clear);

  group('目录：命令集合与出场顺序', () {
    _hostTest('全部能力接上时的 25 条命令', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(_names(await _commands(_host(_wiredBridge()))), <String>[
        'ui.text.set',
        'ui.text.enter',
        'ui.semantics.tree',
        'ui.semantics.action',
        'ui.semantics.actionByIdentifier',
        'ui.semantics.tap',
        'ui.gesture.pressHold',
        'ui.gesture.drag',
        'ui.gesture.fling',
        'ui.gesture.tap',
        'ui.reveal',
        'ui.wait',
        'ui.keepAwake.set',
        'ui.keepAwake.status',
        'ui.capture',
        'ui.capture.diff',
        'ui.inspect.status',
        'ui.inspect.select',
        'navigation.catalog',
        'navigation.current',
        'navigation.go',
        'navigation.push',
        'navigation.back',
        'blob.metadata',
        'blob.read',
      ]);
    });

    _hostTest('接入方没注入可选能力时目录只剩 6 条', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      // `available:` 是逐条的：semantics action 家族跟 actionsEnabled，gesture 跟
      // gesturePolicy，reveal 跟 revealPolicy，capture 跟 artifacts，inspect 跟
      // inspectPolicy，navigation 跟 adapter。keepAwake 反过来——它总在目录里，
      // 用 `wired: false` 作诊断而不是缺一行。
      expect(_names(await _commands(_host(_bareBridge()))), <String>[
        'ui.text.set',
        'ui.text.enter',
        'ui.semantics.tree',
        'ui.wait',
        'ui.keepAwake.set',
        'ui.keepAwake.status',
      ]);
    });

    _hostTest('目录顶层键序', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(
        (await _catalog(_host(_wiredBridge()))).keys.join(','),
        'uiTargets,commands,schemaVersion,catalogDigest',
      );
    });
  });

  group('目录：每条 descriptor 的键序、参数序与声明默认值', () {
    _hostTest('逐条比对', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      const String base =
          'name|summary|plane|mode|sideEffect|factSources|gates|parameters|'
          'weakConfirmationCompletes';
      final Map<String, String> expected = <String, String>{
        'ui.text.set':
            '$base|interactionModel :: '
            'id|generation|text|inputWasStdin :: {}',
        'ui.text.enter':
            '$base|interactionModel :: '
            'id|generation|text|inputWasStdin :: {}',
        'ui.semantics.tree':
            '$base|outputProjection :: maxDepth|maxNodes|inputWasStdin :: '
            '{"maxDepth":64,"maxNodes":1000}',
        'ui.semantics.action':
            '$base|interactionModel :: '
            'nodeId|generation|action|text|inputWasStdin :: {}',
        'ui.semantics.actionByIdentifier':
            '$base|interactionModel :: '
            'identifier|generation|action|text|inputWasStdin :: {}',
        'ui.semantics.tap':
            '$base|interactionModel :: identifier|generation :: {}',
        'ui.gesture.pressHold':
            '$base|interactionModel :: identifier|generation|start|durationMs '
            ':: {"durationMs":500}',
        'ui.gesture.drag':
            '$base|interactionModel :: '
            'identifier|generation|start|path|durationMs :: '
            '{"durationMs":300}',
        'ui.gesture.fling':
            '$base|interactionModel :: '
            'identifier|generation|start|velocity|durationMs :: '
            '{"durationMs":100}',
        'ui.gesture.tap':
            '$base|interactionModel :: identifier|generation|start :: '
            '{"start":{"x":0.5,"y":0.5}}',
        // responseSchema 排在 parameters 之后、weakConfirmationCompletes 之前。
        'ui.reveal':
            'name|summary|plane|mode|sideEffect|factSources|gates|parameters|'
            'responseSchema|weakConfirmationCompletes|interactionModel :: '
            'identifier|container|direction|maxSteps|timeoutMs :: '
            '{"direction":"both","maxSteps":40,"timeoutMs":5000}',
        'ui.wait':
            '$base :: '
            'condition|timeoutMs|semanticsIdentifier|value|destinationId|'
            'revision :: {"timeoutMs":5000}',
        'ui.keepAwake.set': '$base :: enabled|leaseMs :: {"leaseMs":600000}',
        'ui.keepAwake.status': '$base ::  :: {}',
        'ui.capture':
            '$base|outputProjection :: '
            'targetId|generation|pixelRatio|timeoutMs|afterFrames :: '
            '{"pixelRatio":1,"timeoutMs":5000,"afterFrames":1}',
        'ui.capture.diff': '$base :: beforeBlobId|afterBlobId :: {}',
        'ui.inspect.status': '$base ::  :: {}',
        'ui.inspect.select': '$base :: enabled|ttlMs :: {"ttlMs":300000}',
        'navigation.catalog': '$base ::  :: {}',
        'navigation.current': '$base ::  :: {}',
        'navigation.go':
            '$base :: destinationId|revision|timeoutMs :: {"timeoutMs":5000}',
        'navigation.push':
            '$base :: destinationId|revision|timeoutMs :: {"timeoutMs":5000}',
        'navigation.back': '$base :: revision|timeoutMs :: {"timeoutMs":5000}',
      };

      final List<Map<String, Object?>> commands = await _commands(
        _host(_wiredBridge()),
      );
      for (final MapEntry<String, String> entry in expected.entries) {
        final Map<String, Object?> command = commands.singleWhere(
          (Map<String, Object?> candidate) => candidate['name'] == entry.key,
        );
        expect(_shape(command), entry.value, reason: entry.key);
      }
    });

    _hostTest('三个可选键各自的归属', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final List<Map<String, Object?>> commands = await _commands(
        _host(_wiredBridge()),
      );
      List<String> carrying(String key) => <String>[
        for (final Map<String, Object?> command in commands)
          if (command.containsKey(key)) command['name']! as String,
      ];

      expect(carrying('interactionModel'), <String>[
        'ui.text.set',
        'ui.text.enter',
        'ui.semantics.action',
        'ui.semantics.actionByIdentifier',
        'ui.semantics.tap',
        'ui.gesture.pressHold',
        'ui.gesture.drag',
        'ui.gesture.fling',
        'ui.gesture.tap',
        'ui.reveal',
      ]);
      expect(carrying('outputProjection'), <String>[
        'ui.semantics.tree',
        'ui.capture',
      ]);
      expect(carrying('responseSchema'), <String>['ui.reveal']);

      final Map<String, Object?> tree = commands.singleWhere(
        (Map<String, Object?> c) => c['name'] == 'ui.semantics.tree',
      );
      expect(
        jsonEncode(tree['outputProjection']),
        <String>[
          '{"brief":{"id":"ui.semantics.tree","omit":["\$.payload.nodes"]},',
          '"artifact":{"kind":"renderedMember","member":"\$.payload.nodes",',
          '"encoding":"json","mediaType":"application/json",',
          '"extension":"json","automaticSpill":true}}',
        ].join(),
      );

      final Map<String, Object?> capture = commands.singleWhere(
        (Map<String, Object?> c) => c['name'] == 'ui.capture',
      );
      expect(
        jsonEncode(capture['outputProjection']),
        '{"artifact":{"kind":"payloadBlob"}}',
      );

      final Map<String, Object?> reveal = commands.singleWhere(
        (Map<String, Object?> c) => c['name'] == 'ui.reveal',
      );
      expect(
        jsonEncode(reveal['responseSchema']),
        <String>[
          '{"accepted":{"type":"object","properties":{"steps":',
          '{"type":"integer"},"containers":{"type":"array","items":',
          '{"type":"object","properties":{"nodeId":{"type":"integer"}},',
          '"required":["nodeId"],"additionalProperties":true}}},',
          '"required":["containers","steps"],"additionalProperties":true}}',
        ].join(),
      );
    });

    _hostTest('运行期覆写：gates 与参数默认都跟着桥走', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final List<Map<String, Object?>> commands = await _commands(
        _host(
          _wiredBridge(
            captureGates: const <String>{'app.shot'},
            keepAwakeGates: const <String>{'app.awake', 'app.power'},
            inspectPolicy: const PatchbayInspectPolicy(
              gates: <String>{'app.inspect'},
              defaultLease: Duration(seconds: 42),
            ),
          ),
        ),
      );
      Map<String, Object?> byName(String name) => commands.singleWhere(
        (Map<String, Object?> command) => command['name'] == name,
      );

      // capture 与 capture.diff 共用同一组门：diff 是内联声明的，跟随同一个集合。
      expect(jsonEncode(byName('ui.capture')['gates']), '["app.shot"]');
      expect(jsonEncode(byName('ui.capture.diff')['gates']), '["app.shot"]');
      expect(
        jsonEncode(byName('ui.keepAwake.set')['gates']),
        '["app.awake","app.power"]',
      );
      expect(
        jsonEncode(byName('ui.inspect.select')['gates']),
        '["app.inspect"]',
      );
      expect(
        _shape(byName('ui.inspect.select')).endsWith('{"ttlMs":42000}'),
        isTrue,
      );
    });
  });

  group('目录：uiTargets 投影', () {
    _hostTest('两条构造路径都把桥的目标表贴到 domain 目录上', (WidgetTester tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpTextField(tester, key: key, controller: controller);

      final PatchbayFlutterBridge bridge = _wiredBridge(registry: registry);
      final String projected = jsonEncode(
        bridge
            .catalog()
            .map((PatchbayUiTargetDescriptor target) => target.toJson())
            .toList(),
      );
      expect(projected, contains('form.code'));

      final Map<String, Object?> plain = await _catalog(
        PatchbayFlutterServiceHost(
          applicationId: 'dev.patchbay.characterization',
          bridge: bridge,
          domainCatalog: () async => <String, Object?>{'domainKey': 1},
        ),
      );
      expect(jsonEncode(plain['uiTargets']), projected);
      expect(plain['domainKey'], 1);
      // domain 的键在前、uiTargets 追加在后。
      expect(plain.keys.first, 'domainKey');

      final _RecordingCatalogProvider provider = _RecordingCatalogProvider(
        7,
        <String, Object?>{'domainKey': 2},
      );
      final Map<String, Object?> viaProvider = await _catalog(
        PatchbayFlutterServiceHost.withDomainCatalogProvider(
          applicationId: 'dev.patchbay.characterization',
          bridge: bridge,
          domainCatalogProvider: provider,
        ),
      );
      expect(jsonEncode(viaProvider['uiTargets']), projected);
      expect(viaProvider['domainKey'], 2);
      expect(provider.reads, 1);
    });
  });

  group('descriptor 与 handler 的配对', () {
    _hostTest('每条命令由它自己那座桥应答', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      // 参数都是形状合法的，所以拒绝一定来自桥而不是解码；错位的注册会让某条命令
      // 报出另一条命令的码。
      for (final (String command, Map<String, Object?> arguments, String code)
          in <(String, Map<String, Object?>, String)>[
            (
              'ui.text.set',
              <String, Object?>{'id': 'nope', 'generation': 1, 'text': 'a'},
              'uiTargetNotFound',
            ),
            (
              'ui.text.enter',
              <String, Object?>{'id': 'nope', 'generation': 1, 'text': 'a'},
              'uiTargetNotFound',
            ),
            (
              'ui.semantics.action',
              <String, Object?>{
                'nodeId': 4242,
                'generation': 1,
                'action': 'tap',
              },
              'uiSemanticsNodeNotFound',
            ),
            (
              'ui.semantics.actionByIdentifier',
              <String, Object?>{
                'identifier': 'nope',
                'generation': 1,
                'action': 'tap',
              },
              'uiSemanticsIdentifierNotFound',
            ),
            (
              'ui.semantics.tap',
              <String, Object?>{'identifier': 'nope', 'generation': 1},
              'uiSemanticsIdentifierNotFound',
            ),
            (
              'ui.gesture.pressHold',
              <String, Object?>{
                'identifier': 'nope',
                'generation': 1,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
              },
              'uiTargetNotFound',
            ),
            (
              'ui.gesture.tap',
              <String, Object?>{'identifier': 'nope', 'generation': 1},
              'uiTargetNotFound',
            ),
            (
              'ui.reveal',
              <String, Object?>{'identifier': 'nope'},
              'uiRevealTargetNotFound',
            ),
            (
              'ui.wait',
              <String, Object?>{
                'condition': 'semanticsMounted',
                'timeoutMs': 1,
                'semanticsIdentifier': 'nope',
              },
              'uiWaitTimeout',
            ),
            (
              'ui.capture',
              <String, Object?>{'targetId': 'nope'},
              'captureTargetGenerationRequired',
            ),
            (
              'ui.capture.diff',
              <String, Object?>{'beforeBlobId': 'a', 'afterBlobId': 'b'},
              'captureDiffArtifactNotFound',
            ),
            (
              'navigation.go',
              <String, Object?>{'destinationId': 'nope', 'revision': 1},
              'navigationDestinationNotFound',
            ),
            (
              'navigation.push',
              <String, Object?>{'destinationId': 'nope', 'revision': 1},
              'navigationDestinationNotFound',
            ),
            (
              'navigation.back',
              <String, Object?>{'revision': 9},
              'navigationOperationUnavailable',
            ),
          ]) {
        final Map<String, Object?> response = await pumpUntilComplete(
          tester,
          host.dispatchInvoke(command, arguments, 'pairing'),
        );
        expect(response['admission'], 'rejected', reason: command);
        expect(
          (response['rejection']! as Map<String, Object?>)['code'],
          code,
          reason: command,
        );
      }
    });

    _hostTest('只读三条与 keepAwake 状态各自答自己的载荷键序', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      for (final (String command, String keys) in <(String, String)>[
        (
          'ui.keepAwake.status',
          'outcome,source,wired,enabled,leaseMs,leaseRemainingMs',
        ),
        (
          'ui.inspect.status',
          'outcome,source,selectMode,selectionOnTap,managed',
        ),
        (
          'navigation.catalog',
          'outcome,source,navigationRevision,destinations',
        ),
        (
          'navigation.current',
          'outcome,source,navigationRevision,destinationId',
        ),
        (
          'ui.semantics.tree',
          'outcome,source,treeRevision,rootNodeId,truncated,nodeCount,'
              'nodes',
        ),
      ]) {
        final Map<String, Object?> response = await pumpUntilComplete(
          tester,
          host.dispatchInvoke(command, const <String, Object?>{}, 'payload'),
        );
        expect(response['admission'], 'accepted', reason: command);
        expect(
          (response['payload']! as Map<String, Object?>).keys.join(','),
          keys,
          reason: command,
        );
      }
    });

    _hostTest('信封本身的键序', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      final Map<String, Object?> response = await pumpUntilComplete(
        tester,
        _host(
          _wiredBridge(),
        ).dispatchInvoke('ui.inspect.status', const <String, Object?>{}, 'env'),
      );

      expect(
        response.keys.join(','),
        'schemaVersion,requestId,admission,payload,notice,jobId,rejection,'
        'schemaMode',
      );
    });
  });

  group('handler 里那几个字面缺省值', () {
    _hostTest('ui.semantics.tree 的 64 / 1000 与显式传入等价', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('leaf'))),
      );
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      final Map<String, Object?> defaulted = await pumpUntilComplete(
        tester,
        host.dispatchInvoke(
          'ui.semantics.tree',
          const <String, Object?>{},
          'tree',
        ),
      );
      final Map<String, Object?> explicit = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tree', const <String, Object?>{
          'maxDepth': 64,
          'maxNodes': 1000,
        }, 'tree'),
      );

      expect(jsonEncode(defaulted), jsonEncode(explicit));
    });

    _hostTest('gesture 的 500 / 300 / 100 会出现在等待时长上', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Semantics(
              identifier: 'app.button',
              container: true,
              child: TextButton(onPressed: () {}, child: const Text('go')),
            ),
          ),
        ),
      );
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      for (final (String command, Map<String, Object?> arguments, int total)
          in <(String, Map<String, Object?>, int)>[
            (
              'ui.gesture.pressHold',
              <String, Object?>{
                'identifier': 'app.button',
                'generation': 1,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
              },
              500,
            ),
            (
              'ui.gesture.drag',
              <String, Object?>{
                'identifier': 'app.button',
                'generation': 1,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
                'path': <Object?>[
                  <String, Object?>{'x': 0.5, 'y': 0.48},
                  <String, Object?>{'x': 0.5, 'y': 0.45},
                ],
              },
              300,
            ),
            (
              'ui.gesture.fling',
              <String, Object?>{
                'identifier': 'app.button',
                'generation': 1,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
                'velocity': <String, Object?>{'x': 0, 'y': -10},
              },
              100,
            ),
          ]) {
        _gestureDelays.clear();
        final Map<String, Object?> response = await pumpUntilComplete(
          tester,
          host.dispatchInvoke(command, arguments, 'gesture'),
        );
        expect(response['admission'], 'accepted', reason: command);
        expect(
          _gestureDelays.fold<int>(
            0,
            (int sum, Duration d) => sum + d.inMilliseconds,
          ),
          total,
          reason: command,
        );
      }
    });

    _hostTest('inspect 的 ttl 缺省来自 policy，不是 handler 常数', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(
        _wiredBridge(
          inspectPolicy: const PatchbayInspectPolicy(
            defaultLease: Duration(seconds: 30),
          ),
        ),
      );

      final Map<String, Object?> response = await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.inspect.select', const <String, Object?>{
          'enabled': true,
        }, 'inspect'),
      );

      final Map<String, Object?> payload =
          response['payload']! as Map<String, Object?>;
      expect(
        payload.keys.join(','),
        'outcome,source,selectMode,selectionOnTap,managed,previousSelectMode,'
        'restoresTo,leaseMs,leaseRemainingMs',
      );
      expect(payload['leaseMs'], 30000);
    });
  });

  group('参数校验：三类指名与键序', () {
    _hostTest('missing / unexpected / invalid / reason 的 details 逐字', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      Future<String> rejection(
        String command,
        Map<String, Object?> arguments,
      ) async {
        final Map<String, Object?> response = await pumpUntilComplete(
          tester,
          host.dispatchInvoke(command, arguments, 'args'),
        );
        expect(response['admission'], 'rejected', reason: command);
        return jsonEncode(response['rejection']);
      }

      // details 的键序是固定的：command → missing → unexpected → invalid → reason。
      expect(
        await rejection('ui.semantics.tap', const <String, Object?>{
          'generation': 3,
        }),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.semantics.tap","missing":["identifier"]}}',
      );
      expect(
        await rejection('ui.semantics.tap', const <String, Object?>{
          'identifier': 'app.save',
          'nodeId': 7,
        }),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.semantics.tap","unexpected":["nodeId"]}}',
      );
      expect(
        await rejection('ui.semantics.tap', const <String, Object?>{
          'identifier': 'app.save',
          'generation': 'two',
        }),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.semantics.tap","invalid":["generation"]}}',
      );
      // notice 排在 code 之后、details 之前；两者同时出现。
      expect(
        await rejection('ui.text.set', const <String, Object?>{
          'id': 'form.code',
          'generation': 0,
        }),
        '{"code":"invalidUiArguments",'
        '"notice":"id, generation and text are required.",'
        '"details":{"command":"ui.text.set","missing":["text"]}}',
      );
      // exec 式命令（参数整包来自 --args）不把无关键列进 unexpected。
      expect(
        await rejection('ui.semantics.tree', const <String, Object?>{
          'maxDepth': 'deep',
          'note': 'anything',
        }),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.semantics.tree","invalid":["maxDepth"]}}',
      );
      // 形状规则由 reason 承载，且只走协议词汇、不回显调用方的值。
      expect(
        await rejection('ui.wait', const <String, Object?>{
          'condition': 'semanticsMounted',
          'timeoutMs': 999999999,
          'semanticsIdentifier': 'app.ready',
        }),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.wait","reason":'
        '"timeout is out of the accepted range"}}',
      );
      // 三类指名同时命中时按 missing → unexpected → invalid 排列，各自内部有序。
      expect(
        await rejection(
          'ui.semantics.actionByIdentifier',
          const <String, Object?>{
            'generation': 'x',
            'zeta': 1,
            'alpha': 2,
            'action': 'teleport',
          },
        ),
        '{"code":"invalidUiArguments","details":'
        '{"command":"ui.semantics.actionByIdentifier",'
        '"missing":["identifier"],"unexpected":["alpha","zeta"],'
        '"invalid":["action","generation"]}}',
      );
    });
  });

  group('门面：features、审计、兜底与收敛', () {
    _hostTest('features 与 schemaVersion', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      final PatchbayFlutterServiceHost wired = _host(_wiredBridge());
      expect(
        wired.features.map((PatchbayFeature f) => f.name).toSet(),
        <String>{
          'catalogDigest',
          'snapshotSelectors',
          'snapshotRevisionDiff',
          'invocationCancellation',
          'responseSchemas',
          'lifecycleState',
          'captureAfterFrames',
        },
      );
      // captureAfterFrames 只在接入方接了 artifacts 时声明。
      expect(
        _host(_bareBridge()).features
            .map((PatchbayFeature f) => f.name)
            .contains('captureAfterFrames'),
        isFalse,
      );
      expect(wired.schemaVersion, 1);
      expect(wired.applicationId, 'dev.patchbay.characterization');
      expect(wired.appInstanceId, isNotEmpty);
    });

    _hostTest('没有 domainInvoke 时的兜底拒绝', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      final Map<String, Object?> response = await pumpUntilComplete(
        tester,
        _host(
          _wiredBridge(),
        ).dispatchInvoke('example.nope', const <String, Object?>{}, 'fallback'),
      );

      expect(
        jsonEncode(response['rejection']),
        '{"code":"commandNotRegistered","details":{"command":"example.nope"}}',
      );
    });

    _hostTest('默认 snapshot 是空 map，键序不变', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      final Map<String, Object?> snapshot = await pumpUntilComplete(
        tester,
        _host(_wiredBridge()).dispatchSnapshot(),
      );

      expect(
        snapshot.keys.join(','),
        'schemaVersion,snapshotRevision,revisionSource,factSource,observedAt,'
        'retainedRevisionLimit,retainedByteLimit,snapshotBytes',
      );
      expect(snapshot['snapshotBytes'], 2);
    });

    _hostTest('审计事件的键序与 admissionStage / gateDisposition', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      await pumpUntilComplete(
        tester,
        host.dispatchInvoke(
          'ui.inspect.status',
          const <String, Object?>{},
          'audit-accepted',
        ),
      );
      await pumpUntilComplete(
        tester,
        host.dispatchInvoke('ui.semantics.tap', const <String, Object?>{
          'identifier': 'app.save',
          'nodeId': 1,
        }, 'audit-rejected'),
      );

      expect(
        jsonEncode(
          host.auditEvents.map((PatchbayAuditEvent e) => e.toJson()).toList(),
        ),
        '[{"command":"ui.inspect.status","requestId":"audit-accepted",'
        '"parameterShape":{"type":"object","length":"0","keys":{}},'
        '"gateResult":"notDeclared","executionClassification":null,'
        '"admissionStage":"responseValidation","gateDisposition":"notDeclared"},'
        '{"command":"ui.semantics.tap","requestId":"audit-rejected",'
        '"parameterShape":{"type":"object","length":"2-5","keys":'
        '{"identifier":{"type":"string","length":"6-20"},'
        '"nodeId":{"type":"integer"}}},"gateResult":"passed",'
        '"executionClassification":null,"admissionStage":"uiPreflight",'
        '"gateDisposition":"notDeclared"}]',
      );
      // 参数值不进审计：只有键名与形状。
      expect(
        jsonEncode(
          host.auditEvents.map((PatchbayAuditEvent e) => e.toJson()).toList(),
        ),
        isNot(contains('app.save')),
      );
    });

    _hostTest('drain / cancel / dispose 的结果形状', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      expect(
        jsonEncode((await host.drainAudit()).toJson()),
        '{"outcome":"drained","settledCount":0,"overflowDroppedCount":0,'
        '"abandonedCount":0}',
      );
      expect(
        jsonEncode((await host.drainInvocations()).toJson()),
        '{"outcome":"drained","settledCount":0,"confirmedCount":0,'
        '"abandonedCount":0}',
      );
      expect(
        jsonEncode(
          (await host.cancelInvocation(
            command: 'ui.semantics.tree',
            requestId: 'absent',
            ownerToken: 'token',
          )).toJson(),
        ),
        '{"command":"ui.semantics.tree","requestId":"absent",'
        '"outcome":"unknown"}',
      );
      await host.dispose();
    });

    _hostTest('dispatchInvokeHandle 与 dispatchInvoke 同一条答复', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterServiceHost host = _host(_wiredBridge());

      final PatchbayHostInvocationHandle handle = host.dispatchInvokeHandle(
        'ui.inspect.status',
        const <String, Object?>{},
        'handle',
      );
      final Map<String, Object?> viaHandle = await pumpUntilComplete(
        tester,
        handle.response,
      );
      final Map<String, Object?> viaDispatch = await pumpUntilComplete(
        tester,
        host.dispatchInvoke(
          'ui.inspect.status',
          const <String, Object?>{},
          'handle',
        ),
      );

      expect(jsonEncode(viaHandle), jsonEncode(viaDispatch));
    });
  });
}
