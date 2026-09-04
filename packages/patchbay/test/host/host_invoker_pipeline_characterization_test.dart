// PB-050-38：`host_invoker.dart` 按 admission pipeline 阶段拆分前的**表征基线**。
//
// 这个文件不改任何实现，也不主张任何新行为：它把 core host 当前对外的形状逐字钉住，
// 好让下一个提交的结构拆分有一份「拆之前长这样」的机器证据。拆分前后必须同样绿。
//
// 断言口径是 `jsonEncode` 而不是 `Map` 相等——稳定 JSON 的**键序**也是契约的一部分，
// `Map` 相等看不见键序漂移，而 CLI 与老 reader 都按位置读过这些块。
//
// 覆盖面按 DG-060-04 冻结的 pipeline 逐阶段取终态：catalog validity → sensitive
// input → base gate → descriptor gate → post-await recheck → dispatch →
// response validation → audit projection，另加 external 账本（幂等 replay、
// requestId 冲突、重复请求）与取消冻结应答。registry-owned 与 external 两类命令
// 各走一遍同一条前半 pipeline。
//
// 两个形状端到端不可达，因此不在这里，改由拆分后的阶段单测直接构造覆盖：
// `requestLedgerFull` 被 coordinator 的 owner 容量先挡住；门拒绝里的
// `priorRequestObserved` 需要「账本已有记录但 preflight 没有短路」，而 preflight 命中
// 记录时总会先重放或先拒。两者都是既有实现的事实，本 MR 不改。
import 'dart:async';
import 'dart:convert';

import 'package:patchbay/patchbay_host.dart';
import 'package:test/test.dart';

void main() {
  group('external 命令走完整 pipeline 的每一种终态', () {
    test('catalog 违规：应答与审计', () async {
      final PatchbayServiceHost host = _host(
        catalog: () async => <String, Object?>{'commands': 'not-a-list'},
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-catalog',
      );

      _pin(
        'catalog.response',
        response,
        '{"schemaVersion":1,"requestId":"req-catalog","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"catalogUnavailable","catalog":{"reason":"commandsNotAnArray"}}}}',
      );
      _pinAudit(
        host,
        'catalog.audit',
        '{"command":"device.write","requestId":"req-catalog","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"notEvaluated","executionClassification":null,"admissionStage":"catalog","gateDisposition":"notReached"}',
      );
    });

    test('sensitive input 拒绝：应答与审计', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            gates: <String>['unlockedGate'],
            parameters: <Map<String, Object?>>[
              <String, Object?>{
                'name': 'secret',
                'type': 'string',
                'sensitive': true,
              },
            ],
          ),
        ],
        domainGates: _gates(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'secret': 'literal'},
        'req-sensitive',
      );

      _pin(
        'inputPolicy.response',
        response,
        '{"schemaVersion":1,"requestId":"req-sensitive","admission":"rejected","payload":{},"notice":"Sensitive arguments are accepted only from stdin.","jobId":null,"rejection":{"code":"sensitiveInputRequiresStdin","notice":"Sensitive arguments are accepted only from stdin.","details":{"parameters":["secret"]}}}',
      );
      _pinAudit(
        host,
        'inputPolicy.audit',
        '{"command":"device.write","requestId":"req-sensitive","parameterShape":{"type":"object","length":"1","keys":{"secret":{"type":"string","length":"6-20"}}},"gateResult":"notEvaluated","executionClassification":null,"admissionStage":"inputPolicy","gateDisposition":"notReached"}',
      );
    });

    test('base gate 拒绝：应答与审计', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(baseAllowed: false),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-base',
      );

      _pin(
        'baseGate.response',
        response,
        '{"schemaVersion":1,"requestId":"req-base","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"baseGateRejected","details":{"gateId":"patchbay.base"}}}',
      );
      _pinAudit(
        host,
        'baseGate.audit',
        '{"command":"device.write","requestId":"req-base","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"rejected","executionClassification":null,"admissionStage":"baseGate","gateDisposition":"rejected"}',
      );
    });

    test('descriptor gate 拒绝：应答与审计', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['sealedGate']),
        ],
        domainGates: _gates(rejectedGateIds: const <String>{'sealedGate'}),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-declared',
      );

      _pin(
        'descriptorGate.response',
        response,
        '{"schemaVersion":1,"requestId":"req-declared","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"consumerGateRejected","details":{"gateId":"sealedGate"}}}',
      );
      _pinAudit(
        host,
        'descriptorGate.audit',
        '{"command":"device.write","requestId":"req-declared","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"rejected","executionClassification":null,"admissionStage":"descriptorGate","gateDisposition":"rejected"}',
      );
    });

    test('声明了门却没有 evaluator：不可满足的契约按拒绝作答', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['zeta', 'alpha']),
        ],
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-no-evaluator',
      );

      _pin(
        'gateEvaluatorUnavailable.response',
        response,
        '{"schemaVersion":1,"requestId":"req-no-evaluator","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"consumerGateRejected","details":{"gateId":"alpha","reason":"gateEvaluatorUnavailable"}}}',
      );
      _pinAudit(
        host,
        'gateEvaluatorUnavailable.audit',
        '{"command":"device.write","requestId":"req-no-evaluator","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"rejected","executionClassification":null,"admissionStage":"descriptorGate","gateDisposition":"rejected"}',
      );
    });

    test('门后目录漂移：postAwaitRecheck 停在 catalogGateDrift', () async {
      final _MutableProvider provider = _MutableProvider(
        commands: <Object?>[
          _row('device.write', gates: <String>['write']),
        ],
      );
      final PatchbayServiceHost host = PatchbayServiceHost.withCatalogProvider(
        applicationId: 'dev.patchbay.host-invoker-characterization',
        registrar: (_, _) {},
        catalogProvider: provider,
        snapshot: () async => const <String, Object?>{},
        domainGates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) async {
            provider
              ..revision += 1
              ..commands = <Object?>[
                _row('device.write', gates: <String>['write', 'audit']),
              ];
            return const PatchbayGateDecision.allow();
          },
        ),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-drift',
      );

      _pin(
        'postAwaitRecheck.response',
        response,
        '{"schemaVersion":1,"requestId":"req-drift","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"catalogGateDrift","command":"device.write"}}}',
      );
      _pinAudit(
        host,
        'postAwaitRecheck.audit',
        '{"command":"device.write","requestId":"req-drift","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"postAwaitRecheck","gateDisposition":"passed"}',
      );
    });

    test('handler accepted，无 responseSchema：legacyUnvalidated', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            PatchbayInvocation.accepted(
              requestId: requestId,
              payload: const <String, Object?>{'ok': true},
            ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'inputWasStdin': true},
        'req-accepted',
      );

      _pin(
        'dispatch.accepted.response',
        response,
        '{"schemaVersion":1,"requestId":"req-accepted","admission":"accepted","payload":{"ok":true},"notice":null,"jobId":null,"rejection":null,"schemaMode":"legacyUnvalidated"}',
      );
      _pinAudit(
        host,
        'dispatch.accepted.audit',
        '{"command":"device.write","requestId":"req-accepted","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"responseValidation","gateDisposition":"notDeclared"}',
      );
    });

    test('handler rejected：拒绝原样穿过，schemaMode 仍然投影', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            PatchbayInvocation.rejected(
              requestId: requestId,
              rejection: const PatchbayRejection(
                code: 'deviceBusy',
                details: <String, Object?>{'retryAfterMs': 500},
              ),
            ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-handler-rejected',
      );

      _pin(
        'dispatch.rejected.response',
        response,
        '{"schemaVersion":1,"requestId":"req-handler-rejected","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"deviceBusy","details":{"retryAfterMs":500}},"schemaMode":"legacyUnvalidated"}',
      );
      _pinAudit(
        host,
        'dispatch.rejected.audit',
        '{"command":"device.write","requestId":"req-handler-rejected","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"responseValidation","gateDisposition":"notDeclared"}',
      );
    });

    test('accepted 载荷违反 responseSchema', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            responseSchema: const PatchbayResponseSchema(
              accepted: PatchbayResponseValueSchema(
                type: PatchbayResponseType.object,
                properties: <String, PatchbayResponseValueSchema>{
                  'ticket': PatchbayResponseValueSchema(
                    type: PatchbayResponseType.string,
                  ),
                },
                required: <String>{'ticket'},
              ),
            ).toJson(),
          ),
        ],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            PatchbayInvocation.accepted(
              requestId: requestId,
              payload: const <String, Object?>{'ticket': 7},
            ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-schema',
      );

      _pin(
        'responseValidation.schema.response',
        response,
        '{"schemaVersion":1,"requestId":"req-schema","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"wrongType","field":"\$.payload.ticket","expected":"string","violations":[{"field":"\$.payload.ticket","reason":"wrongType","expected":"string"}]}},"schemaMode":"validated"}',
      );
      _pinAudit(
        host,
        'responseValidation.schema.audit',
        '{"command":"device.write","requestId":"req-schema","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"responseValidation","gateDisposition":"notDeclared"}',
      );
    });

    test('accepted 载荷违反执行证据契约', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            PatchbayInvocation.accepted(
              requestId: requestId,
              payload: const <String, Object?>{
                'execution': <String, Object?>{'bogus': 1},
              },
            ).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-evidence',
      );

      _pin(
        'responseValidation.evidence.response',
        response,
        '{"schemaVersion":1,"requestId":"req-evidence","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"unknownField","field":"\$.payload.execution.bogus","violations":[{"field":"\$.payload.execution.bogus","reason":"unknownField"},{"field":"\$.payload.execution.classification","reason":"missingField"},{"field":"\$.payload.execution.factSource","reason":"missingField"},{"field":"\$.payload.execution.observedAtMs","reason":"missingField"},{"field":"\$.payload.execution.reasonCode","reason":"missingField"}]}},"schemaMode":"legacyUnvalidated"}',
      );
    });

    test('provider 返回的信封不是 invocation：malformedEnvelope', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String _) async =>
            const <String, Object?>{'nonsense': true},
      );

      _pin(
        'responseValidation.malformed.response',
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-malformed',
        ),
        '{"schemaVersion":1,"requestId":"req-malformed","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"malformedEnvelope"}}}',
      );
    });

    test('provider 回错 requestId：requestIdMismatch', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String _) async =>
            PatchbayInvocation.accepted(requestId: 'other').toJson(),
      );

      _pin(
        'responseValidation.requestId.response',
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-mismatch',
        ),
        '{"schemaVersion":1,"requestId":"req-mismatch","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"requestIdMismatch"}}}',
      );
    });

    test('rejected 却带 payload：语义违规', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async =>
            <String, Object?>{
              ...PatchbayInvocation.rejected(
                requestId: requestId,
                rejection: const PatchbayRejection(code: 'deviceBusy'),
              ).toJson(),
              'payload': <String, Object?>{'leak': 1},
            },
      );

      _pin(
        'responseValidation.semantic.response',
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-semantic',
        ),
        '{"schemaVersion":1,"requestId":"req-semantic","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"providerProtocolViolation","details":{"reason":"rejectedWithPayload"}}}',
      );
    });
  });

  group('external 账本', () {
    test('幂等 replay：同一应答重放，且只记一次审计', () async {
      var calls = 0;
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            retryPolicy: const <String, Object?>{
              'maxAttempts': 2,
              'backoffMs': 0,
            },
          ),
        ],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String requestId) async {
          calls += 1;
          return PatchbayInvocation.accepted(
            requestId: requestId,
            payload: <String, Object?>{'attempt': calls},
          ).toJson();
        },
      );

      final Map<String, Object?> first = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'a': 1},
        'req-replay',
      );
      final Map<String, Object?> second = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'a': 1},
        'req-replay',
      );

      expect(calls, 1, reason: '幂等重放不得再次触达 provider');
      _pin(
        'ledger.replay.first',
        first,
        '{"schemaVersion":1,"requestId":"req-replay","admission":"accepted","payload":{"attempt":1},"notice":null,"jobId":null,"rejection":null,"schemaMode":"legacyUnvalidated"}',
      );
      expect(jsonEncode(second), jsonEncode(first), reason: '重放逐字节相同');
      expect(host.auditEvents, hasLength(1), reason: '重放不再记一次审计');
    });

    test('同一 requestId 换了参数：requestIdConflict', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            retryPolicy: const <String, Object?>{
              'maxAttempts': 2,
              'backoffMs': 0,
            },
          ),
        ],
        domainGates: _gates(),
      );

      await host.dispatchInvoke('device.write', const <String, Object?>{
        'a': 1,
      }, 'req-conflict');
      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'a': 2},
        'req-conflict',
      );

      _pin(
        'ledger.conflict.response',
        response,
        '{"schemaVersion":1,"requestId":"req-conflict","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"requestIdConflict"}}',
      );
      _pin(
        'ledger.conflict.audit',
        host.auditEvents.last.toJson(),
        '{"command":"device.write","requestId":"req-conflict","parameterShape":{"type":"object","length":"1","keys":{"a":{"type":"integer"}}},"gateResult":"notEvaluated","executionClassification":null,"admissionStage":"dispatch","gateDisposition":"notReached"}',
      );
    });

    test('非幂等命令重复请求：duplicateRequestId', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: _gates(),
      );

      await host.dispatchInvoke('device.write', const <String, Object?>{
        'a': 1,
      }, 'req-duplicate');
      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'a': 1},
        'req-duplicate',
      );

      _pin(
        'ledger.duplicate.response',
        response,
        '{"schemaVersion":1,"requestId":"req-duplicate","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"duplicateRequestId"}}',
      );
    });

    // 账本先于门，只在**已有记录**这一条路径上成立：preflight 命中记录就直接重放，
    // 门不再求值。这条顺序是可观察的，钉住它才能在拆分后证明 preflight 仍在编排最前。
    test('已受理过的幂等 requestId 再次到达：preflight 直接重放，门不再求值', () async {
      var evaluations = 0;
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            gates: <String>['sealedGate'],
            retryPolicy: const <String, Object?>{
              'maxAttempts': 2,
              'backoffMs': 0,
            },
          ),
        ],
        domainGates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) {
            evaluations += 1;
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final Map<String, Object?> first = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-prior',
      );
      final Map<String, Object?> second = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-prior',
      );

      expect(evaluations, 1, reason: '重放不再过门');
      expect(jsonEncode(second), jsonEncode(first));
      _pin(
        'ledger.replayBeforeGate.response',
        second,
        '{"schemaVersion":1,"requestId":"req-prior","admission":"accepted","payload":{},"notice":null,"jobId":null,"rejection":null,"schemaMode":"legacyUnvalidated"}',
      );
    });
  });

  group('取消冻结应答', () {
    test('取消后 handler 的结果被冻结应答顶掉，审计记冻结形状', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.run')],
        domainGates: _gates(),
        invoke: (String _, Map<String, Object?> _, String _) => handler.future,
      );

      final Future<Map<String, Object?>> response = host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'req-cancel',
        ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
      );
      await Future<void>.delayed(Duration.zero);
      await host.cancelInvocation(
        command: 'device.run',
        requestId: 'req-cancel',
        ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
      );
      handler.complete(
        PatchbayInvocation.accepted(requestId: 'req-cancel').toJson(),
      );

      _pin(
        'cancellation.frozen.response',
        await response,
        '{"schemaVersion":1,"requestId":"req-cancel","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"invocationCancelled","details":{"reason":"explicitRequest","cancellation":"unsupported"}}}',
      );
      _pinAudit(
        host,
        'cancellation.frozen.audit',
        '{"command":"device.run","requestId":"req-cancel","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"dispatch","gateDisposition":"notDeclared"}',
      );
    });
  });

  group('registry-owned 命令走同一条前半 pipeline', () {
    test('accepted：registry handler 的结果同样过 response validation', () async {
      final PatchbayServiceHost host = _host(
        domainGates: _gates(),
        registry: _registry(
          gates: const <String>{},
          handle: (Map<String, Object?> _, String requestId) =>
              PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{'served': true},
              ).toJson(),
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'patchbay.registered',
        const <String, Object?>{},
        'req-registry',
      );

      _pin(
        'registry.accepted.response',
        response,
        '{"schemaVersion":1,"requestId":"req-registry","admission":"accepted","payload":{"served":true},"notice":null,"jobId":null,"rejection":null,"schemaMode":"legacyUnvalidated"}',
      );
      _pinAudit(
        host,
        'registry.accepted.audit',
        '{"command":"patchbay.registered","requestId":"req-registry","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"passed","executionClassification":null,"admissionStage":"responseValidation","gateDisposition":"notDeclared"}',
      );
    });

    test('base gate 拒绝：与 external 同形', () async {
      final PatchbayServiceHost host = _host(
        domainGates: _gates(baseAllowed: false),
        registry: _registry(
          gates: const <String>{},
          handle: (Map<String, Object?> _, String requestId) =>
              PatchbayInvocation.accepted(requestId: requestId).toJson(),
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'patchbay.registered',
        const <String, Object?>{},
        'req-registry-base',
      );

      _pin(
        'registry.baseGate.response',
        response,
        '{"schemaVersion":1,"requestId":"req-registry-base","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"baseGateRejected","details":{"gateId":"patchbay.base"}}}',
      );
      _pinAudit(
        host,
        'registry.baseGate.audit',
        '{"command":"patchbay.registered","requestId":"req-registry-base","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"rejected","executionClassification":null,"admissionStage":"baseGate","gateDisposition":"rejected"}',
      );
    });

    test('descriptor gate 拒绝：声明门由 core 执行，handler 不被触达', () async {
      var handled = false;
      final PatchbayServiceHost host = _host(
        domainGates: _gates(rejectedGateIds: const <String>{'registryGate'}),
        registry: _registry(
          gates: const <String>{'registryGate'},
          handle: (Map<String, Object?> _, String requestId) {
            handled = true;
            return PatchbayInvocation.accepted(requestId: requestId).toJson();
          },
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'patchbay.registered',
        const <String, Object?>{},
        'req-registry-gate',
      );

      expect(handled, isFalse);
      _pin(
        'registry.descriptorGate.response',
        response,
        '{"schemaVersion":1,"requestId":"req-registry-gate","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"consumerGateRejected","details":{"gateId":"registryGate"}}}',
      );
      _pinAudit(
        host,
        'registry.descriptorGate.audit',
        '{"command":"patchbay.registered","requestId":"req-registry-gate","parameterShape":{"type":"object","length":"0","keys":{}},"gateResult":"rejected","executionClassification":null,"admissionStage":"descriptorGate","gateDisposition":"rejected"}',
      );
    });

    test('handler 自己拒绝：拒绝穿过 response validation', () async {
      final PatchbayServiceHost host = _host(
        domainGates: _gates(),
        registry: _registry(
          gates: const <String>{},
          handle: (Map<String, Object?> _, String requestId) =>
              PatchbayInvocation.rejected(
                requestId: requestId,
                rejection: const PatchbayRejection(code: 'notReady'),
              ).toJson(),
        ),
      );

      _pin(
        'registry.handlerRejected.response',
        await host.dispatchInvoke(
          'patchbay.registered',
          const <String, Object?>{},
          'req-registry-rejected',
        ),
        '{"schemaVersion":1,"requestId":"req-registry-rejected","admission":"rejected","payload":{},"notice":null,"jobId":null,"rejection":{"code":"notReady"},"schemaMode":"legacyUnvalidated"}',
      );
    });
  });
}

/// 逐字节钉住一块稳定 JSON。
///
/// 用 `jsonEncode` 而不是 `Map` 相等：键序漂移在 `Map` 相等下看不见，而它同样是契约。
void _pin(String label, Object? actual, String expected) =>
    expect(jsonEncode(actual), expected, reason: label);

void _pinAudit(PatchbayServiceHost host, String label, String expected) =>
    _pin(label, host.auditEvents.single.toJson(), expected);

Map<String, Object?> _row(
  String name, {
  String sideEffect = 'external',
  List<String>? gates,
  List<Map<String, Object?>>? parameters,
  Map<String, Object?>? responseSchema,
  Map<String, Object?>? retryPolicy,
}) => <String, Object?>{
  'name': name,
  'mode': 'immediate',
  'sideEffect': sideEffect,
  'factSources': <String>['appRecorded'],
  if (gates != null) 'gates': gates,
  if (parameters != null) 'parameters': parameters,
  if (responseSchema != null) 'responseSchema': responseSchema,
  if (retryPolicy != null) 'retryPolicy': retryPolicy,
};

PatchbayServiceHost _host({
  List<Map<String, Object?>> commands = const <Map<String, Object?>>[],
  PatchbayGateEvaluator? domainGates,
  PatchbayCatalogSource? catalog,
  PatchbayCommandRegistry? registry,
  PatchbayInvocationSource? invoke,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.host-invoker-characterization',
  registrar: (_, _) {},
  domainGates: domainGates,
  registry: registry,
  catalog: catalog ?? () async => <String, Object?>{'commands': commands},
  snapshot: () async => const <String, Object?>{},
  invoke:
      invoke ??
      (String _, Map<String, Object?> _, String requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
);

PatchbayGateEvaluator _gates({
  bool baseAllowed = true,
  Set<String> rejectedGateIds = const <String>{},
}) => PatchbayGateEvaluator(
  baseGate: () => baseAllowed
      ? const PatchbayGateDecision.allow()
      : const PatchbayGateDecision.reject(code: 'baseGateRejected'),
  consumerGate: (String gateId) => rejectedGateIds.contains(gateId)
      ? const PatchbayGateDecision.reject(code: 'consumerGateRejected')
      : const PatchbayGateDecision.allow(),
);

PatchbayCommandRegistry _registry({
  required Set<String> gates,
  required PatchbayCommandHandler<Map<String, Object?>> handle,
}) => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
  PatchbayCommandRegistration<Map<String, Object?>>(
    descriptor: PatchbayCommandDescriptor(
      name: 'patchbay.registered',
      summary: 'Registry-owned write.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: gates,
    ),
    decode: (Map<String, Object?> arguments) => arguments,
    handle: handle,
  ),
]);

final class _MutableProvider implements PatchbayCatalogProvider {
  _MutableProvider({required this.commands});

  int revision = 0;
  List<Object?> commands;

  @override
  int get commandsRevision => revision;

  @override
  Future<PatchbayCatalogSample> readCatalog() async => PatchbayCatalogSample(
    commandsRevision: revision,
    catalog: <String, Object?>{'commands': commands},
  );
}
