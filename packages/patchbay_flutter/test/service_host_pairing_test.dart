// PB-050-38：descriptor↔handler 配对的**行为级**表征。
//
// 注册表靠「第 N 个 descriptor 配第 N 个 handler」的位置约定成表，名字不参与配对。
// 数量错位会被 `PatchbayUiRegistrationBuilder` 两端的守卫当场拦下，**顺序错位不会**
// ——它只会让某条命令悄悄由别的桥应答。所以那道防线只能由测试网格提供，而网格必须
// 细到「任意两条 handler 对调都必然红」。
//
// 按拒绝码分辨是不够的：`navigation.go` 与 `navigation.push` 都答
// `navigationDestinationNotFound`，`ui.text.set` 与 `ui.text.enter` 都答
// `uiTargetNotFound`，把这两对的 handler 对调，只看码的网格全绿。这个盲区在**拆分前
// 的基线上同样存在**（旧网格也只看码），不是拆分引入的。
//
// 这里给每条命令一枚**行为级指纹**：受理结论 + 载荷里那个说明「到底做了什么」的字段
// （`operation` / `gesture` / `action` / 载荷键序）+ 这次调用真正触发的接入方回调
// （导航 adapter 的 go/push、Semantics 的 onTap/onFocus、输入框的 formatter 与
// onChanged、手势的等待时长）。两条断言：
//
// 1. 23 枚指纹两两不同——任意两条 handler 对调都会让至少一枚指纹变值；
// 2. 逐对对调注入之后，被对调的那条命令指纹**确实**变了。
//
// 对调是**测试侧**注入：把喂给 bindings 的 descriptor 列表里两条互换即可，位置约定
// 会把 handler 一起换过去，生产代码一行不动。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/flutter_ui_command_bindings.dart';
import 'package:patchbay_flutter/src/flutter_ui_command_descriptors.dart';
import 'package:patchbay_flutter/src/flutter_ui_registration.dart';

import 'fixture/flutter_bridge_fixtures.dart';

final PatchbayGateEvaluator _gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

/// 这次调用真正打到接入方身上的东西——指纹的另一半。
final class _Observed {
  final List<String> navigation = <String>[];
  final List<String> semantics = <String>[];
  final List<String> text = <String>[];
  final List<int> delays = <int>[];

  String destination = 'home';
  int revision = 1;

  void clear() {
    navigation.clear();
    semantics.clear();
    text.clear();
    delays.clear();
  }

  @override
  String toString() =>
      'nav=$navigation sem=$semantics text=$text delays=$delays';
}

final class _Harness {
  _Harness(
    this.bridge,
    this.observed,
    this.textGeneration,
    this.node,
    this.gestureGeneration,
  );

  final PatchbayFlutterBridge bridge;
  final _Observed observed;
  final int textGeneration;
  final Map<String, Object?> node;
  final int gestureGeneration;

  int get nodeId => node['nodeId']! as int;
  int get generation => node['generation']! as int;
}

/// 一棵同时挂着文本目标、可执行 Semantics 节点与手势目标的树。
Future<_Harness> _pump(WidgetTester tester) async {
  final _Observed observed = _Observed();
  final PatchbayUiRegistry registry = PatchbayUiRegistry();
  final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
  final TextEditingController controller = TextEditingController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            SizedBox(
              width: 200,
              child: TextField(
                key: key,
                controller: controller,
                inputFormatters: <TextInputFormatter>[
                  CountingUpperFormatter(() => observed.text.add('format')),
                ],
                onChanged: (String value) =>
                    observed.text.add('changed:$value'),
              ),
            ),
            Semantics(
              identifier: 'app.action',
              label: 'Action probe',
              focusable: true,
              onTap: () => observed.semantics.add('tap'),
              onFocus: () => observed.semantics.add('focus'),
              child: const SizedBox(width: 40, height: 40),
            ),
            // 手势打的是**指针通道**，目标必须真的可命中：裸 Semantics 包一个
            // SizedBox 在遮挡采样里会命中背景，按 `uiGestureTargetObscured` 拒绝。
            Semantics(
              identifier: 'app.button',
              container: true,
              child: TextButton(
                onPressed: () => observed.semantics.add('pressed'),
                child: const Text('go'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
    registry: registry,
    gates: _gates,
    isAppResumed: () => true,
    semanticsActionPolicy: (_, _) =>
        const PatchbaySemanticsActionDecision.allow(),
    gesturePolicy: (_, _) => const PatchbayGestureDecision.allow(),
    gestureDelay: (Duration d) async => observed.delays.add(d.inMilliseconds),
    gesturePointerDispatcher: (PointerEvent _) {},
    revealPolicy: (_, _) => const PatchbayRevealDecision.allow(),
    inspectPolicy: const PatchbayInspectPolicy(),
    artifacts: PatchbayArtifactService(
      blobs: PatchbayMemoryBlobStore(),
      gates: _gates,
    ),
    navigationAdapter: PatchbayNavigationAdapter(
      destinations: () => <PatchbayNavigationDestination>[
        PatchbayNavigationDestination(
          id: 'home',
          go: () {
            observed.navigation.add('go:home');
            observed.destination = 'home';
            observed.revision += 1;
          },
        ),
        PatchbayNavigationDestination(
          id: 'detail',
          go: () {
            observed.navigation.add('go:detail');
            observed.destination = 'detail';
            observed.revision += 1;
          },
          push: () {
            observed.navigation.add('push:detail');
            observed.destination = 'detail';
            observed.revision += 1;
          },
        ),
      ],
      current: () => PatchbayNavigationObservation(
        revision: observed.revision,
        destinationId: observed.destination,
      ),
    ),
  );

  final PatchbayInvocation tree = await pumpUntilComplete(
    tester,
    bridge.semantics.snapshot(),
  );
  final Map<String, Object?> node = semanticsNodes(
    tree,
  ).singleWhere((Map<String, Object?> n) => n['identifier'] == 'app.action');
  final int gestureGeneration =
      semanticsNodes(tree).singleWhere(
            (Map<String, Object?> n) => n['identifier'] == 'app.button',
          )['generation']!
          as int;
  final int textGeneration = bridge
      .catalog()
      .singleWhere((PatchbayUiTargetDescriptor t) => t.id == 'form.code')
      .generation;
  return _Harness(bridge, observed, textGeneration, node, gestureGeneration);
}

/// 按名字取一条命令的参数——形状合法、能打到现场。
Map<String, Object?> _arguments(String command, _Harness h) =>
    switch (command) {
      'ui.text.set' || 'ui.text.enter' => <String, Object?>{
        'id': 'form.code',
        'generation': h.textGeneration,
        'text': 'ab',
      },
      'ui.semantics.tree' => const <String, Object?>{},
      'ui.semantics.action' => <String, Object?>{
        'nodeId': h.nodeId,
        'generation': h.generation,
        'action': 'focus',
      },
      'ui.semantics.actionByIdentifier' => <String, Object?>{
        'identifier': 'app.action',
        'generation': h.generation,
        'action': 'focus',
      },
      'ui.semantics.tap' => <String, Object?>{
        'identifier': 'app.action',
        'generation': h.generation,
      },
      'ui.gesture.pressHold' => <String, Object?>{
        'identifier': 'app.button',
        'generation': h.gestureGeneration,
        'start': <String, Object?>{'x': 0.5, 'y': 0.5},
      },
      'ui.gesture.drag' => <String, Object?>{
        'identifier': 'app.button',
        'generation': h.gestureGeneration,
        'start': <String, Object?>{'x': 0.5, 'y': 0.5},
        'path': <Object?>[
          <String, Object?>{'x': 0.5, 'y': 0.48},
          <String, Object?>{'x': 0.5, 'y': 0.45},
        ],
      },
      'ui.gesture.fling' => <String, Object?>{
        'identifier': 'app.button',
        'generation': h.gestureGeneration,
        'start': <String, Object?>{'x': 0.5, 'y': 0.5},
        'velocity': <String, Object?>{'x': 0, 'y': -10},
      },
      'ui.gesture.tap' => <String, Object?>{
        'identifier': 'app.button',
        'generation': h.gestureGeneration,
      },
      'ui.reveal' => const <String, Object?>{'identifier': 'app.action'},
      'ui.wait' => const <String, Object?>{
        'condition': 'frameRevision',
        'timeoutMs': 200,
        'revision': 0,
      },
      'ui.keepAwake.set' => const <String, Object?>{'enabled': true},
      'ui.capture' => const <String, Object?>{'timeoutMs': 200},
      'ui.capture.diff' => const <String, Object?>{
        'beforeBlobId': 'a',
        'afterBlobId': 'b',
      },
      'ui.inspect.select' => const <String, Object?>{'enabled': true},
      'navigation.go' || 'navigation.push' => <String, Object?>{
        'destinationId': 'detail',
        'revision': h.observed.revision,
      },
      'navigation.back' => <String, Object?>{'revision': h.observed.revision},
      _ => const <String, Object?>{},
    };

/// 一枚指纹：受理结论 + 载荷里说明「做了什么」的那部分 + 打到接入方的回调。
///
/// 随运行变化的量（代际、租约剩余、树版本）一律不进指纹，只留能区分 handler 的部分。
const Set<String> _volatile = <String>{
  'generation',
  'nodeId',
  'beforeTreeRevision',
  'afterTreeRevision',
  'beforeNavigationRevision',
  'afterNavigationRevision',
  'navigationRevision',
  'treeRevision',
  'frameRevision',
  'leaseRemainingMs',
  'elapsedMs',
  'nodes',
  'nodeCount',
  'rootNodeId',
  'blobId',
  'bytes',
  'width',
  'height',
  'previousSelectMode',
};

Future<String> _fingerprint(
  WidgetTester tester,
  PatchbayCommandRegistry registry,
  String command,
  _Harness h,
) async {
  h.observed.clear();
  final Map<String, Object?> response = await pumpUntilComplete(
    tester,
    registry.dispatch(command, _arguments(command, h), 'fingerprint'),
  );
  final Map<String, Object?>? rejection =
      response['rejection'] as Map<String, Object?>?;
  final Map<String, Object?> payload =
      (response['payload'] as Map<String, Object?>?) ??
      const <String, Object?>{};
  final Map<String, Object?> stable = <String, Object?>{
    for (final MapEntry<String, Object?> entry in payload.entries)
      if (!_volatile.contains(entry.key)) entry.key: entry.value,
  };
  return '${response['admission']} '
      '${rejection == null ? '-' : rejection['code']} '
      '${jsonEncode(stable)} ${h.observed}';
}

/// 把喂给 bindings 的 descriptor 列表里两条互换，位置约定会把 handler 一起换过去。
PatchbayCommandRegistry _registry(
  PatchbayFlutterBridge bridge, {
  (String, String)? swap,
}) {
  final List<PatchbayCommandDescriptor> descriptors =
      patchbayFlutterUiCommandDescriptors(
        captureGates: bridge.capture?.gateIds ?? const <String>{},
        keepAwakeGates: bridge.keepAwake.gateIds,
        inspectPolicy: bridge.inspect?.policy ?? const PatchbayInspectPolicy(),
      ).toList();
  if (swap case (final String a, final String b)) {
    final int i = descriptors.indexWhere(
      (PatchbayCommandDescriptor d) => d.name == a,
    );
    final int j = descriptors.indexWhere(
      (PatchbayCommandDescriptor d) => d.name == b,
    );
    expect(i, isNonNegative, reason: a);
    expect(j, isNonNegative, reason: b);
    final PatchbayCommandDescriptor held = descriptors[i];
    descriptors[i] = descriptors[j];
    descriptors[j] = held;
  }
  final PatchbayUiRegistrationBuilder builder = PatchbayUiRegistrationBuilder(
    descriptors,
  );
  patchbayBindUiTextCommands(builder, bridge);
  patchbayBindUiSemanticsCommands(builder, bridge);
  patchbayBindUiGestureCommands(builder, bridge);
  patchbayBindUiRevealAndWaitCommands(builder, bridge);
  patchbayBindUiKeepAwakeCommands(builder, bridge);
  patchbayBindUiCaptureCommands(builder, bridge);
  patchbayBindUiInspectCommands(builder, bridge);
  patchbayBindNavigationCommands(builder, bridge);
  return builder.seal();
}

const List<String> _commands = <String>[
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
];

/// 同族里彼此参数形状最接近的那些对——只看拒绝码的网格对它们全瞎。
const List<(String, String)> _pairs = <(String, String)>[
  ('ui.text.set', 'ui.text.enter'),
  ('ui.semantics.action', 'ui.semantics.actionByIdentifier'),
  ('ui.semantics.actionByIdentifier', 'ui.semantics.tap'),
  ('ui.gesture.pressHold', 'ui.gesture.drag'),
  ('ui.gesture.fling', 'ui.gesture.tap'),
  ('ui.reveal', 'ui.wait'),
  ('ui.keepAwake.set', 'ui.keepAwake.status'),
  ('ui.capture', 'ui.capture.diff'),
  ('ui.inspect.status', 'ui.inspect.select'),
  ('navigation.catalog', 'navigation.current'),
  ('navigation.go', 'navigation.push'),
  ('navigation.go', 'navigation.back'),
];

void _hostTest(String description, Future<void> Function(WidgetTester) body) =>
    testWidgets(description, (WidgetTester tester) async {
      try {
        await body(tester);
      } finally {
        for (final PatchbayFlutterBridge bridge in _live) {
          bridge.dispose();
        }
        _live.clear();
      }
    });

final List<PatchbayFlutterBridge> _live = <PatchbayFlutterBridge>[];

void main() {
  _hostTest('23 枚行为级指纹两两不同', (WidgetTester tester) async {
    final _Harness h = await _pump(tester);
    _live.add(h.bridge);
    final PatchbayCommandRegistry registry = _registry(h.bridge);

    final Map<String, String> fingerprints = <String, String>{};
    for (final String command in _commands) {
      fingerprints[command] = await _fingerprint(tester, registry, command, h);
    }

    // 逐条钉住那个说明「到底做了什么」的字段，而不是只钉拒绝码。
    expect(fingerprints['ui.text.set'], contains('"operation":"text.set"'));
    expect(fingerprints['ui.text.set'], contains('"value":"ab"'));
    expect(fingerprints['ui.text.set'], contains('text=[]'));
    expect(fingerprints['ui.text.enter'], contains('"operation":"text.enter"'));
    // enter 走目标策略：formatter 跑过、onChanged 触发过，所以值被大写化。
    expect(fingerprints['ui.text.enter'], contains('"value":"AB"'));
    expect(fingerprints['ui.text.enter'], contains('format'));
    expect(fingerprints['ui.text.enter'], contains('changed:AB'));

    expect(fingerprints['ui.semantics.action'], contains('"action":"focus"'));
    expect(
      fingerprints['ui.semantics.action'],
      isNot(contains('"identifier"')),
    );
    expect(fingerprints['ui.semantics.action'], contains('sem=[focus]'));
    expect(
      fingerprints['ui.semantics.actionByIdentifier'],
      contains('"identifier":"app.action"'),
    );
    expect(
      fingerprints['ui.semantics.actionByIdentifier'],
      contains('"action":"focus"'),
    );
    // tap 的 action 是写死的，不跟请求走——这正是它与上一条的区别。
    expect(fingerprints['ui.semantics.tap'], contains('"action":"tap"'));
    expect(fingerprints['ui.semantics.tap'], contains('sem=[tap]'));

    for (final (String command, String gesture) in <(String, String)>[
      ('ui.gesture.pressHold', 'pressHold'),
      ('ui.gesture.drag', 'drag'),
      ('ui.gesture.fling', 'fling'),
      ('ui.gesture.tap', 'tap'),
    ]) {
      expect(fingerprints[command], contains('"gesture":"$gesture"'));
    }

    expect(fingerprints['navigation.go'], contains('"operation":"go"'));
    expect(fingerprints['navigation.go'], contains('nav=[go:detail]'));
    expect(fingerprints['navigation.push'], contains('"operation":"push"'));
    expect(fingerprints['navigation.push'], contains('nav=[push:detail]'));

    // 总闸：两两不同。任意两条 handler 对调都会让至少一枚指纹变值。
    final Map<String, List<String>> byFingerprint = <String, List<String>>{};
    fingerprints.forEach((String command, String fingerprint) {
      byFingerprint.putIfAbsent(fingerprint, () => <String>[]).add(command);
    });
    final List<List<String>> collisions = byFingerprint.values
        .where((List<String> commands) => commands.length > 1)
        .toList();
    expect(collisions, isEmpty, reason: '指纹相同的命令对调之后网格看不出来：$collisions');
    expect(fingerprints, hasLength(_commands.length));
  });

  _hostTest('逐对对调之后，被对调的那条命令指纹确实变了', (WidgetTester tester) async {
    for (final (String a, String b) in _pairs) {
      final _Harness h = await _pump(tester);
      _live.add(h.bridge);

      final String correct = await _fingerprint(
        tester,
        _registry(h.bridge),
        a,
        h,
      );
      final PatchbayCommandRegistry swapped = _registry(h.bridge, swap: (a, b));
      String? mispaired;
      try {
        mispaired = await _fingerprint(tester, swapped, a, h);
      } on Object {
        // 形状不兼容的对调让 handler 当场抛——同样是红，网格看得见。
        mispaired = null;
      }
      expect(mispaired, isNot(correct), reason: '$a ↔ $b 对调之后指纹没变');
    }
  });
}
