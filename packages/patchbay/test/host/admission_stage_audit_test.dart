import 'dart:async';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

/// PB-050-39 / DG-060-04：host audit 如实记录准入阶段与门处置。
///
/// 裁决把这两个事实**只**放进 host-only audit，不进 invocation envelope、也不进
/// rejection details——调用方的恢复由稳定 code、`gateId` 与既有 details 决定，把内部
/// 阶段写进公共应答会让重构拓扑变成协议。因此本文件只从 `host.auditEvents` 断言，
/// 不断言任何应答字段。
///
/// 同时锁住三条兼容义务：`gateResult` 取值与写入点逐字节不变；新字段可选、旧源码构造
/// 继续编译；`toJson` 在缺失时省略新键（老 reader 看不到多出来的键）。
///
/// `uiPreflight` / `operationPolicy` 属 Flutter handler，由 invocation-scoped
/// admission 把最后到达的阶段投影进 core audit；正向行为覆盖位于 Flutter host 测试，
/// 本文件仍负责冻结共用词表。
void main() {
  group('阶段与门处置进 audit，不进应答', () {
    test('目录不可用停在 catalog，且没有任何门被触达', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        catalog: () async => <String, Object?>{'commands': 'not-a-list'},
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-catalog',
      );

      expect(_code(response), 'providerProtocolViolation');
      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.admissionStage, 'catalog');
      expect(event.gateDisposition, 'notReached');
      expect(
        response.containsKey('admissionStage'),
        isFalse,
        reason: '阶段是 host-only 事实，不得出现在应答里',
      );
      expect(_details(response).containsKey('admissionStage'), isFalse);
    });

    test('sensitive 参数未走 stdin 停在 inputPolicy，早于任何门', () async {
      final _RecordingGates gates = _RecordingGates();
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            ..._row('device.write', gates: <String>['unlockedGate']),
            'parameters': <Map<String, Object?>>[
              <String, Object?>{
                'name': 'secret',
                'type': 'string',
                'sensitive': true,
              },
            ],
          },
        ],
        domainGates: gates.evaluator,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'secret': 'literal'},
        'req-sensitive',
      );

      expect(_code(response), 'sensitiveInputRequiresStdin');
      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.admissionStage, 'inputPolicy');
      expect(event.gateDisposition, 'notReached');
      expect(gates.baseCalls, 0, reason: '输入策略先于 base gate');
    });

    test('base gate 拒绝停在 baseGate，处置是 rejected', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['unlockedGate']),
        ],
        domainGates: _RecordingGates(baseAllowed: false).evaluator,
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-base',
      );

      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.admissionStage, 'baseGate');
      expect(
        event.gateDisposition,
        'rejected',
        reason: 'base gate 说不，从 consumer 视角同样是 rejected',
      );
      expect(event.gateResult, 'rejected', reason: '既有字段取值不变');
    });

    test('声明门拒绝停在 descriptorGate', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['sealedGate']),
        ],
        domainGates: _RecordingGates(
          rejectedGateIds: const <String>{'sealedGate'},
        ).evaluator,
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-declared',
      );

      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.admissionStage, 'descriptorGate');
      expect(event.gateDisposition, 'rejected');
    });

    test('声明门但 host 无 evaluator 停在 descriptorGate', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['unlockedGate']),
        ],
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-no-evaluator',
      );

      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.admissionStage, 'descriptorGate');
      expect(event.gateDisposition, 'rejected');
    });

    test('声明门通过后走到 responseValidation，处置是 passed', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['unlockedGate']),
        ],
        domainGates: _RecordingGates().evaluator,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-passed',
      );

      expect(response['admission'], 'accepted');
      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(
        event.admissionStage,
        'responseValidation',
        reason: '阶段记录的是本次事实停止**或完成**的位置',
      );
      expect(event.gateDisposition, 'passed');
    });

    test('写命令没有声明门时处置是 notDeclared，而不是 passed', () async {
      // base gate 仍然跑过并放行，但 consumer 没有声明任何门——「没声明」和
      // 「声明了且通过」是两个事实，混同会让一个未被授权的面读成已授权。
      final _RecordingGates gates = _RecordingGates();
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: gates.evaluator,
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-undeclared',
      );

      expect(gates.baseCalls, 1);
      expect(gates.consumerCalls, isEmpty);
      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.gateDisposition, 'notDeclared');
      expect(event.gateResult, 'passed', reason: '既有字段取值不变');
    });

    test('只读命令没有触达任何门，处置是 notReached', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.status', sideEffect: 'none'),
        ],
        domainGates: gates.evaluator,
      );

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-read',
      );

      expect(gates.baseCalls, 0);
      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.gateDisposition, 'notReached');
      expect(event.gateResult, 'notEvaluated', reason: '既有字段取值不变');
    });

    test('重复 requestId 停在 dispatch，处置是 notReached', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['unlockedGate']),
        ],
        domainGates: _RecordingGates().evaluator,
      );

      await host.dispatchInvoke('device.write', const <String, Object?>{
        'a': 1,
      }, 'req-dup');
      await host.dispatchInvoke('device.write', const <String, Object?>{
        'b': 2,
      }, 'req-dup');

      final PatchbayAuditEvent event = host.auditEvents.last;
      expect(event.admissionStage, 'dispatch');
      expect(event.gateDisposition, 'notReached');
    });
  });

  group('封闭词表', () {
    test('每条记录的阶段与处置都在封闭集内', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.status', sideEffect: 'none'),
          _row('device.write', gates: <String>['unlockedGate']),
          _row('device.denied', gates: <String>['sealedGate']),
        ],
        domainGates: _RecordingGates(
          rejectedGateIds: const <String>{'sealedGate'},
        ).evaluator,
      );

      for (final String command in <String>[
        'device.status',
        'device.write',
        'device.denied',
      ]) {
        await host.dispatchInvoke(command, const <String, Object?>{}, command);
      }

      expect(host.auditEvents, hasLength(3));
      for (final PatchbayAuditEvent event in host.auditEvents) {
        expect(patchbayAuditAdmissionStages, contains(event.admissionStage));
        expect(patchbayAuditGateDispositions, contains(event.gateDisposition));
      }
    });

    test('共用词表包含 Flutter handler 投影的阶段', () {
      // `domain_gate_enforcement_test.dart` 正向覆盖动态 gate 停在
      // `operationPolicy`；这里仅锁住 core 与 Flutter 共用同一封闭词表。
      expect(patchbayAuditAdmissionStages, contains('uiPreflight'));
      expect(patchbayAuditAdmissionStages, contains('operationPolicy'));
    });
  });

  group('兼容义务', () {
    test('旧源码只传五个必填参数仍可构造', () {
      const PatchbayAuditEvent event = PatchbayAuditEvent(
        command: 'device.write',
        requestId: 'req-legacy',
        parameterShape: <String, Object?>{},
        gateResult: 'passed',
        executionClassification: null,
      );

      expect(event.admissionStage, isNull);
      expect(event.gateDisposition, isNull);
    });

    test('缺失时 toJson 省略新键，既有键逐字节不变', () {
      const PatchbayAuditEvent legacy = PatchbayAuditEvent(
        command: 'device.write',
        requestId: 'req-legacy',
        parameterShape: <String, Object?>{},
        gateResult: 'passed',
        executionClassification: null,
      );

      expect(legacy.toJson().keys, <String>[
        'command',
        'requestId',
        'parameterShape',
        'gateResult',
        // 这一键早于「缺失即省略」的规则，老 reader 按位置比对 golden，
        // 因此即使为 null 也照旧写出。
        'executionClassification',
      ]);
    });

    test('存在时 toJson 追加新键，顺序在既有键之后', () {
      const PatchbayAuditEvent event = PatchbayAuditEvent(
        command: 'device.write',
        requestId: 'req-new',
        parameterShape: <String, Object?>{},
        gateResult: 'rejected',
        executionClassification: null,
        admissionStage: 'baseGate',
        gateDisposition: 'rejected',
      );

      expect(event.toJson().keys.toList().sublist(4), <String>[
        'executionClassification',
        'admissionStage',
        'gateDisposition',
      ]);
    });

    test('legacyUnknown 是新 reader 面对老 host 的取值，且不在写入词表里', () {
      expect(patchbayAuditLegacyUnknown, 'legacyUnknown');
      expect(
        patchbayAuditAdmissionStages,
        isNot(contains(patchbayAuditLegacyUnknown)),
        reason: 'host 永不写它——它只表达 reader 侧「这台 host 没有这个字段」',
      );
      expect(
        patchbayAuditGateDispositions,
        isNot(contains(patchbayAuditLegacyUnknown)),
      );
    });
  });
}

Map<String, Object?> _row(
  String name, {
  String sideEffect = 'external',
  List<String>? gates,
}) => <String, Object?>{
  'name': name,
  'mode': 'immediate',
  'sideEffect': sideEffect,
  'factSources': <String>['appRecorded'],
  if (gates != null) 'gates': gates,
};

PatchbayServiceHost _host({
  required List<Map<String, Object?>> commands,
  PatchbayGateEvaluator? domainGates,
  Future<Map<String, Object?>> Function()? catalog,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.admission-stage-test',
  registrar: (_, _) {},
  domainGates: domainGates,
  catalog: catalog ?? () async => <String, Object?>{'commands': commands},
  snapshot: () async => const <String, Object?>{},
  invoke: (String command, Map<String, Object?> _, String requestId) async =>
      PatchbayInvocation.accepted(requestId: requestId).toJson(),
);

String? _code(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}

Map<String, Object?> _details(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  if (rejection is! Map<Object?, Object?>) return const <String, Object?>{};
  final Object? details = rejection['details'];
  return details is Map<Object?, Object?>
      ? Map<String, Object?>.from(details)
      : const <String, Object?>{};
}

final class _RecordingGates {
  _RecordingGates({
    this.baseAllowed = true,
    this.rejectedGateIds = const <String>{},
  });

  final bool baseAllowed;
  final Set<String> rejectedGateIds;

  int baseCalls = 0;
  final List<String> consumerCalls = <String>[];

  PatchbayGateEvaluator get evaluator =>
      PatchbayGateEvaluator(baseGate: _base, consumerGate: _consumer);

  FutureOr<PatchbayGateDecision> _base() {
    baseCalls += 1;
    return baseAllowed
        ? const PatchbayGateDecision.allow()
        : const PatchbayGateDecision.reject(code: 'baseGateRejected');
  }

  FutureOr<PatchbayGateDecision> _consumer(String gateId) {
    consumerCalls.add(gateId);
    return rejectedGateIds.contains(gateId)
        ? const PatchbayGateDecision.reject(code: 'consumerGateRejected')
        : const PatchbayGateDecision.allow();
  }
}
