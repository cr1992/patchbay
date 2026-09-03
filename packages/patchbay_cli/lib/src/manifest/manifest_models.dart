import 'package:patchbay/patchbay_protocol.dart';

import 'manifest_parser.dart';

/// A manifest the CLI refused to read.
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

/// Marks a document the CLI computed itself rather than one an App answered.
const String patchbayUiManifestReportSchema = 'uiManifestReport';

/// The deliberately narrow coverage of an emitted draft.
const String patchbayUiManifestMountedCoverage = 'mountedOnly';

/// The catalog namespace, kept as a string for the manifest artifact.
const String patchbayUiManifestCatalogNamespace = 'catalogTarget';

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

typedef ManifestV2Entry = ({
  PatchbayUiManifestEntry? catalog,
  PatchbayUiManifestSemanticsEntry? semantics,
});

typedef ManifestIdentity = ({
  String id,
  String? destination,
  PatchbayUiManifestNamespace namespace,
  String field,
});

/// One declared UI target: what the consumer says the running App should carry.
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
  final String? destination;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.toJson(),
    'sensitive': sensitive,
    'destination': ?destination,
  };
}

/// One v2 Semantics identifier declaration.
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

/// One declared target the runtime is not currently carrying.
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

/// A parsed `ui verify-manifest` input file.
final class PatchbayUiManifest {
  const PatchbayUiManifest(
    this.entries, {
    this.semanticsEntries = const <PatchbayUiManifestSemanticsEntry>[],
    this.destinations = const <String>[],
  });

  /// Reads one manifest document, fail-closed.
  factory PatchbayUiManifest.parse(String source) =>
      ManifestParser.parseSource(source, format: PatchbayUiManifestFormat.json);

  /// Parses one explicitly selected input format into the shared model.
  factory PatchbayUiManifest.parseSource(
    String source, {
    required PatchbayUiManifestFormat format,
  }) => ManifestParser.parseSource(source, format: format);

  final List<PatchbayUiManifestEntry> entries;
  final List<PatchbayUiManifestSemanticsEntry> semanticsEntries;

  /// Destination declaration order, preserved exactly for opt-in walkthroughs.
  final List<String> destinations;

  /// Whether any entry scopes itself to a destination.
  bool get usesDestinations =>
      entries.any(
        (PatchbayUiManifestEntry entry) => entry.destination != null,
      ) ||
      semanticsEntries.isNotEmpty;

  /// Whether the currently in-scope declarations require one live Semantics snapshot.
  bool requiresSemanticsAt(String? destination) => semanticsEntries.any(
    (PatchbayUiManifestSemanticsEntry entry) =>
        entry.destination == destination,
  );
}
