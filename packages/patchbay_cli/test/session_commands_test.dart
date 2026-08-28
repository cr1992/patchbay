import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/command_registry.dart';
import 'package:patchbay_cli/src/commands/command_parser.dart';
import 'package:patchbay_cli/src/output/local_artifact.dart';
import 'package:patchbay_cli/src/repl.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_resolver.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
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
    final int exitCode = await runPatchbayCliWithSeams(
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
    store.write(_record('worktree-b', deviceId: 'ios-device'));

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

  test('a foreign record is listed but never offered as a choice', () async {
    store.write(_record('worktree-a'));
    store.write(
      _record('elsewhere', deviceId: 'ios-device').withWorkspace(_elsewhere),
    );

    final _Run text = await run(<String>['sessions', 'list']);
    final _Run json = await run(<String>['--json', 'sessions', 'list']);

    // The inventory stays machine-wide -- that is what makes an explicit
    // cross-checkout --session usable -- but only one of these is selectable
    // here, so the "pin one of them" hint must not appear.
    expect(text.out, contains('elsewhere'));
    expect(text.out, isNot(contains('session use')));
    expect(text.out, contains('affinity=current'));
    expect(text.out, contains('affinity=foreign'));
    expect(json.document['selected'], isNull);

    // And pinning it is refused with the code that names the way across.
    final _Run pinned = await run(<String>[
      '--json',
      'session',
      'use',
      'elsewhere',
    ]);
    expect(
      (pinned.document['error']! as Map<String, Object?>)['code'],
      'sessionWorkspaceMismatch',
    );
    expect(store.readSelectionFor(_workspace), isNull);
  });

  test('use pins a session and the listing marks it', () async {
    store.write(_record('worktree-a'));
    store.write(_record('worktree-b'));

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
    expect(store.readSelectionFor(_workspace), isNull);

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
    expect(store.readSelectionFor(_workspace), isNull);
  });

  test('prune reports what it removed', () async {
    store.write(_record('alive', processId: pid));
    store.write(_record('dead', processId: 4243));

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
    expect(store.readSelectionFor(_workspace), isNull);
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
          (
            <String>['session', 'register'],
            PatchbayFriendlyCommand.sessionRegister,
          ),
          (
            <String>['sessions', 'register'],
            PatchbayFriendlyCommand.sessionRegister,
          ),
          (
            <String>['session', 'unregister', 'a'],
            PatchbayFriendlyCommand.sessionUnregister,
          ),
          (
            <String>['sessions', 'unregister', 'a'],
            PatchbayFriendlyCommand.sessionUnregister,
          ),
        ]) {
      expect(
        PatchbayFriendlyCommandRegistry.specFor(typed),
        expected,
        reason: typed.join(' '),
      );
    }
  });

  group('register / unregister an externally launched session (PB-050-27)', () {
    /// The `session register` line a consumer script would run.
    List<String> registerArguments({
      String? sessionId,
      String wsUri = 'ws://127.0.0.1:1234/$_token=/ws',
      String applicationId = 'dev.patchbay.fixture',
      String? buildMode,
    }) => <String>[
      '--json',
      'session',
      'register',
      '--ws-uri',
      wsUri,
      '--application-id',
      applicationId,
      '--device-id',
      'emulator-5554',
      '--process-id',
      '$pid',
      if (buildMode != null) ...<String>['--build-mode', buildMode],
      if (sessionId != null) sessionId,
    ];

    test('a registered record is discoverable here without --ws-uri', () async {
      final _Run registered = await run(registerArguments());

      expect(registered.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> session =
          registered.document['session']! as Map<String, Object?>;
      // Affinity, not just presence: PB-050-14 is what makes this record
      // implicitly selectable *here* and invisible to another checkout, which
      // is the whole reason DG-050-07 routed this need through the CLI instead
      // of freezing the store as an SDK.
      expect(session['workspaceAffinity'], 'current');
      expect(session['status'], 'live');
      expect(session['endpoint'], 'ws://127.0.0.1:1234');
      expect(registered.out, isNot(contains(_token)));

      final PatchbaySessionRecord written = store.readAll().single;
      expect(written.workspaceId, _workspace.workspaceId);
      expect(written.wsUri, contains(_token));

      // And implicit selection actually lands on it: no --session, no --ws-uri.
      final PatchbayDiscoveredSession resolved = await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => const PatchbayRuntimeIdentity(
          schemaVersion: 1,
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: 'instance-1',
          isolateId: 'isolates/1',
        ),
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
      ).resolve();
      expect(resolved.record.sessionId, written.sessionId);
    });

    test('the record reuses the pending shape and adds no field', () async {
      await run(registerArguments(sessionId: 'external-one'));

      final Map<String, Object?> stored =
          jsonDecode(
                File(
                  '${directory.path}${Platform.pathSeparator}'
                  'external-one.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      // Every key a launcher-declared record can carry, and not one more.
      expect(
        stored.keys.toSet().difference(_everyRecordKey),
        isEmpty,
        reason: 'PB-050-27 must not add a session record field',
      );
      expect(stored['schemaVersion'], patchbaySessionSchemaVersion);
      // Pending is the writer's own claim: this process is not the App, so it
      // does not get to say `live`. A completed handshake promotes it.
      expect(stored['state'], PatchbaySessionStatus.pending.name);
      // The App has not been asked anything yet.
      expect(stored['appInstanceId'], isNull);
      expect(stored['isolateId'], isNull);
      // The pending TTL bounds "declared, transport unknown"; this record was
      // born with its transport, so it must not expire out from under a
      // long-running session.
      expect(stored.containsKey('expiresAtMs'), isFalse);
      // Not launcher-supervised: no launch owns it, and none may claim it.
      expect(stored.containsKey('launchId'), isFalse);
      expect(stored.containsKey('ownerPid'), isFalse);
      // Still readable as an ordinary record by the ordinary reader.
      expect(PatchbaySessionRecord.fromJson(stored).sessionId, 'external-one');
    });

    test('--build-mode is recorded and defaults to debug', () async {
      await run(registerArguments(sessionId: 'a'));
      await run(registerArguments(sessionId: 'b', buildMode: 'profile'));

      final Map<String, String> modes = <String, String>{
        for (final PatchbaySessionRecord record in store.readAll())
          record.sessionId: record.buildMode,
      };
      expect(modes, <String, String>{'a': 'debug', 'b': 'profile'});
    });

    test('an id already on disk is refused, not overwritten', () async {
      store.write(_record('worktree-a'));

      final _Run again = await run(
        registerArguments(
          sessionId: 'worktree-a',
          applicationId: 'dev.patchbay.other',
        ),
      );

      expect(
        (again.document['error']! as Map<String, Object?>)['code'],
        'sessionAlreadyRegistered',
      );
      expect(store.readAll().single.applicationId, 'dev.patchbay.fixture');
    });

    test('unregister removes the record and the pin naming it', () async {
      await run(registerArguments(sessionId: 'external-one'));
      final _Run pinned = await run(<String>['session', 'use', 'external-one']);
      expect(pinned.exitCode, PatchbayExitCode.accepted);
      expect(store.readSelectionFor(_workspace), 'external-one');

      final _Run removed = await run(<String>[
        '--json',
        'session',
        'unregister',
        'external-one',
      ]);

      expect(removed.exitCode, PatchbayExitCode.accepted);
      expect(removed.document['removed'], isTrue);
      expect(store.readAll(), isEmpty);
      expect(store.readSelectionFor(_workspace), isNull);
    });

    test('unregistering what is already gone is a reported no-op', () async {
      // A cleanup trap runs after `sessions prune` may already have removed a
      // dead record. Failing there would report a problem for doing its job.
      final _Run removed = await run(<String>[
        '--json',
        'session',
        'unregister',
        'never-existed',
      ]);

      expect(removed.exitCode, PatchbayExitCode.accepted);
      expect(removed.document['removed'], isFalse);
      expect(removed.document['sessionId'], 'never-existed');
    });

    test('register refuses the shapes that would mean dialling', () async {
      for (final (List<String>, String) invalid in <(List<String>, String)>[
        (
          <String>['session', 'register', '--application-id', 'a'],
          '--ws-uri is required',
        ),
        (
          <String>[...registerArguments(), '--session', 'worktree-a'],
          '--ws-uri and --session are mutually exclusive',
        ),
        (
          <String>[
            'session',
            'register',
            '--ws-uri',
            'not-a-uri',
            '--application-id',
            'a',
            '--device-id',
            'd',
            '--process-id',
            '1',
          ],
          '--ws-uri must be an absolute http(s) or ws(s) URI',
        ),
        (
          <String>[
            'session',
            'register',
            '--ws-uri',
            'ws://127.0.0.1:1/ws',
            '--application-id',
            'a',
            '--device-id',
            'd',
            '--process-id',
            'zero',
          ],
          '--process-id must be a positive integer',
        ),
        (
          <String>[...registerArguments(), 'one', 'two'],
          'session register accepts at most one <session-id>',
        ),
      ]) {
        final _Run result = await run(invalid.$1);
        expect(result.exitCode, PatchbayExitCode.usage, reason: invalid.$2);
        expect(result.err, contains(invalid.$2));
        expect(store.readAll(), isEmpty);
      }
    });
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

/// Every key a `PatchbaySessionRecord` can serialise, taken from a maximally
/// populated launcher-declared record rather than from a hand-written list, so
/// the PB-050-27 "adds no record field" assertion cannot go stale against the
/// model it is guarding.
final Set<String> _everyRecordKey = PatchbaySessionRecord(
  sessionId: 'fixture',
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: 'instance-1',
  isolateId: 'isolates/1',
  processId: 4242,
  wsUri: 'ws://127.0.0.1:1/ws',
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 14),
  workspacePath: _workspace.canonicalRoot,
  deviceId: 'device-1',
  state: PatchbaySessionStatus.pending,
  ownerPid: 4242,
  launchId: 'launch-fixture',
  observedAtMs: 0,
  expiresAtMs: 1,
  processStartTime: 'launch-signature',
).withWorkspace(_workspace).toJson().keys.toSet();

/// The checkout this test process is actually running in.
///
/// These tests drive the real CLI, so the records have to belong to the
/// workspace the CLI's own identity probe will report -- that *is* the
/// contract under test on the `sessions`/`session use` side.
final PatchbayWorkspaceIdentity _workspace =
    PatchbayWorkspaceIdentity.current()!;

/// Some other checkout on the same machine.
final PatchbayWorkspaceIdentity _elsewhere = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '${_workspace.canonicalRoot}-elsewhere',
)!;

PatchbaySessionRecord _record(
  String id, {
  int? processId,
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
  workspacePath: _workspace.canonicalRoot,
  deviceId: deviceId,
).withWorkspace(_workspace);
