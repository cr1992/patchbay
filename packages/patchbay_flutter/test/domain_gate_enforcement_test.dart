/// PB-050-25：Flutter host 的 domain 写命令必须过桥已持有的那一套门。
///
/// 这里刻意**不**引入任何新的构造参数：`PatchbayFlutterBridge` 今天就持有
/// `PatchbayGateEvaluator`，UI 面每条写路径都在用它。本文件断言的是同一个
/// evaluator 也覆盖 `domainInvoke` 的写命令——一个 host 只应有一套门语义，
/// 同一个 gateId 在 UI 面与 domain 面必须指同一件事。
///
/// 在闸点落地之前，本文件整组红：domain 写命令直达 adapter，连不可省略的基础门
/// 都不跑。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

void main() {
  test('a rejecting base gate now covers domain writes too', () async {
    final _Adapter adapter = _Adapter();
    final PatchbayFlutterServiceHost host = _host(
      adapter: adapter,
      baseAllowed: false,
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'example.device.write',
      const <String, Object?>{'value': 1},
      'req-base',
    );

    expect(response['admission'], 'rejected');
    expect(_code(response), 'baseGateRejected');
    expect(_details(response), <String, Object?>{'gateId': 'patchbay.base'});
    expect(adapter.calls, isEmpty);
  });

  test('a declared domain gate is evaluated by the bridge evaluator', () async {
    final _Adapter adapter = _Adapter();
    final PatchbayFlutterServiceHost host = _host(
      adapter: adapter,
      closedGateIds: const <String>{'example.write'},
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'example.device.write',
      const <String, Object?>{'value': 1},
      'req-declared',
    );

    expect(_code(response), 'writeGateClosedByDefault');
    expect(_details(response), <String, Object?>{'gateId': 'example.write'});
    expect(adapter.calls, isEmpty);
    expect(host.auditEvents.single.gateResult, 'rejected');
  });

  test('an open write gate leaves the domain reply untouched', () async {
    final _Adapter adapter = _Adapter();
    final PatchbayFlutterServiceHost host = _host(adapter: adapter);

    final Map<String, Object?> response = await host.dispatchInvoke(
      'example.device.write',
      const <String, Object?>{'value': 1},
      'req-open',
    );

    expect(response['admission'], 'accepted');
    expect(adapter.calls, <String>['example.device.write']);
    expect(host.auditEvents.single.gateResult, 'passed');
  });

  test('read-only domain commands skip base but run declared gates', () async {
    final _Adapter adapter = _Adapter();
    final PatchbayFlutterServiceHost host = _host(
      adapter: adapter,
      baseAllowed: false,
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'example.device.read',
      const <String, Object?>{},
      'req-read',
    );

    expect(response['admission'], 'accepted');
    expect(adapter.calls, <String>['example.device.read']);
    expect(host.auditEvents.single.gateResult, 'passed');
  });

  test(
    'host skips the base gate already admitted by core for UI reads',
    () async {
      final _GateProbe probe = _GateProbe(baseAllowed: false);
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        isAppResumed: () => true,
        gates: probe.evaluator,
      );
      final PatchbayFlutterServiceHost host = _host(
        adapter: _Adapter(),
        bridge: bridge,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.keepAwake.status',
        const <String, Object?>{},
        'req-registry',
      );

      expect(response['admission'], 'accepted');
      expect(probe.baseCalls, 0);

      final PatchbayInvocation direct = await bridge.keepAwake.status();
      expect(direct.rejection?.code, 'baseGateRejected');
      expect(probe.baseCalls, 1);
    },
  );

  test('registry descriptor gates are evaluated exactly once', () async {
    final _GateProbe probe = _GateProbe();
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      registry: PatchbayUiRegistry(),
      isAppResumed: () => true,
      gates: probe.evaluator,
      keepAwakeDelegate: (_) async {},
      keepAwakeGates: const <String>{'consumer.keepAwake'},
    );
    final PatchbayFlutterServiceHost host = _host(
      adapter: _Adapter(),
      bridge: bridge,
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'ui.keepAwake.set',
      const <String, Object?>{'enabled': true},
      'req-ui-static-gate',
    );

    expect(response['admission'], 'accepted');
    expect(probe.baseCalls, 1);
    expect(probe.consumerCalls, <String>['consumer.keepAwake']);
    final PatchbayAuditEvent event = host.auditEvents.single;
    expect(event.gateResult, 'passed');
    expect(event.gateDisposition, 'passed');
    expect(event.admissionStage, 'responseValidation');
  });

  test('typed UI argument rejection is audited at uiPreflight only', () async {
    final _GateProbe probe = _GateProbe();
    final PatchbayFlutterServiceHost host = _host(
      adapter: _Adapter(),
      bridge: PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        isAppResumed: () => true,
        gates: probe.evaluator,
      ),
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'ui.text.set',
      const <String, Object?>{'id': 'form.code', 'generation': 1},
      'req-ui-preflight',
    );

    expect(_code(response), 'invalidUiArguments');
    expect(response.containsKey('admissionStage'), isFalse);
    expect(_details(response).containsKey('admissionStage'), isFalse);
    expect(probe.baseCalls, 1);
    expect(probe.consumerCalls, isEmpty);
    final PatchbayAuditEvent event = host.auditEvents.single;
    expect(event.admissionStage, 'uiPreflight');
    expect(event.gateDisposition, 'notDeclared');
  });

  testWidgets('dynamic UI gates remain in operationPolicy audit stage', (
    WidgetTester tester,
  ) async {
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey key = PatchbayKey.text(
      'form.code',
      registry: registry,
      operationGates: const <PatchbayUiOperation, Set<String>>{
        PatchbayUiOperation.textSet: <String>{'target.write'},
      },
    );
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(key: key, controller: controller),
        ),
      ),
    );
    final _GateProbe probe = _GateProbe(
      rejectedGateIds: const <String>{'target.write'},
    );
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      registry: registry,
      isAppResumed: () => true,
      gates: probe.evaluator,
    );
    final PatchbayFlutterServiceHost host = _host(
      adapter: _Adapter(),
      bridge: bridge,
    );
    final int generation = registry.catalog().single.generation;

    final Map<String, Object?> response = await host.dispatchInvoke(
      'ui.text.set',
      <String, Object?>{
        'id': 'form.code',
        'generation': generation,
        'text': 'blocked',
      },
      'req-ui-dynamic-gate',
    );

    expect(_code(response), 'consumerGateRejected');
    expect(_details(response), <String, Object?>{'gateId': 'target.write'});
    expect(controller.text, isEmpty);
    expect(probe.baseCalls, 1);
    expect(probe.consumerCalls, <String>['target.write']);
    final PatchbayAuditEvent event = host.auditEvents.single;
    expect(event.gateResult, 'rejected');
    expect(event.gateDisposition, 'rejected');
    expect(event.admissionStage, 'operationPolicy');
  });
}

PatchbayFlutterServiceHost _host({
  required _Adapter adapter,
  bool baseAllowed = true,
  Set<String> closedGateIds = const <String>{},
  PatchbayFlutterBridge? bridge,
}) => PatchbayFlutterServiceHost(
  applicationId: 'dev.patchbay.domain-gate.test',
  registrar: (_, _) {},
  bridge:
      bridge ??
      PatchbayFlutterBridge(
        registry: PatchbayUiRegistry(),
        isAppResumed: () => true,
        gates: PatchbayGateEvaluator(
          baseGate: () => baseAllowed
              ? const PatchbayGateDecision.allow()
              : const PatchbayGateDecision.reject(code: 'baseGateRejected'),
          consumerGate: (String gateId) => closedGateIds.contains(gateId)
              ? const PatchbayGateDecision.reject(
                  code: 'writeGateClosedByDefault',
                )
              : const PatchbayGateDecision.allow(),
        ),
      ),
  domainCatalog: () async => <String, Object?>{
    'commands': <Object?>[
      for (final PatchbayCommandDescriptor descriptor in _descriptors)
        descriptor.toJson(),
    ],
  },
  domainInvoke: adapter.invoke,
);

final class _GateProbe {
  _GateProbe({
    this.baseAllowed = true,
    this.rejectedGateIds = const <String>{},
  });

  final bool baseAllowed;
  final Set<String> rejectedGateIds;
  int baseCalls = 0;
  final List<String> consumerCalls = <String>[];

  PatchbayGateEvaluator get evaluator => PatchbayGateEvaluator(
    baseGate: () {
      baseCalls += 1;
      return baseAllowed
          ? const PatchbayGateDecision.allow()
          : const PatchbayGateDecision.reject(code: 'baseGateRejected');
    },
    consumerGate: (String gateId) {
      consumerCalls.add(gateId);
      return rejectedGateIds.contains(gateId)
          ? const PatchbayGateDecision.reject(code: 'consumerGateRejected')
          : const PatchbayGateDecision.allow();
    },
  );
}

const List<PatchbayCommandDescriptor> _descriptors =
    <PatchbayCommandDescriptor>[
      PatchbayCommandDescriptor(
        name: 'example.device.write',
        summary: 'Write a simulated device value.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.external,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        gates: <String>{'example.write'},
      ),
      PatchbayCommandDescriptor(
        name: 'example.device.read',
        summary: 'Read the simulated device value.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.none,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        gates: <String>{'example.write'},
      ),
    ];

final class _Adapter {
  final List<String> calls = <String>[];

  Future<Map<String, Object?>> invoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    calls.add(command);
    return PatchbayInvocation.accepted(requestId: requestId).toJson();
  }
}

String? _code(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}

Map<String, Object?> _details(Map<String, Object?> response) {
  final Map<Object?, Object?> rejection =
      response['rejection']! as Map<Object?, Object?>;
  return Map<String, Object?>.from(
    rejection['details']! as Map<Object?, Object?>,
  );
}
