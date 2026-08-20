import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:patchbay/patchbay.dart';

const int patchbayTraceSchemaVersion = 1;
const int patchbayTraceMaxCount = 50;
const int patchbayTraceMaxTotalBytes = 2 * 1024 * 1024 * 1024;
const int patchbayTraceMaxEventBytes = 256 * 1024;
const int patchbayTraceMaxArtifactBytes = 64 * 1024 * 1024;
const Duration patchbayTraceMaxAge = Duration(days: 30);

const Set<String> patchbayTraceWriterEventTypes = <String>{
  'trace.started',
  'trace.truncated',
  'session.observed',
  'command.started',
  'command.admission',
  'job.event',
  'artifact.attached',
  'note.added',
  'command.finished',
  'trace.finished',
};

String defaultPatchbayTraceDirectory() {
  final String? configured = Platform.environment['PATCHBAY_TRACE_DIR'];
  if (configured != null && configured.isNotEmpty) return configured;
  final String? home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const PatchbayTraceException('traceHomeUnavailable');
  }
  return '$home/.patchbay/traces/v1';
}

final class PatchbayTraceException implements Exception {
  const PatchbayTraceException(
    this.code, {
    this.details = const <String, Object?>{},
  });

  final String code;
  final Map<String, Object?> details;

  @override
  String toString() => code;
}

final class PatchbayTraceManifest {
  const PatchbayTraceManifest({
    required this.traceId,
    required this.name,
    required this.createdAt,
    required this.workspaceFingerprint,
    required this.cliVersion,
    required this.eventCount,
    required this.integrityHash,
    required this.pinned,
    this.endedAt,
    this.endedReason,
    this.exportedAt,
  });

  final String traceId;
  final String name;
  final DateTime createdAt;
  final DateTime? endedAt;
  final String? endedReason;
  final String workspaceFingerprint;
  final String cliVersion;
  final int eventCount;
  final String integrityHash;
  final bool pinned;
  final DateTime? exportedAt;

  bool get ended => endedAt != null;

  PatchbayTraceManifest copyWith({
    int? eventCount,
    String? integrityHash,
    DateTime? endedAt,
    String? endedReason,
    DateTime? exportedAt,
  }) => PatchbayTraceManifest(
    traceId: traceId,
    name: name,
    createdAt: createdAt,
    workspaceFingerprint: workspaceFingerprint,
    cliVersion: cliVersion,
    eventCount: eventCount ?? this.eventCount,
    integrityHash: integrityHash ?? this.integrityHash,
    pinned: pinned,
    endedAt: endedAt ?? this.endedAt,
    endedReason: endedReason ?? this.endedReason,
    exportedAt: exportedAt ?? this.exportedAt,
  );

  factory PatchbayTraceManifest.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != patchbayTraceSchemaVersion ||
        json['traceId'] is! String ||
        json['name'] is! String ||
        json['createdAt'] is! String ||
        json['workspaceFingerprint'] is! String ||
        json['cliVersion'] is! String ||
        json['eventCount'] is! int ||
        json['integrityHash'] is! String ||
        json['pinned'] is! bool) {
      throw const PatchbayTraceException('traceManifestInvalid');
    }
    return PatchbayTraceManifest(
      traceId: json['traceId']! as String,
      name: json['name']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
      workspaceFingerprint: json['workspaceFingerprint']! as String,
      cliVersion: json['cliVersion']! as String,
      eventCount: json['eventCount']! as int,
      integrityHash: json['integrityHash']! as String,
      pinned: json['pinned']! as bool,
      endedAt: json['endedAt'] is String
          ? DateTime.parse(json['endedAt']! as String).toUtc()
          : null,
      endedReason: json['endedReason'] as String?,
      exportedAt: json['exportedAt'] is String
          ? DateTime.parse(json['exportedAt']! as String).toUtc()
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': patchbayTraceSchemaVersion,
    'traceId': traceId,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    if (endedReason != null) 'endedReason': endedReason,
    'workspaceFingerprint': workspaceFingerprint,
    'cliVersion': cliVersion,
    'redactionPolicy': 'descriptor-v1',
    'eventCount': eventCount,
    'integrityHash': integrityHash,
    'pinned': pinned,
    if (exportedAt != null) 'exportedAt': exportedAt!.toUtc().toIso8601String(),
  };
}

final class PatchbayTraceEvent {
  const PatchbayTraceEvent({
    required this.traceId,
    required this.sequence,
    required this.eventId,
    required this.recordedAt,
    required this.elapsedMs,
    required this.type,
    required this.observer,
    required this.payload,
    required this.previousEventHash,
    this.requestId,
    this.sessionRef,
    this.jobId,
    this.factSource,
  });

  final String traceId;
  final int sequence;
  final String eventId;
  final DateTime recordedAt;
  final int elapsedMs;
  final String type;
  final String? requestId;
  final Map<String, Object?>? sessionRef;
  final String? jobId;
  final String observer;
  final String? factSource;
  final Map<String, Object?> payload;
  final String previousEventHash;

  factory PatchbayTraceEvent.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != patchbayTraceSchemaVersion ||
        json['traceId'] is! String ||
        json['sequence'] is! int ||
        json['eventId'] is! String ||
        json['recordedAt'] is! String ||
        json['elapsedMs'] is! int ||
        json['type'] is! String ||
        json['observer'] is! String ||
        (json['factSource'] != null && json['factSource'] is! String) ||
        json['payload'] is! Map<Object?, Object?> ||
        json['previousEventHash'] is! String) {
      throw const PatchbayTraceException('traceEventInvalid');
    }
    final Object? rawSession = json['sessionRef'];
    return PatchbayTraceEvent(
      traceId: json['traceId']! as String,
      sequence: json['sequence']! as int,
      eventId: json['eventId']! as String,
      recordedAt: DateTime.parse(json['recordedAt']! as String).toUtc(),
      elapsedMs: json['elapsedMs']! as int,
      type: json['type']! as String,
      requestId: json['requestId'] as String?,
      sessionRef: rawSession is Map<Object?, Object?>
          ? <String, Object?>{
              for (final MapEntry<Object?, Object?> entry in rawSession.entries)
                '${entry.key}': entry.value,
            }
          : null,
      jobId: json['jobId'] as String?,
      observer: json['observer']! as String,
      factSource: json['factSource'] as String?,
      payload: <String, Object?>{
        for (final MapEntry<Object?, Object?> entry
            in (json['payload']! as Map<Object?, Object?>).entries)
          '${entry.key}': entry.value,
      },
      previousEventHash: json['previousEventHash']! as String,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': patchbayTraceSchemaVersion,
    'traceId': traceId,
    'sequence': sequence,
    'eventId': eventId,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'elapsedMs': elapsedMs,
    'type': type,
    if (requestId != null) 'requestId': requestId,
    if (sessionRef != null) 'sessionRef': sessionRef,
    if (jobId != null) 'jobId': jobId,
    'observer': observer,
    if (factSource != null) 'factSource': factSource,
    'payload': payload,
    'previousEventHash': previousEventHash,
  };

  String get hash =>
      sha256.convert(utf8.encode(_canonicalJson(toJson()))).toString();
}

final class PatchbayTraceReadResult {
  const PatchbayTraceReadResult({
    required this.manifest,
    required this.events,
    required this.truncatedTail,
    required this.integrity,
    required this.missingArtifacts,
  });

  final PatchbayTraceManifest manifest;
  final List<PatchbayTraceEvent> events;
  final bool truncatedTail;
  final String integrity;
  final List<String> missingArtifacts;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': patchbayTraceSchemaVersion,
    'trace': manifest.toJson(),
    'events': events.map((PatchbayTraceEvent event) => event.toJson()).toList(),
    'truncatedTail': truncatedTail,
    'integrity': integrity,
    'missingArtifacts': missingArtifacts,
  };
}

final class PatchbayTracePruneResult {
  const PatchbayTracePruneResult({
    required this.candidates,
    required this.dryRun,
  });

  final List<String> candidates;
  final bool dryRun;

  Map<String, Object?> toJson() => <String, Object?>{
    'dryRun': dryRun,
    'traces': candidates,
    'count': candidates.length,
  };
}

final class PatchbayTraceStore {
  PatchbayTraceStore([String? directory, Directory? workspace])
    : root = Directory(directory ?? defaultPatchbayTraceDirectory()),
      workspace = workspace ?? Directory.current;

  final Directory root;
  final Directory workspace;

  String get workspaceFingerprint =>
      sha256.convert(utf8.encode(workspace.absolute.path)).toString();

  PatchbayTraceManifest start({
    required String name,
    required String cliVersion,
    required bool activate,
    bool pinned = false,
    DateTime? now,
  }) {
    final DateTime createdAt = (now ?? DateTime.now()).toUtc();
    if (name.trim().isEmpty) {
      throw const PatchbayTraceException('traceNameEmpty');
    }
    _ensureRoot();
    _enforceStartBudget(createdAt);
    final String traceId = _newId(createdAt);
    final Directory directory = _traceDirectory(traceId)..createSync();
    Directory('${directory.path}/artifacts').createSync();
    final PatchbayTraceManifest manifest = PatchbayTraceManifest(
      traceId: traceId,
      name: name.trim(),
      createdAt: createdAt,
      workspaceFingerprint: workspaceFingerprint,
      cliVersion: cliVersion,
      eventCount: 0,
      integrityHash: '',
      pinned: pinned,
    );
    _writeManifest(manifest);
    final PatchbayTraceRecorder recorder = PatchbayTraceRecorder(this, traceId);
    recorder.append(
      'trace.started',
      observer: 'cliObserved',
      payload: <String, Object?>{'name': name.trim(), 'pinned': pinned},
      recordedAt: createdAt,
    );
    if (activate) {
      try {
        _activate(traceId, createdAt);
      } on Object {
        directory.deleteSync(recursive: true);
        rethrow;
      }
    }
    return readManifest(traceId);
  }

  PatchbayTraceRecorder recorder(String traceId) {
    _validateTraceId(traceId);
    final PatchbayTraceManifest manifest = readManifest(traceId);
    if (manifest.ended) {
      throw const PatchbayTraceException('traceAlreadyFinished');
    }
    return PatchbayTraceRecorder(this, traceId);
  }

  String? activeTraceId() {
    final File pointer = _activePointer;
    if (!pointer.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(pointer.readAsStringSync());
      if (decoded is! Map<String, dynamic> ||
          decoded['traceId'] is! String ||
          decoded['workspaceFingerprint'] != workspaceFingerprint) {
        throw const PatchbayTraceException('traceActivePointerInvalid');
      }
      final String traceId = decoded['traceId']! as String;
      _validateTraceId(traceId);
      if (readManifest(traceId).ended) {
        pointer.deleteSync();
        return null;
      }
      return traceId;
    } on PatchbayTraceException {
      rethrow;
    } on Object {
      throw const PatchbayTraceException('traceActivePointerInvalid');
    }
  }

  String? resolve(String? explicitTraceId) => explicitTraceId == null
      ? activeTraceId()
      : recorder(explicitTraceId).traceId;

  PatchbayTraceManifest mark(String? traceId, String note) {
    final String resolved = traceId ?? _requireActive();
    if (note.trim().isEmpty) {
      throw const PatchbayTraceException('traceNoteEmpty');
    }
    recorder(resolved).append(
      'note.added',
      observer: 'operatorStated',
      payload: <String, Object?>{'note': note.trim()},
    );
    return readManifest(resolved);
  }

  PatchbayTraceManifest stop(
    String? traceId, {
    String reason = 'operatorStop',
  }) {
    final String resolved = traceId ?? _requireActive();
    _recoverInterrupted(resolved);
    final PatchbayTraceRecorder open = recorder(resolved);
    open.append(
      'trace.finished',
      observer: 'cliObserved',
      payload: <String, Object?>{'reason': reason},
    );
    final PatchbayTraceManifest current = readManifest(resolved);
    final PatchbayTraceManifest ended = current.copyWith(
      endedAt: DateTime.now().toUtc(),
      endedReason: reason,
    );
    _writeManifest(ended);
    if (_activePointer.existsSync()) {
      final String? active = activeTraceId();
      if (active == resolved) _activePointer.deleteSync();
    }
    return ended;
  }

  PatchbayTraceReadResult show(String traceId) {
    _recoverInterrupted(traceId);
    return read(traceId);
  }

  PatchbayTraceReadResult read(String traceId) {
    final PatchbayTraceManifest manifest = readManifest(traceId);
    final _DecodedEvents decoded = _readEvents(traceId);
    String previous = '';
    String integrity = 'verified';
    for (var index = 0; index < decoded.events.length; index += 1) {
      final PatchbayTraceEvent event = decoded.events[index];
      if (event.traceId != traceId ||
          event.sequence != index + 1 ||
          event.previousEventHash != previous) {
        integrity = 'mismatched';
        break;
      }
      previous = event.hash;
    }
    if (integrity == 'verified' &&
        (manifest.eventCount != decoded.events.length ||
            manifest.integrityHash != previous)) {
      integrity = 'mismatched';
    }
    final List<String> missing = <String>[];
    for (final PatchbayTraceEvent event in decoded.events) {
      if (event.type != 'artifact.attached') continue;
      final Object? path = event.payload['relativePath'];
      if (path is String &&
          !File('${_traceDirectory(traceId).path}/$path').existsSync()) {
        missing.add(
          event.payload['sha256'] is String
              ? event.payload['sha256']! as String
              : path,
        );
      }
    }
    return PatchbayTraceReadResult(
      manifest: manifest,
      events: List<PatchbayTraceEvent>.unmodifiable(decoded.events),
      truncatedTail: decoded.truncatedTail,
      integrity: integrity,
      missingArtifacts: List<String>.unmodifiable(missing),
    );
  }

  PatchbayTraceManifest readManifest(String traceId) {
    _validateTraceId(traceId);
    final File file = File('${_traceDirectory(traceId).path}/manifest.json');
    if (!file.existsSync()) {
      throw const PatchbayTraceException('traceNotFound');
    }
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const PatchbayTraceException('traceManifestInvalid');
      }
      final PatchbayTraceManifest manifest = PatchbayTraceManifest.fromJson(
        Map<String, Object?>.from(decoded),
      );
      if (manifest.traceId != traceId) {
        throw const PatchbayTraceException('traceManifestInvalid');
      }
      return manifest;
    } on PatchbayTraceException {
      rethrow;
    } on Object {
      throw const PatchbayTraceException('traceManifestInvalid');
    }
  }

  Map<String, Object?> exportDirectory(
    String traceId,
    String outputPath, {
    bool includeArtifacts = true,
  }) {
    _recoverInterrupted(traceId);
    final PatchbayTraceReadResult source = read(traceId);
    if (source.integrity != 'verified') {
      throw const PatchbayTraceException('traceIntegrityMismatch');
    }
    if (source.missingArtifacts.isNotEmpty) {
      throw PatchbayTraceException(
        'traceArtifactMissing',
        details: <String, Object?>{'sha256': source.missingArtifacts},
      );
    }
    final Directory output = Directory(outputPath).absolute;
    if (output.existsSync()) {
      throw const PatchbayTraceException('traceExportExists');
    }
    output.createSync(recursive: true);
    final List<PatchbayTraceEvent> portableEvents = <PatchbayTraceEvent>[];
    String previousHash = '';
    var bytes = 0;
    final StringBuffer eventLines = StringBuffer();
    for (final PatchbayTraceEvent event in source.events) {
      final Map<String, Object?> portable = _portableMap(event.toJson());
      portable['previousEventHash'] = previousHash;
      final PatchbayTraceEvent rewritten = PatchbayTraceEvent.fromJson(
        portable,
      );
      portableEvents.add(rewritten);
      previousHash = rewritten.hash;
      final String line = jsonEncode(rewritten.toJson());
      bytes += utf8.encode(line).length + 1;
      if (bytes > patchbayTraceMaxTotalBytes) {
        throw const PatchbayTraceException('traceBundleTooLarge');
      }
      eventLines.writeln(line);
    }
    final Map<String, Object?> manifest = _portableMap(
      source.manifest
          .copyWith(
            eventCount: portableEvents.length,
            integrityHash: previousHash,
          )
          .toJson(),
    );
    File('${output.path}/manifest.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      flush: true,
    );
    File(
      '${output.path}/events.ndjson',
    ).writeAsStringSync(eventLines.toString(), flush: true);
    var artifactCount = 0;
    if (includeArtifacts) {
      final Directory target = Directory('${output.path}/artifacts')
        ..createSync();
      final Directory sourceArtifacts = Directory(
        '${_traceDirectory(traceId).path}/artifacts',
      );
      for (final FileSystemEntity entity in sourceArtifacts.listSync(
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!_sha256Pattern.hasMatch(name)) {
          throw const PatchbayTraceException('traceArtifactPathInvalid');
        }
        bytes += entity.lengthSync();
        if (bytes > patchbayTraceMaxTotalBytes) {
          throw const PatchbayTraceException('traceBundleTooLarge');
        }
        entity.copySync('${target.path}/$name');
        artifactCount += 1;
      }
    }
    final PatchbayTraceManifest exported = source.manifest.copyWith(
      exportedAt: DateTime.now().toUtc(),
    );
    _writeManifest(exported);
    return <String, Object?>{
      'traceId': traceId,
      'output': output.path,
      'events': source.events.length,
      'artifacts': artifactCount,
      'portable': true,
    };
  }

  Map<String, Object?> diff(String beforeTraceId, String afterTraceId) {
    final PatchbayTraceReadResult before = show(beforeTraceId);
    final PatchbayTraceReadResult after = show(afterTraceId);
    final List<Map<String, Object?>> left = _commandFacts(before.events);
    final List<Map<String, Object?>> right = _commandFacts(after.events);
    final Map<String, int> leftOccurrences = <String, int>{};
    final Map<String, int> rightOccurrences = <String, int>{};
    final Map<String, Map<String, Object?>> leftByKey =
        <String, Map<String, Object?>>{};
    final Map<String, Map<String, Object?>> rightByKey =
        <String, Map<String, Object?>>{};
    for (final Map<String, Object?> fact in left) {
      final String base = '${fact['command']}\u0000${fact['descriptorDigest']}';
      final int occurrence = (leftOccurrences[base] ?? 0) + 1;
      leftOccurrences[base] = occurrence;
      leftByKey['$base\u0000$occurrence'] = fact;
    }
    for (final Map<String, Object?> fact in right) {
      final String base = '${fact['command']}\u0000${fact['descriptorDigest']}';
      final int occurrence = (rightOccurrences[base] ?? 0) + 1;
      rightOccurrences[base] = occurrence;
      rightByKey['$base\u0000$occurrence'] = fact;
    }
    final List<String> keys = <String>{
      ...leftByKey.keys,
      ...rightByKey.keys,
    }.toList()..sort();
    final List<Map<String, Object?>> added = <Map<String, Object?>>[];
    final List<Map<String, Object?>> removed = <Map<String, Object?>>[];
    final List<Map<String, Object?>> changed = <Map<String, Object?>>[];
    for (final String key in keys) {
      final Map<String, Object?>? a = leftByKey[key];
      final Map<String, Object?>? b = rightByKey[key];
      if (a == null) {
        added.add(b!);
      } else if (b == null) {
        removed.add(a);
      } else if (_canonicalJson(a) != _canonicalJson(b)) {
        changed.add(<String, Object?>{'before': a, 'after': b});
      }
    }
    return <String, Object?>{
      'schemaVersion': patchbayTraceSchemaVersion,
      'before': beforeTraceId,
      'after': afterTraceId,
      'added': added,
      'removed': removed,
      'changed': changed,
      'same': added.isEmpty && removed.isEmpty && changed.isEmpty,
    };
  }

  PatchbayTracePruneResult prune({required bool dryRun, DateTime? now}) {
    if (!root.existsSync()) {
      return PatchbayTracePruneResult(
        candidates: const <String>[],
        dryRun: dryRun,
      );
    }
    final DateTime cutoff = (now ?? DateTime.now()).toUtc().subtract(
      patchbayTraceMaxAge,
    );
    final List<PatchbayTraceManifest> candidates = <PatchbayTraceManifest>[];
    for (final PatchbayTraceManifest manifest in _manifests()) {
      if (!manifest.ended ||
          manifest.pinned ||
          !manifest.createdAt.isBefore(cutoff)) {
        continue;
      }
      candidates.add(manifest);
    }
    candidates.sort(
      (PatchbayTraceManifest a, PatchbayTraceManifest b) =>
          a.createdAt.compareTo(b.createdAt),
    );
    if (!dryRun) {
      for (final PatchbayTraceManifest manifest in candidates) {
        _traceDirectory(manifest.traceId).deleteSync(recursive: true);
      }
    }
    return PatchbayTracePruneResult(
      candidates: <String>[
        for (final PatchbayTraceManifest item in candidates) item.traceId,
      ],
      dryRun: dryRun,
    );
  }

  void _activate(String traceId, DateTime createdAt) {
    final File lockFile = File('${root.path}/.active.lock');
    final RandomAccessFile lock = lockFile.openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      if (_activePointer.existsSync() && activeTraceId() != null) {
        throw const PatchbayTraceException('traceAlreadyActive');
      }
      _atomicWrite(_activePointer, <String, Object?>{
        'schemaVersion': patchbayTraceSchemaVersion,
        'traceId': traceId,
        'workspaceFingerprint': workspaceFingerprint,
        'ownerPid': pid,
        'createdAt': createdAt.toIso8601String(),
      });
    } finally {
      try {
        lock.unlockSync();
      } on Object catch (error) {
        Error.safeToString(error);
      }
      lock.closeSync();
    }
  }

  void _recoverInterrupted(String traceId) {
    final PatchbayTraceManifest manifest = readManifest(traceId);
    if (manifest.ended) {
      return;
    }
    if (_readEvents(traceId).truncatedTail) {
      _append(
        traceId: traceId,
        type: 'trace.truncated',
        observer: 'cliObserved',
        payload: const <String, Object?>{'reason': 'tornTailRemoved'},
        repairTornTail: true,
      );
    }
    final List<PatchbayTraceEvent> events = _readEvents(traceId).events;
    final Set<String> open = <String>{};
    for (final PatchbayTraceEvent event in events) {
      final Object? runId = event.payload['commandRunId'];
      if (runId is! String) continue;
      if (event.type == 'command.started') open.add(runId);
      if (event.type == 'command.finished') open.remove(runId);
    }
    final PatchbayTraceRecorder recorder = PatchbayTraceRecorder(this, traceId);
    for (final String runId in open.toList()..sort()) {
      recorder.append(
        'command.finished',
        observer: 'cliObserved',
        payload: <String, Object?>{
          'commandRunId': runId,
          'outcome': 'interrupted',
          'externalInterruptionUnknown': true,
        },
      );
    }
  }

  String _requireActive() {
    final String? active = activeTraceId();
    if (active == null) throw const PatchbayTraceException('traceNotActive');
    return active;
  }

  void _enforceStartBudget(DateTime now) {
    final List<PatchbayTraceManifest> manifests = _manifests();
    if (manifests.length >= patchbayTraceMaxCount) {
      throw const PatchbayTraceException('traceRetentionCountExceeded');
    }
    if (manifests.any(
      (PatchbayTraceManifest item) =>
          now.difference(item.createdAt) > patchbayTraceMaxAge,
    )) {
      throw const PatchbayTraceException('traceRetentionAgeExceeded');
    }
    if (_directoryBytes(root) >= patchbayTraceMaxTotalBytes) {
      throw const PatchbayTraceException('traceRetentionBytesExceeded');
    }
  }

  List<PatchbayTraceManifest> _manifests() {
    if (!root.existsSync()) return const <PatchbayTraceManifest>[];
    final List<PatchbayTraceManifest> result = <PatchbayTraceManifest>[];
    for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final String id = entity.uri.pathSegments
          .where((String item) => item.isNotEmpty)
          .last;
      if (!_traceIdPattern.hasMatch(id)) continue;
      try {
        result.add(readManifest(id));
      } on PatchbayTraceException {
        continue;
      }
    }
    return result;
  }

  _DecodedEvents _readEvents(String traceId) {
    final File file = File('${_traceDirectory(traceId).path}/events.ndjson');
    if (!file.existsSync()) {
      return const _DecodedEvents(<PatchbayTraceEvent>[], false);
    }
    final String content = file.readAsStringSync();
    final bool truncatedTail = content.isNotEmpty && !content.endsWith('\n');
    final List<String> lines = content.split('\n');
    if (truncatedTail) lines.removeLast();
    final List<PatchbayTraceEvent> events = <PatchbayTraceEvent>[];
    for (final String line in lines) {
      if (line.isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const PatchbayTraceException('traceEventInvalid');
        }
        events.add(
          PatchbayTraceEvent.fromJson(Map<String, Object?>.from(decoded)),
        );
      } on PatchbayTraceException {
        rethrow;
      } on Object {
        throw const PatchbayTraceException('traceEventInvalid');
      }
    }
    return _DecodedEvents(events, truncatedTail);
  }

  void _append({
    required String traceId,
    required String type,
    required String observer,
    required Map<String, Object?> payload,
    String? factSource,
    String? requestId,
    Map<String, Object?>? sessionRef,
    String? jobId,
    DateTime? recordedAt,
    bool repairTornTail = false,
  }) {
    if (!patchbayTraceWriterEventTypes.contains(type)) {
      throw const PatchbayTraceException('traceEventTypeUnsupported');
    }
    final File events = File('${_traceDirectory(traceId).path}/events.ndjson');
    final RandomAccessFile file = events.openSync(mode: FileMode.append);
    try {
      file.lockSync(FileLock.exclusive);
      final PatchbayTraceManifest manifest = readManifest(traceId);
      if (manifest.ended) {
        throw const PatchbayTraceException('traceAlreadyFinished');
      }
      var current = _readEvents(traceId);
      if (current.truncatedTail) {
        if (!repairTornTail || type != 'trace.truncated') {
          throw const PatchbayTraceException('traceTruncatedTail');
        }
        final List<int> bytes = events.readAsBytesSync();
        final int lastNewline = bytes.lastIndexOf(0x0a);
        file.truncateSync(lastNewline + 1);
        file.setPositionSync(lastNewline + 1);
        file.flushSync();
        current = _readEvents(traceId);
      }
      if (current.events.isNotEmpty &&
          current.events.last.type == 'trace.finished') {
        throw const PatchbayTraceException('traceAlreadyFinished');
      }
      if (type == 'command.finished' &&
          payload['commandRunId'] is String &&
          current.events.any(
            (PatchbayTraceEvent event) =>
                event.type == 'command.finished' &&
                event.payload['commandRunId'] == payload['commandRunId'],
          )) {
        return;
      }
      if (type == 'job.event' &&
          jobId != null &&
          payload['sequence'] is int &&
          current.events.any(
            (PatchbayTraceEvent event) =>
                event.type == 'job.event' &&
                event.jobId == jobId &&
                event.payload['sequence'] == payload['sequence'],
          )) {
        return;
      }
      final DateTime at = (recordedAt ?? DateTime.now()).toUtc();
      final String previous = current.events.isEmpty
          ? ''
          : current.events.last.hash;
      final PatchbayTraceEvent event = PatchbayTraceEvent(
        traceId: traceId,
        sequence: current.events.length + 1,
        eventId: _newId(at, prefix: 'ev'),
        recordedAt: at,
        elapsedMs: max(0, at.difference(manifest.createdAt).inMilliseconds),
        type: type,
        requestId: requestId,
        sessionRef: sessionRef == null ? null : _redactMap(sessionRef),
        jobId: jobId,
        observer: observer,
        factSource: factSource,
        payload: _redactMap(payload),
        previousEventHash: previous,
      );
      final String encoded = jsonEncode(event.toJson());
      if (utf8.encode(encoded).length > patchbayTraceMaxEventBytes) {
        throw const PatchbayTraceException('traceEventTooLarge');
      }
      file.writeStringSync('$encoded\n');
      file.flushSync();
      _writeManifest(
        manifest.copyWith(
          eventCount: event.sequence,
          integrityHash: event.hash,
        ),
      );
    } finally {
      try {
        file.unlockSync();
      } on Object catch (error) {
        Error.safeToString(error);
      }
      file.closeSync();
    }
  }

  void _writeManifest(PatchbayTraceManifest manifest) => _atomicWrite(
    File('${_traceDirectory(manifest.traceId).path}/manifest.json'),
    manifest.toJson(),
  );

  void _atomicWrite(File target, Map<String, Object?> value) {
    target.parent.createSync(recursive: true);
    final File temporary = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsStringSync(jsonEncode(value), flush: true);
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
    }
  }

  File get _activePointer =>
      File('${root.path}/active-$workspaceFingerprint.json');
  Directory _traceDirectory(String traceId) =>
      Directory('${root.path}/$traceId');
  void _ensureRoot() => root.createSync(recursive: true);
}

final class PatchbayTraceRecorder {
  PatchbayTraceRecorder(this.store, this.traceId);

  final PatchbayTraceStore store;
  final String traceId;
  final Set<String> _seenJobEvents = <String>{};

  void append(
    String type, {
    required String observer,
    required Map<String, Object?> payload,
    String? factSource,
    String? requestId,
    Map<String, Object?>? sessionRef,
    String? jobId,
    DateTime? recordedAt,
  }) => store._append(
    traceId: traceId,
    type: type,
    observer: observer,
    factSource: factSource,
    payload: payload,
    requestId: requestId,
    sessionRef: sessionRef,
    jobId: jobId,
    recordedAt: recordedAt,
  );

  String commandStarted(String command, {required String transport}) {
    final String runId = _newId(DateTime.now().toUtc(), prefix: 'run');
    append(
      'command.started',
      observer: 'cliObserved',
      payload: <String, Object?>{
        'commandRunId': runId,
        'command': command,
        'transport': transport,
      },
    );
    return runId;
  }

  void commandFinished(String runId, int exitCode) {
    append(
      'command.finished',
      observer: 'cliObserved',
      payload: <String, Object?>{
        'commandRunId': runId,
        'outcome': 'finished',
        'exitCode': exitCode,
      },
    );
  }

  void sessionObserved(Map<String, Object?> sessionRef) {
    append(
      'session.observed',
      observer: 'cliObserved',
      sessionRef: sessionRef,
      payload: const <String, Object?>{},
    );
  }

  void admission({
    required String command,
    required String requestId,
    required Map<String, Object?> arguments,
    required Set<String> sensitiveParameters,
    required String descriptorDigest,
    required Map<String, Object?> response,
    required bool includeLegacyPayload,
  }) {
    final Map<String, Object?> recordedArguments = <String, Object?>{};
    final bool stdinSource = arguments['inputWasStdin'] == true;
    for (final MapEntry<String, Object?> entry in arguments.entries) {
      if (entry.key == 'inputWasStdin') continue;
      recordedArguments[entry.key] = sensitiveParameters.contains(entry.key)
          ? <String, Object?>{
              'redacted': true,
              'source': stdinSource ? 'stdin' : 'unknown',
            }
          : entry.value;
    }
    final bool legacy = response['schemaMode'] == 'legacyUnvalidated';
    final Map<String, Object?> responseProjection = <String, Object?>{
      'admission': response['admission'],
      'schemaMode': response['schemaMode'],
      if (response['jobId'] is String) 'jobId': response['jobId'],
      if (_stableRejectionCode(response) case final String code)
        'stableCode': code,
      if (_executionProjection(response)
          case final Map<String, Object?> execution)
        'execution': execution,
      if (legacy) 'legacyUnvalidated': true,
      if (legacy && includeLegacyPayload)
        'payload': _redactMap(
          response['payload'] is Map<Object?, Object?>
              ? <String, Object?>{
                  for (final MapEntry<Object?, Object?> entry
                      in (response['payload']! as Map<Object?, Object?>)
                          .entries)
                    '${entry.key}': entry.value,
                }
              : const <String, Object?>{},
        )
      else
        'payloadShape': patchbayParameterShape(
          response['payload'] is Map<Object?, Object?>
              ? <String, Object?>{
                  for (final MapEntry<Object?, Object?> entry
                      in (response['payload']! as Map<Object?, Object?>)
                          .entries)
                    '${entry.key}': entry.value,
                }
              : const <String, Object?>{},
        ),
    };
    append(
      'command.admission',
      observer: 'hostReported',
      requestId: requestId,
      jobId: response['jobId'] as String?,
      payload: <String, Object?>{
        'command': command,
        'descriptorDigest': descriptorDigest,
        'arguments': recordedArguments,
        'response': responseProjection,
      },
    );
    _recordJobEvents(response);
  }

  void _recordJobEvents(Map<String, Object?> response) {
    final String? topJobId = response['jobId'] as String?;
    final Object? payload = response['payload'];
    if (payload is! Map<Object?, Object?>) return;
    final Object? rawEvents = payload['events'];
    if (rawEvents is! List<Object?>) return;
    for (final Object? raw in rawEvents) {
      if (raw is! Map<Object?, Object?> || raw['sequence'] is! int) continue;
      final String? jobId = topJobId ?? payload['jobId'] as String?;
      if (jobId == null) continue;
      final String key = '$jobId:${raw['sequence']}';
      if (!_seenJobEvents.add(key)) continue;
      append(
        'job.event',
        observer: 'hostReported',
        factSource: raw['source'] is String ? raw['source']! as String : null,
        jobId: jobId,
        payload: <String, Object?>{
          'sequence': raw['sequence'],
          'phase': raw['phase'],
          'operation': raw['operation'],
          'reason': raw['reason'],
          'payloadShape': patchbayParameterShape(
            raw['payload'] is Map<Object?, Object?>
                ? <String, Object?>{
                    for (final MapEntry<Object?, Object?> entry
                        in (raw['payload']! as Map<Object?, Object?>).entries)
                      '${entry.key}': entry.value,
                  }
                : const <String, Object?>{},
          ),
        },
      );
    }
  }

  void attachArtifact({
    required String localPath,
    required String sha256Value,
    required int length,
    required String contentType,
    String? blobId,
  }) {
    if (!_sha256Pattern.hasMatch(sha256Value) ||
        length < 0 ||
        length > patchbayTraceMaxArtifactBytes) {
      throw const PatchbayTraceException('traceArtifactInvalid');
    }
    final File source = File(localPath);
    if (!source.existsSync() || source.lengthSync() != length) {
      throw const PatchbayTraceException('traceArtifactMissing');
    }
    final Directory targetDirectory = Directory(
      '${store._traceDirectory(traceId).path}/artifacts',
    )..createSync();
    final File target = File('${targetDirectory.path}/$sha256Value');
    if (!target.existsSync()) source.copySync(target.path);
    append(
      'artifact.attached',
      observer: 'cliObserved',
      payload: <String, Object?>{
        if (blobId != null) 'blobId': blobId,
        'sha256': sha256Value,
        'length': length,
        'contentType': contentType,
        'relativePath': 'artifacts/$sha256Value',
      },
    );
  }
}

List<Map<String, Object?>> _commandFacts(List<PatchbayTraceEvent> events) {
  final List<Map<String, Object?>> result = <Map<String, Object?>>[];
  for (final PatchbayTraceEvent event in events) {
    if (event.type != 'command.admission') continue;
    final Object? response = event.payload['response'];
    if (response is! Map<Object?, Object?>) continue;
    result.add(<String, Object?>{
      'command': event.payload['command'],
      'descriptorDigest': event.payload['descriptorDigest'],
      'admission': response['admission'],
      'stableCode': response['stableCode'],
      'execution': response['execution'],
      'payloadShape': response['payloadShape'],
    });
  }
  return result;
}

Map<String, Object?>? _executionProjection(Map<String, Object?> response) {
  final Object? payload = response['payload'];
  if (payload is! Map<Object?, Object?>) return null;
  final Object? execution = payload['execution'];
  if (execution is! Map<Object?, Object?>) return null;
  final String? classification = patchbayAuditExecutionClassification(response);
  return <String, Object?>{
    if (classification != null) 'classification': classification,
    for (final String key in const <String>{
      'factSource',
      'reason',
      'observedAt',
      'confirmationBudgetMs',
    })
      if (execution[key] != null) key: execution[key],
  };
}

String? _stableRejectionCode(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?> && rejection['code'] is String
      ? rejection['code']! as String
      : null;
}

Map<String, Object?> _redactMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: _redactValue(entry.key, entry.value),
    });

Object? _redactValue(String key, Object? value) {
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
    return _redactMap(<String, Object?>{
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
    return _redactMap(<String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    });
  }
  if (value is List<Object?>) {
    return <Object?>[for (final Object? item in value) _redactValue('', item)];
  }
  return value;
}

Map<String, Object?> _portableMap(Map<String, Object?> value) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: _portableValue(entry.key, entry.value),
    };

Object? _portableValue(String key, Object? value) {
  final Object? redacted = _redactValue(key, value);
  if (redacted is String && _looksAbsolutePath(redacted)) {
    return '<redacted:absolute-path>';
  }
  if (redacted is Map<Object?, Object?>) {
    return _portableMap(<String, Object?>{
      for (final MapEntry<Object?, Object?> entry in redacted.entries)
        '${entry.key}': entry.value,
    });
  }
  if (redacted is List<Object?>) {
    return <Object?>[
      for (final Object? item in redacted) _portableValue('', item),
    ];
  }
  return redacted;
}

bool _looksAbsolutePath(String value) =>
    value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

int _directoryBytes(Directory directory) {
  if (!directory.existsSync()) return 0;
  var total = 0;
  for (final FileSystemEntity entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) total += entity.lengthSync();
  }
  return total;
}

String _newId(DateTime now, {String prefix = 'tr'}) {
  final Random random = Random.secure();
  final String nonce = List<int>.generate(
    10,
    (_) => random.nextInt(256),
  ).map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${prefix}_${now.microsecondsSinceEpoch.toRadixString(36)}_$nonce';
}

String _canonicalJson(Object? value) {
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

final RegExp _traceIdPattern = RegExp(r'^tr_[a-z0-9]+_[a-f0-9]{20}$');
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

void _validateTraceId(String traceId) {
  if (!_traceIdPattern.hasMatch(traceId)) {
    throw const PatchbayTraceException('traceIdInvalid');
  }
}

final class _DecodedEvents {
  const _DecodedEvents(this.events, this.truncatedTail);

  final List<PatchbayTraceEvent> events;
  final bool truncatedTail;
}
