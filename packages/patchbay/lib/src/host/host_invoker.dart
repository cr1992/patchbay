// PB-050-38 / DG-060-04：core host 的调用入口与 admission pipeline **编排**。
//
// 本文件只剩三件事：公共门面（`dispatchInvoke*` / `cancelInvocation` / 两个
// drain）、按冻结顺序把各阶段串起来，以及「一次调用只落一条审计」这条记账规则。
// 每个阶段本身住在自己的文件里，可以脱离 host 单独构造与单独失败注入：
//
//   `invocation_catalog_stage.dart`   catalog validity 与 descriptor 查找
//   `invocation_input_stage.dart`     sensitive input 判定与转发形态
//   `invocation_gate_stage.dart`      base gate / descriptor gate 与门后复核
//   `invocation_handler_stage.dart`   handler 调用与其两侧的取消复核
//   `invocation_response_stage.dart`  信封结构与 schema / 执行证据校验
//   `invocation_audit_stage.dart`     审计投影、环形上限与投递
//   `external_invocation_ledger.dart` external 的 requestId 账本与槽位
//
// 顺序是 DG-060-04 冻结的，不是实现细节：catalog validity → sensitive input →
// base gate → descriptor gate →（handler 侧 UI decision 回传）→ response
// validation → audit projection。
import 'dart:async';

import '../audit.dart';
import '../command_registry.dart';
import '../gates.dart';
import '../invocation_cancellation.dart';
import 'external_invocation_ledger.dart';
import 'host_catalog.dart';
import 'host_models.dart';
import 'invocation_admission_state.dart';
import 'invocation_audit_stage.dart';
import 'invocation_catalog_stage.dart';
import 'invocation_coordinator.dart';
import 'invocation_gate_stage.dart';
import 'invocation_handler_stage.dart';
import 'invocation_input_stage.dart';
import 'invocation_rejections.dart';
import 'invocation_response_stage.dart';

final class HostInvokerHandler {
  HostInvokerHandler({
    PatchbayInvocationSource? invokeSource,
    PatchbayContextInvocationSource? invokeWithContext,
    required PatchbayCommandRegistry registry,
    required HostCatalogHandler catalogHandler,
    PatchbayGateEvaluator? domainGates,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
    int auditQueueCapacity = 256,
    int maxConcurrentInvocations = 8,
    Duration cancellationConfirmationTimeout = const Duration(seconds: 2),
    PatchbayMonotonicClock? monotonicClock,
  }) : _invoke = invokeSource,
       _invokeWithContext = invokeWithContext,
       _registry = registry,
       _catalogHandler = catalogHandler,
       _domainGates = domainGates,
       _invocations = InvocationCoordinator(
         maxConcurrentInvocations: maxConcurrentInvocations,
         confirmationTimeout: cancellationConfirmationTimeout,
         clock: monotonicClock,
       ) {
    if ((invokeSource == null) == (invokeWithContext == null)) {
      throw ArgumentError(
        'provide exactly one of invokeSource or invokeWithContext',
      );
    }
    _audit = PatchbayInvocationAuditLedger(
      sink: auditSink,
      onSinkError: onAuditSinkError,
      capacity: auditQueueCapacity,
    );
  }

  final PatchbayInvocationSource? _invoke;
  final PatchbayContextInvocationSource? _invokeWithContext;
  final PatchbayCommandRegistry _registry;
  final HostCatalogHandler _catalogHandler;

  /// The evaluator every catalog-declared admission crosses before dispatch.
  ///
  /// The base gate applies to writes. Descriptor gates apply whenever declared,
  /// independent of side effect or registry ownership. Registry handlers run in
  /// an internal scope that removes already-admitted stages from bridge-local
  /// evaluation.
  final PatchbayGateEvaluator? _domainGates;
  late final PatchbayInvocationAuditLedger _audit;
  final InvocationCoordinator _invocations;

  late final PatchbayExternalInvocationLedger _external =
      PatchbayExternalInvocationLedger(invoke: _invokeExternal);

  late final PatchbayInvocationGateStage _gateStage =
      PatchbayInvocationGateStage(
        gates: _domainGates,
        readCatalog: _catalogHandler.readInvocationCatalog,
        priorRequestObserved: _external.contains,
      );

  List<PatchbayAuditEvent> get auditEvents => _audit.events;

  Future<PatchbayAuditDrainResult> drainAudit({
    Duration timeout = const Duration(seconds: 2),
  }) => _audit.drain(timeout);

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    String? ownerToken,
    Duration? deadline,
  }) => dispatchInvokeHandle(
    command,
    arguments,
    requestId,
    ownerToken: ownerToken,
    deadline: deadline,
  ).response;

  PatchbayHostInvocationHandle dispatchInvokeHandle(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    String? ownerToken,
    Duration? deadline,
  }) {
    final PatchbayHostInvocationHandle? externalReplay =
        _preflightExternalInvocation(
          command,
          arguments,
          requestId,
          ownerToken: ownerToken,
        );
    if (externalReplay != null) return externalReplay;
    final PatchbayInvocationAuditState auditState =
        PatchbayInvocationAuditState();
    return _invocations.start(
      command: command,
      requestId: requestId,
      ownerToken: ownerToken,
      deadline: deadline,
      contextAware:
          _registry.isContextAware(command) || _invokeWithContext != null,
      pipeline: (PatchbayInvocationContext context) => _dispatchAndAudit(
        command,
        arguments,
        requestId,
        context,
        auditState: auditState,
        ownerToken: ownerToken,
      ),
      onCancellationResponse: (Map<String, Object?> response) {
        if (auditState.recorded) return;
        auditState.recorded = true;
        _audit.record(
          command: command,
          requestId: requestId,
          arguments: patchbayWithoutStdinProvenance(arguments),
          gateResult: auditState.gateResult,
          response: response,
          admissionStage: auditState.admissionStage,
          gateDisposition: auditState.gateDisposition,
        );
      },
    );
  }

  /// 账本先于编排：命中已有记录时不再新开一次调用。
  PatchbayHostInvocationHandle? _preflightExternalInvocation(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required String? ownerToken,
  }) {
    final PatchbayExternalPreflight preflight = _external.preflight(
      command: command,
      arguments: arguments,
      requestId: requestId,
      registryOwned: _registry.handles(command),
      ownerToken: ownerToken,
    );
    if (preflight.replay case final Future<Map<String, Object?>> response) {
      return PatchbayHostInvocationHandle(
        response: response,
        lifecycle: response.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
    if (preflight.rejection case final Map<String, Object?> rejection) {
      _audit.record(
        command: command,
        requestId: requestId,
        arguments: patchbayWithoutStdinProvenance(arguments),
        gateResult: 'notEvaluated',
        response: rejection,
        // The ledger is consulted before any gate, so no gate was reached.
        admissionStage: 'dispatch',
        gateDisposition: 'notReached',
      );
      return PatchbayHostInvocationHandle(
        response: Future<Map<String, Object?>>.value(rejection),
        lifecycle: Future<void>.value(),
      );
    }
    return null;
  }

  /// 一次调用只落一条审计，且落的是**实际送出**的那份应答。
  ///
  /// 取消冻结应答会顶掉 handler 的结果，重放则根本不再记账；账本持有者还要把送出
  /// 的应答回填进记录，好让后续幂等重放取回同一份事实。
  Future<Map<String, Object?>> _dispatchAndAudit(
    String command,
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context, {
    required PatchbayInvocationAuditState auditState,
    required String? ownerToken,
  }) async {
    var recordAudit = true;
    var externalDisposition = 'none';
    try {
      final Map<String, Object?> result = await _dispatchInvoke(
        command,
        arguments,
        requestId,
        context: context,
        ownerToken: ownerToken,
        onGateResult: (String value) => auditState.gateResult = value,
        onExternalDisposition: (String value) {
          externalDisposition = value;
          if (value == 'replay') recordAudit = false;
        },
        audit: auditState,
      );
      final Map<String, Object?> served =
          _invocations.frozenCancellationResponse(command, requestId) ?? result;
      if (recordAudit && !auditState.recorded) {
        auditState.recorded = true;
        _audit.record(
          command: command,
          requestId: requestId,
          arguments: patchbayWithoutStdinProvenance(arguments),
          gateResult: auditState.gateResult,
          response: served,
          admissionStage: auditState.admissionStage,
          gateDisposition: auditState.gateDisposition,
        );
      }
      if (externalDisposition == 'owner') {
        _external.settleOwner(command, requestId, served);
      }
      return served;
    } catch (error, stackTrace) {
      final Map<String, Object?>? frozen = _invocations
          .frozenCancellationResponse(command, requestId);
      if (frozen != null) {
        if (externalDisposition == 'owner') {
          _external.settleOwner(command, requestId, frozen);
        }
        return frozen;
      }
      if (externalDisposition == 'owner') {
        _external.failOwner(command, requestId, error, stackTrace);
      }
      rethrow;
    }
  }

  Future<PatchbayInvocationCancellationResult> cancelInvocation({
    required String command,
    required String requestId,
    required String ownerToken,
    PatchbayInvocationCancellationReason reason =
        PatchbayInvocationCancellationReason.explicitRequest,
  }) => _invocations.cancel(
    command: command,
    requestId: requestId,
    ownerToken: ownerToken,
    reason: reason,
  );

  Future<PatchbayInvocationDrainResult> drainInvocations({
    Duration timeout = const Duration(seconds: 2),
  }) => _invocations.drain(timeout);

  /// DG-060-04 冻结的阶段顺序，逐段串起来——本方法**只**负责顺序与阶段之间的
  /// 传递，任何一段的判据都不在这里。
  Future<Map<String, Object?>> _dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required void Function(String result) onGateResult,
    required void Function(String disposition) onExternalDisposition,
    required PatchbayInvocationContext context,
    required String? ownerToken,
    PatchbayInvocationAuditState? audit,
  }) async {
    if (requestId.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    final PatchbayCatalogAdmission catalog =
        await patchbayAdmitInvocationCatalog(
          readCatalog: _catalogHandler.readInvocationCatalog,
          command: command,
          requestId: requestId,
          frozenCancellationResponse: () =>
              _invocations.frozenCancellationResponse(command, requestId),
        );
    if (catalog.response case final Map<String, Object?> response) {
      return response;
    }
    final PatchbayCatalogValidity validity = catalog.validity!;
    final PatchbayCommandPolicy policy = catalog.policy;

    final PatchbayInputAdmission input = patchbayAdmitInvocationInput(
      requestId: requestId,
      policy: policy,
      arguments: arguments,
      audit: audit,
    );
    if (input.rejection case final Map<String, Object?> rejection) {
      return rejection;
    }

    // 不需要过门的命令在这里**同步**短路：`await` 只在真的要过门时求值。多让出一个
    // 微任务就多一个取消信号能插进来的窗口，会改变只读命令的取消观察时机。
    final PatchbayGateAdmission gate =
        PatchbayInvocationGateStage.requiresCoreAdmission(policy)
        ? await _gateStage.admit(
            command: command,
            requestId: requestId,
            policy: policy,
            onGateResult: onGateResult,
            audit: audit,
          )
        : PatchbayInvocationGateStage.admissionNotRequired;
    if (gate.refusal case final Map<String, Object?> refusal) return refusal;

    final PatchbayHandlerDispatch dispatch =
        await patchbayDispatchInvocationHandler(
          registry: _registry,
          command: command,
          forwarded: input.forwarded,
          requestId: requestId,
          context: context,
          policy: policy,
          coreGateEvaluated: gate.coreGateEvaluated,
          onGateResult: onGateResult,
          frozenCancellationResponse: () =>
              _invocations.frozenCancellationResponse(command, requestId),
          dispatchExternal: () => _external.dispatch(
            command: command,
            arguments: input.forwarded,
            requestId: requestId,
            retryPolicy: validity.retryPolicies[command],
            onDisposition: onExternalDisposition,
            context: context,
            ownerToken: ownerToken,
          ),
          audit: audit,
        );
    if (dispatch.frozenResponse case final Map<String, Object?> frozen) {
      return frozen;
    }

    return patchbayValidateInvocationResponse(
      result: dispatch.result,
      requestId: requestId,
      registered: dispatch.registered,
      responseSchema: validity.responseSchemas[command],
      executionContract: validity.executionContracts[command],
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      audit: audit,
    );
  }

  Future<Map<String, Object?>> _invokeExternal(
    String command,
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context,
  ) {
    final PatchbayContextInvocationSource? contextSource = _invokeWithContext;
    return contextSource == null
        ? _invoke!(command, arguments, requestId)
        : contextSource(command, arguments, requestId, context);
  }

  static Map<String, Object?> withoutStdinProvenance(
    Map<String, Object?> arguments,
  ) => patchbayWithoutStdinProvenance(arguments);
}
