import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'trace_redaction.dart';

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
      sha256.convert(utf8.encode(canonicalTraceJson(toJson()))).toString();
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

final class DecodedTraceEvents {
  const DecodedTraceEvents(this.events, this.truncatedTail);

  final List<PatchbayTraceEvent> events;
  final bool truncatedTail;
}
