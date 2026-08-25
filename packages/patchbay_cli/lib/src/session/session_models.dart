import 'dart:io';

import '../client.dart';
import '../platform/process_utils.dart';
import 'session_store.dart';

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

  /// Opaque OS-reported launch-time signature for [processId], captured when
  /// the record was created. `null` on records written before PB-050-18, or
  /// when the platform declined to answer at capture time — both cases are
  /// read identically by [PatchbaySessionRecord.fromJson] and only change
  /// what a resolver can *verify*, never what it can parse.
  final String? processStartTime;

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
    ProcessRunner processRunner = PlatformProcessUtils.defaultRunner,
    bool? isWindows,
  }) {
    if (processId <= 0) {
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
      workspacePath: workspacePath,
      deviceId: deviceId,
      state: PatchbaySessionStatus.pending,
      ownerPid: ownerPid,
      launchId: launchId,
      observedAtMs: observed,
      expiresAtMs: observed + ttl.inMilliseconds,
      processStartTime: processStartTime,
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
  });

  final PatchbaySessionRecord record;
  final PatchbaySessionStatus status;
  final bool selected;

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
