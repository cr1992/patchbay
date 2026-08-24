import 'dart:async';
import 'dart:convert';

import '../audit.dart';
import '../catalog_digest.dart';
import '../command_descriptor.dart';
import '../command_registry.dart';
import '../execution_evidence.dart';
import '../generated/core_wire.g.dart';
import '../invocation.dart';
import '../response_schema.dart';
import 'host_catalog.dart';
import 'host_models.dart';

final class HostInvokerHandler {
  HostInvokerHandler({
    required PatchbayInvocationSource invokeSource,
    required PatchbayCommandRegistry registry,
    required HostCatalogHandler catalogHandler,
    this.auditSink,
    this.onAuditSinkError,
  }) : _invoke = invokeSource,
       _registry = registry,
       _catalogHandler = catalogHandler;

  final PatchbayInvocationSource _invoke;
  final PatchbayCommandRegistry _registry;
  final HostCatalogHandler _catalogHandler;
  final PatchbayAuditSink? auditSink;
  final PatchbayAuditSinkErrorHandler? onAuditSinkError;

  final List<PatchbayAuditEvent> _auditLedger = <PatchbayAuditEvent>[];
  final Map<(String, String), PatchbayExternalInvocationRecord>
  _externalInvocations = <(String, String), PatchbayExternalInvocationRecord>{};

  List<PatchbayAuditEvent> get auditEvents =>
      List<PatchbayAuditEvent>.unmodifiable(_auditLedger);

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    var gateResult = 'notEvaluated';
    var recordAudit = true;
    final Map<String, Object?> result = await _dispatchInvoke(
      command,
      arguments,
      requestId,
      onGateResult: (String value) => gateResult = value,
      onExternalDisposition: (String value) {
        if (value == 'replay') recordAudit = false;
      },
    );
    if (recordAudit) {
      _recordAudit(
        command: command,
        requestId: requestId,
        arguments: withoutStdinProvenance(arguments),
        gateResult: gateResult,
        response: result,
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required void Function(String result) onGateResult,
    required void Function(String disposition) onExternalDisposition,
  }) async {
    if (requestId.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    PatchbayCatalogRead? invocationCatalog;
    final Map<String, Object?> forwarded;
    if (arguments.isEmpty) {
      forwarded = arguments;
    } else {
      final PatchbayCatalogRead catalog = invocationCatalog =
          await _catalogHandler.readCatalog();
      if (catalog.violation case final Map<String, Object?> reason) {
        return _invalidInvocationEnvelope(
          requestId,
          'catalogUnavailable',
          <String, Object?>{'catalog': reason},
        );
      }
      final PatchbayCommandPolicy policy = PatchbayCommandPolicy.forCommand(
        catalog.response,
        command,
      );
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
    final Map<String, Object?>? registered = await _registry.tryDispatch(
      command,
      forwarded,
      requestId,
      onGateResult: onGateResult,
    );
    final Map<String, Object?> result;
    if (registered != null) {
      result = registered;
    } else {
      PatchbayCatalogRead? externalCatalog = invocationCatalog;
      externalCatalog ??= await _catalogHandler.readCatalog();
      if (externalCatalog.violation case final Map<String, Object?> violation
          when _invalidRetryPolicyTargets(violation, command)) {
        return _invalidInvocationEnvelope(
          requestId,
          'catalogUnavailable',
          <String, Object?>{'catalog': violation},
        );
      }
      result = await _dispatchExternal(
        command,
        forwarded,
        requestId,
        onDisposition: onExternalDisposition,
        retryPolicy: externalCatalog.violation == null
            ? _retryPolicyFromCatalog(externalCatalog.response, command)
            : null,
      );
      invocationCatalog ??= externalCatalog.violation == null
          ? externalCatalog
          : null;
    }
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
    PatchbayResponseSchema? responseSchema = _registry.responseSchemaFor(
      command,
    );
    PatchbayExecutionContract? executionContract = _registry
        .executionContractFor(command);
    responseSchema ??= invocationCatalog == null
        ? _catalogHandler.responseSchemas[command]
        : HostCatalogHandler.responseSchemasFromCatalog(
            invocationCatalog.response,
          )[command];
    executionContract ??= invocationCatalog == null
        ? _catalogHandler.executionContracts[command]
        : HostCatalogHandler.executionContractsFromCatalog(
            invocationCatalog.response,
          )[command];
    if (responseSchema == null &&
        invocationCatalog == null &&
        !_registry.handles(command)) {
      final PatchbayCatalogRead discovered = await _catalogHandler
          .readCatalog();
      if (discovered.violation == null) {
        responseSchema = HostCatalogHandler.responseSchemasFromCatalog(
          discovered.response,
        )[command];
        executionContract = HostCatalogHandler.executionContractsFromCatalog(
          discovered.response,
        )[command];
      } else if (_invalidCommandContractTargets(
        discovered.violation!,
        command,
      )) {
        return _invalidInvocationEnvelope(
          requestId,
          'catalogUnavailable',
          <String, Object?>{'catalog': discovered.violation!},
        );
      }
    }
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

  Future<Map<String, Object?>> _dispatchExternal(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    required PatchbayRetryPolicy? retryPolicy,
    required void Function(String disposition) onDisposition,
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
        );
    _externalInvocations[key] = record;
    record.response = () async {
      try {
        return _freezeJsonMap(await _invoke(command, arguments, requestId));
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
    final PatchbayAuditSink? sink = auditSink;
    if (sink == null) return;
    unawaited(
      Future<void>.sync(() => sink(event)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        try {
          onAuditSinkError?.call(error, stackTrace, event);
        } on Object {
          // Sink error swallowed safely.
        }
      }),
    );
  }

  static PatchbayRetryPolicy? _retryPolicyFromCatalog(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return null;
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> || row['name'] != command) continue;
      if (!row.containsKey('retryPolicy')) return null;
      return PatchbayRetryPolicy.fromJson(row['retryPolicy']);
    }
    return null;
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

  static bool _invalidCommandContractTargets(
    Map<String, Object?> violation,
    String command,
  ) {
    final Object? rows = violation['violations'];
    if (rows is! List<Object?>) return false;
    return rows.any(
      (Object? row) =>
          row is Map<Object?, Object?> &&
          row['name'] == command &&
          (row['reason'] == 'invalidResponseSchema' ||
              row['reason'] == 'invalidExecutionContract'),
    );
  }

  static bool _invalidRetryPolicyTargets(
    Map<String, Object?> violation,
    String command,
  ) {
    final Object? rows = violation['violations'];
    if (rows is! List<Object?>) return false;
    return rows.any(
      (Object? row) =>
          row is Map<Object?, Object?> &&
          row['name'] == command &&
          row['reason'] == 'invalidRetryPolicy',
    );
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
