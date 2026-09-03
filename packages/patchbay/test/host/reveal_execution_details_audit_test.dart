import 'dart:convert';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

/// PB-050-26 / DG-060-04：`ui.reveal` 的 accepted 响应在通过 response schema 与
/// 语义校验之后，core host 把 `steps` 与被驱动容器 nodeId 投影进 host-only
/// `PatchbayAuditEvent.executionDetails`。裁决把这条投影钉死为「只读已校验
/// response、越界整块省略并报告既有 error observer」，因此本文件只从
/// `host.auditEvents` 断言，不断言任何应答字段——`executionDetails` 从不进入
/// invocation envelope，和 PB-050-39 的 `admissionStage` / `gateDisposition`
/// 走同一条兼容边界。
///
/// 目录一律来自**生产 descriptor**（`patchbayUiRevealCommandDescriptor`）：裁决
/// 的前提是「payload 已通过 response schema 校验」，用手写 schema 合成目录行会
/// 把这条前提测成自证。唯一使用降级目录行的是「未声明 schema 的 host」那一格，
/// 它测的正是投影器防御底线，不是生产路径。
void main() {
  group('生产 descriptor 的 responseSchema 前提', () {
    test('ui.reveal 声明 responseSchema，且目录行可被 host 重新解析', () {
      final Map<String, Object?> row = patchbayUiRevealCommandDescriptor
          .toJson();

      expect(patchbayUiRevealCommandDescriptor.responseSchema, isNotNull);
      expect(row.containsKey('responseSchema'), isTrue);
      // host 是从目录 JSON 重新解析 schema 的，声明必须能过 fromJson 与上限检查。
      final PatchbayResponseSchema parsed = PatchbayResponseSchema.fromJson(
        row['responseSchema'],
      );
      validatePatchbayResponseSchema(parsed);
      expect(parsed.terminal, isEmpty, reason: 'reveal 是 immediate，不是 job');
    });

    test('0.5.0 冻结的 revealed / failed 受理 payload 逐字通过声明的 schema', () {
      final PatchbayResponseSchema schema = PatchbayResponseSchema.fromJson(
        patchbayUiRevealCommandDescriptor.toJson()['responseSchema'],
      );

      for (final Map<String, Object?> payload in <Map<String, Object?>>[
        _frozenRevealedPayload,
        _frozenFailedPayload,
      ]) {
        expect(
          validatePatchbayResponsePayload(schema.accepted, payload)
              .map((PatchbayResponseValidationIssue issue) => issue.toJson())
              .toList(),
          isEmpty,
          reason: '$payload',
        );
      }
    });

    test('accepted 的 ui.reveal 自本版起是 validated，不再 legacyUnvalidated', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: _frozenRevealedPayload,
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-schema-mode',
      );

      expect(response['admission'], 'accepted');
      expect(response['schemaMode'], 'validated');
    });
  });

  group('absent：非 reveal 命令、拒绝、provider 违规', () {
    test('非 ui.reveal 命令即使 payload 恰好带 steps/containers 也不投影', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_revealRow(name: 'device.status')],
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

    test('缺 containers 是 provider 违规，省略 executionDetails 且不报缺陷', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{'steps': 3},
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-schema-violation',
      );
      await host.drainAudit();

      expect(_code(response), 'providerProtocolViolation');
      expect(response['schemaMode'], 'validated');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(reported, isEmpty, reason: '目录已声明 schema，这不是 host 投影缺陷');
    });
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

    test('steps 0 却带容器：语义不变式被违反，整块省略并报告 defect', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 0,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 7},
            ],
          },
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-zero-steps-with-containers',
      );
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      // schema 只管类型，这条形状是**语义**不变式：应答本身仍然受理。
      expect(response['admission'], 'accepted');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containersPresentWithZeroSteps',
      );
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

    test('重复的 containerNodeId 不可能是首次驱动顺序，整块省略并报告 defect', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 2,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 7},
              <String, Object?>{'nodeId': 7},
            ],
          },
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-duplicate-node-id',
      );
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      expect(response['admission'], 'accepted');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containerNodeIdDuplicated',
      );
    });
  });

  group('上限 200 与 201 越界', () {
    test('steps 恰好 200 在界内', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 200,
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 1},
            ],
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
            'containers': <Map<String, Object?>>[
              <String, Object?>{'nodeId': 1},
            ],
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

  group('nodeId 的类型与范围：schema 在上游，范围在投影器', () {
    test('nodeId 为负数视为投影缺陷，即便声明的 schema 只检查类型', () async {
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

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-negative-node-id',
      );
      await host.drainAudit();
      await _waitUntil(() => reported.isNotEmpty);

      expect(response['admission'], 'accepted');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(
        (reported.single as PatchbayAuditExecutionDetailsProjectionDefect)
            .reason,
        'containerNodeIdInvalid',
      );
    });

    test('生产目录下 steps 非 int 走 providerProtocolViolation，不是静默投影', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 'three',
            'containers': <Object?>[],
          },
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-non-int-steps',
      );
      await host.drainAudit();

      expect(_code(response), 'providerProtocolViolation');
      expect(_details(response)?['field'], r'$.payload.steps');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(reported, isEmpty);
    });

    test('生产目录下 containers 非数组走 providerProtocolViolation', () async {
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{'steps': 1, 'containers': 'nope'},
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-non-list-containers',
      );

      expect(_code(response), 'providerProtocolViolation');
      expect(_details(response)?['field'], r'$.payload.containers');
      expect(host.auditEvents.single.executionDetails, isNull);
    });

    test('生产目录下 nodeId 非 int 走 providerProtocolViolation', () async {
      final PatchbayServiceHost host = _host(
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

      expect(_code(response), 'providerProtocolViolation');
      expect(_details(response)?['field'], r'$.payload.containers[0].nodeId');
      expect(host.auditEvents.single.executionDetails, isNull);
    });

    test('未声明 responseSchema 的 host：投影器沉默省略，不冒充缺陷', () async {
      final List<Object> reported = <Object>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_revealRowWithoutResponseSchema()],
        auditSink: (PatchbayAuditEvent _) {},
        onAuditSinkError: (Object error, StackTrace _, PatchbayAuditEvent __) =>
            reported.add(error),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{
            'steps': 'three',
            'containers': <Object?>[],
          },
        ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'ui.reveal',
        const <String, Object?>{'identifier': 'a'},
        'req-legacy-unvalidated',
      );
      await host.drainAudit();

      // 缺声明是「目录没承诺校验」，不是「host 投影出错」：应答按老路径受理，
      // 投影器保持防御式 null 而不报 defect。
      expect(response['admission'], 'accepted');
      expect(response['schemaMode'], 'legacyUnvalidated');
      expect(host.auditEvents.single.executionDetails, isNull);
      expect(reported, isEmpty);
    });
  });

  group('缺陷 reason 词表封闭', () {
    test('投影器只会报这五个 reason', () {
      expect(patchbayAuditExecutionDetailsDefectReasons, <String>{
        'stepsOutOfRange',
        'containerNodeIdsTooLong',
        'containersPresentWithZeroSteps',
        'containerNodeIdInvalid',
        'containerNodeIdDuplicated',
      });
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

/// DG-050-10 冻结的 `outcome: revealed` 受理 payload（`semantics-scroll-reveal.md`
/// 的字段表 + `PatchbayRevealResultWire.toJson`）。
const Map<String, Object?> _frozenRevealedPayload = <String, Object?>{
  'outcome': 'revealed',
  'source': 'uiObserved',
  'identifier': 'reveal.target',
  'steps': 2,
  'elapsedMs': 17,
  'containers': <Map<String, Object?>>[
    <String, Object?>{
      'nodeId': 41,
      'generation': 2,
      'steps': 2,
      'direction': 'forward',
      'extentGrowthSteps': 1,
    },
  ],
  'nodeId': 11,
  'generation': 4,
  'reachability': 'pointer',
  'beforeTreeRevision': 1,
  'afterTreeRevision': 2,
};

/// 同一张表的 `outcome: failed` 一侧：没有 `reachability`，多出 `reason` /
/// `failureType` / `gateId` / `gateCode`。声明的 schema 不能把这一侧误判成违规。
const Map<String, Object?> _frozenFailedPayload = <String, Object?>{
  'outcome': 'failed',
  'source': 'uiObserved',
  'identifier': 'reveal.target',
  'steps': 1,
  'elapsedMs': 9,
  'containers': <Map<String, Object?>>[
    <String, Object?>{
      'nodeId': 41,
      'generation': 2,
      'steps': 1,
      'direction': 'both',
      'extentGrowthSteps': 0,
    },
  ],
  'beforeTreeRevision': 1,
  'afterTreeRevision': 2,
  'reason': 'gateRejected',
  'failureType': 'StateError',
  'gateId': 'consumer.gate',
  'gateCode': 'uiRevealDenied',
};

/// 生产目录行。`name` 可改写，用来证明投影的闸是命令名而不是「碰巧没声明
/// schema」——改名后的行仍然带同一份 schema。
Map<String, Object?> _revealRow({String name = 'ui.reveal'}) =>
    <String, Object?>{
      ...patchbayUiRevealCommandDescriptor.toJson(),
      'name': name,
    };

/// 同一行去掉 `responseSchema`，复刻一个还没声明校验的 host。
Map<String, Object?> _revealRowWithoutResponseSchema() =>
    _revealRow()..remove('responseSchema');

PatchbayServiceHost _host({
  PatchbayInvocationSource? invoke,
  PatchbayAuditSink? auditSink,
  PatchbayAuditSinkErrorHandler? onAuditSinkError,
  List<Map<String, Object?>>? commands,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.reveal-execution-details-audit-test',
  registrar: (_, _) {},
  catalog: () async => <String, Object?>{
    'commands': commands ?? <Map<String, Object?>>[_revealRow()],
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

Map<Object?, Object?>? _details(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  final Object? details = rejection is Map<Object?, Object?>
      ? rejection['details']
      : null;
  return details is Map<Object?, Object?> ? details : null;
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
