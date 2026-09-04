// PB-050-38：admission pipeline **每个阶段各自**的失败注入。
//
// 表征测试（`host_invoker_pipeline_characterization_test.dart`）证明的是「整条
// 管线对外的形状没变」；这份文件证明的是拆分真的拆开了——每个阶段都能脱离
// `HostInvokerHandler` 单独构造、被单独注入失败，并给出**类型化**的结论。拆完了
// 却只能整条跑，那就只是把私有方法搬了个文件。
//
// 两个端到端不可达的形状在这里第一次拿到覆盖：门拒绝里的 `priorRequestObserved`
// 与账本的 `requestLedgerFull`。整条 host 上前者被 preflight 短路挡住、后者被
// coordinator 的 owner 容量挡住；阶段单元可以直接把账本摆到那个状态。
library;

import 'dart:async';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/src/host/external_invocation_ledger.dart';
import 'package:patchbay/src/host/host_catalog.dart';
import 'package:patchbay/src/host/host_models.dart';
import 'package:patchbay/src/host/invocation_admission_state.dart';
import 'package:patchbay/src/host/invocation_audit_stage.dart';
import 'package:patchbay/src/host/invocation_catalog_stage.dart';
import 'package:patchbay/src/host/invocation_gate_stage.dart';
import 'package:patchbay/src/host/invocation_handler_stage.dart';
import 'package:patchbay/src/host/invocation_input_stage.dart';
import 'package:patchbay/src/host/invocation_response_stage.dart';
import 'package:patchbay/src/invocation_cancellation.dart';
import 'package:test/test.dart';

void main() {
  group('catalog 阶段', () {
    test('注入目录违规：原样出现在 details 里，证明走的是接缝', () async {
      final PatchbayCatalogAdmission admission =
          await patchbayAdmitInvocationCatalog(
            readCatalog: () async => PatchbayCatalogValidity.violated(
              <String, Object?>{'reason': 'injectedByTest'},
            ),
            command: 'device.write',
            requestId: 'req-1',
            frozenCancellationResponse: () => null,
          );

      expect(admission.admitted, isFalse);
      expect(_details(admission.response!), <String, Object?>{
        'reason': 'catalogUnavailable',
        'catalog': <String, Object?>{'reason': 'injectedByTest'},
      });
    });

    test('取消复核先于目录诊断：两者同时成立时冻结应答胜出', () async {
      final PatchbayCatalogAdmission admission =
          await patchbayAdmitInvocationCatalog(
            readCatalog: () async => PatchbayCatalogValidity.violated(
              const <String, Object?>{'reason': 'injectedByTest'},
            ),
            command: 'device.write',
            requestId: 'req-2',
            frozenCancellationResponse: () => const <String, Object?>{
              'frozen': true,
            },
          );

      expect(admission.response, const <String, Object?>{'frozen': true});
    });

    test('目录读取抛出：阶段不吞异常', () async {
      await expectLater(
        patchbayAdmitInvocationCatalog(
          readCatalog: () async => throw StateError('provider down'),
          command: 'device.write',
          requestId: 'req-3',
          frozenCancellationResponse: () => null,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('目录里没有这条命令：按 fail-closed 的 undeclared 处理', () async {
      final PatchbayCatalogAdmission admission =
          await patchbayAdmitInvocationCatalog(
            readCatalog: () async => _validity(),
            command: 'device.unknown',
            requestId: 'req-4',
            frozenCancellationResponse: () => null,
          );

      expect(admission.admitted, isTrue);
      expect(admission.policy.writesSideEffect, isTrue, reason: '不在目录里不等于只读');
    });
  });

  group('sensitive input 阶段', () {
    test('空参数：原样放行，且阶段不推进', () {
      final PatchbayInvocationAuditState audit = PatchbayInvocationAuditState();
      const Map<String, Object?> arguments = <String, Object?>{};

      final PatchbayInputAdmission admission = patchbayAdmitInvocationInput(
        requestId: 'req-1',
        policy: _policy(sensitive: const <String>{'secret'}),
        arguments: arguments,
        audit: audit,
      );

      expect(admission.admitted, isTrue);
      expect(identical(admission.forwarded, arguments), isTrue);
      expect(
        audit.admissionStage,
        'catalog',
        reason: '没有参数就没有判定，推进阶段会让审计谎报走过一段',
      );
    });

    test('注入敏感参数：拒绝并把阶段推进到 inputPolicy', () {
      final PatchbayInvocationAuditState audit = PatchbayInvocationAuditState();

      final PatchbayInputAdmission admission = patchbayAdmitInvocationInput(
        requestId: 'req-2',
        policy: _policy(sensitive: const <String>{'apiKey', 'password'}),
        arguments: const <String, Object?>{
          'password': 'hunter2',
          'apiKey': 'ak',
        },
        audit: audit,
      );

      expect(_code(admission.rejection!), 'sensitiveInputRequiresStdin');
      expect(_details(admission.rejection!)['parameters'], <String>[
        'apiKey',
        'password',
      ]);
      expect(audit.admissionStage, 'inputPolicy');
    });

    test('stdin 出处按 plane 决定去留', () {
      const Map<String, Object?> arguments = <String, Object?>{
        'a': 1,
        'inputWasStdin': true,
      };

      expect(
        patchbayAdmitInvocationInput(
          requestId: 'req-3',
          policy: _policy(retainsStdinProvenance: true),
          arguments: arguments,
        ).forwarded,
        arguments,
      );
      expect(
        patchbayAdmitInvocationInput(
          requestId: 'req-4',
          policy: _policy(),
          arguments: arguments,
        ).forwarded,
        const <String, Object?>{'a': 1},
      );
    });
  });

  group('gate 阶段', () {
    // 「需不需要过门」是**同步**判定，且必须在编排层短路：`admit` 本身是 async，
    // 让它顺带回答「不需要」会平白多让出一个微任务，进而改变只读命令的取消观察时机。
    // 让步轮次由 `host_invoker_microtask_depth_test.dart` 实测钉住，这里钉的是判据。
    test('只读且无声明门：判定为不需要过门，结论是同步常量', () {
      expect(
        PatchbayInvocationGateStage.requiresCoreAdmission(
          _policy(writes: false),
        ),
        isFalse,
      );
      expect(PatchbayInvocationGateStage.admissionNotRequired.refusal, isNull);
      expect(
        PatchbayInvocationGateStage.admissionNotRequired.coreGateEvaluated,
        isFalse,
      );
    });

    test('只读但声明了门：仍然要过门，声明存在却从不执行才是缺口', () {
      expect(
        PatchbayInvocationGateStage.requiresCoreAdmission(
          _policy(writes: false, declared: const <String>{'sealed'}),
        ),
        isTrue,
      );
    });

    test('注入抛出的 evaluator：阶段不吞异常', () async {
      await expectLater(
        _gateStage(
          gates: PatchbayGateEvaluator(
            baseGate: () => throw StateError('policy exploded'),
            consumerGate: (String _) => const PatchbayGateDecision.allow(),
          ),
        ).admit(
          command: 'device.write',
          requestId: 'req-2',
          policy: _policy(),
          onGateResult: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('声明了门却没有 evaluator：取字典序最小的门 id，并记 rejected', () async {
      final PatchbayInvocationAuditState audit = PatchbayInvocationAuditState();

      final PatchbayGateAdmission admission = await _gateStage(gates: null)
          .admit(
            command: 'device.write',
            requestId: 'req-3',
            policy: _policy(declared: const <String>{'zeta', 'alpha'}),
            onGateResult: (String value) => audit.gateResult = value,
            audit: audit,
          );

      expect(_code(admission.refusal!), 'consumerGateRejected');
      expect(_details(admission.refusal!), <String, Object?>{
        'gateId': 'alpha',
        'reason': 'gateEvaluatorUnavailable',
      });
      expect(audit.admissionStage, 'descriptorGate');
      expect(audit.gateDisposition, 'rejected');
      expect(admission.coreGateEvaluated, isFalse, reason: '没有求值器就没评估过');
    });

    // 端到端不可达：整条 host 上 preflight 命中记录时总会先重放或先拒，门看不到
    // 已有记录。阶段单元可以直接注入「账本说有」，这条 details 分支才拿到覆盖。
    test('注入「账本已有这条 requestId」：门拒绝补 priorRequestObserved', () async {
      final PatchbayGateAdmission admission =
          await _gateStage(
            gates: PatchbayGateEvaluator(
              baseGate: () =>
                  const PatchbayGateDecision.reject(code: 'baseGateRejected'),
              consumerGate: (String _) => const PatchbayGateDecision.allow(),
            ),
            priorRequestObserved: true,
          ).admit(
            command: 'device.write',
            requestId: 'req-4',
            policy: _policy(),
            onGateResult: (_) {},
          );

      expect(_details(admission.refusal!), <String, Object?>{
        'gateId': 'patchbay.base',
        'priorRequestObserved': true,
      });
    });

    test('base gate 拒绝停在 baseGate，声明门拒绝停在 descriptorGate', () async {
      final PatchbayInvocationAuditState base = PatchbayInvocationAuditState();
      await _gateStage(
        gates: PatchbayGateEvaluator(
          baseGate: () =>
              const PatchbayGateDecision.reject(code: 'baseGateRejected'),
          consumerGate: (String _) => const PatchbayGateDecision.allow(),
        ),
      ).admit(
        command: 'device.write',
        requestId: 'req-5',
        policy: _policy(),
        onGateResult: (_) {},
        audit: base,
      );
      expect(base.admissionStage, 'baseGate');

      final PatchbayInvocationAuditState declared =
          PatchbayInvocationAuditState();
      await _gateStage(
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) =>
              const PatchbayGateDecision.reject(code: 'consumerGateRejected'),
        ),
      ).admit(
        command: 'device.write',
        requestId: 'req-6',
        policy: _policy(declared: const <String>{'sealed'}),
        onGateResult: (_) {},
        audit: declared,
      );
      expect(declared.admissionStage, 'descriptorGate');
      expect(declared.gateDisposition, 'rejected');
    });

    test('门后复核：声明集在 await 期间漂移就 fail-closed', () async {
      final PatchbayInvocationAuditState audit = PatchbayInvocationAuditState();
      var reads = 0;

      // 门阶段自己只读一次目录：门前那次由 catalog 阶段读过并作为 `policy` 传进来。
      // 所以「漂移」在这里表现为唯一那次复核读到的声明集与传入 policy 不一致。
      final PatchbayGateAdmission admission =
          await PatchbayInvocationGateStage(
            gates: PatchbayGateEvaluator(
              baseGate: () => const PatchbayGateDecision.allow(),
              consumerGate: (String _) => const PatchbayGateDecision.allow(),
            ),
            readCatalog: () async {
              reads += 1;
              return _validity(
                command: 'device.write',
                declared: const <String>{'audit'},
              );
            },
            priorRequestObserved: (_, _) => false,
          ).admit(
            command: 'device.write',
            requestId: 'req-7',
            policy: _policy(),
            onGateResult: (_) {},
            audit: audit,
          );

      expect(_details(admission.refusal!), <String, Object?>{
        'reason': 'catalogGateDrift',
        'command': 'device.write',
      });
      expect(reads, 1, reason: '门后只复核一次，不在同一次调用里重跑新声明');
      expect(audit.admissionStage, 'postAwaitRecheck');
      expect(audit.gateDisposition, 'notDeclared', reason: '门确实过了，漂移在门之后');
    });

    test('门后复核：目录在 await 期间整份不可用', () async {
      final PatchbayGateAdmission admission =
          await PatchbayInvocationGateStage(
            gates: PatchbayGateEvaluator(
              baseGate: () => const PatchbayGateDecision.allow(),
              consumerGate: (String _) => const PatchbayGateDecision.allow(),
            ),
            readCatalog: () async => PatchbayCatalogValidity.violated(
              const <String, Object?>{'reason': 'lateViolation'},
            ),
            priorRequestObserved: (_, _) => false,
          ).admit(
            command: 'device.write',
            requestId: 'req-8',
            policy: _policy(),
            onGateResult: (_) {},
          );

      expect(_details(admission.refusal!)['reason'], 'catalogUnavailable');
    });
  });

  group('handler 阶段', () {
    test('注入抛出的外部派发：阶段不吞异常', () async {
      await expectLater(
        _dispatchHandler(
          dispatchExternal: () async => throw TimeoutException('provider hung'),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('handler 之前被取消：外部派发根本不被触达', () async {
      var calls = 0;
      final PatchbayHandlerDispatch dispatch = await _dispatchHandler(
        frozen: () => const <String, Object?>{'frozen': 'before'},
        dispatchExternal: () async {
          calls += 1;
          return const <String, Object?>{};
        },
      );

      expect(dispatch.frozenResponse, const <String, Object?>{
        'frozen': 'before',
      });
      expect(calls, 0);
    });

    test('handler 之后被取消：结果被丢弃，冻结应答胜出', () async {
      var seen = 0;
      final PatchbayHandlerDispatch dispatch = await _dispatchHandler(
        frozen: () => (seen += 1) == 1
            ? null
            : const <String, Object?>{'frozen': 'after'},
        dispatchExternal: () async => const <String, Object?>{'served': true},
      );

      expect(dispatch.frozenResponse, const <String, Object?>{
        'frozen': 'after',
      });
    });

    test('registry 不认这条命令时才回退外部，且回退的结论标注 registered=false', () async {
      final PatchbayHandlerDispatch dispatch = await _dispatchHandler(
        dispatchExternal: () async => const <String, Object?>{'served': true},
      );

      expect(dispatch.registered, isFalse);
      expect(dispatch.result, const <String, Object?>{'served': true});
    });
  });

  group('response validation 阶段', () {
    test('注入不成信封的载荷：malformedEnvelope，且阶段推进到 responseValidation', () {
      final PatchbayInvocationAuditState audit = PatchbayInvocationAuditState();

      final Map<String, Object?> response = patchbayValidateInvocationResponse(
        result: const <String, Object?>{'nonsense': true},
        requestId: 'req-1',
        registered: false,
        responseSchema: null,
        executionContract: null,
        nowMs: () => fail('时钟不该在结构违规时被读'),
        audit: audit,
      );

      expect(_details(response)['reason'], 'malformedEnvelope');
      expect(audit.admissionStage, 'responseValidation');
    });

    test('rejected 信封不读时钟——执行证据只对 accepted 求值', () {
      expect(
        patchbayValidateInvocationResponse(
          result: PatchbayInvocation.rejected(
            requestId: 'req-2',
            rejection: const PatchbayRejection(code: 'deviceBusy'),
          ).toJson(),
          requestId: 'req-2',
          registered: false,
          responseSchema: null,
          executionContract: const PatchbayExecutionContract(
            factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
          ),
          nowMs: () => fail('rejected 不该读时钟'),
        )['schemaMode'],
        'legacyUnvalidated',
      );
    });

    test('时钟恰好读一次：accepted + executionContract 记 1 次，rejected 记 0 次', () {
      var reads = 0;
      int clock() {
        reads += 1;
        return DateTime.now().millisecondsSinceEpoch;
      }

      const PatchbayExecutionContract contract = PatchbayExecutionContract(
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      );

      patchbayValidateInvocationResponse(
        result: PatchbayInvocation.accepted(requestId: 'req-clock-1').toJson(),
        requestId: 'req-clock-1',
        registered: false,
        responseSchema: null,
        executionContract: contract,
        nowMs: clock,
      );
      expect(reads, 1, reason: 'accepted 且声明了执行证据契约，读且只读一次');

      patchbayValidateInvocationResponse(
        result: PatchbayInvocation.rejected(
          requestId: 'req-clock-2',
          rejection: const PatchbayRejection(code: 'deviceBusy'),
        ).toJson(),
        requestId: 'req-clock-2',
        registered: false,
        responseSchema: null,
        executionContract: contract,
        nowMs: clock,
      );
      expect(reads, 1, reason: 'rejected 一次都不读——执行证据只对 accepted 求值');

      patchbayValidateInvocationResponse(
        result: PatchbayInvocation.accepted(requestId: 'req-clock-3').toJson(),
        requestId: 'req-clock-3',
        registered: false,
        responseSchema: null,
        executionContract: null,
        nowMs: clock,
      );
      expect(reads, 1, reason: '没有契约就没有证据要校验，同样不读');
    });

    test('registry handler 的 UI 阶段回填只在 rejected 上生效', () {
      PatchbayInvocationAuditState staged(String stage) =>
          PatchbayInvocationAuditState()..admissionStage = stage;

      final PatchbayInvocationAuditState rejected = staged('uiPreflight');
      patchbayValidateInvocationResponse(
        result: PatchbayInvocation.rejected(
          requestId: 'req-3',
          rejection: const PatchbayRejection(code: 'uiObscuredTarget'),
        ).toJson(),
        requestId: 'req-3',
        registered: true,
        responseSchema: null,
        executionContract: null,
        nowMs: () => 0,
        audit: rejected,
      );
      expect(rejected.admissionStage, 'uiPreflight');

      final PatchbayInvocationAuditState accepted = staged('uiPreflight');
      patchbayValidateInvocationResponse(
        result: PatchbayInvocation.accepted(requestId: 'req-4').toJson(),
        requestId: 'req-4',
        registered: true,
        responseSchema: null,
        executionContract: null,
        nowMs: () => 0,
        audit: accepted,
      );
      expect(
        accepted.admissionStage,
        'responseValidation',
        reason: '受理成功的调用停在 response validation，不回填 UI 阶段',
      );
    });

    test('注入越界 payload：首条 issue 抬到顶层，全量列在 violations 里', () {
      final Map<String, Object?> response = patchbayValidateInvocationResponse(
        result: PatchbayInvocation.accepted(
          requestId: 'req-5',
          payload: const <String, Object?>{'ticket': 7},
        ).toJson(),
        requestId: 'req-5',
        registered: false,
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
        ),
        executionContract: null,
        nowMs: () => 0,
      );

      expect(_details(response)['reason'], 'wrongType');
      expect(response['schemaMode'], 'validated');
    });

    test('语义组合违规是一张封闭清单，逐条给出稳定 reason', () {
      String? violation(Map<String, Object?> envelope) =>
          _details(
                patchbayValidateInvocationResponse(
                  result: envelope,
                  requestId: 'req-6',
                  registered: false,
                  responseSchema: null,
                  executionContract: null,
                  nowMs: () => 0,
                ),
              )['reason']
              as String?;

      expect(
        violation(<String, Object?>{
          ...PatchbayInvocation.rejected(
            requestId: 'req-6',
            rejection: const PatchbayRejection(code: 'deviceBusy'),
          ).toJson(),
          'payload': <String, Object?>{'leak': 1},
        }),
        'rejectedWithPayload',
      );
      expect(
        violation(<String, Object?>{
          ...PatchbayInvocation.rejected(
            requestId: 'req-6',
            rejection: const PatchbayRejection(code: 'deviceBusy'),
          ).toJson(),
          'jobId': 'job-1',
        }),
        'rejectedWithJobId',
      );
      expect(
        violation(<String, Object?>{
          ...PatchbayInvocation.accepted(requestId: 'req-6').toJson(),
          'schemaVersion': 2,
        }),
        'schemaVersionMismatch',
      );
    });
  });

  group('audit 阶段', () {
    test('注入抛出的 sink：缺陷经既有 error observer 上报，本地账本照样准确', () async {
      final List<Object> errors = <Object>[];
      final PatchbayInvocationAuditLedger ledger =
          PatchbayInvocationAuditLedger(
            sink: (PatchbayAuditEvent _) => throw StateError('sink down'),
            onSinkError: (Object error, StackTrace _, PatchbayAuditEvent _) =>
                errors.add(error),
            capacity: 8,
          );

      ledger.record(
        command: 'device.write',
        requestId: 'req-1',
        arguments: const <String, Object?>{},
        gateResult: 'passed',
        response: PatchbayInvocation.accepted(requestId: 'req-1').toJson(),
      );
      await ledger.drain(const Duration(seconds: 2));
      // 缺陷上报走 `Timer.run`，刻意排在投递之后：观察者失败不得改变投递或命令结果。
      await Future<void>.delayed(Duration.zero);

      expect(errors.single, isA<StateError>());
      expect(ledger.events.single.requestId, 'req-1');
    });

    test('环形上限：第 257 条挤掉最早的一条', () {
      final PatchbayInvocationAuditLedger ledger =
          PatchbayInvocationAuditLedger(
            sink: null,
            onSinkError: null,
            capacity: 8,
          );

      for (
        var index = 0;
        index < PatchbayInvocationAuditLedger.retainedEvents + 1;
        index += 1
      ) {
        ledger.record(
          command: 'device.write',
          requestId: 'req-$index',
          arguments: const <String, Object?>{},
          gateResult: 'passed',
          response: PatchbayInvocation.accepted(
            requestId: 'req-$index',
          ).toJson(),
        );
      }

      expect(
        ledger.events,
        hasLength(PatchbayInvocationAuditLedger.retainedEvents),
      );
      expect(ledger.events.first.requestId, 'req-1');
    });

    test('没有 sink 也能 drain，且校验 timeout', () async {
      final PatchbayInvocationAuditLedger ledger =
          PatchbayInvocationAuditLedger(
            sink: null,
            onSinkError: null,
            capacity: 8,
          );

      expect(
        (await ledger.drain(const Duration(seconds: 1))).outcome,
        PatchbayAuditDrainOutcome.drained,
      );
      // 越界 timeout 在**第一次** drain 上判红；已经答过的账本记住那一次结论，
      // 后来的调用拿到同一个 future，这与拆分前逐字一致。
      expect(
        () => PatchbayInvocationAuditLedger(
          sink: null,
          onSinkError: null,
          capacity: 8,
        ).drain(const Duration(minutes: 30)),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('external 账本', () {
    test('并发同一 requestId：preflight 按幂等与所有者给出三种结论', () async {
      final PatchbayExternalInvocationLedger ledger = _ledger();
      await ledger.dispatch(
        command: 'device.write',
        arguments: const <String, Object?>{'a': 1},
        requestId: 'req-1',
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 0),
        onDisposition: (_) {},
        context: _context('req-1'),
        ownerToken: 'AAAAAAAAAAAAAAAAAAAAAA',
      );

      expect(
        ledger
            .preflight(
              command: 'device.write',
              arguments: const <String, Object?>{'a': 1},
              requestId: 'req-1',
              registryOwned: false,
              ownerToken: 'AAAAAAAAAAAAAAAAAAAAAA',
            )
            .replay,
        isNotNull,
      );
      expect(
        _code(
          ledger
              .preflight(
                command: 'device.write',
                arguments: const <String, Object?>{'a': 2},
                requestId: 'req-1',
                registryOwned: false,
                ownerToken: 'AAAAAAAAAAAAAAAAAAAAAA',
              )
              .rejection!,
        ),
        'requestIdConflict',
      );
      expect(
        _code(
          ledger
              .preflight(
                command: 'device.write',
                arguments: const <String, Object?>{'a': 1},
                requestId: 'req-1',
                registryOwned: false,
                ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
              )
              .rejection!,
        ),
        'requestIdConflict',
      );
      expect(
        ledger
            .preflight(
              command: 'device.write',
              arguments: const <String, Object?>{'a': 1},
              requestId: 'req-1',
              registryOwned: true,
              ownerToken: null,
            )
            .isEmpty,
        isTrue,
        reason: 'registry 命令根本不走这本账',
      );
    });

    test('非幂等命令的重复请求是 duplicateRequestId', () async {
      final PatchbayExternalInvocationLedger ledger = _ledger();
      await ledger.dispatch(
        command: 'device.write',
        arguments: const <String, Object?>{},
        requestId: 'req-2',
        retryPolicy: null,
        onDisposition: (_) {},
        context: _context('req-2'),
        ownerToken: null,
      );

      expect(
        _code(
          ledger
              .preflight(
                command: 'device.write',
                arguments: const <String, Object?>{},
                requestId: 'req-2',
                registryOwned: false,
                ownerToken: null,
              )
              .rejection!,
        ),
        'duplicateRequestId',
      );
    });

    // 端到端不可达：coordinator 的 owner 容量与账本容量同为 256，先命中前者。
    // 账本单元可以把 256 条**未结算**记录直接摆出来。
    test('注入 256 条未结算记录：槽位判满，且已结算的记录会被回收让路', () async {
      final Completer<Map<String, Object?>> parked =
          Completer<Map<String, Object?>>();
      final PatchbayExternalInvocationLedger ledger =
          PatchbayExternalInvocationLedger(
            invoke: (String _, Map<String, Object?> _, String _, _) =>
                parked.future,
          );
      for (
        var index = 0;
        index < PatchbayExternalInvocationLedger.slotCapacity;
        index += 1
      ) {
        unawaited(
          ledger.dispatch(
            command: 'device.write',
            arguments: const <String, Object?>{},
            requestId: 'parked-$index',
            retryPolicy: null,
            onDisposition: (_) {},
            context: _context('parked-$index'),
            ownerToken: null,
          ),
        );
      }

      final List<String> dispositions = <String>[];
      expect(
        _code(
          await ledger.dispatch(
            command: 'device.write',
            arguments: const <String, Object?>{},
            requestId: 'overflow',
            retryPolicy: null,
            onDisposition: dispositions.add,
            context: _context('overflow'),
            ownerToken: null,
          ),
        ),
        'requestLedgerFull',
      );
      expect(dispositions, <String>['rejection']);

      parked.complete(
        PatchbayInvocation.accepted(requestId: 'parked-0').toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ledger.reserveSlot(), isTrue, reason: '已结算的记录可以被回收让路');
    });

    test('应答被冻结：provider 事后改写自己的 Map 改不动重放结果', () async {
      final Map<String, Object?> mutable = <String, Object?>{
        ...PatchbayInvocation.accepted(
          requestId: 'req-3',
          payload: const <String, Object?>{'attempt': 1},
        ).toJson(),
      };
      final PatchbayExternalInvocationLedger ledger =
          PatchbayExternalInvocationLedger(
            invoke: (String _, Map<String, Object?> _, String _, _) async =>
                mutable,
          );

      final Map<String, Object?> served = await ledger.dispatch(
        command: 'device.write',
        arguments: const <String, Object?>{},
        requestId: 'req-3',
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 0),
        onDisposition: (_) {},
        context: _context('req-3'),
        ownerToken: null,
      );
      mutable['payload'] = <String, Object?>{'attempt': 99};

      expect(served['payload'], const <String, Object?>{'attempt': 1});
    });

    test('provider 抛出：记录照样结算，槽位不会永远被占住', () async {
      final PatchbayExternalInvocationLedger ledger =
          PatchbayExternalInvocationLedger(
            invoke: (String _, Map<String, Object?> _, String _, _) async =>
                throw StateError('provider down'),
          );

      await expectLater(
        ledger.dispatch(
          command: 'device.write',
          arguments: const <String, Object?>{},
          requestId: 'req-4',
          retryPolicy: null,
          onDisposition: (_) {},
          context: _context('req-4'),
          ownerToken: null,
        ),
        throwsA(isA<StateError>()),
      );
      expect(ledger.contains('device.write', 'req-4'), isTrue);
    });
  });
}

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

PatchbayCommandPolicy _policy({
  bool writes = true,
  bool retainsStdinProvenance = false,
  Set<String> declared = const <String>{},
  Set<String> sensitive = const <String>{},
}) => PatchbayCommandPolicy(
  sensitiveParameters: sensitive,
  retainsStdinProvenance: retainsStdinProvenance,
  declaredGates: declared,
  writesSideEffect: writes,
);

PatchbayCatalogValidity _validity({
  String command = 'device.write',
  Set<String> declared = const <String>{},
}) => PatchbayCatalogValidity.valid(
  commandPolicies: <String, PatchbayCommandPolicy>{
    command: _policy(declared: declared),
  },
  responseSchemas: const <String, PatchbayResponseSchema>{},
  executionContracts: const <String, PatchbayExecutionContract>{},
  retryPolicies: const <String, PatchbayRetryPolicy>{},
);

PatchbayInvocationGateStage _gateStage({
  required PatchbayGateEvaluator? gates,
  bool priorRequestObserved = false,
}) => PatchbayInvocationGateStage(
  gates: gates,
  readCatalog: () async => _validity(),
  priorRequestObserved: (_, _) => priorRequestObserved,
);

Future<PatchbayHandlerDispatch> _dispatchHandler({
  required Future<Map<String, Object?>> Function() dispatchExternal,
  Map<String, Object?>? Function() frozen = _noFrozenResponse,
}) => patchbayDispatchInvocationHandler(
  registry: PatchbayCommandRegistry(
    const <PatchbayCommandRegistration<Object?>>[],
  ),
  command: 'device.write',
  forwarded: const <String, Object?>{},
  requestId: 'req-handler',
  context: _context('req-handler'),
  policy: _policy(),
  coreGateEvaluated: true,
  onGateResult: (_) {},
  frozenCancellationResponse: frozen,
  dispatchExternal: dispatchExternal,
);

Map<String, Object?>? _noFrozenResponse() => null;

PatchbayExternalInvocationLedger _ledger() => PatchbayExternalInvocationLedger(
  invoke:
      (
        String _,
        Map<String, Object?> _,
        String requestId,
        PatchbayInvocationContext _,
      ) async => PatchbayInvocation.accepted(requestId: requestId).toJson(),
);

PatchbayInvocationContext _context(String requestId) =>
    PatchbayInvocationCancellationController(
      requestId: requestId,
      clock: patchbayMonotonicNow,
    ).context;
