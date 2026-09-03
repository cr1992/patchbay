import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/rpc_timeout.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// The URI path segment a VM Service record carries as its auth token.
///
/// Doctor output is pasted into tickets and chat, so every assertion about a
/// session record greps for this string: it must not appear on either channel.
const String _token = 'SeCrEtToKeN';

/// The catalog row that makes the lifecycle probe possible.
const Map<String, Object?> _semanticsTreeRow = <String, Object?>{
  'name': 'ui.semantics.tree',
  'summary': 'Observe the current Flutter Semantics tree.',
};

final class _Run {
  const _Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  Map<String, Object?> get doctor =>
      (jsonDecode(out) as Map<String, Object?>)['doctor']!
          as Map<String, Object?>;

  List<Map<String, Object?>> get checks => <Map<String, Object?>>[
    for (final Object? check in doctor['checks']! as List<Object?>)
      check! as Map<String, Object?>,
  ];

  Map<String, Object?> check(String name) =>
      checks.firstWhere((Map<String, Object?> check) => check['check'] == name);

  List<Map<String, Object?>> get warnings => <Map<String, Object?>>[
    for (final Object? warning in doctor['warnings']! as List<Object?>)
      warning! as Map<String, Object?>,
  ];
}

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-doctor-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<_Run> run(
    List<String> arguments, {
    Future<PatchbayClient> Function(ArgResults options)? connect,
  }) async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int exitCode = await runPatchbayCliWithSeams(
      <String>['--session-dir', directory.path, ...arguments],
      connect:
          connect ?? (_) async => fail('this run must not need a connection'),
      output: out,
      errorOutput: err,
    );
    return _Run(exitCode, out.toString(), err.toString());
  }

  group('session directory', () {
    test('an empty directory is a failure with a way out', () async {
      // The `connect` seam fails the test if it is reached: a session check
      // that failed has already established there is nothing to dial, and
      // dialling anyway would spend the RPC budget re-deriving it.
      final _Run result = await run(<String>['doctor']);

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(result.out, contains('failed  session'));
      expect(result.out, contains('--ws-uri'));
      // Nothing downstream was reached, and the report says so rather than
      // implying those checks passed.
      expect(result.out, contains('skipped connection'));
      expect(result.out, contains('skipped catalog'));
      expect(result.out, contains('skipped lifecycle'));
    });

    test('several selectable sessions warn instead of failing', () async {
      store
        ..write(_record('worktree-a'))
        ..write(_record('worktree-b'));

      final _Run result = await run(<String>[
        '--json',
        'doctor',
      ], connect: (_) async => _healthyClient());

      // Ambiguity is not broken — it is one `session use` away — so the exit
      // code stays 0 and only the verdict says something is off.
      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.check('session')['verdict'], 'warning');
      expect(result.check('session')['action'], contains('session use'));
      expect(result.doctor['verdict'], 'warning');
    });

    test('a record whose process is gone fails and names the fix', () async {
      // Past the maximum PID, so no process can hold it — unlike a plausible
      // free PID, which another process may claim, or PID 1, which exists and
      // is signalable when the tests run as root inside a container.
      store.write(_record('worktree-a', processId: 2147483647));

      final _Run result = await run(<String>['--json', 'doctor']);

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(result.check('session')['verdict'], 'failed');
      expect(result.check('session')['action'], contains('sessions prune'));
    });

    test(
      'a pinned session whose file was deleted fails at session check and names clear hint',
      () async {
        store
          ..write(_record('worktree-a'))
          ..writeSelectionFor(_workspace, 'worktree-deleted');

        final _Run result = await run(<String>['--json', 'doctor']);

        expect(result.exitCode, PatchbayExitCode.transport);
        expect(result.check('session')['verdict'], 'failed');
        expect(
          result.check('session')['action'],
          patchbaySessionSelectionStaleHint,
        );
        expect(
          (result.check('session')['details']! as Map<String, Object?>)['code'],
          'sessionSelectionStale',
        );
        expect(result.check('connection')['verdict'], 'skipped');
      },
    );

    test('the directory is not consulted when the peer is named', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(<String>[
        '--json',
        '--ws-uri',
        'ws://127.0.0.1:1234/ws',
        'doctor',
      ], connect: (_) async => _healthyClient());

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.check('session')['verdict'], 'skipped');
      expect(result.check('session')['observed'], contains('--ws-uri'));
    });

    test('a printed record never carries the auth token', () async {
      store
        ..write(_record('worktree-a'))
        ..write(_record('worktree-b'));

      final _Run text = await run(<String>[
        'doctor',
      ], connect: (_) async => _healthyClient());
      final _Run json = await run(<String>[
        '--json',
        'doctor',
      ], connect: (_) async => _healthyClient());

      for (final _Run result in <_Run>[text, json]) {
        expect(result.out, isNot(contains(_token)));
        expect(result.err, isNot(contains(_token)));
      }
    });
  });

  group('connection', () {
    test('an unresponsive peer is named and blamed on a frozen App', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async =>
            throw const PatchbayTransportException(patchbayAppUnresponsiveCode),
      );

      expect(result.exitCode, PatchbayExitCode.transport);
      final Map<String, Object?> connection = result.check('connection');
      expect(connection['verdict'], 'failed');
      expect(connection['observed'], contains(patchbayAppUnresponsiveCode));
      expect(connection['cause'], contains('stopped answering'));
      expect(connection['action'], contains('KEYCODE_WAKEUP'));
      expect(connection['action'], contains('--transport-timeout-ms'));
    });

    test('an unreachable App still warns against force-stopping it', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async =>
            throw const PatchbayTransportException(patchbayAppUnresponsiveCode),
      );

      // The whole point: the operator reads this at the moment they are about
      // to kill the process, and doctor has just proved it cannot tell them
      // whether that would destroy live work.
      expect(result.warnings, hasLength(1));
      expect(
        result.warnings.single['kind'],
        patchbaySnapshotUnavailableWarningKind,
      );
      expect(result.warnings.single['message'], contains('force-stop'));
    });

    test('an unknown failure contributes its type and nothing else', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => throw const SocketException(
          'connection refused to ws://127.0.0.1:1234/$_token=/ws',
        ),
      );

      expect(result.check('connection')['verdict'], 'failed');
      // A socket exception embeds the endpoint it failed to reach, and a VM
      // Service URI carries its auth token in that path.
      expect(result.out, isNot(contains(_token)));
      expect(result.out, contains('SocketException'));
    });

    test('a session failure carries the resolver hint', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => throw const PatchbaySessionException(
          'sessionSelectionStale',
          hint: patchbaySessionSelectionStaleHint,
        ),
      );

      expect(result.check('connection')['verdict'], 'failed');
      expect(
        result.check('connection')['action'],
        patchbaySessionSelectionStaleHint,
      );
    });
  });

  group('catalog', () {
    test('a healthy catalog reports what the App registers', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(<String>[
        '--json',
        'doctor',
      ], connect: (_) async => _healthyClient());

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.check('catalog')['verdict'], 'ok');
      expect(
        (result.check('catalog')['details']!
            as Map<String, Object?>)['commands'],
        1,
      );
    });

    test('a refused catalog is a protocol-class failure', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(<String>[
        '--json',
        'doctor',
      ], connect: (_) async => _RefusedCatalogClient());

      expect(result.exitCode, PatchbayExitCode.protocol);
      expect(result.check('catalog')['verdict'], 'failed');
      expect(
        (result.check('catalog')['details']! as Map<String, Object?>)['code'],
        'invalidCommandName',
      );
      expect(result.check('lifecycle')['verdict'], 'skipped');
    });

    test('an App with no commands warns without failing', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => FakePatchbayClient(
          commands: const <Map<String, Object?>>[],
          handle: (_, _) async => fakeCommandNotRegistered(),
        ),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.check('catalog')['verdict'], 'warning');
      // Without a cataloged probe there is no lifecycle answer to give, and
      // doctor says that rather than reporting the App as resumed.
      expect(result.check('lifecycle')['verdict'], 'skipped');
    });
  });

  group('lifecycle', () {
    test('a refused probe fails with the state and the remedies', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => FakePatchbayClient(
          commands: const <Map<String, Object?>>[_semanticsTreeRow],
          handle: (String command, _) async => <String, Object?>{
            'admission': 'rejected',
            'rejection': const <String, Object?>{
              'code': 'uiLifecycleNotResumed',
              'details': <String, Object?>{'lifecycleState': 'paused'},
            },
          },
        ),
      );

      // The App answered and refused: that is a rejection, not a transport or
      // protocol fault.
      expect(result.exitCode, PatchbayExitCode.rejected);
      final Map<String, Object?> lifecycle = result.check('lifecycle');
      expect(lifecycle['verdict'], 'failed');
      expect(lifecycle['observed'], contains('lifecycleState=paused'));
      expect(lifecycle['action'], contains('KEYCODE_WAKEUP'));
      // iOS has no power command, but a backgrounded App on an unlocked
      // device is a separate problem with a command that does solve it —
      // the remedy has to name it rather than send the operator to the
      // device for something the Mac can do.
      expect(lifecycle['action'], contains('xcrun devicectl device process'));
      expect(lifecycle['action'], contains('Desktop'));
    });

    test(
      'the probe asks for the smallest tree the bridge will build',
      () async {
        store.write(_record('worktree-a'));
        final FakePatchbayClient client = _healthyClient();

        await run(<String>['doctor'], connect: (_) async => client);

        expect(client.calls, hasLength(1));
        expect(client.calls.single.command, patchbayLifecycleProbeCommand);
        expect(client.calls.single.arguments, <String, Object?>{
          'maxDepth': 0,
          'maxNodes': 1,
        });
      },
    );

    test('a gate refusal is a warning, not a lifecycle verdict', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => FakePatchbayClient(
          commands: const <Map<String, Object?>>[_semanticsTreeRow],
          handle: (_, _) async => <String, Object?>{
            'admission': 'rejected',
            'rejection': const <String, Object?>{'code': 'gateClosed'},
          },
        ),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.check('lifecycle')['verdict'], 'warning');
      expect(result.check('lifecycle')['observed'], contains('gateClosed'));
    });
  });

  group('active business session', () {
    test('a live session in the snapshot warns against force-stop', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => _healthyClient(
          snapshot: const <String, Object?>{
            'schemaVersion': 1,
            'call': <String, Object?>{
              'session': <String, Object?>{'active': true, 'id': 'c-1'},
            },
          },
        ),
      );

      // Nothing is broken, so the exit code stays 0 — the warning is about
      // what recovery to avoid, not about the CLI being unable to work.
      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single['kind'], patchbayActiveSessionWarningKind);
      expect(result.warnings.single['path'], 'call.session.active');
      expect(result.warnings.single['message'], contains('force-stop'));
      expect(result.doctor['verdict'], 'warning');
    });

    test('the human rendering shows the warning too', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['doctor'],
        connect: (_) async => _healthyClient(
          snapshot: const <String, Object?>{
            'call': <String, Object?>{
              'session': <String, Object?>{'active': true},
            },
          },
        ),
      );

      expect(result.out, contains('!! '));
      expect(result.out, contains('call.session.active'));
    });

    test('an idle snapshot produces no warning at all', () async {
      store.write(_record('worktree-a'));

      final _Run result = await run(
        <String>['--json', 'doctor'],
        connect: (_) async => _healthyClient(
          snapshot: const <String, Object?>{
            'call': <String, Object?>{
              'session': <String, Object?>{'active': false},
            },
          },
        ),
      );

      expect(result.warnings, isEmpty);
      expect(result.doctor['verdict'], 'ok');
    });

    test('sessions carried in a list are found by their index', () {
      final List<PatchbayDoctorWarning> warnings =
          patchbayActiveSessionWarnings(const <String, Object?>{
            'media': <String, Object?>{
              'streams': <Object?>[
                <String, Object?>{'active': false},
                <String, Object?>{'active': true},
              ],
            },
          });

      expect(warnings, hasLength(1));
      expect(warnings.single.path, 'media.streams[1].active');
    });

    test('the protocol-owned schemaVersion is never scanned', () {
      // Not a business domain, and it is the one key the host always adds.
      expect(
        patchbayActiveSessionWarnings(const <String, Object?>{
          'schemaVersion': <String, Object?>{'active': true},
        }),
        isEmpty,
      );
    });

    test('a non-boolean active field is not a live session', () {
      expect(
        patchbayActiveSessionWarnings(const <String, Object?>{
          'pairing': <String, Object?>{'active': 'true'},
        }),
        isEmpty,
      );
    });

    test('the scan reaches the documented depth and stops there', () {
      // The snapshot is consumer data of unknown shape, so the walk is
      // bounded: an unbounded one is how a diagnosis becomes another hang.
      // Both sides of the bound are pinned here, because a bound that only
      // ever gets its "too deep" half tested can silently shrink to nothing.
      expect(
        patchbayActiveSessionWarnings(const <String, Object?>{
          'domain': <String, Object?>{
            'a': <String, Object?>{
              'b': <String, Object?>{
                'c': <String, Object?>{
                  'd': <String, Object?>{'active': true},
                },
              },
            },
          },
        }).single.path,
        'domain.a.b.c.d.active',
      );
      expect(
        patchbayActiveSessionWarnings(const <String, Object?>{
          'domain': <String, Object?>{
            'a': <String, Object?>{
              'b': <String, Object?>{
                'c': <String, Object?>{
                  'd': <String, Object?>{
                    'e': <String, Object?>{'active': true},
                  },
                },
              },
            },
          },
        }),
        isEmpty,
      );
    });
  });

  group('command shape', () {
    test('doctor takes no arguments', () async {
      final _Run result = await run(<String>['doctor', 'now']);

      expect(result.exitCode, PatchbayExitCode.usage);
    });

    test('doctor takes no command options', () async {
      final _Run result = await run(<String>['--timeout-ms', '1000', 'doctor']);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('--timeout-ms is not valid for doctor'));
    });

    test('a usage failure under --json still answers on stdout', () async {
      final _Run result = await run(<String>['--json', 'doctor', 'now']);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(
        (jsonDecode(result.out) as Map<String, Object?>)['error'],
        isA<Map<String, Object?>>(),
      );
    });

    test('doctor is refused inside a repl session', () async {
      store.write(_record('worktree-a'));
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();

      await runPatchbayCliWithSeams(
        <String>['--session-dir', directory.path, 'repl'],
        connect: (_) async => _healthyClient(),
        replInput: Stream<String>.fromIterable(<String>['doctor']),
        output: out,
        errorOutput: err,
      );

      expect(err.toString(), contains('doctor is unavailable inside a repl'));
      expect(out.toString(), contains('exit=${PatchbayExitCode.usage}'));
    });

    test('help describes it without connecting', () async {
      final _Run result = await run(<String>['help', 'doctor']);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.out, contains('Always available'));
      expect(result.out, contains('read-only UI probe'));
    });
  });

  group('repl lifecycle banner', () {
    Future<_Run> repl(List<String> lines, PatchbayClient client) async {
      store.write(_record('worktree-a'));
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      final int exitCode = await runPatchbayCliWithSeams(
        <String>['--session-dir', directory.path, '--json', 'repl'],
        connect: (_) async => client,
        replInput: Stream<String>.fromIterable(lines),
        output: out,
        errorOutput: err,
      );
      return _Run(exitCode, out.toString(), err.toString());
    }

    FakePatchbayClient pausedApp() => FakePatchbayClient(
      commands: const <Map<String, Object?>>[_semanticsTreeRow],
      handle: (_, _) async => <String, Object?>{
        'admission': 'rejected',
        'rejection': const <String, Object?>{
          'code': 'uiLifecycleNotResumed',
          'details': <String, Object?>{'lifecycleState': 'paused'},
        },
      },
    );

    test('the first refused line explains the remedies', () async {
      final _Run result = await repl(<String>[
        'ui semantics tree',
      ], pausedApp());

      expect(result.err, contains('patchbay preflight'));
      expect(result.err, contains('lifecycleState=paused'));
      expect(result.err, contains('KEYCODE_WAKEUP'));
      expect(result.err, contains('xcrun devicectl device process'));
      expect(result.err, contains('patchbay doctor'));
    });

    test('the banner never repeats inside one session', () async {
      final _Run result = await repl(<String>[
        'ui semantics tree',
        'ui semantics tree',
        'ui semantics tree',
      ], pausedApp());

      // Every line is refused, but the remedies are the same three sentences
      // each time and repeating them would bury the results being read.
      expect('patchbay preflight'.allMatches(result.err), hasLength(1));
    });

    test('the banner costs the session no traffic of its own', () async {
      final FakePatchbayClient client = pausedApp();

      await repl(<String>['ui semantics tree'], client);

      // A repl runs the lines that were typed. The lifecycle is read out of a
      // refusal the App produced anyway, never out of a probe the session
      // sent — the only lifecycle-gated read-only command enables semantics
      // and schedules frames in the App being observed.
      expect(client.calls, hasLength(1));
      expect(client.catalogReads, 1);
    });

    test('a session against a resumed App stays silent', () async {
      final _Run result = await repl(<String>[
        'ui semantics tree',
      ], _healthyClient());

      expect(result.err, isEmpty);
    });
  });

  group('report shape', () {
    test('the exit code is the class of the first failure', () {
      const PatchbayDoctorReport report = PatchbayDoctorReport(
        findings: <PatchbayDoctorFinding>[
          PatchbayDoctorFinding(
            check: PatchbayDoctorCheck.session,
            verdict: PatchbayCheckVerdict.failed,
            observed: 'gone',
          ),
          PatchbayDoctorFinding(
            check: PatchbayDoctorCheck.catalog,
            verdict: PatchbayCheckVerdict.failed,
            observed: 'refused',
          ),
        ],
        warnings: <PatchbayDoctorWarning>[],
      );

      expect(report.exitCode, PatchbayExitCode.transport);
      expect(report.verdict, PatchbayCheckVerdict.failed);
    });

    test('a skipped check never becomes the verdict', () {
      const PatchbayDoctorReport report = PatchbayDoctorReport(
        findings: <PatchbayDoctorFinding>[
          PatchbayDoctorFinding(
            check: PatchbayDoctorCheck.session,
            verdict: PatchbayCheckVerdict.skipped,
            observed: 'named explicitly',
          ),
        ],
        warnings: <PatchbayDoctorWarning>[],
      );

      expect(report.verdict, PatchbayCheckVerdict.ok);
      expect(report.exitCode, PatchbayExitCode.accepted);
    });

    test('the banner is only ever a lifecycle refusal', () {
      expect(
        patchbayLifecycleBanner(
          const PatchbayDoctorFinding(
            check: PatchbayDoctorCheck.connection,
            verdict: PatchbayCheckVerdict.failed,
            observed: 'unreachable',
          ),
        ),
        isNull,
      );
      expect(
        patchbayLifecycleBanner(
          const PatchbayDoctorFinding(
            check: PatchbayDoctorCheck.lifecycle,
            verdict: PatchbayCheckVerdict.warning,
            observed: 'a gate refused it',
          ),
        ),
        isNull,
      );
    });
  });
}

/// An App with a cataloged probe that answers it.
FakePatchbayClient _healthyClient({Map<String, Object?>? snapshot}) =>
    FakePatchbayClient(
      commands: const <Map<String, Object?>>[_semanticsTreeRow],
      snapshotData:
          snapshot ?? const <String, Object?>{'source': 'appRecorded'},
      handle: (String command, _) async => command == 'ui.semantics.tree'
          ? fakeAccepted(const <String, Object?>{'nodes': <Object?>[]})
          : fakeCommandNotRegistered(),
    );

/// A host that refuses to serve its catalog at all.
final class _RefusedCatalogClient implements PatchbayClient {
  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'dev.patchbay.fake',
    'appInstanceId': 'fake-instance',
    'isolateId': 'isolates/1',
  };

  @override
  Future<Map<String, Object?>> catalog() async => <String, Object?>{
    'admission': 'rejected',
    'rejection': const <String, Object?>{
      'code': 'invalidCommandName',
      'details': <String, Object?>{'command': 'Bad.Name'},
    },
  };

  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async => <String, Object?>{'source': 'appRecorded'};

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async => fail('a refused catalog must not be followed by an invoke');

  @override
  Future<Map<String, Object?>> widgetTree() async => fail('not used');

  @override
  Future<Map<String, Object?>> renderTree() async => fail('not used');

  @override
  Future<Map<String, Object?>> focusTree() async => fail('not used');

  @override
  Future<void> close() async {}
}

/// The checkout this test process is actually running in: doctor drives the
/// real CLI, so its own workspace probe decides which records count as ours.
final PatchbayWorkspaceIdentity _workspace =
    PatchbayWorkspaceIdentity.current()!;

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
