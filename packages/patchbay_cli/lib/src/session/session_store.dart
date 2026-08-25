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
        _quarantineFile(entity);
      }
    }
    records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return records;
  }

  /// Files [readAll] could not parse, moved aside rather than deleted.
  ///
  /// A record that fails to parse is evidence of something worth explaining
  /// (a bug, a downgrade, a half-written file that lost the temp+rename
  /// race) -- deleting it destroys that evidence and, worse, makes a
  /// version bump on the record schema look like "the session vanished"
  /// instead of "the CLI refused to read it" (see `docs/design.md`,
  /// 本地会话文件是第三个兼容面). Nothing in this package re-reads these
  /// files: `patchbay doctor` is expected to report their existence and
  /// path so an operator can inspect them.
  List<File> quarantinedFiles() {
    if (!directory.existsSync()) return const [];
    return directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((File file) => file.path.contains(_quarantineMarker))
        .toList(growable: false);
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

  /// The infix a quarantined file's name always contains.
  ///
  /// Renaming rather than appending keeps the original `.json` filename
  /// intact as a prefix (so it stays identifiable at a glance) while no
  /// longer ending in `.json` -- which is exactly what makes [readAll]'s
  /// directory scan skip it on every later pass, with no extra state to
  /// track: the rename itself is the "already processed" marker.
  static const String _quarantineMarker = '.quarantine-';

  /// Moves a file `readAll` could not parse aside instead of deleting it.
  ///
  /// The unique `pid`+microsecond suffix means a second corrupt file that
  /// reuses the same session id filename (e.g. after a crash-loop) quarantines
  /// alongside the first instead of overwriting it.
  void _quarantineFile(File file) {
    try {
      if (!file.existsSync()) return;
      final String quarantined =
          '${file.path}$_quarantineMarker$pid-${DateTime.now().microsecondsSinceEpoch}';
      file.renameSync(quarantined);
    } on FileSystemException {
      // Best-effort: if the rename itself fails (permissions, a concurrent
      // process already moved or removed it), leave the file where it is.
      // It still won't parse next time either, so the caller sees the same
      // evidence again rather than losing it -- and readAll must keep going
      // either way, never abort the rest of the directory scan over this.
    }
  }

  static void _validateSessionId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
      throw const PatchbaySessionException('sessionIdInvalid');
    }
  }
}
