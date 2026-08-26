import 'dart:async';
import 'dart:developer';
import 'dart:math';

import '../generated/core_wire.g.dart';
import '../invocation.dart';
import '../invocation_cancellation.dart';
import '../snapshot.dart';

typedef PatchbayCatalogSource = Future<Map<String, Object?>> Function();
typedef PatchbaySnapshotSource = Future<Map<String, Object?>> Function();
typedef PatchbayInvocationSource =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
    );
typedef PatchbayContextInvocationSource =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
      PatchbayInvocationContext context,
    );
typedef PatchbayExtensionRegistrar =
    void Function(String method, ServiceExtensionHandler handler);

/// A complete catalog observation bound to the commands revision it describes.
final class PatchbayCatalogSample {
  const PatchbayCatalogSample({
    required this.commandsRevision,
    required this.catalog,
  });

  final int commandsRevision;
  final Map<String, Object?> catalog;
}

/// A catalog source with an explicit, cheap commands invalidation signal.
abstract interface class PatchbayCatalogProvider {
  int get commandsRevision;

  Future<PatchbayCatalogSample> readCatalog();
}

final RegExp patchbayCommandNamePattern = RegExp(
  r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$',
);

String patchbayGenerateNonce() {
  final Random random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// One catalog read: either the catalog to serve, or the whole-catalog
/// protocol violation that makes it unusable.
final class PatchbayCatalogRead {
  const PatchbayCatalogRead._({
    required this.response,
    required this.violation,
  });

  const PatchbayCatalogRead.valid(this.response) : violation = null;

  factory PatchbayCatalogRead.violated(Map<String, Object?> violation) =>
      PatchbayCatalogRead._(
        response: _violationEnvelope(violation),
        violation: violation,
      );

  final Map<String, Object?> response;
  final Map<String, Object?>? violation;

  static Map<String, Object?> _violationEnvelope(
    Map<String, Object?> violation,
  ) => patchbayProviderViolationEnvelope(_violationNotice, violation);

  static const String _violationNotice =
      'The App catalog violates the Patchbay command contract.';
}

/// One snapshot read: either the snapshot to serve, or the envelope that
/// replaces it when the consumer source could not be read.
final class PatchbaySnapshotRead {
  const PatchbaySnapshotRead._(
    this.response,
    this.body,
    this.metadata, {
    required this.violated,
  });

  const PatchbaySnapshotRead.valid(
    Map<String, Object?> response,
    Map<String, Object?> body,
    Map<String, Object?> metadata,
  ) : this._(response, body, metadata, violated: false);

  const PatchbaySnapshotRead.violated(Map<String, Object?> response)
    : this._(
        response,
        const <String, Object?>{},
        const <String, Object?>{},
        violated: true,
      );

  final Map<String, Object?> response;
  final Map<String, Object?> body;
  final Map<String, Object?> metadata;
  final bool violated;
}

final class PatchbaySnapshotRevision {
  const PatchbaySnapshotRevision({
    required this.revision,
    required this.canonical,
    required this.body,
  });

  final int revision;
  final String canonical;
  final Map<String, Object?> body;
}

final class PatchbaySnapshotDiff {
  PatchbaySnapshotDiff._(this.added, this.changed, this.removed);

  factory PatchbaySnapshotDiff.between(Object? before, Object? after) {
    final List<Map<String, Object?>> added = <Map<String, Object?>>[];
    final List<Map<String, Object?>> changed = <Map<String, Object?>>[];
    final List<Map<String, Object?>> removed = <Map<String, Object?>>[];
    void walk(String path, Object? left, Object? right) {
      if (patchbayJsonEquals(left, right)) return;
      if (left is Map<String, Object?> && right is Map<String, Object?>) {
        final List<String> keys = <String>{...left.keys, ...right.keys}.toList()
          ..sort();
        for (final String key in keys) {
          final String child = '$path/${patchbayJsonPointerSegment(key)}';
          if (!left.containsKey(key)) {
            added.add(<String, Object?>{'path': child, 'after': right[key]});
          } else if (!right.containsKey(key)) {
            removed.add(<String, Object?>{'path': child, 'before': left[key]});
          } else {
            walk(child, left[key], right[key]);
          }
        }
        return;
      }
      changed.add(<String, Object?>{
        'path': path,
        'before': left,
        'after': right,
      });
    }

    walk('', before, after);
    return PatchbaySnapshotDiff._(added, changed, removed);
  }

  final List<Map<String, Object?>> added;
  final List<Map<String, Object?>> changed;
  final List<Map<String, Object?>> removed;
  int get count => added.length + changed.length + removed.length;
}

String patchbayJsonPointerSegment(String value) =>
    value.replaceAll('~', '~0').replaceAll('/', '~1');

Map<String, Object?> patchbayProviderViolationEnvelope(
  String notice,
  Map<String, Object?> violation,
) => <String, Object?>{
  'schemaVersion': 1,
  'admission': PatchbayAdmissionWire.rejected.name,
  'notice': notice,
  'rejection': PatchbayRejection(
    code: 'providerProtocolViolation',
    notice: notice,
    details: violation,
  ).toJson(),
};

final class PatchbayExternalInvocationRecord {
  PatchbayExternalInvocationRecord({
    required this.argumentDigest,
    required this.idempotent,
    required this.ownerToken,
  });

  final String argumentDigest;
  final bool idempotent;
  final String? ownerToken;
  final Completer<Map<String, Object?>> servedResponse =
      Completer<Map<String, Object?>>();
  late final Future<Map<String, Object?>> response;
  bool settled = false;
}

/// The catalog-declared argument and gate policy the host enforces before
/// dispatch.
final class PatchbayCommandPolicy {
  const PatchbayCommandPolicy({
    required this.sensitiveParameters,
    required this.retainsStdinProvenance,
    required this.declaredGates,
    required this.writesSideEffect,
  });

  factory PatchbayCommandPolicy.forCommand(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Object? commands = catalog['commands'];
    if (commands is! List<Object?>) {
      return const PatchbayCommandPolicy.undeclared();
    }
    for (final Object? entry in commands) {
      if (entry is! Map<Object?, Object?> || entry['name'] != command) continue;
      return PatchbayCommandPolicy.fromCatalogRow(entry);
    }
    return const PatchbayCommandPolicy.undeclared();
  }

  factory PatchbayCommandPolicy.fromCatalogRow(Map<Object?, Object?> command) {
    final Object? parameters = command['parameters'];
    return PatchbayCommandPolicy(
      sensitiveParameters: Set<String>.unmodifiable(<String>{
        if (parameters is List<Object?>)
          for (final Object? parameter in parameters)
            if (parameter is Map<Object?, Object?> &&
                parameter['sensitive'] == true &&
                parameter['name'] is String)
              parameter['name']! as String,
      }),
      retainsStdinProvenance:
          command['plane'] == PatchbayPlaneWire.flutterUi.name,
      declaredGates: _declaredGates(command['gates']),
      // Fail-closed: only a row that *says* `none` is treated as read-only.
      // A missing key or a word outside the closed vocabulary can only come
      // from a hand-written catalog row — `toJson()` always writes the field —
      // and a host that cannot prove a command is read-only must not skip the
      // admission gate for it.
      writesSideEffect:
          command['sideEffect'] != PatchbaySideEffectWire.none.name,
    );
  }

  const PatchbayCommandPolicy.undeclared()
    : sensitiveParameters = const <String>{},
      retainsStdinProvenance = false,
      declaredGates = const <String>{},
      // "Not in the catalog" is not the same as "will not execute": the
      // consumer adapter still sees the command, so it is admitted as a write.
      writesSideEffect = true;

  final Set<String> sensitiveParameters;
  final bool retainsStdinProvenance;

  /// The consumer gate IDs this catalog row declares, handed to the evaluator
  /// unchanged. An absent or malformed declaration reads as the empty set,
  /// which means "base gate only" — the same meaning it already has on the UI
  /// plane.
  final Set<String> declaredGates;

  /// Whether this row must cross the admission gate before dispatch.
  final bool writesSideEffect;

  /// Whether [other] describes the same admission decision as this policy.
  ///
  /// A consumer gate may `await`, and a dynamic catalog provider can advance
  /// its revision while it does. Only the two facts the gate decision was
  /// taken from are compared: everything else about a row may change under a
  /// call without making the authorization it already obtained wrong.
  bool sameGatePolicy(PatchbayCommandPolicy other) =>
      writesSideEffect == other.writesSideEffect &&
      declaredGates.length == other.declaredGates.length &&
      declaredGates.containsAll(other.declaredGates);

  static Set<String> _declaredGates(Object? gates) {
    if (gates is! List<Object?>) return const <String>{};
    final Set<String> declared = <String>{};
    for (final Object? gate in gates) {
      if (gate is! String) return const <String>{};
      declared.add(gate);
    }
    return Set<String>.unmodifiable(declared);
  }

  List<String> sensitiveViolations(Map<String, Object?> arguments) {
    if (sensitiveParameters.isEmpty) return const <String>[];
    if (arguments['inputWasStdin'] == true) {
      return const <String>[];
    }
    return <String>[
      for (final String name in sensitiveParameters)
        if (arguments[name] != null) name,
    ]..sort();
  }
}
