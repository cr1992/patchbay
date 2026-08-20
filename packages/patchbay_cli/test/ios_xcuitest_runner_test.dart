import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/ios_xcuitest_runner.dart';
import 'package:patchbay_cli/src/permission_platform_adapter.dart';
import 'package:test/test.dart';

void main() {
  test(
    'injects request facts into xctestrun and emits only runner JSON',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'patchbay-ios-xcuitest-test-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final File source = File('${directory.path}/source.xctestrun')
        ..writeAsStringSync('fixture');
      final StringBuffer output = StringBuffer();
      final StringBuffer error = StringBuffer();
      final Map<String, Object?> payload = <String, Object?>{
        'deviceId': 'physical-device',
        'applicationId': 'com.example.consumer.debug',
        'capabilities': <String, Object?>{},
      };

      Future<PatchbayPlatformCommandResult> command(
        String executable,
        List<String> arguments,
        Duration timeout,
      ) async {
        if (executable == '/usr/bin/plutil') {
          final String outputPath = arguments[arguments.indexOf('-o') + 1];
          if (arguments.contains('json')) {
            File(outputPath).writeAsStringSync(
              jsonEncode(<String, Object?>{
                'PatchbayPermissionUITests': <String, Object?>{
                  'TestBundlePath':
                      '__TESTHOST__/PlugIns/'
                      'PatchbayPermissionUITests.xctest',
                  'TestHostPath':
                      '__TESTROOT__/Debug-iphoneos/'
                      'PatchbayPermissionUITests-Runner.app',
                  'DependentProductPaths': <String>[
                    '__TESTROOT__/Debug-iphoneos/'
                        'PatchbayPermissionUITests-Runner.app',
                    '__TESTROOT__/Debug-iphoneos/Runner.app',
                  ],
                  'EnvironmentVariables': <String, Object?>{'TERM': 'dumb'},
                },
              }),
            );
          } else {
            final File input = File(arguments.last);
            File(outputPath).writeAsStringSync(input.readAsStringSync());
          }
          return const PatchbayPlatformCommandResult(
            exitCode: 0,
            stdout: '',
            stderr: '',
          );
        }
        expect(executable, 'fake-xcodebuild');
        final File request = File(
          arguments[arguments.indexOf('-xctestrun') + 1],
        );
        final Map<String, dynamic> configured = jsonDecode(
          request.readAsStringSync(),
        );
        final Map<String, dynamic> test =
            configured['PatchbayPermissionUITests'] as Map<String, dynamic>;
        final Map<String, dynamic> environment =
            test['EnvironmentVariables'] as Map<String, dynamic>;
        expect(
          test['TestHostPath'],
          '${directory.path}/Debug-iphoneos/'
          'PatchbayPermissionUITests-Runner.app',
        );
        expect(test['DependentProductPaths'], <String>[
          '${directory.path}/Debug-iphoneos/'
              'PatchbayPermissionUITests-Runner.app',
          '${directory.path}/Debug-iphoneos/Runner.app',
        ]);
        expect(environment['TERM'], 'dumb');
        expect(environment['PATCHBAY_OPERATION'], 'capabilities');
        expect(environment['PATCHBAY_DEVICE_ID'], 'physical-device');
        expect(
          environment['PATCHBAY_APPLICATION_ID'],
          'com.example.consumer.debug',
        );
        return PatchbayPlatformCommandResult(
          exitCode: 0,
          stdout:
              'PATCHBAY_RESULT=${base64Encode(utf8.encode(jsonEncode(payload)))}',
          stderr: '',
        );
      }

      final int exitCode = await runPatchbayIosXcuiTestRunner(
        const <String>[
          '--operation',
          'capabilities',
          '--device-id',
          'physical-device',
          '--application-id',
          'com.example.consumer.debug',
        ],
        environment: <String, String>{
          patchbayIosXctestrunEnvironment: source.path,
          patchbayXcodebuildEnvironment: 'fake-xcodebuild',
        },
        runCommand: command,
        output: output,
        errorOutput: error,
      );

      expect(exitCode, 0);
      expect(error.toString(), isEmpty);
      expect(jsonDecode(output.toString()), payload);
    },
  );

  test('rejects a missing signed xctestrun before invoking Xcode', () async {
    final StringBuffer error = StringBuffer();
    final int exitCode = await runPatchbayIosXcuiTestRunner(
      const <String>[
        '--operation',
        'capabilities',
        '--device-id',
        'physical-device',
        '--application-id',
        'com.example.consumer.debug',
      ],
      environment: const <String, String>{},
      errorOutput: error,
    );

    expect(exitCode, 69);
    expect(error.toString(), contains('platformSigningUnavailable'));
  });
}
