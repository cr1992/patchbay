import 'dart:convert';

import 'package:patchbay/patchbay.dart';

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
    return buffer.toString();
  }
}

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

/// A parsed `ui verify-manifest` input file.
final class PatchbayUiManifest {
  const PatchbayUiManifest(this.entries);

  /// Reads one manifest document, fail-closed.
  ///
  /// Every rule below refuses rather than repairs. A manifest exists to be
  /// compared against a runtime, so a file this parser had to guess about would
  /// produce a verdict about something the author never wrote.
  factory PatchbayUiManifest.parse(String source) {
    final Object? document;
    try {
      document = jsonDecode(source);
    } on FormatException catch (failure) {
      // `message` names the syntax problem; `toString()` would paste the
      // offending slice of the file into the envelope.
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'the file is not valid JSON: ${failure.message}',
          'offset': ?failure.offset,
        },
      );
    }
    if (document is! Map<String, Object?>) {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'the manifest root must be a JSON object',
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
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
    for (var index = 0; index < targets.length; index += 1) {
      entries.add(_v1Entry(targets[index], _targetField(index)));
    }
    _refuseConflictingIds(entries);
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
    final List<PatchbayUiManifestEntry> entries = <PatchbayUiManifestEntry>[];
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
      for (
        var targetIndex = 0;
        targetIndex < targets.length;
        targetIndex += 1
      ) {
        entries.add(
          _v2Entry(
            targets[targetIndex],
            '$field.targets[$targetIndex]',
            destination,
          ),
        );
      }
    }
    _refuseConflictingIds(entries);
    return PatchbayUiManifest(
      List<PatchbayUiManifestEntry>.unmodifiable(entries),
    );
  }

  final List<PatchbayUiManifestEntry> entries;

  /// Whether any entry scopes itself to a destination.
  ///
  /// This is what decides whether the command reads `navigation.current` at
  /// all: a manifest that never mentions a destination has nothing to filter,
  /// and asking the App for its current screen anyway would make an unrelated
  /// gate able to fail a verification that does not depend on it.
  bool get usesDestinations =>
      entries.any((PatchbayUiManifestEntry entry) => entry.destination != null);

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

  static PatchbayUiManifestEntry _v2Entry(
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
    if (value['namespace'] != patchbayUiManifestCatalogNamespace) {
      throw PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'namespace must be catalogTarget in this CLI',
          'field': '$field.namespace',
        },
      );
    }
    return _v1Entry(<String, Object?>{
      'id': value['id'],
      'kind': value['kind'],
      'sensitive': value['sensitive'],
      'destination': destination,
    }, field);
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
  static void _refuseConflictingIds(List<PatchbayUiManifestEntry> entries) {
    final Map<String, Set<String?>> seen = <String, Set<String?>>{};
    for (var index = 0; index < entries.length; index += 1) {
      final PatchbayUiManifestEntry entry = entries[index];
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
            'field': '${_targetField(index)}.id',
            'id': entry.id,
          },
        );
      }
      destinations.add(entry.destination);
    }
  }
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

  int get checked => declared - skipped;

  bool get hasDeviation =>
      notMounted.isNotEmpty || notDeclared.isNotEmpty || drifted.isNotEmpty;

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
    ],
    'mountedNotDeclared': <Object?>[
      for (final PatchbayUiTargetDescriptorWire target in notDeclared)
        <String, Object?>{
          'id': target.id,
          'kind': target.kind.toJson(),
          'sensitive': _isSensitive(target),
          'generation': target.generation,
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
    'stats': <String, Object?>{
      'declared': declared,
      'checked': checked,
      'skippedOutOfScope': skipped,
      'mountedTargets': mountedTargets,
      'declaredNotMounted': notMounted.length,
      'mountedNotDeclared': notDeclared.length,
      'propertyMismatch': drifted.length,
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

/// The only target namespace PB-040-15 can derive from the live catalog.
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
  final Set<String> declaredIds = <String>{};
  var skipped = 0;

  for (final PatchbayUiManifestEntry entry in manifest.entries) {
    // An ID declared anywhere in the manifest is declared, even when this
    // occurrence is scoped to another screen: reporting it as undeclared would
    // be a statement about the manifest that the manifest contradicts.
    declaredIds.add(entry.id);
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

  final List<PatchbayUiTargetDescriptorWire> mounted = runtime
      .where((PatchbayUiTargetDescriptorWire target) => target.mounted)
      .toList(growable: false);
  return PatchbayUiManifestReport(
    destination: currentDestination,
    destinationFiltered: filtered,
    declared: manifest.entries.length,
    skipped: skipped,
    mountedTargets: mounted.length,
    notMounted: notMounted,
    // Only a mounted target can be "mounted but not declared"; a registered,
    // unmounted one the manifest never mentions is not evidence of anything.
    notDeclared: mounted
        .where(
          (PatchbayUiTargetDescriptorWire target) =>
              !declaredIds.contains(target.id),
        )
        .toList(growable: false),
    drifted: drifted,
    ambiguous: <String>[
      for (final PatchbayUiTargetDescriptorWire target in mounted)
        if (target.ambiguous) target.id,
    ],
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
