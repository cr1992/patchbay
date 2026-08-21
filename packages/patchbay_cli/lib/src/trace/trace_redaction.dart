import 'dart:convert';
import 'dart:math';

import 'trace_models.dart';

final RegExp traceIdPattern = RegExp(r'^tr_[a-z0-9]+_[a-f0-9]{20}$');
final RegExp sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

void validateTraceId(String traceId) {
  if (!traceIdPattern.hasMatch(traceId)) {
    throw const PatchbayTraceException('traceIdInvalid');
  }
}

String newTraceId(DateTime now, {String prefix = 'tr'}) {
  final Random random = Random.secure();
  final String nonce = List<int>.generate(
    10,
    (_) => random.nextInt(256),
  ).map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${prefix}_${now.microsecondsSinceEpoch.toRadixString(36)}_$nonce';
}

String canonicalTraceJson(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map<Object?, Object?>) {
      final List<String> keys = item.keys.map((Object? key) => '$key').toList()
        ..sort();
      return <String, Object?>{
        for (final String key in keys) key: canonical(item[key]),
      };
    }
    if (item is List<Object?>) {
      return <Object?>[for (final Object? child in item) canonical(child)];
    }
    return item;
  }

  return jsonEncode(canonical(value));
}

Map<String, Object?> redactMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: redactValue(entry.key, entry.value),
    });

Object? redactValue(String key, Object? value) {
  final String normalized = key.toLowerCase().replaceAll(
    RegExp('[^a-z0-9]'),
    '',
  );
  if (const <String>{
    'globalx',
    'globaly',
    'absolutex',
    'absolutey',
    'screenx',
    'screeny',
    'globalposition',
    'screenposition',
  }.contains(normalized)) {
    return const <String, Object?>{
      'redacted': true,
      'reason': 'absoluteCoordinate',
    };
  }
  if (value is Map<Object?, Object?> && value['redacted'] == true) {
    return redactMap(<String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    });
  }
  if (const <String>{
    'token',
    'authorization',
    'cookie',
    'wsuri',
    'password',
    'secret',
  }.contains(normalized)) {
    return const <String, Object?>{'redacted': true};
  }
  if (value is Map<Object?, Object?>) {
    return redactMap(<String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    });
  }
  if (value is List<Object?>) {
    return <Object?>[for (final Object? item in value) redactValue('', item)];
  }
  return value;
}

Map<String, Object?> portableTraceMap(Map<String, Object?> value) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: portableTraceValue(entry.key, entry.value),
    };

Object? portableTraceValue(String key, Object? value) {
  final Object? redacted = redactValue(key, value);
  if (redacted is String && looksAbsolutePath(redacted)) {
    return '<redacted:absolute-path>';
  }
  if (redacted is Map<Object?, Object?>) {
    return portableTraceMap(<String, Object?>{
      for (final MapEntry<Object?, Object?> entry in redacted.entries)
        '${entry.key}': entry.value,
    });
  }
  if (redacted is List<Object?>) {
    return <Object?>[
      for (final Object? item in redacted) portableTraceValue('', item),
    ];
  }
  return redacted;
}

bool looksAbsolutePath(String value) =>
    value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
