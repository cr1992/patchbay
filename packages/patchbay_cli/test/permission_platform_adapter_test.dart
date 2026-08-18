import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

PatchbayPermissionDriverRequest _request(
  PatchbayPermissionOperation operation, {
  String permission = 'camera',
}) => PatchbayPermissionDriverRequest(
  requestId: 'adapter-test',
  operation: operation,
  deviceId: 'device-1',
  applicationId: 'dev.moii.debug',
  sessionRef: const <String, Object?>{
    'sessionId': 'moii-session',
    'appInstanceId': 'moii-instance',
    'buildMode': 'debug',
  },
  permission: permission,
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
          stdout: 'package:/data/app/dev.moii.debug/base.apk\n',
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
          stdout: 'UIKitApplication:dev.moii.debug',
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
    'recovery reconnects, probes lifecycle and re-resolves current targets',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'patchbay-permission-recovery-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final PatchbaySessionStore store = PatchbaySessionStore(directory.path);
      final PatchbaySessionRecord record = PatchbaySessionRecord(
        sessionId: 'moii-session',
        applicationId: 'dev.moii.debug',
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
        applicationId: 'dev.moii.debug',
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
  applicationId: 'dev.moii.debug',
  appInstanceId: 'before-instance',
  isolateId: 'before-isolate',
);

final class _RecoveryClient implements PatchbayClient {
  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'dev.moii.debug',
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
