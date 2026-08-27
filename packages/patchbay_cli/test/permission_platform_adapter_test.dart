import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/android_permission_adapter.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/ios_permission_adapter.dart';
import 'package:patchbay_cli/src/permission_platform_adapter.dart';
import 'package:patchbay_cli/src/permission_recovery.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_resolver.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:test/test.dart';

PatchbayPermissionDriverRequest _request(
  PatchbayPermissionOperation operation, {
  String permission = 'camera',
  PatchbayPermissionDecision? decision,
  PatchbayPermissionState? state,
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
  state: state,
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

  // BUG-20260826-02 的真正根因：`, flags=[...]` 是可选小节，Android 在这个权限
  // 当前没有任何标记时（典型形态——刚 `pm grant` 出来，还没被打上 USER_SET /
  // USER_FIXED / ONE_TIME / REVOKE_WHEN_REQUESTED 里的任何一个）会整段省略它，
  // 不打印成 `flags=[]`。真机实测录制：`dumpsys package` 里刚授予的
  // `android.permission.CAMERA: granted=true` 后面什么都没有。旧正则把逗号+
  // flags 写成必需，于是这行永远匹配不上，落进"没有条目"分支——之前被误诊断
  // 为写后立即复核撞上设备最终一致性窗口，实际上重试多少次都读到同一段解析
  // 失败的文本，不会因为等待而变好。
  test('a freshly granted permission with no flags at all (Android omits the '
      'flags clause, not an empty one) still parses as granted', () async {
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
        // 录制自真机：没有 `, flags=[...]` 后缀，不是 `flags=[]`。
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: 'android.permission.CAMERA: granted=true\n',
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
    expect(response.after?.state, PatchbayPermissionState.granted);
    expect(response.after?.platformState, 'granted');
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

  // BUG-20260826-02：写后立即复核可能撞上设备侧的最终一致性窗口（`pm grant` /
  // `pm revoke` 退出后立即查询 `dumpsys package`，某些 OEM / Android 版本组合上
  // 有一定概率仍读到写入前的旧状态，稍后再查会显示已生效）。controller 已裁决
  // 允许对写后复核的"读"做有界重试来吸收这条窗口，不重发 mutation，窗口耗尽仍
  // 照旧报 `permissionStateMismatch`。
  //
  // 本仓这条缺陷最初排查到的真机复现，事后定位到真正根因其实是 `_status` 里
  // `flags=[...]` 小节可选未处理的解析缺陷（已在 `_status` 修好，见其注释）——
  // 重试再多次也读不到一段永远解析失败的文本。这里的重试逻辑仍然按 controller
  // 裁决保留，作为对真实存在、只是更少见的设备最终一致性窗口的防御。
  group('BUG-20260826-02 post-mutation retry', () {
    // 假 shell：dumpsys 的 CAMERA 运行时行从第几次查询开始"翻新"可配置，
    // 用来模拟"前 N 次读旧值、之后读新值"的最终一致窗口。null 表示永远读旧值
    // （模拟窗口耗尽都等不到的形态）。
    Future<PatchbayPlatformCommandResult> Function(
      String,
      List<String>,
      Duration,
    )
    android({required int? freshFromCall}) {
      var dumpsysCalls = 0;
      return (
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
          dumpsysCalls++;
          final bool granted =
              freshFromCall != null && dumpsysCalls >= freshFromCall;
          return PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout:
                'android.permission.CAMERA: granted=$granted, '
                'flags=[${granted ? ' USER_SET' : ''}]\n',
            stderr: '',
          );
        }
        // pm grant / pm revoke / clear-permission-flags：不重发 mutation，
        // 每条只应该被调用一次，用调用计数在下方复核。
        return const PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        );
      };
    }

    test('normalize granted retries the post-mutation read until it observes '
        'the granted state, and does not resend the grant', () async {
      final List<Duration> delays = <Duration>[];
      var grantCalls = 0;
      final Future<PatchbayPlatformCommandResult> Function(
        String,
        List<String>,
        Duration,
      )
      base = android(freshFromCall: 3);
      Future<PatchbayPlatformCommandResult> command(
        String executable,
        List<String> arguments,
        Duration timeout,
      ) {
        if (arguments.contains('grant')) grantCalls++;
        return base(executable, arguments, timeout);
      }

      final PatchbayPermissionDriverResponse response =
          await PatchbayAndroidPermissionAdapter(
            runCommand: command,
            delay: (Duration duration) async {
              delays.add(duration);
            },
          ).handle(
            _request(
              PatchbayPermissionOperation.normalize,
              state: PatchbayPermissionState.granted,
            ),
          );

      expect(response.accepted, isTrue, reason: response.code ?? '');
      expect(response.after?.state, PatchbayPermissionState.granted);
      // 第 1 次 dumpsys 是写前 before，第 2 次是写后第一次复核（仍是旧值），
      // 第 3 次才翻新——所以只应该看到恰好一次退避等待。
      expect(delays, equals(<Duration>[const Duration(milliseconds: 100)]));
      expect(grantCalls, 1, reason: '重试只重发"读"，mutation 本身只应该发生一次');
    });

    test('normalize granted gives up after the bounded retry window and '
        'reports the still-stale state as-is, not a fabricated one', () async {
      final List<Duration> delays = <Duration>[];
      final PatchbayPermissionDriverResponse response =
          await PatchbayAndroidPermissionAdapter(
            runCommand: android(freshFromCall: null),
            delay: (Duration duration) async {
              delays.add(duration);
            },
          ).handle(
            _request(
              PatchbayPermissionOperation.normalize,
              state: PatchbayPermissionState.granted,
            ),
          );

      expect(response.accepted, isTrue, reason: response.code ?? '');
      // 窗口耗尽仍然如实报最后一次观测到的状态，不伪造成功；由调用方
      // （PatchbayPermissionDriverRunner）据此判 permissionStateMismatch，
      // 这里不新增字段、不改信封形状。
      expect(response.after?.state, PatchbayPermissionState.notDetermined);
      // 指数退避总和恰好等于 5 秒的有界窗口，不多不少：
      // 100+200+400+800+1600=3100，最后一段被剩余预算裁到 1900。
      expect(
        delays,
        equals(const <Duration>[
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
          Duration(milliseconds: 400),
          Duration(milliseconds: 800),
          Duration(milliseconds: 1600),
          Duration(milliseconds: 1900),
        ]),
      );
      expect(
        delays.fold<Duration>(
          Duration.zero,
          (Duration sum, Duration each) => sum + each,
        ),
        const Duration(seconds: 5),
      );
    });

    // reset 复核同一条最终一致性窗口，判定目标从 granted 换成 notDetermined。
    test('reset retries the post-mutation read the same way, targeting '
        'notDetermined', () async {
      final List<Duration> delays = <Duration>[];
      // reset 的起点是"已授予"（reset 之前先读 before，再 revoke），revoke
      // 之后前几次复核仍读到旧的 granted=true，第 3 次才翻新为 false。
      var dumpsysCalls = 0;
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
          dumpsysCalls++;
          // 第 1 次（before）读旧值 granted=true；写后复核第 2 次仍是旧值；
          // 第 3 次才翻新为 notDetermined。
          final bool stillGranted = dumpsysCalls < 3;
          return PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout:
                'android.permission.CAMERA: granted=$stillGranted, '
                'flags=[${stillGranted ? ' USER_SET' : ''}]\n',
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
            delay: (Duration duration) async {
              delays.add(duration);
            },
          ).handle(_request(PatchbayPermissionOperation.reset));

      expect(response.accepted, isTrue, reason: response.code ?? '');
      expect(response.after?.state, PatchbayPermissionState.notDetermined);
      expect(delays, equals(<Duration>[const Duration(milliseconds: 100)]));
    });
  });

  // 假 shell：可配置"应用声明了哪些权限"、"哪些声明过的权限还没有 runtime 记录"
  // 与"设备上有没有注册 runner"。
  //
  // dumpsys 输出录制自真机形态（见 BUG-20260826-01）：`requested permissions:`
  // 小节列出 manifest 合并声明过的全部权限（不带 granted=），`runtime
  // permissions:` 小节只列出已经被物化过的权限（带 granted=/flags=）——真机上
  // 声明过但从未被请求过的权限只会出现在前者，不出现在后者。
  Future<PatchbayPlatformCommandResult> Function(String, List<String>, Duration)
  _android({
    Set<String> declared = const <String>{'android.permission.CAMERA'},
    Set<String> withoutRuntimeRecord = const <String>{},
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
      final StringBuffer buffer = StringBuffer()
        ..writeln('    requested permissions:');
      for (final String name in declared) {
        buffer.writeln('      $name');
      }
      buffer.writeln('    runtime permissions:');
      for (final String name in declared) {
        if (withoutRuntimeRecord.contains(name)) continue;
        buffer.writeln('      $name: granted=false, flags=[]');
      }
      return PatchbayPlatformCommandResult(
        exitCode: 0,
        stdout: buffer.toString(),
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

  // BUG-20260826-01：应用声明过的权限，Android 还没有为它物化 runtime 记录
  // （真机实测形态——`dumpsys package` 的 `requested permissions:` 里有
  // CAMERA/RECORD_AUDIO/ACCESS_FINE_LOCATION/POST_NOTIFICATIONS，`runtime
  // permissions:` 却只物化了被请求过的 ACCESS_COARSE_LOCATION 一行）。这不是
  // "没声明"，之前把它跟真未声明混在一起报 notDeclaredByApp，是这条缺陷的根因。
  test('a declared permission without a materialized runtime record reports '
      'noRuntimeRecord, not notDeclaredByApp', () async {
    final PatchbayPermissionDriverResponse response =
        await PatchbayAndroidPermissionAdapter(
          runCommand: _android(
            declared: const <String>{'android.permission.CAMERA'},
            withoutRuntimeRecord: const <String>{'android.permission.CAMERA'},
          ),
        ).handle(_request(PatchbayPermissionOperation.status));
    expect(response.accepted, isTrue, reason: response.code ?? '');
    expect(response.after?.state, PatchbayPermissionState.notDetermined);
    expect(response.after?.platformState, 'noRuntimeRecord');
    // 声明过就有完整动作集：grant/revoke/reset 都能作用于它（`pm grant` 会
    // 促成物化），不该被收窄成只剩 status。
    expect(
      response.after?.supportedActions,
      containsAll(<PatchbayPermissionAction>{
        PatchbayPermissionAction.status,
        PatchbayPermissionAction.grant,
        PatchbayPermissionAction.revoke,
        PatchbayPermissionAction.reset,
      }),
    );
  });

  // 同一个形态下，capabilities 的 preflight（`PatchbayPermissionDriverRunner.run`
  // 在每次 normalize/reset 前都会先问一次 capabilities）不能把这个权限的 actions
  // 收窄成只剩 status——否则 preflight 会在到达 `_normalize`/`_reset` 之前就把
  // normalize/reset 拒掉（`permissionUnsupported`），这正是四步预检退 6 的直接原因。
  test('capabilities preflight still grants normalize/reset actions when the '
      'runtime record has not materialized yet', () async {
    final PatchbayPermissionDriverResponse response =
        await PatchbayAndroidPermissionAdapter(
          runCommand: _android(
            declared: const <String>{'android.permission.CAMERA'},
            withoutRuntimeRecord: const <String>{'android.permission.CAMERA'},
          ),
        ).handle(_request(PatchbayPermissionOperation.capabilities));
    expect(response.accepted, isTrue, reason: response.code ?? '');
    final PatchbayPermissionCapability capability =
        response.capabilities!.permissions['camera']!;
    expect(
      capability.actions,
      containsAll(<PatchbayPermissionAction>{
        PatchbayPermissionAction.status,
        PatchbayPermissionAction.grant,
        PatchbayPermissionAction.revoke,
        PatchbayPermissionAction.reset,
      }),
    );
  });

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
    'iOS physical-device capabilities come from the configured XCUITest runner',
    () async {
      Future<PatchbayPlatformCommandResult> command(
        String executable,
        List<String> arguments,
        Duration timeout,
      ) async {
        if (executable == 'xcui-runner') {
          expect(
            arguments,
            containsAll(<String>['--operation', 'capabilities']),
          );
          return PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: jsonEncode(<String, Object?>{
              'deviceId': 'physical-device',
              'applicationId': 'com.example.consumer.debug',
              'capabilities': <String, Object?>{
                'camera': <String, Object?>{
                  'actions': <String>['reset', 'exercise'],
                  'decisions': <String>['allow', 'deny'],
                },
                'microphone': <String, Object?>{
                  'actions': <String>['reset', 'exercise'],
                  'decisions': <String>['allow', 'deny'],
                },
                'locationWhenInUse': <String, Object?>{
                  'actions': <String>['reset', 'exercise'],
                  'decisions': <String>['allow', 'deny', 'allowOnce'],
                },
                'notifications': <String, Object?>{
                  'actions': <String>['exercise'],
                  'decisions': <String>['allow', 'deny'],
                },
              },
            }),
            stderr: '',
          );
        }
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
          await PatchbayIosPermissionAdapter(
            xcuiTestRunner: 'xcui-runner',
            runCommand: command,
          ).handle(
            _request(
              PatchbayPermissionOperation.capabilities,
              deviceId: 'physical-device',
            ),
          );

      expect(response.accepted, isTrue);
      final Map<String, PatchbayPermissionCapability> permissions =
          response.capabilities!.permissions;
      expect(
        permissions['camera']!.actions,
        containsAll(<PatchbayPermissionAction>{
          PatchbayPermissionAction.reset,
          PatchbayPermissionAction.exercise,
        }),
      );
      expect(
        permissions['locationWhenInUse']!.decisions,
        contains(PatchbayPermissionDecision.allowOnce),
      );
      expect(
        permissions['notifications']!.actions,
        isNot(contains(PatchbayPermissionAction.reset)),
      );
      expect(
        permissions['notifications']!.decisions,
        isNot(contains(PatchbayPermissionDecision.allowOnce)),
      );
    },
  );

  test('iOS physical-device reset and exercise use XCUITest facts', () async {
    Future<PatchbayPlatformCommandResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) async {
      if (executable == 'xcui-runner') {
        final String operation =
            arguments[arguments.indexOf('--operation') + 1];
        if (operation == 'capabilities') {
          return PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: jsonEncode(<String, Object?>{
              'deviceId': 'physical-device',
              'applicationId': 'com.example.consumer.debug',
              'capabilities': <String, Object?>{
                'camera': <String, Object?>{
                  'actions': <String>['reset', 'exercise'],
                  'decisions': <String>['allow', 'deny'],
                },
              },
            }),
            stderr: '',
          );
        }
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout: jsonEncode(<String, Object?>{
            'deviceId': 'physical-device',
            'applicationId': 'com.example.consumer.debug',
            'permission': 'camera',
            if (operation == 'exercise') 'decision': 'allow',
            'handled': true,
            'state': operation == 'reset' ? 'notDetermined' : 'granted',
            'platformState': operation == 'reset'
                ? 'xctestReset'
                : 'allowedButtonObserved',
            'factSource': operation == 'reset'
                ? 'deviceReported'
                : 'uiObserved',
          }),
          stderr: '',
        );
      }
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

    final PatchbayIosPermissionAdapter adapter = PatchbayIosPermissionAdapter(
      xcuiTestRunner: 'xcui-runner',
      runCommand: command,
    );
    final PatchbayPermissionDriverResponse reset = await adapter.handle(
      _request(PatchbayPermissionOperation.reset, deviceId: 'physical-device'),
    );
    expect(reset.accepted, isTrue);
    expect(reset.after?.state, PatchbayPermissionState.notDetermined);
    expect(
      reset.after?.factSource,
      PatchbayPermissionFactSource.deviceReported,
    );

    final PatchbayPermissionDriverResponse exercise = await adapter.handle(
      _request(
        PatchbayPermissionOperation.exercise,
        decision: PatchbayPermissionDecision.allow,
        deviceId: 'physical-device',
      ),
    );
    expect(exercise.accepted, isTrue);
    expect(exercise.after?.state, PatchbayPermissionState.granted);
    expect(exercise.after?.factSource, PatchbayPermissionFactSource.uiObserved);
    expect(exercise.interruption?.handled, isTrue);
  });

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
