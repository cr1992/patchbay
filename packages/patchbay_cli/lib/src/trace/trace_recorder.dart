import 'dart:io';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

import 'trace_models.dart';
import 'trace_redaction.dart';
import 'trace_store.dart';

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
  }) => store.appendInternal(
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
    final String runId = newTraceId(DateTime.now().toUtc(), prefix: 'run');
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
      if (stableRejectionCode(response) case final String code)
        'stableCode': code,
      if (executionProjection(response)
          case final Map<String, Object?> execution)
        'execution': execution,
      if (legacy) 'legacyUnvalidated': true,
      if (legacy && includeLegacyPayload)
        'payload': redactMap(
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
    if (!sha256Pattern.hasMatch(sha256Value) ||
        length < 0 ||
        length > patchbayTraceMaxArtifactBytes) {
      throw const PatchbayTraceException('traceArtifactInvalid');
    }
    final File source = File(localPath);
    if (!source.existsSync() || source.lengthSync() != length) {
      throw const PatchbayTraceException('traceArtifactMissing');
    }
    final Directory targetDirectory = Directory(
      '${store.traceDirectory(traceId).path}/artifacts',
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

List<Map<String, Object?>> commandFacts(List<PatchbayTraceEvent> events) {
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

Map<String, Object?>? executionProjection(Map<String, Object?> response) {
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

String? stableRejectionCode(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?> && rejection['code'] is String
      ? rejection['code']! as String
      : null;
}
