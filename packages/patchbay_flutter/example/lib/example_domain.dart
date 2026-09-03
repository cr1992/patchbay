import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:permission_handler/permission_handler.dart';

import 'example_log_source.dart';

/// The single write gate this example declares, on both planes.
///
/// `consumerGate` only ever receives a gate ID string (see
/// `PatchbayConsumerGate` in `package:patchbay`); it cannot see a command's
/// descriptor, its `sideEffect`, or which command is being invoked. So the
/// read/write split this example demonstrates is not something the framework
/// infers — it is entirely a choice about *which operations declare this gate
/// ID at all*.
///
/// On the UI plane every call site in `main.dart` that attaches this ID does
/// so because `packages/patchbay/lib/src/ui_protocol_commands.dart` (and
/// `protocol_commands.dart` for navigation) classifies that operation with
/// `sideEffect: PatchbaySideEffect.appState` or `.external`: `ui.semantics.
/// action`/`.tap`, `ui.gesture.*`, `navigation.go`/`push`/`back`,
/// `ui.inspect.select`, `ui.keepAwake.set`, and `ui.text.set`/`.enter`.
/// `ui.capture`/`.capture.diff` deliberately do **not** use it: the same
/// descriptors classify them `sideEffect: none` / `mode: readOnly`, same as
/// `logs.*`/`blob.*`, so they only ever pass the base gate.
///
/// The same rule now applies to the domain descriptors below, and the host
/// enforces it: a `sideEffect != none` row crosses its declared gates before
/// `domainInvoke` is called at all. `patchbay.job.cancel` shares this gate
/// with `example.job.run` on purpose — whoever may start a job may stop it,
/// and a cancel gated more strictly than its run would strand a running job
/// behind a closed gate.
///
/// See `_exampleConsumerGate` in `main.dart` for the actual default (reject)
/// and the one explicit exception this example ships with.
const String exampleWriteGate = 'example.uiWrite';

/// Domain command names the example exposes.
const String incrementCommand = 'example.counter.increment';
const String deviceWriteCommand = 'example.device.write';
const String jobRunCommand = 'example.job.run';
const String idempotentTouchCommand = 'example.idempotent.touch';
const String permissionRequestCommand = 'example.permission.request';
const String permissionStatusCommand = 'example.permission.status';
const String cooperativeWaitCommand = 'example.invocation.cooperativeWait';
const String unresponsiveWaitCommand = 'example.invocation.unresponsiveWait';

const Set<String> examplePermissionNames = <String>{
  'camera',
  'microphone',
  'locationWhenInUse',
  'notifications',
};

/// Consumer seam for reading and requesting native permissions.
///
/// Patchbay only invokes this App-owned seam; the external driver remains
/// responsible for recognizing and operating the system dialog.
abstract interface class ExamplePermissionGateway {
  Future<String> status(String permission);

  /// Dispatches a request without waiting for the dialog decision.
  void request(String permission);
}

final class PermissionHandlerExampleGateway
    implements ExamplePermissionGateway {
  static const Map<String, Permission> _permissions = <String, Permission>{
    'camera': Permission.camera,
    'microphone': Permission.microphone,
    'locationWhenInUse': Permission.locationWhenInUse,
    'notifications': Permission.notification,
  };

  @override
  Future<String> status(String permission) async =>
      (await _permissions[permission]!.status).name;

  @override
  void request(String permission) {
    // Awaiting request() would deadlock the orchestrator: the Future completes
    // only after the external driver answers the dialog. A later status read is
    // the authoritative completion check.
    unawaited(
      _permissions[permission]!.request().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
}

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

const PatchbayResponseSchema _permissionRequestSchema = PatchbayResponseSchema(
  accepted: PatchbayResponseValueSchema(
    type: PatchbayResponseType.object,
    required: <String>{
      'outcome',
      'source',
      'permission',
      'beforePlatformState',
    },
    properties: <String, PatchbayResponseValueSchema>{
      'outcome': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
        allowedValues: <String>{'requested'},
      ),
      'source': PatchbayResponseValueSchema(type: PatchbayResponseType.string),
      'permission': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
      ),
      'beforePlatformState': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
      ),
    },
  ),
);

const PatchbayResponseSchema _permissionStatusSchema = PatchbayResponseSchema(
  accepted: PatchbayResponseValueSchema(
    type: PatchbayResponseType.object,
    required: <String>{'outcome', 'source', 'permission', 'platformState'},
    properties: <String, PatchbayResponseValueSchema>{
      'outcome': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
        allowedValues: <String>{'completed'},
      ),
      'source': PatchbayResponseValueSchema(type: PatchbayResponseType.string),
      'permission': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
      ),
      'platformState': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
      ),
    },
  ),
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
    ExamplePermissionGateway? permissions,
  }) : device = device ?? ExampleDeviceController(),
       permissions = permissions ?? PermissionHandlerExampleGateway() {
    jobs = PatchbayJobRegistry();
  }

  final ValueNotifier<int> counter;
  final ExampleLogSource logs;
  final ExampleDeviceController device;
  final ExamplePermissionGateway permissions;
  late final PatchbayJobRegistry jobs;

  /// requestIds already applied, so a declared-idempotent retry is a no-op
  /// rather than a second effect.
  final Set<String> _appliedRequestIds = <String>{};
  int _touches = 0;

  // 每条 `sideEffect != none` 的行都声明 `exampleWriteGate`，只读行一条都不声明。
  // 这不再只是目录上的说明文字：host 在受理段读回这里的 `gates`，写命令必须先过
  // 基础门与声明门才会进入 `invoke`。因此 `_exampleConsumerGate` 一旦回落到
  // `factoryDefaultWriteGateDecision`，下面六条写命令会立即一起关上，而
  // `example.permission.status` / `patchbay.job.get` / `patchbay.job.wait` 逐字节
  // 不变——「只读默认开放、写入显式开放」在 domain 面有了落点。
  //
  // 反过来也成立：声明一个 `consumerGate` 没接线的门 = 拒绝，不是放行，所以迁移
  // 途中的半成品状态是 fail-closed 的。
  List<PatchbayCommandDescriptor>
  get descriptors => <PatchbayCommandDescriptor>[
    const PatchbayCommandDescriptor(
      name: permissionRequestCommand,
      summary: 'Request one native permission and return after dispatch.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.external,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: <String>{exampleWriteGate},
      responseSchema: _permissionRequestSchema,
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'permission',
          type: PatchbayParameterType.string,
          required: true,
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: permissionStatusCommand,
      summary: 'Read the App-side native permission state.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      responseSchema: _permissionStatusSchema,
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'permission',
          type: PatchbayParameterType.string,
          required: true,
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: incrementCommand,
      summary: 'Increment the example consumer counter.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: <String>{exampleWriteGate},
    ),
    const PatchbayCommandDescriptor(
      name: deviceWriteCommand,
      summary: 'Write a simulated device value and report execution evidence.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.external,
      factSources: <PatchbayFactSource>{
        PatchbayFactSource.appRecorded,
        PatchbayFactSource.commandEcho,
        PatchbayFactSource.deviceReported,
      },
      gates: <String>{exampleWriteGate},
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
      gates: <String>{exampleWriteGate},
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
      gates: <String>{exampleWriteGate},
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
      // 与 example.job.run 共用同一个门：拿得到启动权限就拿得到停止权限。
      gates: <String>{exampleWriteGate},
    ),
    const PatchbayCommandDescriptor(
      name: cooperativeWaitCommand,
      summary: 'Wait until cancellation and confirm the operation stopped.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          required: true,
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: unresponsiveWaitCommand,
      summary:
          'Intentionally ignore cancellation to exercise retained capacity.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          required: true,
        ),
      ],
    ),
  ];

  Future<Map<String, Object?>> invokeWithContext(
    String command,
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context,
  ) {
    return switch (command) {
      cooperativeWaitCommand => _cooperativeWait(arguments, requestId, context),
      unresponsiveWaitCommand => _unresponsiveWait(arguments, requestId),
      _ => invoke(command, arguments, requestId),
    };
  }

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
      permissionRequestCommand => await _permissionRequest(
        arguments,
        requestId,
      ),
      permissionStatusCommand => await _permissionStatus(arguments, requestId),
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

  Future<Map<String, Object?>> _cooperativeWait(
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context,
  ) {
    final Map<String, Object?>? invalid = _validateWait(arguments, requestId);
    if (invalid != null) return Future<Map<String, Object?>>.value(invalid);
    final Completer<Map<String, Object?>> stopped =
        Completer<Map<String, Object?>>();
    context.registerCancellationConfirmation((reason) async {
      if (!stopped.isCompleted) {
        stopped.complete(
          PatchbayInvocation.accepted(
            requestId: requestId,
            payload: <String, Object?>{'stopped': true, 'reason': reason.name},
          ).toJson(),
        );
      }
    });
    return stopped.future;
  }

  Future<Map<String, Object?>> _unresponsiveWait(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    final Map<String, Object?>? invalid = _validateWait(arguments, requestId);
    if (invalid != null) return Future<Map<String, Object?>>.value(invalid);
    return Completer<Map<String, Object?>>().future;
  }

  Map<String, Object?>? _validateWait(
    Map<String, Object?> arguments,
    String requestId,
  ) {
    if (arguments.length != 1 ||
        arguments['timeoutMs'] is! int ||
        (arguments['timeoutMs']! as int) <= 0) {
      return _invalid(requestId, 'timeoutMs must be a positive integer');
    }
    return null;
  }

  Future<Map<String, Object?>> _permissionRequest(
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    final Object? rawPermission = arguments['permission'];
    if (rawPermission is! String ||
        !examplePermissionNames.contains(rawPermission)) {
      return _invalid(requestId, 'permission must name one P0 permission');
    }
    final String beforePlatformState = await permissions.status(rawPermission);
    permissions.request(rawPermission);
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'requested',
        'source': PatchbayFactSource.appRecorded.name,
        'permission': rawPermission,
        // permission_handler has no notDetermined enum: a never-requested App
        // permission reads as `denied`. Keep it as a raw platform view rather
        // than falsely presenting it as Patchbay's canonical state.
        'beforePlatformState': beforePlatformState,
      },
    ).toJson();
  }

  Future<Map<String, Object?>> _permissionStatus(
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    final Object? rawPermission = arguments['permission'];
    if (rawPermission is! String ||
        !examplePermissionNames.contains(rawPermission)) {
      return _invalid(requestId, 'permission must name one P0 permission');
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.appRecorded.name,
        'permission': rawPermission,
        'platformState': await permissions.status(rawPermission),
      },
    ).toJson();
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
    // 这里用 `operation` 而不是 `command`，是一条设计边界而不是偷懒：
    //
    // `PatchbayCommandRegistry` 只装协议自有命令；接入方的域命令按设计走宿主的
    // external fallback（本例的 domainInvoke）。`start(command:)` 只在注册表 dispatch
    // 内部合法，`startBoundToCommand` 又要求 PatchbayJobRegistry(commandRegistry:)。
    // 因此接入方自有的 job 无法获得 responseSchema 校验，其终态 payload 会被标成
    // `legacyUnvalidated`——这正是协议对"未绑定 job"的既定答复。想要被校验的终态，
    // 命令必须是注册表自有的，那是框架侧的面，不是接入方能自行声明的。
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      operation: jobRunCommand,
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
