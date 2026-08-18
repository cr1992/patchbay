import 'dart:collection';
import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:yaml/yaml.dart';

import 'client.dart';

/// A manifest the CLI refused to read.
///
/// A manifest is caller input, so a bare "invalid" would send its author back to
/// bisect their own file. Every failure therefore names itself with a stable
/// [code], says which rule was broken (`details.reason`) and where
/// (`details.field`, a JSON path into the manifest). Target IDs may travel: they
/// are protocol vocabulary published in the catalog, exactly like the parameter
/// names an `invalidUiArguments` rejection names. Nothing else from the file
/// does.
final class PatchbayUiManifestException implements Exception {
  const PatchbayUiManifestException(
    this.code, {
    this.details = const <String, Object?>{},
  });

  final String code;
  final Map<String, Object?> details;

  /// The stderr sentence: the code names the class, the details locate it.
  String get sentence {
    final StringBuffer buffer = StringBuffer('patchbay manifest error: $code');
    if (details['reason'] case final String reason) buffer.write('\n  $reason');
    if (details['field'] case final String field) buffer.write('\n  at $field');
    if ((details['line'], details['column']) case (
      final int line,
      final int column,
    )) {
      buffer.write('\n  at line $line, column $column');
    }
    return buffer.toString();
  }
}

/// The only file formats `ui verify-manifest` selects by extension.
enum PatchbayUiManifestFormat { json, yaml }

/// Manifest parsing budgets apply before schema validation for both formats.
const int patchbayUiManifestMaximumBytes = 1024 * 1024;
const int patchbayUiManifestMaximumDepth = 64;
const int patchbayUiManifestMaximumNodes = 200000;
const int patchbayUiManifestMaximumDestinations = 100;
const int patchbayUiManifestMaximumTargetsPerDestination = 1000;
const int patchbayUiManifestMaximumTargets = 10000;
const int patchbayUiManifestMaximumSemanticsNodes = 10000;

/// A manifest-local namespace, deliberately separate from the strict wire
/// enum that describes catalog target kinds.
enum PatchbayUiManifestNamespace {
  catalogTarget,
  semanticsIdentifier;

  static PatchbayUiManifestNamespace? tryParse(Object? value) {
    for (final PatchbayUiManifestNamespace candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

typedef _ManifestV2Entry = ({
  PatchbayUiManifestEntry? catalog,
  PatchbayUiManifestSemanticsEntry? semantics,
});

typedef _ManifestIdentity = ({
  String id,
  String? destination,
  PatchbayUiManifestNamespace namespace,
  String field,
});

/// One declared UI target: what the consumer says the running App should carry.
///
/// The vocabulary is the catalog's, not a second one invented here. [kind] is
/// the same `PatchbayUiTargetKindWire` a catalog row publishes and is decoded by
/// that enum, so the accepted words cannot drift from the protocol. [sensitive]
/// is the boolean form of `sensitivePolicy` (`redacted` ⇔ `true`).
final class PatchbayUiManifestEntry {
  const PatchbayUiManifestEntry({
    required this.id,
    required this.kind,
    required this.sensitive,
    this.destination,
  });

  final String id;
  final PatchbayUiTargetKindWire kind;
  final bool sensitive;

  /// The destination this declaration belongs to, when it is not App-wide.
  ///
  /// In v1 this is a filter and nothing more: an entry scoped to a destination
  /// is only reconciled while the App is actually on it. Driving navigation to
  /// sweep every screen is a separate feature, not something this command does
  /// behind the operator's back.
  final String? destination;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.toJson(),
    'sensitive': sensitive,
    'destination': ?destination,
  };
}

/// One v2 Semantics identifier declaration. It is intentionally not a
/// `PatchbayUiManifestEntry`: keeping the published catalog entry shape intact
/// prevents a local namespace addition from making its non-null wire kind
/// nullable for existing callers.
final class PatchbayUiManifestSemanticsEntry {
  const PatchbayUiManifestSemanticsEntry({
    required this.id,
    required this.destination,
  });

  final String id;
  final String destination;

  Map<String, Object?> toJson() => <String, Object?>{
    'namespace': PatchbayUiManifestNamespace.semanticsIdentifier.name,
    'id': id,
    'destination': destination,
  };
}

/// A parsed `ui verify-manifest` input file.
final class PatchbayUiManifest {
  const PatchbayUiManifest(
    this.entries, {
    this.semanticsEntries = const <PatchbayUiManifestSemanticsEntry>[],
  });

  /// Reads one manifest document, fail-closed.
  ///
  /// Every rule below refuses rather than repairs. A manifest exists to be
  /// compared against a runtime, so a file this parser had to guess about would
  /// produce a verdict about something the author never wrote.
  factory PatchbayUiManifest.parse(String source) =>
      PatchbayUiManifest.parseSource(
        source,
        format: PatchbayUiManifestFormat.json,
      );

  /// Parses one explicitly selected input format into the shared model.
  factory PatchbayUiManifest.parseSource(
    String source, {
    required PatchbayUiManifestFormat format,
  }) {
    _refuseSourceOverBudget(source);
    final Object? document;
    document = switch (format) {
      PatchbayUiManifestFormat.json => _decodeJson(source),
      PatchbayUiManifestFormat.yaml => _decodeYaml(source),
    };
    if (document is! Map<String, Object?>) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: const <String, Object?>{
          'reason': 'the manifest root must be an object',
          'field': r'$',
        },
      );
    }
    return switch (document['version']) {
      2 => _parseV2(document),
      null || 1 => _parseV1(document),
      final Object version => throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'unsupported manifest version: $version',
          'field': r'$.version',
        },
      ),
    };
  }

  static PatchbayUiManifest _parseV1(Map<String, Object?> document) {
    _refuseUnknownKeys(document, const <String>{'version', 'targets'}, r'$');
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
    _refuseLimit(
      targets.length > patchbayUiManifestMaximumTargets,
      reason: 'manifest target limit exceeded',
      field: r'$.targets',
      limit: patchbayUiManifestMaximumTargets,
    );
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
    for (var index = 0; index < targets.length; index += 1) {
      entries.add(_v1Entry(targets[index], _targetField(index)));
    }
    _refuseV1DestinationLimits(entries);
    _refuseConflictingIds(<_ManifestIdentity>[
      for (var index = 0; index < entries.length; index += 1)
        (
          id: entries[index].id,
          destination: entries[index].destination,
          namespace: PatchbayUiManifestNamespace.catalogTarget,
          field: _targetField(index),
        ),
    ]);
    return PatchbayUiManifest(
      List<PatchbayUiManifestEntry>.unmodifiable(entries),
    );
  }

  static PatchbayUiManifest _parseV2(Map<String, Object?> document) {
    _refuseUnknownKeys(document, const <String>{
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
    _refuseLimit(
      destinations.length > patchbayUiManifestMaximumDestinations,
      reason: 'manifest destination limit exceeded',
      field: r'$.destinations',
      limit: patchbayUiManifestMaximumDestinations,
    );
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
    final List<PatchbayUiManifestSemanticsEntry> semanticsEntries =
        <PatchbayUiManifestSemanticsEntry>[];
    final List<_ManifestIdentity> identities = <_ManifestIdentity>[];
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
      _refuseUnknownKeys(value, const <String>{'id', 'targets'}, field);
      final String destination = _requiredText(value['id'], '$field.id');
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
      _refuseLimit(
        targets.length > patchbayUiManifestMaximumTargetsPerDestination,
        reason: 'manifest per-destination target limit exceeded',
        field: '$field.targets',
        limit: patchbayUiManifestMaximumTargetsPerDestination,
      );
      _refuseLimit(
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
        final _ManifestV2Entry entry = _v2Entry(
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
    _refuseConflictingIds(identities);
    return PatchbayUiManifest(
      List<PatchbayUiManifestEntry>.unmodifiable(entries),
      semanticsEntries: List<PatchbayUiManifestSemanticsEntry>.unmodifiable(
        semanticsEntries,
      ),
    );
  }

  final List<PatchbayUiManifestEntry> entries;
  final List<PatchbayUiManifestSemanticsEntry> semanticsEntries;

  static Object? _decodeJson(String source) {
    try {
      return _ManifestDocumentNormalizer().fromJson(jsonDecode(source));
    } on FormatException catch (failure) {
      final ({int line, int column}) location = _jsonLocation(
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

  static Object? _decodeYaml(String source) {
    _preflightYaml(source);
    try {
      return _ManifestDocumentNormalizer().fromYaml(loadYamlNode(source));
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

  static void _preflightYaml(String source) {
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

  static void _refuseSourceOverBudget(String source) {
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

  static ({int line, int column}) _jsonLocation(String source, int? offset) {
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

  /// Whether any entry scopes itself to a destination.
  ///
  /// This is what decides whether the command reads `navigation.current` at
  /// all: a manifest that never mentions a destination has nothing to filter,
  /// and asking the App for its current screen anyway would make an unrelated
  /// gate able to fail a verification that does not depend on it.
  bool get usesDestinations =>
      entries.any(
        (PatchbayUiManifestEntry entry) => entry.destination != null,
      ) ||
      semanticsEntries.isNotEmpty;

  /// Whether the currently in-scope declarations require one live Semantics
  /// snapshot. Out-of-scope identifiers do not make an unrelated screen
  /// depend on the Semantics capability.
  bool requiresSemanticsAt(String? destination) => semanticsEntries.any(
    (PatchbayUiManifestSemanticsEntry entry) =>
        entry.destination == destination,
  );

  /// Where in the document one target sits, in the same JSON-path notation the
  /// wire decoders use for their own field errors.
  static String _targetField(int index) => '\$.targets[$index]';

  /// The `kind` words this CLI accepts, taken from the catalog's own enum.
  static String get _kindVocabulary => PatchbayUiTargetKindWire.values
      .map((PatchbayUiTargetKindWire value) => value.name)
      .join(', ');

  static PatchbayUiManifestEntry _v1Entry(Object? value, String field) {
    if (value is! Map<String, Object?>) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'every target must be a JSON object',
          'field': field,
        },
      );
    }
    _refuseUnknownKeys(value, const <String>{
      'id',
      'kind',
      'sensitive',
      'destination',
    }, field);
    final String id = _requiredText(value['id'], '$field.id');
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
      // Decoded by the catalog's own enum: the accepted words are the ones a
      // catalog row can actually publish, never a second list maintained here.
      decoded = PatchbayUiTargetKindWire.fromJson(kind);
    } on FormatException {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'kind must be one of $_kindVocabulary',
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
          : _requiredText(value['destination'], '$field.destination'),
    );
  }

  static _ManifestV2Entry _v2Entry(
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
    _refuseUnknownKeys(value, const <String>{
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
        catalog: _v1Entry(<String, Object?>{
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
        id: _requiredText(value['id'], '$field.id'),
        destination: destination,
      ),
    );
  }

  static String _requiredText(Object? value, String field) {
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

  static void _refuseUnknownKeys(
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

  /// Refuses a manifest that could put two declarations on one ID at once.
  ///
  /// The same ID may legitimately appear more than once — one control can exist
  /// on several screens — but only if every occurrence names a distinct
  /// destination. Otherwise two entries would be in scope simultaneously and a
  /// single runtime target would be reconciled against both, so the manifest
  /// would decide its own verdict by ordering.
  static void _refuseConflictingIds(List<_ManifestIdentity> entries) {
    final Map<String, Set<String?>> seen = <String, Set<String?>>{};
    final Map<String, PatchbayUiManifestNamespace> namespaces =
        <String, PatchbayUiManifestNamespace>{};
    for (var index = 0; index < entries.length; index += 1) {
      final _ManifestIdentity entry = entries[index];
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

  static void _refuseV1DestinationLimits(
    List<PatchbayUiManifestEntry> entries,
  ) {
    final Map<String?, int> counts = <String?, int>{};
    for (var index = 0; index < entries.length; index += 1) {
      final PatchbayUiManifestEntry entry = entries[index];
      final int count = (counts[entry.destination] ?? 0) + 1;
      counts[entry.destination] = count;
      _refuseLimit(
        count > patchbayUiManifestMaximumTargetsPerDestination,
        reason: 'manifest per-destination target limit exceeded',
        field: _targetField(index),
        limit: patchbayUiManifestMaximumTargetsPerDestination,
      );
    }
  }

  static void _refuseLimit(
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
final class _ManifestDocumentNormalizer {
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

/// One attached Semantics node carrying a stable identifier.
final class PatchbayUiManifestSemanticsMatch {
  const PatchbayUiManifestSemanticsMatch({
    required this.id,
    required this.nodeId,
    required this.generation,
  });

  final String id;
  final int nodeId;
  final int generation;

  Map<String, Object?> toJson() => <String, Object?>{
    'nodeId': nodeId,
    'generation': generation,
  };
}

/// The bounded, complete Semantics fact set used by manifest reconciliation.
final class PatchbayUiManifestSemanticsRuntime {
  const PatchbayUiManifestSemanticsRuntime({
    required this.treeRevision,
    required this.factSource,
    required this.byIdentifier,
  });

  final int treeRevision;
  final String factSource;
  final Map<String, List<PatchbayUiManifestSemanticsMatch>> byIdentifier;

  Iterable<String> get identifiers => byIdentifier.keys;
}

/// Decodes an accepted `ui.semantics.tree` payload through the existing strict
/// wire model. A truncated tree cannot prove absence or completeness, so it is
/// refused rather than used for a partial verdict.
PatchbayUiManifestSemanticsRuntime decodePatchbayManifestSemantics(
  Map<String, Object?> payload,
) {
  final PatchbaySemanticsSnapshotWire snapshot;
  try {
    snapshot = PatchbaySemanticsSnapshotWire.fromJson(payload);
  } on FormatException catch (failure) {
    throw PatchbayProtocolException(
      'manifestSemanticsContractViolated',
      details: <String, Object?>{'reason': failure.message},
    );
  }
  if (snapshot.outcome != 'observed') {
    throw PatchbayProtocolException(
      'manifestSemanticsContractViolated',
      details: <String, Object?>{
        'reason': 'ui.semantics.tree outcome must be observed',
      },
    );
  }
  if (snapshot.nodeCount != snapshot.nodes.length) {
    throw const PatchbayProtocolException(
      'manifestSemanticsContractViolated',
      details: <String, Object?>{
        'reason': 'ui.semantics.tree nodeCount does not match nodes',
      },
    );
  }
  if (snapshot.nodes.length > patchbayUiManifestMaximumSemanticsNodes) {
    throw const PatchbayProtocolException(
      'manifestSemanticsResourceLimit',
      details: <String, Object?>{
        'reason': 'ui.semantics.tree exceeds the manifest node budget',
        'limit': patchbayUiManifestMaximumSemanticsNodes,
      },
    );
  }
  if (snapshot.truncated) {
    throw const PatchbayProtocolException(
      'manifestSemanticsTreeTruncated',
      details: <String, Object?>{
        'reason': 'a truncated Semantics tree cannot prove identifier absence',
      },
    );
  }
  final Map<String, List<PatchbayUiManifestSemanticsMatch>> byIdentifier =
      <String, List<PatchbayUiManifestSemanticsMatch>>{};
  final Set<int> nodeIds = <int>{};
  for (final PatchbaySemanticsNodeWire node in snapshot.nodes) {
    if (!nodeIds.add(node.nodeId) || node.generation < 0) {
      throw const PatchbayProtocolException(
        'manifestSemanticsContractViolated',
        details: <String, Object?>{
          'reason':
              'ui.semantics.tree node ids must be unique and generations '
              'must be non-negative',
        },
      );
    }
    if (node.identifier.isEmpty) continue;
    byIdentifier
        .putIfAbsent(
          node.identifier,
          () => <PatchbayUiManifestSemanticsMatch>[],
        )
        .add(
          PatchbayUiManifestSemanticsMatch(
            id: node.identifier,
            nodeId: node.nodeId,
            generation: node.generation,
          ),
        );
  }
  return PatchbayUiManifestSemanticsRuntime(
    treeRevision: snapshot.treeRevision,
    factSource: snapshot.source.toJson(),
    byIdentifier: <String, List<PatchbayUiManifestSemanticsMatch>>{
      for (final MapEntry<String, List<PatchbayUiManifestSemanticsMatch>> entry
          in (byIdentifier.entries.toList()
            ..sort((left, right) => left.key.compareTo(right.key))))
        entry.key: List<PatchbayUiManifestSemanticsMatch>.unmodifiable(
          entry.value
            ..sort((left, right) => left.nodeId.compareTo(right.nodeId)),
        ),
    },
  );
}

/// One declared target the runtime is not currently carrying.
///
/// [registered] separates the two ways that happens: the catalog knows the ID
/// but nothing is mounted right now (`true`), or the catalog has never heard of
/// it (`false`). The first is ordinary for a control that lives on another
/// screen; the second is the one that usually means a missing annotation.
typedef PatchbayUiManifestAbsence = ({
  PatchbayUiManifestEntry declared,
  bool registered,
});

/// One declared target whose runtime row contradicts the declaration.
typedef PatchbayUiManifestDrift = ({
  PatchbayUiManifestEntry declared,
  PatchbayUiTargetDescriptorWire runtime,
  List<String> fields,
});

typedef PatchbayUiManifestSemanticsObserved = ({
  PatchbayUiManifestSemanticsEntry declared,
  PatchbayUiManifestSemanticsMatch match,
});

typedef PatchbayUiManifestSemanticsAmbiguity = ({
  String id,
  List<PatchbayUiManifestSemanticsMatch> matches,
});

/// What a manifest and a running App disagree about, and nothing more.
///
/// The report states observations, never a diagnosis. "Declared but not mounted"
/// is exactly that — this command reconciles the mount state of one moment, so
/// a control that lives on another screen is expected to be missing and is not
/// reported as lost.
final class PatchbayUiManifestReport {
  const PatchbayUiManifestReport({
    required this.destination,
    required this.destinationFiltered,
    required this.declared,
    required this.skipped,
    required this.mountedTargets,
    required this.notMounted,
    required this.notDeclared,
    required this.drifted,
    required this.ambiguous,
    this.semanticsTreeRevision,
    this.semanticsFactSource,
    this.semanticsNotMounted = const <PatchbayUiManifestSemanticsEntry>[],
    this.semanticsNotDeclared = const <PatchbayUiManifestSemanticsMatch>[],
    this.semanticsObserved = const <PatchbayUiManifestSemanticsObserved>[],
    this.semanticsAmbiguous = const <PatchbayUiManifestSemanticsAmbiguity>[],
  });

  /// The destination every scoped entry was filtered against, or `null` when
  /// the App reported no settled destination.
  final String? destination;

  /// Whether [destination] was read at all. `false` means the manifest scopes
  /// nothing, so every entry was in scope and `navigation.current` was never
  /// called — which is a different thing from "read, and the App had no
  /// destination to report".
  final bool destinationFiltered;

  final int declared;
  final int skipped;
  final int mountedTargets;
  final List<PatchbayUiManifestAbsence> notMounted;
  final List<PatchbayUiTargetDescriptorWire> notDeclared;
  final List<PatchbayUiManifestDrift> drifted;

  /// Targets mounted more than once under one ID.
  ///
  /// Not a manifest deviation — the manifest cannot declare how many instances
  /// exist — but the bridge refuses every operation on such a target, so a
  /// report that stayed silent would call a target verified that nothing can
  /// actually drive.
  final List<String> ambiguous;
  final int? semanticsTreeRevision;
  final String? semanticsFactSource;
  final List<PatchbayUiManifestSemanticsEntry> semanticsNotMounted;
  final List<PatchbayUiManifestSemanticsMatch> semanticsNotDeclared;
  final List<PatchbayUiManifestSemanticsObserved> semanticsObserved;
  final List<PatchbayUiManifestSemanticsAmbiguity> semanticsAmbiguous;

  int get checked => declared - skipped;

  bool get hasDeviation =>
      notMounted.isNotEmpty ||
      notDeclared.isNotEmpty ||
      drifted.isNotEmpty ||
      semanticsNotMounted.isNotEmpty ||
      semanticsNotDeclared.isNotEmpty ||
      semanticsAmbiguous.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': patchbayUiManifestReportSchema,
    'destination': destination,
    'destinationSource': destinationFiltered ? 'navigation.current' : null,
    'declaredNotMounted': <Object?>[
      for (final PatchbayUiManifestAbsence absence in notMounted)
        <String, Object?>{
          ...absence.declared.toJson(),
          'runtime': absence.registered ? 'unmounted' : 'absent',
        },
      for (final PatchbayUiManifestSemanticsEntry entry in semanticsNotMounted)
        <String, Object?>{
          ...entry.toJson(),
          'runtime': 'unmounted',
          'code': 'uiSemanticsIdentifierNotFound',
        },
    ],
    'mountedNotDeclared': <Object?>[
      for (final PatchbayUiTargetDescriptorWire target in notDeclared)
        <String, Object?>{
          'id': target.id,
          'kind': target.kind.toJson(),
          'sensitive': _isSensitive(target),
          'generation': target.generation,
        },
      for (final PatchbayUiManifestSemanticsMatch target
          in semanticsNotDeclared)
        <String, Object?>{
          'namespace': PatchbayUiManifestNamespace.semanticsIdentifier.name,
          'id': target.id,
          'generation': target.generation,
          'nodeId': target.nodeId,
        },
    ],
    'propertyMismatch': <Object?>[
      for (final PatchbayUiManifestDrift drift in drifted)
        <String, Object?>{
          'id': drift.declared.id,
          'fields': <Object?>[
            for (final String field in drift.fields)
              <String, Object?>{
                'field': field,
                'declared': _declaredValue(drift.declared, field),
                'runtime': _runtimeValue(drift.runtime, field),
              },
          ],
        },
    ],
    'notices': <Object?>[
      for (final String id in ambiguous)
        <String, Object?>{'code': 'uiTargetAmbiguous', 'id': id},
    ],
    if (semanticsTreeRevision != null)
      'semantics': <String, Object?>{
        'command': 'ui.semantics.tree',
        'source': semanticsFactSource,
        'treeRevision': semanticsTreeRevision,
        'observed': <Object?>[
          for (final PatchbayUiManifestSemanticsObserved observation
              in semanticsObserved)
            <String, Object?>{
              'namespace': PatchbayUiManifestNamespace.semanticsIdentifier.name,
              'id': observation.declared.id,
              ...observation.match.toJson(),
            },
        ],
        'identifierAmbiguous': <Object?>[
          for (final PatchbayUiManifestSemanticsAmbiguity ambiguity
              in semanticsAmbiguous)
            <String, Object?>{
              'code': 'uiSemanticsIdentifierAmbiguous',
              'namespace': PatchbayUiManifestNamespace.semanticsIdentifier.name,
              'id': ambiguity.id,
              'matchCount': ambiguity.matches.length,
              'matches': <Object?>[
                for (final PatchbayUiManifestSemanticsMatch match
                    in ambiguity.matches)
                  match.toJson(),
              ],
            },
        ],
      },
    'stats': <String, Object?>{
      'declared': declared,
      'checked': checked,
      'skippedOutOfScope': skipped,
      'mountedTargets': mountedTargets,
      'declaredNotMounted': notMounted.length + semanticsNotMounted.length,
      'mountedNotDeclared': notDeclared.length + semanticsNotDeclared.length,
      'propertyMismatch': drifted.length,
      if (semanticsTreeRevision != null) ...<String, Object?>{
        'mountedIdentifiers':
            semanticsNotDeclared.length +
            semanticsObserved.length +
            semanticsAmbiguous.length,
        'identifierAmbiguous': semanticsAmbiguous.length,
      },
    },
  };

  /// One line, for a repl transcript where every line owns exactly one.
  String get summaryLine => patchbayUiManifestSummaryLine(toJson());

  /// The one-shot rendering: the deviations themselves, not just how many.
  ///
  /// A verification whose human output is three counts forces every reader to
  /// re-run it with `--json` — and re-running means reconnecting to an App whose
  /// screen may have moved on.
  String get humanReport {
    final StringBuffer output = StringBuffer()
      ..writeln(hasDeviation ? summaryLine : 'uiManifest no deviation')
      ..writeln(
        'destination=${destination ?? '<none>'}'
        '${destinationFiltered ? ' (navigation.current)' : ' (manifest scopes nothing)'} '
        'declared=$declared checked=$checked skipped=$skipped '
        'mountedTargets=$mountedTargets',
      );
    if (notMounted.isNotEmpty) {
      output.writeln('declared, not mounted right now:');
      for (final PatchbayUiManifestAbsence absence in notMounted) {
        output.writeln(
          '  ${absence.declared.id}  '
          '${absence.registered ? 'registered but unmounted' : 'absent from the catalog'}',
        );
      }
    }
    if (notDeclared.isNotEmpty) {
      output.writeln('mounted, not declared:');
      for (final PatchbayUiTargetDescriptorWire target in notDeclared) {
        output.writeln(
          '  ${target.id}  kind=${target.kind.name} '
          'sensitive=${_isSensitive(target)} generation=${target.generation}',
        );
      }
    }
    if (drifted.isNotEmpty) {
      output.writeln('declared, but the runtime says otherwise:');
      for (final PatchbayUiManifestDrift drift in drifted) {
        for (final String field in drift.fields) {
          output.writeln(
            '  ${drift.declared.id}  $field: '
            'declared=${_declaredValue(drift.declared, field)} '
            'runtime=${_runtimeValue(drift.runtime, field)}',
          );
        }
      }
    }
    if (semanticsNotMounted.isNotEmpty) {
      output.writeln('semantics identifiers not mounted right now:');
      for (final PatchbayUiManifestSemanticsEntry entry
          in semanticsNotMounted) {
        output.writeln('  ${entry.id}  absent from the observed tree');
      }
    }
    if (semanticsNotDeclared.isNotEmpty) {
      output.writeln('mounted semantics identifiers not declared:');
      for (final PatchbayUiManifestSemanticsMatch match
          in semanticsNotDeclared) {
        output.writeln(
          '  ${match.id}  nodeId=${match.nodeId} '
          'generation=${match.generation}',
        );
      }
    }
    for (final PatchbayUiManifestSemanticsAmbiguity ambiguity
        in semanticsAmbiguous) {
      output.writeln(
        'failure: ${ambiguity.id} matches '
        '${ambiguity.matches.length} semantics nodes '
        '(uiSemanticsIdentifierAmbiguous)',
      );
    }
    for (final String id in ambiguous) {
      output.writeln('notice: $id is mounted more than once (ambiguous)');
    }
    return output.toString().trimRight();
  }

  static Object? _declaredValue(PatchbayUiManifestEntry entry, String field) =>
      switch (field) {
        'kind' => entry.kind.toJson(),
        'sensitive' => entry.sensitive,
        _ => throw StateError('unknown manifest field $field'),
      };

  static Object? _runtimeValue(
    PatchbayUiTargetDescriptorWire target,
    String field,
  ) => switch (field) {
    'kind' => target.kind.toJson(),
    'sensitive' => _isSensitive(target),
    _ => throw StateError('unknown manifest field $field'),
  };

  static bool _isSensitive(PatchbayUiTargetDescriptorWire target) =>
      target.sensitivePolicy == PatchbaySensitivePolicyWire.redacted;
}

/// Marks a document the CLI computed itself rather than one an App answered.
const String patchbayUiManifestReportSchema = 'uiManifestReport';

/// The deliberately narrow coverage of an emitted draft.
const String patchbayUiManifestMountedCoverage = 'mountedOnly';

/// The catalog namespace, kept as a string for the manifest artifact.
const String patchbayUiManifestCatalogNamespace = 'catalogTarget';

/// Builds an editable v2 draft from one observed, settled destination.
///
/// Only mounted catalog rows are evidence about the current screen. Registered
/// but unmounted rows may belong to another screen, so including them would make
/// a single live observation look like whole-App coverage. The caller must
/// supply a destination the App actually reported; inventing one here would
/// make the generated file impossible to verify honestly.
Map<String, Object?> emitPatchbayMountedUiManifest({
  required List<PatchbayUiTargetDescriptorWire> runtime,
  required String destination,
  PatchbayUiManifestSemanticsRuntime? semantics,
}) {
  if (destination.isEmpty) {
    throw const PatchbayProtocolException(
      'manifestDestinationUnavailable',
      details: <String, Object?>{
        'reason':
            'navigation.current did not report a settled destination; the '
            'CLI will not invent one for a manifest draft',
      },
    );
  }
  final List<PatchbayUiTargetDescriptorWire> mounted =
      runtime
          .where((PatchbayUiTargetDescriptorWire target) => target.mounted)
          .toList()
        ..sort(
          (
            PatchbayUiTargetDescriptorWire left,
            PatchbayUiTargetDescriptorWire right,
          ) => left.id.compareTo(right.id),
        );
  final Set<String> catalogIds = <String>{
    for (final PatchbayUiTargetDescriptorWire target in mounted) target.id,
  };
  final List<PatchbayUiManifestSemanticsMatch> mountedIdentifiers =
      <PatchbayUiManifestSemanticsMatch>[];
  if (semantics != null) {
    for (final String id in semantics.identifiers) {
      final List<PatchbayUiManifestSemanticsMatch> matches =
          semantics.byIdentifier[id]!;
      if (matches.length != 1) {
        throw PatchbayProtocolException(
          'manifestSemanticsIdentifierAmbiguous',
          details: <String, Object?>{
            'identifier': id,
            'matchCount': matches.length,
          },
        );
      }
      if (catalogIds.contains(id)) {
        throw PatchbayProtocolException(
          'manifestNamespaceConflict',
          details: <String, Object?>{
            'id': id,
            'reason':
                'one live id exists in both catalogTarget and '
                'semanticsIdentifier namespaces',
          },
        );
      }
      mountedIdentifiers.add(matches.single);
    }
  }
  return <String, Object?>{
    'version': 2,
    'coverage': patchbayUiManifestMountedCoverage,
    'destinations': <Object?>[
      <String, Object?>{
        'id': destination,
        'targets': <Object?>[
          for (final PatchbayUiTargetDescriptorWire target in mounted)
            <String, Object?>{
              'namespace': patchbayUiManifestCatalogNamespace,
              'id': target.id,
              'kind': target.kind.toJson(),
              'sensitive':
                  target.sensitivePolicy ==
                  PatchbaySensitivePolicyWire.redacted,
            },
          for (final PatchbayUiManifestSemanticsMatch match
              in mountedIdentifiers)
            <String, Object?>{
              'namespace': PatchbayUiManifestNamespace.semanticsIdentifier.name,
              'id': match.id,
            },
        ],
      },
    ],
  };
}

/// One summary line for a report [document].
///
/// It reads the JSON rather than the report object because the repl only ever
/// holds the document; keeping one implementation is what stops the line an
/// operator sees from disagreeing with the report it summarises.
String patchbayUiManifestSummaryLine(Map<String, Object?> document) {
  final Object? stats = document['stats'];
  if (stats is! Map<Object?, Object?>) return jsonEncode(document);
  return 'uiManifest '
      'declaredNotMounted=${stats['declaredNotMounted']} '
      'mountedNotDeclared=${stats['mountedNotDeclared']} '
      'propertyMismatch=${stats['propertyMismatch']} '
      'checked=${stats['checked']} skipped=${stats['skippedOutOfScope']}';
}

/// Reconciles one manifest against one catalog reading.
///
/// The three deviation groups are independent axes rather than a ranking: a
/// declaration can be both unmounted and contradicted, and it is listed under
/// both, because suppressing the second would hide a real drift behind an
/// ordinary absence.
PatchbayUiManifestReport verifyPatchbayUiManifest({
  required PatchbayUiManifest manifest,
  required List<PatchbayUiTargetDescriptorWire> runtime,
  required String? currentDestination,
  PatchbayUiManifestSemanticsRuntime? semantics,
}) {
  final Map<String, PatchbayUiTargetDescriptorWire> byId =
      <String, PatchbayUiTargetDescriptorWire>{
        for (final PatchbayUiTargetDescriptorWire target in runtime)
          target.id: target,
      };
  final bool filtered = manifest.usesDestinations;

  final List<PatchbayUiManifestAbsence> notMounted =
      <PatchbayUiManifestAbsence>[];
  final List<PatchbayUiManifestDrift> drifted = <PatchbayUiManifestDrift>[];
  final Set<String> declaredCatalogIds = <String>{};
  final Set<String> declaredSemanticsIds = <String>{};
  final List<PatchbayUiManifestSemanticsEntry> semanticsNotMounted =
      <PatchbayUiManifestSemanticsEntry>[];
  final List<PatchbayUiManifestSemanticsObserved> semanticsObserved =
      <PatchbayUiManifestSemanticsObserved>[];
  final List<PatchbayUiManifestSemanticsAmbiguity> semanticsAmbiguous =
      <PatchbayUiManifestSemanticsAmbiguity>[];
  var skipped = 0;

  for (final PatchbayUiManifestEntry entry in manifest.entries) {
    // An ID declared anywhere in the manifest is declared, even when this
    // occurrence is scoped to another screen: reporting it as undeclared would
    // be a statement about the manifest that the manifest contradicts.
    declaredCatalogIds.add(entry.id);
    if (entry.destination != null && entry.destination != currentDestination) {
      skipped += 1;
      continue;
    }
    final PatchbayUiTargetDescriptorWire? target = byId[entry.id];
    if (target == null || !target.mounted) {
      notMounted.add((declared: entry, registered: target != null));
    }
    if (target == null) continue;
    final List<String> fields = <String>[
      if (target.kind != entry.kind) 'kind',
      if (PatchbayUiManifestReport._isSensitive(target) != entry.sensitive)
        'sensitive',
    ];
    if (fields.isNotEmpty) {
      drifted.add((declared: entry, runtime: target, fields: fields));
    }
  }
  for (final PatchbayUiManifestSemanticsEntry entry
      in manifest.semanticsEntries) {
    declaredSemanticsIds.add(entry.id);
    if (entry.destination != currentDestination) {
      skipped += 1;
      continue;
    }
    final List<PatchbayUiManifestSemanticsMatch> matches =
        semantics?.byIdentifier[entry.id] ??
        const <PatchbayUiManifestSemanticsMatch>[];
    if (matches.isEmpty) {
      semanticsNotMounted.add(entry);
    } else if (matches.length > 1) {
      semanticsAmbiguous.add((id: entry.id, matches: matches));
    } else {
      semanticsObserved.add((declared: entry, match: matches.single));
    }
  }

  final List<PatchbayUiTargetDescriptorWire> mounted = runtime
      .where((PatchbayUiTargetDescriptorWire target) => target.mounted)
      .toList(growable: false);
  final List<PatchbayUiManifestSemanticsMatch> semanticsNotDeclared =
      <PatchbayUiManifestSemanticsMatch>[
        if (semantics != null)
          for (final String id in semantics.identifiers)
            if (!declaredSemanticsIds.contains(id))
              semantics.byIdentifier[id]!.first,
      ];
  for (final String id in semantics?.identifiers ?? const <String>[]) {
    final List<PatchbayUiManifestSemanticsMatch> matches =
        semantics!.byIdentifier[id]!;
    if (matches.length < 2 ||
        semanticsAmbiguous.any((ambiguity) => ambiguity.id == id)) {
      continue;
    }
    semanticsAmbiguous.add((id: id, matches: matches));
  }
  return PatchbayUiManifestReport(
    destination: currentDestination,
    destinationFiltered: filtered,
    declared: manifest.entries.length + manifest.semanticsEntries.length,
    skipped: skipped,
    mountedTargets: mounted.length,
    notMounted: notMounted,
    // Only a mounted target can be "mounted but not declared"; a registered,
    // unmounted one the manifest never mentions is not evidence of anything.
    notDeclared: mounted
        .where(
          (PatchbayUiTargetDescriptorWire target) =>
              !declaredCatalogIds.contains(target.id),
        )
        .toList(growable: false),
    drifted: drifted,
    ambiguous: <String>[
      for (final PatchbayUiTargetDescriptorWire target in mounted)
        if (target.ambiguous) target.id,
    ],
    semanticsTreeRevision: semantics?.treeRevision,
    semanticsFactSource: semantics?.factSource,
    semanticsNotMounted: semanticsNotMounted,
    semanticsNotDeclared: semanticsNotDeclared,
    semanticsObserved: semanticsObserved,
    semanticsAmbiguous: semanticsAmbiguous,
  );
}

/// Decodes `catalog.uiTargets` through the wire contract itself.
///
/// The rows are the other half of this comparison, so a row this CLI had to
/// guess about would produce a verdict about a target nobody published. The
/// generated decoder already states the contract; a hand-rolled reader here
/// would be a second copy of it, free to drift.
List<PatchbayUiTargetDescriptorWire> decodePatchbayCatalogUiTargets(
  Map<String, Object?> catalog,
) {
  final Object? rows = catalog['uiTargets'];
  if (rows is! List<Object?>) {
    throw const PatchbayProtocolException(
      'catalogUiTargetsContractViolated',
      details: <String, Object?>{'reason': 'catalog.uiTargets is not an array'},
    );
  }
  final List<PatchbayUiTargetDescriptorWire> targets =
      <PatchbayUiTargetDescriptorWire>[];
  final Set<String> seen = <String>{};
  for (final Object? row in rows) {
    if (row is! Map<String, Object?>) {
      throw const PatchbayProtocolException(
        'catalogUiTargetsContractViolated',
        details: <String, Object?>{
          'reason': 'a catalog.uiTargets row is not an object',
        },
      );
    }
    final PatchbayUiTargetDescriptorWire target;
    try {
      target = PatchbayUiTargetDescriptorWire.fromJson(
        row,
        path: r'$.uiTargets[]',
      );
    } on FormatException catch (failure) {
      throw PatchbayProtocolException(
        'catalogUiTargetsContractViolated',
        details: <String, Object?>{'reason': failure.message},
      );
    }
    if (!seen.add(target.id)) {
      // One row per stable ID is what makes the reconciliation a lookup at all.
      throw PatchbayProtocolException(
        'catalogUiTargetsContractViolated',
        details: <String, Object?>{
          'reason': 'catalog.uiTargets repeats an id',
          'id': target.id,
        },
      );
    }
    targets.add(target);
  }
  return targets;
}
