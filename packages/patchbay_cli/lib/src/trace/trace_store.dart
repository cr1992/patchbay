import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'trace_models.dart';
import 'trace_recorder.dart';
import 'trace_redaction.dart';

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
    final String traceId = newTraceId(createdAt);
    final Directory directory = traceDirectory(traceId)..createSync();
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
    final PatchbayTraceRecorder rec = PatchbayTraceRecorder(this, traceId);
    rec.append(
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
    validateTraceId(traceId);
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
      validateTraceId(traceId);
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
    final DecodedTraceEvents decoded = _readEvents(traceId);
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
          !File('${traceDirectory(traceId).path}/$path').existsSync()) {
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
    validateTraceId(traceId);
    final File file = File('${traceDirectory(traceId).path}/manifest.json');
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
      final Map<String, Object?> portable = portableTraceMap(event.toJson());
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
    final Map<String, Object?> manifest = portableTraceMap(
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
        '${traceDirectory(traceId).path}/artifacts',
      );
      for (final FileSystemEntity entity in sourceArtifacts.listSync(
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!sha256Pattern.hasMatch(name)) {
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
    final List<Map<String, Object?>> left = commandFacts(before.events);
    final List<Map<String, Object?>> right = commandFacts(after.events);
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
      } else if (canonicalTraceJson(a) != canonicalTraceJson(b)) {
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
        traceDirectory(manifest.traceId).deleteSync(recursive: true);
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
      appendInternal(
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
    final PatchbayTraceRecorder rec = PatchbayTraceRecorder(this, traceId);
    for (final String runId in open.toList()..sort()) {
      rec.append(
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
      if (!traceIdPattern.hasMatch(id)) continue;
      try {
        result.add(readManifest(id));
      } on PatchbayTraceException {
        continue;
      }
    }
    return result;
  }

  DecodedTraceEvents _readEvents(String traceId) {
    final File file = File('${traceDirectory(traceId).path}/events.ndjson');
    if (!file.existsSync()) {
      return const DecodedTraceEvents(<PatchbayTraceEvent>[], false);
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
    return DecodedTraceEvents(events, truncatedTail);
  }

  void appendInternal({
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
    final File events = File('${traceDirectory(traceId).path}/events.ndjson');
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
        eventId: newTraceId(at, prefix: 'ev'),
        recordedAt: at,
        elapsedMs: max(0, at.difference(manifest.createdAt).inMilliseconds),
        type: type,
        requestId: requestId,
        sessionRef: sessionRef == null ? null : redactMap(sessionRef),
        jobId: jobId,
        observer: observer,
        factSource: factSource,
        payload: redactMap(payload),
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
    File('${traceDirectory(manifest.traceId).path}/manifest.json'),
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
  Directory traceDirectory(String traceId) =>
      Directory('${root.path}/$traceId');
  void _ensureRoot() => root.createSync(recursive: true);

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
}
