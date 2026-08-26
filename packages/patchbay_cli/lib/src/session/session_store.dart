import 'dart:convert';
import 'dart:io';

import '../platform/process_utils.dart';
import 'session_models.dart';
import 'workspace_identity.dart';

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

  /// The session id [identity]'s workspace pinned, if any.
  ///
  /// The file name carries the workspace digest and the body repeats the full
  /// `workspaceId`; both are cross-checked against [identity] on every read.
  /// A pin that fails any check is discarded rather than obeyed -- obeying a
  /// pin whose provenance we cannot confirm is exactly the misdirection this
  /// feature removes -- and discarding never touches session records.
  String? readSelectionFor(PatchbayWorkspaceIdentity identity) {
    final File file = File(_scopedSelectionFileName(identity.digest));
    if (!file.existsSync()) return null;
    try {
      if (file.lengthSync() > patchbayScopedSelectionMaximumBytes) {
        throw const PatchbaySessionException('sessionSelectionInvalid');
      }
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != patchbaySessionSchemaVersion ||
          decoded['workspaceId'] != identity.workspaceId) {
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

  /// Pins [sessionId] for [identity]'s workspace only.
  ///
  /// Serialised through the directory lock together with pin pruning, so the
  /// capacity check sees a settled set rather than one another process is in
  /// the middle of changing. Throws `sessionSelectionCapacityExceeded` when
  /// [patchbayScopedSelectionMaximumCount] distinct workspaces still hold a
  /// live pin: evicting one of those would silently re-aim somebody else's
  /// next command.
  void writeSelectionFor(PatchbayWorkspaceIdentity identity, String sessionId) {
    _validateSessionId(sessionId);
    _ensureDirectory();
    _withDirectoryLock(() {
      final String target = _scopedSelectionFileName(identity.digest);
      // Only a *new* workspace can push the directory over the cap, and only
      // then is the (directory-wide) prune worth paying for.
      if (!File(target).existsSync() &&
          _scopedSelectionFiles().length >=
              patchbayScopedSelectionMaximumCount) {
        _pruneScopedSelectionsLocked();
        if (_scopedSelectionFiles().length >=
            patchbayScopedSelectionMaximumCount) {
          throw const PatchbaySessionException(
            'sessionSelectionCapacityExceeded',
            hint:
                'this session directory already pins the maximum number of '
                'workspaces; run `patchbay sessions prune`, or use '
                '--session <session-id> per command',
          );
        }
      }
      _atomicallyWrite(
        target,
        jsonEncode(<String, Object?>{
          'schemaVersion': patchbaySessionSchemaVersion,
          'workspaceId': identity.workspaceId,
          'sessionId': sessionId,
        }),
      );
    });
  }

  void clearSelectionFor(PatchbayWorkspaceIdentity identity) =>
      _removeFile(File(_scopedSelectionFileName(identity.digest)));

  /// The 64-hex digests of every scoped pin currently on disk.
  List<String> scopedSelectionDigests() => _scopedSelectionFiles()
      .map(
        (File file) =>
            file.uri.pathSegments.last.substring(_scopedSelectionPrefix.length),
      )
      .toList(growable: false);

  /// Removes scoped pins naming a session id that no longer has a record, and
  /// the retired global pin. Returns the digests it cleared.
  List<String> pruneScopedSelections() {
    if (!directory.existsSync()) return const <String>[];
    final List<String> cleared = <String>[];
    _withDirectoryLock(() {
      cleared.addAll(_pruneScopedSelectionsLocked());
      _removeFile(File(_retiredSelectionFileName));
    });
    return cleared;
  }

  /// The session id the pre-PB-050-14 global pin names, if that file is still
  /// there. Reading it is *not* selection: only [migrateLegacyGlobalSelection]
  /// may act on it, and only once.
  String? readLegacyGlobalSelection() {
    final File file = File(_legacySelectionFileName);
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

  /// Writes the legacy global pin.
  ///
  /// Nothing in this package calls it: the whole point of PB-050-14 is that a
  /// workspace-aware CLI stops writing this file, and dual-writing it "for
  /// old CLIs" would preserve the cross-workspace misdirection the proposal
  /// removes. It exists so migration fixtures can build the old state.
  void writeLegacyGlobalSelection(String sessionId) {
    _validateSessionId(sessionId);
    _ensureDirectory();
    _atomicallyWrite(
      _legacySelectionFileName,
      jsonEncode(<String, Object?>{
        'schemaVersion': patchbaySessionSchemaVersion,
        'sessionId': sessionId,
      }),
    );
  }

  /// Retires the pre-PB-050-14 global pin, at most once per session directory.
  ///
  /// The rename is the claim: two workspaces racing here produce exactly one
  /// `retired: true`, and the loser simply has no pin. That is the intended
  /// degrade -- losing a pin costs one `session use`, whereas inheriting the
  /// winner's pin would cost a write command sent to the wrong device.
  ///
  /// [adoptable] decides whether the named record can be *proven* to belong to
  /// [identity]. When it cannot -- foreign, missing, or an unprovable legacy
  /// path -- the old file is still retired but nothing is adopted; the record
  /// itself is never removed.
  ({bool retired, String? adopted}) migrateLegacyGlobalSelection(
    PatchbayWorkspaceIdentity identity, {
    required bool Function(String sessionId) adoptable,
  }) {
    if (!directory.existsSync()) {
      return (retired: false, adopted: null);
    }
    String? claimed;
    var retired = false;
    _withDirectoryLock(() {
      final File legacy = File(_legacySelectionFileName);
      if (!legacy.existsSync()) return;
      claimed = readLegacyGlobalSelection();
      try {
        legacy.renameSync(_retiredSelectionFileName);
        retired = true;
      } on FileSystemException {
        // Another process claimed it between the check and the rename.
        return;
      }
    });
    if (!retired) return (retired: false, adopted: null);
    final String? sessionId = claimed;
    if (sessionId == null || !adoptable(sessionId)) {
      return (retired: true, adopted: null);
    }
    writeSelectionFor(identity, sessionId);
    return (retired: true, adopted: sessionId);
  }

  static const String _scopedSelectionPrefix = 'selected-session-';

  String _scopedSelectionFileName(String digest) =>
      '${directory.path}${Platform.pathSeparator}'
      '$_scopedSelectionPrefix$digest';

  String get _legacySelectionFileName =>
      '${directory.path}${Platform.pathSeparator}selected-session';

  String get _retiredSelectionFileName => '$_legacySelectionFileName.legacy';

  List<File> _scopedSelectionFiles() {
    if (!directory.existsSync()) return const <File>[];
    return directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((File file) {
          final String name = file.uri.pathSegments.last;
          return name.length == _scopedSelectionPrefix.length + _digestLength &&
              name.startsWith(_scopedSelectionPrefix) &&
              _digestShape.hasMatch(
                name.substring(_scopedSelectionPrefix.length),
              );
        })
        .toList(growable: false);
  }

  /// Clears pins whose session record is gone. Caller holds the lock.
  List<String> _pruneScopedSelectionsLocked() {
    final Set<String> known = <String>{
      for (final PatchbaySessionRecord record in readAll()) record.sessionId,
    };
    final List<String> cleared = <String>[];
    for (final File file in _scopedSelectionFiles()) {
      final String? sessionId = _peekScopedSelection(file);
      if (sessionId != null && known.contains(sessionId)) continue;
      cleared.add(
        file.uri.pathSegments.last.substring(_scopedSelectionPrefix.length),
      );
      _removeFile(file);
    }
    return cleared;
  }

  /// Reads a pin's session id without the identity cross-check, for pruning.
  String? _peekScopedSelection(File file) {
    try {
      if (file.lengthSync() > patchbayScopedSelectionMaximumBytes) return null;
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final Object? sessionId = decoded['sessionId'];
      return sessionId is String ? sessionId : null;
    } on Object {
      return null;
    }
  }

  void _atomicallyWrite(String target, String contents) {
    final File temporary = createRestrictedFileSync(
      '$target.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(contents, flush: true);
      temporary.renameSync(target);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  /// Serialises pin writes, pruning and legacy retirement across processes.
  ///
  /// Best-effort by design: if the lock file itself cannot be opened or
  /// locked, the body still runs. Every write underneath it is an atomic
  /// temp+rename, so losing the lock costs interleaving, never a torn file.
  void _withDirectoryLock(void Function() body) {
    final File lockFile = File(
      '${directory.path}${Platform.pathSeparator}selection.lock',
    );
    RandomAccessFile? lock;
    try {
      lock = lockFile.openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException {
      lock?.closeSync();
      lock = null;
    }
    try {
      body();
    } finally {
      if (lock != null) {
        try {
          lock.unlockSync();
        } on FileSystemException {
          // Releasing a lock we no longer hold is not worth failing over.
        }
        lock.closeSync();
      }
    }
  }

  static const int _digestLength = 64;
  static final RegExp _digestShape = RegExp(r'^[0-9a-f]{64}$');

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
