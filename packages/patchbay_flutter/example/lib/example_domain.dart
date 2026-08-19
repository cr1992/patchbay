import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'example_log_source.dart';

/// Domain command names the example exposes.
const String incrementCommand = 'example.counter.increment';
const String deviceWriteCommand = 'example.device.write';
const String jobRunCommand = 'example.job.run';
const String idempotentTouchCommand = 'example.idempotent.touch';

/// Job ledger commands are consumer-served: the protocol defines their names
/// and payload shapes, the app decides whether it has a ledger at all.
const String jobGetCommand = 'patchbay.job.get';
const String jobWaitCommand = 'patchbay.job.wait';
const String jobCancelCommand = 'patchbay.job.cancel';

/// Simulated device write outcomes, one per execution-evidence class.
///
/// These are **simulated replies**, not a real peripheral. The point is that a
/// caller can drive every branch of the evidence contract from the CLI and see
/// the exit code and fact source that branch produces; a real consumer maps
/// the same four shapes onto its own controller and device SDK.
enum ExampleWriteOutcome {
  notSent,
  sentUnconfirmed,
  unchanged,
  deviceConfirmed,
}

/// A stand-in for the consumer's device-facing controller.
final class ExampleDeviceController {
  int value = 0;
  DateTime? lastConfirmedAt;

  /// Applies [next] and reports which evidence class the write produced.
  ExampleWriteOutcome write(int next, ExampleWriteOutcome requested) {
    switch (requested) {
      case ExampleWriteOutcome.notSent:
        // Nothing left the app: the value is untouched on purpose.
        return ExampleWriteOutcome.notSent;
      case ExampleWriteOutcome.sentUnconfirmed:
        value = next;
        return ExampleWriteOutcome.sentUnconfirmed;
      case ExampleWriteOutcome.unchanged:
        // "Same value" is only honest when it really is the same value.
        if (value != next) {
          value = next;
          lastConfirmedAt = DateTime.now();
          return ExampleWriteOutcome.deviceConfirmed;
        }
        return ExampleWriteOutcome.unchanged;
      case ExampleWriteOutcome.deviceConfirmed:
        value = next;
        lastConfirmedAt = DateTime.now();
        return ExampleWriteOutcome.deviceConfirmed;
    }
  }
}

/// Schema for a write response: a closed shape a script can rely on.
const PatchbayResponseSchema _writeSchema = PatchbayResponseSchema(
  accepted: PatchbayResponseValueSchema(
    type: PatchbayResponseType.object,
    required: <String>{'outcome', 'value', 'execution'},
    properties: <String, PatchbayResponseValueSchema>{
      'outcome': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
        allowedValues: <String>{'completed', 'refused'},
      ),
      'value': PatchbayResponseValueSchema(type: PatchbayResponseType.integer),
      'execution': PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        additionalProperties: true,
      ),
    },
  ),
);

const PatchbayResponseSchema _jobSchema = PatchbayResponseSchema(
  accepted: PatchbayResponseValueSchema(
    type: PatchbayResponseType.object,
    required: <String>{'jobId'},
    properties: <String, PatchbayResponseValueSchema>{
      'jobId': PatchbayResponseValueSchema(type: PatchbayResponseType.string),
    },
  ),
  // job 模式必须为 completed / failed / cancelled 三个终态各声明形状：
  // 少一个，脚本就会在那条路径上重新面对自由 Map。
  terminal: <String, PatchbayResponseValueSchema>{
    'completed': PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
      required: <String>{'steps'},
      properties: <String, PatchbayResponseValueSchema>{
        'steps': PatchbayResponseValueSchema(
          type: PatchbayResponseType.integer,
        ),
      },
    ),
    'failed': PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
      required: <String>{'reason'},
      properties: <String, PatchbayResponseValueSchema>{
        'reason': PatchbayResponseValueSchema(
          type: PatchbayResponseType.string,
        ),
      },
    ),
    'cancelled': PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
      required: <String>{'reason'},
      properties: <String, PatchbayResponseValueSchema>{
        'reason': PatchbayResponseValueSchema(
          type: PatchbayResponseType.string,
        ),
      },
    ),
  },
);

/// Everything the example serves through `domainInvoke`.
///
/// It is deliberately one place: a consumer adapter is where domain vocabulary
/// lives, and keeping it out of the widget tree is the whole point of the
/// separation Patchbay asks for.
final class ExampleDomain {
  ExampleDomain({
    required this.counter,
    required this.logs,
    ExampleDeviceController? device,
  }) : device = device ?? ExampleDeviceController() {
    jobs = PatchbayJobRegistry();
  }

  final ValueNotifier<int> counter;
  final ExampleLogSource logs;
  final ExampleDeviceController device;
  late final PatchbayJobRegistry jobs;

  /// requestIds already applied, so a declared-idempotent retry is a no-op
  /// rather than a second effect.
  final Set<String> _appliedRequestIds = <String>{};
  int _touches = 0;

  List<PatchbayCommandDescriptor> get descriptors =>
      <PatchbayCommandDescriptor>[
        const PatchbayCommandDescriptor(
          name: incrementCommand,
          summary: 'Increment the example consumer counter.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.appState,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        ),
        const PatchbayCommandDescriptor(
          name: deviceWriteCommand,
          summary:
              'Write a simulated device value and report execution evidence.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.external,
          factSources: <PatchbayFactSource>{
            PatchbayFactSource.appRecorded,
            PatchbayFactSource.commandEcho,
            PatchbayFactSource.deviceReported,
          },
          unchangedEvidenceMaxAgeMs: 60000,
          confirmationBudgetMs: 5000,
          responseSchema: _writeSchema,
          parameters: <PatchbayParameterDescriptor>[
            PatchbayParameterDescriptor(
              name: 'value',
              type: PatchbayParameterType.integer,
              required: true,
            ),
            PatchbayParameterDescriptor(
              name: 'outcome',
              type: PatchbayParameterType.string,
              required: false,
            ),
          ],
        ),
        const PatchbayCommandDescriptor(
          name: jobRunCommand,
          summary: 'Run a bounded example job that emits progress events.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.job,
          sideEffect: PatchbaySideEffect.appState,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
          responseSchema: _jobSchema,
          parameters: <PatchbayParameterDescriptor>[
            PatchbayParameterDescriptor(
              name: 'steps',
              type: PatchbayParameterType.integer,
              required: false,
            ),
          ],
        ),
        const PatchbayCommandDescriptor(
          name: idempotentTouchCommand,
          summary:
              'Idempotent external touch used to exercise requestId '
              'de-duplication.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          // retryPolicy 只允许 external：宿主的重试去重边界是「离开 App 的那次写」，
          // 声明在 appState 上会让 App 内副作用被当成可安全重放。
          sideEffect: PatchbaySideEffect.external,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
          retryPolicy: PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 200),
        ),
        const PatchbayCommandDescriptor(
          name: jobGetCommand,
          summary: 'Read one job from the example ledger.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.none,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        ),
        const PatchbayCommandDescriptor(
          name: jobWaitCommand,
          summary: 'Wait for the next event of one example job.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.none,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        ),
        const PatchbayCommandDescriptor(
          name: jobCancelCommand,
          summary: 'Request cancellation of one example job.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.appState,
          factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        ),
      ];

  Future<Map<String, Object?>> invoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    logs.write(
      category: 'domain',
      message: 'invoke $command',
      fields: <String, Object?>{'requestId': requestId},
    );
    return switch (command) {
      incrementCommand => _increment(arguments, requestId),
      deviceWriteCommand => _deviceWrite(arguments, requestId),
      jobRunCommand => _jobRun(arguments, requestId),
      idempotentTouchCommand => _touch(arguments, requestId),
      jobGetCommand => _jobGet(arguments, requestId),
      jobWaitCommand => await _jobWait(arguments, requestId),
      jobCancelCommand => await _jobCancel(arguments, requestId),
      _ => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: 'commandNotRegistered',
          details: <String, Object?>{'command': command},
        ),
      ).toJson(),
    };
  }

  Map<String, Object?> _increment(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    if (arguments.isNotEmpty) {
      return _invalid(requestId, 'increment takes no arguments');
    }
    counter.value += 1;
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.appRecorded.name,
        'counter': counter.value,
      },
    ).toJson();
  }

  Map<String, Object?> _deviceWrite(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    final Object? rawValue = arguments['value'];
    if (rawValue is! int) {
      return _invalid(requestId, 'value must be an integer');
    }
    final String requested =
        arguments['outcome'] as String? ?? 'deviceConfirmed';
    final ExampleWriteOutcome? wanted = ExampleWriteOutcome.values
        .where((ExampleWriteOutcome value) => value.name == requested)
        .firstOrNull;
    if (wanted == null) {
      return _invalid(requestId, 'outcome must name an execution class');
    }
    final DateTime? priorAt = device.lastConfirmedAt;
    final ExampleWriteOutcome outcome = device.write(rawValue, wanted);
    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    final Map<String, Object?> execution = <String, Object?>{
      'classification': outcome.name,
      'factSource': switch (outcome) {
        ExampleWriteOutcome.notSent => PatchbayFactSource.appRecorded.name,
        ExampleWriteOutcome.sentUnconfirmed =>
          PatchbayFactSource.commandEcho.name,
        ExampleWriteOutcome.unchanged => PatchbayFactSource.appRecorded.name,
        ExampleWriteOutcome.deviceConfirmed =>
          PatchbayFactSource.deviceReported.name,
      },
      'observedAtMs': nowMs,
      'reasonCode': outcome == ExampleWriteOutcome.notSent
          ? 'exampleTransportClosed'
          : null,
      if (outcome == ExampleWriteOutcome.unchanged) ...<String, Object?>{
        'priorValueSource': PatchbayFactSource.deviceReported.name,
        'priorObservedAtMs': (priorAt ?? DateTime.now()).millisecondsSinceEpoch,
      },
    };

    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': outcome == ExampleWriteOutcome.notSent
            ? 'refused'
            : 'completed',
        'value': device.value,
        'execution': execution,
      },
    ).toJson();
  }

  Map<String, Object?> _jobRun(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    final Object? rawSteps = arguments['steps'];
    if (rawSteps != null && rawSteps is! int) {
      return _invalid(requestId, 'steps must be an integer');
    }
    final int steps = (rawSteps as int?) ?? 3;
    if (steps < 1 || steps > 20) {
      return _invalid(requestId, 'steps must be between 1 and 20');
    }
    bool cancelled = false;
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      command: jobRunCommand,
      body: () async {
        for (int step = 0; step < steps; step += 1) {
          if (cancelled) {
            throw const PatchbayJobCancellationSignal(
              reason: 'cancelledByOperator',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return <String, Object?>{'steps': steps};
      },
      cancel: () => cancelled = true,
    );
    return PatchbayInvocation.accepted(
      requestId: requestId,
      jobId: jobId,
      payload: <String, Object?>{'jobId': jobId},
    ).toJson();
  }

  Map<String, Object?> _touch(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    // Declared idempotent: a retried requestId must not apply twice.
    if (_appliedRequestIds.add(requestId)) {
      _touches += 1;
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.appRecorded.name,
        'touches': _touches,
      },
    ).toJson();
  }

  Map<String, Object?> _jobGet(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    final Object? jobId = arguments['jobId'];
    if (jobId is! String || jobId.isEmpty) {
      return _invalid(requestId, 'jobId is required');
    }
    final PatchbayJobSnapshot? snapshot = jobs.snapshot(jobId);
    if (snapshot == null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'unknownJob'),
      ).toJson();
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: snapshot.toJson(),
    ).toJson();
  }

  Future<Map<String, Object?>> _jobWait(
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    final Object? jobId = arguments['jobId'];
    final Object? afterSequence = arguments['afterSequence'];
    final Object? timeoutMs = arguments['timeoutMs'];
    if (jobId is! String || jobId.isEmpty) {
      return _invalid(requestId, 'jobId is required');
    }
    if (afterSequence is! int || afterSequence < 0) {
      return _invalid(requestId, 'afterSequence must be a non-negative int');
    }
    if (timeoutMs is! int || timeoutMs <= 0) {
      return _invalid(requestId, 'timeoutMs must be positive');
    }
    final PatchbayJobWaitResult? result = await jobs.waitForChange(
      jobId,
      afterSequence: afterSequence,
      timeout: Duration(milliseconds: timeoutMs),
    );
    if (result == null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'unknownJob'),
      ).toJson();
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: result.toJson(),
    ).toJson();
  }

  Future<Map<String, Object?>> _jobCancel(
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    final Object? jobId = arguments['jobId'];
    if (jobId is! String || jobId.isEmpty) {
      return _invalid(requestId, 'jobId is required');
    }
    final bool accepted = await jobs.cancel(jobId);
    if (!accepted) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'unknownJob'),
      ).toJson();
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{'outcome': 'cancelRequested'},
    ).toJson();
  }

  Map<String, Object?> _invalid(String requestId, String notice) =>
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(code: 'invalidArguments', notice: notice),
      ).toJson();
}
