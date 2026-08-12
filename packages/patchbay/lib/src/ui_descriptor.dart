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

/// Consumer declaration stored by a [PatchbayKey] without Widget callbacks.
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
