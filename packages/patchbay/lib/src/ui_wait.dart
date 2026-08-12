import 'generated/core_wire.g.dart';

enum PatchbayUiWaitCondition {
  semanticsMounted,
  semanticsUnmounted,
  semanticsValue,
  navigationDestination,
  treeRevision,
  frameRevision;

  PatchbayUiWaitConditionWire get wire => switch (this) {
    PatchbayUiWaitCondition.semanticsMounted =>
      PatchbayUiWaitConditionWire.semanticsMounted,
    PatchbayUiWaitCondition.semanticsUnmounted =>
      PatchbayUiWaitConditionWire.semanticsUnmounted,
    PatchbayUiWaitCondition.semanticsValue =>
      PatchbayUiWaitConditionWire.semanticsValue,
    PatchbayUiWaitCondition.navigationDestination =>
      PatchbayUiWaitConditionWire.navigationDestination,
    PatchbayUiWaitCondition.treeRevision =>
      PatchbayUiWaitConditionWire.treeRevision,
    PatchbayUiWaitCondition.frameRevision =>
      PatchbayUiWaitConditionWire.frameRevision,
  };

  static PatchbayUiWaitCondition fromWire(PatchbayUiWaitConditionWire wire) =>
      switch (wire) {
        PatchbayUiWaitConditionWire.semanticsMounted => semanticsMounted,
        PatchbayUiWaitConditionWire.semanticsUnmounted => semanticsUnmounted,
        PatchbayUiWaitConditionWire.semanticsValue => semanticsValue,
        PatchbayUiWaitConditionWire.navigationDestination =>
          navigationDestination,
        PatchbayUiWaitConditionWire.treeRevision => treeRevision,
        PatchbayUiWaitConditionWire.frameRevision => frameRevision,
      };
}

/// Validated, consumer-neutral request for one bounded Flutter observation.
final class PatchbayUiWaitRequest {
  PatchbayUiWaitRequest({
    required this.condition,
    required this.timeout,
    this.semanticsIdentifier,
    this.value,
    this.destinationId,
    this.revision,
  }) {
    if (timeout <= Duration.zero || timeout > const Duration(minutes: 2)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'must be greater than zero and at most two minutes',
      );
    }
    if (revision != null && revision! < 0) {
      throw ArgumentError.value(revision, 'revision', 'must be non-negative');
    }
    _validateShape();
  }

  factory PatchbayUiWaitRequest.fromWire(PatchbayUiWaitRequestWire wire) =>
      PatchbayUiWaitRequest(
        condition: PatchbayUiWaitCondition.fromWire(wire.condition),
        timeout: Duration(milliseconds: wire.timeoutMs),
        semanticsIdentifier: wire.semanticsIdentifier,
        value: wire.value,
        destinationId: wire.destinationId,
        revision: wire.revision,
      );

  final PatchbayUiWaitCondition condition;
  final Duration timeout;
  final String? semanticsIdentifier;
  final String? value;
  final String? destinationId;
  final int? revision;

  PatchbayUiWaitRequestWire toWire() => PatchbayUiWaitRequestWire(
    condition: condition.wire,
    timeoutMs: timeout.inMilliseconds,
    semanticsIdentifier: semanticsIdentifier,
    value: value,
    destinationId: destinationId,
    revision: revision,
  );

  void _validateShape() {
    final bool hasSemantics =
        semanticsIdentifier != null && semanticsIdentifier!.isNotEmpty;
    final bool hasDestination =
        destinationId != null && _stableDestinationId.hasMatch(destinationId!);
    switch (condition) {
      case PatchbayUiWaitCondition.semanticsMounted ||
          PatchbayUiWaitCondition.semanticsUnmounted:
        if (!hasSemantics ||
            value != null ||
            destinationId != null ||
            revision != null) {
          throw const FormatException(
            'semantics mounted/unmounted requires only semanticsIdentifier',
          );
        }
      case PatchbayUiWaitCondition.semanticsValue:
        if (!hasSemantics ||
            value == null ||
            destinationId != null ||
            revision != null) {
          throw const FormatException(
            'semanticsValue requires semanticsIdentifier and value',
          );
        }
      case PatchbayUiWaitCondition.navigationDestination:
        if (!hasDestination || semanticsIdentifier != null || value != null) {
          throw const FormatException(
            'navigationDestination requires destinationId and optional revision',
          );
        }
      case PatchbayUiWaitCondition.treeRevision ||
          PatchbayUiWaitCondition.frameRevision:
        if (revision == null ||
            semanticsIdentifier != null ||
            value != null ||
            destinationId != null) {
          throw const FormatException(
            'revision waits require only a non-negative revision',
          );
        }
    }
  }
}

final RegExp _stableDestinationId = RegExp(
  r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$',
);
