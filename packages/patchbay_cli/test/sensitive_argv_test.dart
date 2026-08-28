import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// Catalog with one command whose `token` parameter is declared sensitive.
FakePatchbayClient _client() => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    <String, Object?>{
      'name': 'fixture.command',
      'parameters': <Object?>[
        <String, Object?>{'name': 'token', 'type': 'string', 'sensitive': true},
        <String, Object?>{'name': 'deviceId', 'type': 'string'},
      ],
    },
  ],
  handle: (String command, Map<String, Object?> arguments) async =>
      fakeAccepted(<String, Object?>{
        'outcome': 'completed',
        'source': 'appRecorded',
        'arguments': arguments,
      }),
);

Future<({int exitCode, String out, String err, FakePatchbayClient client})>
_run(List<String> arguments) async {
  final FakePatchbayClient client = _client();
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (
    exitCode: exitCode,
    out: out.toString(),
    err: err.toString(),
    client: client,
  );
}

void main() {
  test(
    'a catalog-declared sensitive parameter may not travel in --args',
    () async {
      final result = await _run(<String>[
        '--args',
        '{"token":"s3cret"}',
        'exec',
        'fixture.command',
      ]);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('sensitive'));
      expect(result.err, contains('--stdin'));
      // Refused before the wire, not after: the secret must never leave the
      // process once it has already been recorded by the shell.
      expect(result.client.calls, isEmpty);
      // The message names the parameter but must not echo its value.
      expect(result.err, isNot(contains('s3cret')));
    },
  );

  test('ordinary parameters still travel in --args', () async {
    final result = await _run(<String>[
      '--args',
      '{"deviceId":"abc"}',
      'exec',
      'fixture.command',
    ]);

    expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
    expect(result.client.calls.single.command, 'fixture.command');
    expect(result.client.calls.single.arguments, <String, Object?>{
      'deviceId': 'abc',
    });
  });
}
