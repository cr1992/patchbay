import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

/// PB-050-26 / DG-060-04：`ui.reveal` 的 accepted 响应在通过 response schema 与
/// 语义校验之后，core host 把 `steps` 与被驱动容器 nodeId 投影进 host-only
/// `PatchbayAuditEvent.executionDetails`。裁决把这条投影钉死为「只读已校验
/// response、越界整块省略并报告既有 error observer」，因此本文件只从
/// `host.auditEvents` 断言，不断言任何应答字段——`executionDetails` 从不进入
/// invocation envelope，和 PB-050-39 的 `admissionStage` / `gateDisposition`
/// 走同一条兼容边界。
void main() {
  group('absent：非 reveal 命令、拒绝、provider 违规', () {
    test('非 ui.reveal 命令即使 payload 恰好带 steps/containers 也不投影', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _revealRow(name: 'device.status', sideEffect: 'none'),
        ],
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: <String, Object?>{
            'steps': 3,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 41},
            ],
          },
        ).toJson(),
      );

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-non-reveal',
      );

      expect(host.auditEvents.single.executionDetails, isNull);
    });

    test('拒绝的 ui.reveal 省略 executionDetails', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(code: 'uiRevealDenied'),
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-rejected');

      expect(host.auditEvents.single.executionDetails, isNull);
    });

    test(
      'accepted 但违反声明的 response schema 视为 provider 违规，省略 executionDetails',
      () async {
        final PatchbayServiceHost host = _host(
          invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
            requestId: requestId,
            // 缺 schema 要求的 `containers`。
            payload: const <String, Object?>{'steps': 3},
          ).toJson(),
        );

        final Map<String, Object?> response = await host.dispatchInvoke(
          'ui.reveal',
          const <String, Object?>{'identifier': 'a'},
          'req-schema-violation',
        );

        expect(_code(response), 'providerProtocolViolation');
        expect(host.auditEvents.single.executionDetails, isNull);
      },
    );
  });

  group('empty：steps 0', () {
    test('steps 0 时 containerNodeIds 是空列表', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 0,
            'containers': <Object?>[],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-empty');

      final PatchbayAuditRevealExecutionDetails? reveal =
          host.auditEvents.single.executionDetails?.reveal;
      expect(reveal?.steps, 0);
      expect(reveal?.containerNodeIds, isEmpty);
    });
  });

  group('populated', () {
    test('steps 与 containerNodeIds 按首次驱动顺序投影', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 3,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 41},
              <String, Object?>{'nodeId': 57},
            ],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-populated');

      final PatchbayAuditEvent event = host.auditEvents.single;
      expect(event.executionDetails?.reveal?.steps, 3);
      expect(event.executionDetails?.reveal?.containerNodeIds, <int>[41, 57]);
      expect(event.executionDetails!.toJson(), <String, Object?>{
        'reveal': <String, Object?>{
          'steps': 3,
          'containerNodeIds': <int>[41, 57],
        },
      });
    });
  });

  group('上限 200 与 201 越界', () {
    test('steps 恰好 200 在界内', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 200,
            'containers': <Object?>[],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-steps-200');

      expect(host.auditEvents.single.executionDetails?.reveal?.steps, 200);
    });

    test('steps 201 越界，省略整块并报告 defect', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 201,
            'containers': <Object?>[],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-steps-oob');
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      expect(host.auditEvents.single.executionDetails, isNull);
      expect(reported, hasLength(1));
      final PatchbayAuditExecutionDetailsProjectionDefect defect =
          reported.single as PatchbayAuditExecutionDetailsProjectionDefect;
      expect(defect.reason, 'stepsOutOfRange');
      expect(defect.command, 'ui.reveal');
      expect(defect.requestId, 'req-steps-oob');
    });

    test('containerNodeIds 恰好 200 个在界内', () async {
      final List<Map<String, Object?>> containers = <Map<String, Object?>>[
        for (var i = 0; i < 200; i += 1) <String, Object?>{'nodeId': i},
      ];
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: <String, Object?>{'steps': 200, 'containers': containers},
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-containers-200');

      expect(
        host.auditEvents.single.executionDetails?.reveal?.containerNodeIds,
        hasLength(200),
      );
    });

    test('containerNodeIds 201 个越界，省略整块并报告 defect', () async {
      final List<Map<String, Object?>> containers = <Map<String, Object?>>[
        for (var i = 0; i < 201; i += 1) <String, Object?>{'nodeId': i},
      ];
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: <String, Object?>{'steps': 200, 'containers': containers},
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-containers-oob');
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containerNodeIdsTooLong',
      );
    });
  });

  group('负数或非 int 元素', () {
    test('nodeId 为负数视为投影缺陷，即便通用 response schema 只检查类型', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 1,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': -1},
            ],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-negative-node-id');
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containerNodeIdInvalid',
      );
    });

    test('nodeId 非 int 时（未声明 response schema）投影自行判定为缺陷', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        withResponseSchema: false,
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 1,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 'forty-one'},
            ],
          },
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-non-int-node-id',
      );
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      // 未声明 responseSchema：应答本身仍是 accepted（legacyUnvalidated），
      // 投影靠自己的类型判定拦住，不依赖通用 schema 校验先行拒绝。
      expect(response['admission'], 'accepted');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containerNodeIdInvalid',
      );
    });
  });

  group('老 reader 忽略新键 / 兼容义务', () {
    test('旧源码只传五个必填参数仍可构造，executionDetails 缺省为 null', () {
      const PatchbayAuditEvent legacy = PatchbayAuditEvent(
        command: 'ui.reveal',
        requestId: 'req-legacy',
        parameterShape: <String, Object?>{},
        gateResult: 'passed',
        executionClassification: null,
      );

      expect(legacy.executionDetails, isNull);
      expect(legacy.toJson().containsKey('executionDetails'), isFalse);
    });

    test('存在时 executionDetails 追加在既有键之后', () {
      const PatchbayAuditEvent event = PatchbayAuditEvent(
        command: 'ui.reveal',
        requestId: 'req-new',
        parameterShape: <String, Object?>{},
        gateResult: 'passed',
        executionClassification: null,
        admissionStage: 'responseValidation',
        gateDisposition: 'notDeclared',
        executionDetails: PatchbayAuditExecutionDetails(
          reveal: PatchbayAuditRevealExecutionDetails(
            steps: 1,
            containerNodeIds: <int>[1],
          ),
        ),
      );

      expect(event.toJson().keys.toList().sublist(4), <String>[
        'executionClassification',
        'admissionStage',
        'gateDisposition',
        'executionDetails',
      ]);
    });
  });

  group('VM 与 direct 同一 host 路径一致', () {
    test('同一 host 无论走 dispatchInvoke 还是 handleInvoke，投影结果一致', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 2,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 9},
            ],
          },
        ).toJson(),
      );

      await host.dispatchInvoke('ui.reveal', const <String, Object?>{
        'identifier': 'a',
      }, 'req-direct');
      await host.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': 'ui.reveal',
          'args': jsonEncode(<String, Object?>{'identifier': 'a'}),
          'requestId': 'req-vm',
        },
      );

      expect(host.auditEvents, hasLength(2));
      expect(
        host.auditEvents[0].executionDetails?.toJson(),
        host.auditEvents[1].executionDetails?.toJson(),
      );
      expect(host.auditEvents[0].executionDetails?.toJson(), <String, Object?>{
        'reveal': <String, Object?>{
          'steps': 2,
          'containerNodeIds': <int>[9],
        },
      });
    });
  });
}

const Map<String, Object?> _revealResponseSchema = <String, Object?>{
  'accepted': <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'steps': <String, Object?>{'type': 'integer'},
      'containers': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'nodeId': <String, Object?>{'type': 'integer'},
          },
          'required': <String>['nodeId'],
          'additionalProperties': true,
        },
      },
    },
    'required': <String>['steps', 'containers'],
    'additionalProperties': true,
  },
};

Map<String, Object?> _revealRow({
  String name = 'ui.reveal',
  String sideEffect = 'external',
  bool withResponseSchema = true,
}) => <String, Object?>{
  'name': name,
  'mode': 'immediate',
  'sideEffect': sideEffect,
  'factSources': <String>['uiObserved'],
  if (withResponseSchema) 'responseSchema': _revealResponseSchema,
};

PatchbayServiceHost _host({
  PatchbayInvocationSource? invoke,
  PatchbayAuditSink? auditSink,
  PatchbayAuditSinkErrorHandler? onAuditSinkError,
  bool withResponseSchema = true,
  List<Map<String, Object?>>? commands,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.reveal-execution-details-audit-test',
  registrar: (_, _) {},
  catalog: () async => <String, Object?>{
    'commands':
        commands ??
        <Map<String, Object?>>[
          _revealRow(withResponseSchema: withResponseSchema),
        ],
  },
  snapshot: () async => const <String, Object?>{},
  invoke:
      invoke ??
      (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
  auditSink: auditSink,
  onAuditSinkError: onAuditSinkError,
);

String? _code(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}

/// `AuditDispatcher._report` delivers through `Timer.run`, one macrotask
/// after `drainAudit()`'s Future (delivery pump, microtask-driven) settles —
/// so a defect test must poll past that macrotask boundary rather than
/// assume the observer already ran. Mirrors `audit_delivery_test.dart`.
Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not reached');
}
