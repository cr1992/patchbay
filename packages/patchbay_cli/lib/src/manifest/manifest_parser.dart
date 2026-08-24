import 'dart:collection';
import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:yaml/yaml.dart';

import 'manifest_models.dart';

abstract final class ManifestParser {
  static PatchbayUiManifest parseSource(
    String source, {
    required PatchbayUiManifestFormat format,
  }) {
    refuseSourceOverBudget(source);
    final Object? document = switch (format) {
      PatchbayUiManifestFormat.json => decodeJson(source),
      PatchbayUiManifestFormat.yaml => decodeYaml(source),
    };
    if (document is! Map<String, Object?>) {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'the manifest root must be an object',
          'field': r'$',
        },
      );
    }
    return switch (document['version']) {
      2 => parseV2(document),
      null || 1 => parseV1(document),
      final Object version => throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'unsupported manifest version: $version',
          'field': r'$.version',
        },
      ),
    };
  }

  static PatchbayUiManifest parseV1(Map<String, Object?> document) {
    refuseUnknownKeys(document, const <String>{'version', 'targets'}, r'$');
    final Object? targets = document['targets'];
    if (targets is! List<Object?>) {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'targets must be a JSON array',
          'field': r'$.targets',
        },
      );
    }
    refuseLimit(
      targets.length > patchbayUiManifestMaximumTargets,
      reason: 'manifest target limit exceeded',
      field: r'$.targets',
      limit: patchbayUiManifestMaximumTargets,
    );
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
    for (var index = 0; index < targets.length; index += 1) {
      entries.add(v1Entry(targets[index], targetField(index)));
    }
    refuseV1DestinationLimits(entries);
    refuseConflictingIds(<ManifestIdentity>[
      for (var index = 0; index < entries.length; index += 1)
        (
          id: entries[index].id,
          destination: entries[index].destination,
          namespace: PatchbayUiManifestNamespace.catalogTarget,
          field: targetField(index),
        ),
    ]);
    return PatchbayUiManifest(
      List<PatchbayUiManifestEntry>.unmodifiable(entries),
      destinations: List<String>.unmodifiable(<String>{
        for (final PatchbayUiManifestEntry entry in entries)
          if (entry.destination case final String destination) destination,
      }),
    );
  }

  static PatchbayUiManifest parseV2(Map<String, Object?> document) {
    refuseUnknownKeys(document, const <String>{
      'version',
      'coverage',
      'destinations',
    }, r'$');
    if (document['coverage'] != patchbayUiManifestMountedCoverage) {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'coverage must be mountedOnly',
          'field': r'$.coverage',
        },
      );
    }
    final Object? destinations = document['destinations'];
    if (destinations is! List<Object?>) {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'destinations must be a JSON array',
          'field': r'$.destinations',
        },
      );
    }
    refuseLimit(
      destinations.length > patchbayUiManifestMaximumDestinations,
      reason: 'manifest destination limit exceeded',
      field: r'$.destinations',
      limit: patchbayUiManifestMaximumDestinations,
    );
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
    final List<PatchbayUiManifestSemanticsEntry> semanticsEntries =
        <PatchbayUiManifestSemanticsEntry>[];
    final List<ManifestIdentity> identities = <ManifestIdentity>[];
    final Set<String> destinationIds = <String>{};
    for (
      var destinationIndex = 0;
      destinationIndex < destinations.length;
      destinationIndex += 1
    ) {
      final String field = '\$.destinations[$destinationIndex]';
      final Object? value = destinations[destinationIndex];
      if (value is! Map<String, Object?>) {
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason': 'every destination must be a JSON object',
            'field': field,
          },
        );
      }
      refuseUnknownKeys(value, const <String>{'id', 'targets'}, field);
      final String destination = requiredText(value['id'], '$field.id');
      if (!destinationIds.add(destination)) {
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason': 'destination ids must be unique',
            'field': '$field.id',
            'id': destination,
          },
        );
      }
      final Object? targets = value['targets'];
      if (targets is! List<Object?>) {
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason': 'targets must be a JSON array',
            'field': '$field.targets',
          },
        );
      }
      refuseLimit(
        targets.length > patchbayUiManifestMaximumTargetsPerDestination,
        reason: 'manifest per-destination target limit exceeded',
        field: '$field.targets',
        limit: patchbayUiManifestMaximumTargetsPerDestination,
      );
      refuseLimit(
        entries.length + semanticsEntries.length + targets.length >
            patchbayUiManifestMaximumTargets,
        reason: 'manifest target limit exceeded',
        field: '$field.targets',
        limit: patchbayUiManifestMaximumTargets,
      );
      for (
        var targetIndex = 0;
        targetIndex < targets.length;
        targetIndex += 1
      ) {
        final ManifestV2Entry entry = v2Entry(
          targets[targetIndex],
          '$field.targets[$targetIndex]',
          destination,
        );
        if (entry.catalog case final PatchbayUiManifestEntry catalog) {
          entries.add(catalog);
          identities.add((
            id: catalog.id,
            destination: catalog.destination,
            namespace: PatchbayUiManifestNamespace.catalogTarget,
            field: '$field.targets[$targetIndex]',
          ));
        }
        if (entry.semantics
            case final PatchbayUiManifestSemanticsEntry semantics) {
          semanticsEntries.add(semantics);
          identities.add((
            id: semantics.id,
            destination: semantics.destination,
            namespace: PatchbayUiManifestNamespace.semanticsIdentifier,
            field: '$field.targets[$targetIndex]',
          ));
        }
      }
    }
    refuseConflictingIds(identities);
    return PatchbayUiManifest(
      List<PatchbayUiManifestEntry>.unmodifiable(entries),
      semanticsEntries: List<PatchbayUiManifestSemanticsEntry>.unmodifiable(
        semanticsEntries,
      ),
      destinations: List<String>.unmodifiable(destinationIds),
    );
  }

  static Object? decodeJson(String source) {
    try {
      return ManifestDocumentNormalizer().fromJson(jsonDecode(source));
    } on FormatException catch (failure) {
      final ({int line, int column}) location = jsonLocation(
        source,
        failure.offset,
      );
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'the file is not valid JSON',
          'line': location.line,
          'column': location.column,
        },
      );
    }
  }

  static Object? decodeYaml(String source) {
    preflightYaml(source);
    try {
      return ManifestDocumentNormalizer().fromYaml(loadYamlNode(source));
    } on YamlException catch (failure) {
      final int line = (failure.span?.start.line ?? 0) + 1;
      final int column = (failure.span?.start.column ?? 0) + 1;
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': failure.message == 'Duplicate mapping key.'
              ? 'YAML mapping keys must be unique'
              : 'the file is not valid safe YAML',
          'line': line,
          'column': column,
        },
      );
    }
  }

  static void preflightYaml(String source) {
    final List<String> lines = const LineSplitter().convert(source);
    final List<int> indentationStack = <int>[];
    var flowDepth = 0;
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
      final String line = lines[lineIndex];
      final int firstContent = line.length - line.trimLeft().length;
      final String trimmed = line.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      while (indentationStack.isNotEmpty &&
          indentationStack.last > firstContent) {
        indentationStack.removeLast();
      }
      if (indentationStack.isEmpty || indentationStack.last < firstContent) {
        indentationStack.add(firstContent);
      }
      var singleQuoted = false;
      var doubleQuoted = false;
      var escaped = false;
      var blockSequenceDepth = 0;
      for (var columnIndex = 0; columnIndex < line.length; columnIndex += 1) {
        final String character = line[columnIndex];
        if (doubleQuoted) {
          if (escaped) {
            escaped = false;
          } else if (character == r'\') {
            escaped = true;
          } else if (character == '"') {
            doubleQuoted = false;
          }
          continue;
        }
        if (singleQuoted) {
          if (character == "'" &&
              columnIndex + 1 < line.length &&
              line[columnIndex + 1] == "'") {
            columnIndex += 1;
          } else if (character == "'") {
            singleQuoted = false;
          }
          continue;
        }
        if (character == '#') break;
        if (character == '"') {
          doubleQuoted = true;
          continue;
        }
        if (character == "'") {
          singleQuoted = true;
          continue;
        }
        if (character == '[' || character == '{') {
          flowDepth += 1;
        } else if (character == ']' || character == '}') {
          flowDepth -= 1;
        } else if (character == '-' &&
            (columnIndex == firstContent ||
                RegExp(r'\s').hasMatch(line[columnIndex - 1])) &&
            columnIndex + 1 < line.length &&
            RegExp(r'\s').hasMatch(line[columnIndex + 1])) {
          blockSequenceDepth += 1;
        }
        final int estimatedDepth =
            indentationStack.length + flowDepth + blockSequenceDepth;
        if (estimatedDepth > patchbayUiManifestMaximumDepth) {
          throw PatchbayUiManifestException(
            'manifestResourceLimit',
            details: <String, Object?>{
              'reason': 'manifest depth limit exceeded',
              'limit': patchbayUiManifestMaximumDepth,
              'line': lineIndex + 1,
              'column': columnIndex + 1,
            },
          );
        }
        if (character != '!') continue;
        final String? previous = columnIndex == 0
            ? null
            : line[columnIndex - 1];
        if (previous != null &&
            !RegExp(r'[\s\[\]{},:?\-]').hasMatch(previous)) {
          continue;
        }
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason': 'explicit YAML tags are not supported',
            'line': lineIndex + 1,
            'column': columnIndex + 1,
          },
        );
      }
    }
  }

  static void refuseSourceOverBudget(String source) {
    final int bytes = utf8.encode(source).length;
    if (bytes <= patchbayUiManifestMaximumBytes) return;
    throw PatchbayUiManifestException(
      'manifestResourceLimit',
      details: <String, Object?>{
        'reason': 'manifest byte limit exceeded',
        'limit': patchbayUiManifestMaximumBytes,
      },
    );
  }

  static ({int line, int column}) jsonLocation(String source, int? offset) {
    final int end = (offset ?? 0).clamp(0, source.length);
    var line = 1;
    var column = 1;
    for (var index = 0; index < end; index += 1) {
      if (source.codeUnitAt(index) == 0x0a) {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }
    return (line: line, column: column);
  }

  static String targetField(int index) => '\$.targets[$index]';

  static String get kindVocabulary => PatchbayUiTargetKindWire.values
      .map((PatchbayUiTargetKindWire value) => value.name)
      .join(', ');

  static PatchbayUiManifestEntry v1Entry(Object? value, String field) {
    if (value is! Map<String, Object?>) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'every target must be a JSON object',
          'field': field,
        },
      );
    }
    refuseUnknownKeys(value, const <String>{
      'id',
      'kind',
      'sensitive',
      'destination',
    }, field);
    final String id = requiredText(value['id'], '$field.id');
    final Object? kind = value['kind'];
    if (kind == null) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'kind is required',
          'field': '$field.kind',
        },
      );
    }
    final PatchbayUiTargetKindWire decoded;
    try {
      decoded = PatchbayUiTargetKindWire.fromJson(kind);
    } on FormatException {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'kind must be one of $kindVocabulary',
          'field': '$field.kind',
        },
      );
    }
    final Object? sensitive = value['sensitive'];
    if (sensitive != null && sensitive is! bool) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'sensitive must be a boolean',
          'field': '$field.sensitive',
        },
      );
    }
    return PatchbayUiManifestEntry(
      id: id,
      kind: decoded,
      sensitive: sensitive == true,
      destination: value['destination'] == null
          ? null
          : requiredText(value['destination'], '$field.destination'),
    );
  }

  static ManifestV2Entry v2Entry(
    Object? value,
    String field,
    String destination,
  ) {
    if (value is! Map<String, Object?>) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'every target must be a JSON object',
          'field': field,
        },
      );
    }
    refuseUnknownKeys(value, const <String>{
      'namespace',
      'id',
      'kind',
      'sensitive',
    }, field);
    final PatchbayUiManifestNamespace? namespace =
        PatchbayUiManifestNamespace.tryParse(value['namespace']);
    if (namespace == null) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'namespace must be catalogTarget or semanticsIdentifier',
          'field': '$field.namespace',
        },
      );
    }
    if (namespace == PatchbayUiManifestNamespace.catalogTarget) {
      return (
        catalog: v1Entry(<String, Object?>{
          'id': value['id'],
          'kind': value['kind'],
          'sensitive': value['sensitive'],
          'destination': destination,
        }, field),
        semantics: null,
      );
    }
    if (value.containsKey('kind') || value.containsKey('sensitive')) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason':
              'kind and sensitive are only valid for catalogTarget entries',
          'field': field,
        },
      );
    }
    return (
      catalog: null,
      semantics: PatchbayUiManifestSemanticsEntry(
        id: requiredText(value['id'], '$field.id'),
        destination: destination,
      ),
    );
  }

  static String requiredText(Object? value, String field) {
    if (value is! String || value.isEmpty) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': '${field.split('.').last} must be a non-empty string',
          'field': field,
        },
      );
    }
    return value;
  }

  static void refuseUnknownKeys(
    Map<String, Object?> value,
    Set<String> declared,
    String field,
  ) {
    final List<String> unexpected =
        value.keys.where((String key) => !declared.contains(key)).toList()
          ..sort();
    if (unexpected.isEmpty) return;
    throw PatchbayUiManifestException(
      'manifestInvalid',
      details: <String, Object?>{
        'reason': 'the manifest declares no such key',
        'field': field,
        'unexpected': unexpected,
      },
    );
  }

  static void refuseConflictingIds(List<ManifestIdentity> entries) {
    final Map<String, Set<String?>> seen = <String, Set<String?>>{};
    final Map<String, PatchbayUiManifestNamespace> namespaces =
        <String, PatchbayUiManifestNamespace>{};
    for (var index = 0; index < entries.length; index += 1) {
      final ManifestIdentity entry = entries[index];
      final PatchbayUiManifestNamespace? existingNamespace =
          namespaces[entry.id];
      if (existingNamespace != null && existingNamespace != entry.namespace) {
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason': 'a target id cannot cross manifest namespaces',
            'field': '${entry.field}.namespace',
            'id': entry.id,
          },
        );
      }
      namespaces[entry.id] = entry.namespace;
      final Set<String?> destinations = seen.putIfAbsent(
        entry.id,
        () => <String?>{},
      );
      final bool conflicts =
          destinations.isNotEmpty &&
          (entry.destination == null ||
              destinations.contains(null) ||
              destinations.contains(entry.destination));
      if (conflicts) {
        throw PatchbayUiManifestException(
          'manifestInvalid',
          details: <String, Object?>{
            'reason':
                'a repeated target id must declare a distinct destination on '
                'every entry',
            'field': '${entry.field}.id',
            'id': entry.id,
          },
        );
      }
      destinations.add(entry.destination);
    }
  }

  static void refuseV1DestinationLimits(List<PatchbayUiManifestEntry> entries) {
    final Map<String?, int> counts = <String?, int>{};
    for (var index = 0; index < entries.length; index += 1) {
      final PatchbayUiManifestEntry entry = entries[index];
      final int count = (counts[entry.destination] ?? 0) + 1;
      counts[entry.destination] = count;
      refuseLimit(
        count > patchbayUiManifestMaximumTargetsPerDestination,
        reason: 'manifest per-destination target limit exceeded',
        field: targetField(index),
        limit: patchbayUiManifestMaximumTargetsPerDestination,
      );
    }
  }

  static void refuseLimit(
    bool exceeded, {
    required String reason,
    required String field,
    required int limit,
  }) {
    if (!exceeded) return;
    throw PatchbayUiManifestException(
      'manifestResourceLimit',
      details: <String, Object?>{
        'reason': reason,
        'field': field,
        'limit': limit,
      },
    );
  }
}

/// Converts JSON/YAML into the same JSON-domain tree under shared budgets.
final class ManifestDocumentNormalizer {
  final Set<YamlNode> _yamlNodes = HashSet<YamlNode>.identity();
  var _nodes = 0;

  Object? fromJson(Object? value) => _normalizeJson(value, depth: 1);

  Object? fromYaml(YamlNode node) => _normalizeYaml(node, depth: 1);

  Object? _normalizeJson(Object? value, {required int depth}) {
    _count(depth, line: null, column: null);
    if (value == null || value is bool || value is String || value is int) {
      return value;
    }
    if (value is double && value.isFinite) return value;
    if (value is List<Object?>) {
      return <Object?>[
        for (final Object? child in value)
          _normalizeJson(child, depth: depth + 1),
      ];
    }
    if (value is Map<String, Object?>) {
      final Map<String, Object?> result = <String, Object?>{};
      for (final MapEntry<String, Object?> entry in value.entries) {
        _count(depth + 1, line: null, column: null);
        result[entry.key] = _normalizeJson(entry.value, depth: depth + 1);
      }
      return result;
    }
    throw const PatchbayUiManifestException(
      'manifestInvalid',
      details: <String, Object?>{
        'reason': 'the manifest contains a non-JSON value',
      },
    );
  }

  Object? _normalizeYaml(YamlNode node, {required int depth}) {
    final int line = node.span.start.line + 1;
    final int column = node.span.start.column + 1;
    if (!_yamlNodes.add(node)) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'YAML aliases are not supported',
          'line': line,
          'column': column,
        },
      );
    }
    _count(depth, line: line, column: column);
    if (node is YamlScalar) {
      final Object? value = node.value;
      if (value == null || value is bool || value is String || value is int) {
        return value;
      }
      if (value is double && value.isFinite) return value;
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'the manifest contains a non-JSON scalar',
          'line': line,
          'column': column,
        },
      );
    }
    if (node is YamlList) {
      return <Object?>[
        for (final YamlNode child in node.nodes)
          _normalizeYaml(child, depth: depth + 1),
      ];
    }
    if (node is YamlMap) {
      final Map<String, Object?> result = <String, Object?>{};
      for (final MapEntry<dynamic, YamlNode> entry in node.nodes.entries) {
        final YamlNode key = entry.key as YamlNode;
        _count(
          depth + 1,
          line: key.span.start.line + 1,
          column: key.span.start.column + 1,
        );
        if (!_yamlNodes.add(key)) {
          throw PatchbayUiManifestException(
            'manifestInvalid',
            details: <String, Object?>{
              'reason': 'YAML aliases are not supported',
              'line': key.span.start.line + 1,
              'column': key.span.start.column + 1,
            },
          );
        }
        final Object? rawKey = key.value;
        if (rawKey is! String) {
          throw PatchbayUiManifestException(
            'manifestInvalid',
            details: <String, Object?>{
              'reason': 'YAML mapping keys must be strings',
              'line': key.span.start.line + 1,
              'column': key.span.start.column + 1,
            },
          );
        }
        if (result.containsKey(rawKey)) {
          throw PatchbayUiManifestException(
            'manifestInvalid',
            details: <String, Object?>{
              'reason': 'YAML mapping keys must be unique',
              'line': key.span.start.line + 1,
              'column': key.span.start.column + 1,
            },
          );
        }
        result[rawKey] = _normalizeYaml(entry.value, depth: depth + 1);
      }
      return result;
    }
    throw PatchbayUiManifestException(
      'manifestInvalid',
      details: <String, Object?>{
        'reason': 'the manifest contains an unsupported YAML node',
        'line': line,
        'column': column,
      },
    );
  }

  void _count(int depth, {required int? line, required int? column}) {
    if (depth > patchbayUiManifestMaximumDepth) {
      throw PatchbayUiManifestException(
        'manifestResourceLimit',
        details: <String, Object?>{
          'reason': 'manifest depth limit exceeded',
          'limit': patchbayUiManifestMaximumDepth,
          if (line != null) 'line': line,
          if (column != null) 'column': column,
        },
      );
    }
    _nodes += 1;
    if (_nodes <= patchbayUiManifestMaximumNodes) return;
    throw PatchbayUiManifestException(
      'manifestResourceLimit',
      details: <String, Object?>{
        'reason': 'manifest node limit exceeded',
        'limit': patchbayUiManifestMaximumNodes,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
      },
    );
  }
}
