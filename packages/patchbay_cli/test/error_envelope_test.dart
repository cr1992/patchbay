import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

final class _Run {
  const _Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  /// The single JSON document `--json` promises on stdout.
  Map<String, Object?> get document =>
      jsonDecode(out) as Map<String, Object?>;

  Map<String, Object?> get error =>
      document['error']! as Map<String, Object?>;

  Map<String, Object?> get details =>
      error['details']! as Map<String, Object?>;
}

FakePatchbayClient _client() => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    <String, Object?>{'name': 'logs.export'},
  ],
  handle: (String command, Map<String, Object?> arguments) async =>
      fakeCommandNotRegistered(),
);

Future<_Run> _run(
  List<String> arguments, {
  FakePatchbayClient? client,
  bool connected = true,
}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    arguments,
    connect: connected ? (_) async => client ?? _client() : null,
    output: out,
    errorOutput: err,
  );
  return _Run(exitCode, out.toString(), err.toString());
}

void main() {
  test('a usage error reaches stdout as JSON when --json is asked for', () async {
    final _Run result = await _run(<String>['--json', 'identity', 'unexpected']);

    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.document.keys, <String>['error']);
    expect(result.error['code'], 'usageError');
    expect(result.details['message'], contains('unexpected argument'));
    // The sentence stays where operators already read it.
    expect(result.err, contains('unexpected argument'));
  });

  test('logs export without --output is a JSON error, not only prose', () async {
    final _Run result = await _run(<String>['--json', 'logs', 'export']);

    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.error['code'], 'usageError');
    expect(result.details['message'], contains('--output is required'));
  });

  test('an argv parse failure is JSON too, before any ArgResults exists', () async {
    final _Run result = await _run(<String>[
      '--json',
      '--not-a-real-option',
    ], connected: false);

    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.error['code'], 'usageError');
    expect(result.details['message'], contains('not-a-real-option'));
  });

  test('sessionAmbiguous lists its choices in the JSON envelope', () async {
    final Directory sessions = Directory.systemTemp.createTempSync(
      'patchbay-error-envelope-sessions-',
    );
    addTearDown(() => sessions.deleteSync(recursive: true));
    final PatchbaySessionStore store = PatchbaySessionStore(sessions.path);
    for (final String id in <String>['fixture-one', 'fixture-two']) {
      store.write(
        PatchbaySessionRecord(
          sessionId: id,
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: null,
          isolateId: null,
          // This test process is alive, so both records are live candidates
          // and neither can be picked without the operator saying which.
          processId: pid,
          wsUri: null,
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: Directory.current.path,
          deviceId: 'local-vm',
        ),
      );
    }

    final _Run result = await _run(<String>[
      '--session-dir',
      sessions.path,
      '--json',
      'identity',
    ], connected: false);

    expect(result.exitCode, PatchbayExitCode.transport);
    expect(result.error['code'], 'sessionAmbiguous');
    final List<Object?> choices = result.details['sessions']! as List<Object?>;
    expect(choices, hasLength(2));
    expect(choices.join(' '), contains('fixture-one'));
    expect(choices.join(' '), contains('fixture-two'));
    // Same rule as the printed list: a choice label never carries a URI.
    expect(result.out, isNot(contains('ws://')));
    expect(result.err, contains('--session fixture-one'));
  });

  test('a transport-class failure keeps its own stable code', () async {
    final _Run result = await _run(<String>['--json', 'ui', 'widget-tree']);

    expect(result.exitCode, PatchbayExitCode.protocol);
    expect(result.error['code'], 'flutterDiagnosticUnavailable');
    expect(result.error['details'], isEmpty);
  });

  test('without --json stdout stays empty and only stderr speaks', () async {
    final _Run result = await _run(<String>['logs', 'export']);

    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.out, isEmpty);
    expect(result.err, contains('--output is required'));
  });
}
