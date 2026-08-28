import 'dart:async';
import 'dart:convert';

/// One redacted command audit fact retained by [PatchbayServiceHost].
///
/// [parameterShape] contains only JSON types, object keys and coarse length
/// buckets. Scalar values and hashes never cross this boundary.
final class PatchbayAuditEvent {
  const PatchbayAuditEvent({
    required this.command,
    required this.requestId,
    required this.parameterShape,
    required this.gateResult,
    required this.executionClassification,
  });

  final String command;
  final String requestId;
  final Map<String, Object?> parameterShape;
  final String gateResult;
  final String? executionClassification;

  Map<String, Object?> toJson() => <String, Object?>{
    'command': command,
    'requestId': requestId,
    'parameterShape': parameterShape,
    'gateResult': gateResult,
    'executionClassification': executionClassification,
  };
}

typedef PatchbayAuditSink = FutureOr<void> Function(PatchbayAuditEvent event);

typedef PatchbayAuditSinkErrorHandler =
    void Function(
      Object error,
      StackTrace stackTrace,
      PatchbayAuditEvent event,
    );

/// The terminal outcome of one host audit-delivery drain.
enum PatchbayAuditDrainOutcome { drained, timedOut }

/// Immutable accounting for the audit events accepted before the drain gate.
final class PatchbayAuditDrainResult {
  const PatchbayAuditDrainResult({
    required this.outcome,
    required this.settledCount,
    required this.overflowDroppedCount,
    required this.abandonedCount,
  });

  final PatchbayAuditDrainOutcome outcome;
  final int settledCount;
  final int overflowDroppedCount;
  final int abandonedCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome.name,
    'settledCount': settledCount,
    'overflowDroppedCount': overflowDroppedCount,
    'abandonedCount': abandonedCount,
  };
}

/// Reports one complete burst of audit events dropped by bounded delivery.
///
/// The error contains sequence accounting only. The matching redacted event is
/// passed separately to [PatchbayAuditSinkErrorHandler].
final class PatchbayAuditDeliveryOverflow implements Exception {
  const PatchbayAuditDeliveryOverflow({
    required this.droppedCount,
    required this.firstSequence,
    required this.lastSequence,
    required this.capacity,
  });

  final int droppedCount;
  final int firstSequence;
  final int lastSequence;
  final int capacity;

  @override
  String toString() =>
      'PatchbayAuditDeliveryOverflow('
      'droppedCount: $droppedCount, '
      'firstSequence: $firstSequence, '
      'lastSequence: $lastSequence, '
      'capacity: $capacity)';
}

/// Reports a ledger event recorded after audit delivery was closed.
final class PatchbayAuditDeliveryClosed implements Exception {
  const PatchbayAuditDeliveryClosed({required this.sequence});

  final int sequence;

  @override
  String toString() => 'PatchbayAuditDeliveryClosed(sequence: $sequence)';
}

/// The stable execution classification projected by both host audit and CLI
/// trace consumers from one invocation response.
///
/// The transport boundary remains explicit: host-only audit events are not
/// streamed back to the CLI. Sharing this pure projection prevents the two
/// persisted views from assigning different meanings to a response they both
/// observed without inventing a cross-process event channel.
String? patchbayAuditExecutionClassification(Map<String, Object?> response) {
  final Object? payload = response['payload'];
  final Object? execution = payload is Map<Object?, Object?>
      ? payload['execution']
      : null;
  final Object? raw = execution is Map<Object?, Object?>
      ? execution['classification']
      : null;
  return raw is String &&
          const <String>{
            'notSent',
            'sentUnconfirmed',
            'unchanged',
            'deviceConfirmed',
          }.contains(raw)
      ? raw
      : null;
}

/// Builds the redacted audit projection from a command fact.
PatchbayAuditEvent patchbayProjectAuditEvent({
  required String command,
  required String requestId,
  required Map<String, Object?> arguments,
  required String gateResult,
  required Map<String, Object?> response,
}) => PatchbayAuditEvent(
  command: command,
  requestId: requestId,
  parameterShape: patchbayParameterShape(arguments),
  gateResult: gateResult,
  executionClassification: patchbayAuditExecutionClassification(response),
);

/// Produces a recursively redacted JSON shape without retaining scalar values.
Map<String, Object?> patchbayParameterShape(Map<String, Object?> arguments) =>
    _shape(arguments);

Map<String, Object?> _shape(Object? value) {
  if (value == null) return const <String, Object?>{'type': 'null'};
  if (value is bool) return const <String, Object?>{'type': 'boolean'};
  if (value is int) return const <String, Object?>{'type': 'integer'};
  if (value is num) return const <String, Object?>{'type': 'number'};
  if (value is String) {
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      'type': 'string',
      'length': _lengthBucket(value.length),
    });
  }
  if (value is List<Object?>) {
    final Map<String, Map<String, Object?>> itemShapes =
        <String, Map<String, Object?>>{};
    for (final Object? item in value) {
      final Map<String, Object?> shape = _shape(item);
      itemShapes.putIfAbsent(jsonEncode(shape), () => shape);
    }
    final List<String> sortedShapes = itemShapes.keys.toList()..sort();
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      'type': 'array',
      'length': _lengthBucket(value.length),
      'items': List<Map<String, Object?>>.unmodifiable(<Map<String, Object?>>[
        for (final String key in sortedShapes) itemShapes[key]!,
      ]),
    });
  }
  if (value is Map<Object?, Object?>) {
    final List<MapEntry<String, Object?>> entries =
        value.entries
            .map(
              (MapEntry<Object?, Object?> entry) =>
                  MapEntry<String, Object?>('${entry.key}', entry.value),
            )
            .toList()
          ..sort(
            (MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
                a.key.compareTo(b.key),
          );
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      'type': 'object',
      'length': _lengthBucket(entries.length),
      'keys': Map<String, Object?>.unmodifiable(<String, Object?>{
        for (final MapEntry<String, Object?> entry in entries)
          entry.key: _shape(entry.value),
      }),
    });
  }
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'unsupported',
  });
}

String _lengthBucket(int length) => switch (length) {
  0 => '0',
  1 => '1',
  >= 2 && <= 5 => '2-5',
  >= 6 && <= 20 => '6-20',
  _ => '21+',
};
