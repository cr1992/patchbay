import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fixture/fake_client.dart';

/// A client whose snapshot RPC is served by the **real** service host.
///
/// The CLI's own job ends at the wire, so [FakePatchbayClient.snapshotRequests]
/// is what proves an option arrived in the declared shape. But how the CLI
/// *classifies* a wait — a timeout is an exit code, not a payload — can only be
/// tested against the envelopes the host actually produces, and re-typing those
/// into a fake would be a test that agrees with itself. Everything except the
/// snapshot is delegated to the ordinary fake.
final class _HostBackedClient
    implements PatchbayClient, PatchbaySnapshotDiffClient {
  _HostBackedClient(this._source, {this.identityData});

  /// Answers one probe. A wait test hands over a source that changes its mind,
  /// which is the only way to show the host re-reads rather than answering from
  /// its first look.
  final Future<Map<String, Object?>> Function() _source;

  /// Overrides the real host identity when modelling an older peer.
  final Map<String, Object?>? identityData;

  late final FakePatchbayClient _fake = FakePatchbayClient(
    commands: const <Map<String, Object?>>[],
    handle: (_, _) async => fakeCommandNotRegistered(),
  );

  late final PatchbayServiceHost _host = PatchbayServiceHost(
    applicationId: 'dev.patchbay.fake',
    registrar: (_, _) {},
    catalog: () async => const <String, Object?>{'commands': <Object?>[]},
    snapshot: _source,
    invoke: (_, _, String requestId) async =>
        PatchbayInvocation.accepted(requestId: requestId).toJson(),
  );

  /// Every request that reached the host; null for a whole-snapshot read.
  final List<PatchbaySnapshotRequest?> requests = <PatchbaySnapshotRequest?>[];

  /// Thrown instead of answering, to stand in for a transport-level refusal.
  Object? snapshotFailure;

  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async {
    requests.add(request);
    if (snapshotFailure case final Object failure) {
      return Future<Map<String, Object?>>.error(failure);
    }
    return _host.dispatchSnapshot(request?.toWire().toJson());
  }

  @override
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision}) =>
      _host.dispatchSnapshot(
        PatchbaySnapshotDiffRequest(
          fromRevision: fromRevision,
        ).toWire().toJson(),
      );

  @override
  Future<Map<String, Object?>> identity() async =>
      identityData ?? _host.identityResponse();

  @override
  Future<Map<String, Object?>> catalog() => _fake.catalog();

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) => _fake.invoke(
    command: command,
    arguments: arguments,
    requestId: requestId,
    deadline: deadline,
  );

  @override
  Future<Map<String, Object?>> widgetTree() => _fake.widgetTree();

  @override
  Future<Map<String, Object?>> renderTree() => _fake.renderTree();

  @override
  Future<Map<String, Object?>> focusTree() => _fake.focusTree();

  @override
  Future<void> close() => _fake.close();
}

typedef _Result = ({
  int exitCode,
  Map<String, Object?>? response,
  String out,
  String err,
  List<PatchbaySnapshotRequest?> requests,
});

const Map<String, Object?> _deviceSnapshot = <String, Object?>{
  'call': <String, Object?>{
    'session': <String, Object?>{
      'active': true,
      'peer': 'device-7',
      'endedAt': null,
    },
  },
  'battery': 41,
};

Future<_Result> _run(
  List<String> arguments, {
  Map<String, Object?> snapshot = _deviceSnapshot,
  Future<Map<String, Object?>> Function()? source,
  Map<String, Object?>? identityData,
  Object? snapshotFailure,
}) async {
  final _HostBackedClient client = _HostBackedClient(
    source ?? () async => snapshot,
    identityData: identityData,
  )..snapshotFailure = snapshotFailure;
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  final String stdout = out.toString();
  return (
    exitCode: exitCode,
    response: stdout.trim().startsWith('{')
        ? jsonDecode(stdout) as Map<String, Object?>
        : null,
    out: stdout,
    err: err.toString(),
    requests: client.requests,
  );
}

Map<String, Object?> _selection(Map<String, Object?> response) =>
    response['selection']! as Map<String, Object?>;

Map<String, Object?> _details(Map<String, Object?> response) =>
    (response['rejection']! as Map<String, Object?>)['details']!
        as Map<String, Object?>;

void main() {
  group('a host built before selectors existed', () {
    test('a selector falls back before any snapshot request is sent', () async {
      final _Result result = await _run(
        <String>['--json', 'snapshot', '--path', 'call.session.active'],
        identityData: legacyFakeIdentity,
        // This would surface if the capability gate accidentally sent a
        // selector to the old host.
        snapshotFailure: const PatchbayTransportException('shouldNotBeSent'),
      );

      expect(result.exitCode, PatchbayExitCode.rejected);
      expect(result.requests, isEmpty);
      final Map<String, Object?> rejection =
          result.response!['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'snapshotSelectionUnsupportedByHost');
      expect(rejection['notice'], contains('snapshot'));
    });

    test(
      'a wait is refused before the request when capability is absent',
      () async {
        final _Result result = await _run(
          <String>[
            '--json',
            'snapshot',
            'wait',
            'call.session.active',
            '--until',
            'exists',
          ],
          identityData: const <String, Object?>{
            ...legacyFakeIdentity,
            'features': <String>['catalogDigest', 'futureCapability'],
          },
        );

        expect(result.exitCode, PatchbayExitCode.rejected);
        expect(result.requests, isEmpty);
        expect(
          (result.response!['rejection']! as Map<String, Object?>)['code'],
          'snapshotSelectionUnsupportedByHost',
        );
      },
    );

    test('a whole-snapshot read still reaches an old host', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
      ], identityData: legacyFakeIdentity);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.requests, <PatchbaySnapshotRequest?>[null]);
      expect(result.response!['battery'], 41);
    });
  });

  group('a host that declares selectors', () {
    test(
      'unknown capabilities stay loose while the known one enables selectors',
      () async {
        final _Result result = await _run(
          <String>['--json', 'snapshot', '--path', 'call.session.peer'],
          identityData: const <String, Object?>{
            ...legacyFakeIdentity,
            'features': <String>[
              'catalogDigest',
              'snapshotSelectors',
              'futureCapability',
            ],
          },
        );

        expect(result.exitCode, PatchbayExitCode.accepted);
        expect(result.requests, hasLength(1));
        expect(_selection(result.response!)['value'], 'device-7');
      },
    );

    test('a protocol failure keeps its real classification', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
        '--path',
        'call',
      ], snapshotFailure: const PatchbayProtocolException('protocolError'));

      expect(result.exitCode, PatchbayExitCode.protocol);
      expect(result.requests, hasLength(1));
      expect(
        (result.response!['error']! as Map<String, Object?>)['code'],
        'protocolError',
      );
    });

    test('VM invalidParams is not guessed to mean unsupported', () async {
      final _Result result = await _run(
        <String>['--json', 'snapshot', '--path', 'call'],
        snapshotFailure: RPCError(
          'snapshot',
          RPCErrorKind.kInvalidParams.code,
          'unknown',
        ),
      );

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(result.requests, hasLength(1));
      expect(
        (result.response!['error']! as Map<String, Object?>)['code'],
        'transportError',
      );
    });
  });

  group('snapshot --path', () {
    test('an omitted --path is still the whole-snapshot read', () async {
      final _Result result = await _run(<String>['--json', 'snapshot']);

      expect(result.exitCode, PatchbayExitCode.accepted);
      // Null, not an empty selector: the request that always worked must keep
      // travelling as the request it was, or every existing App sees a new one.
      expect(result.requests, <PatchbaySnapshotRequest?>[null]);
      expect(result.response!['battery'], 41);
    });

    test('a path travels as a selection and answers only that', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
        '--path',
        'call.session.peer',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.requests.single!.toWire().toJson(), <String, Object?>{
        'path': 'call.session.peer',
      });
      expect(_selection(result.response!), <String, Object?>{
        'path': 'call.session.peer',
        'found': true,
        'value': 'device-7',
      });
      expect(result.response!.containsKey('call'), isFalse);
    });

    test(
      'a path that resolves to nothing is an answer, not a failure',
      () async {
        // The whole-snapshot read would equally just not have the key. A plain
        // selection reports absence with a reason and exits 0; only a *wait* on
        // that absence is a failure, because a wait asserts the field will come.
        final _Result result = await _run(<String>[
          '--json',
          'snapshot',
          '--path',
          'call.session.missing',
        ]);

        expect(result.exitCode, PatchbayExitCode.accepted);
        expect(_selection(result.response!), <String, Object?>{
          'path': 'call.session.missing',
          'found': false,
          'miss': 'missingKey',
        });
      },
    );

    test('the human summary states the path, the verdict and why', () async {
      final _Result found = await _run(<String>[
        'snapshot',
        '--path',
        'call.session.active',
      ]);
      expect(
        found.out.trim(),
        'path=call.session.active found=true value=true',
      );

      final _Result miss = await _run(<String>[
        'snapshot',
        '--path',
        'call.session.endedAt',
      ]);
      expect(
        miss.out.trim(),
        'path=call.session.endedAt found=false miss=nullValue',
      );
    });

    test('a malformed path never reaches the App', () async {
      for (final String path in <String>['', 'call.', 'call..session', 'a b']) {
        final _Result result = await _run(<String>[
          '--json',
          'snapshot',
          '--path',
          path,
        ]);

        expect(result.exitCode, PatchbayExitCode.usage, reason: path);
        expect(result.requests, isEmpty, reason: path);
        expect(
          (result.response!['error']! as Map<String, Object?>)['code'],
          'usageError',
        );
      }
    });

    test('--path is refused on a command that does not take it', () async {
      final _Result result = await _run(<String>[
        '--json',
        '--path',
        'call',
        'catalog',
      ]);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.requests, isEmpty);
    });
  });

  group('snapshot wait', () {
    test('a condition already true answers with the default budget', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
        'wait',
        'call.session.active',
        '--until',
        'equals',
        'true',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.requests.single!.toWire().toJson(), <String, Object?>{
        'path': 'call.session.active',
        'until': 'equals',
        'value': true,
        'timeoutMs': 5000,
      });
      expect(
        (result.response!['wait']! as Map<String, Object?>)['outcome'],
        'observed',
      );
    });

    test('the App keeps re-reading until the field turns up', () async {
      var probes = 0;
      final _Result result = await _run(
        <String>[
          '--json',
          'snapshot',
          'wait',
          'call.session',
          '--until',
          'exists',
        ],
        source: () async {
          probes += 1;
          return probes < 3
              ? const <String, Object?>{'call': <String, Object?>{}}
              : const <String, Object?>{
                  'call': <String, Object?>{'session': 'device-7'},
                };
        },
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(_selection(result.response!)['value'], 'device-7');
      expect((result.response!['wait']! as Map<String, Object?>)['polls'], 3);
    });

    test('absent is observed for a null field', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
        'wait',
        'call.session.endedAt',
        '--until',
        'absent',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(
        (result.response!['wait']! as Map<String, Object?>)['outcome'],
        'observed',
      );
    });

    test(
      'a condition that never holds exits rejected with what it saw',
      () async {
        final _Result result = await _run(<String>[
          '--json',
          '--timeout-ms',
          '150',
          'snapshot',
          'wait',
          'call.session.active',
          '--until',
          'equals',
          'false',
        ]);

        // Same classification as any other App rejection, `ui wait` included:
        // a script that already branches on 5 branches on this too.
        expect(result.exitCode, PatchbayExitCode.rejected);
        expect(
          (result.response!['rejection']! as Map<String, Object?>)['code'],
          'snapshotWaitTimeout',
        );
        final Map<String, Object?> details = _details(result.response!);
        expect(details['timeoutMs'], 150);
        expect(details['observed'], <String, Object?>{
          'path': 'call.session.active',
          'found': true,
          'value': true,
        });
      },
    );

    test('a snapshot source slower than the budget exits rejected', () async {
      // The condition holds on the first probe, but reading it overran the
      // budget. Exit 0 here would tell a script the field reached its value in
      // time when it did not — which is the whole point of declaring one.
      final _Result result = await _run(
        <String>[
          '--json',
          '--timeout-ms',
          '10',
          'snapshot',
          'wait',
          'call.session.active',
          '--until',
          'equals',
          'true',
        ],
        source: () async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return _deviceSnapshot;
        },
      );

      expect(result.exitCode, PatchbayExitCode.rejected);
      expect(
        (result.response!['rejection']! as Map<String, Object?>)['code'],
        'snapshotWaitTimeout',
      );
      expect(_details(result.response!)['polls'], 1);
    });

    test('a path that never appears times out, it does not answer', () async {
      final _Result result = await _run(<String>[
        '--json',
        '--timeout-ms',
        '120',
        'snapshot',
        'wait',
        'call.session.peerName',
        '--until',
        'exists',
      ]);

      expect(result.exitCode, PatchbayExitCode.rejected);
      expect(
        (result.response!['rejection']! as Map<String, Object?>)['code'],
        'snapshotWaitTimeout',
      );
      expect(
        (_details(result.response!)['observed']!
            as Map<String, Object?>)['miss'],
        'missingKey',
      );
    });

    test('the declared wait extends the RPC budget', () async {
      // The App legitimately spends longer than one round-trip budget waiting.
      // Without the arithmetic in `patchbayRpcBudget` the CLI would abandon a
      // request the App is still serving — the opposite of the failure that
      // budget exists to catch.
      var probes = 0;
      final _Result result = await _run(
        <String>[
          '--json',
          '--transport-timeout-ms',
          '200',
          '--timeout-ms',
          '2000',
          'snapshot',
          'wait',
          'ready',
          '--until',
          'equals',
          'true',
        ],
        source: () async {
          probes += 1;
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return <String, Object?>{'ready': probes > 2};
        },
      );

      expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
      expect(probes, greaterThan(2));
    });

    test('an incomplete or over-full line is a usage error', () async {
      for (final List<String> words in <List<String>>[
        <String>['snapshot', 'wait', 'call.session'],
        <String>['snapshot', 'wait', '--until', 'exists'],
        <String>['snapshot', 'wait', 'call.session', '--until', 'equals'],
        <String>['snapshot', 'wait', 'call.session', '--until', 'exists', '1'],
        <String>['snapshot', 'wait', 'call.session', '--until', 'matches'],
      ]) {
        final _Result result = await _run(<String>['--json', ...words]);

        expect(result.exitCode, PatchbayExitCode.usage, reason: '$words');
        expect(result.requests, isEmpty, reason: '$words');
      }
    });

    test('a bare word is refused with the quoting that fixes it', () async {
      final _Result result = await _run(<String>[
        'snapshot',
        'wait',
        'call.session.peer',
        '--until',
        'equals',
        'device-7',
      ]);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('"device-7"'));
      expect(result.requests, isEmpty);
    });

    test('null as a compared value points at --until absent', () async {
      final _Result result = await _run(<String>[
        'snapshot',
        'wait',
        'call.session.endedAt',
        '--until',
        'equals',
        'null',
      ]);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('--until absent'));
    });

    test('a quoted JSON literal keeps its type on the wire', () async {
      final _Result result = await _run(<String>[
        '--json',
        'snapshot',
        'wait',
        'call.session.peer',
        '--until',
        'equals',
        '"device-7"',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.requests.single!.value, 'device-7');
    });
  });
}
