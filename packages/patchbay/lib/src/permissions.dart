/// Platform-neutral permission state and external-driver wire contracts.
///
/// This library deliberately has no platform or Flutter dependencies. Native
/// permission UI belongs to an explicitly installed external driver.
library;

const String patchbayPermissionProtocolVersion = '1.0';
const int patchbayPermissionProtocolMajor = 1;

enum PatchbayPermissionState {
  notDetermined,
  granted,
  denied,
  permanentlyDenied,
  limited,
  restricted,
  allowOnce,
  unsupported,
  unknown;

  static PatchbayPermissionState fromWire(Object? value) => values.firstWhere(
    (PatchbayPermissionState state) => state.name == value,
    orElse: () => unknown,
  );
}

enum PatchbayPermissionFactSource {
  deviceReported,
  appRecorded,
  uiObserved,
  unknown;

  static PatchbayPermissionFactSource fromWire(Object? value) =>
      values.firstWhere(
        (PatchbayPermissionFactSource source) => source.name == value,
        orElse: () => unknown,
      );
}

enum PatchbayPermissionAction { status, grant, revoke, reset, exercise }

enum PatchbayPermissionDecision { allow, deny, allowOnce }

enum PatchbayPermissionOperation {
  capabilities,
  status,
  normalize,
  exercise,
  fail,
}

final class PatchbayPermissionCapability {
  const PatchbayPermissionCapability({
    required this.actions,
    this.decisions = const <PatchbayPermissionDecision>{},
  });

  factory PatchbayPermissionCapability.fromJson(Map<String, Object?> json) =>
      PatchbayPermissionCapability(
        actions: _enumSet(
          json['actions'],
          PatchbayPermissionAction.values,
          'permissionCapabilityInvalid',
        ),
        decisions: _enumSet(
          json['decisions'] ?? const <Object?>[],
          PatchbayPermissionDecision.values,
          'permissionCapabilityInvalid',
        ),
      );

  final Set<PatchbayPermissionAction> actions;
  final Set<PatchbayPermissionDecision> decisions;

  Map<String, Object?> toJson() => <String, Object?>{
    'actions': _sortedNames(actions),
    'decisions': _sortedNames(decisions),
  };
}

final class PatchbayPermissionCapabilities {
  const PatchbayPermissionCapabilities({
    required this.platform,
    required this.driver,
    required this.driverVersion,
    required this.permissions,
  });

  factory PatchbayPermissionCapabilities.fromJson(Map<String, Object?> json) {
    final String platform = _requiredString(
      json['platform'],
      'permissionCapabilityInvalid',
    );
    final String driver = _requiredString(
      json['driver'],
      'permissionCapabilityInvalid',
    );
    final String driverVersion = _requiredString(
      json['driverVersion'],
      'permissionCapabilityInvalid',
    );
    final Object? rawPermissions = json['permissions'];
    if (rawPermissions is! Map<Object?, Object?>) {
      throw const PatchbayPermissionWireException(
        'permissionCapabilityInvalid',
      );
    }
    final Map<String, PatchbayPermissionCapability> permissions =
        <String, PatchbayPermissionCapability>{};
    for (final MapEntry<Object?, Object?> entry in rawPermissions.entries) {
      if (entry.key is! String ||
          (entry.key! as String).isEmpty ||
          entry.value is! Map<Object?, Object?>) {
        throw const PatchbayPermissionWireException(
          'permissionCapabilityInvalid',
        );
      }
      permissions[entry.key! as String] = PatchbayPermissionCapability.fromJson(
        Map<String, Object?>.from(entry.value! as Map),
      );
    }
    return PatchbayPermissionCapabilities(
      platform: platform,
      driver: driver,
      driverVersion: driverVersion,
      permissions: Map<String, PatchbayPermissionCapability>.unmodifiable(
        permissions,
      ),
    );
  }

  final String platform;
  final String driver;
  final String driverVersion;
  final Map<String, PatchbayPermissionCapability> permissions;

  Map<String, Object?> toJson() => <String, Object?>{
    'platform': platform,
    'driver': driver,
    'driverVersion': driverVersion,
    'permissions': <String, Object?>{
      for (final String permission in permissions.keys.toList()..sort())
        permission: permissions[permission]!.toJson(),
    },
  };
}

final class PatchbayPermissionStatus {
  const PatchbayPermissionStatus({
    required this.permission,
    required this.platformPermission,
    required this.state,
    required this.platformState,
    required this.factSource,
    required this.driver,
    required this.driverVersion,
    required this.supportedActions,
    required this.requiresRestart,
    required this.requiresSettings,
    required this.systemUiExpected,
    this.notice,
  });

  factory PatchbayPermissionStatus.fromJson(Map<String, Object?> json) {
    final Object? actions = json['supportedActions'];
    final String state = _requiredString(
      json['state'],
      'permissionStatusInvalid',
    );
    final String factSource = _requiredString(
      json['factSource'],
      'permissionStatusInvalid',
    );
    return PatchbayPermissionStatus(
      permission: _requiredString(
        json['permission'],
        'permissionStatusInvalid',
      ),
      platformPermission: _requiredString(
        json['platformPermission'],
        'permissionStatusInvalid',
      ),
      state: PatchbayPermissionState.fromWire(state),
      platformState: _requiredString(
        json['platformState'],
        'permissionStatusInvalid',
      ),
      factSource: PatchbayPermissionFactSource.fromWire(factSource),
      driver: _requiredString(json['driver'], 'permissionStatusInvalid'),
      driverVersion: _requiredString(
        json['driverVersion'],
        'permissionStatusInvalid',
      ),
      supportedActions: _enumSet(
        actions,
        PatchbayPermissionAction.values,
        'permissionStatusInvalid',
      ),
      requiresRestart: _requiredBool(
        json['requiresRestart'],
        'permissionStatusInvalid',
      ),
      requiresSettings: _requiredBool(
        json['requiresSettings'],
        'permissionStatusInvalid',
      ),
      systemUiExpected: _requiredBool(
        json['systemUiExpected'],
        'permissionStatusInvalid',
      ),
      notice: _optionalString(json['notice'], 'permissionStatusInvalid'),
    );
  }

  final String permission;
  final String platformPermission;
  final PatchbayPermissionState state;
  final String platformState;
  final PatchbayPermissionFactSource factSource;
  final String driver;
  final String driverVersion;
  final Set<PatchbayPermissionAction> supportedActions;
  final bool requiresRestart;
  final bool requiresSettings;
  final bool systemUiExpected;
  final String? notice;

  Map<String, Object?> toJson() => <String, Object?>{
    'permission': permission,
    'platformPermission': platformPermission,
    'state': state.name,
    'platformState': platformState,
    'factSource': factSource.name,
    'driver': driver,
    'driverVersion': driverVersion,
    'supportedActions': _sortedNames(supportedActions),
    'requiresRestart': requiresRestart,
    'requiresSettings': requiresSettings,
    'systemUiExpected': systemUiExpected,
    if (notice != null) 'notice': notice,
  };
}

final class PatchbayPermissionEvidence {
  const PatchbayPermissionEvidence({
    required this.factSource,
    required this.kind,
    this.details = const <String, Object?>{},
  });

  factory PatchbayPermissionEvidence.fromJson(Map<String, Object?> json) {
    final Object? details = json['details'] ?? const <String, Object?>{};
    if (details is! Map<Object?, Object?>) {
      throw const PatchbayPermissionWireException('permissionEvidenceInvalid');
    }
    return PatchbayPermissionEvidence(
      factSource: PatchbayPermissionFactSource.fromWire(
        _requiredString(json['factSource'], 'permissionEvidenceInvalid'),
      ),
      kind: _requiredString(json['kind'], 'permissionEvidenceInvalid'),
      details: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(details),
      ),
    );
  }

  final PatchbayPermissionFactSource factSource;
  final String kind;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'factSource': factSource.name,
    'kind': kind,
    'details': details,
  };
}

final class PatchbayPermissionInterruption {
  const PatchbayPermissionInterruption({
    required this.expected,
    required this.handled,
    this.permission,
    this.decision,
    this.code,
  });

  factory PatchbayPermissionInterruption.fromJson(
    Map<String, Object?> json,
  ) => PatchbayPermissionInterruption(
    expected: _requiredBool(json['expected'], 'permissionInterruptionInvalid'),
    handled: _requiredBool(json['handled'], 'permissionInterruptionInvalid'),
    permission: _optionalString(
      json['permission'],
      'permissionInterruptionInvalid',
    ),
    decision: json['decision'] == null
        ? null
        : _requiredEnum(
            json['decision'],
            PatchbayPermissionDecision.values,
            'permissionInterruptionInvalid',
          ),
    code: _optionalString(json['code'], 'permissionInterruptionInvalid'),
  );

  final bool expected;
  final bool handled;
  final String? permission;
  final PatchbayPermissionDecision? decision;
  final String? code;

  Map<String, Object?> toJson() => <String, Object?>{
    'expected': expected,
    'handled': handled,
    if (permission != null) 'permission': permission,
    if (decision != null) 'decision': decision!.name,
    if (code != null) 'code': code,
  };
}

final class PatchbayPermissionDriverRequest {
  const PatchbayPermissionDriverRequest({
    this.protocolVersion = patchbayPermissionProtocolVersion,
    required this.requestId,
    required this.operation,
    this.deviceId,
    this.applicationId,
    this.sessionRef,
    this.permission,
    this.policy,
    this.state,
    this.decision,
    required this.timeoutMs,
  });

  factory PatchbayPermissionDriverRequest.fromJson(Map<String, Object?> json) {
    final Object? rawSessionRef = json['sessionRef'];
    if (rawSessionRef != null && rawSessionRef is! Map<Object?, Object?>) {
      throw const PatchbayPermissionWireException(
        'permissionDriverRequestInvalid',
      );
    }
    final Object? rawTimeout = json['timeoutMs'];
    if (rawTimeout is! int || rawTimeout <= 0) {
      throw const PatchbayPermissionWireException(
        'permissionDriverRequestInvalid',
      );
    }
    return PatchbayPermissionDriverRequest(
      protocolVersion: _requiredString(
        json['protocolVersion'],
        'permissionDriverRequestInvalid',
      ),
      requestId: _requiredString(
        json['requestId'],
        'permissionDriverRequestInvalid',
      ),
      operation: _requiredEnum(
        json['operation'],
        PatchbayPermissionOperation.values,
        'permissionDriverRequestInvalid',
      ),
      deviceId: _optionalString(
        json['deviceId'],
        'permissionDriverRequestInvalid',
      ),
      applicationId: _optionalString(
        json['applicationId'],
        'permissionDriverRequestInvalid',
      ),
      sessionRef: rawSessionRef == null
          ? null
          : Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(rawSessionRef as Map),
            ),
      permission: _optionalString(
        json['permission'],
        'permissionDriverRequestInvalid',
      ),
      policy: _optionalString(json['policy'], 'permissionDriverRequestInvalid'),
      state: json['state'] == null
          ? null
          : _requiredEnum(
              json['state'],
              PatchbayPermissionState.values,
              'permissionDriverRequestInvalid',
            ),
      decision: json['decision'] == null
          ? null
          : _requiredEnum(
              json['decision'],
              PatchbayPermissionDecision.values,
              'permissionDriverRequestInvalid',
            ),
      timeoutMs: rawTimeout,
    );
  }

  final String protocolVersion;
  final String requestId;
  final PatchbayPermissionOperation operation;
  final String? deviceId;
  final String? applicationId;
  final Map<String, Object?>? sessionRef;
  final String? permission;
  final String? policy;
  final PatchbayPermissionState? state;
  final PatchbayPermissionDecision? decision;
  final int timeoutMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'requestId': requestId,
    'operation': operation.name,
    if (deviceId != null) 'deviceId': deviceId,
    if (applicationId != null) 'applicationId': applicationId,
    if (sessionRef != null) 'sessionRef': sessionRef,
    if (permission != null) 'permission': permission,
    if (policy != null) 'policy': policy,
    if (state != null) 'state': state!.name,
    if (decision != null) 'decision': decision!.name,
    'timeoutMs': timeoutMs,
  };
}

final class PatchbayPermissionDriverResponse {
  const PatchbayPermissionDriverResponse({
    required this.protocolVersion,
    required this.requestId,
    required this.admission,
    this.code,
    this.details = const <String, Object?>{},
    this.capabilities,
    this.before,
    this.after,
    this.evidence = const <PatchbayPermissionEvidence>[],
    this.interruption,
    this.notice,
  });

  factory PatchbayPermissionDriverResponse.fromJson(Map<String, Object?> json) {
    final String admission = _requiredString(
      json['admission'],
      'permissionDriverResponseInvalid',
    );
    if (admission != 'accepted' && admission != 'rejected') {
      throw const PatchbayPermissionWireException(
        'permissionDriverResponseInvalid',
      );
    }
    final Object? rawRejection = json['rejection'];
    if (admission == 'rejected' && rawRejection is! Map<Object?, Object?>) {
      throw const PatchbayPermissionWireException(
        'permissionDriverResponseInvalid',
      );
    }
    final Map<Object?, Object?>? rejection =
        rawRejection is Map<Object?, Object?> ? rawRejection : null;
    final Object? rawDetails =
        rejection?['details'] ?? const <String, Object?>{};
    if (rawDetails is! Map<Object?, Object?>) {
      throw const PatchbayPermissionWireException(
        'permissionDriverResponseInvalid',
      );
    }
    final Object? rawEvidence = json['evidence'] ?? const <Object?>[];
    if (rawEvidence is! List<Object?> ||
        rawEvidence.any((Object? item) => item is! Map<Object?, Object?>)) {
      throw const PatchbayPermissionWireException(
        'permissionDriverResponseInvalid',
      );
    }
    final Map<Object?, Object?>? rawCapabilities = _optionalMap(
      json['capabilities'],
    );
    final Map<Object?, Object?>? rawBefore = _optionalMap(json['before']);
    final Map<Object?, Object?>? rawAfter = _optionalMap(json['after']);
    final Map<Object?, Object?>? rawInterruption = _optionalMap(
      json['interruption'],
    );
    return PatchbayPermissionDriverResponse(
      protocolVersion: _requiredString(
        json['protocolVersion'],
        'permissionDriverResponseInvalid',
      ),
      requestId: _requiredString(
        json['requestId'],
        'permissionDriverResponseInvalid',
      ),
      admission: admission,
      code: rejection == null
          ? null
          : _requiredString(
              rejection['code'],
              'permissionDriverResponseInvalid',
            ),
      details: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(rawDetails),
      ),
      capabilities: rawCapabilities == null
          ? null
          : PatchbayPermissionCapabilities.fromJson(
              Map<String, Object?>.from(rawCapabilities),
            ),
      before: rawBefore == null
          ? null
          : PatchbayPermissionStatus.fromJson(
              Map<String, Object?>.from(rawBefore),
            ),
      after: rawAfter == null
          ? null
          : PatchbayPermissionStatus.fromJson(
              Map<String, Object?>.from(rawAfter),
            ),
      evidence: <PatchbayPermissionEvidence>[
        for (final Object? item in rawEvidence)
          PatchbayPermissionEvidence.fromJson(
            Map<String, Object?>.from(item! as Map),
          ),
      ],
      interruption: rawInterruption == null
          ? null
          : PatchbayPermissionInterruption.fromJson(
              Map<String, Object?>.from(rawInterruption),
            ),
      notice: _optionalString(
        json['notice'],
        'permissionDriverResponseInvalid',
      ),
    );
  }

  final String protocolVersion;
  final String requestId;
  final String admission;
  final String? code;
  final Map<String, Object?> details;
  final PatchbayPermissionCapabilities? capabilities;
  final PatchbayPermissionStatus? before;
  final PatchbayPermissionStatus? after;
  final List<PatchbayPermissionEvidence> evidence;
  final PatchbayPermissionInterruption? interruption;
  final String? notice;

  bool get accepted => admission == 'accepted';

  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'requestId': requestId,
    'admission': admission,
    if (code != null)
      'rejection': <String, Object?>{'code': code, 'details': details},
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
    if (before != null) 'before': before!.toJson(),
    if (after != null) 'after': after!.toJson(),
    'evidence': <Map<String, Object?>>[
      for (final PatchbayPermissionEvidence item in evidence) item.toJson(),
    ],
    if (interruption != null) 'interruption': interruption!.toJson(),
    if (notice != null) 'notice': notice,
  };
}

final class PatchbayPermissionWireException implements Exception {
  const PatchbayPermissionWireException(this.code);

  final String code;

  @override
  String toString() => 'PatchbayPermissionWireException($code)';
}

int patchbayPermissionProtocolMajorOf(String version) {
  final String first = version.split('.').first;
  final int? major = int.tryParse(first);
  if (major == null || major < 0) {
    throw const PatchbayPermissionWireException(
      'platformDriverVersionMismatch',
    );
  }
  return major;
}

T _requiredEnum<T extends Enum>(Object? value, List<T> values, String code) {
  for (final T candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw PatchbayPermissionWireException(code);
}

Set<T> _enumSet<T extends Enum>(Object? value, List<T> values, String code) {
  if (value is! List<Object?>) throw PatchbayPermissionWireException(code);
  return Set<T>.unmodifiable(<T>{
    for (final Object? item in value) _requiredEnum(item, values, code),
  });
}

List<String> _sortedNames(Iterable<Enum> values) =>
    values.map((Enum value) => value.name).toList(growable: false)..sort();

String _requiredString(Object? value, String code) {
  if (value is! String || value.isEmpty) {
    throw PatchbayPermissionWireException(code);
  }
  return value;
}

String? _optionalString(Object? value, String code) {
  if (value == null) return null;
  return _requiredString(value, code);
}

bool _requiredBool(Object? value, String code) {
  if (value is! bool) throw PatchbayPermissionWireException(code);
  return value;
}

Map<Object?, Object?>? _optionalMap(Object? value) {
  if (value == null) return null;
  if (value is! Map<Object?, Object?>) {
    throw const PatchbayPermissionWireException(
      'permissionDriverResponseInvalid',
    );
  }
  return value;
}
