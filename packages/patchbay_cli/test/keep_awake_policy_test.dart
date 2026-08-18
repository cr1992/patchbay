import 'dart:convert';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

void main() {
  test('policy is default-off and --no override beats local default', () {
    expect(
      PatchbayKeepAwakePolicy.resolve(
        commandLine: null,
        environment: const <String, String>{},
      ).enabled,
      isFalse,
    );
    expect(
      PatchbayKeepAwakePolicy.resolve(
        commandLine: null,
        environment: const <String, String>{
          patchbayKeepAwakeEnvironmentKey: 'true',
        },
      ).enabled,
      isTrue,
    );
    expect(
      PatchbayKeepAwakePolicy.resolve(
        commandLine: false,
        environment: const <String, String>{
          patchbayKeepAwakeEnvironmentKey: 'true',
        },
      ).enabled,
      isFalse,
    );
  });

  test(
    'invalid local default is a usage error only when policy is used',
    () async {
      final Map<String, String> invalidEnvironment = <String, String>{
        patchbayKeepAwakeEnvironmentKey: 'sometimes',
      };
      final StringBuffer helpOutput = StringBuffer();

      expect(
        await runPatchbayCli(
          const <String>['--help'],
          output: helpOutput,
          errorOutput: StringBuffer(),
          environment: invalidEnvironment,
        ),
        PatchbayExitCode.accepted,
      );
      expect(helpOutput, isNotEmpty);

      expect(
        await runPatchbayCli(
          const <String>['identity'],
          connect: (_) async => _client(),
          output: StringBuffer(),
          errorOutput: StringBuffer(),
          environment: invalidEnvironment,
        ),
        PatchbayExitCode.usage,
      );
    },
  );

  test('successful one-shot command renews configured local lease', () async {
    final FakePatchbayClient client = _client();
    final StringBuffer output = StringBuffer();

    final int exitCode = await runPatchbayCli(
      const <String>['--json', '--keep-awake', 'identity'],
      connect: (_) async => client,
      output: output,
      errorOutput: StringBuffer(),
      environment: const <String, String>{},
    );

    expect(exitCode, PatchbayExitCode.accepted);
    expect(client.calls, hasLength(1));
    expect(client.calls.single.command, 'ui.keepAwake.set');
    expect(client.calls.single.arguments, <String, Object?>{
      'enabled': true,
      'leaseMs': patchbayKeepAwakeDefaultLease.inMilliseconds,
    });
    final Map<String, Object?> result =
        jsonDecode(output.toString()) as Map<String, Object?>;
    expect(
      (result['localKeepAwake'] as Map<String, Object?>)['state'],
      'renewed',
    );
  });

  test('--no-keep-awake suppresses an enabled local default', () async {
    final FakePatchbayClient client = _client();

    final int exitCode = await runPatchbayCli(
      const <String>['--json', '--no-keep-awake', 'identity'],
      connect: (_) async => client,
      output: StringBuffer(),
      errorOutput: StringBuffer(),
      environment: const <String, String>{
        patchbayKeepAwakeEnvironmentKey: 'true',
      },
    );

    expect(exitCode, PatchbayExitCode.accepted);
    expect(client.calls, isEmpty);
  });

  test('status read never becomes an implicit renewal', () async {
    final FakePatchbayClient client = _client(
      commands: const <Map<String, Object?>>[
        <String, Object?>{'name': 'ui.keepAwake.status'},
      ],
    );

    final int exitCode = await runPatchbayCli(
      const <String>['--json', '--keep-awake', 'ui', 'keep-awake', 'status'],
      connect: (_) async => client,
      output: StringBuffer(),
      errorOutput: StringBuffer(),
      environment: const <String, String>{},
    );

    expect(exitCode, PatchbayExitCode.accepted);
    expect(client.calls.map((call) => call.command), <String>[
      'ui.keepAwake.status',
    ]);
  });

  test(
    'stable set service identity excludes both friendly spellings',
    () async {
      for (final String operation in <String>['on', 'off']) {
        final FakePatchbayClient client = _client(
          commands: const <Map<String, Object?>>[
            <String, Object?>{'name': 'ui.keepAwake.set'},
          ],
        );

        final int exitCode = await runPatchbayCli(
          <String>['--json', '--keep-awake', 'ui', 'keep-awake', operation],
          connect: (_) async => client,
          output: StringBuffer(),
          errorOutput: StringBuffer(),
          environment: const <String, String>{},
        );

        expect(exitCode, PatchbayExitCode.accepted, reason: operation);
        expect(client.calls.map((call) => call.command), <String>[
          'ui.keepAwake.set',
        ], reason: operation);
      }
    },
  );

  test('rejected command does not renew the local lease', () async {
    final FakePatchbayClient client = FakePatchbayClient(
      commands: const <Map<String, Object?>>[
        <String, Object?>{'name': 'debug.reject'},
      ],
      handle: (_, _) async => fakeCommandNotRegistered(),
    );

    final int exitCode = await runPatchbayCli(
      const <String>['--json', '--keep-awake', 'exec', 'debug.reject'],
      connect: (_) async => client,
      output: StringBuffer(),
      errorOutput: StringBuffer(),
      environment: const <String, String>{},
    );

    expect(exitCode, PatchbayExitCode.protocol);
    expect(client.calls.map((call) => call.command), <String>['debug.reject']);
  });

  test('failed renewal is machine-visible and changes the CLI exit', () async {
    final FakePatchbayClient client = FakePatchbayClient(
      commands: const <Map<String, Object?>>[],
      handle: (_, _) async => fakeCommandNotRegistered(),
    );
    final StringBuffer output = StringBuffer();

    final int exitCode = await runPatchbayCli(
      const <String>['--json', '--keep-awake', 'identity'],
      connect: (_) async => client,
      output: output,
      errorOutput: StringBuffer(),
      environment: const <String, String>{},
    );

    expect(exitCode, PatchbayExitCode.typedFailure);
    final Map<String, Object?> result =
        jsonDecode(output.toString()) as Map<String, Object?>;
    expect(
      (result['localKeepAwake'] as Map<String, Object?>)['reasonCode'],
      'commandNotRegistered',
    );
  });

  test('failed renewal is also explicit in human output', () async {
    final FakePatchbayClient client = FakePatchbayClient(
      commands: const <Map<String, Object?>>[],
      handle: (_, _) async => fakeCommandNotRegistered(),
    );
    final StringBuffer output = StringBuffer();

    final int exitCode = await runPatchbayCli(
      const <String>['--keep-awake', 'identity'],
      connect: (_) async => client,
      output: output,
      errorOutput: StringBuffer(),
      environment: const <String, String>{},
    );

    expect(exitCode, PatchbayExitCode.typedFailure);
    expect(output.toString(), contains('keepAwake=renewalRejected'));
    expect(output.toString(), contains('reason=commandNotRegistered'));
  });
}

FakePatchbayClient _client({
  List<Map<String, Object?>> commands = const <Map<String, Object?>>[],
}) => FakePatchbayClient(
  commands: commands,
  handle: (String command, Map<String, Object?> arguments) async {
    if (command == 'ui.keepAwake.status') {
      return fakeAccepted(const <String, Object?>{
        'outcome': 'observed',
        'wired': true,
      });
    }
    return fakeAccepted(const <String, Object?>{
      'outcome': 'renewed',
      'enabled': true,
    });
  },
);
