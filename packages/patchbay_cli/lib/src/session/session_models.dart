import 'dart:io';

import '../client.dart';
import '../platform/process_utils.dart';
import 'session_store.dart';
import 'workspace_identity.dart';

const int patchbaySessionSchemaVersion = 1;
const Duration patchbayPendingDefaultTtl = Duration(minutes: 5);
const Duration patchbayPendingMaximumTtl = Duration(minutes: 30);

/// What to do when more than one session is discoverable and none was named.
const String patchbaySessionAmbiguousHint =
    'run `patchbay session use <session-id>` to pin one for later commands, '
    'or pass --session per command';

/// What to do when the pinned session no longer resolves.
const String patchbaySessionSelectionStaleHint =
    'the pinned session no longer resolves: run `patchbay sessions prune` or '
    '`patchbay session use --clear`, then select again';

/// What to do when this checkout owns no session but the machine does.
const String patchbaySessionWorkspaceEmptyHint =
    'no session belongs to this checkout: start the App from here, or name '
    'one from another checkout with --session <session-id> on the single '
    'command (`patchbay sessions list` shows every record on this machine)';

/// What to do when the current workspace cannot be established at all.
const String patchbaySessionWorkspaceUnavailableHint =
    'this command could not establish which checkout it is running in, so it '
    'refuses to pick a session: re-run from an existing directory, or name '
    'one explicitly with --session <session-id>';

/// What to do when a record belongs somewhere else.
const String patchbaySessionWorkspaceMismatchHint =
    'that session belongs to another checkout: pass --session <session-id> on '
    'the single command instead of pinning it here';

String defaultPatchbaySessionDirectory({Map<String, String>? environment}) {
  final variables = environment ?? Platform.environment;
  final override = variables['PATCHBAY_SESSION_DIR']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'patchbay-sessions-v1';
}

/// Creates [path] empty and owner-only **before** any content is written to it.
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
  final String? hint;

  @override
  String toString() => 'PatchbaySessionException($code)';
}

/// What a record looks like from the local machine alone.
enum PatchbaySessionStatus {
  /// The process is alive and a transport URI has been recorded.
  live,

  /// The process is alive but the launcher has not written a URI yet.
  pending,

  /// The process that owned this record is gone.
  stale,
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
    this.processStartTime,
    this.workspaceIdentityVersion,
    this.workspaceKind,
    this.workspaceId,
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
    final processStartTime = json['processStartTime'];
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
        (expiresAtMs != null && (expiresAtMs is! int || expiresAtMs < 0)) ||
        (processStartTime != null &&
            (processStartTime is! String || processStartTime.isEmpty))) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    final PatchbayWorkspaceKind? workspaceKind = _parseWorkspaceTriple(
      json,
      workspacePath: workspacePath,
    );
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
      processStartTime: processStartTime as String?,
      workspaceIdentityVersion: workspaceKind == null
          ? null
          : patchbayWorkspaceIdentityVersion,
      workspaceKind: workspaceKind,
      workspaceId: workspaceKind == null
          ? null
          : json['workspaceId']! as String,
    );
  }

  /// Validates the additive workspace triple (PB-050-14) and returns its kind.
  ///
  /// All three fields or none: a partially written triple is not a "mostly
  /// fine" record, it is evidence that something wrote half a thought, so it
  /// goes to quarantine rather than being read with a guessed remainder. The
  /// digest is *recomputed* from the record's own kind and path rather than
  /// trusted, which is what makes a hand-edited or replayed record fail here
  /// instead of silently claiming another checkout's sessions.
  static PatchbayWorkspaceKind? _parseWorkspaceTriple(
    Map<String, Object?> json, {
    required String workspacePath,
  }) {
    final Object? version = json['workspaceIdentityVersion'];
    final Object? kind = json['workspaceKind'];
    final Object? id = json['workspaceId'];
    if (version == null && kind == null && id == null) return null;
    if (version != patchbayWorkspaceIdentityVersion ||
        kind is! String ||
        id is! String ||
        !PatchbayWorkspaceIdentity.isWorkspaceIdShaped(id)) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    final PatchbayWorkspaceKind? parsed = PatchbayWorkspaceKind.values
        .where((PatchbayWorkspaceKind value) => value.name == kind)
        .firstOrNull;
    if (parsed == null) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    final String recomputed = PatchbayWorkspaceIdentity.workspaceIdFor(
      kind: parsed,
      canonicalRoot: workspacePath,
    );
    if (recomputed != id) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    return parsed;
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

  /// Opaque OS-reported launch-time signature for [processId], captured when
  /// the record was created. `null` on records written before PB-050-18, or
  /// when the platform declined to answer at capture time — both cases are
  /// read identically by [PatchbaySessionRecord.fromJson] and only change
  /// what a resolver can *verify*, never what it can parse.
  final String? processStartTime;

  /// `1` on records written by a workspace-aware CLI, `null` on legacy ones.
  ///
  /// These three fields (PB-050-14) are strictly additive: the record's own
  /// `schemaVersion` stays `1`, so a 0.4.x reader parses the file unchanged
  /// and simply ignores them -- it just does not get this proposal's
  /// isolation guarantee.
  final int? workspaceIdentityVersion;
  final PatchbayWorkspaceKind? workspaceKind;
  final String? workspaceId;

  /// Whether this record can name its own workspace without being re-proven.
  bool get hasWorkspaceIdentity => workspaceId != null;

  bool get isComplete =>
      appInstanceId != null && isolateId != null && wsUri != null;

  /// This record, re-stated as belonging to [identity].
  ///
  /// Used in exactly two places: a workspace-aware launcher declaring a new
  /// record, and the one-shot upgrade of a legacy record whose path was
  /// *proven* to recompute to the current identity. It rewrites
  /// [workspacePath] to the canonical root, because a launcher that ran in a
  /// subdirectory recorded that subdirectory and the digest is only
  /// reproducible from the root.
  PatchbaySessionRecord withWorkspace(PatchbayWorkspaceIdentity identity) =>
      PatchbaySessionRecord(
        sessionId: sessionId,
        applicationId: applicationId,
        appInstanceId: appInstanceId,
        isolateId: isolateId,
        processId: processId,
        wsUri: wsUri,
        buildMode: buildMode,
        createdAt: createdAt,
        workspacePath: identity.canonicalRoot,
        deviceId: deviceId,
        state: state,
        ownerPid: ownerPid,
        launchId: launchId,
        observedAtMs: observedAtMs,
        expiresAtMs: expiresAtMs,
        processStartTime: processStartTime,
        workspaceIdentityVersion: patchbayWorkspaceIdentityVersion,
        workspaceKind: identity.kind,
        workspaceId: identity.workspaceId,
      );

  /// Last path segment of the workspace, which is what tells two runs apart.
  String get workspaceName =>
      workspacePath
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      workspacePath;

  /// Transport endpoint with the authentication material removed.
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
    processStartTime: processStartTime,
    workspaceIdentityVersion: workspaceIdentityVersion,
    workspaceKind: workspaceKind,
    workspaceId: workspaceId,
  );

  /// Adds the child-discovered transport while keeping writer state pending.
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
    processStartTime: processStartTime,
    workspaceIdentityVersion: workspaceIdentityVersion,
    workspaceKind: workspaceKind,
    workspaceId: workspaceId,
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
    if (processStartTime != null) 'processStartTime': processStartTime,
    if (workspaceId != null) ...<String, Object?>{
      'workspaceIdentityVersion': workspaceIdentityVersion,
      'workspaceKind': workspaceKind!.name,
      'workspaceId': workspaceId,
    },
  };
}

/// Additive child-declaration context injected by `patchbay launch`.
final class PatchbayLaunchContext {
  const PatchbayLaunchContext({
    required this.sessionDirectory,
    required this.launchId,
    required this.ownerPid,
    this.workspace,
  });

  static const String sessionDirectoryKey = 'PATCHBAY_SESSION_DIR';
  static const String launchIdKey = 'PATCHBAY_LAUNCH_ID';
  static const String ownerPidKey = 'PATCHBAY_LAUNCH_OWNER_PID';
  static const String workspaceIdKey = PatchbayWorkspaceIdentity.idKey;
  static const String workspaceKindKey = PatchbayWorkspaceIdentity.kindKey;
  static const String workspaceRootKey = PatchbayWorkspaceIdentity.rootKey;

  factory PatchbayLaunchContext.fromEnvironment(Map<String, String> values) {
    final PatchbayLaunchContext? context = tryFromEnvironment(values);
    if (context == null) {
      throw const PatchbaySessionException('launchContextInvalid');
    }
    return context;
  }

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
    final ({PatchbayWorkspaceIdentity? identity, bool invalid}) workspace =
        PatchbayWorkspaceIdentity.fromEnvironment(values);
    if (workspace.invalid) {
      throw const PatchbaySessionException('launchContextInvalid');
    }
    return PatchbayLaunchContext(
      sessionDirectory: directory,
      launchId: launchId,
      ownerPid: ownerPid,
      workspace: workspace.identity,
    );
  }

  final String sessionDirectory;
  final String launchId;
  final int ownerPid;

  /// The workspace `patchbay launch` computed once, before the child started.
  ///
  /// `null` for a launcher that predates PB-050-14; such a context still
  /// declares perfectly readable records, they are simply legacy ones that
  /// have to prove their own membership later.
  final PatchbayWorkspaceIdentity? workspace;

  PatchbaySessionStore get store => PatchbaySessionStore(sessionDirectory);

  PatchbaySessionRecord pendingRecord({
    required String sessionId,
    required String applicationId,
    required int processId,
    required String buildMode,
    required DateTime createdAt,
    required String deviceId,
    String? workspacePath,
    Duration ttl = patchbayPendingDefaultTtl,
    ProcessRunner processRunner = PlatformProcessUtils.defaultRunner,
    bool? isWindows,
  }) {
    if (processId <= 0) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    // A workspace-aware context is the authority on where this session lives.
    // `workspacePath` survives as a source-compatibility parameter only, and a
    // child that reports a *different* path is not "adding detail" -- it is
    // contradicting the launcher, so it is refused rather than merged.
    final PatchbayWorkspaceIdentity? identity = workspace;
    if (identity != null &&
        workspacePath != null &&
        workspacePath != identity.canonicalRoot) {
      throw const PatchbaySessionException('sessionWorkspaceMismatch');
    }
    final String recordedPath = identity?.canonicalRoot ?? workspacePath ?? '';
    if (recordedPath.isEmpty) {
      throw const PatchbaySessionException('sessionRecordInvalid');
    }
    if (ttl <= Duration.zero || ttl > patchbayPendingMaximumTtl) {
      throw const PatchbaySessionException('pendingTtlInvalid');
    }
    final int observed = createdAt.toUtc().millisecondsSinceEpoch;
    // Captured once, at the moment this process declares itself: this is
    // the one place that can cheaply ask "what is my own launch time",
    // before any PID-reuse race has a chance to matter.
    final String? processStartTime =
        PlatformProcessUtils.processStartTimeSignature(
          processId,
          runner: processRunner,
          isWindows: isWindows,
        );
    return PatchbaySessionRecord(
      sessionId: sessionId,
      applicationId: applicationId,
      appInstanceId: null,
      isolateId: null,
      processId: processId,
      wsUri: null,
      buildMode: buildMode,
      createdAt: createdAt,
      workspacePath: recordedPath,
      deviceId: deviceId,
      state: PatchbaySessionStatus.pending,
      ownerPid: ownerPid,
      launchId: launchId,
      observedAtMs: observed,
      expiresAtMs: observed + ttl.inMilliseconds,
      processStartTime: processStartTime,
      workspaceIdentityVersion: identity == null
          ? null
          : patchbayWorkspaceIdentityVersion,
      workspaceKind: identity?.kind,
      workspaceId: identity?.workspaceId,
    );
  }

  bool owns(PatchbaySessionRecord record) =>
      record.launchId == launchId && record.ownerPid == ownerPid;
}

final class PatchbayDiscoveredSession {
  const PatchbayDiscoveredSession({
    required this.record,
    required this.identity,
  });

  final PatchbaySessionRecord record;
  final PatchbayRuntimeIdentity identity;
}

/// One record as `sessions list` reports it.
final class PatchbaySessionListing {
  const PatchbaySessionListing({
    required this.record,
    required this.status,
    required this.selected,
    this.identityUnverified = false,
    this.workspaceAffinity = PatchbayWorkspaceAffinity.legacyUnverified,
  });

  final PatchbaySessionRecord record;
  final PatchbaySessionStatus status;

  /// Whether *this* workspace's scoped pin names this record.
  ///
  /// Never true because some other checkout pinned it: `selected` answers
  /// "would a command run here use this one", not "does a pin exist".
  final bool selected;

  /// Where this record sits relative to the workspace doing the listing.
  ///
  /// `sessions list` stays a global inventory -- the machine-wide view is what
  /// makes an explicit cross-checkout `--session` usable -- and this field is
  /// what turns that inventory into an answer about *here*.
  final PatchbayWorkspaceAffinity workspaceAffinity;

  /// `true` when [status] was decided on the PID alone: [record] predates
  /// process-launch-identity capture (PB-050-18), or the OS declined to
  /// answer the current start-time probe. Always `false` when the record's
  /// process-launch identity was actually compared — including when that
  /// comparison is what produced [PatchbaySessionStatus.stale] for a
  /// PID-reuse collision, which is a definite answer, not an unverified one.
  final bool identityUnverified;

  /// One printable line. URI-free by construction.
  String get label =>
      '${record.sessionId} ${status.name} app=${record.applicationId} '
      'device=${record.deviceId} mode=${record.buildMode} '
      'workspace=${record.workspaceName}'
      ' affinity=${workspaceAffinity.name}'
      '${record.maskedEndpoint == null ? '' : ' endpoint=${record.maskedEndpoint}'}'
      '${identityUnverified ? ' identityUnverified' : ''}';

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
    'identityUnverified': identityUnverified,
    'workspaceAffinity': workspaceAffinity.name,
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

typedef PatchbayIdentityProbe =
    Future<PatchbayRuntimeIdentity> Function(Uri uri);
typedef PatchbayPidProbe = bool Function(int processId);

typedef PatchbaySessionClock = DateTime Function();

extension<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
