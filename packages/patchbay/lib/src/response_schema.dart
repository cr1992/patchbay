/// Closed JSON value kinds supported by command response schemas.
enum PatchbayResponseType { string, integer, number, boolean, object, array }

/// One recursively declared response value.
final class PatchbayResponseValueSchema {
  const PatchbayResponseValueSchema({
    required this.type,
    this.nullable = false,
    this.properties = const <String, PatchbayResponseValueSchema>{},
    this.required = const <String>{},
    this.additionalProperties = false,
    this.items,
    this.discriminator,
    this.variants = const <String, PatchbayResponseValueSchema>{},
  });

  final PatchbayResponseType type;
  final bool nullable;
  final Map<String, PatchbayResponseValueSchema> properties;
  final Set<String> required;
  final bool additionalProperties;
  final PatchbayResponseValueSchema? items;

  /// Object field selecting one member of [variants].
  final String? discriminator;
  final Map<String, PatchbayResponseValueSchema> variants;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    if (nullable) 'nullable': true,
    if (type == PatchbayResponseType.object) ...<String, Object?>{
      'properties': <String, Object?>{
        for (final MapEntry<String, PatchbayResponseValueSchema> entry
            in properties.entries)
          entry.key: entry.value.toJson(),
      },
      'required': required.toList(growable: false)..sort(),
      'additionalProperties': additionalProperties,
      if (discriminator != null) 'discriminator': discriminator!,
      if (variants.isNotEmpty)
        'variants': <String, Object?>{
          for (final MapEntry<String, PatchbayResponseValueSchema> entry
              in variants.entries)
            entry.key: entry.value.toJson(),
        },
    },
    if (type == PatchbayResponseType.array) 'items': items!.toJson(),
  };

  factory PatchbayResponseValueSchema.fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('response schema node must be an object');
    }
    final Object? rawType = value['type'];
    final PatchbayResponseType? type = rawType is String
        ? PatchbayResponseType.values.cast<PatchbayResponseType?>().firstWhere(
            (PatchbayResponseType? candidate) => candidate?.name == rawType,
            orElse: () => null,
          )
        : null;
    if (type == null) throw const FormatException('unknown response type');
    final Set<String> allowedKeys = <String>{
      'type',
      'nullable',
      if (type == PatchbayResponseType.object) ...<String>{
        'properties',
        'required',
        'additionalProperties',
        'discriminator',
        'variants',
      },
      if (type == PatchbayResponseType.array) 'items',
    };
    if (value.keys.any(
      (Object? key) => key is! String || !allowedKeys.contains(key),
    )) {
      throw const FormatException('unknown response schema keyword');
    }
    final Object? rawNullable = value['nullable'];
    if (rawNullable != null && rawNullable is! bool) {
      throw const FormatException('nullable must be boolean');
    }
    final Map<String, PatchbayResponseValueSchema> properties =
        <String, PatchbayResponseValueSchema>{};
    final Set<String> required = <String>{};
    final Map<String, PatchbayResponseValueSchema> variants =
        <String, PatchbayResponseValueSchema>{};
    PatchbayResponseValueSchema? items;
    String? discriminator;
    var additionalProperties = false;
    if (type == PatchbayResponseType.object) {
      final Object? rawProperties = value['properties'];
      if (rawProperties is! Map<Object?, Object?>) {
        throw const FormatException('object properties must be an object');
      }
      for (final MapEntry<Object?, Object?> entry in rawProperties.entries) {
        if (entry.key is! String) {
          throw const FormatException('property name must be a string');
        }
        properties[entry.key! as String] = PatchbayResponseValueSchema.fromJson(
          entry.value,
        );
      }
      final Object? rawRequired = value['required'];
      if (rawRequired is! List<Object?> ||
          rawRequired.any((Object? entry) => entry is! String)) {
        throw const FormatException('required must be a string array');
      }
      required.addAll(rawRequired.cast<String>());
      if (!properties.keys.toSet().containsAll(required)) {
        throw const FormatException('required field is not declared');
      }
      final Object? rawAdditional = value['additionalProperties'];
      if (rawAdditional is! bool) {
        throw const FormatException('additionalProperties must be explicit');
      }
      additionalProperties = rawAdditional;
      final Object? rawDiscriminator = value['discriminator'];
      if (rawDiscriminator != null && rawDiscriminator is! String) {
        throw const FormatException('discriminator must be a string');
      }
      discriminator = rawDiscriminator as String?;
      final Object? rawVariants = value['variants'];
      if (rawVariants != null) {
        if (discriminator == null || rawVariants is! Map<Object?, Object?>) {
          throw const FormatException('variants require a discriminator');
        }
        for (final MapEntry<Object?, Object?> entry in rawVariants.entries) {
          if (entry.key is! String) {
            throw const FormatException('variant name must be a string');
          }
          final PatchbayResponseValueSchema variant =
              PatchbayResponseValueSchema.fromJson(entry.value);
          if (variant.type != PatchbayResponseType.object) {
            throw const FormatException('variant must be an object schema');
          }
          variants[entry.key! as String] = variant;
        }
      }
      if (discriminator != null && variants.isEmpty) {
        throw const FormatException('discriminator requires variants');
      }
    } else if (value.containsKey('properties') ||
        value.containsKey('required') ||
        value.containsKey('additionalProperties') ||
        value.containsKey('discriminator') ||
        value.containsKey('variants')) {
      throw const FormatException('object keywords require object type');
    }
    if (type == PatchbayResponseType.array) {
      items = PatchbayResponseValueSchema.fromJson(value['items']);
    } else if (value.containsKey('items')) {
      throw const FormatException('items requires array type');
    }
    return PatchbayResponseValueSchema(
      type: type,
      nullable: rawNullable as bool? ?? false,
      properties: Map<String, PatchbayResponseValueSchema>.unmodifiable(
        properties,
      ),
      required: Set<String>.unmodifiable(required),
      additionalProperties: additionalProperties,
      items: items,
      discriminator: discriminator,
      variants: Map<String, PatchbayResponseValueSchema>.unmodifiable(variants),
    );
  }
}

/// Accepted and job-terminal payload declarations for one command.
final class PatchbayResponseSchema {
  const PatchbayResponseSchema({
    required this.accepted,
    this.terminal = const {},
  });

  final PatchbayResponseValueSchema accepted;
  final Map<String, PatchbayResponseValueSchema> terminal;

  Map<String, Object?> toJson() => <String, Object?>{
    'accepted': accepted.toJson(),
    if (terminal.isNotEmpty)
      'terminal': <String, Object?>{
        for (final MapEntry<String, PatchbayResponseValueSchema> entry
            in terminal.entries)
          entry.key: entry.value.toJson(),
      },
  };

  factory PatchbayResponseSchema.fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('responseSchema must be an object');
    }
    if (value.keys.any(
      (Object? key) =>
          key is! String || (key != 'accepted' && key != 'terminal'),
    )) {
      throw const FormatException('unknown responseSchema keyword');
    }
    final PatchbayResponseValueSchema accepted =
        PatchbayResponseValueSchema.fromJson(value['accepted']);
    if (accepted.type != PatchbayResponseType.object) {
      throw const FormatException('accepted schema must be an object');
    }
    final Map<String, PatchbayResponseValueSchema> terminal =
        <String, PatchbayResponseValueSchema>{};
    final Object? rawTerminal = value['terminal'];
    if (rawTerminal != null) {
      if (rawTerminal is! Map<Object?, Object?>) {
        throw const FormatException('terminal must be an object');
      }
      const Set<String> phases = <String>{'completed', 'failed', 'cancelled'};
      for (final MapEntry<Object?, Object?> entry in rawTerminal.entries) {
        if (entry.key is! String || !phases.contains(entry.key)) {
          throw const FormatException('unknown terminal phase');
        }
        final PatchbayResponseValueSchema schema =
            PatchbayResponseValueSchema.fromJson(entry.value);
        if (schema.type != PatchbayResponseType.object) {
          throw const FormatException('terminal schema must be an object');
        }
        terminal[entry.key! as String] = schema;
      }
    }
    final PatchbayResponseSchema schema = PatchbayResponseSchema(
      accepted: accepted,
      terminal: Map<String, PatchbayResponseValueSchema>.unmodifiable(terminal),
    );
    _checkSchemaLimits(schema);
    return schema;
  }
}

/// One value-free validation issue safe to return to an untrusted caller.
final class PatchbayResponseValidationIssue {
  const PatchbayResponseValidationIssue({
    required this.field,
    required this.reason,
    this.expected,
  });

  final String field;
  final String reason;
  final String? expected;

  Map<String, Object?> toJson() => <String, Object?>{
    'field': field,
    'reason': reason,
    if (expected != null) 'expected': expected!,
  };
}

const int patchbayResponseSchemaMaxDepth = 12;
const int patchbayResponseSchemaMaxFields = 256;
const int patchbayResponseValidationMaxIssues = 20;

void validatePatchbayResponseSchema(PatchbayResponseSchema schema) =>
    _checkSchemaLimits(schema);

List<PatchbayResponseValidationIssue> validatePatchbayResponsePayload(
  PatchbayResponseValueSchema schema,
  Object? payload,
) {
  final List<PatchbayResponseValidationIssue> issues =
      <PatchbayResponseValidationIssue>[];
  _validateValue(schema, payload, r'$.payload', issues);
  return List<PatchbayResponseValidationIssue>.unmodifiable(issues);
}

void _checkSchemaLimits(PatchbayResponseSchema schema) {
  var fields = 0;
  void visit(PatchbayResponseValueSchema node, int depth) {
    if (depth > patchbayResponseSchemaMaxDepth) {
      throw ArgumentError('response schema exceeds depth limit');
    }
    fields += node.properties.length;
    if (fields > patchbayResponseSchemaMaxFields) {
      throw ArgumentError('response schema exceeds field limit');
    }
    if (node.type == PatchbayResponseType.object) {
      if (!node.properties.keys.toSet().containsAll(node.required)) {
        throw ArgumentError('response schema requires an undeclared field');
      }
      if ((node.discriminator == null) != node.variants.isEmpty) {
        throw ArgumentError('response schema variants need one discriminator');
      }
      if (node.discriminator case final String discriminator) {
        final PatchbayResponseValueSchema? declared =
            node.properties[discriminator];
        if (declared?.type != PatchbayResponseType.string ||
            declared!.nullable ||
            !node.required.contains(discriminator)) {
          throw ArgumentError(
            'response schema discriminator must be a required string field',
          );
        }
      }
      if (node.items != null) {
        throw ArgumentError('object response schema cannot declare items');
      }
    } else if (node.properties.isNotEmpty ||
        node.required.isNotEmpty ||
        node.discriminator != null ||
        node.variants.isNotEmpty ||
        node.additionalProperties) {
      throw ArgumentError('object response keywords require object type');
    }
    if (node.type == PatchbayResponseType.array && node.items == null) {
      throw ArgumentError('array response schema requires items');
    }
    if (node.type != PatchbayResponseType.array && node.items != null) {
      throw ArgumentError('response schema items require array type');
    }
    for (final PatchbayResponseValueSchema child in node.properties.values) {
      visit(child, depth + 1);
    }
    if (node.items case final PatchbayResponseValueSchema child) {
      visit(child, depth + 1);
    }
    for (final PatchbayResponseValueSchema variant in node.variants.values) {
      visit(variant, depth + 1);
    }
  }

  if (schema.accepted.type != PatchbayResponseType.object) {
    throw ArgumentError('accepted response schema must be an object');
  }
  visit(schema.accepted, 1);
  const Set<String> terminalPhases = <String>{
    'completed',
    'failed',
    'cancelled',
  };
  for (final MapEntry<String, PatchbayResponseValueSchema> entry
      in schema.terminal.entries) {
    if (!terminalPhases.contains(entry.key) ||
        entry.value.type != PatchbayResponseType.object) {
      throw ArgumentError('invalid terminal response schema');
    }
    final PatchbayResponseValueSchema terminal = entry.value;
    visit(terminal, 1);
  }
}

void _validateValue(
  PatchbayResponseValueSchema schema,
  Object? value,
  String path,
  List<PatchbayResponseValidationIssue> issues,
) {
  if (issues.length >= patchbayResponseValidationMaxIssues) return;
  if (value == null) {
    if (!schema.nullable) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: path,
          reason: 'unexpectedNull',
          expected: schema.type.name,
        ),
      );
    }
    return;
  }
  final bool rightType = switch (schema.type) {
    PatchbayResponseType.string => value is String,
    PatchbayResponseType.integer => value is int,
    PatchbayResponseType.number => value is num,
    PatchbayResponseType.boolean => value is bool,
    PatchbayResponseType.object => value is Map<Object?, Object?>,
    PatchbayResponseType.array => value is List<Object?>,
  };
  if (!rightType) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: path,
        reason: 'wrongType',
        expected: schema.type.name,
      ),
    );
    return;
  }
  if (schema.type == PatchbayResponseType.array) {
    final List<Object?> values = value as List<Object?>;
    for (
      var index = 0;
      index < values.length &&
          issues.length < patchbayResponseValidationMaxIssues;
      index += 1
    ) {
      _validateValue(schema.items!, values[index], '$path[$index]', issues);
    }
    return;
  }
  if (schema.type != PatchbayResponseType.object) return;
  final Map<Object?, Object?> object = value as Map<Object?, Object?>;
  PatchbayResponseValueSchema effective = schema;
  if (schema.discriminator case final String discriminator) {
    final Object? selected = object[discriminator];
    final PatchbayResponseValueSchema? variant = selected is String
        ? schema.variants[selected]
        : null;
    if (variant == null) {
      final List<String> expectedVariants = schema.variants.keys.toList()
        ..sort();
      issues.add(
        PatchbayResponseValidationIssue(
          field: '$path.$discriminator',
          reason: 'unknownVariant',
          expected: expectedVariants.join('|'),
        ),
      );
    } else {
      effective = _mergeObjectSchemas(schema, variant);
    }
  }
  final List<String> requiredFields = effective.required.toList()..sort();
  for (final String field in requiredFields) {
    if (!object.containsKey(field)) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: '$path.$field',
          reason: 'missingField',
        ),
      );
      if (issues.length >= patchbayResponseValidationMaxIssues) return;
    }
  }
  final List<MapEntry<Object?, Object?>> entries = object.entries.toList()
    ..sort((a, b) => '${a.key}'.compareTo('${b.key}'));
  for (final MapEntry<Object?, Object?> entry in entries) {
    if (issues.length >= patchbayResponseValidationMaxIssues) return;
    final String? field = entry.key is String ? entry.key! as String : null;
    final PatchbayResponseValueSchema? child = field == null
        ? null
        : effective.properties[field];
    if (child == null) {
      if (!effective.additionalProperties) {
        issues.add(
          PatchbayResponseValidationIssue(
            field: field == null ? path : '$path.$field',
            reason: 'unknownField',
          ),
        );
      }
      continue;
    }
    _validateValue(child, entry.value, '$path.$field', issues);
  }
}

PatchbayResponseValueSchema _mergeObjectSchemas(
  PatchbayResponseValueSchema base,
  PatchbayResponseValueSchema variant,
) => PatchbayResponseValueSchema(
  type: PatchbayResponseType.object,
  nullable: base.nullable,
  properties: <String, PatchbayResponseValueSchema>{
    ...base.properties,
    ...variant.properties,
  },
  required: <String>{...base.required, ...variant.required},
  additionalProperties:
      base.additionalProperties || variant.additionalProperties,
);
