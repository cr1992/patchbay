import 'facts.dart';
import 'generated/core_wire.g.dart';

enum PatchbayPlane { domain, flutterUi }

enum PatchbayUiTargetKind { text, capture }

enum PatchbayUiOperation {
  textSet('text.set'),
  textEnter('text.enter'),
  capture('capture');

  const PatchbayUiOperation(this.wireName);

  final String wireName;
}

enum PatchbaySideEffect { none, appState, external }

enum PatchbaySensitivePolicy { public, redacted }

/// Closed catalog-wire classification distinguishing an explicit consumer
/// automation surface from an action that must still satisfy user-like
/// reachability (DG-060-05, "交互模型进入 catalog").
///
/// Declared only on UI commands with write side effects or reachability
/// semantics: `ui.text.set`/`ui.text.enter` declare [directTarget];
/// Semantics action/tap, pointer gesture and `ui.reveal` declare [userLike].
/// Read commands and non-UI commands carry no `interactionModel` at all —
/// absence is not a third value, it means the field does not apply or the
/// host predates it (a reader must never infer one from the command name).
///
/// [directTarget] means the command operates a controller/adapter surface
/// the consumer explicitly opened for automation. Success proves only that
/// the operation was applied, never that a real user, pointer or device
/// could reach the target, and it adds no occlusion gate.
///
/// [userLike] keeps the existing generation, policy, hit-test/occlusion
/// admission and post-gate re-resolution. There is no `force`,
/// `ignoreOcclusion` or cross-channel fallback for either value.
enum PatchbayInteractionModel {
  directTarget,
  userLike;

  /// Decodes the optional `interactionModel` catalog-row key.
  ///
  /// Returns `null` when the row does not declare the key at all — absence
  /// is not an error, it is the additive-field default every older host and
  /// every command outside the closed declaring set produces. Throws
  /// [FormatException] for any declared value outside the two-member closed
  /// set, which callers must treat as a whole-catalog provider violation
  /// (DG-060-05), not a single bad row.
  static PatchbayInteractionModel? fromCatalogRow(Map<Object?, Object?> row) {
    if (!row.containsKey('interactionModel')) return null;
    final Object? raw = row['interactionModel'];
    if (raw is! String) {
      throw const FormatException('interactionModel must be a string');
    }
    for (final PatchbayInteractionModel candidate in values) {
      if (candidate.name == raw) return candidate;
    }
    throw FormatException('unknown interactionModel: $raw');
  }

  /// Encodes this value using its stable catalog-wire name.
  String toJson() => name;
}

/// Consumer declaration stored by a `PatchbayKey` without Widget callbacks.
final class PatchbayUiTargetDeclaration {
  PatchbayUiTargetDeclaration.text({
    required this.id,
    bool sensitive = false,
    this.sideEffect = PatchbaySideEffect.appState,
    Map<PatchbayUiOperation, Set<String>> operationGates =
        const <PatchbayUiOperation, Set<String>>{},
  }) : kind = PatchbayUiTargetKind.text,
       sensitivePolicy = sensitive
           ? PatchbaySensitivePolicy.redacted
           : PatchbaySensitivePolicy.public,
       operationGates = Map<PatchbayUiOperation, Set<String>>.unmodifiable(
         <PatchbayUiOperation, Set<String>>{
           for (final MapEntry<PatchbayUiOperation, Set<String>> entry
               in operationGates.entries)
             entry.key: Set<String>.unmodifiable(entry.value),
         },
       ) {
    if (!_validId.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be a stable dotted identifier');
    }
  }

  PatchbayUiTargetDeclaration.capture({
    required this.id,
    Set<String> gates = const <String>{},
  }) : kind = PatchbayUiTargetKind.capture,
       sensitivePolicy = PatchbaySensitivePolicy.public,
       sideEffect = PatchbaySideEffect.none,
       operationGates = <PatchbayUiOperation, Set<String>>{
         PatchbayUiOperation.capture: Set<String>.unmodifiable(gates),
       } {
    if (!_validId.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be a stable dotted identifier');
    }
  }

  static final RegExp _validId = RegExp(
    r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$',
  );

  final String id;
  final PatchbayUiTargetKind kind;
  final PatchbaySensitivePolicy sensitivePolicy;
  final PatchbaySideEffect sideEffect;
  final Map<PatchbayUiOperation, Set<String>> operationGates;

  Set<String> gatesFor(PatchbayUiOperation operation) =>
      operationGates[operation] ?? const <String>{};
}

/// Runtime catalog entry. Operations are the declaration/runtime intersection.
final class PatchbayUiTargetDescriptor {
  const PatchbayUiTargetDescriptor({
    required this.id,
    required this.generation,
    required this.kind,
    required this.mounted,
    required this.ambiguous,
    required this.operations,
    required this.operationGates,
    required this.sensitivePolicy,
    required this.sideEffect,
    this.factSources = const <PatchbayFactSource>{
      PatchbayFactSource.uiObserved,
    },
  });

  final String id;
  final int generation;
  final PatchbayUiTargetKind kind;
  final bool mounted;
  final bool ambiguous;
  final Set<PatchbayUiOperation> operations;
  final Map<PatchbayUiOperation, Set<String>> operationGates;
  final PatchbaySensitivePolicy sensitivePolicy;
  final PatchbaySideEffect sideEffect;
  final Set<PatchbayFactSource> factSources;

  Map<String, Object?> toJson() {
    final List<String> sortedOperations =
        operations.map((value) => value.wireName).toList(growable: false)
          ..sort();
    final List<PatchbayFactSourceWire> sortedFactSources =
        factSources.map(_factSourceWire).toList(growable: false)
          ..sort((a, b) => a.name.compareTo(b.name));
    return PatchbayUiTargetDescriptorWire(
      id: id,
      generation: generation,
      kind: switch (kind) {
        PatchbayUiTargetKind.text => PatchbayUiTargetKindWire.text,
        PatchbayUiTargetKind.capture => PatchbayUiTargetKindWire.capture,
      },
      mounted: mounted,
      ambiguous: ambiguous,
      operations: sortedOperations,
      operationGates: <String, Object?>{
        for (final PatchbayUiOperation operation in operations)
          operation.wireName:
              (operationGates[operation] ?? const <String>{}).toList()..sort(),
      },
      sensitivePolicy: switch (sensitivePolicy) {
        PatchbaySensitivePolicy.public => PatchbaySensitivePolicyWire.public,
        PatchbaySensitivePolicy.redacted =>
          PatchbaySensitivePolicyWire.redacted,
      },
      sideEffect: switch (sideEffect) {
        PatchbaySideEffect.none => PatchbaySideEffectWire.none,
        PatchbaySideEffect.appState => PatchbaySideEffectWire.appState,
        PatchbaySideEffect.external => PatchbaySideEffectWire.external,
      },
      factSources: sortedFactSources,
    ).toJson();
  }
}

PatchbayFactSourceWire _factSourceWire(PatchbayFactSource value) =>
    switch (value) {
      PatchbayFactSource.appRecorded => PatchbayFactSourceWire.appRecorded,
      PatchbayFactSource.commandEcho => PatchbayFactSourceWire.commandEcho,
      PatchbayFactSource.deviceReported =>
        PatchbayFactSourceWire.deviceReported,
      PatchbayFactSource.uiObserved => PatchbayFactSourceWire.uiObserved,
      PatchbayFactSource.unknown => PatchbayFactSourceWire.unknown,
    };
