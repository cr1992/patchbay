import 'generated/core_wire.g.dart';

/// Stable navigation verbs exposed without leaking a consumer route path.
enum PatchbayNavigationOperation {
  go,
  push,
  back;

  PatchbayNavigationOperationWire get wire => switch (this) {
    PatchbayNavigationOperation.go => PatchbayNavigationOperationWire.go,
    PatchbayNavigationOperation.push => PatchbayNavigationOperationWire.push,
    PatchbayNavigationOperation.back => PatchbayNavigationOperationWire.back,
  };
}

/// A consumer-observed, settled navigation state.
///
/// The consumer owns the revision and must increase it whenever the settled
/// destination changes. Transient route paths are deliberately not exposed.
final class PatchbayNavigationObservation {
  PatchbayNavigationObservation({
    required this.revision,
    required this.destinationId,
  }) {
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision', 'must be non-negative');
    }
    final String? id = destinationId;
    if (id != null && !_stableId.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'destinationId',
        'must be a stable dotted identifier',
      );
    }
  }

  final int revision;
  final String? destinationId;
}

/// Runtime catalog row for one consumer-owned destination.
final class PatchbayDestinationDescriptor {
  PatchbayDestinationDescriptor({
    required String id,
    required Set<PatchbayNavigationOperation> operations,
    this.summary,
    Set<String> gates = const <String>{},
    this.ambiguous = false,
  }) : id = id,
       operations = Set<PatchbayNavigationOperation>.unmodifiable(operations),
       gates = Set<String>.unmodifiable(gates) {
    if (!_stableId.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be a stable dotted identifier');
    }
    if (this.operations.contains(PatchbayNavigationOperation.back)) {
      throw ArgumentError.value(
        operations,
        'operations',
        'back belongs to the adapter, not a destination',
      );
    }
  }

  final String id;
  final String? summary;
  final Set<PatchbayNavigationOperation> operations;
  final Set<String> gates;
  final bool ambiguous;

  PatchbayDestinationDescriptorWire toWire() {
    final List<PatchbayNavigationOperationWire> sortedOperations =
        operations
            .map((PatchbayNavigationOperation operation) => operation.wire)
            .toList(growable: false)
          ..sort((a, b) => a.name.compareTo(b.name));
    final List<String> sortedGates = gates.toList(growable: false)..sort();
    return PatchbayDestinationDescriptorWire(
      id: id,
      summary: summary,
      operations: sortedOperations,
      gates: sortedGates,
      ambiguous: ambiguous,
    );
  }

  Map<String, Object?> toJson() => toWire().toJson();
}

final RegExp _stableId = RegExp(r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$');
