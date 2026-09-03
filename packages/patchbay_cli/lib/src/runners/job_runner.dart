import 'package:patchbay/patchbay_protocol.dart';

import '../client.dart';
import '../result.dart';

/// Runner responsible for polling and waiting on asynchronous jobs.
abstract final class JobRunner {
  /// Waits for a job to reach a terminal state, utilizing server long-polling when available
  /// or falling back to client-side periodic polling.
  static Future<Map<String, Object?>> waitForJob(
    PatchbayClient connection,
    Map<String, Object?> catalog,
    Map<String, Object?> admission,
    Duration? descriptorTimeout, {
    required bool serverWaitAvailable,
    required Future<Map<String, Object?>> Function(
      PatchbayClient connection,
      Map<String, Object?> catalog,
      String command,
      Map<String, Object?> parameters, {
      Duration? deadline,
    })
    invokeAgainstCatalog,
  }) async {
    final Object? jobIdValue = admission['jobId'];
    if (jobIdValue is! String) return admission;
    final Object? admissionPayload = admission['payload'];
    final Object? suggestedMs = admissionPayload is Map
        ? admissionPayload['suggestedWaitTimeoutMs']
        : null;
    final Duration timeout =
        descriptorTimeout ??
        (suggestedMs is int && suggestedMs > 0
            ? Duration(milliseconds: suggestedMs)
            : const Duration(seconds: 60));
    if (!serverWaitAvailable) {
      final Map<String, Object?> response = await waitForPatchbayJob(
        admission: admission,
        timeout: timeout,
        read: (String jobId) => invokeAgainstCatalog(
          connection,
          catalog,
          'patchbay.job.get',
          <String, Object?>{'jobId': jobId},
        ),
      );
      return <String, Object?>{
        ...response,
        'jobId': jobIdValue,
        'waitMode': 'legacyPolling',
        'waitNotice':
            'host did not catalog patchbay.job.wait; CLI polled patchbay.job.get',
      };
    }

    final Stopwatch elapsed = Stopwatch()..start();
    var afterSequence = 0;
    while (elapsed.elapsed < timeout) {
      final Duration remaining = timeout - elapsed.elapsed;
      final int requestTimeoutMs = remaining.inMilliseconds.clamp(1, 30000);
      final Map<String, Object?> response = await invokeAgainstCatalog(
        connection,
        catalog,
        'patchbay.job.wait',
        <String, Object?>{
          'jobId': jobIdValue,
          'afterSequence': afterSequence,
          'timeoutMs': requestTimeoutMs,
        },
        deadline: Duration(milliseconds: requestTimeoutMs),
      );
      if (response['admission'] == 'rejected') return response;
      final Object? payload = response['payload'];
      if (payload is! Map<Object?, Object?>) {
        throw const PatchbayProtocolException('jobWaitPayloadContractViolated');
      }
      final PatchbayJobWaitResultWire result;
      try {
        result = PatchbayJobWaitResultWire.fromJson(
          Map<String, Object?>.from(payload),
        );
      } on Object {
        throw const PatchbayProtocolException('jobWaitPayloadContractViolated');
      }
      for (final PatchbayJobEventWire event in result.snapshot.events) {
        if (event.sequence > afterSequence) afterSequence = event.sequence;
      }
      if (result.snapshot.terminal) {
        return <String, Object?>{
          ...response,
          'jobId': jobIdValue,
          'payload': <String, Object?>{
            ...result.snapshot.toJson(),
            'waitOutcome': result.outcome.toJson(),
          },
          'waitMode': 'serverLongPoll',
        };
      }
    }
    throw PatchbayJobWaitTimeout(jobIdValue);
  }
}
