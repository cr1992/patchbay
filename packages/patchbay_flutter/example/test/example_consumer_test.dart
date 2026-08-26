import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';
import 'package:patchbay_flutter_example/example_domain.dart';
import 'package:patchbay_flutter_example/example_log_source.dart';
import 'package:patchbay_flutter_example/main.dart';

void main() {
  testWidgets('widget exposes stable semantics and keeps normal interaction', (
    WidgetTester tester,
  ) async {
    final ExampleCounterModel model = ExampleCounterModel();
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey noteKey = PatchbayKey.text(
      noteTargetId,
      registry: registry,
    );
    final PatchbayKey cardCaptureKey = PatchbayKey.capture(
      cardCaptureTargetId,
      registry: registry,
    );
    final ExampleRouter router = ExampleRouter();
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      router: router,
      isAppResumed: () => true,
    );
    try {
      await tester.pumpWidget(
        PatchbayExampleApp(
          model: model,
          noteKey: noteKey,
          cardCaptureKey: cardCaptureKey,
          router: router,
        ),
      );
      expect(find.text('Count: 0'), findsOneWidget);

      final PatchbaySemanticsIdentifierObservation? before =
          await _pumpUntilComplete(
            tester,
            host.bridge.semantics.observeIdentifier(counterSemanticsId),
          );
      expect(before?.matches, hasLength(1));
      expect(before?.matches.single.value, '0');

      await tester.tap(find.text('Increment'));
      await tester.pump();
      expect(find.text('Count: 1'), findsOneWidget);

      final PatchbaySemanticsIdentifierObservation? after =
          await _pumpUntilComplete(
            tester,
            host.bridge.semantics.observeIdentifier(counterSemanticsId),
          );
      expect(after?.matches.single.value, '1');
    } finally {
      host.dispose();
      model.dispose();
    }
  });

  testWidgets('host composes identity, catalog and consumer invoke', (
    WidgetTester tester,
  ) async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final ExampleCounterModel model = ExampleCounterModel();
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey noteKey = PatchbayKey.text(
      noteTargetId,
      registry: registry,
    );
    final PatchbayKey cardCaptureKey = PatchbayKey.capture(
      cardCaptureTargetId,
      registry: registry,
    );
    final ExampleRouter router = ExampleRouter();
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      router: router,
      appInstanceId: 'example-test-instance',
      isAppResumed: () => true,
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
    )..register();
    try {
      await tester.pumpWidget(
        PatchbayExampleApp(
          model: model,
          noteKey: noteKey,
          cardCaptureKey: cardCaptureKey,
          router: router,
        ),
      );

      final Map<String, Object?> identity = await _call(
        handlers,
        PatchbayServiceHost.identityMethod,
      );
      expect(identity['applicationId'], exampleApplicationId);
      expect(identity['appInstanceId'], 'example-test-instance');
      expect(identity['isolateId'], isA<String>());

      final Map<String, Object?> catalog = await _call(
        handlers,
        PatchbayServiceHost.catalogMethod,
      );
      final List<Map<String, Object?>> commands =
          (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        commands.map((Map<String, Object?> row) => row['name']),
        containsAll(<String>{
          incrementCommand,
          'ui.semantics.tree',
          'ui.text.set',
        }),
      );
      // 0.4.0 的能力全部靠组合根注入。没有这条断言，接线被删掉时 example 仍然编译、
      // 单测仍然全绿，而本地端到端预检会在设备上才发现命令根本不在 catalog 里。
      expect(
        commands.map((Map<String, Object?> row) => row['name']),
        containsAll(<String>{
          'ui.semantics.action',
          'ui.gesture.pressHold',
          'ui.gesture.drag',
          'ui.gesture.fling',
          // PB-050-17：reveal 只在接入方注入了 revealPolicy 时才进 catalog，
          // 所以这一行就是「example 的组合根真的写下了那份授权」的机检。
          'ui.reveal',
          'ui.inspect.select',
          'ui.inspect.status',
          'ui.keepAwake.set',
          'ui.keepAwake.status',
          'navigation.catalog',
          'navigation.current',
          'navigation.go',
          'navigation.push',
          'navigation.back',
          'ui.capture',
          'ui.capture.diff',
          'blob.metadata',
          'logs.query',
          'logs.tail',
          'logs.export',
          deviceWriteCommand,
          jobRunCommand,
          idempotentTouchCommand,
          permissionRequestCommand,
          permissionStatusCommand,
          semanticsBenchmarkCommand,
          jobGetCommand,
          jobWaitCommand,
          jobCancelCommand,
        }),
      );
      final List<Map<String, Object?>> targets =
          (catalog['uiTargets']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        targets.singleWhere(
          (Map<String, Object?> target) => target['id'] == noteTargetId,
        ),
        containsPair('mounted', true),
      );
      expect(
        targets.singleWhere(
          (Map<String, Object?> target) => target['id'] == cardCaptureTargetId,
        ),
        allOf(containsPair('mounted', true), containsPair('kind', 'capture')),
      );

      final Map<String, Object?> treeInvocation = await _pumpUntilComplete(
        tester,
        _call(handlers, PatchbayServiceHost.invokeMethod, <String, String>{
          'command': 'ui.semantics.tree',
          'args': '{}',
          'requestId': 'tree-request',
        }),
      );
      expect(treeInvocation['admission'], 'accepted');
      final Map<String, Object?> treePayload =
          treeInvocation['payload']! as Map<String, Object?>;
      final List<Map<String, Object?>> nodes =
          (treePayload['nodes']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        nodes.map((Map<String, Object?> n) => n['identifier']),
        containsAll(<String>{
          gestureSurfaceSemanticsId,
          gestureListSemanticsId,
          gestureNestedListSemanticsId,
        }),
      );

      final Map<String, Object?> benchmark = await _pumpUntilComplete(
        tester,
        _call(handlers, PatchbayServiceHost.invokeMethod, <String, String>{
          'command': semanticsBenchmarkCommand,
          'args': '{"samples":2}',
          'requestId': 'benchmark-request',
        }),
      );
      expect(benchmark['admission'], 'accepted');
      expect(benchmark['payload'], containsPair('buildMode', 'debug'));
      expect(benchmark['payload'], containsPair('sampleRuns', 2));
      expect(
        benchmark['payload'],
        containsPair('scannedNodes', greaterThanOrEqualTo(nodes.length)),
      );

      final Map<String, Object?> invocation = await _call(
        handlers,
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': incrementCommand,
          'args': '{}',
          'requestId': 'example-request',
        },
      );
      expect(invocation['admission'], 'accepted');
      expect(
        invocation['payload'],
        containsPair('source', PatchbayFactSource.appRecorded.name),
      );
      await tester.pump();
      expect(find.text('Count: 1'), findsOneWidget);
    } finally {
      host.dispose();
      model.dispose();
    }
  });

  group('PB-050-22 factory-default write gate', () {
    test(
      'rejects an unauthorized write gate with the factory-default code',
      () {
        final PatchbayGateDecision decision = factoryDefaultWriteGateDecision(
          exampleWriteGate,
        );
        expect(decision.allowed, isFalse);
        expect(decision.code, 'writeGateClosedByDefault');
        expect(decision.notice, contains('factory-safe default'));
        expect(decision.notice, contains(exampleWriteGate));
      },
    );

    test('a gate evaluator built on the factory default closes writes but '
        'leaves declared-gate-free reads open', () async {
      // This is the reference shape a real consumer keeps: unlike
      // `PatchbayExampleHost`, which allows `exampleWriteGate` outright as
      // a disclosed exception for `tool/example_precheck.sh` (see
      // `_exampleConsumerGate`'s doc comment in lib/main.dart), a gate
      // evaluator wired straight to [factoryDefaultWriteGateDecision]
      // keeps every write gate closed until the host names it explicitly.
      final PatchbayGateEvaluator gates = PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (String id) => factoryDefaultWriteGateDecision(id),
      );

      // A read-only command (ui.semantics.tree, ui.wait, ui.capture,
      // logs.*, ...) declares no consumer gate IDs at all, so it only
      // crosses the always-open base gate.
      expect(await gates.evaluate(const <String>{}), isNull);

      // Every write-classified command in this example declares
      // `exampleWriteGate`. Under the factory default, that gate ID stays
      // closed until a host authorizes it by name.
      final PatchbayGateRejection? rejection = await gates.evaluate(
        const <String>{exampleWriteGate},
      );
      expect(rejection, isNotNull);
      expect(rejection!.code, 'writeGateClosedByDefault');
    });
  });

  test('permission request dispatches without inventing completion', () async {
    final _FakePermissionGateway permissions = _FakePermissionGateway();
    final ValueNotifier<int> counter = ValueNotifier<int>(0);
    final ExampleDomain domain = ExampleDomain(
      counter: counter,
      logs: ExampleLogSource(),
      permissions: permissions,
    );
    addTearDown(counter.dispose);

    final Map<String, Object?> response = await domain.invoke(
      permissionRequestCommand,
      <String, Object?>{'permission': 'camera'},
      'permission-request',
    );
    expect(response['admission'], 'accepted');
    expect(response['payload'], containsPair('outcome', 'requested'));
    expect(response['payload'], containsPair('beforePlatformState', 'denied'));
    expect(permissions.requests, <String>['camera']);

    final Map<String, Object?> status = await domain.invoke(
      permissionStatusCommand,
      <String, Object?>{'permission': 'camera'},
      'permission-status',
    );
    expect(status['admission'], 'accepted');
    expect(status['payload'], containsPair('platformState', 'denied'));
  });
}

final class _FakePermissionGateway implements ExamplePermissionGateway {
  final List<String> requests = <String>[];

  @override
  void request(String permission) => requests.add(permission);

  @override
  Future<String> status(String permission) async => 'denied';
}

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 20 && !completed; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (!completed) {
    throw StateError(
      'Patchbay example operation did not complete in 20 frames',
    );
  }
  return pending;
}

Future<Map<String, Object?>> _call(
  Map<String, ServiceExtensionHandler> handlers,
  String method, [
  Map<String, String> arguments = const <String, String>{},
]) async {
  final ServiceExtensionResponse response = await handlers[method]!(
    method,
    arguments,
  );
  return Map<String, Object?>.from(
    jsonDecode(response.result!) as Map<String, dynamic>,
  );
}
