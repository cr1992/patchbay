import 'dart:async';

abstract final class PatchbayExitCode {
  static const int accepted = 0;
  static const int transport = 3;
  static const int protocol = 4;
  static const int rejected = 5;
  static const int typedFailure = 6;
  static const int usage = 64;
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
    if (payload['outcome'] == 'failed' || payload['dispatched'] == false) {
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
      }
    }
  }
  return PatchbayExitCode.accepted;
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
