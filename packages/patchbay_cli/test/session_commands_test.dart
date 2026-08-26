import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/output/local_artifact.dart';
import 'package:test/test.dart';

/// The URI path segment a VM Service record carries as its auth token.
///
/// Every assertion about masking greps for this string: it is the one part of
/// a record that must never reach stdout, and the tests below print records on
/// both the human and the `--json` channel.
const String _token = 'SeCrEtToKeN';

final class _Run {
  const _Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  Map<String, Object?> get document => jsonDecode(out) as Map<String, Object?>;
}

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-session-cli-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Runs one CLI invocation against this test's session directory.
  ///
  /// The `connect` seam fails the test if it is ever called: these commands
  /// answer questions the operator asks *because* no session can be selected,
  /// so needing a connection first would defeat them.
  Future<_Run> run(List<String> arguments) async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int exitCode = await runPatchbayCli(
      <String>['--session-dir', directory.path, ...arguments],
      connect: (_) async =>
          fail('a session-directory command must not dial the App'),
      output: out,
      errorOutput: err,
    );
    return _Run(exitCode, out.toString(), err.toString());
  }

  test('an empty directory lists nothing instead of failing', () async {
    final _Run result = await run(<String>['sessions', 'list']);

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.out.trim(), 'no session records');
  });

  test('a listing shows the records and masks the token', () async {
    store.write(_record('worktree-a', deviceId: 'emulator-5554'));
    store.write(
      _record('worktree-b', deviceId: 'ios-device', workspacePath: '/repo/b'),
    );

    final _Run text = await run(<String>['sessions', 'list']);
    final _Run json = await run(<String>['--json', 'sessions', 'list']);

    for (final _Run result in <_Run>[text, json]) {
      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.out, contains('worktree-a'));
      expect(result.out, contains('worktree-b'));
      expect(result.out, contains('ws://127.0.0.1:1234'));
      expect(result.out, isNot(contains(_token)));
    }
    // Two records and nothing pinned is exactly the state `session use` fixes,
    // so the listing says so rather than leaving it to be discovered.
    expect(text.out, contains('session use'));
    expect(text.out, contains('emulator-5554'));
    expect(json.document['selected'], isNull);
    expect((json.document['sessions']! as List<Object?>).length, 2);
  });

  test('use pins a session and the listing marks it', () async {
    store.write(_record('worktree-a'));
    store.write(_record('worktree-b', workspacePath: '/repo/b'));

    final _Run pinned = await run(<String>['session', 'use', 'worktree-b']);
    expect(pinned.exitCode, PatchbayExitCode.accepted);
    expect(pinned.out, contains('worktree-b'));
    expect(pinned.out, isNot(contains(_token)));

    final _Run listed = await run(<String>['--json', 'sessions', 'list']);
    expect(listed.document['selected'], 'worktree-b');
    final _Run text = await run(<String>['sessions', 'list']);
    expect(text.out, contains('* worktree-b'));
    // A pinned session answers the ambiguity, so the hint retires.
    expect(text.out, isNot(contains('session use')));
  });

  test('use --clear unpins and says whether anything was pinned', () async {
    store.write(_record('worktree-a'));
    await run(<String>['session', 'use', 'worktree-a']);

    final _Run cleared = await run(<String>['session', 'use', '--clear']);
    expect(cleared.exitCode, PatchbayExitCode.accepted);
    expect(cleared.out, contains('worktree-a'));
    expect(store.readSelection(), isNull);

    final _Run again = await run(<String>['session', 'use', '--clear']);
    expect(again.out.trim(), 'no session was pinned');
  });

  test('use refuses an unknown session with a stable code', () async {
    store.write(_record('worktree-a'));

    final _Run result = await run(<String>[
      '--json',
      'session',
      'use',
      'worktree-z',
    ]);

    expect(result.exitCode, PatchbayExitCode.transport);
    expect(
      ((result.document['error']! as Map<String, Object?>)['code']),
      'sessionNotFound',
    );
    expect(result.err, contains('sessionNotFound'));
    expect(store.readSelection(), isNull);
  });

  test('prune reports what it removed', () async {
    store.write(_record('alive', processId: pid));
    store.write(_record('dead', processId: 4243, workspacePath: '/repo/b'));

    final _Run result = await run(<String>['--json', 'sessions', 'prune']);

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.document['pruned'], <String>['dead']);
    expect((result.document['sessions']! as List<Object?>).length, 1);
    expect(store.readAll().single.sessionId, 'alive');
  });

  test('a session-directory command refuses transport options', () async {
    store.write(_record('worktree-a'));

    for (final List<String> arguments in <List<String>>[
      <String>['--ws-uri', 'ws://127.0.0.1:1/ws', 'sessions', 'list'],
      <String>['--session', 'worktree-a', 'sessions', 'list'],
    ]) {
      final _Run result = await run(arguments);
      expect(result.exitCode, PatchbayExitCode.usage, reason: '$arguments');
      expect(result.err, contains('does not apply'), reason: '$arguments');
    }
  });

  test('session use takes an id or --clear, never both or neither', () async {
    store.write(_record('worktree-a'));

    for (final List<String> arguments in <List<String>>[
      <String>['session', 'use'],
      <String>['session', 'use', 'worktree-a', '--clear'],
      <String>['session', 'use', 'worktree-a', 'worktree-b'],
    ]) {
      final _Run result = await run(arguments);
      expect(result.exitCode, PatchbayExitCode.usage, reason: '$arguments');
    }
    expect(store.readSelection(), isNull);
  });

  test('--clear belongs to session use alone', () {
    final parsed = patchbayCliParser().parse(<String>['--clear', 'catalog']);

    expect(
      () => PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed),
      throwsA(isA<FormatException>()),
    );
  });

  test('either spelling of the group reaches the declared path', () {
    for (final (List<String> typed, PatchbayFriendlyCommand expected)
        in <(List<String>, PatchbayFriendlyCommand)>[
          (<String>['sessions', 'list'], PatchbayFriendlyCommand.sessionsList),
          (<String>['session', 'list'], PatchbayFriendlyCommand.sessionsList),
          (
            <String>['sessions', 'prune'],
            PatchbayFriendlyCommand.sessionsPrune,
          ),
          (<String>['session', 'prune'], PatchbayFriendlyCommand.sessionsPrune),
          (<String>['session', 'use', 'a'], PatchbayFriendlyCommand.sessionUse),
          (
            <String>['sessions', 'use', 'a'],
            PatchbayFriendlyCommand.sessionUse,
          ),
        ]) {
      expect(
        PatchbayFriendlyCommandRegistry.specFor(typed),
        expected,
        reason: typed.join(' '),
      );
    }
  });

  test('a repl refuses session-directory commands', () async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int exitCode = await PatchbayReplSession(
      parser: patchbayCliParser(),
      execute: (_) async => fail('the repl must not dispatch this line'),
      out: out,
      err: err,
      json: false,
      outputWriter: PatchbayLocalArtifactWriter(),
    ).run(Stream<String>.fromIterable(<String>['sessions list']));

    expect(exitCode, PatchbayExitCode.accepted);
    expect(out.toString(), contains('exit=${PatchbayExitCode.usage}'));
    expect(err.toString(), contains('unavailable inside a repl session'));
  });
}

PatchbaySessionRecord _record(
  String id, {
  int? processId,
  String workspacePath = '/repo/a',
  String deviceId = 'device-1',
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: null,
  isolateId: null,
  // The current process is the only PID a test can be sure is alive.
  processId: processId ?? pid,
  wsUri: 'ws://127.0.0.1:1234/$_token=/ws',
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 14),
  workspacePath: workspacePath,
  deviceId: deviceId,
);
