import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';

import 'client.dart';

const int patchbaySessionSchemaVersion = 1;

String defaultPatchbaySessionDirectory({Map<String, String>? environment}) {
  final variables = environment ?? Platform.environment;
  final override = variables['PATCHBAY_SESSION_DIR']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'patchbay-sessions-v1';
}

final class PatchbaySessionException implements Exception {
  const PatchbaySessionException(this.code, {this.choices = const []});

  final String code;
  final List<String> choices;

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
        (wsUri != null && wsUri is! String)) {
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

  bool get isComplete =>
      appInstanceId != null && isolateId != null && wsUri != null;

  String get choiceLabel {
    final workspace = workspacePath
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    return '$sessionId app=$applicationId mode=$buildMode '
        'workspace=${workspace ?? workspacePath}';
  }

  PatchbaySessionRecord completedWith(PatchbayRuntimeIdentity identity) =>
      PatchbaySessionRecord(
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
  };
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
    final temporary = File(
      '${target.path}.tmp-${pid}-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
      _restrictFile(temporary);
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void remove(String sessionId) {
    _validateSessionId(sessionId);
    _removeFile(File(_fileName(sessionId)));
  }

  String _fileName(String sessionId) {
    _validateSessionId(sessionId);
    return '${directory.path}${Platform.pathSeparator}$sessionId.json';
  }

  void _ensureDirectory() {
    directory.createSync(recursive: true);
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['700', directory.path]);
    }
  }

  void _restrictFile(File file) {
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  }

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

final class PatchbayDiscoveredSession {
  const PatchbayDiscoveredSession({
    required this.record,
    required this.identity,
  });

  final PatchbaySessionRecord record;
  final PatchbayRuntimeIdentity identity;
}

final class PatchbaySessionResolver {
  PatchbaySessionResolver({
    PatchbaySessionStore? store,
    PatchbayIdentityProbe? identityProbe,
    PatchbayPidProbe? pidProbe,
  }) : store = store ?? PatchbaySessionStore(),
       _identityProbe = identityProbe ?? _probeIdentity,
       _pidProbe = pidProbe ?? _isProcessAlive;

  final PatchbaySessionStore store;
  final PatchbayIdentityProbe _identityProbe;
  final PatchbayPidProbe _pidProbe;

  Future<PatchbayDiscoveredSession> resolve({String? sessionId}) async {
    final all = store.readAll();
    if (all.isEmpty) {
      throw const PatchbaySessionException('sessionDirectoryEmpty');
    }
    final candidates = sessionId == null
        ? all
        : all.where((record) => record.sessionId == sessionId).toList();
    if (candidates.isEmpty) {
      throw const PatchbaySessionException('sessionNotFound');
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
        store.remove(record.sessionId);
        lastStaleCode = 'sessionStaleTransport';
        continue;
      }
      if (identity.schemaVersion != PatchbayServiceHost.schemaVersion ||
          identity.applicationId != record.applicationId ||
          (record.appInstanceId != null &&
              identity.appInstanceId != record.appInstanceId) ||
          (record.isolateId != null &&
              identity.isolateId != record.isolateId)) {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionIdentityMismatch';
        continue;
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
      );
    }
    if (valid.length == 1) return valid.single;
    if (pending.isNotEmpty) {
      throw const PatchbaySessionException('sessionPending');
    }
    throw PatchbaySessionException(lastStaleCode ?? 'sessionNotFound');
  }

  static Future<PatchbayRuntimeIdentity> _probeIdentity(Uri uri) async {
    final connection = await PatchbayConnection.connect(uri);
    try {
      return connection.runtimeIdentity;
    } finally {
      await connection.close();
    }
  }

  static bool _isProcessAlive(int processId) {
    try {
      if (Platform.isWindows) {
        final result = Process.runSync('tasklist', [
          '/FI',
          'PID eq $processId',
          '/NH',
        ]);
        return result.exitCode == 0 &&
            RegExp(
              '(?:^|\\s)$processId(?:\\s|\$)',
              multiLine: true,
            ).hasMatch(result.stdout.toString());
      }
      return Process.runSync('kill', ['-0', '$processId']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

extension<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
