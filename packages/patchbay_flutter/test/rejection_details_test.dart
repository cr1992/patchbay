/// 空拒绝补全护栏：拒绝信封必须说清「哪里不对」，而不是只说「不对」。
///
/// `invalidUiArguments` 与 `*LifecycleNotResumed` 原先都是裸码，调用方只能自己
/// 二分请求。这里逐条钉死 details 的三类指名（缺键 / 多键 / 类型不符）、形状规则
/// 的 reason，以及生命周期状态。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

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

/// A host with every UI command registered, so a rejection is about the
/// arguments rather than about a missing capability.
PatchbayFlutterServiceHost _host({
  bool Function()? isAppResumed,
  PatchbayLifecycleStateReader? lifecycleState,
}) {
  final _NavigationState state = _NavigationState();
  return PatchbayFlutterServiceHost(
    applicationId: 'dev.patchbay.details.test',
    bridge: PatchbayFlutterBridge(
      registry: PatchbayUiRegistry(),
      gates: _gates,
      semanticsActionPolicy: (_, _) =>
          const PatchbaySemanticsActionDecision.allow(),
      navigationAdapter: PatchbayNavigationAdapter(
        destinations: () => <PatchbayNavigationDestination>[
          PatchbayNavigationDestination(id: 'home', go: () {}),
        ],
        current: state.observe,
      ),
      artifacts: PatchbayArtifactService(
        blobs: PatchbayMemoryBlobStore(),
        gates: _gates,
      ),
      isAppResumed: isAppResumed ?? () => true,
      lifecycleState: lifecycleState,
    ),
  );
}

Future<Map<String, Object?>> _rejection(
  String command,
  Map<String, Object?> arguments, {
  PatchbayFlutterServiceHost? host,
}) async {
  final Map<String, Object?> response = await (host ?? _host()).dispatchInvoke(
    command,
    arguments,
    'request-1',
  );
  expect(
    response['admission'],
    'rejected',
    reason: 'expected $command to refuse these arguments',
  );
  return response['rejection']! as Map<String, Object?>;
}

Future<Map<String, Object?>> _details(
  String command,
  Map<String, Object?> arguments, {
  PatchbayFlutterServiceHost? host,
}) async {
  final Map<String, Object?> rejection = await _rejection(
    command,
    arguments,
    host: host,
  );
  expect(rejection['code'], 'invalidUiArguments');
  return rejection['details']! as Map<String, Object?>;
}

void main() {
  group('invalidUiArguments 指名缺的键', () {
    test('ui.semantics.tap 少了 identifier', () async {
      final Map<String, Object?> details = await _details(
        'ui.semantics.tap',
        const <String, Object?>{'generation': 3},
      );

      expect(details['command'], 'ui.semantics.tap');
      expect(details['missing'], <String>['identifier']);
    });

    test('navigation.go 少了 revision 与 destinationId', () async {
      final Map<String, Object?> details = await _details(
        'navigation.go',
        const <String, Object?>{'timeoutMs': 5000},
      );

      expect(details['missing'], <String>['destinationId', 'revision']);
    });

    test('ui.text.set 少了 text，notice 与 details 同时保留', () async {
      final Map<String, Object?> rejection = await _rejection(
        'ui.text.set',
        const <String, Object?>{'id': 'form.code', 'generation': 0},
      );

      expect(rejection['notice'], contains('required'));
      expect(
        (rejection['details']! as Map<String, Object?>)['missing'],
        <String>['text'],
      );
    });
  });

  group('invalidUiArguments 指名多的键', () {
    test('ui.semantics.tap 收到未声明的键', () async {
      final Map<String, Object?> details = await _details(
        'ui.semantics.tap',
        const <String, Object?>{'identifier': 'app.save', 'nodeId': 7},
      );

      expect(details['unexpected'], <String>['nodeId']);
    });

    test('navigation.back 不声明 destinationId', () async {
      // go / push 共用的那道检查会放行这个键，back 自己才拒；details 指的是
      // back 的声明，而不是那道共用检查的白名单。
      final Map<String, Object?> details = await _details(
        'navigation.back',
        const <String, Object?>{'revision': 1, 'destinationId': 'home'},
      );

      expect(details['unexpected'], <String>['destinationId']);
    });

    test('navigation.current 一个参数都不收', () async {
      final Map<String, Object?> details = await _details(
        'navigation.current',
        const <String, Object?>{'destinationId': 'home'},
      );

      expect(details['unexpected'], <String>['destinationId']);
    });

    test('ui.capture 的未声明键连同解码原因一起回', () async {
      final Map<String, Object?> details = await _details(
        'ui.capture',
        const <String, Object?>{'pixelRatio': 1, 'quality': 90},
      );

      expect(details['unexpected'], <String>['quality']);
      expect(details['reason'], isA<String>());
    });

    test('exec 式命令不把无关键当成拒绝理由', () async {
      // `ui.semantics.tree` 的参数整包来自 `--args`，这道拒绝只读两个键；把
      // 请求里其他键列进 unexpected 会把调用方指向错误的地方。
      final Map<String, Object?> details = await _details(
        'ui.semantics.tree',
        const <String, Object?>{'maxDepth': 'deep', 'note': 'anything'},
      );

      expect(details.containsKey('unexpected'), isFalse);
      expect(details['invalid'], <String>['maxDepth']);
    });
  });

  group('invalidUiArguments 指名类型不符的键', () {
    test('声明为整数的键收到字符串', () async {
      final Map<String, Object?> details = await _details(
        'ui.semantics.tap',
        const <String, Object?>{'identifier': 'app.save', 'generation': 'two'},
      );

      expect(details['invalid'], <String>['generation']);
    });

    test('枚举参数收到未声明的取值', () async {
      final Map<String, Object?> details = await _details(
        'ui.semantics.action',
        const <String, Object?>{
          'nodeId': 1,
          'generation': 0,
          'action': 'teleport',
        },
      );

      expect(details['invalid'], <String>['action']);
    });
  });

  group('形状规则由 reason 承载', () {
    test('semanticsValue 缺 value 时键差集为空，reason 说出规则', () async {
      final Map<String, Object?> details =
          await _details('ui.wait', const <String, Object?>{
            'condition': 'semanticsValue',
            'timeoutMs': 1000,
            'semanticsIdentifier': 'app.counter',
          });

      expect(details.containsKey('missing'), isFalse);
      expect(details.containsKey('unexpected'), isFalse);
      expect(details['reason'], contains('semanticsValue'));
    });

    test('未声明的 condition 取值同时进 invalid 与 reason', () async {
      final Map<String, Object?> details = await _details(
        'ui.wait',
        const <String, Object?>{'condition': 'sunrise', 'timeoutMs': 1000},
      );

      expect(details['invalid'], <String>['condition']);
      expect(details['reason'], isA<String>());
    });

    test('reason 不回显调用方的值', () async {
      // 报文里只走协议词汇：字段名、路径、规则。`ArgumentError.toString()`
      // 会把越界的值一起带上（这里是 999999999ms 渲染成的 Duration），所以那条
      // 路径只报被拒的字段名，句子逐字钉死。
      final Map<String, Object?> details =
          await _details('ui.wait', const <String, Object?>{
            'condition': 'semanticsMounted',
            'timeoutMs': 999999999,
            'semanticsIdentifier': 'app.ready',
          });

      expect(details['reason'], 'timeout is out of the accepted range');
      expect(details['reason'], isNot(contains('277777')));
    });
  });

  group('生命周期拒绝带上当前状态', () {
    test('注入的状态原样出现在 details 里', () async {
      final PatchbayFlutterServiceHost host = _host(
        isAppResumed: () => false,
        lifecycleState: () => AppLifecycleState.paused,
      );

      for (final (String command, Map<String, Object?> arguments, String code)
          in <(String, Map<String, Object?>, String)>[
            (
              'ui.semantics.tree',
              const <String, Object?>{},
              'uiLifecycleNotResumed',
            ),
            (
              'ui.semantics.tap',
              const <String, Object?>{'identifier': 'app.save'},
              'uiLifecycleNotResumed',
            ),
            (
              'navigation.go',
              const <String, Object?>{'destinationId': 'home', 'revision': 1},
              'navigationLifecycleNotResumed',
            ),
            (
              'ui.wait',
              const <String, Object?>{
                'condition': 'frameRevision',
                'timeoutMs': 200,
                'revision': 0,
              },
              'uiWaitLifecycleNotResumed',
            ),
            (
              'ui.capture',
              const <String, Object?>{'timeoutMs': 200},
              'captureLifecycleNotResumed',
            ),
          ]) {
        final Map<String, Object?> rejection = await _rejection(
          command,
          arguments,
          host: host,
        );
        expect(rejection['code'], code, reason: command);
        expect(
          (rejection['details']! as Map<String, Object?>)['lifecycleState'],
          'paused',
          reason: command,
        );
      }
    });

    test('只覆写 isAppResumed 时如实报 unknown，不假称 binding 的状态', () async {
      final Map<String, Object?> rejection = await _rejection(
        'ui.semantics.tree',
        const <String, Object?>{},
        host: _host(isAppResumed: () => false),
      );

      expect(rejection['code'], 'uiLifecycleNotResumed');
      expect(
        (rejection['details']! as Map<String, Object?>)['lifecycleState'],
        'unknown',
      );
    });
  });
}
