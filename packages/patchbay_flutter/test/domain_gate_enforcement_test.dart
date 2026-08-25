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

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

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

  test('read-only domain commands never reach the gate', () async {
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
    expect(host.auditEvents.single.gateResult, 'notEvaluated');
  });

  test('registry-owned UI commands keep their own gate stage', () async {
    // `ui.keepAwake.status` is `sideEffect: none` and registry-owned; the
    // domain admission gate must not appear in front of it.
    final PatchbayFlutterServiceHost host = _host(
      adapter: _Adapter(),
      closedGateIds: const <String>{'example.write'},
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'ui.keepAwake.status',
      const <String, Object?>{},
      'req-registry',
    );

    expect(response['admission'], 'accepted');
  });
}

PatchbayFlutterServiceHost _host({
  required _Adapter adapter,
  bool baseAllowed = true,
  Set<String> closedGateIds = const <String>{},
}) => PatchbayFlutterServiceHost(
  applicationId: 'dev.patchbay.domain-gate.test',
  registrar: (_, _) {},
  bridge: PatchbayFlutterBridge(
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
