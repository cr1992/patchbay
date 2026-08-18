import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

String _quoted(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _driver(String mode) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-permission-driver-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final String fixture = File(
    'test/fixture/fake_permission_driver.dart',
  ).absolute.path;
  final File wrapper = File('${directory.path}/driver');
  final String stateFile = '${directory.path}/state';
  wrapper.writeAsStringSync(
    '#!/bin/sh\nFAKE_PERMISSION_MODE=${_quoted(mode)} '
    'FAKE_PERMISSION_STATE_FILE=${_quoted(stateFile)} exec '
    '${_quoted(Platform.resolvedExecutable)} ${_quoted(fixture)}\n',
  );
  Process.runSync('chmod', <String>['700', wrapper.path]);
  return wrapper.path;
}

PatchbayPermissionDriverRequest _request(
  PatchbayPermissionOperation operation, {
  String permission = 'camera',
}) => PatchbayPermissionDriverRequest(
  requestId: 'fixture-request',
  operation: operation,
  permission: permission,
  timeoutMs: 1000,
);

PatchbayPermissionCommandRunner _commandRunner(String driver) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-permission-session-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final PatchbaySessionStore store = PatchbaySessionStore(directory.path);
  store.write(
    PatchbaySessionRecord(
      sessionId: 'fixture-session',
      applicationId: 'dev.patchbay.fixture',
      appInstanceId: 'fixture-instance',
      isolateId: 'fixture-isolate',
      processId: pid,
      wsUri: 'ws://127.0.0.1:1/token/ws',
      buildMode: 'debug',
      createdAt: DateTime.now().toUtc(),
      workspacePath: Directory.current.path,
      deviceId: 'fixture-device',
    ),
  );
  return PatchbayPermissionCommandRunner(
    discovery: PatchbayPermissionDriverDiscovery(
      environment: <String, String>{
        patchbayPermissionDriverEnvironment: driver,
      },
    ),
    sessions: PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      identityProbe: (_) async => const PatchbayRuntimeIdentity(
        schemaVersion: 1,
        applicationId: 'dev.patchbay.fixture',
        appInstanceId: 'fixture-instance',
        isolateId: 'fixture-isolate',
      ),
    ),
  );
}

Future<Map<String, Object?>> _runCli(
  List<String> arguments, {
  PatchbayPermissionCommandRunner? runner,
  int expectedExit = PatchbayExitCode.accepted,
}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    arguments,
    output: out,
    errorOutput: err,
    permissionCommands: runner,
  );
  expect(exitCode, expectedExit, reason: err.toString());
  return Map<String, Object?>.from(jsonDecode(out.toString()) as Map);
}

void main() {
  test('protocol major mismatch fails before an operation', () async {
    final PatchbayPermissionDriverClient client =
        PatchbayPermissionDriverClient(executable: _driver('major-mismatch'));
    await expectLater(
      client.call(
        _request(PatchbayPermissionOperation.capabilities),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<PatchbayPermissionDriverException>().having(
          (PatchbayPermissionDriverException error) => error.code,
          'code',
          'platformDriverVersionMismatch',
        ),
      ),
    );
  });

  test(
    'unknown state remains closed and unsupported permission is typed',
    () async {
      final PatchbayPermissionDriverRunner unknown =
          PatchbayPermissionDriverRunner(
            PatchbayPermissionDriverClient(
              executable: _driver('unknown-state'),
            ),
          );
      final PatchbayPermissionDriverResponse response = await unknown.run(
        _request(PatchbayPermissionOperation.status),
        timeout: const Duration(seconds: 3),
      );
      expect(response.after?.state, PatchbayPermissionState.unknown);
      expect(response.after?.platformState, 'vendorFutureState');

      await expectLater(
        unknown.run(
          _request(
            PatchbayPermissionOperation.status,
            permission: 'not-supported',
          ),
          timeout: const Duration(seconds: 3),
        ),
        throwsA(
          isA<PatchbayPermissionDriverException>().having(
            (PatchbayPermissionDriverException error) => error.code,
            'code',
            'permissionUnsupported',
          ),
        ),
      );
    },
  );

  test('one total timeout budget terminates a slow driver', () async {
    final PatchbayPermissionDriverClient client =
        PatchbayPermissionDriverClient(executable: _driver('timeout'));
    await expectLater(
      client.call(
        _request(PatchbayPermissionOperation.capabilities),
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(
        isA<PatchbayPermissionDriverException>().having(
          (PatchbayPermissionDriverException error) => error.code,
          'code',
          'budgetExceeded',
        ),
      ),
    );
  });

  test(
    'CLI fake driver closes capabilities/normalize/exercise/fail loop',
    () async {
      final String driver = _driver('normal');
      final Map<String, Object?> capabilities = await _runCli(<String>[
        '--json',
        '--permission-driver',
        driver,
        'permission',
        'capabilities',
      ]);
      expect(capabilities['admission'], 'accepted');
      expect(capabilities['capabilities'], isA<Map>());

      for (final List<String> command in <List<String>>[
        <String>['permission', 'normalize', 'camera', '--state', 'granted'],
        <String>['permission', 'exercise', 'camera', '--decision', 'deny'],
        <String>['permission', 'fail', 'camera', '--state', 'granted'],
      ]) {
        final String commandDriver = _driver('normal');
        final Map<String, Object?> response = await _runCli(<String>[
          '--json',
          '--permission-driver',
          commandDriver,
          ...command,
        ], runner: _commandRunner(commandDriver));
        expect(response['admission'], 'accepted', reason: command.join(' '));
      }
    },
  );

  test(
    'exercise allow without explicit confirmation rejects before driver',
    () async {
      final Map<String, Object?> response = await _runCli(<String>[
        '--json',
        '--permission-driver',
        _driver('normal'),
        'permission',
        'exercise',
        'camera',
        '--decision',
        'allow',
      ], expectedExit: PatchbayExitCode.usage);
      expect((response['error']! as Map)['code'], 'usageError');
    },
  );
}
