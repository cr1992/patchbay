import 'dart:convert';

import 'package:patchbay/patchbay_protocol.dart';

import '../client.dart';
import 'manifest_models.dart';

/// What a manifest and a running App disagree about, and nothing more.
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

  /// Whether [destination] was read at all.
  final bool destinationFiltered;

  final int declared;
  final int skipped;
  final int mountedTargets;
  final List<PatchbayUiManifestAbsence> notMounted;
  final List<PatchbayUiTargetDescriptorWire> notDeclared;
  final List<PatchbayUiManifestDrift> drifted;

  /// Targets mounted more than once under one ID.
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
          'sensitive': isSensitive(target),
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
                'declared': declaredValue(drift.declared, field),
                'runtime': runtimeValue(drift.runtime, field),
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
          'sensitive=${isSensitive(target)} generation=${target.generation}',
        );
      }
    }
    if (drifted.isNotEmpty) {
      output.writeln('declared, but the runtime says otherwise:');
      for (final PatchbayUiManifestDrift drift in drifted) {
        for (final String field in drift.fields) {
          output.writeln(
            '  ${drift.declared.id}  $field: '
            'declared=${declaredValue(drift.declared, field)} '
            'runtime=${runtimeValue(drift.runtime, field)}',
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

  static Object? declaredValue(PatchbayUiManifestEntry entry, String field) =>
      switch (field) {
        'kind' => entry.kind.toJson(),
        'sensitive' => entry.sensitive,
        _ => throw StateError('unknown manifest field $field'),
      };

  static Object? runtimeValue(
    PatchbayUiTargetDescriptorWire target,
    String field,
  ) => switch (field) {
    'kind' => target.kind.toJson(),
    'sensitive' => isSensitive(target),
    _ => throw StateError('unknown manifest field $field'),
  };

  static bool isSensitive(PatchbayUiTargetDescriptorWire target) =>
      target.sensitivePolicy == PatchbaySensitivePolicyWire.redacted;
}

/// One summary line for a report [document].
String patchbayUiManifestSummaryLine(Map<String, Object?> document) {
  final Object? stats = document['stats'];
  if (stats is! Map<Object?, Object?>) return jsonEncode(document);
  return 'uiManifest '
      'declaredNotMounted=${stats['declaredNotMounted']} '
      'mountedNotDeclared=${stats['mountedNotDeclared']} '
      'propertyMismatch=${stats['propertyMismatch']} '
      'checked=${stats['checked']} skipped=${stats['skippedOutOfScope']}';
}

/// Decodes an accepted `ui.semantics.tree` payload through the existing strict wire model.
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
    throw const PatchbayProtocolException(
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

/// Decodes `catalog.uiTargets` through the wire contract itself.
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
