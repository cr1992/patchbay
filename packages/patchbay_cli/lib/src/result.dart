import 'dart:async';
import 'dart:convert';

import 'ui_manifest.dart';

/// The exit codes `runPatchbayCli` and the `patchbay` executable return.
///
/// The values are a stable contract: a script branches on them, so a code
/// never changes meaning and a new class of failure gets a new number rather
/// than reusing one.
abstract final class PatchbayExitCode {
  static const int accepted = 0;
  static const int transport = 3;
  static const int protocol = 4;
  static const int rejected = 5;
  static const int typedFailure = 6;

  /// A local reconciliation the App answered normally, whose report is not
  /// clean.
  ///
  /// It is deliberately not `5` or `6`: nothing was rejected and nothing failed
  /// — every request in the command succeeded — so a script must be able to
  /// tell "the App refused me" from "the App answered, and what it answered
  /// disagrees with the file I brought".
  static const int verificationDeviation = 7;
  static const int usage = 64;
}

/// A CLI-level error, shaped for `--json` consumers.
///
/// `--json` promises that stdout is machine-readable, but every failure used to
/// leave stdout empty and put a sentence on stderr, so a script that asked for
/// JSON got nothing to parse exactly when something went wrong. This envelope
/// deliberately mirrors the App's rejection envelope — a stable `code` plus
/// free-form `details` — so one reader handles both, and it carries no human
/// sentence: the prose stays on stderr where it always was.
///
/// The code names the failure class, never the transport: URIs, tokens and
/// endpoints must not reach it, for the same reason they never reach stderr.
final class PatchbayErrorEnvelope {
  const PatchbayErrorEnvelope(
    this.code, {
    this.details = const <String, Object?>{},
  });

  final String code;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'error': <String, Object?>{'code': code, 'details': details},
  };
}

/// Classifies a decoded Patchbay response without strengthening its meaning.
int patchbayExitCodeFor(Map<String, Object?> response) {
  if (response['admission'] == 'rejected') {
    final Object? rejection = response['rejection'];
    final Object? code = rejection is Map ? rejection['code'] : null;
    return code == 'commandNotRegistered'
        ? PatchbayExitCode.protocol
        : PatchbayExitCode.rejected;
  }

  if (response['outcome'] == 'failed') {
    return PatchbayExitCode.typedFailure;
  }

  final Object? payload = response['payload'];
  if (payload is Map) {
    if (payload['outcome'] == 'failed') {
      return PatchbayExitCode.typedFailure;
    }
    final Object? execution = payload['execution'];
    if (execution is! Map<Object?, Object?> && payload['dispatched'] == false) {
      return PatchbayExitCode.typedFailure;
    }
    if (payload['terminal'] == true) {
      final Object? events = payload['events'];
      if (events is List && events.isNotEmpty) {
        final Object? last = events.last;
        final Object? phase = last is Map ? last['phase'] : null;
        if (phase == 'failed' || phase == 'cancelled') {
          return PatchbayExitCode.typedFailure;
        }
        if (phase == 'completed') return PatchbayExitCode.accepted;
      }
    }
    if (execution is Map<Object?, Object?>) {
      final Object? classification = execution['classification'];
      if (classification == 'notSent' || classification == 'sentUnconfirmed') {
        return PatchbayExitCode.typedFailure;
      }
      // The typed execution object supersedes the legacy dispatched bit even
      // when the two disagree; the validator records that conflict in details.
      return PatchbayExitCode.accepted;
    }
  }
  return PatchbayExitCode.accepted;
}

/// One human-readable line for a decoded response.
///
/// It summarises, it never classifies: the exit code beside it is what says
/// whether the App admitted the request, so this must not add a verdict of its
/// own. Anything without a known shape falls back to the raw JSON.
String patchbayResponseSummary(Map<String, Object?> value) {
  if (value['localArtifact'] case final Map<Object?, Object?> artifact) {
    return 'artifact=${artifact['path']} length=${artifact['length']} '
        'verified=true';
  }
  // A selected snapshot, matched on its own shape rather than on the key
  // alone: the whole-snapshot read is consumer JSON, and a consumer free to
  // publish a `selection` key must not be able to make this line lie.
  if (value['selection'] case {
    'path': final String path,
    'found': final bool found,
  }) {
    final StringBuffer line = StringBuffer('path=$path found=$found');
    if (found) {
      line.write(' value=${jsonEncode((value['selection']! as Map)['value'])}');
    } else {
      line.write(' miss=${(value['selection']! as Map)['miss']}');
    }
    if (value['wait'] case {'outcome': final Object outcome}) {
      line.write(' wait=$outcome');
    }
    return line.toString();
  }
  if (value case {
    'applicationId': final Object app,
    'appInstanceId': final Object instance,
  }) {
    return '$app instance=$instance';
  }
  // A locally computed report, not an App response. The one-shot path prints
  // the deviations themselves; a repl line owns exactly one line, so it gets
  // the same counts every other summary here gives.
  if (value['schema'] == patchbayUiManifestReportSchema) {
    return patchbayUiManifestSummaryLine(value);
  }
  if (value['uiTargets'] case final List<Object?> targets) {
    return 'commands=${(value['commands'] as List<Object?>?)?.length ?? 0} '
        'uiTargets=${targets.length}';
  }
  if (value['payload'] case {
    'outcome': 'applied',
    'targetId': final Object targetId,
    'generation': final Object generation,
    'operation': final String operation,
    'length': final Object length,
  } when operation == 'text.set' || operation == 'text.enter') {
    final String callbacks = operation == 'text.set'
        ? 'formatters=skipped onChanged=skipped'
        : 'formatters=run onChanged=calledIfConfigured';
    return 'targetId=$targetId generation=$generation operation=$operation '
        'length=$length $callbacks';
  }
  // A terminal job answers with both an id and an outcome; summarising it as
  // just the id would hide the half the operator was waiting for.
  if (value['payload'] case final Map<Object?, Object?> payload
      when payload['terminal'] == true) {
    final Object? events = payload['events'];
    final Object? last = events is List<Object?> && events.isNotEmpty
        ? events.last
        : null;
    final Object? phase = last is Map<Object?, Object?> ? last['phase'] : null;
    final Object? jobId = value['jobId'] ?? payload['jobId'];
    return 'jobId=$jobId terminal=true${phase == null ? '' : ' phase=$phase'}';
  }
  if (value['jobId'] case final String jobId) return 'jobId=$jobId';
  return jsonEncode(value);
}

typedef PatchbayJobReader = Future<Map<String, Object?>> Function(String jobId);

final class PatchbayJobWaitTimeout implements Exception {
  const PatchbayJobWaitTimeout(this.jobId);

  final String jobId;
}

Future<Map<String, Object?>> waitForPatchbayJob({
  required Map<String, Object?> admission,
  required PatchbayJobReader read,
  Duration? timeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final Object? jobId = admission['jobId'];
  if (jobId is! String) return admission;

  final Object? admissionPayload = admission['payload'];
  final Object? suggestedWaitTimeoutMs = admissionPayload is Map
      ? admissionPayload['suggestedWaitTimeoutMs']
      : null;
  final Duration effectiveTimeout =
      timeout ??
      (suggestedWaitTimeoutMs is int && suggestedWaitTimeoutMs > 0
          ? Duration(milliseconds: suggestedWaitTimeoutMs)
          : const Duration(seconds: 60));

  final Stopwatch elapsed = Stopwatch()..start();
  while (elapsed.elapsed < effectiveTimeout) {
    final Map<String, Object?> result = await read(jobId);
    final Object? payload = result['payload'];
    if (payload is Map && payload['terminal'] == true) return result;
    await Future<void>.delayed(pollInterval);
  }
  throw PatchbayJobWaitTimeout(jobId);
}
