import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

PatchbayPermissionDriverRequest _request(
  PatchbayPermissionOperation operation, {
  String permission = 'camera',
  PatchbayPermissionDecision? decision,
  String deviceId = 'device-1',
}) => PatchbayPermissionDriverRequest(
  requestId: 'adapter-test',
  operation: operation,
  deviceId: deviceId,
  applicationId: 'com.example.consumer.debug',
  sessionRef: const <String, Object?>{
    'sessionId': 'consumer-session',
    'appInstanceId': 'consumer-instance',
    'buildMode': 'debug',
  },
  permission: permission,
  decision: decision,
  timeoutMs: 1000,
);

void main() {
  test('Android adapter verifies app and resets permission flags', () async {
    var reset = false;
    final List<List<String>> calls = <List<String>>[];
    Future<PatchbayPlatformCommandResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) async {
      calls.add(arguments);
      if (arguments case ['version']) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'Android Debug Bridge version 1.0.41\n',
          stderr: '',
        );
      }
      if (arguments case ['devices']) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'List of devices attached\ndevice-1\tdevice\n',
          stderr: '',
        );
      }
      if (arguments.contains('path')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'package:/data/app/com.example.consumer.debug/base.apk\n',
          stderr: '',
        );
      }
      if (arguments.contains('pidof')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: '4242\n',
          stderr: '',
        );
      }
      if (arguments.contains('dumpsys')) {
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout:
              'android.permission.CAMERA: granted=false, flags=[${reset ? '' : ' USER_SET'}]\n',
          stderr: '',
        );
      }
      if (arguments.contains('clear-permission-flags')) reset = true;
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }

    final PatchbayPermissionDriverResponse response =
        await PatchbayAndroidPermissionAdapter(
          runCommand: command,
        ).handle(_request(PatchbayPermissionOperation.reset));
    expect(response.accepted, isTrue);
    expect(response.before?.state, PatchbayPermissionState.denied);
    expect(response.after?.state, PatchbayPermissionState.notDetermined);
    expect(
      calls.where(
        (List<String> call) => call.contains('clear-permission-flags'),
      ),
      hasLength(2),
    );
  });

  // 撤销一个已授予的运行时权限会让 Android 终止应用进程——确定性的系统行为，因此
  // 状态答复必须提前把它说出来，而不是让操作者在重连窗口超时后自己反推。
  test(
    'granted Android permission reports that a change restarts the app',
    () async {
      Future<PatchbayPermissionStatus?> statusFor({
        required bool granted,
      }) async {
        Future<PatchbayPlatformCommandResult> command(
          String executable,
          List<String> arguments,
          Duration timeout,
        ) async {
          if (arguments case ['version']) {
            return const PatchbayPlatformCommandResult(
              exitCode: 0,
              stdout: 'Android Debug Bridge version 1.0.41',
              stderr: '',
            );
          }
          if (arguments.contains('devices')) {
            return const PatchbayPlatformCommandResult(
              exitCode: 0,
              stdout: 'List of devices attached\ndevice-1\tdevice\n',
              stderr: '',
            );
          }
          // 适配器不假定应用存在也不假定它在跑：先 `pm path` 再 `pidof`。
          if (arguments.contains('path')) {
            return const PatchbayPlatformCommandResult(
              exitCode: 0,
              stdout: 'package:/data/app/consumer/base.apk',
              stderr: '',
            );
          }
          if (arguments.contains('pidof')) {
            return const PatchbayPlatformCommandResult(
              exitCode: 0,
              stdout: '4321',
              stderr: '',
            );
          }
          if (arguments.contains('dumpsys')) {
            return PatchbayPlatformCommandResult(
              exitCode: 0,
              stdout:
                  'android.permission.CAMERA: granted=$granted, '
                  'flags=[${granted ? ' USER_SET' : ''}]\n',
              stderr: '',
            );
          }
          return const PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: '',
            stderr: '',
          );
        }

        final PatchbayPermissionDriverResponse response =
            await PatchbayAndroidPermissionAdapter(
              runCommand: command,
            ).handle(_request(PatchbayPermissionOperation.status));
        expect(response.accepted, isTrue, reason: response.code ?? '');
        return response.after;
      }

      final PatchbayPermissionStatus? grantedStatus = await statusFor(
        granted: true,
      );
      expect(grantedStatus?.state, PatchbayPermissionState.granted);
      expect(
        grantedStatus?.requiresRestart,
        isTrue,
        reason: '从 granted 出发只能 revoke，而 revoke 必然杀进程',
      );

      final PatchbayPermissionStatus? pendingStatus = await statusFor(
        granted: false,
      );
      expect(
        pendingStatus?.requiresRestart,
        isFalse,
        reason: 'grant 不会终止进程，不该要求重启',
      );
    },
  );

  // 假 shell：可配置"应用声明了哪些权限"与"设备上有没有注册 runner"。
  Future<PatchbayPlatformCommandResult> Function(String, List<String>, Duration)
  _android({
    Set<String> declared = const <String>{'android.permission.CAMERA'},
    String? installedRunner,
  }) => (String executable, List<String> arguments, Duration timeout) async {
    if (arguments case ['version']) {
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: 'Android Debug Bridge version 1.0.41',
        stderr: '',
      );
    }
    if (arguments.contains('devices')) {
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: 'List of devices attached\ndevice-1\tdevice\n',
        stderr: '',
      );
    }
    if (arguments.contains('instrumentation')) {
      return PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: installedRunner == null
            ? ''
            : 'instrumentation:$installedRunner (target=com.example.consumer)\n',
        stderr: '',
      );
    }
    if (arguments.contains('path')) {
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: 'package:/data/app/consumer/base.apk',
        stderr: '',
      );
    }
    if (arguments.contains('pidof')) {
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: '4321',
        stderr: '',
      );
    }
    if (arguments.contains('dumpsys')) {
      return PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: <String>[
          for (final String name in declared) '$name: granted=false, flags=[]',
        ].join('\n'),
        stderr: '',
      );
    }
    return const PatchbayPlatformCommandResult(
      exitCode: 0,
      stdout: '',
      stderr: '',
    );
  };

  // 应用没声明的权限是一条可读事实，不是协议失败：把它报成拒绝会让同一个 code 同时
  // 表示"平台不支持"和"这个应用没声明"，而两者的处置完全不同。
  test(
    'a permission the app never declared reads back as unsupported',
    () async {
      final PatchbayPermissionDriverResponse response =
          await PatchbayAndroidPermissionAdapter(
            runCommand: _android(declared: const <String>{}),
          ).handle(_request(PatchbayPermissionOperation.status));
      expect(response.accepted, isTrue, reason: response.code ?? '');
      expect(response.after?.state, PatchbayPermissionState.unsupported);
      expect(response.after?.platformState, 'notDeclaredByApp');
      expect(response.after?.supportedActions, isEmpty);
    },
  );

  // capability 不能凭"配了 runner 路径"就宣布能处理弹窗：路径存在与 runner 真的装在这台
  // 设备上是两件事，声明比事实宽会让调用方按声明编排、到执行时才失败。
  test(
    'capabilities only claim exercise when the runner is installed',
    () async {
      Future<Set<String>> decisionsFor({required bool installed}) async {
        const String runner =
            'com.example.consumer.test/androidx.test.runner'
            '.AndroidJUnitRunner';
        final PatchbayPermissionDriverResponse response =
            await PatchbayAndroidPermissionAdapter(
              instrumentationRunner: runner,
              runCommand: _android(installedRunner: installed ? runner : null),
            ).handle(_request(PatchbayPermissionOperation.capabilities));
        final PatchbayPermissionCapability capability =
            response.capabilities!.permissions['camera']!;
        return <String>{
          for (final PatchbayPermissionDecision decision
              in capability.decisions)
            decision.name,
          if (capability.actions.contains(PatchbayPermissionAction.exercise))
            'exercise',
        };
      }

      expect(await decisionsFor(installed: false), isEmpty);
      final Set<String> claimed = await decisionsFor(installed: true);
      expect(claimed, contains('exercise'));
      expect(claimed, contains('allow'));
      // 通知没有"仅这一次"这一档，不能跟着相机一起宣布。
      final PatchbayPermissionDriverResponse response =
          await PatchbayAndroidPermissionAdapter(
            instrumentationRunner: 'r/r',
            runCommand: _android(
              declared: const <String>{
                'android.permission.CAMERA',
                'android.permission.POST_NOTIFICATIONS',
              },
              installedRunner: 'r/r',
            ),
          ).handle(_request(PatchbayPermissionOperation.capabilities));
      expect(
        response.capabilities!.permissions['notifications']!.decisions,
        isNot(contains(PatchbayPermissionDecision.allowOnce)),
      );
    },
  );

  // adb 撤销只能到 notDetermined；把 denied 当成可达会先改掉权限、再报状态不符，
  // 副作用已经发生却什么都没达成。
  test('normalize to denied is refused before touching the device', () async {
    final List<List<String>> calls = <List<String>>[];
    Future<PatchbayPlatformCommandResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) {
      calls.add(arguments);
      return _android()(executable, arguments, timeout);
    }

    final PatchbayPermissionDriverResponse response =
        await PatchbayAndroidPermissionAdapter(runCommand: command).handle(
          PatchbayPermissionDriverRequest(
            requestId: 'adapter-test',
            operation: PatchbayPermissionOperation.normalize,
            deviceId: 'device-1',
            applicationId: 'com.example.consumer.debug',
            sessionRef: const <String, Object?>{
              'sessionId': 'consumer-session',
              'appInstanceId': 'consumer-instance',
              'buildMode': 'debug',
            },
            permission: 'camera',
            state: PatchbayPermissionState.denied,
            timeoutMs: 1000,
          ),
        );
    expect(response.accepted, isFalse);
    expect(response.code, 'permissionStateUnreachable');
    expect(
      calls.where((List<String> call) => call.contains('revoke')),
      isEmpty,
      reason: '拒绝必须发生在改设备之前',
    );
  });

  test('Android exercise marks both snapshots as crossing system UI', () async {
    var handled = false;
    const String runner =
        'com.example.consumer.test/androidx.test.runner.AndroidJUnitRunner';
    final String marker = base64Encode(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'targetPackage': 'com.example.consumer.debug',
          'permission': 'camera',
          'decision': 'allow',
          'handled': true,
        }),
      ),
    );
    Future<PatchbayPlatformCommandResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) async {
      if (arguments case ['version']) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'Android Debug Bridge version 1.0.41',
          stderr: '',
        );
      }
      if (arguments.contains('devices')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'List of devices attached\ndevice-1\tdevice\n',
          stderr: '',
        );
      }
      if (arguments.contains('path')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'package:/data/app/consumer/base.apk',
          stderr: '',
        );
      }
      if (arguments.contains('pidof')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: '4321',
          stderr: '',
        );
      }
      if (arguments.contains('dumpsys')) {
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'android.permission.CAMERA: granted=$handled, flags=[]\n',
          stderr: '',
        );
      }
      if (arguments.contains('instrument')) {
        handled = true;
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'PATCHBAY_RESULT=$marker\nOK (1 test)\n',
          stderr: '',
        );
      }
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }

    final PatchbayPermissionDriverResponse response =
        await PatchbayAndroidPermissionAdapter(
          instrumentationRunner: runner,
          runCommand: command,
        ).handle(
          _request(
            PatchbayPermissionOperation.exercise,
            decision: PatchbayPermissionDecision.allow,
          ),
        );
    expect(response.accepted, isTrue, reason: response.code ?? '');
    expect(response.before?.systemUiExpected, isTrue);
    expect(response.after?.systemUiExpected, isTrue);
    expect(response.interruption?.handled, isTrue);
  });

  test('iOS adapter exposes reset without inventing a status fact', () async {
    Future<PatchbayPlatformCommandResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) async {
      if (arguments case ['simctl', 'help']) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'simctl',
          stderr: '',
        );
      }
      if (arguments.contains('--json')) {
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: jsonEncode(<String, Object?>{
            'devices': <String, Object?>{
              'runtime': <Object?>[
                <String, Object?>{
                  'udid': 'device-1',
                  'state': 'Booted',
                  'isAvailable': true,
                },
              ],
            },
          }),
          stderr: '',
        );
      }
      if (arguments.contains('get_app_container')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: '/sim/app',
          stderr: '',
        );
      }
      if (arguments.contains('launchctl')) {
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'UIKitApplication:com.example.consumer.debug',
          stderr: '',
        );
      }
      return const PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );
    }

    final PatchbayIosPermissionAdapter adapter = PatchbayIosPermissionAdapter(
      runCommand: command,
    );
    final PatchbayPermissionDriverResponse capabilities = await adapter.handle(
      _request(PatchbayPermissionOperation.capabilities),
    );
    expect(capabilities.accepted, isTrue);
    expect(
      capabilities.capabilities?.permissions['camera']?.actions,
      contains(PatchbayPermissionAction.reset),
    );

    final PatchbayPermissionDriverResponse reset = await adapter.handle(
      _request(PatchbayPermissionOperation.reset),
    );
    expect(reset.accepted, isTrue);
    expect(reset.after?.state, PatchbayPermissionState.notDetermined);
    expect(
      reset.after?.factSource,
      PatchbayPermissionFactSource.deviceReported,
    );

    final PatchbayPermissionDriverResponse status = await adapter.handle(
      _request(PatchbayPermissionOperation.status),
    );
    expect(status.accepted, isFalse);
    expect(status.code, 'permissionUnsupported');
  });

  test(
    'iOS capabilities do not expose Simulator reset for a physical device',
    () async {
      Future<PatchbayPlatformCommandResult> command(
        String executable,
        List<String> arguments,
        Duration timeout,
      ) async {
        if (arguments case ['simctl', 'help']) {
          return const PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: 'simctl',
            stderr: '',
          );
        }
        if (arguments.contains('--json')) {
          return PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: jsonEncode(<String, Object?>{
              'devices': <String, Object?>{
                'runtime': <Object?>[
                  <String, Object?>{
                    'udid': 'simulator-1',
                    'state': 'Booted',
                    'isAvailable': true,
                  },
                ],
              },
            }),
            stderr: '',
          );
        }
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        );
      }

      final PatchbayPermissionDriverResponse response =
          await PatchbayIosPermissionAdapter(runCommand: command).handle(
            _request(
              PatchbayPermissionOperation.capabilities,
              deviceId: 'physical-device',
            ),
          );

      expect(response.accepted, isFalse);
      expect(response.code, 'platformDeviceUnavailable');
    },
  );

  test(
    'recovery reconnects, probes lifecycle and re-resolves current targets',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'patchbay-permission-recovery-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final PatchbaySessionStore store = PatchbaySessionStore(directory.path);
      final PatchbaySessionRecord record = PatchbaySessionRecord(
        sessionId: 'consumer-session',
        applicationId: 'com.example.consumer.debug',
        appInstanceId: 'before-instance',
        isolateId: 'before-isolate',
        processId: pid,
        wsUri: 'ws://127.0.0.1:1/token/ws',
        buildMode: 'debug',
        createdAt: DateTime.now().toUtc(),
        workspacePath: Directory.current.path,
        deviceId: 'device-1',
      );
      store.write(record);
      const PatchbayRuntimeIdentity identity = PatchbayRuntimeIdentity(
        schemaVersion: 1,
        applicationId: 'com.example.consumer.debug',
        appInstanceId: 'after-instance',
        isolateId: 'after-isolate',
      );
      final PatchbaySessionResolver sessions = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => identity,
      );
      final List<String> events = <String>[];
      final PatchbayPermissionRecoveryResult result =
          await PatchbayPermissionRecoveryCoordinator(
            sessions: sessions,
            connect: (_) async => _RecoveryClient(),
            delay: (_) async {},
            eventSink: (String event, Map<String, Object?> fields) {
              events.add(event);
            },
          ).recover(
            PatchbayDiscoveredSession(record: record, identity: _before),
            timeout: const Duration(seconds: 1),
          );
      expect(result.runtimeRestarted, isTrue);
      expect(result.catalogRefreshed, isTrue);
      expect(result.resolvedTargetCount, 0);
      expect(
        events,
        containsAll(<String>['app.resumeObserved', 'permission.transition']),
      );
    },
  );
}

const PatchbayRuntimeIdentity _before = PatchbayRuntimeIdentity(
  schemaVersion: 1,
  applicationId: 'com.example.consumer.debug',
  appInstanceId: 'before-instance',
  isolateId: 'before-isolate',
);

final class _RecoveryClient implements PatchbayClient {
  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'com.example.consumer.debug',
    'appInstanceId': 'after-instance',
    'isolateId': 'after-isolate',
  };

  @override
  Future<Map<String, Object?>> catalog() async => <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{'name': patchbayLifecycleProbeCommand},
    ],
    'uiTargets': <Object?>[],
  };

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async => <String, Object?>{'admission': 'accepted'};

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, Object?>> focusTree() => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> renderTree() => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> snapshot({PatchbaySnapshotRequest? request}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> widgetTree() => throw UnimplementedError();
}
