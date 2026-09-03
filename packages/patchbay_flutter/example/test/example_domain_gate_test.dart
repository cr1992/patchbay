/// PB-050-25 的逐命令回归矩阵：example 全部 domain 命令 + 边界行，
/// 门开 / 门关两态各跑一遍。
///
/// 驱动的是 example 真正发货的那个 host、那份目录和那个 adapter，只把
/// `consumerGate` 换成一份可开关的实现——也就是把 `_exampleConsumerGate` 里为
/// 预检保留的特判删掉之后，一份全新拷贝的出厂状态。
///
/// 有一条边界行不在本文件：「写命令 + sensitive 参数未走 stdin 仍先返回
/// `sensitiveInputRequiresStdin`」。example 的 domain 命令没有 sensitive 参数，
/// 硬造一个只会让样板失真；这条次序由
/// `packages/patchbay/test/host/domain_gate_admission_test.dart` 的
/// 「sensitive-stdin rejection precedes the gate」锁定。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter_example/example_domain.dart';
import 'package:patchbay_flutter_example/main.dart';

/// 目录里 example 自有的 domain 命令，按加闸与否分组。
const Set<String> _writeCommands = <String>{
  permissionRequestCommand,
  deviceWriteCommand,
  idempotentTouchCommand,
  incrementCommand,
  jobRunCommand,
  jobCancelCommand,
};
const Set<String> _readCommands = <String>{
  permissionStatusCommand,
  jobGetCommand,
  jobWaitCommand,
  semanticsBenchmarkCommand,
  cooperativeWaitCommand,
  unresponsiveWaitCommand,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every example domain write declares a gate and no read does', () async {
    final _Harness harness = _harness();
    final Map<String, Object?> catalog = await harness.host.service
        .dispatchCatalog();
    final Map<String, Map<String, Object?>> rows =
        <String, Map<String, Object?>>{};
    for (final Object? row in catalog['commands']! as List<Object?>) {
      final String name = (row! as Map<String, Object?>)['name']! as String;
      if (name.startsWith('example.') || name.startsWith('patchbay.job.')) {
        rows[name] = row as Map<String, Object?>;
      }
    }

    // 锁住命令集合：新增一条 example domain 命令必须在这里登记，才不会绕过
    // 下面的机检。
    expect(rows.keys.toSet(), <String>{..._writeCommands, ..._readCommands});

    for (final MapEntry<String, Map<String, Object?>> row in rows.entries) {
      final bool write = row.value['sideEffect'] != 'none';
      final List<Object?> gates =
          (row.value['gates'] as List<Object?>?) ?? const <Object?>[];
      expect(
        write,
        _writeCommands.contains(row.key),
        reason: '${row.key} 的 sideEffect 分类与本文件的分组不一致',
      );
      expect(
        gates,
        write ? <String>[exampleWriteGate] : <String>[],
        reason: write
            ? '${row.key} 是写命令，必须声明写门，否则它只受基础门保护'
            : '${row.key} 是只读命令，声明写门会与「只读默认开放」矛盾',
      );
    }
  });

  group('gate open — every command behaves exactly as before', () {
    test('the six write commands are admitted and take effect', () async {
      final _Harness harness = _harness();

      expect(
        await harness.accept(permissionRequestCommand, <String, Object?>{
          'permission': 'camera',
        }),
        containsPair('outcome', 'requested'),
      );
      expect(harness.permissions.requests, <String>['camera']);

      expect(
        await harness.accept(deviceWriteCommand, <String, Object?>{'value': 7}),
        containsPair('value', 7),
      );
      expect(harness.host.domain.device.value, 7);

      expect(
        await harness.accept(idempotentTouchCommand, const <String, Object?>{}),
        containsPair('touches', 1),
      );

      expect(
        await harness.accept(incrementCommand, const <String, Object?>{}),
        containsPair('counter', 1),
      );

      final Map<String, Object?> job = await harness.accept(
        jobRunCommand,
        const <String, Object?>{'steps': 1},
      );
      expect(job['jobId'], isA<String>());

      expect(
        await harness.accept(jobCancelCommand, <String, Object?>{
          'jobId': job['jobId'],
        }),
        containsPair('outcome', 'cancelRequested'),
      );
    });

    test('the read commands are admitted without touching the '
        'gate', () async {
      final _Harness harness = _harness()..gate.open = false;

      expect(
        await harness.accept(permissionStatusCommand, <String, Object?>{
          'permission': 'camera',
        }),
        containsPair('platformState', 'denied'),
      );
      expect(
        _code(
          await harness.invoke(jobGetCommand, <String, Object?>{
            'jobId': 'absent',
          }),
        ),
        // 未加闸，因此看到的是 adapter 自己的答复而不是门拒绝。
        'unknownJob',
      );
      expect(
        _code(
          await harness.invoke(jobWaitCommand, <String, Object?>{
            'jobId': 'absent',
            'afterSequence': 0,
            'timeoutMs': 10,
          }),
        ),
        'unknownJob',
      );
      expect(
        _code(
          await harness.invoke(semanticsBenchmarkCommand, <String, Object?>{
            'samples': 'x',
          }),
        ),
        // adapter 自己的答复，而不是门拒绝：只读命令不进闸。
        'benchmarkInvalid',
      );
      expect(harness.gateCalls, isEmpty);
    });

    test('cooperative wait confirms an explicit stop', () async {
      final _Harness harness = _harness();
      const String requestId = 'cooperative-stop';
      const String ownerToken = 'EEEEEEEEEEEEEEEEEEEEEE';
      final PatchbayHostInvocationHandle invocation = harness.host.service
          .dispatchInvokeHandle(
            cooperativeWaitCommand,
            const <String, Object?>{'timeoutMs': 5000},
            requestId,
            ownerToken: ownerToken,
          );
      await Future<void>.delayed(Duration.zero);

      final PatchbayInvocationCancellationResult cancellation = await harness
          .host
          .service
          .cancelInvocation(
            command: cooperativeWaitCommand,
            requestId: requestId,
            ownerToken: ownerToken,
          );

      expect(
        cancellation.outcome,
        PatchbayInvocationCancellationOutcome.confirmed,
      );
      expect(_code(await invocation.response), 'invocationCancelled');
      await invocation.lifecycle;
    });

    test('unresponsive wait retains its slot after deadline', () async {
      final _Harness harness = _harness();
      final Map<String, Object?> response = await harness.host.service
          .dispatchInvoke(
            unresponsiveWaitCommand,
            const <String, Object?>{'timeoutMs': 1},
            'unresponsive-deadline',
            ownerToken: 'FFFFFFFFFFFFFFFFFFFFFF',
            deadline: const Duration(milliseconds: 1),
          );

      expect(_code(response), 'invocationDeadlineExceeded');
      expect(_details(response), <String, Object?>{
        'reason': 'callerDeadlineExceeded',
        'cancellation': 'requested',
      });
      expect(
        await harness.host.service.drainInvocations(timeout: Duration.zero),
        isA<PatchbayInvocationDrainResult>()
            .having(
              (PatchbayInvocationDrainResult result) => result.outcome,
              'outcome',
              PatchbayInvocationDrainOutcome.timedOut,
            )
            .having(
              (PatchbayInvocationDrainResult result) => result.abandonedCount,
              'abandonedCount',
              1,
            ),
      );
    });
  });

  group('gate closed — the factory default', () {
    test('every write command is refused and nothing changes', () async {
      final _Harness harness = _harness()..gate.open = false;

      final Map<String, Object?> job = await harness.accept(
        jobRunCommand,
        const <String, Object?>{'steps': 1},
        // 先在门开时启动一个 job，好让 cancel 有真实目标。
        openGate: true,
      );

      for (final (String command, Map<String, Object?> arguments)
          in <(String, Map<String, Object?>)>[
            (
              permissionRequestCommand,
              <String, Object?>{'permission': 'camera'},
            ),
            (deviceWriteCommand, <String, Object?>{'value': 42}),
            (idempotentTouchCommand, const <String, Object?>{}),
            (incrementCommand, const <String, Object?>{}),
            (jobRunCommand, const <String, Object?>{'steps': 1}),
            (jobCancelCommand, <String, Object?>{'jobId': job['jobId']}),
          ]) {
        final Map<String, Object?> response = await harness.invoke(
          command,
          arguments,
        );
        expect(response['admission'], 'rejected', reason: command);
        expect(response['jobId'], isNull, reason: command);
        expect(_code(response), 'writeGateClosedByDefault', reason: command);
        expect(_details(response), <String, Object?>{
          'gateId': exampleWriteGate,
        }, reason: command);
      }

      // 副作用一件都没有发生。
      expect(harness.permissions.requests, isEmpty);
      expect(harness.host.domain.device.value, 0);
      expect(harness.model.value, 0);
    });

    test('a write gate rejection precedes argument decoding', () async {
      // 刻意的次序后果：host 不持有接入方的参数词表，无法在不进入 adapter 的
      // 情况下解码，所以 domain 命令只能是「gate → adapter 自行 decode」。
      // 安全方向也更好——未获授权者不该先拿到参数探测反馈。
      final _Harness harness = _harness()..gate.open = false;

      final Map<String, Object?> response = await harness.invoke(
        deviceWriteCommand,
        <String, Object?>{'value': 'x'},
      );

      expect(_code(response), 'writeGateClosedByDefault');
      expect(_code(response), isNot('invalidArguments'));
    });

    test(
      'a command the catalog never declared is admitted as a write',
      () async {
        // 「目录里没有」不等于「不会执行」，所以 undeclared 按写加闸。但它声明的门
        // 是空集，按 DG-050-11 裁决①「空集 = 只跑基础门」——而 example 的基础门是
        // 常开的 `_allowBaseGate`，于是这条仍然落到 adapter 的
        // `commandNotRegistered`。加闸这件事本身由审计取值证明：只读命令是
        // `notEvaluated`，这条是 `passed`，说明它确实过了受理闸。
        //
        // 「基础门关闭时 undeclared 先被门拒绝」由
        // `packages/patchbay/test/host/domain_gate_admission_test.dart` 的
        // 「a command missing from the catalog counts as a write」证明；example
        // 没有条件基础门可用来演示。
        final _Harness harness = _harness()..gate.open = false;

        final Map<String, Object?> response = await harness.invoke(
          'example.never.declared',
          const <String, Object?>{},
        );

        expect(_code(response), 'commandNotRegistered');
        expect(harness.host.service.auditEvents.single.gateResult, 'passed');
      },
    );

    test('an idempotent retry replays before a new gate admission', () async {
      final _Harness harness = _harness();

      expect(
        await harness.accept(
          idempotentTouchCommand,
          const <String, Object?>{},
          requestId: 'touch-1',
        ),
        containsPair('touches', 1),
      );

      harness.gate.open = false;
      final Map<String, Object?> replay = await harness.accept(
        idempotentTouchCommand,
        const <String, Object?>{},
        requestId: 'touch-1',
      );

      expect(replay, containsPair('touches', 1));
      expect(harness.gateCalls, <String>[exampleWriteGate]);
    });

    test('the audit ledger records the refusal without the gate ID', () async {
      final _Harness harness = _harness()..gate.open = false;

      await harness.invoke(incrementCommand, const <String, Object?>{});

      final PatchbayAuditEvent event = harness.host.service.auditEvents.single;
      expect(event.command, incrementCommand);
      expect(event.gateResult, 'rejected');
      expect(event.toJson().toString(), isNot(contains(exampleWriteGate)));
    });
  });
}

_Harness _harness() {
  final ExampleCounterModel model = ExampleCounterModel();
  final _SwitchableGate gate = _SwitchableGate();
  final _FakePermissions permissions = _FakePermissions();
  final PatchbayExampleHost host = PatchbayExampleHost(
    model: model,
    registry: PatchbayUiRegistry(),
    router: ExampleRouter(),
    isAppResumed: () => true,
    registrar: (_, _) {},
    consumerGate: gate.decide,
    permissions: permissions,
  );
  addTearDown(() {
    host.dispose();
    model.dispose();
  });
  return _Harness(
    host: host,
    gate: gate,
    model: model,
    permissions: permissions,
  );
}

final class _Harness {
  _Harness({
    required this.host,
    required this.gate,
    required this.model,
    required this.permissions,
  });

  final PatchbayExampleHost host;
  final _SwitchableGate gate;
  final ExampleCounterModel model;
  final _FakePermissions permissions;

  List<String> get gateCalls => gate.calls;

  int _requests = 0;

  Future<Map<String, Object?>> invoke(
    String command,
    Map<String, Object?> arguments, {
    String? requestId,
  }) => host.service.dispatchInvoke(
    command,
    arguments,
    requestId ?? 'matrix-${_requests += 1}',
  );

  /// Invokes and unwraps an accepted payload, failing the test otherwise.
  Future<Map<String, Object?>> accept(
    String command,
    Map<String, Object?> arguments, {
    String? requestId,
    bool openGate = false,
  }) async {
    final bool restore = gate.open;
    if (openGate) gate.open = true;
    final Map<String, Object?> response = await invoke(
      command,
      arguments,
      requestId: requestId,
    );
    if (openGate) gate.open = restore;
    expect(
      response['admission'],
      'accepted',
      reason: '$command was expected to pass the gate: $response',
    );
    return <String, Object?>{
      ...response['payload']! as Map<String, Object?>,
      if (response['jobId'] != null) 'jobId': response['jobId'],
    };
  }
}

/// `_exampleConsumerGate` minus the precheck exception: the write gate is a
/// switch, and closed is the factory default.
final class _SwitchableGate {
  bool open = true;
  final List<String> calls = <String>[];

  FutureOr<PatchbayGateDecision> decide(String id) {
    calls.add(id);
    if (id != exampleWriteGate) {
      return PatchbayGateDecision.reject(
        code: 'unknownConsumerGate',
        notice: 'No consumer gate named $id.',
      );
    }
    return open
        ? const PatchbayGateDecision.allow()
        : factoryDefaultWriteGateDecision(id);
  }
}

final class _FakePermissions implements ExamplePermissionGateway {
  final List<String> requests = <String>[];

  @override
  void request(String permission) => requests.add(permission);

  @override
  Future<String> status(String permission) async => 'denied';
}

String? _code(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}

Map<String, Object?> _details(Map<String, Object?> response) {
  final Map<Object?, Object?> rejection =
      response['rejection']! as Map<Object?, Object?>;
  return Map<String, Object?>.from(
    rejection['details']! as Map<Object?, Object?>,
  );
}
