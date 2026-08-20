// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, prefer_null_aware_operators, unused_element, use_null_aware_elements
// Contract: packages/patchbay/contracts/core_wire.json
// Generator: packages/patchbay/tool/wire_codegen.dart
// Library: patchbay_core_wire

/// Strict wire representation of `PatchbayCommandModeWire`.
enum PatchbayCommandModeWire {
  /// The `readOnly` wire value.
  readOnly,

  /// The `immediate` wire value.
  immediate,

  /// The `job` wire value.
  job;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayCommandModeWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayCommandModeWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayParameterTypeWire`.
enum PatchbayParameterTypeWire {
  /// The `string` wire value.
  string,

  /// The `integer` wire value.
  integer,

  /// The `number` wire value.
  number,

  /// The `boolean` wire value.
  boolean,

  /// The `enumeration` wire value.
  enumeration,

  /// The `json` wire value.
  json;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayParameterTypeWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayParameterTypeWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayPlaneWire`.
enum PatchbayPlaneWire {
  /// The `domain` wire value.
  domain,

  /// The `flutterUi` wire value.
  flutterUi;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayPlaneWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayPlaneWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbaySideEffectWire`.
enum PatchbaySideEffectWire {
  /// The `none` wire value.
  none,

  /// The `appState` wire value.
  appState,

  /// The `external` wire value.
  external;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbaySideEffectWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbaySideEffectWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayFactSourceWire`.
enum PatchbayFactSourceWire {
  /// The `appRecorded` wire value.
  appRecorded,

  /// The `commandEcho` wire value.
  commandEcho,

  /// The `deviceReported` wire value.
  deviceReported,

  /// The `uiObserved` wire value.
  uiObserved,

  /// The `unknown` wire value.
  unknown;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayFactSourceWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayFactSourceWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayAdmissionWire`.
enum PatchbayAdmissionWire {
  /// The `accepted` wire value.
  accepted,

  /// The `rejected` wire value.
  rejected;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayAdmissionWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayAdmissionWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayJobPhaseWire`.
enum PatchbayJobPhaseWire {
  /// The `running` wire value.
  running,

  /// The `completed` wire value.
  completed,

  /// The `failed` wire value.
  failed,

  /// The `cancelled` wire value.
  cancelled;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayJobPhaseWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayJobPhaseWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayJobWaitOutcomeWire`.
enum PatchbayJobWaitOutcomeWire {
  /// The `changed` wire value.
  changed,

  /// The `timedOut` wire value.
  timedOut;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayJobWaitOutcomeWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayJobWaitOutcomeWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayUiTargetKindWire`.
enum PatchbayUiTargetKindWire {
  /// The `text` wire value.
  text,

  /// The `capture` wire value.
  capture;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayUiTargetKindWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayUiTargetKindWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbaySensitivePolicyWire`.
enum PatchbaySensitivePolicyWire {
  /// The `public` wire value.
  public,

  /// The `redacted` wire value.
  redacted;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbaySensitivePolicyWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbaySensitivePolicyWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayNavigationOperationWire`.
enum PatchbayNavigationOperationWire {
  /// The `go` wire value.
  go,

  /// The `push` wire value.
  push,

  /// The `back` wire value.
  back;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayNavigationOperationWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayNavigationOperationWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayUiWaitConditionWire`.
enum PatchbayUiWaitConditionWire {
  /// The `semanticsMounted` wire value.
  semanticsMounted,

  /// The `semanticsUnmounted` wire value.
  semanticsUnmounted,

  /// The `semanticsValue` wire value.
  semanticsValue,

  /// The `navigationDestination` wire value.
  navigationDestination,

  /// The `treeRevision` wire value.
  treeRevision,

  /// The `frameRevision` wire value.
  frameRevision;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayUiWaitConditionWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayUiWaitConditionWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayLogLevelWire`.
enum PatchbayLogLevelWire {
  /// The `trace` wire value.
  trace,

  /// The `debug` wire value.
  debug,

  /// The `info` wire value.
  info,

  /// The `warning` wire value.
  warning,

  /// The `error` wire value.
  error,

  /// The `fatal` wire value.
  fatal;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayLogLevelWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayLogLevelWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayLogDirectionWire`.
enum PatchbayLogDirectionWire {
  /// The `forward` wire value.
  forward,

  /// The `backward` wire value.
  backward;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayLogDirectionWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayLogDirectionWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayLogBatchOutcomeWire`.
enum PatchbayLogBatchOutcomeWire {
  /// The `records` wire value.
  records,

  /// The `staleCursor` wire value.
  staleCursor,

  /// The `timedOut` wire value.
  timedOut,

  /// The `cancelled` wire value.
  cancelled;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayLogBatchOutcomeWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayLogBatchOutcomeWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayLogTruncationWire`.
enum PatchbayLogTruncationWire {
  /// The `entryLimit` wire value.
  entryLimit,

  /// The `byteLimit` wire value.
  byteLimit,

  /// The `sourceLimit` wire value.
  sourceLimit;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayLogTruncationWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayLogTruncationWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayLogRedactionWire`.
enum PatchbayLogRedactionWire {
  /// The `consumerRedacted` wire value.
  consumerRedacted;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayLogRedactionWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayLogRedactionWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayBlobSourceWire`.
enum PatchbayBlobSourceWire {
  /// The `logExport` wire value.
  logExport,

  /// The `flutterCapture` wire value.
  flutterCapture;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayBlobSourceWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayBlobSourceWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayCaptureTargetWire`.
enum PatchbayCaptureTargetWire {
  /// The `root` wire value.
  root,

  /// The `registeredTarget` wire value.
  registeredTarget;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayCaptureTargetWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayCaptureTargetWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayCaptureWarningWire`.
enum PatchbayCaptureWarningWire {
  /// The `flutterSubtreeOnly` wire value.
  flutterSubtreeOnly,

  /// The `platformViewsMayBeMissing` wire value.
  platformViewsMayBeMissing,

  /// The `systemUiNotIncluded` wire value.
  systemUiNotIncluded;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayCaptureWarningWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayCaptureWarningWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayKeepAwakeReleaseWire`.
enum PatchbayKeepAwakeReleaseWire {
  /// The `operatorRequest` wire value.
  operatorRequest,

  /// The `leaseExpired` wire value.
  leaseExpired,

  /// The `hostDisposed` wire value.
  hostDisposed;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayKeepAwakeReleaseWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayKeepAwakeReleaseWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbaySnapshotConditionWire`.
enum PatchbaySnapshotConditionWire {
  /// The `exists` wire value.
  exists,

  /// The `absent` wire value.
  absent,

  /// The `equals` wire value.
  equals;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbaySnapshotConditionWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbaySnapshotConditionWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbaySnapshotMissWire`.
enum PatchbaySnapshotMissWire {
  /// The `missingKey` wire value.
  missingKey,

  /// The `nullValue` wire value.
  nullValue,

  /// The `notAnObject` wire value.
  notAnObject;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbaySnapshotMissWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbaySnapshotMissWire: $wire');
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayParameterDescriptorWire`.
final class PatchbayParameterDescriptorWire {
  /// Creates a fully validated wire value.
  const PatchbayParameterDescriptorWire({
    required this.name,
    required this.type,
    required this.required,
    required this.sensitive,
    required this.defaultValue,
    required this.allowedValues,
    required this.summary,
  });

  /// Value of the `name` wire field.
  final String name;

  /// Value of the `type` wire field.
  final PatchbayParameterTypeWire type;

  /// Value of the `required` wire field.
  final bool required;

  /// Value of the `sensitive` wire field.
  final bool sensitive;

  /// Value of the `default` wire field.
  final Object? defaultValue;

  /// Value of the `allowedValues` wire field.
  final List<Object?> allowedValues;

  /// Value of the `summary` wire field.
  final String? summary;

  /// Decodes a strict JSON object at [path].
  factory PatchbayParameterDescriptorWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'name',
      'type',
      'required',
      'sensitive',
      'default',
      'allowedValues',
      'summary',
    }, path);
    return PatchbayParameterDescriptorWire(
      name: _wireString(json['name'], '$path.name'),
      type: PatchbayParameterTypeWire.fromJson(
        json['type'],
        path: '$path.type',
      ),
      required: _wireBool(json['required'], '$path.required'),
      sensitive: _wireBool(json['sensitive'], '$path.sensitive'),
      defaultValue: json['default'] == null
          ? null
          : _wireJson(json['default'], '$path.default'),
      allowedValues: json['allowedValues'] == null
          ? const <Object?>[]
          : _wireList(json['allowedValues'], '$path.allowedValues')
                .map((item) => _wireJson(item, '$path.allowedValues[]'))
                .toList(growable: false),
      summary: json['summary'] == null
          ? null
          : _wireString(json['summary'], '$path.summary'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type.toJson(),
    'required': required,
    'sensitive': sensitive,
    if (defaultValue != null) 'default': _wireJson(defaultValue!, r'$.default'),
    if (allowedValues.isNotEmpty)
      'allowedValues': allowedValues
          .map((item) => _wireJson(item, r'$.allowedValues[]'))
          .toList(growable: false),
    if (summary != null) 'summary': summary!,
  };
}

/// Strict wire representation of `PatchbayIdentityWire`.
final class PatchbayIdentityWire {
  /// Creates a fully validated wire value.
  const PatchbayIdentityWire({
    required this.schemaVersion,
    required this.serverVersion,
    required this.features,
    required this.applicationId,
    required this.appInstanceId,
    required this.isolateId,
  });

  /// Value of the `schemaVersion` wire field.
  final int schemaVersion;

  /// Value of the `serverVersion` wire field.
  final String serverVersion;

  /// Value of the `features` wire field.
  final List<String> features;

  /// Value of the `applicationId` wire field.
  final String applicationId;

  /// Value of the `appInstanceId` wire field.
  final String appInstanceId;

  /// Value of the `isolateId` wire field.
  final String? isolateId;

  /// Decodes a strict JSON object at [path].
  factory PatchbayIdentityWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'schemaVersion',
      'serverVersion',
      'features',
      'applicationId',
      'appInstanceId',
      'isolateId',
    }, path);
    return PatchbayIdentityWire(
      schemaVersion: _wireInt(json['schemaVersion'], '$path.schemaVersion'),
      serverVersion: _wireString(json['serverVersion'], '$path.serverVersion'),
      features: _wireList(json['features'], '$path.features')
          .map((item) => _wireString(item, '$path.features[]'))
          .toList(growable: false),
      applicationId: _wireString(json['applicationId'], '$path.applicationId'),
      appInstanceId: _wireString(json['appInstanceId'], '$path.appInstanceId'),
      isolateId: json['isolateId'] == null
          ? null
          : _wireString(json['isolateId'], '$path.isolateId'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'serverVersion': serverVersion,
    'features': features.map((item) => item).toList(growable: false),
    'applicationId': applicationId,
    'appInstanceId': appInstanceId,
    'isolateId': isolateId == null ? null : isolateId!,
  };
}

/// Strict wire representation of `PatchbayCatalogDigestWire`.
final class PatchbayCatalogDigestWire {
  /// Creates a fully validated wire value.
  const PatchbayCatalogDigestWire({
    required this.algorithm,
    required this.covers,
    required this.value,
  });

  /// Value of the `algorithm` wire field.
  final String algorithm;

  /// Value of the `covers` wire field.
  final List<String> covers;

  /// Value of the `value` wire field.
  final String value;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCatalogDigestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'algorithm', 'covers', 'value'}, path);
    return PatchbayCatalogDigestWire(
      algorithm: _wireString(json['algorithm'], '$path.algorithm'),
      covers: _wireList(json['covers'], '$path.covers')
          .map((item) => _wireString(item, '$path.covers[]'))
          .toList(growable: false),
      value: _wireString(json['value'], '$path.value'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'algorithm': algorithm,
    'covers': covers.map((item) => item).toList(growable: false),
    'value': value,
  };
}

/// Strict wire representation of `PatchbayCommandDescriptorWire`.
final class PatchbayCommandDescriptorWire {
  /// Creates a fully validated wire value.
  const PatchbayCommandDescriptorWire({
    required this.name,
    required this.summary,
    required this.plane,
    required this.mode,
    required this.sideEffect,
    required this.factSources,
    required this.gates,
    required this.parameters,
  });

  /// Value of the `name` wire field.
  final String name;

  /// Value of the `summary` wire field.
  final String summary;

  /// Value of the `plane` wire field.
  final PatchbayPlaneWire plane;

  /// Value of the `mode` wire field.
  final PatchbayCommandModeWire mode;

  /// Value of the `sideEffect` wire field.
  final PatchbaySideEffectWire sideEffect;

  /// Value of the `factSources` wire field.
  final List<PatchbayFactSourceWire> factSources;

  /// Value of the `gates` wire field.
  final List<String> gates;

  /// Value of the `parameters` wire field.
  final List<PatchbayParameterDescriptorWire> parameters;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCommandDescriptorWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'name',
      'summary',
      'plane',
      'mode',
      'sideEffect',
      'factSources',
      'gates',
      'parameters',
    }, path);
    return PatchbayCommandDescriptorWire(
      name: _wireString(json['name'], '$path.name'),
      summary: _wireString(json['summary'], '$path.summary'),
      plane: PatchbayPlaneWire.fromJson(json['plane'], path: '$path.plane'),
      mode: PatchbayCommandModeWire.fromJson(json['mode'], path: '$path.mode'),
      sideEffect: PatchbaySideEffectWire.fromJson(
        json['sideEffect'],
        path: '$path.sideEffect',
      ),
      factSources: _wireList(json['factSources'], '$path.factSources')
          .map(
            (item) => PatchbayFactSourceWire.fromJson(
              item,
              path: '$path.factSources[]',
            ),
          )
          .toList(growable: false),
      gates: _wireList(json['gates'], '$path.gates')
          .map((item) => _wireString(item, '$path.gates[]'))
          .toList(growable: false),
      parameters: _wireList(json['parameters'], '$path.parameters')
          .map(
            (item) => PatchbayParameterDescriptorWire.fromJson(
              _wireMap(item, '$path.parameters[]'),
              path: '$path.parameters[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'summary': summary,
    'plane': plane.toJson(),
    'mode': mode.toJson(),
    'sideEffect': sideEffect.toJson(),
    'factSources': factSources
        .map((item) => item.toJson())
        .toList(growable: false),
    'gates': gates.map((item) => item).toList(growable: false),
    'parameters': parameters
        .map((item) => item.toJson())
        .toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayRejectionWire`.
final class PatchbayRejectionWire {
  /// Creates a fully validated wire value.
  const PatchbayRejectionWire({
    required this.code,
    required this.notice,
    required this.details,
  });

  /// Value of the `code` wire field.
  final String code;

  /// Value of the `notice` wire field.
  final String? notice;

  /// Value of the `details` wire field.
  final Map<String, Object?> details;

  /// Decodes a strict JSON object at [path].
  factory PatchbayRejectionWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'code', 'notice', 'details'}, path);
    return PatchbayRejectionWire(
      code: _wireString(json['code'], '$path.code'),
      notice: json['notice'] == null
          ? null
          : _wireString(json['notice'], '$path.notice'),
      details: json['details'] == null
          ? const <String, Object?>{}
          : _wireJsonObject(json['details'], '$path.details'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    if (notice != null) 'notice': notice!,
    if (details.isNotEmpty) 'details': _wireJsonObject(details, r'$.details'),
  };
}

/// Strict wire representation of `PatchbayInvocationWire`.
final class PatchbayInvocationWire {
  /// Creates a fully validated wire value.
  const PatchbayInvocationWire({
    required this.schemaVersion,
    required this.requestId,
    required this.admission,
    required this.payload,
    required this.notice,
    required this.jobId,
    required this.rejection,
  });

  /// Value of the `schemaVersion` wire field.
  final int schemaVersion;

  /// Value of the `requestId` wire field.
  final String requestId;

  /// Value of the `admission` wire field.
  final PatchbayAdmissionWire admission;

  /// Value of the `payload` wire field.
  final Map<String, Object?> payload;

  /// Value of the `notice` wire field.
  final String? notice;

  /// Value of the `jobId` wire field.
  final String? jobId;

  /// Value of the `rejection` wire field.
  final PatchbayRejectionWire? rejection;

  /// Decodes a strict JSON object at [path].
  factory PatchbayInvocationWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'schemaVersion',
      'requestId',
      'admission',
      'payload',
      'notice',
      'jobId',
      'rejection',
    }, path);
    return PatchbayInvocationWire(
      schemaVersion: _wireInt(json['schemaVersion'], '$path.schemaVersion'),
      requestId: _wireString(json['requestId'], '$path.requestId'),
      admission: PatchbayAdmissionWire.fromJson(
        json['admission'],
        path: '$path.admission',
      ),
      payload: _wireJsonObject(json['payload'], '$path.payload'),
      notice: json['notice'] == null
          ? null
          : _wireString(json['notice'], '$path.notice'),
      jobId: json['jobId'] == null
          ? null
          : _wireString(json['jobId'], '$path.jobId'),
      rejection: json['rejection'] == null
          ? null
          : PatchbayRejectionWire.fromJson(
              _wireMap(json['rejection'], '$path.rejection'),
              path: '$path.rejection',
            ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'requestId': requestId,
    'admission': admission.toJson(),
    'payload': _wireJsonObject(payload, r'$.payload'),
    'notice': notice == null ? null : notice!,
    'jobId': jobId == null ? null : jobId!,
    'rejection': rejection == null ? null : rejection!.toJson(),
  };
}

/// Strict wire representation of `PatchbayJobEventWire`.
final class PatchbayJobEventWire {
  /// Creates a fully validated wire value.
  const PatchbayJobEventWire({
    required this.sequence,
    required this.at,
    required this.phase,
    required this.source,
    required this.operation,
    required this.payload,
    required this.reason,
  });

  /// Value of the `sequence` wire field.
  final int sequence;

  /// Value of the `at` wire field.
  final String at;

  /// Value of the `phase` wire field.
  final PatchbayJobPhaseWire phase;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `operation` wire field.
  final String? operation;

  /// Value of the `payload` wire field.
  final Map<String, Object?> payload;

  /// Value of the `reason` wire field.
  final String? reason;

  /// Decodes a strict JSON object at [path].
  factory PatchbayJobEventWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'sequence',
      'at',
      'phase',
      'source',
      'operation',
      'payload',
      'reason',
    }, path);
    return PatchbayJobEventWire(
      sequence: _wireInt(json['sequence'], '$path.sequence'),
      at: _wireString(json['at'], '$path.at'),
      phase: PatchbayJobPhaseWire.fromJson(json['phase'], path: '$path.phase'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      operation: json['operation'] == null
          ? null
          : _wireString(json['operation'], '$path.operation'),
      payload: _wireJsonObject(json['payload'], '$path.payload'),
      reason: json['reason'] == null
          ? null
          : _wireString(json['reason'], '$path.reason'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'sequence': sequence,
    'at': at,
    'phase': phase.toJson(),
    'source': source.toJson(),
    if (operation != null) 'operation': operation!,
    'payload': _wireJsonObject(payload, r'$.payload'),
    if (reason != null) 'reason': reason!,
  };
}

/// Strict wire representation of `PatchbayJobSnapshotWire`.
final class PatchbayJobSnapshotWire {
  /// Creates a fully validated wire value.
  const PatchbayJobSnapshotWire({
    required this.jobId,
    required this.terminal,
    required this.events,
  });

  /// Value of the `jobId` wire field.
  final String jobId;

  /// Value of the `terminal` wire field.
  final bool terminal;

  /// Value of the `events` wire field.
  final List<PatchbayJobEventWire> events;

  /// Decodes a strict JSON object at [path].
  factory PatchbayJobSnapshotWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'jobId', 'terminal', 'events'}, path);
    return PatchbayJobSnapshotWire(
      jobId: _wireString(json['jobId'], '$path.jobId'),
      terminal: _wireBool(json['terminal'], '$path.terminal'),
      events: _wireList(json['events'], '$path.events')
          .map(
            (item) => PatchbayJobEventWire.fromJson(
              _wireMap(item, '$path.events[]'),
              path: '$path.events[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'jobId': jobId,
    'terminal': terminal,
    'events': events.map((item) => item.toJson()).toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayJobWaitResultWire`.
final class PatchbayJobWaitResultWire {
  /// Creates a fully validated wire value.
  const PatchbayJobWaitResultWire({
    required this.outcome,
    required this.snapshot,
  });

  /// Value of the `outcome` wire field.
  final PatchbayJobWaitOutcomeWire outcome;

  /// Value of the `snapshot` wire field.
  final PatchbayJobSnapshotWire snapshot;

  /// Decodes a strict JSON object at [path].
  factory PatchbayJobWaitResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'outcome', 'snapshot'}, path);
    return PatchbayJobWaitResultWire(
      outcome: PatchbayJobWaitOutcomeWire.fromJson(
        json['outcome'],
        path: '$path.outcome',
      ),
      snapshot: PatchbayJobSnapshotWire.fromJson(
        _wireMap(json['snapshot'], '$path.snapshot'),
        path: '$path.snapshot',
      ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome.toJson(),
    'snapshot': snapshot.toJson(),
  };
}

/// Strict wire representation of `PatchbayUiTargetDescriptorWire`.
final class PatchbayUiTargetDescriptorWire {
  /// Creates a fully validated wire value.
  const PatchbayUiTargetDescriptorWire({
    required this.id,
    required this.generation,
    required this.kind,
    required this.mounted,
    required this.ambiguous,
    required this.operations,
    required this.operationGates,
    required this.sensitivePolicy,
    required this.sideEffect,
    required this.factSources,
  });

  /// Value of the `id` wire field.
  final String id;

  /// Value of the `generation` wire field.
  final int generation;

  /// Value of the `kind` wire field.
  final PatchbayUiTargetKindWire kind;

  /// Value of the `mounted` wire field.
  final bool mounted;

  /// Value of the `ambiguous` wire field.
  final bool ambiguous;

  /// Value of the `operations` wire field.
  final List<String> operations;

  /// Value of the `operationGates` wire field.
  final Map<String, Object?> operationGates;

  /// Value of the `sensitivePolicy` wire field.
  final PatchbaySensitivePolicyWire sensitivePolicy;

  /// Value of the `sideEffect` wire field.
  final PatchbaySideEffectWire sideEffect;

  /// Value of the `factSources` wire field.
  final List<PatchbayFactSourceWire> factSources;

  /// Decodes a strict JSON object at [path].
  factory PatchbayUiTargetDescriptorWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'id',
      'generation',
      'kind',
      'mounted',
      'ambiguous',
      'operations',
      'operationGates',
      'sensitivePolicy',
      'sideEffect',
      'factSources',
    }, path);
    return PatchbayUiTargetDescriptorWire(
      id: _wireString(json['id'], '$path.id'),
      generation: _wireInt(json['generation'], '$path.generation'),
      kind: PatchbayUiTargetKindWire.fromJson(json['kind'], path: '$path.kind'),
      mounted: _wireBool(json['mounted'], '$path.mounted'),
      ambiguous: _wireBool(json['ambiguous'], '$path.ambiguous'),
      operations: _wireList(json['operations'], '$path.operations')
          .map((item) => _wireString(item, '$path.operations[]'))
          .toList(growable: false),
      operationGates: _wireJsonObject(
        json['operationGates'],
        '$path.operationGates',
      ),
      sensitivePolicy: PatchbaySensitivePolicyWire.fromJson(
        json['sensitivePolicy'],
        path: '$path.sensitivePolicy',
      ),
      sideEffect: PatchbaySideEffectWire.fromJson(
        json['sideEffect'],
        path: '$path.sideEffect',
      ),
      factSources: _wireList(json['factSources'], '$path.factSources')
          .map(
            (item) => PatchbayFactSourceWire.fromJson(
              item,
              path: '$path.factSources[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'generation': generation,
    'kind': kind.toJson(),
    'mounted': mounted,
    'ambiguous': ambiguous,
    'operations': operations.map((item) => item).toList(growable: false),
    'operationGates': _wireJsonObject(operationGates, r'$.operationGates'),
    'sensitivePolicy': sensitivePolicy.toJson(),
    'sideEffect': sideEffect.toJson(),
    'factSources': factSources
        .map((item) => item.toJson())
        .toList(growable: false),
  };
}

/// Strict wire representation of `PatchbaySemanticsRectWire`.
final class PatchbaySemanticsRectWire {
  /// Creates a fully validated wire value.
  const PatchbaySemanticsRectWire({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// Value of the `left` wire field.
  final num left;

  /// Value of the `top` wire field.
  final num top;

  /// Value of the `width` wire field.
  final num width;

  /// Value of the `height` wire field.
  final num height;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySemanticsRectWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'left', 'top', 'width', 'height'}, path);
    return PatchbaySemanticsRectWire(
      left: _wireNum(json['left'], '$path.left'),
      top: _wireNum(json['top'], '$path.top'),
      width: _wireNum(json['width'], '$path.width'),
      height: _wireNum(json['height'], '$path.height'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };
}

/// Strict wire representation of `PatchbaySemanticsNodeWire`.
final class PatchbaySemanticsNodeWire {
  /// Creates a fully validated wire value.
  const PatchbaySemanticsNodeWire({
    required this.nodeId,
    required this.generation,
    required this.parentNodeId,
    required this.depth,
    required this.identifier,
    required this.label,
    required this.value,
    required this.valueRedacted,
    required this.hint,
    required this.tooltip,
    required this.flags,
    required this.actions,
    required this.invisible,
    required this.userActionsBlocked,
    required this.rect,
    required this.rectCoordinateSpace,
    required this.transformToParent,
    required this.scrollPosition,
    required this.scrollExtentMin,
    required this.scrollExtentMax,
    required this.platformViewId,
    required this.children,
  });

  /// Value of the `nodeId` wire field.
  final int nodeId;

  /// Value of the `generation` wire field.
  final int generation;

  /// Value of the `parentNodeId` wire field.
  final int? parentNodeId;

  /// Value of the `depth` wire field.
  final int depth;

  /// Value of the `identifier` wire field.
  final String identifier;

  /// Value of the `label` wire field.
  final String label;

  /// Value of the `value` wire field.
  final String? value;

  /// Value of the `valueRedacted` wire field.
  final bool? valueRedacted;

  /// Value of the `hint` wire field.
  final String? hint;

  /// Value of the `tooltip` wire field.
  final String? tooltip;

  /// Value of the `flags` wire field.
  final List<String> flags;

  /// Value of the `actions` wire field.
  final List<String> actions;

  /// Value of the `invisible` wire field.
  final bool invisible;

  /// Value of the `userActionsBlocked` wire field.
  final bool userActionsBlocked;

  /// Value of the `rect` wire field.
  final PatchbaySemanticsRectWire rect;

  /// Value of the `rectCoordinateSpace` wire field.
  final String rectCoordinateSpace;

  /// Value of the `transformToParent` wire field.
  final List<num>? transformToParent;

  /// Value of the `scrollPosition` wire field.
  final num? scrollPosition;

  /// Value of the `scrollExtentMin` wire field.
  final num? scrollExtentMin;

  /// Value of the `scrollExtentMax` wire field.
  final num? scrollExtentMax;

  /// Value of the `platformViewId` wire field.
  final int? platformViewId;

  /// Value of the `children` wire field.
  final List<int> children;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySemanticsNodeWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'nodeId',
      'generation',
      'parentNodeId',
      'depth',
      'identifier',
      'label',
      'value',
      'valueRedacted',
      'hint',
      'tooltip',
      'flags',
      'actions',
      'invisible',
      'userActionsBlocked',
      'rect',
      'rectCoordinateSpace',
      'transformToParent',
      'scrollPosition',
      'scrollExtentMin',
      'scrollExtentMax',
      'platformViewId',
      'children',
    }, path);
    return PatchbaySemanticsNodeWire(
      nodeId: _wireInt(json['nodeId'], '$path.nodeId'),
      generation: _wireInt(json['generation'], '$path.generation'),
      parentNodeId: json['parentNodeId'] == null
          ? null
          : _wireInt(json['parentNodeId'], '$path.parentNodeId'),
      depth: _wireInt(json['depth'], '$path.depth'),
      identifier: _wireString(json['identifier'], '$path.identifier'),
      label: _wireString(json['label'], '$path.label'),
      value: json['value'] == null
          ? null
          : _wireString(json['value'], '$path.value'),
      valueRedacted: json['valueRedacted'] == null
          ? null
          : _wireBool(json['valueRedacted'], '$path.valueRedacted'),
      hint: json['hint'] == null
          ? null
          : _wireString(json['hint'], '$path.hint'),
      tooltip: json['tooltip'] == null
          ? null
          : _wireString(json['tooltip'], '$path.tooltip'),
      flags: _wireList(json['flags'], '$path.flags')
          .map((item) => _wireString(item, '$path.flags[]'))
          .toList(growable: false),
      actions: _wireList(json['actions'], '$path.actions')
          .map((item) => _wireString(item, '$path.actions[]'))
          .toList(growable: false),
      invisible: _wireBool(json['invisible'], '$path.invisible'),
      userActionsBlocked: _wireBool(
        json['userActionsBlocked'],
        '$path.userActionsBlocked',
      ),
      rect: PatchbaySemanticsRectWire.fromJson(
        _wireMap(json['rect'], '$path.rect'),
        path: '$path.rect',
      ),
      rectCoordinateSpace: _wireString(
        json['rectCoordinateSpace'],
        '$path.rectCoordinateSpace',
      ),
      transformToParent: json['transformToParent'] == null
          ? null
          : _wireList(json['transformToParent'], '$path.transformToParent')
                .map((item) => _wireNum(item, '$path.transformToParent[]'))
                .toList(growable: false),
      scrollPosition: json['scrollPosition'] == null
          ? null
          : _wireNum(json['scrollPosition'], '$path.scrollPosition'),
      scrollExtentMin: json['scrollExtentMin'] == null
          ? null
          : _wireNum(json['scrollExtentMin'], '$path.scrollExtentMin'),
      scrollExtentMax: json['scrollExtentMax'] == null
          ? null
          : _wireNum(json['scrollExtentMax'], '$path.scrollExtentMax'),
      platformViewId: json['platformViewId'] == null
          ? null
          : _wireInt(json['platformViewId'], '$path.platformViewId'),
      children: _wireList(json['children'], '$path.children')
          .map((item) => _wireInt(item, '$path.children[]'))
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'nodeId': nodeId,
    'generation': generation,
    'parentNodeId': parentNodeId == null ? null : parentNodeId!,
    'depth': depth,
    'identifier': identifier,
    'label': label,
    if (value != null) 'value': value!,
    if (valueRedacted != null) 'valueRedacted': valueRedacted!,
    if (hint != null) 'hint': hint!,
    if (tooltip != null) 'tooltip': tooltip!,
    'flags': flags.map((item) => item).toList(growable: false),
    'actions': actions.map((item) => item).toList(growable: false),
    'invisible': invisible,
    'userActionsBlocked': userActionsBlocked,
    'rect': rect.toJson(),
    'rectCoordinateSpace': rectCoordinateSpace,
    if (transformToParent != null)
      'transformToParent': transformToParent!
          .map((item) => item)
          .toList(growable: false),
    if (scrollPosition != null) 'scrollPosition': scrollPosition!,
    if (scrollExtentMin != null) 'scrollExtentMin': scrollExtentMin!,
    if (scrollExtentMax != null) 'scrollExtentMax': scrollExtentMax!,
    if (platformViewId != null) 'platformViewId': platformViewId!,
    'children': children.map((item) => item).toList(growable: false),
  };
}

/// Strict wire representation of `PatchbaySemanticsSnapshotWire`.
final class PatchbaySemanticsSnapshotWire {
  /// Creates a fully validated wire value.
  const PatchbaySemanticsSnapshotWire({
    required this.outcome,
    required this.source,
    required this.treeRevision,
    required this.rootNodeId,
    required this.truncated,
    required this.nodeCount,
    required this.nodes,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `treeRevision` wire field.
  final int treeRevision;

  /// Value of the `rootNodeId` wire field.
  final int rootNodeId;

  /// Value of the `truncated` wire field.
  final bool truncated;

  /// Value of the `nodeCount` wire field.
  final int nodeCount;

  /// Value of the `nodes` wire field.
  final List<PatchbaySemanticsNodeWire> nodes;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySemanticsSnapshotWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'treeRevision',
      'rootNodeId',
      'truncated',
      'nodeCount',
      'nodes',
    }, path);
    return PatchbaySemanticsSnapshotWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      treeRevision: _wireInt(json['treeRevision'], '$path.treeRevision'),
      rootNodeId: _wireInt(json['rootNodeId'], '$path.rootNodeId'),
      truncated: _wireBool(json['truncated'], '$path.truncated'),
      nodeCount: _wireInt(json['nodeCount'], '$path.nodeCount'),
      nodes: _wireList(json['nodes'], '$path.nodes')
          .map(
            (item) => PatchbaySemanticsNodeWire.fromJson(
              _wireMap(item, '$path.nodes[]'),
              path: '$path.nodes[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'treeRevision': treeRevision,
    'rootNodeId': rootNodeId,
    'truncated': truncated,
    'nodeCount': nodeCount,
    'nodes': nodes.map((item) => item.toJson()).toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayDestinationDescriptorWire`.
final class PatchbayDestinationDescriptorWire {
  /// Creates a fully validated wire value.
  const PatchbayDestinationDescriptorWire({
    required this.id,
    required this.summary,
    required this.operations,
    required this.gates,
    required this.ambiguous,
  });

  /// Value of the `id` wire field.
  final String id;

  /// Value of the `summary` wire field.
  final String? summary;

  /// Value of the `operations` wire field.
  final List<PatchbayNavigationOperationWire> operations;

  /// Value of the `gates` wire field.
  final List<String> gates;

  /// Value of the `ambiguous` wire field.
  final bool ambiguous;

  /// Decodes a strict JSON object at [path].
  factory PatchbayDestinationDescriptorWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'id',
      'summary',
      'operations',
      'gates',
      'ambiguous',
    }, path);
    return PatchbayDestinationDescriptorWire(
      id: _wireString(json['id'], '$path.id'),
      summary: json['summary'] == null
          ? null
          : _wireString(json['summary'], '$path.summary'),
      operations: _wireList(json['operations'], '$path.operations')
          .map(
            (item) => PatchbayNavigationOperationWire.fromJson(
              item,
              path: '$path.operations[]',
            ),
          )
          .toList(growable: false),
      gates: _wireList(json['gates'], '$path.gates')
          .map((item) => _wireString(item, '$path.gates[]'))
          .toList(growable: false),
      ambiguous: _wireBool(json['ambiguous'], '$path.ambiguous'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (summary != null) 'summary': summary!,
    'operations': operations
        .map((item) => item.toJson())
        .toList(growable: false),
    'gates': gates.map((item) => item).toList(growable: false),
    'ambiguous': ambiguous,
  };
}

/// Strict wire representation of `PatchbayNavigationCatalogWire`.
final class PatchbayNavigationCatalogWire {
  /// Creates a fully validated wire value.
  const PatchbayNavigationCatalogWire({
    required this.outcome,
    required this.source,
    required this.navigationRevision,
    required this.destinations,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `navigationRevision` wire field.
  final int navigationRevision;

  /// Value of the `destinations` wire field.
  final List<PatchbayDestinationDescriptorWire> destinations;

  /// Decodes a strict JSON object at [path].
  factory PatchbayNavigationCatalogWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'navigationRevision',
      'destinations',
    }, path);
    return PatchbayNavigationCatalogWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      navigationRevision: _wireInt(
        json['navigationRevision'],
        '$path.navigationRevision',
      ),
      destinations: _wireList(json['destinations'], '$path.destinations')
          .map(
            (item) => PatchbayDestinationDescriptorWire.fromJson(
              _wireMap(item, '$path.destinations[]'),
              path: '$path.destinations[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'navigationRevision': navigationRevision,
    'destinations': destinations
        .map((item) => item.toJson())
        .toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayNavigationCurrentWire`.
final class PatchbayNavigationCurrentWire {
  /// Creates a fully validated wire value.
  const PatchbayNavigationCurrentWire({
    required this.outcome,
    required this.source,
    required this.navigationRevision,
    required this.destinationId,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `navigationRevision` wire field.
  final int navigationRevision;

  /// Value of the `destinationId` wire field.
  final String? destinationId;

  /// Decodes a strict JSON object at [path].
  factory PatchbayNavigationCurrentWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'navigationRevision',
      'destinationId',
    }, path);
    return PatchbayNavigationCurrentWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      navigationRevision: _wireInt(
        json['navigationRevision'],
        '$path.navigationRevision',
      ),
      destinationId: json['destinationId'] == null
          ? null
          : _wireString(json['destinationId'], '$path.destinationId'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'navigationRevision': navigationRevision,
    'destinationId': destinationId == null ? null : destinationId!,
  };
}

/// Strict wire representation of `PatchbayNavigationResultWire`.
final class PatchbayNavigationResultWire {
  /// Creates a fully validated wire value.
  const PatchbayNavigationResultWire({
    required this.outcome,
    required this.source,
    required this.operation,
    required this.requestedDestinationId,
    required this.destinationId,
    required this.beforeNavigationRevision,
    required this.afterNavigationRevision,
    required this.frameRevision,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `operation` wire field.
  final PatchbayNavigationOperationWire operation;

  /// Value of the `requestedDestinationId` wire field.
  final String? requestedDestinationId;

  /// Value of the `destinationId` wire field.
  final String destinationId;

  /// Value of the `beforeNavigationRevision` wire field.
  final int beforeNavigationRevision;

  /// Value of the `afterNavigationRevision` wire field.
  final int afterNavigationRevision;

  /// Value of the `frameRevision` wire field.
  final int frameRevision;

  /// Decodes a strict JSON object at [path].
  factory PatchbayNavigationResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'operation',
      'requestedDestinationId',
      'destinationId',
      'beforeNavigationRevision',
      'afterNavigationRevision',
      'frameRevision',
    }, path);
    return PatchbayNavigationResultWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      operation: PatchbayNavigationOperationWire.fromJson(
        json['operation'],
        path: '$path.operation',
      ),
      requestedDestinationId: json['requestedDestinationId'] == null
          ? null
          : _wireString(
              json['requestedDestinationId'],
              '$path.requestedDestinationId',
            ),
      destinationId: _wireString(json['destinationId'], '$path.destinationId'),
      beforeNavigationRevision: _wireInt(
        json['beforeNavigationRevision'],
        '$path.beforeNavigationRevision',
      ),
      afterNavigationRevision: _wireInt(
        json['afterNavigationRevision'],
        '$path.afterNavigationRevision',
      ),
      frameRevision: _wireInt(json['frameRevision'], '$path.frameRevision'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'operation': operation.toJson(),
    'requestedDestinationId': requestedDestinationId == null
        ? null
        : requestedDestinationId!,
    'destinationId': destinationId,
    'beforeNavigationRevision': beforeNavigationRevision,
    'afterNavigationRevision': afterNavigationRevision,
    'frameRevision': frameRevision,
  };
}

/// Strict wire representation of `PatchbayUiWaitRequestWire`.
final class PatchbayUiWaitRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayUiWaitRequestWire({
    required this.condition,
    required this.timeoutMs,
    required this.semanticsIdentifier,
    required this.value,
    required this.destinationId,
    required this.revision,
  });

  /// Value of the `condition` wire field.
  final PatchbayUiWaitConditionWire condition;

  /// Value of the `timeoutMs` wire field.
  final int timeoutMs;

  /// Value of the `semanticsIdentifier` wire field.
  final String? semanticsIdentifier;

  /// Value of the `value` wire field.
  final String? value;

  /// Value of the `destinationId` wire field.
  final String? destinationId;

  /// Value of the `revision` wire field.
  final int? revision;

  /// Decodes a strict JSON object at [path].
  factory PatchbayUiWaitRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'condition',
      'timeoutMs',
      'semanticsIdentifier',
      'value',
      'destinationId',
      'revision',
    }, path);
    return PatchbayUiWaitRequestWire(
      condition: PatchbayUiWaitConditionWire.fromJson(
        json['condition'],
        path: '$path.condition',
      ),
      timeoutMs: _wireInt(json['timeoutMs'], '$path.timeoutMs'),
      semanticsIdentifier: json['semanticsIdentifier'] == null
          ? null
          : _wireString(
              json['semanticsIdentifier'],
              '$path.semanticsIdentifier',
            ),
      value: json['value'] == null
          ? null
          : _wireString(json['value'], '$path.value'),
      destinationId: json['destinationId'] == null
          ? null
          : _wireString(json['destinationId'], '$path.destinationId'),
      revision: json['revision'] == null
          ? null
          : _wireInt(json['revision'], '$path.revision'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'condition': condition.toJson(),
    'timeoutMs': timeoutMs,
    if (semanticsIdentifier != null)
      'semanticsIdentifier': semanticsIdentifier!,
    if (value != null) 'value': value!,
    if (destinationId != null) 'destinationId': destinationId!,
    if (revision != null) 'revision': revision!,
  };
}

/// Strict wire representation of `PatchbayUiWaitResultWire`.
final class PatchbayUiWaitResultWire {
  /// Creates a fully validated wire value.
  const PatchbayUiWaitResultWire({
    required this.outcome,
    required this.source,
    required this.condition,
    required this.elapsedMs,
    required this.semanticsIdentifier,
    required this.nodeId,
    required this.generation,
    required this.value,
    required this.destinationId,
    required this.navigationRevision,
    required this.treeRevision,
    required this.frameRevision,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `condition` wire field.
  final PatchbayUiWaitConditionWire condition;

  /// Value of the `elapsedMs` wire field.
  final int elapsedMs;

  /// Value of the `semanticsIdentifier` wire field.
  final String? semanticsIdentifier;

  /// Value of the `nodeId` wire field.
  final int? nodeId;

  /// Value of the `generation` wire field.
  final int? generation;

  /// Value of the `value` wire field.
  final String? value;

  /// Value of the `destinationId` wire field.
  final String? destinationId;

  /// Value of the `navigationRevision` wire field.
  final int? navigationRevision;

  /// Value of the `treeRevision` wire field.
  final int? treeRevision;

  /// Value of the `frameRevision` wire field.
  final int frameRevision;

  /// Decodes a strict JSON object at [path].
  factory PatchbayUiWaitResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'condition',
      'elapsedMs',
      'semanticsIdentifier',
      'nodeId',
      'generation',
      'value',
      'destinationId',
      'navigationRevision',
      'treeRevision',
      'frameRevision',
    }, path);
    return PatchbayUiWaitResultWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      condition: PatchbayUiWaitConditionWire.fromJson(
        json['condition'],
        path: '$path.condition',
      ),
      elapsedMs: _wireInt(json['elapsedMs'], '$path.elapsedMs'),
      semanticsIdentifier: json['semanticsIdentifier'] == null
          ? null
          : _wireString(
              json['semanticsIdentifier'],
              '$path.semanticsIdentifier',
            ),
      nodeId: json['nodeId'] == null
          ? null
          : _wireInt(json['nodeId'], '$path.nodeId'),
      generation: json['generation'] == null
          ? null
          : _wireInt(json['generation'], '$path.generation'),
      value: json['value'] == null
          ? null
          : _wireString(json['value'], '$path.value'),
      destinationId: json['destinationId'] == null
          ? null
          : _wireString(json['destinationId'], '$path.destinationId'),
      navigationRevision: json['navigationRevision'] == null
          ? null
          : _wireInt(json['navigationRevision'], '$path.navigationRevision'),
      treeRevision: json['treeRevision'] == null
          ? null
          : _wireInt(json['treeRevision'], '$path.treeRevision'),
      frameRevision: _wireInt(json['frameRevision'], '$path.frameRevision'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'condition': condition.toJson(),
    'elapsedMs': elapsedMs,
    if (semanticsIdentifier != null)
      'semanticsIdentifier': semanticsIdentifier!,
    if (nodeId != null) 'nodeId': nodeId!,
    if (generation != null) 'generation': generation!,
    if (value != null) 'value': value!,
    if (destinationId != null) 'destinationId': destinationId!,
    if (navigationRevision != null) 'navigationRevision': navigationRevision!,
    if (treeRevision != null) 'treeRevision': treeRevision!,
    'frameRevision': frameRevision,
  };
}

/// Strict wire representation of `PatchbayLogRecordWire`.
final class PatchbayLogRecordWire {
  /// Creates a fully validated wire value.
  const PatchbayLogRecordWire({
    required this.cursor,
    required this.at,
    required this.level,
    required this.category,
    required this.message,
    required this.fields,
    required this.redaction,
    required this.source,
  });

  /// Value of the `cursor` wire field.
  final String cursor;

  /// Value of the `at` wire field.
  final String at;

  /// Value of the `level` wire field.
  final PatchbayLogLevelWire level;

  /// Value of the `category` wire field.
  final String category;

  /// Value of the `message` wire field.
  final String message;

  /// Value of the `fields` wire field.
  final Map<String, Object?> fields;

  /// Value of the `redaction` wire field.
  final PatchbayLogRedactionWire redaction;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogRecordWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'cursor',
      'at',
      'level',
      'category',
      'message',
      'fields',
      'redaction',
      'source',
    }, path);
    return PatchbayLogRecordWire(
      cursor: _wireString(json['cursor'], '$path.cursor'),
      at: _wireString(json['at'], '$path.at'),
      level: PatchbayLogLevelWire.fromJson(json['level'], path: '$path.level'),
      category: _wireString(json['category'], '$path.category'),
      message: _wireString(json['message'], '$path.message'),
      fields: json['fields'] == null
          ? const <String, Object?>{}
          : _wireJsonObject(json['fields'], '$path.fields'),
      redaction: PatchbayLogRedactionWire.fromJson(
        json['redaction'],
        path: '$path.redaction',
      ),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'cursor': cursor,
    'at': at,
    'level': level.toJson(),
    'category': category,
    'message': message,
    if (fields.isNotEmpty) 'fields': _wireJsonObject(fields, r'$.fields'),
    'redaction': redaction.toJson(),
    'source': source.toJson(),
  };
}

/// Strict wire representation of `PatchbayLogQueryRequestWire`.
final class PatchbayLogQueryRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayLogQueryRequestWire({
    required this.cursor,
    required this.direction,
    required this.limit,
    required this.levels,
    required this.categories,
    required this.since,
    required this.until,
  });

  /// Value of the `cursor` wire field.
  final String? cursor;

  /// Value of the `direction` wire field.
  final PatchbayLogDirectionWire? direction;

  /// Value of the `limit` wire field.
  final int? limit;

  /// Value of the `levels` wire field.
  final List<PatchbayLogLevelWire> levels;

  /// Value of the `categories` wire field.
  final List<String> categories;

  /// Value of the `since` wire field.
  final String? since;

  /// Value of the `until` wire field.
  final String? until;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogQueryRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'cursor',
      'direction',
      'limit',
      'levels',
      'categories',
      'since',
      'until',
    }, path);
    return PatchbayLogQueryRequestWire(
      cursor: json['cursor'] == null
          ? null
          : _wireString(json['cursor'], '$path.cursor'),
      direction: json['direction'] == null
          ? null
          : PatchbayLogDirectionWire.fromJson(
              json['direction'],
              path: '$path.direction',
            ),
      limit: json['limit'] == null
          ? null
          : _wireInt(json['limit'], '$path.limit'),
      levels: json['levels'] == null
          ? const <PatchbayLogLevelWire>[]
          : _wireList(json['levels'], '$path.levels')
                .map(
                  (item) => PatchbayLogLevelWire.fromJson(
                    item,
                    path: '$path.levels[]',
                  ),
                )
                .toList(growable: false),
      categories: json['categories'] == null
          ? const <String>[]
          : _wireList(json['categories'], '$path.categories')
                .map((item) => _wireString(item, '$path.categories[]'))
                .toList(growable: false),
      since: json['since'] == null
          ? null
          : _wireString(json['since'], '$path.since'),
      until: json['until'] == null
          ? null
          : _wireString(json['until'], '$path.until'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    if (cursor != null) 'cursor': cursor!,
    if (direction != null) 'direction': direction!.toJson(),
    if (limit != null) 'limit': limit!,
    if (levels.isNotEmpty)
      'levels': levels.map((item) => item.toJson()).toList(growable: false),
    if (categories.isNotEmpty)
      'categories': categories.map((item) => item).toList(growable: false),
    if (since != null) 'since': since!,
    if (until != null) 'until': until!,
  };
}

/// Strict wire representation of `PatchbayLogTailRequestWire`.
final class PatchbayLogTailRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayLogTailRequestWire({
    required this.cursor,
    required this.limit,
    required this.timeoutMs,
    required this.levels,
    required this.categories,
  });

  /// Value of the `cursor` wire field.
  final String? cursor;

  /// Value of the `limit` wire field.
  final int? limit;

  /// Value of the `timeoutMs` wire field.
  final int? timeoutMs;

  /// Value of the `levels` wire field.
  final List<PatchbayLogLevelWire> levels;

  /// Value of the `categories` wire field.
  final List<String> categories;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogTailRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'cursor',
      'limit',
      'timeoutMs',
      'levels',
      'categories',
    }, path);
    return PatchbayLogTailRequestWire(
      cursor: json['cursor'] == null
          ? null
          : _wireString(json['cursor'], '$path.cursor'),
      limit: json['limit'] == null
          ? null
          : _wireInt(json['limit'], '$path.limit'),
      timeoutMs: json['timeoutMs'] == null
          ? null
          : _wireInt(json['timeoutMs'], '$path.timeoutMs'),
      levels: json['levels'] == null
          ? const <PatchbayLogLevelWire>[]
          : _wireList(json['levels'], '$path.levels')
                .map(
                  (item) => PatchbayLogLevelWire.fromJson(
                    item,
                    path: '$path.levels[]',
                  ),
                )
                .toList(growable: false),
      categories: json['categories'] == null
          ? const <String>[]
          : _wireList(json['categories'], '$path.categories')
                .map((item) => _wireString(item, '$path.categories[]'))
                .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    if (cursor != null) 'cursor': cursor!,
    if (limit != null) 'limit': limit!,
    if (timeoutMs != null) 'timeoutMs': timeoutMs!,
    if (levels.isNotEmpty)
      'levels': levels.map((item) => item.toJson()).toList(growable: false),
    if (categories.isNotEmpty)
      'categories': categories.map((item) => item).toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayLogExportRequestWire`.
final class PatchbayLogExportRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayLogExportRequestWire({
    required this.cursor,
    required this.direction,
    required this.limit,
    required this.levels,
    required this.categories,
    required this.since,
    required this.until,
    required this.ttlMs,
  });

  /// Value of the `cursor` wire field.
  final String? cursor;

  /// Value of the `direction` wire field.
  final PatchbayLogDirectionWire? direction;

  /// Value of the `limit` wire field.
  final int? limit;

  /// Value of the `levels` wire field.
  final List<PatchbayLogLevelWire> levels;

  /// Value of the `categories` wire field.
  final List<String> categories;

  /// Value of the `since` wire field.
  final String? since;

  /// Value of the `until` wire field.
  final String? until;

  /// Value of the `ttlMs` wire field.
  final int? ttlMs;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogExportRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'cursor',
      'direction',
      'limit',
      'levels',
      'categories',
      'since',
      'until',
      'ttlMs',
    }, path);
    return PatchbayLogExportRequestWire(
      cursor: json['cursor'] == null
          ? null
          : _wireString(json['cursor'], '$path.cursor'),
      direction: json['direction'] == null
          ? null
          : PatchbayLogDirectionWire.fromJson(
              json['direction'],
              path: '$path.direction',
            ),
      limit: json['limit'] == null
          ? null
          : _wireInt(json['limit'], '$path.limit'),
      levels: json['levels'] == null
          ? const <PatchbayLogLevelWire>[]
          : _wireList(json['levels'], '$path.levels')
                .map(
                  (item) => PatchbayLogLevelWire.fromJson(
                    item,
                    path: '$path.levels[]',
                  ),
                )
                .toList(growable: false),
      categories: json['categories'] == null
          ? const <String>[]
          : _wireList(json['categories'], '$path.categories')
                .map((item) => _wireString(item, '$path.categories[]'))
                .toList(growable: false),
      since: json['since'] == null
          ? null
          : _wireString(json['since'], '$path.since'),
      until: json['until'] == null
          ? null
          : _wireString(json['until'], '$path.until'),
      ttlMs: json['ttlMs'] == null
          ? null
          : _wireInt(json['ttlMs'], '$path.ttlMs'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    if (cursor != null) 'cursor': cursor!,
    if (direction != null) 'direction': direction!.toJson(),
    if (limit != null) 'limit': limit!,
    if (levels.isNotEmpty)
      'levels': levels.map((item) => item.toJson()).toList(growable: false),
    if (categories.isNotEmpty)
      'categories': categories.map((item) => item).toList(growable: false),
    if (since != null) 'since': since!,
    if (until != null) 'until': until!,
    if (ttlMs != null) 'ttlMs': ttlMs!,
  };
}

/// Strict wire representation of `PatchbayLogBatchWire`.
final class PatchbayLogBatchWire {
  /// Creates a fully validated wire value.
  const PatchbayLogBatchWire({
    required this.outcome,
    required this.source,
    required this.records,
    required this.nextCursor,
    required this.currentCursor,
    required this.truncated,
    required this.truncation,
    required this.elapsedMs,
  });

  /// Value of the `outcome` wire field.
  final PatchbayLogBatchOutcomeWire outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `records` wire field.
  final List<PatchbayLogRecordWire> records;

  /// Value of the `nextCursor` wire field.
  final String? nextCursor;

  /// Value of the `currentCursor` wire field.
  final String? currentCursor;

  /// Value of the `truncated` wire field.
  final bool truncated;

  /// Value of the `truncation` wire field.
  final PatchbayLogTruncationWire? truncation;

  /// Value of the `elapsedMs` wire field.
  final int elapsedMs;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogBatchWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'records',
      'nextCursor',
      'currentCursor',
      'truncated',
      'truncation',
      'elapsedMs',
    }, path);
    return PatchbayLogBatchWire(
      outcome: PatchbayLogBatchOutcomeWire.fromJson(
        json['outcome'],
        path: '$path.outcome',
      ),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      records: _wireList(json['records'], '$path.records')
          .map(
            (item) => PatchbayLogRecordWire.fromJson(
              _wireMap(item, '$path.records[]'),
              path: '$path.records[]',
            ),
          )
          .toList(growable: false),
      nextCursor: json['nextCursor'] == null
          ? null
          : _wireString(json['nextCursor'], '$path.nextCursor'),
      currentCursor: json['currentCursor'] == null
          ? null
          : _wireString(json['currentCursor'], '$path.currentCursor'),
      truncated: _wireBool(json['truncated'], '$path.truncated'),
      truncation: json['truncation'] == null
          ? null
          : PatchbayLogTruncationWire.fromJson(
              json['truncation'],
              path: '$path.truncation',
            ),
      elapsedMs: _wireInt(json['elapsedMs'], '$path.elapsedMs'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome.toJson(),
    'source': source.toJson(),
    'records': records.map((item) => item.toJson()).toList(growable: false),
    'nextCursor': nextCursor == null ? null : nextCursor!,
    'currentCursor': currentCursor == null ? null : currentCursor!,
    'truncated': truncated,
    'truncation': truncation == null ? null : truncation!.toJson(),
    'elapsedMs': elapsedMs,
  };
}

/// Strict wire representation of `PatchbayBlobMetadataWire`.
final class PatchbayBlobMetadataWire {
  /// Creates a fully validated wire value.
  const PatchbayBlobMetadataWire({
    required this.blobId,
    required this.source,
    required this.kind,
    required this.contentType,
    required this.length,
    required this.sha256,
    required this.createdAt,
    required this.expiresAt,
    required this.filename,
    required this.properties,
  });

  /// Value of the `blobId` wire field.
  final String blobId;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `kind` wire field.
  final PatchbayBlobSourceWire kind;

  /// Value of the `contentType` wire field.
  final String contentType;

  /// Value of the `length` wire field.
  final int length;

  /// Value of the `sha256` wire field.
  final String sha256;

  /// Value of the `createdAt` wire field.
  final String createdAt;

  /// Value of the `expiresAt` wire field.
  final String expiresAt;

  /// Value of the `filename` wire field.
  final String? filename;

  /// Value of the `properties` wire field.
  final Map<String, Object?> properties;

  /// Decodes a strict JSON object at [path].
  factory PatchbayBlobMetadataWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'blobId',
      'source',
      'kind',
      'contentType',
      'length',
      'sha256',
      'createdAt',
      'expiresAt',
      'filename',
      'properties',
    }, path);
    return PatchbayBlobMetadataWire(
      blobId: _wireString(json['blobId'], '$path.blobId'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      kind: PatchbayBlobSourceWire.fromJson(json['kind'], path: '$path.kind'),
      contentType: _wireString(json['contentType'], '$path.contentType'),
      length: _wireInt(json['length'], '$path.length'),
      sha256: _wireString(json['sha256'], '$path.sha256'),
      createdAt: _wireString(json['createdAt'], '$path.createdAt'),
      expiresAt: _wireString(json['expiresAt'], '$path.expiresAt'),
      filename: json['filename'] == null
          ? null
          : _wireString(json['filename'], '$path.filename'),
      properties: json['properties'] == null
          ? const <String, Object?>{}
          : _wireJsonObject(json['properties'], '$path.properties'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'blobId': blobId,
    'source': source.toJson(),
    'kind': kind.toJson(),
    'contentType': contentType,
    'length': length,
    'sha256': sha256,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
    if (filename != null) 'filename': filename!,
    if (properties.isNotEmpty)
      'properties': _wireJsonObject(properties, r'$.properties'),
  };
}

/// Strict wire representation of `PatchbayBlobMetadataRequestWire`.
final class PatchbayBlobMetadataRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayBlobMetadataRequestWire({required this.blobId});

  /// Value of the `blobId` wire field.
  final String blobId;

  /// Decodes a strict JSON object at [path].
  factory PatchbayBlobMetadataRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'blobId'}, path);
    return PatchbayBlobMetadataRequestWire(
      blobId: _wireString(json['blobId'], '$path.blobId'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{'blobId': blobId};
}

/// Strict wire representation of `PatchbayBlobReadRequestWire`.
final class PatchbayBlobReadRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayBlobReadRequestWire({
    required this.blobId,
    required this.offset,
    required this.limit,
  });

  /// Value of the `blobId` wire field.
  final String blobId;

  /// Value of the `offset` wire field.
  final int offset;

  /// Value of the `limit` wire field.
  final int? limit;

  /// Decodes a strict JSON object at [path].
  factory PatchbayBlobReadRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'blobId', 'offset', 'limit'}, path);
    return PatchbayBlobReadRequestWire(
      blobId: _wireString(json['blobId'], '$path.blobId'),
      offset: _wireInt(json['offset'], '$path.offset'),
      limit: json['limit'] == null
          ? null
          : _wireInt(json['limit'], '$path.limit'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'blobId': blobId,
    'offset': offset,
    if (limit != null) 'limit': limit!,
  };
}

/// Strict wire representation of `PatchbayBlobChunkWire`.
final class PatchbayBlobChunkWire {
  /// Creates a fully validated wire value.
  const PatchbayBlobChunkWire({
    required this.metadata,
    required this.offset,
    required this.length,
    required this.nextOffset,
    required this.eof,
    required this.dataBase64,
  });

  /// Value of the `metadata` wire field.
  final PatchbayBlobMetadataWire metadata;

  /// Value of the `offset` wire field.
  final int offset;

  /// Value of the `length` wire field.
  final int length;

  /// Value of the `nextOffset` wire field.
  final int nextOffset;

  /// Value of the `eof` wire field.
  final bool eof;

  /// Value of the `dataBase64` wire field.
  final String dataBase64;

  /// Decodes a strict JSON object at [path].
  factory PatchbayBlobChunkWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'metadata',
      'offset',
      'length',
      'nextOffset',
      'eof',
      'dataBase64',
    }, path);
    return PatchbayBlobChunkWire(
      metadata: PatchbayBlobMetadataWire.fromJson(
        _wireMap(json['metadata'], '$path.metadata'),
        path: '$path.metadata',
      ),
      offset: _wireInt(json['offset'], '$path.offset'),
      length: _wireInt(json['length'], '$path.length'),
      nextOffset: _wireInt(json['nextOffset'], '$path.nextOffset'),
      eof: _wireBool(json['eof'], '$path.eof'),
      dataBase64: _wireString(json['dataBase64'], '$path.dataBase64'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'metadata': metadata.toJson(),
    'offset': offset,
    'length': length,
    'nextOffset': nextOffset,
    'eof': eof,
    'dataBase64': dataBase64,
  };
}

/// Strict wire representation of `PatchbayLogExportResultWire`.
final class PatchbayLogExportResultWire {
  /// Creates a fully validated wire value.
  const PatchbayLogExportResultWire({
    required this.source,
    required this.blob,
    required this.recordCount,
    required this.truncated,
    required this.truncation,
  });

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `blob` wire field.
  final PatchbayBlobMetadataWire blob;

  /// Value of the `recordCount` wire field.
  final int recordCount;

  /// Value of the `truncated` wire field.
  final bool truncated;

  /// Value of the `truncation` wire field.
  final PatchbayLogTruncationWire? truncation;

  /// Decodes a strict JSON object at [path].
  factory PatchbayLogExportResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'source',
      'blob',
      'recordCount',
      'truncated',
      'truncation',
    }, path);
    return PatchbayLogExportResultWire(
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      blob: PatchbayBlobMetadataWire.fromJson(
        _wireMap(json['blob'], '$path.blob'),
        path: '$path.blob',
      ),
      recordCount: _wireInt(json['recordCount'], '$path.recordCount'),
      truncated: _wireBool(json['truncated'], '$path.truncated'),
      truncation: json['truncation'] == null
          ? null
          : PatchbayLogTruncationWire.fromJson(
              json['truncation'],
              path: '$path.truncation',
            ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.toJson(),
    'blob': blob.toJson(),
    'recordCount': recordCount,
    'truncated': truncated,
    'truncation': truncation == null ? null : truncation!.toJson(),
  };
}

/// Strict wire representation of `PatchbayCaptureRequestWire`.
final class PatchbayCaptureRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayCaptureRequestWire({
    required this.targetId,
    required this.generation,
    required this.pixelRatio,
    required this.timeoutMs,
    required this.afterFrames,
  });

  /// Value of the `targetId` wire field.
  final String? targetId;

  /// Value of the `generation` wire field.
  final int? generation;

  /// Value of the `pixelRatio` wire field.
  final num? pixelRatio;

  /// Value of the `timeoutMs` wire field.
  final int? timeoutMs;

  /// Value of the `afterFrames` wire field.
  final int? afterFrames;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCaptureRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'targetId',
      'generation',
      'pixelRatio',
      'timeoutMs',
      'afterFrames',
    }, path);
    return PatchbayCaptureRequestWire(
      targetId: json['targetId'] == null
          ? null
          : _wireString(json['targetId'], '$path.targetId'),
      generation: json['generation'] == null
          ? null
          : _wireInt(json['generation'], '$path.generation'),
      pixelRatio: json['pixelRatio'] == null
          ? null
          : _wireNum(json['pixelRatio'], '$path.pixelRatio'),
      timeoutMs: json['timeoutMs'] == null
          ? null
          : _wireInt(json['timeoutMs'], '$path.timeoutMs'),
      afterFrames: json['afterFrames'] == null
          ? null
          : _wireInt(json['afterFrames'], '$path.afterFrames'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    if (targetId != null) 'targetId': targetId!,
    if (generation != null) 'generation': generation!,
    if (pixelRatio != null) 'pixelRatio': pixelRatio!,
    if (timeoutMs != null) 'timeoutMs': timeoutMs!,
    if (afterFrames != null) 'afterFrames': afterFrames!,
  };
}

/// Strict wire representation of `PatchbayCaptureResultWire`.
final class PatchbayCaptureResultWire {
  /// Creates a fully validated wire value.
  const PatchbayCaptureResultWire({
    required this.outcome,
    required this.source,
    required this.target,
    required this.targetId,
    required this.generation,
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.pixelFormat,
    required this.capturedAt,
    required this.requestedFrames,
    required this.observedFrames,
    required this.maxPixels,
    required this.maxBytes,
    required this.warnings,
    required this.blob,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `target` wire field.
  final PatchbayCaptureTargetWire target;

  /// Value of the `targetId` wire field.
  final String? targetId;

  /// Value of the `generation` wire field.
  final int? generation;

  /// Value of the `width` wire field.
  final int width;

  /// Value of the `height` wire field.
  final int height;

  /// Value of the `pixelRatio` wire field.
  final num pixelRatio;

  /// Value of the `pixelFormat` wire field.
  final String pixelFormat;

  /// Value of the `capturedAt` wire field.
  final String capturedAt;

  /// Value of the `requestedFrames` wire field.
  final int requestedFrames;

  /// Value of the `observedFrames` wire field.
  final int observedFrames;

  /// Value of the `maxPixels` wire field.
  final int maxPixels;

  /// Value of the `maxBytes` wire field.
  final int maxBytes;

  /// Value of the `warnings` wire field.
  final List<PatchbayCaptureWarningWire> warnings;

  /// Value of the `blob` wire field.
  final PatchbayBlobMetadataWire blob;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCaptureResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'target',
      'targetId',
      'generation',
      'width',
      'height',
      'pixelRatio',
      'pixelFormat',
      'capturedAt',
      'requestedFrames',
      'observedFrames',
      'maxPixels',
      'maxBytes',
      'warnings',
      'blob',
    }, path);
    return PatchbayCaptureResultWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      target: PatchbayCaptureTargetWire.fromJson(
        json['target'],
        path: '$path.target',
      ),
      targetId: json['targetId'] == null
          ? null
          : _wireString(json['targetId'], '$path.targetId'),
      generation: json['generation'] == null
          ? null
          : _wireInt(json['generation'], '$path.generation'),
      width: _wireInt(json['width'], '$path.width'),
      height: _wireInt(json['height'], '$path.height'),
      pixelRatio: _wireNum(json['pixelRatio'], '$path.pixelRatio'),
      pixelFormat: _wireString(json['pixelFormat'], '$path.pixelFormat'),
      capturedAt: _wireString(json['capturedAt'], '$path.capturedAt'),
      requestedFrames: _wireInt(
        json['requestedFrames'],
        '$path.requestedFrames',
      ),
      observedFrames: _wireInt(json['observedFrames'], '$path.observedFrames'),
      maxPixels: _wireInt(json['maxPixels'], '$path.maxPixels'),
      maxBytes: _wireInt(json['maxBytes'], '$path.maxBytes'),
      warnings: _wireList(json['warnings'], '$path.warnings')
          .map(
            (item) => PatchbayCaptureWarningWire.fromJson(
              item,
              path: '$path.warnings[]',
            ),
          )
          .toList(growable: false),
      blob: PatchbayBlobMetadataWire.fromJson(
        _wireMap(json['blob'], '$path.blob'),
        path: '$path.blob',
      ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'target': target.toJson(),
    'targetId': targetId == null ? null : targetId!,
    'generation': generation == null ? null : generation!,
    'width': width,
    'height': height,
    'pixelRatio': pixelRatio,
    'pixelFormat': pixelFormat,
    'capturedAt': capturedAt,
    'requestedFrames': requestedFrames,
    'observedFrames': observedFrames,
    'maxPixels': maxPixels,
    'maxBytes': maxBytes,
    'warnings': warnings.map((item) => item.toJson()).toList(growable: false),
    'blob': blob.toJson(),
  };
}

/// Strict wire representation of `PatchbayCaptureDiffRequestWire`.
final class PatchbayCaptureDiffRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayCaptureDiffRequestWire({
    required this.beforeBlobId,
    required this.afterBlobId,
  });

  /// Value of the `beforeBlobId` wire field.
  final String beforeBlobId;

  /// Value of the `afterBlobId` wire field.
  final String afterBlobId;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCaptureDiffRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'beforeBlobId', 'afterBlobId'}, path);
    return PatchbayCaptureDiffRequestWire(
      beforeBlobId: _wireString(json['beforeBlobId'], '$path.beforeBlobId'),
      afterBlobId: _wireString(json['afterBlobId'], '$path.afterBlobId'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'beforeBlobId': beforeBlobId,
    'afterBlobId': afterBlobId,
  };
}

/// Strict wire representation of `PatchbayCaptureDiffResultWire`.
final class PatchbayCaptureDiffResultWire {
  /// Creates a fully validated wire value.
  const PatchbayCaptureDiffResultWire({
    required this.outcome,
    required this.source,
    required this.beforeBlobId,
    required this.afterBlobId,
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.changedPixels,
    required this.totalPixels,
    required this.differenceRatio,
    required this.comparedAt,
    required this.maxPixels,
    required this.maxBytes,
    required this.warnings,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `beforeBlobId` wire field.
  final String beforeBlobId;

  /// Value of the `afterBlobId` wire field.
  final String afterBlobId;

  /// Value of the `width` wire field.
  final int width;

  /// Value of the `height` wire field.
  final int height;

  /// Value of the `pixelFormat` wire field.
  final String pixelFormat;

  /// Value of the `changedPixels` wire field.
  final int changedPixels;

  /// Value of the `totalPixels` wire field.
  final int totalPixels;

  /// Value of the `differenceRatio` wire field.
  final num differenceRatio;

  /// Value of the `comparedAt` wire field.
  final String comparedAt;

  /// Value of the `maxPixels` wire field.
  final int maxPixels;

  /// Value of the `maxBytes` wire field.
  final int maxBytes;

  /// Value of the `warnings` wire field.
  final List<PatchbayCaptureWarningWire> warnings;

  /// Decodes a strict JSON object at [path].
  factory PatchbayCaptureDiffResultWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'beforeBlobId',
      'afterBlobId',
      'width',
      'height',
      'pixelFormat',
      'changedPixels',
      'totalPixels',
      'differenceRatio',
      'comparedAt',
      'maxPixels',
      'maxBytes',
      'warnings',
    }, path);
    return PatchbayCaptureDiffResultWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      beforeBlobId: _wireString(json['beforeBlobId'], '$path.beforeBlobId'),
      afterBlobId: _wireString(json['afterBlobId'], '$path.afterBlobId'),
      width: _wireInt(json['width'], '$path.width'),
      height: _wireInt(json['height'], '$path.height'),
      pixelFormat: _wireString(json['pixelFormat'], '$path.pixelFormat'),
      changedPixels: _wireInt(json['changedPixels'], '$path.changedPixels'),
      totalPixels: _wireInt(json['totalPixels'], '$path.totalPixels'),
      differenceRatio: _wireNum(
        json['differenceRatio'],
        '$path.differenceRatio',
      ),
      comparedAt: _wireString(json['comparedAt'], '$path.comparedAt'),
      maxPixels: _wireInt(json['maxPixels'], '$path.maxPixels'),
      maxBytes: _wireInt(json['maxBytes'], '$path.maxBytes'),
      warnings: _wireList(json['warnings'], '$path.warnings')
          .map(
            (item) => PatchbayCaptureWarningWire.fromJson(
              item,
              path: '$path.warnings[]',
            ),
          )
          .toList(growable: false),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'beforeBlobId': beforeBlobId,
    'afterBlobId': afterBlobId,
    'width': width,
    'height': height,
    'pixelFormat': pixelFormat,
    'changedPixels': changedPixels,
    'totalPixels': totalPixels,
    'differenceRatio': differenceRatio,
    'comparedAt': comparedAt,
    'maxPixels': maxPixels,
    'maxBytes': maxBytes,
    'warnings': warnings.map((item) => item.toJson()).toList(growable: false),
  };
}

/// Strict wire representation of `PatchbayKeepAwakeRequestWire`.
final class PatchbayKeepAwakeRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayKeepAwakeRequestWire({
    required this.enabled,
    required this.leaseMs,
  });

  /// Value of the `enabled` wire field.
  final bool enabled;

  /// Value of the `leaseMs` wire field.
  final int? leaseMs;

  /// Decodes a strict JSON object at [path].
  factory PatchbayKeepAwakeRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'enabled', 'leaseMs'}, path);
    return PatchbayKeepAwakeRequestWire(
      enabled: _wireBool(json['enabled'], '$path.enabled'),
      leaseMs: json['leaseMs'] == null
          ? null
          : _wireInt(json['leaseMs'], '$path.leaseMs'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    if (leaseMs != null) 'leaseMs': leaseMs!,
  };
}

/// Strict wire representation of `PatchbayKeepAwakeStateWire`.
final class PatchbayKeepAwakeStateWire {
  /// Creates a fully validated wire value.
  const PatchbayKeepAwakeStateWire({
    required this.outcome,
    required this.source,
    required this.wired,
    required this.enabled,
    required this.leaseMs,
    required this.leaseRemainingMs,
    required this.lastRelease,
    required this.lastReleaseFailure,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `wired` wire field.
  final bool wired;

  /// Value of the `enabled` wire field.
  final bool enabled;

  /// Value of the `leaseMs` wire field.
  final int? leaseMs;

  /// Value of the `leaseRemainingMs` wire field.
  final int? leaseRemainingMs;

  /// Value of the `lastRelease` wire field.
  final PatchbayKeepAwakeReleaseWire? lastRelease;

  /// Value of the `lastReleaseFailure` wire field.
  final String? lastReleaseFailure;

  /// Decodes a strict JSON object at [path].
  factory PatchbayKeepAwakeStateWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'wired',
      'enabled',
      'leaseMs',
      'leaseRemainingMs',
      'lastRelease',
      'lastReleaseFailure',
    }, path);
    return PatchbayKeepAwakeStateWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      wired: _wireBool(json['wired'], '$path.wired'),
      enabled: _wireBool(json['enabled'], '$path.enabled'),
      leaseMs: json['leaseMs'] == null
          ? null
          : _wireInt(json['leaseMs'], '$path.leaseMs'),
      leaseRemainingMs: json['leaseRemainingMs'] == null
          ? null
          : _wireInt(json['leaseRemainingMs'], '$path.leaseRemainingMs'),
      lastRelease: json['lastRelease'] == null
          ? null
          : PatchbayKeepAwakeReleaseWire.fromJson(
              json['lastRelease'],
              path: '$path.lastRelease',
            ),
      lastReleaseFailure: json['lastReleaseFailure'] == null
          ? null
          : _wireString(json['lastReleaseFailure'], '$path.lastReleaseFailure'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'wired': wired,
    'enabled': enabled,
    'leaseMs': leaseMs == null ? null : leaseMs!,
    'leaseRemainingMs': leaseRemainingMs == null ? null : leaseRemainingMs!,
    if (lastRelease != null) 'lastRelease': lastRelease!.toJson(),
    if (lastReleaseFailure != null) 'lastReleaseFailure': lastReleaseFailure!,
  };
}

/// Strict wire representation of `PatchbaySnapshotRequestWire`.
final class PatchbaySnapshotRequestWire {
  /// Creates a fully validated wire value.
  const PatchbaySnapshotRequestWire({
    required this.path,
    required this.until,
    required this.value,
    required this.timeoutMs,
  });

  /// Value of the `path` wire field.
  final String path;

  /// Value of the `until` wire field.
  final PatchbaySnapshotConditionWire? until;

  /// Value of the `value` wire field.
  final Object? value;

  /// Value of the `timeoutMs` wire field.
  final int? timeoutMs;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySnapshotRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'path',
      'until',
      'value',
      'timeoutMs',
    }, path);
    return PatchbaySnapshotRequestWire(
      path: _wireString(json['path'], '$path.path'),
      until: json['until'] == null
          ? null
          : PatchbaySnapshotConditionWire.fromJson(
              json['until'],
              path: '$path.until',
            ),
      value: json['value'] == null
          ? null
          : _wireJson(json['value'], '$path.value'),
      timeoutMs: json['timeoutMs'] == null
          ? null
          : _wireInt(json['timeoutMs'], '$path.timeoutMs'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    if (until != null) 'until': until!.toJson(),
    if (value != null) 'value': _wireJson(value!, r'$.value'),
    if (timeoutMs != null) 'timeoutMs': timeoutMs!,
  };
}

/// Strict wire representation of `PatchbaySnapshotDiffRequestWire`.
final class PatchbaySnapshotDiffRequestWire {
  /// Creates a fully validated wire value.
  const PatchbaySnapshotDiffRequestWire({required this.fromRevision});

  /// Value of the `fromRevision` wire field.
  final int fromRevision;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySnapshotDiffRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'fromRevision'}, path);
    return PatchbaySnapshotDiffRequestWire(
      fromRevision: _wireInt(json['fromRevision'], '$path.fromRevision'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'fromRevision': fromRevision,
  };
}

/// Strict wire representation of `PatchbaySnapshotSelectionWire`.
final class PatchbaySnapshotSelectionWire {
  /// Creates a fully validated wire value.
  const PatchbaySnapshotSelectionWire({
    required this.path,
    required this.found,
    required this.value,
    required this.miss,
  });

  /// Value of the `path` wire field.
  final String path;

  /// Value of the `found` wire field.
  final bool found;

  /// Value of the `value` wire field.
  final Object? value;

  /// Value of the `miss` wire field.
  final PatchbaySnapshotMissWire? miss;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySnapshotSelectionWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'path', 'found', 'value', 'miss'}, path);
    return PatchbaySnapshotSelectionWire(
      path: _wireString(json['path'], '$path.path'),
      found: _wireBool(json['found'], '$path.found'),
      value: json['value'] == null
          ? null
          : _wireJson(json['value'], '$path.value'),
      miss: json['miss'] == null
          ? null
          : PatchbaySnapshotMissWire.fromJson(json['miss'], path: '$path.miss'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'found': found,
    if (value != null) 'value': _wireJson(value!, r'$.value'),
    if (miss != null) 'miss': miss!.toJson(),
  };
}

/// Strict wire representation of `PatchbaySnapshotWaitWire`.
final class PatchbaySnapshotWaitWire {
  /// Creates a fully validated wire value.
  const PatchbaySnapshotWaitWire({
    required this.outcome,
    required this.condition,
    required this.timeoutMs,
    required this.elapsedMs,
    required this.pollIntervalMs,
    required this.polls,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `condition` wire field.
  final PatchbaySnapshotConditionWire condition;

  /// Value of the `timeoutMs` wire field.
  final int timeoutMs;

  /// Value of the `elapsedMs` wire field.
  final int elapsedMs;

  /// Value of the `pollIntervalMs` wire field.
  final int pollIntervalMs;

  /// Value of the `polls` wire field.
  final int polls;

  /// Decodes a strict JSON object at [path].
  factory PatchbaySnapshotWaitWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'condition',
      'timeoutMs',
      'elapsedMs',
      'pollIntervalMs',
      'polls',
    }, path);
    return PatchbaySnapshotWaitWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      condition: PatchbaySnapshotConditionWire.fromJson(
        json['condition'],
        path: '$path.condition',
      ),
      timeoutMs: _wireInt(json['timeoutMs'], '$path.timeoutMs'),
      elapsedMs: _wireInt(json['elapsedMs'], '$path.elapsedMs'),
      pollIntervalMs: _wireInt(json['pollIntervalMs'], '$path.pollIntervalMs'),
      polls: _wireInt(json['polls'], '$path.polls'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'condition': condition.toJson(),
    'timeoutMs': timeoutMs,
    'elapsedMs': elapsedMs,
    'pollIntervalMs': pollIntervalMs,
    'polls': polls,
  };
}

/// Strict wire representation of `PatchbayInspectUnavailableWire`.
enum PatchbayInspectUnavailableWire {
  /// The `notDebugBuild` wire value.
  notDebugBuild,

  /// The `rootInspectorExcluded` wire value.
  rootInspectorExcluded,

  /// The `hostDisposed` wire value.
  hostDisposed;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayInspectUnavailableWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayInspectUnavailableWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayInspectReleaseWire`.
enum PatchbayInspectReleaseWire {
  /// The `explicitOff` wire value.
  explicitOff,

  /// The `leaseExpired` wire value.
  leaseExpired,

  /// The `disposed` wire value.
  disposed;

  /// Decodes a value at [path], rejecting unknown values.
  static PatchbayInspectReleaseWire fromJson(
    Object? value, {
    String path = r'$',
  }) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException(
      '$path has unknown PatchbayInspectReleaseWire: $wire',
    );
  }

  /// Encodes this value using its stable wire name.
  String toJson() => name;
}

/// Strict wire representation of `PatchbayInspectSelectRequestWire`.
final class PatchbayInspectSelectRequestWire {
  /// Creates a fully validated wire value.
  const PatchbayInspectSelectRequestWire({
    required this.enabled,
    required this.ttlMs,
  });

  /// Value of the `enabled` wire field.
  final bool enabled;

  /// Value of the `ttlMs` wire field.
  final int? ttlMs;

  /// Decodes a strict JSON object at [path].
  factory PatchbayInspectSelectRequestWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{'enabled', 'ttlMs'}, path);
    return PatchbayInspectSelectRequestWire(
      enabled: _wireBool(json['enabled'], '$path.enabled'),
      ttlMs: json['ttlMs'] == null
          ? null
          : _wireInt(json['ttlMs'], '$path.ttlMs'),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    if (ttlMs != null) 'ttlMs': ttlMs!,
  };
}

/// Strict wire representation of `PatchbayInspectStateWire`.
final class PatchbayInspectStateWire {
  /// Creates a fully validated wire value.
  const PatchbayInspectStateWire({
    required this.outcome,
    required this.source,
    required this.selectMode,
    required this.selectionOnTap,
    required this.managed,
    required this.previousSelectMode,
    required this.restoresTo,
    required this.leaseMs,
    required this.leaseRemainingMs,
    required this.lastRelease,
  });

  /// Value of the `outcome` wire field.
  final String outcome;

  /// Value of the `source` wire field.
  final PatchbayFactSourceWire source;

  /// Value of the `selectMode` wire field.
  final bool selectMode;

  /// Value of the `selectionOnTap` wire field.
  final bool selectionOnTap;

  /// Value of the `managed` wire field.
  final bool managed;

  /// Value of the `previousSelectMode` wire field.
  final bool? previousSelectMode;

  /// Value of the `restoresTo` wire field.
  final bool? restoresTo;

  /// Value of the `leaseMs` wire field.
  final int? leaseMs;

  /// Value of the `leaseRemainingMs` wire field.
  final int? leaseRemainingMs;

  /// Value of the `lastRelease` wire field.
  final PatchbayInspectReleaseWire? lastRelease;

  /// Decodes a strict JSON object at [path].
  factory PatchbayInspectStateWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'outcome',
      'source',
      'selectMode',
      'selectionOnTap',
      'managed',
      'previousSelectMode',
      'restoresTo',
      'leaseMs',
      'leaseRemainingMs',
      'lastRelease',
    }, path);
    return PatchbayInspectStateWire(
      outcome: _wireString(json['outcome'], '$path.outcome'),
      source: PatchbayFactSourceWire.fromJson(
        json['source'],
        path: '$path.source',
      ),
      selectMode: _wireBool(json['selectMode'], '$path.selectMode'),
      selectionOnTap: _wireBool(json['selectionOnTap'], '$path.selectionOnTap'),
      managed: _wireBool(json['managed'], '$path.managed'),
      previousSelectMode: json['previousSelectMode'] == null
          ? null
          : _wireBool(json['previousSelectMode'], '$path.previousSelectMode'),
      restoresTo: json['restoresTo'] == null
          ? null
          : _wireBool(json['restoresTo'], '$path.restoresTo'),
      leaseMs: json['leaseMs'] == null
          ? null
          : _wireInt(json['leaseMs'], '$path.leaseMs'),
      leaseRemainingMs: json['leaseRemainingMs'] == null
          ? null
          : _wireInt(json['leaseRemainingMs'], '$path.leaseRemainingMs'),
      lastRelease: json['lastRelease'] == null
          ? null
          : PatchbayInspectReleaseWire.fromJson(
              json['lastRelease'],
              path: '$path.lastRelease',
            ),
    );
  }

  /// Encodes this value as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'selectMode': selectMode,
    'selectionOnTap': selectionOnTap,
    'managed': managed,
    if (previousSelectMode != null) 'previousSelectMode': previousSelectMode!,
    if (restoresTo != null) 'restoresTo': restoresTo!,
    if (leaseMs != null) 'leaseMs': leaseMs!,
    if (leaseRemainingMs != null) 'leaseRemainingMs': leaseRemainingMs!,
    if (lastRelease != null) 'lastRelease': lastRelease!.toJson(),
  };
}

Map<String, Object?> _wireMap(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object');
  try {
    return Map<String, Object?>.from(value);
  } on Object {
    throw FormatException('$path must have string keys');
  }
}

List<Object?> _wireList(Object? value, String path) {
  if (value is! List) throw FormatException('$path must be a list');
  return List<Object?>.from(value);
}

String _wireString(Object? value, String path) {
  if (value is! String) throw FormatException('$path must be a string');
  return value;
}

bool _wireBool(Object? value, String path) {
  if (value is! bool) throw FormatException('$path must be a bool');
  return value;
}

int _wireInt(Object? value, String path) {
  if (value is! int) throw FormatException('$path must be an int');
  return value;
}

num _wireNum(Object? value, String path) {
  if (value is! num) throw FormatException('$path must be a number');
  if (!value.isFinite) throw FormatException('$path must be finite');
  return value;
}

Object? _wireJson(Object? value, String path) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) return _wireNum(value, path);
  if (value is List) {
    return <Object?>[
      for (var index = 0; index < value.length; index += 1)
        _wireJson(value[index], '$path[$index]'),
    ];
  }
  if (value is Map) return _wireJsonObject(value, path);
  throw FormatException('$path must be a JSON value');
}

Map<String, Object?> _wireJsonObject(Object? value, String path) {
  final map = _wireMap(value, path);
  return <String, Object?>{
    for (final entry in map.entries)
      entry.key: _wireJson(entry.value, '$path.${entry.key}'),
  };
}

void _wireKeys(Map<String, Object?> json, Set<String> allowed, String path) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException('$path has unknown fields: ${unknown.join(',')}');
  }
}
