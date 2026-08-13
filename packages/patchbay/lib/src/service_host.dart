import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';
import 'dart:math';

import 'generated/core_wire.g.dart';
import 'invocation.dart';

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
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
  }) : appInstanceId = appInstanceId ?? _nonce(),
       _catalog = catalog,
       _snapshot = snapshot,
       _invoke = invoke,
       _registrar = registrar ?? registerExtension;

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

  final String applicationId;
  final String appInstanceId;
  final PatchbayCatalogSource _catalog;
  final PatchbaySnapshotSource _snapshot;
  final PatchbayInvocationSource _invoke;
  final PatchbayExtensionRegistrar _registrar;
  bool _registered = false;

  /// Transport-neutral dispatch seam used by alternate, explicitly enabled
  /// hosts. VM Service registration and direct transports must call these
  /// same handlers instead of rebuilding command routing.
  Future<Map<String, Object?>> dispatchCatalog() async =>
      (await _readCatalog()).response;

  Future<Map<String, Object?>> dispatchSnapshot() async => <String, Object?>{
    ...await _snapshot(),
    // Protocol-owned fields always win over consumer callback data.
    'schemaVersion': schemaVersion,
  };

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    if (requestId.isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    final Map<String, Object?> forwarded;
    if (arguments.isEmpty) {
      // No transmitted value can be sensitive and there is no meta key to
      // remove, so the catalog is not consulted: an argument-free command must
      // not start failing because a consumer catalog source is broken.
      forwarded = arguments;
    } else {
      final _CatalogRead catalog = await _readCatalog();
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
    final Map<String, Object?> result = await _invoke(
      command,
      forwarded,
      requestId,
    );
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
    return result;
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
    if (method != snapshotMethod || _hasUserParameters(parameters)) {
      return _invalidParams('snapshot does not accept parameters');
    }
    return _result(await dispatchSnapshot());
  }

  Future<ServiceExtensionResponse> handleIdentity(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != identityMethod || _hasUserParameters(parameters)) {
      return _invalidParams('identity does not accept parameters');
    }
    return _result(
      PatchbayIdentityWire(
        schemaVersion: schemaVersion,
        applicationId: applicationId,
        appInstanceId: appInstanceId,
        isolateId: Service.getIsolateId(Isolate.current),
      ).toJson(),
    );
  }

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
    final Map<String, Object?> declared;
    try {
      declared = await _catalog();
    } on Object catch (error) {
      // The type, never the message: a consumer error string is arbitrary App
      // data and this envelope goes back over the wire.
      return _CatalogRead.violated(<String, Object?>{
        'reason': 'catalogSourceFailed',
        'error': error.runtimeType.toString(),
      });
    }
    final Map<String, Object?> catalog = <String, Object?>{
      ...declared,
      // Protocol-owned fields always win over consumer callback data.
      'schemaVersion': schemaVersion,
    };
    final Map<String, Object?>? violation = _commandsViolation(
      catalog['commands'],
    );
    return violation == null
        ? _CatalogRead.valid(catalog)
        : _CatalogRead.violated(violation);
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

  /// Reuses the invocation vocabulary — `admission` plus a stable rejection
  /// `code` — so a client that already classifies rejections classifies a
  /// broken catalog without learning a second error shape.
  static Map<String, Object?> _violationEnvelope(
    Map<String, Object?> violation,
  ) => <String, Object?>{
    'schemaVersion': PatchbayServiceHost.schemaVersion,
    'admission': PatchbayAdmissionWire.rejected.name,
    'notice': _violationNotice,
    'rejection': PatchbayRejection(
      code: 'providerProtocolViolation',
      notice: _violationNotice,
      details: violation,
    ).toJson(),
  };

  static const String _violationNotice =
      'The App catalog violates the Patchbay command contract.';
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
