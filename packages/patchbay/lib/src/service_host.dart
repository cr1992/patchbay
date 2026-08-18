import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';
import 'dart:math';

import 'audit.dart';
import 'catalog_digest.dart';
import 'command_descriptor.dart';
import 'command_registry.dart';
import 'execution_evidence.dart';
import 'features.dart';
import 'generated/core_wire.g.dart';
import 'invocation.dart';
import 'response_schema.dart';
import 'snapshot.dart';
import 'version.dart';

typedef PatchbayCatalogSource = Future<Map<String, Object?>> Function();
typedef PatchbaySnapshotSource = Future<Map<String, Object?>> Function();
typedef PatchbayInvocationSource =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
    );
typedef PatchbayExtensionRegistrar =
    void Function(String method, ServiceExtensionHandler handler);

/// Generic VM Service extension host. It has no Flutter or consumer imports.
final class PatchbayServiceHost {
  PatchbayServiceHost({
    required this.applicationId,
    required PatchbayCatalogSource catalog,
    required PatchbaySnapshotSource snapshot,
    required PatchbayInvocationSource invoke,
    PatchbayCommandRegistry? registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    Set<PatchbayFeature> features = const <PatchbayFeature>{},
    this.auditSink,
    this.onAuditSinkError,
  }) : appInstanceId = appInstanceId ?? _nonce(),
       _catalog = catalog,
       _snapshot = snapshot,
       _invoke = invoke,
       _registry = registry ?? PatchbayCommandRegistry(const []),
       _registrar = registrar ?? registerExtension,
       _declaredFeatures = features;

  static const int schemaVersion = 1;
  static const String identityMethod = 'ext.patchbay.identity';
  static const String catalogMethod = 'ext.patchbay.catalog';
  static const String snapshotMethod = 'ext.patchbay.snapshot';
  static const String invokeMethod = 'ext.patchbay.invoke';

  /// Wire-level provenance flag a client attaches when it read the value from
  /// one no-echo stdin line.
  ///
  /// It is protocol metadata, not a command argument. The host consumes it —
  /// enforcing every declared `sensitive` parameter against it and then
  /// removing it — so a hand-written consumer adapter never sees it, never has
  /// to exempt it from an argument whitelist, and must not re-implement the
  /// stdin check against it.
  static const String stdinProvenanceKey = 'inputWasStdin';

  /// Wire parameter carrying one JSON-encoded [PatchbaySnapshotRequestWire].
  ///
  /// The snapshot RPC takes its selection and wait as a single encoded object
  /// for the same reason `invoke` takes `args` that way: the VM Service hands a
  /// handler `Map<String, String>`, so one decoder shared with the direct
  /// transport is the only way both paths can enforce the same shape instead of
  /// each re-parsing loose strings.
  static const String snapshotRequestKey = 'request';

  final String applicationId;
  final String appInstanceId;
  final PatchbayCatalogSource _catalog;
  final PatchbaySnapshotSource _snapshot;
  final PatchbayInvocationSource _invoke;
  final PatchbayCommandRegistry _registry;
  final PatchbayExtensionRegistrar _registrar;
  final Set<PatchbayFeature> _declaredFeatures;
  final PatchbayAuditSink? auditSink;
  final PatchbayAuditSinkErrorHandler? onAuditSinkError;
  final List<PatchbayAuditEvent> _auditLedger = <PatchbayAuditEvent>[];
  final Map<(String, String), _ExternalInvocationRecord> _externalInvocations =
      <(String, String), _ExternalInvocationRecord>{};
  Map<String, PatchbayResponseSchema> _catalogResponseSchemas =
      const <String, PatchbayResponseSchema>{};
  Map<String, PatchbayExecutionContract> _catalogExecutionContracts =
      const <String, PatchbayExecutionContract>{};
  int _catalogReadGeneration = 0;
  bool _registered = false;

  /// The newest 256 redacted command facts, in dispatch completion order.
  List<PatchbayAuditEvent> get auditEvents =>
      List<PatchbayAuditEvent>.unmodifiable(_auditLedger);

  /// Capabilities this host declares on the identity plane.
  ///
  /// [_coreFeatures] are the ones this class implements itself, so a caller
  /// cannot fail to declare them and cannot declare them away — a client that
  /// reads a Patchbay identity is entitled to assume every capability the
  /// protocol layer provides is really there. Anything a layer above adds —
  /// the Flutter host's lifecycle reporting, for instance — arrives through
  /// the constructor.
  Set<PatchbayFeature> get features => <PatchbayFeature>{
    ..._coreFeatures,
    if (_registry.hasResponseSchemas) PatchbayFeature.responseSchemas,
    ..._declaredFeatures,
  };

  static const Set<PatchbayFeature> _coreFeatures = <PatchbayFeature>{
    PatchbayFeature.catalogDigest,
  };

  /// Transport-neutral dispatch seam used by alternate, explicitly enabled
  /// hosts. VM Service registration and direct transports must call these
  /// same handlers instead of rebuilding command routing.
  Future<Map<String, Object?>> dispatchCatalog() async =>
      (await _readCatalog()).response;

  /// Serves the snapshot RPC: the whole snapshot, one selected field, or a
  /// server-side wait for a condition on that field.
  ///
  /// [request] is the raw wire object, decoded here rather than by each
  /// transport, so the VM Service path and the direct HTTP path enforce one
  /// shape and answer one vocabulary. Passing null keeps the original
  /// behaviour — the whole snapshot — unchanged.
  ///
  /// Like the catalog, every failure is *answered*: a malformed request, a
  /// consumer snapshot source that throws, and a wait that runs out all come
  /// back as envelopes. Throwing would cost the caller an unbounded wait for a
  /// reply that a precise diagnosis was already available for, because every
  /// transport in front of this seam turns an escaping error into a dropped
  /// response.
  Future<Map<String, Object?>> dispatchSnapshot([
    Map<String, Object?>? request,
  ]) async {
    if (request == null) {
      final _SnapshotRead read = await _readSnapshot();
      return read.response;
    }
    final PatchbaySnapshotRequest selection;
    try {
      selection = PatchbaySnapshotRequest.fromWire(
        PatchbaySnapshotRequestWire.fromJson(request),
      );
    } on FormatException catch (error) {
      // The decoder phrases its own failures in protocol vocabulary — which
      // field, which rule — so its sentence is exactly what the caller needs.
      return _rejectionEnvelope(
        'invalidSnapshotRequest',
        _invalidSnapshotRequestNotice,
        <String, Object?>{'reason': error.message},
      );
    }
    return selection.isWait
        ? _awaitSnapshot(selection)
        : _selectSnapshot(selection);
  }

  Future<Map<String, Object?>> _selectSnapshot(
    PatchbaySnapshotRequest request,
  ) async {
    final _SnapshotRead read = await _readSnapshot();
    if (read.violated) return read.response;
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'selection': PatchbaySnapshotSelection.resolve(
        read.body,
        request.path,
      ).toJson(),
    };
  }

  /// Polls the consumer snapshot until the condition holds or the budget ends.
  ///
  /// The first probe happens before any delay, so a condition that already
  /// holds answers immediately instead of paying one poll interval. A snapshot
  /// source that fails mid-wait ends the wait with its own envelope rather than
  /// being retried: the caller asked about App state, and a source that cannot
  /// be read is not a state the wait can ever observe.
  ///
  /// The declared budget is a **hard cap on the answer**, not a schedule for
  /// the probes: an observation that arrives past the deadline is reported as
  /// `snapshotWaitTimeout` even when the condition held. The wall clock can
  /// still overshoot it by up to one snapshot-source read, because a consumer
  /// callback already in flight cannot be abandoned — `elapsedMs` in the
  /// rejection is what tells the operator that the source itself is the slow
  /// part.
  Future<Map<String, Object?>> _awaitSnapshot(
    PatchbaySnapshotRequest request,
  ) async {
    final Duration timeout = request.timeout!;
    final PatchbaySnapshotCondition condition = request.until!;
    final Stopwatch elapsed = Stopwatch()..start();
    var polls = 0;
    PatchbaySnapshotSelection? last;
    Map<String, Object?> body = const <String, Object?>{};
    while (true) {
      final _SnapshotRead read = await _readSnapshot();
      if (read.violated) return read.response;
      polls += 1;
      body = read.body;
      last = PatchbaySnapshotSelection.resolve(body, request.path);
      // The budget caps the whole request, not merely the gaps between probes.
      // A consumer snapshot source slow enough to overrun it on its own would
      // otherwise let an observation come back *after* the deadline and still
      // report `observed` — a success the caller already stopped waiting for,
      // and on the CLI side exit 0 where the operator declared exit 5 was the
      // answer. Checked before the condition precisely because the case worth
      // catching is the one where the condition does hold, only too late.
      if (elapsed.elapsed > timeout) break;
      if (last.satisfies(condition, request.value)) {
        return <String, Object?>{
          'schemaVersion': schemaVersion,
          'selection': last.toJson(),
          'wait': PatchbaySnapshotWaitWire(
            outcome: 'observed',
            condition: condition.wire,
            timeoutMs: timeout.inMilliseconds,
            elapsedMs: elapsed.elapsed.inMilliseconds,
            pollIntervalMs: patchbaySnapshotPollInterval.inMilliseconds,
            polls: polls,
          ).toJson(),
        };
      }
      final Duration remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < patchbaySnapshotPollInterval
            ? remaining
            : patchbaySnapshotPollInterval,
      );
    }
    // A timeout is a rejection, exactly as `ui.wait` reports one: the condition
    // was never observed, so there is no observation to accept. The last
    // resolution travels with it — "waited for equals true, kept seeing false"
    // is the half that says whether to wait longer or fix the path.
    return _rejectionEnvelope(
      'snapshotWaitTimeout',
      'The snapshot condition was not observed inside the declared budget.',
      <String, Object?>{
        'path': request.path,
        'condition': condition.name,
        'timeoutMs': timeout.inMilliseconds,
        'elapsedMs': elapsed.elapsed.inMilliseconds,
        'pollIntervalMs': patchbaySnapshotPollInterval.inMilliseconds,
        'polls': polls,
        'observed': last.toJson(),
        // Only when the path was never addressable here to begin with. A first
        // segment that does not exist times out exactly like a field that has
        // not arrived yet, and the two call for opposite actions — wait longer
        // versus fix the path. The host is the only side that knows which keys
        // the App actually publishes, so it is the only side that can say.
        if (_unaddressableRoot(last, body) case final List<String> keys)
          'availableKeys': keys,
      },
    );
  }

  /// The App's top-level keys when [selection] failed on its *first* segment,
  /// or null when the path resolved far enough to be a genuine wait.
  static List<String>? _unaddressableRoot(
    PatchbaySnapshotSelection selection,
    Map<String, Object?> body,
  ) {
    if (selection.miss != PatchbaySnapshotMiss.missingKey) return null;
    final String root = selection.path.split('.').first;
    if (body.containsKey(root)) return null;
    return body.keys.toList(growable: false)..sort();
  }

  /// Reads the consumer snapshot once, answering a failed source instead of
  /// letting it escape as a dropped response.
  Future<_SnapshotRead> _readSnapshot() async {
    final Map<String, Object?> declared;
    try {
      declared = await _snapshot();
    } on Object catch (error) {
      // The type, never the message: a consumer error string is arbitrary App
      // data and this envelope goes back over the wire.
      return _SnapshotRead.violated(
        _providerViolationEnvelope(
          'The App snapshot source failed.',
          <String, Object?>{
            'reason': 'snapshotSourceFailed',
            'error': error.runtimeType.toString(),
          },
        ),
      );
    }
    return _SnapshotRead.valid(<String, Object?>{
      ...declared,
      // Protocol-owned fields always win over consumer callback data.
      'schemaVersion': schemaVersion,
    }, declared);
  }

  Map<String, Object?> _rejectionEnvelope(
    String code,
    String notice,
    Map<String, Object?> details,
  ) => <String, Object?>{
    'schemaVersion': schemaVersion,
    'admission': PatchbayAdmissionWire.rejected.name,
    'notice': notice,
    'rejection': PatchbayRejection(
      code: code,
      notice: notice,
      details: details,
    ).toJson(),
  };

  static const String _invalidSnapshotRequestNotice =
      'The snapshot request violates the Patchbay selection contract.';

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
        arguments: _withoutStdinProvenance(arguments),
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
    _CatalogRead? invocationCatalog;
    final Map<String, Object?> forwarded;
    if (arguments.isEmpty) {
      // No transmitted value can be sensitive and there is no meta key to
      // remove, so the catalog is not consulted: an argument-free command must
      // not start failing because a consumer catalog source is broken.
      forwarded = arguments;
    } else {
      final _CatalogRead catalog = invocationCatalog = await _readCatalog();
      if (catalog.violation case final Map<String, Object?> reason) {
        // The policy is only readable from the catalog. Without it the host
        // cannot prove a sensitive value arrived from stdin, so it fails closed
        // instead of forwarding the arguments unchecked. The catalog's own
        // violation travels along, so the caller is told what to fix here and
        // does not have to go read the catalog RPC to find out.
        return _invalidInvocationEnvelope(
          requestId,
          'catalogUnavailable',
          <String, Object?>{'catalog': reason},
        );
      }
      final _CommandPolicy policy = _CommandPolicy.forCommand(
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
          : _withoutStdinProvenance(arguments);
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
      _CatalogRead? externalCatalog = invocationCatalog;
      externalCatalog ??= await _readCatalog();
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
    if (wire.schemaVersion != schemaVersion) {
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
        ? _catalogResponseSchemas[command]
        : _responseSchemasFromCatalog(invocationCatalog.response)[command];
    executionContract ??= invocationCatalog == null
        ? _catalogExecutionContracts[command]
        : _executionContractsFromCatalog(invocationCatalog.response)[command];
    if (responseSchema == null &&
        invocationCatalog == null &&
        !_registry.handles(command)) {
      // An argument-free external command did not need the catalog for input
      // policy, but it may still have declared an output contract. Discover it
      // after adapter dispatch so a broken catalog cannot make a legacy,
      // argument-free command stop working; a valid declaration, however, is
      // never bypassed merely because this was the first direct invocation.
      final _CatalogRead discovered = await _readCatalog();
      if (discovered.violation == null) {
        responseSchema = _responseSchemasFromCatalog(
          discovered.response,
        )[command];
        executionContract = _executionContractsFromCatalog(
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
    final _ExternalInvocationRecord? existing = _externalInvocations[key];
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
    final _ExternalInvocationRecord record = _ExternalInvocationRecord(
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
    for (final MapEntry<(String, String), _ExternalInvocationRecord> entry
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
          // An observer of an already-isolated sink failure cannot change
          // the command fact either.
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

  void register() {
    if (_registered) return;
    _registered = true;
    _registrar(identityMethod, handleIdentity);
    _registrar(catalogMethod, handleCatalog);
    _registrar(snapshotMethod, handleSnapshot);
    _registrar(invokeMethod, handleInvoke);
  }

  Future<ServiceExtensionResponse> handleSnapshot(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != snapshotMethod ||
        parameters.keys.any(
          (String key) => key != 'isolateId' && key != snapshotRequestKey,
        )) {
      return _invalidParams('snapshot received unknown parameters');
    }
    final String? encoded = parameters[snapshotRequestKey];
    if (encoded == null) return _result(await dispatchSnapshot());
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return _invalidParams('$snapshotRequestKey must be a JSON object');
    }
    if (decoded is! Map<String, dynamic>) {
      return _invalidParams('$snapshotRequestKey must be a JSON object');
    }
    return _result(await dispatchSnapshot(Map<String, Object?>.from(decoded)));
  }

  Future<ServiceExtensionResponse> handleIdentity(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != identityMethod || _hasUserParameters(parameters)) {
      return _invalidParams('identity does not accept parameters');
    }
    return _result(identityResponse());
  }

  /// The identity answer, without the VM Service response wrapper.
  ///
  /// [serverVersion] and [features] are additive fields under the same
  /// `schemaVersion`: an older client reads identity key by key and ignores
  /// what it does not know, so gaining them breaks nobody, while a newer
  /// client that finds them absent learns the host predates them. That is the
  /// evolution rule this plane exists to demonstrate — see
  /// `docs/design.md`.
  Map<String, Object?> identityResponse() => PatchbayIdentityWire(
    schemaVersion: schemaVersion,
    serverVersion: patchbayPackageVersion,
    // Sorted so two hosts declaring the same capabilities produce the same
    // bytes, and so a diff of two identity answers shows a capability change
    // rather than a set iteration order.
    features:
        features
            .map((PatchbayFeature feature) => feature.name)
            .toList(growable: false)
          ..sort(),
    applicationId: applicationId,
    appInstanceId: appInstanceId,
    isolateId: Service.getIsolateId(Isolate.current),
  ).toJson();

  Future<ServiceExtensionResponse> handleCatalog(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != catalogMethod || _hasUserParameters(parameters)) {
      return _invalidParams('catalog does not accept parameters');
    }
    return _result(await dispatchCatalog());
  }

  Future<ServiceExtensionResponse> handleInvoke(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != invokeMethod ||
        parameters.keys.any(
          (String key) =>
              key != 'isolateId' &&
              key != 'command' &&
              key != 'args' &&
              key != 'requestId',
        )) {
      return _invalidParams('invoke received unknown parameters');
    }
    final String? command = parameters['command'];
    final String requestId = parameters['requestId'] ?? _nonce();
    if (command == null || command.isEmpty) {
      return _invalidParams('command is required');
    }
    if (requestId.isEmpty) {
      return _invalidParams('requestId must not be empty');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(parameters['args'] ?? '{}');
    } on FormatException {
      return _invalidParams('args must be a JSON object');
    }
    if (decoded is! Map<String, dynamic>) {
      return _invalidParams('args must be a JSON object');
    }
    return _result(
      await dispatchInvoke(
        command,
        Map<String, Object?>.from(decoded),
        requestId,
      ),
    );
  }

  /// Reads the consumer catalog once and validates it as a whole.
  ///
  /// A catalog that violates the protocol is *answered*, never thrown. Every
  /// transport in front of this seam — `registerExtension` and the direct HTTP
  /// host — turns an escaping error into a dropped response, so throwing costs
  /// the caller an unbounded wait for a reply that a precise diagnosis was
  /// already available for. Only an envelope reaches the caller.
  ///
  /// A violated catalog carries no `commands` at all. Skipping the offending
  /// entries and serving the rest would hide a consumer bug behind a catalog
  /// that quietly lost capabilities, which is the one failure mode a debugging
  /// protocol must never produce.
  Future<_CatalogRead> _readCatalog() async {
    final int generation = ++_catalogReadGeneration;
    final Map<String, Object?> declared;
    try {
      declared = await _catalog();
    } on Object catch (error) {
      if (generation == _catalogReadGeneration) {
        _catalogResponseSchemas = const <String, PatchbayResponseSchema>{};
        _catalogExecutionContracts =
            const <String, PatchbayExecutionContract>{};
      }
      // The type, never the message: a consumer error string is arbitrary App
      // data and this envelope goes back over the wire.
      return _CatalogRead.violated(<String, Object?>{
        'reason': 'catalogSourceFailed',
        'error': error.runtimeType.toString(),
      });
    }
    final Object? declaredCommands = declared['commands'];
    final Object? commands = switch (declaredCommands) {
      List<Object?> values => <Object?>[
        ..._registry.descriptors.map((descriptor) => descriptor.toJson()),
        ...values,
      ],
      null when !_registry.isEmpty => <Object?>[
        ..._registry.descriptors.map((descriptor) => descriptor.toJson()),
      ],
      _ => declaredCommands,
    };
    final Map<String, Object?> catalog = <String, Object?>{
      ...declared,
      if (commands != null) 'commands': commands,
      // Protocol-owned fields always win over consumer callback data.
      'schemaVersion': schemaVersion,
    };
    final Map<String, Object?>? violation = _commandsViolation(
      catalog['commands'],
    );
    if (violation != null) {
      if (generation == _catalogReadGeneration) {
        _catalogResponseSchemas = const <String, PatchbayResponseSchema>{};
        _catalogExecutionContracts =
            const <String, PatchbayExecutionContract>{};
      }
      return _CatalogRead.violated(violation);
    }
    if (generation == _catalogReadGeneration) {
      _catalogResponseSchemas = _responseSchemasFromCatalog(catalog);
      _catalogExecutionContracts = _executionContractsFromCatalog(catalog);
    }
    return _CatalogRead.valid(<String, Object?>{
      ...catalog,
      // Protocol-owned, and only ever attached to a catalog that passed
      // validation: a violated catalog carries no `commands`, so there is no
      // command surface for a digest to describe and none is invented.
      'catalogDigest': PatchbayCatalogDigest.ofCommands(
        catalog['commands'],
      ).toJson(),
    });
  }

  /// The rejection `details` describing what makes [commands] unusable, or null
  /// when the declared command list satisfies the protocol.
  static Map<String, Object?>? _commandsViolation(Object? commands) {
    if (commands == null) return null;
    if (commands is! List<Object?>) {
      return <String, Object?>{'reason': 'commandsNotAnArray'};
    }
    final List<Map<String, Object?>> violations = <Map<String, Object?>>[];
    final Set<String> names = <String>{};
    for (var index = 0; index < commands.length; index += 1) {
      final Object? entry = commands[index];
      final Object? rawName = entry is Map<Object?, Object?>
          ? entry['name']
          : null;
      if (rawName is! String) {
        // Nothing nameable to echo — a string abbreviation, a missing key, or a
        // non-string name — so the entry is identified by position only.
        violations.add(<String, Object?>{
          'index': index,
          'reason': 'missingCommandName',
        });
      } else if (!_commandName.hasMatch(rawName)) {
        // A command name is public protocol vocabulary, not consumer data, so
        // naming the offender is safe — and it is the whole point: the consumer
        // that shipped `auth.switch-tenant` learned nothing from a bare throw.
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'invalidCommandName',
        });
      } else if (!names.add(rawName)) {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'duplicateCommandName',
        });
      } else if (entry case final Map<Object?, Object?> command) {
        if (command.containsKey('responseSchema')) {
          try {
            final PatchbayResponseSchema schema =
                PatchbayResponseSchema.fromJson(command['responseSchema']);
            if (command['mode'] == 'job' &&
                !schema.terminal.keys.toSet().containsAll(const <String>{
                  'completed',
                  'failed',
                  'cancelled',
                })) {
              throw const FormatException('incomplete terminal schema');
            }
          } on Object {
            violations.add(<String, Object?>{
              'index': index,
              'name': rawName,
              'reason': 'invalidResponseSchema',
            });
          }
        }
        if (command.containsKey('retryPolicy')) {
          try {
            if (command['sideEffect'] != PatchbaySideEffectWire.external.name) {
              throw const FormatException(
                'retryPolicy requires external sideEffect',
              );
            }
            PatchbayRetryPolicy.fromJson(command['retryPolicy']);
          } on Object {
            violations.add(<String, Object?>{
              'index': index,
              'name': rawName,
              'reason': 'invalidRetryPolicy',
            });
          }
        }
        try {
          PatchbayExecutionContract.fromCatalogRow(command);
        } on Object {
          violations.add(<String, Object?>{
            'index': index,
            'name': rawName,
            'reason': 'invalidExecutionContract',
          });
        }
      }
    }
    if (violations.isEmpty) return null;
    // Every offender in one answer. Reporting only the first turns a rename
    // sweep into one round trip per bad name.
    return <String, Object?>{
      'reason': 'invalidCatalogCommands',
      'commandNamePattern': _commandName.pattern,
      'violations': violations,
    };
  }

  static Map<String, Object?> _withoutStdinProvenance(
    Map<String, Object?> arguments,
  ) => arguments.containsKey(stdinProvenanceKey)
      ? (Map<String, Object?>.of(arguments)..remove(stdinProvenanceKey))
      : arguments;

  static ServiceExtensionResponse _result(Map<String, Object?> value) =>
      ServiceExtensionResponse.result(jsonEncode(value));

  static ServiceExtensionResponse _invalidParams(String message) =>
      ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode(<String, Object?>{'message': message}),
      );

  /// `VmService.callServiceExtension` carries the routed isolate id in the
  /// handler parameter map. It is VM metadata, not a Patchbay RPC argument.
  static bool _hasUserParameters(Map<String, String> parameters) =>
      parameters.keys.any((String key) => key != 'isolateId');

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

  static Map<String, PatchbayResponseSchema> _responseSchemasFromCatalog(
    Map<String, Object?> catalog,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return const <String, PatchbayResponseSchema>{};
    final Map<String, PatchbayResponseSchema> schemas =
        <String, PatchbayResponseSchema>{};
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> ||
          row['name'] is! String ||
          !row.containsKey('responseSchema')) {
        continue;
      }
      schemas[row['name']! as String] = PatchbayResponseSchema.fromJson(
        row['responseSchema'],
      );
    }
    return Map<String, PatchbayResponseSchema>.unmodifiable(schemas);
  }

  static Map<String, PatchbayExecutionContract> _executionContractsFromCatalog(
    Map<String, Object?> catalog,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) {
      return const <String, PatchbayExecutionContract>{};
    }
    return Map<String, PatchbayExecutionContract>.unmodifiable(<
      String,
      PatchbayExecutionContract
    >{
      for (final Object? row in rows)
        if (row is Map<Object?, Object?> && row['name'] is String)
          row['name']! as String: PatchbayExecutionContract.fromCatalogRow(row),
    });
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

  static final RegExp _commandName = RegExp(
    r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$',
  );

  static String _nonce() {
    final Random random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One catalog read: either the catalog to serve, or the whole-catalog
/// protocol violation that makes it unusable.
///
/// When [violation] is set, [response] is the rejection envelope every catalog
/// caller receives in place of the catalog — it deliberately has no `commands`
/// key, so no caller can mistake a violated catalog for an App that declares
/// nothing.
final class _CatalogRead {
  const _CatalogRead._({required this.response, required this.violation});

  const _CatalogRead.valid(this.response) : violation = null;

  factory _CatalogRead.violated(Map<String, Object?> violation) =>
      _CatalogRead._(
        response: _violationEnvelope(violation),
        violation: violation,
      );

  final Map<String, Object?> response;

  /// The rejection `details` naming what is wrong, or null for a valid catalog.
  final Map<String, Object?>? violation;

  static Map<String, Object?> _violationEnvelope(
    Map<String, Object?> violation,
  ) => _providerViolationEnvelope(_violationNotice, violation);

  static const String _violationNotice =
      'The App catalog violates the Patchbay command contract.';
}

/// One snapshot read: either the snapshot to serve, or the envelope that
/// replaces it when the consumer source could not be read.
final class _SnapshotRead {
  const _SnapshotRead._(this.response, this.body, {required this.violated});

  const _SnapshotRead.valid(
    Map<String, Object?> response,
    Map<String, Object?> body,
  ) : this._(response, body, violated: false);

  const _SnapshotRead.violated(Map<String, Object?> response)
    : this._(response, const <String, Object?>{}, violated: true);

  /// The snapshot, or the rejection envelope every caller receives instead.
  final Map<String, Object?> response;

  /// The App's snapshot exactly as it was served — the addressing root for a
  /// selection, and deliberately *not* [response].
  ///
  /// The two differ by the protocol-owned fields the host layers on top. A path
  /// resolved against the response could select `schemaVersion`, answering a
  /// host field as though the App had published it; the operator has no way to
  /// tell that apart from their own data. What the App nests inside its own
  /// snapshot stays part of the path, because that nesting is the App's and the
  /// host has no business guessing which of a consumer's keys is "really" the
  /// body — the shipped example publishes its state flat, others wrap it.
  final Map<String, Object?> body;
  final bool violated;
}

/// The envelope a provider-side contract failure is answered with.
///
/// Reuses the invocation vocabulary — `admission` plus a stable rejection
/// `code` — so a client that already classifies rejections classifies a broken
/// catalog or an unreadable snapshot without learning a second error shape.
Map<String, Object?> _providerViolationEnvelope(
  String notice,
  Map<String, Object?> violation,
) => <String, Object?>{
  'schemaVersion': PatchbayServiceHost.schemaVersion,
  'admission': PatchbayAdmissionWire.rejected.name,
  'notice': notice,
  'rejection': PatchbayRejection(
    code: 'providerProtocolViolation',
    notice: notice,
    details: violation,
  ).toJson(),
};

final class _ExternalInvocationRecord {
  _ExternalInvocationRecord({
    required this.argumentDigest,
    required this.idempotent,
  });

  final String argumentDigest;
  final bool idempotent;
  late final Future<Map<String, Object?>> response;
  bool settled = false;
}

/// The catalog-declared argument policy the host enforces before dispatch.
final class _CommandPolicy {
  const _CommandPolicy({
    required this.sensitiveParameters,
    required this.retainsStdinProvenance,
  });

  /// Reads the argument policy of [command] from [catalog], which is the single
  /// source of truth for what a command declares.
  ///
  /// Deriving it here is what keeps the guarantee framework-owned: a consumer
  /// declares `sensitive: true` once in its descriptor and gets the stdin
  /// enforcement for free, with no matching code in its invoke handler.
  ///
  /// [catalog] must be a validated one: the caller proves every entry is an
  /// object with a unique, valid dotted name before this scan trusts the lookup.
  factory _CommandPolicy.forCommand(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Object? commands = catalog['commands'];
    if (commands is! List<Object?>) return const _CommandPolicy.undeclared();
    for (final Object? entry in commands) {
      if (entry is! Map<Object?, Object?> || entry['name'] != command) continue;
      final Object? parameters = entry['parameters'];
      return _CommandPolicy(
        sensitiveParameters: <String>{
          if (parameters is List<Object?>)
            for (final Object? parameter in parameters)
              if (parameter is Map<Object?, Object?> &&
                  parameter['sensitive'] == true &&
                  parameter['name'] is String)
                parameter['name']! as String,
        },
        // The Flutter UI plane is served by this repository's own bridge, whose
        // sensitivity is per-target (`PatchbaySensitivePolicy.redacted`, an
        // obscured Semantics node) and therefore not expressible in a parameter
        // descriptor. That bridge still reads the provenance itself, so the meta
        // key survives for it — and only for it.
        retainsStdinProvenance:
            entry['plane'] == PatchbayPlaneWire.flutterUi.name,
      );
    }
    return const _CommandPolicy.undeclared();
  }

  /// A command the catalog does not declare. The consumer will reject it as
  /// unregistered; the meta key is still removed so an undeclared handler
  /// cannot come to depend on it either.
  const _CommandPolicy.undeclared()
    : sensitiveParameters = const <String>{},
      retainsStdinProvenance = false;

  final Set<String> sensitiveParameters;
  final bool retainsStdinProvenance;

  /// Names of the sensitive parameters this request carries without attesting
  /// stdin provenance, sorted so the rejection details are deterministic.
  ///
  /// A declared default is deliberately not counted: the flag attests where a
  /// *transmitted* value came from, and a value the App bakes in never crossed
  /// the wire.
  List<String> sensitiveViolations(Map<String, Object?> arguments) {
    if (sensitiveParameters.isEmpty) return const <String>[];
    if (arguments[PatchbayServiceHost.stdinProvenanceKey] == true) {
      return const <String>[];
    }
    return <String>[
      for (final String name in sensitiveParameters)
        if (arguments[name] != null) name,
    ]..sort();
  }
}
