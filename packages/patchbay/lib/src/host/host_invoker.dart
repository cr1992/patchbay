import 'dart:async';
import 'dart:convert';

import '../audit.dart';
import '../catalog_digest.dart';
import '../command_descriptor.dart';
import '../command_registry.dart';
import '../execution_evidence.dart';
import '../gates.dart';
import '../generated/core_wire.g.dart';
import '../invocation.dart';
import '../invocation_cancellation.dart';
import '../response_schema.dart';
import 'audit_dispatcher.dart';
import 'host_catalog.dart';
import 'host_models.dart';
import 'invocation_coordinator.dart';

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
    validateAuditQueueCapacity(auditQueueCapacity);
    _auditDispatcher = auditSink == null
        ? null
        : AuditDispatcher(
            sink: auditSink,
            capacity: auditQueueCapacity,
            onError: onAuditSinkError,
          );
  }

  final PatchbayInvocationSource? _invoke;
  final PatchbayContextInvocationSource? _invokeWithContext;
  final PatchbayCommandRegistry _registry;
  final HostCatalogHandler _catalogHandler;

  /// The evaluator consumer-owned write commands cross before dispatch.
  ///
  /// Registry-owned commands are not routed through it: they already evaluate
  /// their own declared gates inside their registration or bridge handler, and
  /// running the same IDs twice would turn one authorization into two.
  final PatchbayGateEvaluator? _domainGates;
  late final AuditDispatcher? _auditDispatcher;
  Future<PatchbayAuditDrainResult>? _emptyAuditDrain;
  final InvocationCoordinator _invocations;

  final List<PatchbayAuditEvent> _auditLedger = <PatchbayAuditEvent>[];
  var _nextAuditSequence = 1;
  final Map<(String, String), PatchbayExternalInvocationRecord>
  _externalInvocations = <(String, String), PatchbayExternalInvocationRecord>{};

  List<PatchbayAuditEvent> get auditEvents =>
      List<PatchbayAuditEvent>.unmodifiable(_auditLedger);

  Future<PatchbayAuditDrainResult> drainAudit({
    Duration timeout = const Duration(seconds: 2),
  }) {
    final AuditDispatcher? dispatcher = _auditDispatcher;
    if (dispatcher != null) return dispatcher.drain(timeout);
    final Future<PatchbayAuditDrainResult>? existing = _emptyAuditDrain;
    if (existing != null) return existing;
    validateAuditDrainTimeout(timeout);
    return _emptyAuditDrain = Future<PatchbayAuditDrainResult>.value(
      const PatchbayAuditDrainResult(
        outcome: PatchbayAuditDrainOutcome.drained,
        settledCount: 0,
        overflowDroppedCount: 0,
        abandonedCount: 0,
      ),
    );
  }

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
    final _InvocationAuditState auditState = _InvocationAuditState();
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
        _recordAudit(
          command: command,
          requestId: requestId,
          arguments: withoutStdinProvenance(arguments),
          gateResult: auditState.gateResult,
          response: response,
        );
      },
    );
  }

  PatchbayHostInvocationHandle? _preflightExternalInvocation(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required String? ownerToken,
  }) {
    if (_registry.handles(command)) return null;
    final PatchbayExternalInvocationRecord? existing =
        _externalInvocations[(command, requestId)];
    if (existing == null) return null;
    final String rawDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      arguments,
    ]).value;
    final String forwardedDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      withoutStdinProvenance(arguments),
    ]).value;
    final bool sameArguments =
        existing.argumentDigest == rawDigest ||
        existing.argumentDigest == forwardedDigest;
    final bool sameOwner =
        ownerToken == null || existing.ownerToken == ownerToken;
    if (sameArguments && existing.idempotent && sameOwner) {
      final Future<Map<String, Object?>> response =
          existing.servedResponse.future;
      return PatchbayHostInvocationHandle(
        response: response,
        lifecycle: response.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
    final Map<String, Object?> rejection = _externalDuplicateRejection(
      requestId,
      !sameArguments || !sameOwner ? 'requestIdConflict' : 'duplicateRequestId',
    );
    _recordAudit(
      command: command,
      requestId: requestId,
      arguments: withoutStdinProvenance(arguments),
      gateResult: 'notEvaluated',
      response: rejection,
    );
    return PatchbayHostInvocationHandle(
      response: Future<Map<String, Object?>>.value(rejection),
      lifecycle: Future<void>.value(),
    );
  }

  Future<Map<String, Object?>> _dispatchAndAudit(
    String command,
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context, {
    required _InvocationAuditState auditState,
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
      );
      final Map<String, Object?> served =
          _invocations.frozenCancellationResponse(command, requestId) ?? result;
      if (recordAudit && !auditState.recorded) {
        auditState.recorded = true;
        _recordAudit(
          command: command,
          requestId: requestId,
          arguments: withoutStdinProvenance(arguments),
          gateResult: auditState.gateResult,
          response: served,
        );
      }
      if (externalDisposition == 'owner') {
        _externalInvocations[(command, requestId)]?.servedResponse.complete(
          served,
        );
      }
      return served;
    } catch (error, stackTrace) {
      final Map<String, Object?>? frozen = _invocations
          .frozenCancellationResponse(command, requestId);
      if (frozen != null) {
        if (externalDisposition == 'owner') {
          _externalInvocations[(command, requestId)]?.servedResponse.complete(
            frozen,
          );
        }
        return frozen;
      }
      if (externalDisposition == 'owner') {
        _externalInvocations[(command, requestId)]?.servedResponse
            .completeError(error, stackTrace);
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

  Future<Map<String, Object?>> _dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required void Function(String result) onGateResult,
    required void Function(String disposition) onExternalDisposition,
    required PatchbayInvocationContext context,
    required String? ownerToken,
  }) async {
    if (requestId.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    final PatchbayCatalogValidity catalog = await _catalogHandler
        .readInvocationCatalog();
    final Map<String, Object?>? cancelledAfterCatalog = _invocations
        .frozenCancellationResponse(command, requestId);
    if (cancelledAfterCatalog != null) return cancelledAfterCatalog;
    if (catalog.violation case final Map<String, Object?> reason) {
      return _invalidInvocationEnvelope(
        requestId,
        'catalogUnavailable',
        <String, Object?>{'catalog': reason},
      );
    }
    final PatchbayCommandPolicy policy =
        catalog.commandPolicies[command] ??
        const PatchbayCommandPolicy.undeclared();
    final Map<String, Object?> forwarded;
    if (arguments.isEmpty) {
      forwarded = arguments;
    } else {
      final List<String> violations = policy.sensitiveViolations(arguments);
      if (violations.isNotEmpty) {
        return PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: PatchbayRejection(
            code: 'sensitiveInputRequiresStdin',
            notice: 'Sensitive arguments are accepted only from stdin.',
            details: <String, Object?>{'parameters': violations},
          ),
        ).toJson();
      }
      forwarded = policy.retainsStdinProvenance
          ? arguments
          : withoutStdinProvenance(arguments);
    }
    if (!_registry.handles(command) && policy.writesSideEffect) {
      final Map<String, Object?>? refusal = await _admitDomainWrite(
        command,
        requestId,
        policy,
        onGateResult: onGateResult,
      );
      if (refusal != null) return refusal;
    }
    final Map<String, Object?>? cancelledBeforeHandler = _invocations
        .frozenCancellationResponse(command, requestId);
    if (cancelledBeforeHandler != null) return cancelledBeforeHandler;
    final Map<String, Object?>? registered = await _registry.tryDispatch(
      command,
      forwarded,
      requestId,
      onGateResult: onGateResult,
      context: context,
    );
    final Map<String, Object?> result;
    if (registered != null) {
      result = registered;
    } else {
      result = await _dispatchExternal(
        command,
        forwarded,
        requestId,
        context: context,
        ownerToken: ownerToken,
        onDisposition: onExternalDisposition,
        retryPolicy: catalog.retryPolicies[command],
      );
    }
    final Map<String, Object?>? cancelledAfterHandler = _invocations
        .frozenCancellationResponse(command, requestId);
    if (cancelledAfterHandler != null) return cancelledAfterHandler;
    final PatchbayInvocationWire wire;
    try {
      wire = PatchbayInvocationWire.fromJson(result);
    } on FormatException {
      return _invalidInvocationEnvelope(requestId, 'malformedEnvelope');
    }
    if (wire.schemaVersion != 1) {
      return _invalidInvocationEnvelope(requestId, 'schemaVersionMismatch');
    }
    if (wire.requestId != requestId) {
      return _invalidInvocationEnvelope(requestId, 'requestIdMismatch');
    }
    final String? semanticViolation = _invocationSemanticViolation(wire);
    if (semanticViolation != null) {
      return _invalidInvocationEnvelope(requestId, semanticViolation);
    }
    final PatchbayResponseSchema? responseSchema =
        catalog.responseSchemas[command];
    final PatchbayExecutionContract? executionContract =
        catalog.executionContracts[command];
    PatchbayExecutionValidationResult executionValidation =
        const PatchbayExecutionValidationResult();
    if (wire.admission == PatchbayAdmissionWire.accepted) {
      if (responseSchema != null) {
        final List<PatchbayResponseValidationIssue> issues =
            validatePatchbayResponsePayload(
              responseSchema.accepted,
              wire.payload,
            );
        if (issues.isNotEmpty) {
          return <String, Object?>{
            ..._responseSchemaViolation(requestId, issues),
            'schemaMode': 'validated',
          };
        }
      }
      if (executionContract != null) {
        executionValidation = validatePatchbayExecutionEvidence(
          executionContract,
          wire.payload,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
        if (executionValidation.issues.isNotEmpty) {
          return <String, Object?>{
            ..._responseSchemaViolation(requestId, executionValidation.issues),
            'schemaMode': responseSchema == null
                ? 'legacyUnvalidated'
                : 'validated',
          };
        }
      }
    }
    return _withExecutionDetails(<String, Object?>{
      ...result,
      'schemaMode': responseSchema == null ? 'legacyUnvalidated' : 'validated',
    }, executionValidation);
  }

  /// The admission gate for consumer-owned write commands.
  ///
  /// It sits after the sensitive-stdin check and before routing, and returns
  /// the rejection envelope to serve, or null to continue dispatching.
  ///
  /// The gate is an authorization judgement, so it runs before the external
  /// requestId ledger is consulted: every admission crosses it, including a
  /// retry of a request that was already served. It also runs before a ledger
  /// slot is reserved, so a slow gate cannot starve unrelated commands into
  /// `requestLedgerFull`.
  Future<Map<String, Object?>?> _admitDomainWrite(
    String command,
    String requestId,
    PatchbayCommandPolicy policy, {
    required void Function(String result) onGateResult,
  }) async {
    final PatchbayGateEvaluator? gates = _domainGates;
    if (gates == null) {
      // No declaration, no evaluator, nothing to enforce: byte-for-byte what
      // the host did before this gate existed.
      if (policy.declaredGates.isEmpty) return null;
      // A declared gate on a host that has no evaluator is an unsatisfiable
      // contract — the gate can never pass. Saying so is the only answer that
      // keeps "declared but never enforced" from existing at all.
      onGateResult('rejected');
      return _domainGateRejection(
        command: command,
        requestId: requestId,
        code: 'consumerGateRejected',
        gateId: (policy.declaredGates.toList()..sort()).first,
        reason: 'gateEvaluatorUnavailable',
      );
    }
    final PatchbayGateRejection? rejection = await gates.evaluate(
      policy.declaredGates,
    );
    if (rejection != null) {
      onGateResult('rejected');
      return _domainGateRejection(
        command: command,
        requestId: requestId,
        code: rejection.code,
        gateId: rejection.gateId,
        notice: rejection.notice,
      );
    }
    onGateResult('passed');
    // A consumer gate may await, and a versioned provider can advance its
    // revision meanwhile. Re-read and compare the two facts the decision was
    // taken from; on a revision cache hit this costs one synchronous getter.
    final PatchbayCatalogValidity recheck = await _catalogHandler
        .readInvocationCatalog();
    if (recheck.violation case final Map<String, Object?> reason) {
      return _invalidInvocationEnvelope(
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
    return _invalidInvocationEnvelope(
      requestId,
      'catalogGateDrift',
      <String, Object?>{'command': command},
    );
  }

  /// A gate rejection in the shape the UI plane already uses.
  ///
  /// `priorRequestObserved` is the one extra fact: because the gate runs
  /// before ledger replay, a caller retrying an already-served requestId can
  /// receive a rejection for work that *did* happen. Without this flag it
  /// could read the rejection as "nothing happened", pick a fresh requestId
  /// and cause a second effect. The flag says only that this requestId was
  /// admitted before — never what it did, or with which arguments.
  Map<String, Object?> _domainGateRejection({
    required String command,
    required String requestId,
    required String code,
    required String gateId,
    String? notice,
    String? reason,
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: code,
      notice: notice,
      details: <String, Object?>{
        'gateId': gateId,
        if (reason != null) 'reason': reason,
        if (_externalInvocations.containsKey((command, requestId)))
          'priorRequestObserved': true,
      },
    ),
  ).toJson();

  Future<Map<String, Object?>> _dispatchExternal(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required PatchbayRetryPolicy? retryPolicy,
    required void Function(String disposition) onDisposition,
    required PatchbayInvocationContext context,
    required String? ownerToken,
  }) async {
    final (String, String) key = (command, requestId);
    final String argumentDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      arguments,
    ]).value;
    final PatchbayExternalInvocationRecord? existing =
        _externalInvocations[key];
    if (existing != null) {
      if (existing.argumentDigest != argumentDigest) {
        onDisposition('rejection');
        return _externalDuplicateRejection(requestId, 'requestIdConflict');
      }
      if (!existing.idempotent) {
        onDisposition('rejection');
        return _externalDuplicateRejection(requestId, 'duplicateRequestId');
      }
      onDisposition('replay');
      return existing.response;
    }
    if (!_reserveExternalInvocationSlot()) {
      onDisposition('rejection');
      return _externalDuplicateRejection(requestId, 'requestLedgerFull');
    }
    onDisposition('owner');
    final PatchbayExternalInvocationRecord record =
        PatchbayExternalInvocationRecord(
          argumentDigest: argumentDigest,
          idempotent: retryPolicy != null,
          ownerToken: ownerToken,
        );
    _externalInvocations[key] = record;
    record.response = () async {
      try {
        final PatchbayContextInvocationSource? contextSource =
            _invokeWithContext;
        return _freezeJsonMap(
          await (contextSource == null
              ? _invoke!(command, arguments, requestId)
              : contextSource(command, arguments, requestId, context)),
        );
      } finally {
        record.settled = true;
      }
    }();
    return record.response;
  }

  bool _reserveExternalInvocationSlot() {
    if (_externalInvocations.length < 256) return true;
    for (final MapEntry<(String, String), PatchbayExternalInvocationRecord>
        entry
        in _externalInvocations.entries) {
      if (!entry.value.settled) continue;
      _externalInvocations.remove(entry.key);
      return true;
    }
    return false;
  }

  static Map<String, Object?> _externalDuplicateRejection(
    String requestId,
    String code,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code),
  ).toJson();

  static Map<String, Object?> _freezeJsonMap(Map<String, Object?> value) =>
      Map<String, Object?>.from(
        jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
      );

  void _recordAudit({
    required String command,
    required String requestId,
    required Map<String, Object?> arguments,
    required String gateResult,
    required Map<String, Object?> response,
  }) {
    final PatchbayAuditEvent event = patchbayProjectAuditEvent(
      command: command,
      requestId: requestId,
      arguments: arguments,
      gateResult: gateResult,
      response: response,
    );
    if (_auditLedger.length == 256) _auditLedger.removeAt(0);
    _auditLedger.add(event);
    _auditDispatcher?.enqueue(event, _nextAuditSequence);
    _nextAuditSequence += 1;
  }

  static Map<String, Object?> _invalidInvocationEnvelope(
    String requestId,
    String reason, [
    Map<String, Object?> details = const <String, Object?>{},
  ]) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: 'providerProtocolViolation',
      details: <String, Object?>{'reason': reason, ...details},
    ),
  ).toJson();

  static Map<String, Object?> _responseSchemaViolation(
    String requestId,
    List<PatchbayResponseValidationIssue> issues,
  ) {
    final PatchbayResponseValidationIssue first = issues.first;
    return _invalidInvocationEnvelope(
      requestId,
      first.reason,
      <String, Object?>{
        'field': first.field,
        if (first.expected != null) 'expected': first.expected!,
        'violations': issues
            .map((PatchbayResponseValidationIssue issue) => issue.toJson())
            .toList(growable: false),
      },
    );
  }

  static Map<String, Object?> _withExecutionDetails(
    Map<String, Object?> response,
    PatchbayExecutionValidationResult validation,
  ) {
    if (!validation.legacyDispatchedConflict) return response;
    final Object? existing = response['details'];
    return <String, Object?>{
      ...response,
      'details': <String, Object?>{
        if (existing is Map<Object?, Object?>)
          for (final MapEntry<Object?, Object?> entry in existing.entries)
            if (entry.key is String) entry.key! as String: entry.value,
        'legacyDispatchedConflict': true,
      },
    };
  }

  static String? _invocationSemanticViolation(PatchbayInvocationWire wire) {
    if (wire.requestId.isEmpty) return 'emptyRequestId';
    if (wire.jobId != null && wire.jobId!.isEmpty) return 'emptyJobId';
    switch (wire.admission) {
      case PatchbayAdmissionWire.accepted:
        if (wire.rejection != null) return 'acceptedWithRejection';
      case PatchbayAdmissionWire.rejected:
        final PatchbayRejectionWire? rejection = wire.rejection;
        if (rejection == null) return 'rejectedWithoutRejection';
        if (rejection.code.isEmpty) return 'emptyRejectionCode';
        if (wire.jobId != null) return 'rejectedWithJobId';
        if (wire.payload.isNotEmpty) return 'rejectedWithPayload';
        if (wire.notice != rejection.notice) return 'rejectionNoticeMismatch';
    }
    return null;
  }

  static Map<String, Object?> withoutStdinProvenance(
    Map<String, Object?> arguments,
  ) => arguments.containsKey('inputWasStdin')
      ? (Map<String, Object?>.of(arguments)..remove('inputWasStdin'))
      : arguments;
}

final class _InvocationAuditState {
  String gateResult = 'notEvaluated';
  bool recorded = false;
}
