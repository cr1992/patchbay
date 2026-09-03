// PB-050-17 / DG-050-10：`ui.reveal` 的契约面与机制唯一性。
//
// 机制唯一性在这里以**机检**落地，不靠代码评审：
//   1. 源码级封闭集合——reveal 的两个实现文件里没有 `showOnScreen`，
//      `performAction` 只有一个调用点，派发的 action 只能来自同轴 action 对；
//   2. 运行时记录器——整条矩阵里 `showOnScreenCalls` 恒为 0，并配一条正向对照
//      证明这个记录器真的会响（否则断言是空的）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_flutter/src/reveal/reveal_engine.dart';
import 'package:patchbay_flutter/src/reveal/reveal_models.dart';

import 'reveal_fixtures.dart';

const String _engineSource = 'lib/src/reveal/reveal_engine.dart';
const String _bridgeSource = 'lib/src/reveal/reveal_bridge.dart';

void main() {
  setUp(resetRevealCounters);

  group('机制唯一性', () {
    test('reveal 的实现代码里不存在 showOnScreen（注释可以谈论它）', () {
      for (final String path in <String>[_engineSource, _bridgeSource]) {
        expect(
          _code(path),
          isNot(contains('showOnScreen')),
          reason: '\$path 不得以任何形式保留 showOnScreen 通道',
        );
      }
    });

    test('performAction 只有一个调用点，派发的 action 只能来自同轴 action 对', () {
      final String source = File(_engineSource).readAsStringSync();
      expect(
        'performAction('.allMatches(source).length,
        1,
        reason: '多一个派发点就多一条接入方看不见的驱动通道',
      );
      expect(
        source,
        contains('_owner.performAction(layer.nodeId, action.flutterAction)'),
      );
      expect(_code(_bridgeSource), isNot(contains('performAction(')));

      // action 只可能是 `PatchbayRevealAxis` 里的那两个之一，两条轴合起来正好是
      // 四个 scroll action，一个都不多。
      expect(
        <PatchbaySemanticsAction>{
          PatchbayRevealAxis.vertical.first,
          PatchbayRevealAxis.vertical.second,
          PatchbayRevealAxis.horizontal.first,
          PatchbayRevealAxis.horizontal.second,
        },
        <PatchbaySemanticsAction>{
          PatchbaySemanticsAction.scrollUp,
          PatchbaySemanticsAction.scrollDown,
          PatchbaySemanticsAction.scrollLeft,
          PatchbaySemanticsAction.scrollRight,
        },
      );
    });

    testWidgets('正向对照：记录器真的会响（否则零派发断言是空的）', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 0)),
      );
      final SemanticsOwner owner = (await pumpReveal(
        tester,
        bridge.semantics.ensureOwner(),
      ))!;
      final int targetNodeId = _nodeIdFor(owner, revealTargetId);

      expect(showOnScreenCalls, 0);
      owner.performAction(targetNodeId, SemanticsAction.showOnScreen);
      bridge.semantics.dispose();

      expect(showOnScreenCalls, 1, reason: '记录器挂在目标节点上，一次派发必须被记到');
    });

    testWidgets('一整次 reveal 之后记录器仍然是 0', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> payload = revealPayload(
        await runReveal(
          tester,
          bridge,
          bridge.reveal.reveal(identifier: revealTargetId, timeoutMs: 60000),
        ),
      );

      expect(payload['outcome'], 'revealed');
      expect(payload['steps'], greaterThan(0));
      expect(showOnScreenCalls, 0);
    });
  });

  group('封闭词表', () {
    test('受理后 reason 恰好 13 个，且引擎里出现的每一个都在表内', () {
      expect(PatchbayRevealReason.values, hasLength(13));
      final String source = File(_engineSource).readAsStringSync();
      final Set<String> used = RegExp(r'PatchbayRevealReason\.([A-Za-z]+)')
          .allMatches(source)
          .map((RegExpMatch match) => match.group(1)!)
          .where((String name) => name != 'values')
          .toSet();
      expect(used, isNotEmpty);
      for (final String name in used) {
        expect(
          PatchbayRevealReason.values.contains(_reasonNamed(name)),
          isTrue,
          reason: '$name 不在封闭词表内',
        );
      }
    });

    test('准入前新增码恰好 8 个，且 bridge 里以字面量出现（可被全仓 ratchet 扫到）', () {
      // PB-050-35 把偏宽的 uiRevealNoScrollableContainer 拆成三个恢复方向，
      // 因此这张封闭表从 6 涨到 8。
      expect(PatchbayRevealRejection.values, hasLength(8));
      final String source = File(_bridgeSource).readAsStringSync();
      for (final String code in PatchbayRevealRejection.values) {
        expect(
          source.contains("'$code'"),
          isTrue,
          reason:
              '$code 必须在 bridge 里以字面量出现，否则 PB-050-23 的全仓扫描'
              '看不到它，注册表就锁不住',
        );
      }
    });
  });

  group('descriptor 与 wire', () {
    test('descriptor 冻结命令名、平面、副作用与五个参数', () {
      final PatchbayCommandDescriptor descriptor =
          patchbayUiRevealCommandDescriptor;
      expect(descriptor.name, 'ui.reveal');
      expect(descriptor.plane, PatchbayPlane.flutterUi);
      expect(descriptor.mode, PatchbayCommandMode.immediate);
      expect(descriptor.sideEffect, PatchbaySideEffect.appState);
      expect(descriptor.factSources, <PatchbayFactSource>{
        PatchbayFactSource.uiObserved,
      });
      expect(
        descriptor.parameters.map(
          (PatchbayParameterDescriptor parameter) => parameter.name,
        ),
        <String>[
          'identifier',
          'container',
          'direction',
          'maxSteps',
          'timeoutMs',
        ],
      );
      final Map<String, PatchbayParameterDescriptor> parameters =
          <String, PatchbayParameterDescriptor>{
            for (final PatchbayParameterDescriptor parameter
                in descriptor.parameters)
              parameter.name: parameter,
          };
      expect(parameters['identifier']!.required, isTrue);
      expect(parameters['container']!.required, isFalse);
      expect(parameters['direction']!.allowedValues, <String>[
        'forward',
        'backward',
        'both',
      ]);
      expect(parameters['direction']!.defaultValue, 'both');
      expect(parameters['maxSteps']!.defaultValue, 40);
      expect(parameters['timeoutMs']!.defaultValue, 5000);
      // 坐标红线：五个参数是全集，其中没有任何位置入参——上面的逐项列表就是
      // 这条红线的机检形式，多一个 offset / pixelDelta / scrollToOffset 都会红。
      expect(descriptor.cliSyntax.single.path, <String>['ui', 'reveal']);
    });

    test('host 常量与不可参数化常量如实冻结', () {
      expect(PatchbayRevealBudget.maxSteps, 200);
      expect(PatchbayRevealBudget.maxDurationMs, 120000);
      expect(PatchbayRevealBudget.stallSteps, 2);
      expect(PatchbayRevealBudget.maxProbeStepsPerContainer, 1);
      expect(PatchbayRevealBudget.defaultSteps, 40);
      expect(PatchbayRevealBudget.defaultTimeoutMs, 5000);
    });

    test('direction 与 reachability 的 wire 值封闭', () {
      expect(
        PatchbayRevealDirectionWire.values.map(
          (PatchbayRevealDirectionWire value) => value.name,
        ),
        <String>['forward', 'backward', 'both'],
      );
      expect(
        PatchbayRevealReachabilityWire.values.map(
          (PatchbayRevealReachabilityWire value) => value.name,
        ),
        <String>['pointer', 'semanticsOnly'],
      );
    });
  });

  group('host 注册', () {
    testWidgets('strictKeys：未知 key 在 bridge 与 policy 之前就被拒', (
      WidgetTester tester,
    ) async {
      var policyCalls = 0;
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final PatchbayFlutterBridge bridge = revealBridge(
        policy: (_, _) {
          policyCalls += 1;
          return const PatchbayRevealDecision.allow(
            maxSteps: 200,
            maxDurationMs: 120000,
          );
        },
      );
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 400, targetIndex: 380, controller: controller),
        ),
      );

      final Map<String, Object?> response = await pumpReveal(
        tester,
        host.dispatchInvoke('ui.reveal', <String, Object?>{
          'identifier': revealTargetId,
          'scrollToOffset': 120,
        }, 'request-unknown-key'),
      );
      bridge.semantics.dispose();

      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'invalidUiArguments');
      expect(
        (rejection['details']! as Map<String, Object?>)['unexpected'],
        <String>['scrollToOffset'],
      );
      expect(policyCalls, 0, reason: '未知 key 必须在 policy 之前就被拒');
      expect(controller.offset, 0);
      expect(showOnScreenCalls, 0);
    });

    testWidgets('direction 非法值按 wire 枚举类型化拒绝', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> response = await pumpReveal(
        tester,
        host.dispatchInvoke('ui.reveal', <String, Object?>{
          'identifier': revealTargetId,
          'direction': 'down',
        }, 'request-bad-direction'),
      );
      bridge.semantics.dispose();

      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'invalidUiArguments');
      expect(
        (rejection['details']! as Map<String, Object?>)['invalid'],
        <String>['direction'],
      );
    });

    testWidgets('revealed payload 的键与值逐项钉死（golden）', (
      WidgetTester tester,
    ) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(revealList(itemCount: 40, targetIndex: 20)),
      );

      final Map<String, Object?> response = await pumpReveal(
        tester,
        host.dispatchInvoke('ui.reveal', <String, Object?>{
          'identifier': revealTargetId,
          'direction': 'forward',
          'maxSteps': 60,
          'timeoutMs': 60000,
        }, 'request-golden'),
      );
      bridge.semantics.dispose();

      final Map<String, Object?> payload =
          response['payload']! as Map<String, Object?>;
      expect(payload.keys.toList(), <String>[
        'outcome',
        'source',
        'identifier',
        'steps',
        'elapsedMs',
        'containers',
        'nodeId',
        'generation',
        'reachability',
        'beforeTreeRevision',
        'afterTreeRevision',
      ]);
      expect(payload['outcome'], 'revealed');
      expect(payload['source'], 'uiObserved');
      expect(payload['identifier'], revealTargetId);
      expect(payload['reachability'], 'pointer');
      final List<Map<String, Object?>> containers = revealContainers(payload);
      expect(containers, hasLength(1));
      expect(containers.single.keys.toList(), <String>[
        'nodeId',
        'generation',
        'steps',
        'direction',
        'extentGrowthSteps',
      ]);
      // 只回计数与代际：上面两条键集断言就是「不回显 scrollPosition /
      // scrollExtent 像素值、不回显坐标 / rect / 探针点」的机检形式。再加一条
      // 类型断言——像素是 double，计数与代际只能是 int。
      for (final Object? value in <Object?>[
        payload['steps'],
        payload['elapsedMs'],
        payload['nodeId'],
        payload['generation'],
        payload['beforeTreeRevision'],
        payload['afterTreeRevision'],
        ...containers.single.values.where((Object? item) => item is! String),
      ]) {
        expect(value, isA<int>(), reason: '\$payload');
      }
      expectRevealInvariants(payload);
    });

    testWidgets('老客户端把 outcome: failed 读成 typedFailure：admission 仍是 '
        'accepted', (WidgetTester tester) async {
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.flutter.test',
        bridge: bridge,
      );
      await tester.pumpWidget(
        revealApp(
          revealList(itemCount: 12, targetIndex: -1, targetId: 'reveal.absent'),
        ),
      );

      final Map<String, Object?> response = await pumpReveal(
        tester,
        host.dispatchInvoke('ui.reveal', <String, Object?>{
          'identifier': revealTargetId,
          'direction': 'forward',
          'timeoutMs': 60000,
        }, 'request-failed'),
      );
      bridge.semantics.dispose();

      expect(response['admission'], 'accepted');
      final Map<String, Object?> payload =
          response['payload']! as Map<String, Object?>;
      expect(payload['outcome'], 'failed');
      expect(payload['reason'], 'scrollExhausted');
      expectRevealInvariants(payload);
    });
  });
}

String _reasonNamed(String name) => switch (name) {
  'stepBudgetExceeded' => PatchbayRevealReason.stepBudgetExceeded,
  'scrollExhausted' => PatchbayRevealReason.scrollExhausted,
  'targetObscured' => PatchbayRevealReason.targetObscured,
  'targetBlocked' => PatchbayRevealReason.targetBlocked,
  'targetAmbiguous' => PatchbayRevealReason.targetAmbiguous,
  'containerChanged' => PatchbayRevealReason.containerChanged,
  'containerDenied' => PatchbayRevealReason.containerDenied,
  'containerBudgetTooSmall' => PatchbayRevealReason.containerBudgetTooSmall,
  'policyChanged' => PatchbayRevealReason.policyChanged,
  'gateRejected' => PatchbayRevealReason.gateRejected,
  'lifecycleNotResumed' => PatchbayRevealReason.lifecycleNotResumed,
  'timeout' => PatchbayRevealReason.timeout,
  'scrollActionFailed' => PatchbayRevealReason.scrollActionFailed,
  _ => name,
};

/// 去掉行注释之后的源码：注释里可以讨论 `showOnScreen`，代码里不行。
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');

int _nodeIdFor(SemanticsOwner owner, String identifier) {
  int? found;
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().identifier == identifier) found = node.id;
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(owner.rootSemanticsNode!);
  return found!;
}
