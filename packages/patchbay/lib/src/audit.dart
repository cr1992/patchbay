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
