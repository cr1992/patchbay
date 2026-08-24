import 'dart:convert';
import 'dart:io';

import '../platform/process_utils.dart';
import 'session_models.dart';

final class PatchbaySessionStore {
  PatchbaySessionStore([String? directory])
    : directory = Directory(directory ?? defaultPatchbaySessionDirectory());

  final Directory directory;

  List<PatchbaySessionRecord> readAll() {
    if (!directory.existsSync()) return const [];
    final records = <PatchbaySessionRecord>[];
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(entity.readAsStringSync());
        if (decoded is! Map<String, dynamic>) {
          throw const PatchbaySessionException('sessionRecordInvalid');
        }
        final record = PatchbaySessionRecord.fromJson(
          Map<String, Object?>.from(decoded),
        );
        if (_fileName(record.sessionId) != entity.path) {
          throw const PatchbaySessionException('sessionRecordInvalid');
        }
        records.add(record);
      } on Object {
        _removeFile(entity);
      }
    }
    records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return records;
  }

  void write(PatchbaySessionRecord record) {
    _validateSessionId(record.sessionId);
    _ensureDirectory();
    final target = File(_fileName(record.sessionId));
    final temporary = createRestrictedFileSync(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void remove(String sessionId) {
    _validateSessionId(sessionId);
    _removeFile(File(_fileName(sessionId)));
  }

  /// The session id pinned for commands that pass no `--session`, if any.
  String? readSelection() {
    final File file = File(_selectionFileName);
    if (!file.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != patchbaySessionSchemaVersion) {
        throw const PatchbaySessionException('sessionSelectionInvalid');
      }
      final Object? sessionId = decoded['sessionId'];
      if (sessionId is! String) {
        throw const PatchbaySessionException('sessionSelectionInvalid');
      }
      _validateSessionId(sessionId);
      return sessionId;
    } on Object {
      _removeFile(file);
      return null;
    }
  }

  void writeSelection(String sessionId) {
    _validateSessionId(sessionId);
    _ensureDirectory();
    final File temporary = createRestrictedFileSync(
      '$_selectionFileName.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': patchbaySessionSchemaVersion,
          'sessionId': sessionId,
        }),
        flush: true,
      );
      temporary.renameSync(_selectionFileName);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void clearSelection() => _removeFile(File(_selectionFileName));

  String get _selectionFileName =>
      '${directory.path}${Platform.pathSeparator}selected-session';

  String _fileName(String sessionId) {
    _validateSessionId(sessionId);
    return '${directory.path}${Platform.pathSeparator}$sessionId.json';
  }

  void _ensureDirectory() =>
      PlatformProcessUtils.ensureRestrictedDirectorySync(directory);

  void _removeFile(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // A concurrent launcher may already have replaced or removed it.
    }
  }

  static void _validateSessionId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
      throw const PatchbaySessionException('sessionIdInvalid');
    }
  }
}
