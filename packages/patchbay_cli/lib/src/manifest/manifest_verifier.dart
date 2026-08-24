import 'package:patchbay/patchbay.dart';

import '../client.dart';
import 'manifest_models.dart';
import 'manifest_report.dart';

/// Builds an editable v2 draft from one observed, settled destination.
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

/// Reconciles one manifest against one catalog reading.
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
      if (PatchbayUiManifestReport.isSensitive(target) != entry.sensitive)
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
