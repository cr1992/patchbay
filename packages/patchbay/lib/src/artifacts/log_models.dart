import 'dart:async';

import '../generated/core_wire.g.dart';

/// A log record whose public constructor enforces Patchbay's defensive
/// redaction boundary before a consumer source can return it.
final class PatchbayRedactedLogRecord {
  PatchbayRedactedLogRecord({
    required String cursor,
    required DateTime at,
    required PatchbayLogLevelWire level,
    required String category,
    required String message,
    Map<String, Object?> fields = const <String, Object?>{},
  }) : wire = PatchbayLogRecordWire(
         cursor: nonEmpty(cursor, 'cursor'),
         at: at.toUtc().toIso8601String(),
         level: level,
         category: nonEmpty(category, 'category'),
         message: checkedText(message, r'$.message'),
         fields: checkedFields(fields),
         redaction: PatchbayLogRedactionWire.consumerRedacted,
         source: PatchbayFactSourceWire.appRecorded,
       ) {
    wire.toJson();
  }

  final PatchbayLogRecordWire wire;
}

final class PatchbayLogRedactionFailure implements Exception {
  const PatchbayLogRedactionFailure(this.path);

  final String path;

  @override
  String toString() => 'PatchbayLogRedactionFailure($path)';
}

final class PatchbayLogRecordTooLarge implements Exception {
  const PatchbayLogRecordTooLarge(this.encodedBytes);

  final int encodedBytes;
}

final class PatchbayLogSourceContractFailure implements Exception {
  const PatchbayLogSourceContractFailure(this.reason);

  final String reason;
}

enum PatchbayLogPageState { records, staleCursor }

/// Consumer-owned query result. Patchbay applies its own response bounds after
/// the source returns and never subscribes to or takes ownership of the source.
final class PatchbayLogPage {
  const PatchbayLogPage.records({
    this.records = const <PatchbayRedactedLogRecord>[],
    this.nextCursor,
    this.sourceTruncated = false,
  }) : state = PatchbayLogPageState.records,
       currentCursor = null;

  const PatchbayLogPage.staleCursor({required this.currentCursor})
    : state = PatchbayLogPageState.staleCursor,
      records = const <PatchbayRedactedLogRecord>[],
      nextCursor = null,
      sourceTruncated = false;

  final PatchbayLogPageState state;
  final List<PatchbayRedactedLogRecord> records;
  final String? nextCursor;
  final String? currentCursor;
  final bool sourceTruncated;
}

final class PatchbayLogQuery {
  const PatchbayLogQuery({
    required this.direction,
    required this.limit,
    this.cursor,
    this.levels = const <PatchbayLogLevelWire>{},
    this.categories = const <String>{},
    this.since,
    this.until,
  });

  final String? cursor;
  final PatchbayLogDirectionWire direction;
  final int limit;
  final Set<PatchbayLogLevelWire> levels;
  final Set<String> categories;
  final DateTime? since;
  final DateTime? until;
}

final class PatchbayCancellationSignal {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get cancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
  }
}

/// Consumer injection seam for already-redacted structured records.
abstract interface class PatchbayLogSource {
  Future<PatchbayLogPage> query(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  );

  /// Waits for records strictly after [PatchbayLogQuery.cursor]. The service
  /// still owns and enforces the outer timeout and cancels this signal when it
  /// expires or is disposed.
  Future<PatchbayLogPage> tail(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  );
}

String nonEmpty(String value, String name) {
  if (value.isEmpty) throw FormatException('$name must not be empty');
  return value;
}

String checkedText(String value, String path) {
  final RegExp credential = RegExp(
    r'(?:\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})',
    caseSensitive: false,
  );
  if (credential.hasMatch(value)) throw PatchbayLogRedactionFailure(path);
  return value;
}

Map<String, Object?> checkedFields(Map<String, Object?> fields) {
  const Set<String> sensitiveKeys = <String>{
    'password',
    'passwd',
    'secret',
    'token',
    'accesstoken',
    'refreshtoken',
    'authorization',
    'cookie',
    'setcookie',
    'apikey',
    'privatekey',
  };

  Object? check(Object? value, String path) {
    if (value is String) return checkedText(value, path);
    if (value is num || value is bool || value == null) return value;
    if (value is List) {
      return <Object?>[
        for (var index = 0; index < value.length; index += 1)
          check(value[index], '$path[$index]'),
      ];
    }
    if (value is Map) {
      final Map<String, Object?> map;
      try {
        map = Map<String, Object?>.from(value);
      } on Object {
        throw FormatException('$path must have string keys');
      }
      final Map<String, Object?> checked = <String, Object?>{};
      for (final MapEntry<String, Object?> entry in map.entries) {
        if (sensitiveKeys.contains(
          entry.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), ''),
        )) {
          throw PatchbayLogRedactionFailure('$path.${entry.key}');
        }
        checked[entry.key] = check(entry.value, '$path.${entry.key}');
      }
      return checked;
    }
    throw FormatException('$path must be JSON-compatible');
  }

  return check(fields, r'$.fields')! as Map<String, Object?>;
}
