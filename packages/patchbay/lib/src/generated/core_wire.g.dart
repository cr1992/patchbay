// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, unused_element, use_null_aware_elements
// Contract: packages/patchbay/contracts/core_wire.json
// Generator: packages/patchbay/tool/wire_codegen.dart
// Library: patchbay_core_wire

enum PatchbayCommandModeWire {
  readOnly,
  immediate,
  job;

  static PatchbayCommandModeWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayCommandModeWire: $wire');
  }

  String toJson() => name;
}

enum PatchbayParameterTypeWire {
  string,
  integer,
  number,
  boolean,
  enumeration,
  json;

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

  String toJson() => name;
}

enum PatchbayPlaneWire {
  domain,
  flutterUi;

  static PatchbayPlaneWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayPlaneWire: $wire');
  }

  String toJson() => name;
}

enum PatchbaySideEffectWire {
  none,
  appState,
  external;

  static PatchbaySideEffectWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbaySideEffectWire: $wire');
  }

  String toJson() => name;
}

enum PatchbayFactSourceWire {
  appRecorded,
  commandEcho,
  deviceReported,
  uiObserved,
  unknown;

  static PatchbayFactSourceWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayFactSourceWire: $wire');
  }

  String toJson() => name;
}

enum PatchbayAdmissionWire {
  accepted,
  rejected;

  static PatchbayAdmissionWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayAdmissionWire: $wire');
  }

  String toJson() => name;
}

enum PatchbayJobPhaseWire {
  running,
  completed,
  failed,
  cancelled;

  static PatchbayJobPhaseWire fromJson(Object? value, {String path = r'$'}) {
    final wire = _wireString(value, path);
    for (final candidate in values) {
      if (candidate.name == wire) return candidate;
    }
    throw FormatException('$path has unknown PatchbayJobPhaseWire: $wire');
  }

  String toJson() => name;
}

enum PatchbayUiTargetKindWire {
  text;

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

  String toJson() => name;
}

enum PatchbaySensitivePolicyWire {
  public,
  redacted;

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

  String toJson() => name;
}

enum PatchbayNavigationOperationWire {
  go,
  push,
  back;

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

  String toJson() => name;
}

enum PatchbayUiWaitConditionWire {
  semanticsMounted,
  semanticsUnmounted,
  semanticsValue,
  navigationDestination,
  treeRevision,
  frameRevision;

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

  String toJson() => name;
}

final class PatchbayParameterDescriptorWire {
  const PatchbayParameterDescriptorWire({
    required this.name,
    required this.type,
    required this.required,
    required this.sensitive,
    required this.defaultValue,
    required this.allowedValues,
    required this.summary,
  });

  final String name;
  final PatchbayParameterTypeWire type;
  final bool required;
  final bool sensitive;
  final Object? defaultValue;
  final List<Object?> allowedValues;
  final String? summary;

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

final class PatchbayIdentityWire {
  const PatchbayIdentityWire({
    required this.schemaVersion,
    required this.applicationId,
    required this.appInstanceId,
    required this.isolateId,
  });

  final int schemaVersion;
  final String applicationId;
  final String appInstanceId;
  final String? isolateId;

  factory PatchbayIdentityWire.fromJson(
    Map<String, Object?> json, {
    String path = r'$',
  }) {
    _wireKeys(json, const <String>{
      'schemaVersion',
      'applicationId',
      'appInstanceId',
      'isolateId',
    }, path);
    return PatchbayIdentityWire(
      schemaVersion: _wireInt(json['schemaVersion'], '$path.schemaVersion'),
      applicationId: _wireString(json['applicationId'], '$path.applicationId'),
      appInstanceId: _wireString(json['appInstanceId'], '$path.appInstanceId'),
      isolateId: json['isolateId'] == null
          ? null
          : _wireString(json['isolateId'], '$path.isolateId'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'applicationId': applicationId,
    'appInstanceId': appInstanceId,
    'isolateId': isolateId == null ? null : isolateId!,
  };
}

final class PatchbayCommandDescriptorWire {
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

  final String name;
  final String summary;
  final PatchbayPlaneWire plane;
  final PatchbayCommandModeWire mode;
  final PatchbaySideEffectWire sideEffect;
  final List<PatchbayFactSourceWire> factSources;
  final List<String> gates;
  final List<PatchbayParameterDescriptorWire> parameters;

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

final class PatchbayRejectionWire {
  const PatchbayRejectionWire({
    required this.code,
    required this.notice,
    required this.details,
  });

  final String code;
  final String? notice;
  final Map<String, Object?> details;

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

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    if (notice != null) 'notice': notice!,
    if (details.isNotEmpty) 'details': _wireJsonObject(details, r'$.details'),
  };
}

final class PatchbayInvocationWire {
  const PatchbayInvocationWire({
    required this.schemaVersion,
    required this.requestId,
    required this.admission,
    required this.payload,
    required this.notice,
    required this.jobId,
    required this.rejection,
  });

  final int schemaVersion;
  final String requestId;
  final PatchbayAdmissionWire admission;
  final Map<String, Object?> payload;
  final String? notice;
  final String? jobId;
  final PatchbayRejectionWire? rejection;

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

final class PatchbayJobEventWire {
  const PatchbayJobEventWire({
    required this.sequence,
    required this.at,
    required this.phase,
    required this.source,
    required this.operation,
    required this.payload,
    required this.reason,
  });

  final int sequence;
  final String at;
  final PatchbayJobPhaseWire phase;
  final PatchbayFactSourceWire source;
  final String? operation;
  final Map<String, Object?> payload;
  final String? reason;

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

final class PatchbayJobSnapshotWire {
  const PatchbayJobSnapshotWire({
    required this.jobId,
    required this.terminal,
    required this.events,
  });

  final String jobId;
  final bool terminal;
  final List<PatchbayJobEventWire> events;

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

  Map<String, Object?> toJson() => <String, Object?>{
    'jobId': jobId,
    'terminal': terminal,
    'events': events.map((item) => item.toJson()).toList(growable: false),
  };
}

final class PatchbayUiTargetDescriptorWire {
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

  final String id;
  final int generation;
  final PatchbayUiTargetKindWire kind;
  final bool mounted;
  final bool ambiguous;
  final List<String> operations;
  final Map<String, Object?> operationGates;
  final PatchbaySensitivePolicyWire sensitivePolicy;
  final PatchbaySideEffectWire sideEffect;
  final List<PatchbayFactSourceWire> factSources;

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

final class PatchbaySemanticsRectWire {
  const PatchbaySemanticsRectWire({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final num left;
  final num top;
  final num width;
  final num height;

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

  Map<String, Object?> toJson() => <String, Object?>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };
}

final class PatchbaySemanticsNodeWire {
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

  final int nodeId;
  final int generation;
  final int? parentNodeId;
  final int depth;
  final String identifier;
  final String label;
  final String? value;
  final bool? valueRedacted;
  final String? hint;
  final String? tooltip;
  final List<String> flags;
  final List<String> actions;
  final bool invisible;
  final bool userActionsBlocked;
  final PatchbaySemanticsRectWire rect;
  final String rectCoordinateSpace;
  final List<num>? transformToParent;
  final num? scrollPosition;
  final num? scrollExtentMin;
  final num? scrollExtentMax;
  final int? platformViewId;
  final List<int> children;

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

final class PatchbaySemanticsSnapshotWire {
  const PatchbaySemanticsSnapshotWire({
    required this.outcome,
    required this.source,
    required this.treeRevision,
    required this.rootNodeId,
    required this.truncated,
    required this.nodeCount,
    required this.nodes,
  });

  final String outcome;
  final PatchbayFactSourceWire source;
  final int treeRevision;
  final int rootNodeId;
  final bool truncated;
  final int nodeCount;
  final List<PatchbaySemanticsNodeWire> nodes;

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

final class PatchbayDestinationDescriptorWire {
  const PatchbayDestinationDescriptorWire({
    required this.id,
    required this.summary,
    required this.operations,
    required this.gates,
    required this.ambiguous,
  });

  final String id;
  final String? summary;
  final List<PatchbayNavigationOperationWire> operations;
  final List<String> gates;
  final bool ambiguous;

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

final class PatchbayNavigationCatalogWire {
  const PatchbayNavigationCatalogWire({
    required this.outcome,
    required this.source,
    required this.navigationRevision,
    required this.destinations,
  });

  final String outcome;
  final PatchbayFactSourceWire source;
  final int navigationRevision;
  final List<PatchbayDestinationDescriptorWire> destinations;

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

  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'navigationRevision': navigationRevision,
    'destinations': destinations
        .map((item) => item.toJson())
        .toList(growable: false),
  };
}

final class PatchbayNavigationCurrentWire {
  const PatchbayNavigationCurrentWire({
    required this.outcome,
    required this.source,
    required this.navigationRevision,
    required this.destinationId,
  });

  final String outcome;
  final PatchbayFactSourceWire source;
  final int navigationRevision;
  final String? destinationId;

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

  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'source': source.toJson(),
    'navigationRevision': navigationRevision,
    'destinationId': destinationId == null ? null : destinationId!,
  };
}

final class PatchbayNavigationResultWire {
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

  final String outcome;
  final PatchbayFactSourceWire source;
  final PatchbayNavigationOperationWire operation;
  final String? requestedDestinationId;
  final String destinationId;
  final int beforeNavigationRevision;
  final int afterNavigationRevision;
  final int frameRevision;

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

final class PatchbayUiWaitRequestWire {
  const PatchbayUiWaitRequestWire({
    required this.condition,
    required this.timeoutMs,
    required this.semanticsIdentifier,
    required this.value,
    required this.destinationId,
    required this.revision,
  });

  final PatchbayUiWaitConditionWire condition;
  final int timeoutMs;
  final String? semanticsIdentifier;
  final String? value;
  final String? destinationId;
  final int? revision;

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

final class PatchbayUiWaitResultWire {
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

  final String outcome;
  final PatchbayFactSourceWire source;
  final PatchbayUiWaitConditionWire condition;
  final int elapsedMs;
  final String? semanticsIdentifier;
  final int? nodeId;
  final int? generation;
  final String? value;
  final String? destinationId;
  final int? navigationRevision;
  final int? treeRevision;
  final int frameRevision;

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
