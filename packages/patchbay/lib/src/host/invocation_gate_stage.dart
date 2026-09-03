// PB-050-38 / DG-060-04：admission pipeline 的 **base gate / descriptor gate
// 阶段**，以及紧随其后的 **post-await recheck**。
//
// 三段放在同一个文件，因为它们回答同一个问题的三个部分：这次调用该不该被授权，
// 授权是谁给的，以及授权期间现场有没有变。门可以 await，而 await 恰恰是目录能够
// 漂移的那个窗口——所以「求值」和「复核」拆开会立刻退化成两套判据。
//
// 阶段同时负责 `gateDisposition` 记账：base gate 说不也记 `rejected`（从 consumer
// 视角授权答案就是不），早于任何门的失败记 `notReached`，而不是 `notDeclared`。
//
// 求值器、目录读取与「账本里是否已有这条 requestId」三个接缝都从外面注入，因此
// 本阶段可以脱离 `HostInvokerHandler` 单独构造：注入一个会抛的 evaluator、一个
// 读第二次就换声明的目录、或一个恒真的账本，都不需要一台 host。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import '../gate_admission_scope.dart';
import '../gates.dart';
import 'host_catalog.dart';
import 'host_models.dart';
import 'invocation_admission_state.dart';
import 'invocation_catalog_stage.dart';
import 'invocation_rejections.dart';

/// 门阶段的结论。
final class PatchbayGateAdmission {
  const PatchbayGateAdmission({
    required this.refusal,
    required this.coreGateEvaluated,
  });

  /// 要送出的拒绝；`null` 表示放行。
  final Map<String, Object?>? refusal;

  /// core 是否**真的**评估过门。它决定后续 handler 作用域要不要跳过 base gate
  /// 与已准入的声明门——注意「需要过门」与「过了门」是两件事：没有 evaluator 的
  /// host 需要过门却评估不了。
  final bool coreGateEvaluated;
}

/// The shared admission gate for registry-owned and external commands.
///
/// It sits after the sensitive-stdin check and before routing, and returns
/// the rejection envelope to serve, or null to continue dispatching.
///
/// The gate is an authorization judgement, so it runs before the external
/// requestId ledger is consulted: every admission crosses it, including a
/// retry of a request that was already served. It also runs before a ledger
/// slot is reserved, so a slow gate cannot starve unrelated commands into
/// `requestLedgerFull`.
final class PatchbayInvocationGateStage {
  const PatchbayInvocationGateStage({
    required PatchbayGateEvaluator? gates,
    required PatchbayInvocationCatalogReader readCatalog,
    required bool Function(String command, String requestId)
    priorRequestObserved,
  }) : _gates = gates,
       _readCatalog = readCatalog,
       _priorRequestObserved = priorRequestObserved;

  final PatchbayGateEvaluator? _gates;
  final PatchbayInvocationCatalogReader _readCatalog;
  final bool Function(String command, String requestId) _priorRequestObserved;

  /// 一条目录行是否必须过 core 的准入门。
  ///
  /// 写命令一律要过 base gate；纯只读但声明了门的行也要过——声明存在却从不执行
  /// 正是 0.5.0 修掉的那个缺口。
  static bool requiresCoreAdmission(PatchbayCommandPolicy policy) =>
      policy.writesSideEffect || policy.declaredGates.isNotEmpty;

  Future<PatchbayGateAdmission> admit({
    required String command,
    required String requestId,
    required PatchbayCommandPolicy policy,
    required void Function(String result) onGateResult,
    PatchbayInvocationAuditState? audit,
  }) async {
    final bool required = requiresCoreAdmission(policy);
    final bool coreGateEvaluated = required && _gates != null;
    if (!required) {
      return const PatchbayGateAdmission(
        refusal: null,
        coreGateEvaluated: false,
      );
    }
    return PatchbayGateAdmission(
      refusal: await _admit(
        command: command,
        requestId: requestId,
        policy: policy,
        onGateResult: onGateResult,
        audit: audit,
      ),
      coreGateEvaluated: coreGateEvaluated,
    );
  }

  Future<Map<String, Object?>?> _admit({
    required String command,
    required String requestId,
    required PatchbayCommandPolicy policy,
    required void Function(String result) onGateResult,
    PatchbayInvocationAuditState? audit,
  }) async {
    audit?.admissionStage = policy.writesSideEffect
        ? 'baseGate'
        : 'descriptorGate';
    final PatchbayGateEvaluator? gates = _gates;
    if (gates == null) {
      // No declaration, no evaluator, nothing to enforce: byte-for-byte what
      // the host did before this gate existed.
      if (policy.declaredGates.isEmpty) return null;
      // A declared gate on a host that has no evaluator is an unsatisfiable
      // contract — the gate can never pass. Saying so is the only answer that
      // keeps "declared but never enforced" from existing at all.
      onGateResult('rejected');
      audit
        ?..admissionStage = 'descriptorGate'
        ..gateDisposition = 'rejected';
      return patchbayDomainGateRejection(
        requestId: requestId,
        code: 'consumerGateRejected',
        gateId: (policy.declaredGates.toList()..sort()).first,
        reason: 'gateEvaluatorUnavailable',
        priorRequestObserved: _priorRequestObserved(command, requestId),
      );
    }
    final PatchbayGateRejection? rejection =
        await runInPatchbayGateAdmissionScope<PatchbayGateRejection?>(
          skipBase: !policy.writesSideEffect,
          admittedGateIds: const <String>{},
          body: () => gates.evaluate(policy.declaredGates),
        );
    if (rejection != null) {
      onGateResult('rejected');
      // `patchbay.base` is the evaluator's own marker for the non-optional host
      // gate; anything else is a consumer-declared gate id.
      audit
        ?..admissionStage = rejection.gateId == 'patchbay.base'
            ? 'baseGate'
            : 'descriptorGate'
        ..gateDisposition = 'rejected';
      return patchbayDomainGateRejection(
        requestId: requestId,
        code: rejection.code,
        gateId: rejection.gateId,
        notice: rejection.notice,
        priorRequestObserved: _priorRequestObserved(command, requestId),
      );
    }
    onGateResult('passed');
    audit
      ?..admissionStage = 'descriptorGate'
      ..gateDisposition = policy.declaredGates.isEmpty
          ? 'notDeclared'
          : 'passed';
    // A consumer gate may await, and a versioned provider can advance its
    // revision meanwhile. Re-read and compare the two facts the decision was
    // taken from; on a revision cache hit this costs one synchronous getter.
    audit?.admissionStage = 'postAwaitRecheck';
    final PatchbayCatalogValidity recheck = await _readCatalog();
    if (recheck.violation case final Map<String, Object?> reason) {
      return patchbayInvalidInvocationEnvelope(
        requestId,
        'catalogUnavailable',
        <String, Object?>{'catalog': reason},
      );
    }
    final PatchbayCommandPolicy current =
        recheck.commandPolicies[command] ??
        const PatchbayCommandPolicy.undeclared();
    if (policy.sameGatePolicy(current)) return null;
    // Drift is reported as-is and the caller re-sends. Re-evaluating against
    // the new declaration would make one call an unbounded gate loop and leave
    // the caller unable to say which declaration it finally passed.
    return patchbayInvalidInvocationEnvelope(
      requestId,
      'catalogGateDrift',
      <String, Object?>{'command': command},
    );
  }
}
