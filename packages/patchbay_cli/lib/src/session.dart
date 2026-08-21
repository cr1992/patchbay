import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';

import 'client.dart';
import 'platform/process_utils.dart';

const int patchbaySessionSchemaVersion = 1;
const Duration patchbayPendingDefaultTtl = Duration(minutes: 5);
const Duration patchbayPendingMaximumTtl = Duration(minutes: 30);

/// What to do when more than one session is discoverable and none was named.
const String patchbaySessionAmbiguousHint =
    'run `patchbay session use <session-id>` to pin one for later commands, '
    'or pass --session per command';

/// What to do when the pinned session no longer resolves.
///
/// The pin is never cleared on the CLI's own initiative: doing so would turn
/// "the session you selected is gone" into "the CLI quietly picked a different
/// one", which is the guess this whole path exists to refuse.
const String patchbaySessionSelectionStaleHint =
    'the pinned session no longer resolves: run `patchbay sessions prune` or '
    '`patchbay session use --clear`, then select again';

String defaultPatchbaySessionDirectory({Map<String, String>? environment}) {
  final variables = environment ?? Platform.environment;
  final override = variables['PATCHBAY_SESSION_DIR']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'patchbay-sessions-v1';
}

/// Creates [path] empty and owner-only **before** any content is written to it.
///
/// Session records carry the VM Service authentication URI. `writeAsStringSync`
/// creates the file with the process umask — commonly `0644` — so a `chmod`
/// issued *after* the write leaves a window in which the token is world-readable
/// on a shared machine. Creating the file while it is still empty and
/// restricting it there removes that window: by the time any secret reaches the
/// file, the mode is already `0600`.
///
/// `exclusive: true` additionally refuses to write through a file another user
/// planted at that path; the session directory lives under the world-writable
/// system temp directory, so that is not hypothetical.
File createRestrictedFileSync(String path) =>
    PlatformProcessUtils.createRestrictedFileSync(path);

final class PatchbaySessionException implements Exception {
  const PatchbaySessionException(
    this.code, {
    this.choices = const [],
    this.hint,
  });

  final String code;
  final List<String> choices;

  /// One actionable sentence, when the code alone leaves the operator stuck.
  ///
  /// It never carries a URI or a token — the same rule the choice labels
  /// follow — because it is printed on stderr and echoed into `--json`.
  final String? hint;

  @override
  String toString() => 'PatchbaySessionException($code)';
}

final class PatchbaySessionRecord {
  const PatchbaySessionRecord({
    required this.sessionId,
    required this.applicationId,
    required this.appInstanceId,
    required this.isolateId,
    required this.processId,
    required this.wsUri,
    required this.buildMode,
    required this.createdAt,
    required this.workspacePath,
    required this.deviceId,
    this.state,
    this.ownerPid,
    this.launchId,
    this.observedAtMs,
    this.expiresAtMs,
  });

  factory PatchbaySessionRecord.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != patchbaySessionSchemaVersion) {
      throw const PatchbaySessionException('sessionSchemaMismatch');
    }
    final sessionId = json['sessionId'];
    final applicationId = json['applicationId'];
    final appInstanceId = json['appInstanceId'];
    final isolateId = json['isolateId'];
    final processId = json['processId'];
    final wsUri = json['wsUri'];
    final buildMode = json['buildMode'];
    final createdAt = json['createdAt'];
    final workspacePath = json['workspacePath'];
    final deviceId = json['deviceId'];
    final state = json['state'];
    final ownerPid = json['ownerPid'];
    final launchId = json['launchId'];
    final observedAtMs = json['observedAtMs'];
    final expiresAtMs = json['expiresAtMs'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        applicationId is! String ||
        applicationId.isEmpty ||
        processId is! int ||
        processId <= 0 ||
        buildMode is! String ||
        buildMode.isEmpty ||
        createdAt is! String ||
        DateTime.tryParse(createdAt) == null ||
        workspacePath is! String ||
        workspacePath.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        (appInstanceId != null && appInstanceId is! String) ||
        (isolateId != null && isolateId is! String) ||
        (wsUri != null && wsUri is! String) ||
        (state != null &&
            (state is! String ||
                !PatchbaySessionStatus.values.any(
                  (value) => value.name == state,
                ))) ||
        (ownerPid != null && (ownerPid is! int || ownerPid <= 0)) ||
        (launchId != null && (launchId is! String || launchId.isEmpty)) ||
        (observedAtMs != null && (observedAtMs is! int || observedAtMs < 0)) ||
        (expiresAtMs != null && (expiresAtMs is! int || expiresAtMs < 0))) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    return PatchbaySessionRecord(
      sessionId: sessionId,
      applicationId: applicationId,
      appInstanceId: appInstanceId as String?,
      isolateId: isolateId as String?,
      processId: processId,
      wsUri: wsUri as String?,
      buildMode: buildMode,
      createdAt: DateTime.parse(createdAt).toUtc(),
      workspacePath: workspacePath,
      deviceId: deviceId,
      state: state == null
          ? null
          : PatchbaySessionStatus.values.byName(state as String),
      ownerPid: ownerPid as int?,
      launchId: launchId as String?,
      observedAtMs: observedAtMs as int?,
      expiresAtMs: expiresAtMs as int?,
    );
  }

  final String sessionId;
  final String applicationId;
  final String? appInstanceId;
  final String? isolateId;
  final int processId;
  final String? wsUri;
  final String buildMode;
  final DateTime createdAt;
  final String workspacePath;
  final String deviceId;
  final PatchbaySessionStatus? state;
  final int? ownerPid;
  final String? launchId;
  final int? observedAtMs;
  final int? expiresAtMs;

  bool get isComplete =>
      appInstanceId != null && isolateId != null && wsUri != null;

  /// Last path segment of the workspace, which is what tells two runs apart.
  String get workspaceName =>
      workspacePath
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      workspacePath;

  /// Transport endpoint with the authentication material removed.
  ///
  /// A VM Service URI carries its auth token in the path, so anything that
  /// prints a record — a listing, a choice label, a hint — may show scheme,
  /// host and port and must stop there. `null` while the launcher has not
  /// written a URI yet.
  String? get maskedEndpoint {
    final String? raw = wsUri;
    if (raw == null) return null;
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.scheme}://${uri.host}';
  }

  String get choiceLabel =>
      '$sessionId app=$applicationId mode=$buildMode workspace=$workspaceName';

  PatchbaySessionRecord completedWith(
    PatchbayRuntimeIdentity identity, {
    int? observedAtMs,
  }) => PatchbaySessionRecord(
    sessionId: sessionId,
    applicationId: identity.applicationId,
    appInstanceId: identity.appInstanceId,
    isolateId: identity.isolateId,
    processId: processId,
    wsUri: wsUri,
    buildMode: buildMode,
    createdAt: createdAt,
    workspacePath: workspacePath,
    deviceId: deviceId,
    state: PatchbaySessionStatus.live,
    ownerPid: ownerPid,
    launchId: launchId,
    observedAtMs: observedAtMs ?? this.observedAtMs,
    expiresAtMs: expiresAtMs,
  );

  /// Adds the child-discovered transport while keeping writer state pending.
  /// The launcher changes it to live only after identity succeeds.
  PatchbaySessionRecord withTransport(
    String wsUri, {
    required int observedAtMs,
  }) => PatchbaySessionRecord(
    sessionId: sessionId,
    applicationId: applicationId,
    appInstanceId: appInstanceId,
    isolateId: isolateId,
    processId: processId,
    wsUri: wsUri,
    buildMode: buildMode,
    createdAt: createdAt,
    workspacePath: workspacePath,
    deviceId: deviceId,
    state: state ?? PatchbaySessionStatus.pending,
    ownerPid: ownerPid,
    launchId: launchId,
    observedAtMs: observedAtMs,
    expiresAtMs: expiresAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': patchbaySessionSchemaVersion,
    'sessionId': sessionId,
    'applicationId': applicationId,
    'appInstanceId': appInstanceId,
    'isolateId': isolateId,
    'processId': processId,
    'wsUri': wsUri,
    'buildMode': buildMode,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'workspacePath': workspacePath,
    'deviceId': deviceId,
    if (state != null) 'state': state!.name,
    if (ownerPid != null) 'ownerPid': ownerPid,
    if (launchId != null) 'launchId': launchId,
    if (observedAtMs != null) 'observedAtMs': observedAtMs,
    if (expiresAtMs != null) 'expiresAtMs': expiresAtMs,
  };
}

/// Additive child-declaration context injected by `patchbay launch`.
final class PatchbayLaunchContext {
  const PatchbayLaunchContext({
    required this.sessionDirectory,
    required this.launchId,
    required this.ownerPid,
  });

  static const String sessionDirectoryKey = 'PATCHBAY_SESSION_DIR';
  static const String launchIdKey = 'PATCHBAY_LAUNCH_ID';
  static const String ownerPidKey = 'PATCHBAY_LAUNCH_OWNER_PID';

  factory PatchbayLaunchContext.fromEnvironment(Map<String, String> values) {
    final PatchbayLaunchContext? context = tryFromEnvironment(values);
    if (context == null) {
      throw const PatchbaySessionException('launchContextInvalid');
    }
    return context;
  }

  /// Returns no context when the consumer was not started by `patchbay launch`.
  ///
  /// A partially present declaration is invalid rather than silently treated
  /// as standalone; that catches misspelled or stripped ownership variables.
  static PatchbayLaunchContext? tryFromEnvironment(Map<String, String> values) {
    final String? directory = values[sessionDirectoryKey];
    final String? launchId = values[launchIdKey];
    final String? rawOwnerPid = values[ownerPidKey];
    if (directory == null && launchId == null && rawOwnerPid == null) {
      return null;
    }
    final int? ownerPid = int.tryParse(rawOwnerPid ?? '');
    if (directory == null ||
        directory.isEmpty ||
        launchId == null ||
        launchId.isEmpty ||
        ownerPid == null ||
        ownerPid <= 0) {
      throw const PatchbaySessionException('launchContextInvalid');
    }
    return PatchbayLaunchContext(
      sessionDirectory: directory,
      launchId: launchId,
      ownerPid: ownerPid,
    );
  }

  final String sessionDirectory;
  final String launchId;
  final int ownerPid;

  PatchbaySessionStore get store => PatchbaySessionStore(sessionDirectory);

  PatchbaySessionRecord pendingRecord({
    required String sessionId,
    required String applicationId,
    required int processId,
    required String buildMode,
    required DateTime createdAt,
    required String workspacePath,
    required String deviceId,
    Duration ttl = patchbayPendingDefaultTtl,
  }) {
    if (processId <= 0) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    if (ttl <= Duration.zero || ttl > patchbayPendingMaximumTtl) {
      throw const PatchbaySessionException('pendingTtlInvalid');
    }
    final int observed = createdAt.toUtc().millisecondsSinceEpoch;
    return PatchbaySessionRecord(
      sessionId: sessionId,
      applicationId: applicationId,
      appInstanceId: null,
      isolateId: null,
      processId: processId,
      wsUri: null,
      buildMode: buildMode,
      createdAt: createdAt,
      workspacePath: workspacePath,
      deviceId: deviceId,
      state: PatchbaySessionStatus.pending,
      ownerPid: ownerPid,
      launchId: launchId,
      observedAtMs: observed,
      expiresAtMs: observed + ttl.inMilliseconds,
    );
  }

  bool owns(PatchbaySessionRecord record) =>
      record.launchId == launchId && record.ownerPid == ownerPid;
}

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
  ///
  /// A selection that cannot be read back as a valid id is removed and
  /// reported as absent. That is not a fallback guess: with no pin the
  /// resolver still refuses to choose between several sessions, so a corrupt
  /// file costs the operator one `session use`, never a command sent to the
  /// wrong App.
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

  /// Deliberately not `*.json`: [readAll] treats every `.json` file in this
  /// directory as a session record and deletes the ones that fail to parse.
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

typedef PatchbayIdentityProbe =
    Future<PatchbayRuntimeIdentity> Function(Uri uri);
typedef PatchbayPidProbe = bool Function(int processId);
typedef PatchbaySessionClock = DateTime Function();

final class PatchbayDiscoveredSession {
  const PatchbayDiscoveredSession({
    required this.record,
    required this.identity,
  });

  final PatchbaySessionRecord record;
  final PatchbayRuntimeIdentity identity;
}

/// What a record looks like from the local machine alone.
///
/// This is a **local** judgement — process liveness plus whether the launcher
/// has written a URI yet — not a round trip to the App. Listing several
/// devices must not cost one connection attempt per record, and a live process
/// that has stopped answering is still reported as [live]; only an actual
/// command can decide reachability, and it does, with its own budget.
enum PatchbaySessionStatus {
  /// The process is alive and a transport URI has been recorded.
  live,

  /// The process is alive but the launcher has not written a URI yet.
  pending,

  /// The process that owned this record is gone.
  stale,
}

/// One record as `sessions list` reports it.
final class PatchbaySessionListing {
  const PatchbaySessionListing({
    required this.record,
    required this.status,
    required this.selected,
  });

  final PatchbaySessionRecord record;
  final PatchbaySessionStatus status;
  final bool selected;

  /// One printable line. URI-free by construction — see
  /// [PatchbaySessionRecord.maskedEndpoint].
  String get label =>
      '${record.sessionId} ${status.name} app=${record.applicationId} '
      'device=${record.deviceId} mode=${record.buildMode} '
      'workspace=${record.workspaceName}'
      '${record.maskedEndpoint == null ? '' : ' endpoint=${record.maskedEndpoint}'}';

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': record.sessionId,
    'applicationId': record.applicationId,
    'deviceId': record.deviceId,
    'buildMode': record.buildMode,
    'workspace': record.workspaceName,
    'endpoint': record.maskedEndpoint,
    'status': status.name,
    'selected': selected,
    'createdAt': record.createdAt.toUtc().toIso8601String(),
  };
}

/// What `sessions prune` removed and what is left.
final class PatchbaySessionPruneResult {
  const PatchbaySessionPruneResult({
    required this.removed,
    required this.remaining,
    required this.selectionCleared,
  });

  final List<String> removed;
  final List<PatchbaySessionListing> remaining;

  /// Whether the pinned session was among the records this run removed.
  final bool selectionCleared;
}

final class PatchbaySessionResolver {
  PatchbaySessionResolver({
    PatchbaySessionStore? store,
    PatchbayIdentityProbe? identityProbe,
    PatchbayPidProbe? pidProbe,
    PatchbaySessionClock? clock,
  }) : store = store ?? PatchbaySessionStore(),
       _identityProbe = identityProbe ?? _probeIdentity,
       _pidProbe = pidProbe ?? _isProcessAlive,
       _clock = clock ?? DateTime.now;

  final PatchbaySessionStore store;
  final PatchbayIdentityProbe _identityProbe;
  final PatchbayPidProbe _pidProbe;
  final PatchbaySessionClock _clock;

  /// The pinned session id, or `null` when nothing is pinned.
  String? get selection => store.readSelection();

  /// Every record, with the local judgement of what state it is in.
  List<PatchbaySessionListing> inventory() {
    final String? selected = store.readSelection();
    return <PatchbaySessionListing>[
      for (final PatchbaySessionRecord record in store.readAll())
        PatchbaySessionListing(
          record: record,
          status: statusOf(record),
          selected: record.sessionId == selected,
        ),
    ];
  }

  /// Removes records whose process is gone, without dialling anything.
  ///
  /// Records that no longer parse are removed by [PatchbaySessionStore.readAll]
  /// itself and cannot be named here — their id was exactly the unreadable
  /// part. Only a pin that pointed at one of the removed records is cleared:
  /// pruning must not silently unpin a session that is still there.
  PatchbaySessionPruneResult prune() {
    final List<String> removed = <String>[];
    for (final PatchbaySessionListing listing in inventory()) {
      if (listing.status != PatchbaySessionStatus.stale) continue;
      store.remove(listing.record.sessionId);
      removed.add(listing.record.sessionId);
    }
    final String? selected = store.readSelection();
    final bool cleared = selected != null && removed.contains(selected);
    if (cleared) store.clearSelection();
    return PatchbaySessionPruneResult(
      removed: removed,
      remaining: inventory(),
      selectionCleared: cleared,
    );
  }

  /// Pins [sessionId] for later commands that pass no `--session`.
  ///
  /// A record that does not exist, or whose process is already gone, is
  /// refused rather than pinned: the alternative is an operator discovering on
  /// the next command that the selection never had an App behind it.
  PatchbaySessionListing select(String sessionId) {
    final List<PatchbaySessionRecord> all = store.readAll();
    final PatchbaySessionRecord? record = all
        .where((PatchbaySessionRecord record) => record.sessionId == sessionId)
        .firstOrNull;
    if (record == null) {
      throw PatchbaySessionException(
        'sessionNotFound',
        choices: <String>[
          for (final PatchbaySessionRecord candidate in all)
            candidate.choiceLabel,
        ],
      );
    }
    final PatchbaySessionStatus status = statusOf(record);
    if (status == PatchbaySessionStatus.stale) {
      store.remove(sessionId);
      throw const PatchbaySessionException(
        'sessionStaleProcess',
        hint:
            'that record has no live process; it has been removed — run '
            '`patchbay sessions list` and select from what is left',
      );
    }
    store.writeSelection(sessionId);
    return PatchbaySessionListing(
      record: record,
      status: status,
      selected: true,
    );
  }

  void clearSelection() => store.clearSelection();

  PatchbaySessionStatus statusOf(PatchbaySessionRecord record) {
    if (!_pidProbe(record.processId)) return PatchbaySessionStatus.stale;
    final int? expiresAtMs = record.expiresAtMs;
    if (record.wsUri == null &&
        expiresAtMs != null &&
        expiresAtMs <= _clock().toUtc().millisecondsSinceEpoch) {
      return PatchbaySessionStatus.stale;
    }
    return record.wsUri == null
        ? PatchbaySessionStatus.pending
        : PatchbaySessionStatus.live;
  }

  /// Selects one session: explicit id first, then the pin, then uniqueness.
  ///
  /// The three steps are ordered, never blended. `--session` wins outright and
  /// ignores the pin. A pin narrows the candidates to exactly one record and
  /// then goes through the same liveness and identity checks as any other
  /// selection — if that record is gone or unreachable the command fails with
  /// the pin's own reason instead of falling back to whatever else happens to
  /// be running, which on a two-device bench would be the other device.
  Future<PatchbayDiscoveredSession> resolve({String? sessionId}) async {
    final all = store.readAll();
    if (all.isEmpty) {
      throw const PatchbaySessionException('sessionDirectoryEmpty');
    }
    final String? pinned = sessionId == null ? store.readSelection() : null;
    final String? wanted = sessionId ?? pinned;
    final candidates = wanted == null
        ? all
        : all.where((record) => record.sessionId == wanted).toList();
    if (candidates.isEmpty) {
      throw pinned == null
          ? const PatchbaySessionException('sessionNotFound')
          : const PatchbaySessionException(
              'sessionSelectionStale',
              hint: patchbaySessionSelectionStaleHint,
            );
    }

    final valid = <PatchbayDiscoveredSession>[];
    final pending = <PatchbaySessionRecord>[];
    String? lastStaleCode;
    for (final record in candidates) {
      if (!_pidProbe(record.processId)) {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionStaleProcess';
        continue;
      }
      final rawUri = record.wsUri;
      if (rawUri == null) {
        pending.add(record);
        continue;
      }
      final Uri uri;
      try {
        uri = Uri.parse(rawUri);
        if (!const {'http', 'https', 'ws', 'wss'}.contains(uri.scheme)) {
          throw const FormatException();
        }
      } on FormatException {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionStaleTransport';
        continue;
      }
      final PatchbayRuntimeIdentity identity;
      try {
        identity = await _identityProbe(uri);
      } on PatchbayProtocolException {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionIdentityMismatch';
        continue;
      } on Object {
        // The process is alive and the record is well-formed; this probe simply
        // did not get an answer. Deleting here would turn a locked screen or a
        // busy VM into a permanently lost session, because the launcher only
        // writes the record once per `flutter run`.
        lastStaleCode = 'sessionUnreachable';
        continue;
      }
      if (identity.schemaVersion != PatchbayServiceHost.schemaVersion ||
          identity.applicationId != record.applicationId) {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionIdentityMismatch';
        continue;
      }
      // A live process serving the same application over the same URI, with a
      // new instance or isolate, is a hot restart — not a foreign app. The
      // record is re-pinned to the new runtime instead of being discarded,
      // because `app.debugPort` is emitted once per run and would never
      // re-create it.
      if ((record.appInstanceId != null &&
              identity.appInstanceId != record.appInstanceId) ||
          (record.isolateId != null &&
              identity.isolateId != record.isolateId)) {
        lastStaleCode = 'sessionRuntimeRestarted';
      }
      final completed = record.completedWith(identity);
      store.write(completed);
      valid.add(
        PatchbayDiscoveredSession(record: completed, identity: identity),
      );
    }

    if (valid.length + pending.length > 1) {
      throw PatchbaySessionException(
        'sessionAmbiguous',
        choices: <String>[
          ...valid.map((candidate) => candidate.record.choiceLabel),
          ...pending.map((record) => record.choiceLabel),
        ],
        hint: patchbaySessionAmbiguousHint,
      );
    }
    if (valid.length == 1) return valid.single;
    if (pending.isNotEmpty) {
      throw const PatchbaySessionException('sessionPending');
    }
    throw PatchbaySessionException(
      lastStaleCode ?? 'sessionNotFound',
      hint: pinned == null ? null : patchbaySessionSelectionStaleHint,
    );
  }

  static Future<PatchbayRuntimeIdentity> _probeIdentity(Uri uri) async {
    final connection = await PatchbayConnection.connect(uri);
    try {
      return connection.runtimeIdentity;
    } finally {
      await connection.close();
    }
  }

  static bool _isProcessAlive(int processId) =>
      PlatformProcessUtils.isProcessAlive(processId);
}

extension<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
  T? get firstOrNull => isEmpty ? null : first;
}
