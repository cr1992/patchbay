import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/repl.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:test/test.dart';

/// A client that counts how many times a session actually dials the App.
///
/// The whole claim of this mode is "connect once, run many", and the only
/// honest way to test that claim is to count connections rather than to
/// observe that the commands happened to succeed.
final class _FakeClient implements PatchbayClient {
  final List<String> invoked = <String>[];
  int catalogReads = 0;
  bool closed = false;
  Object? failNextWith;

  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'dev.patchbay.fake',
    'appInstanceId': 'fake-instance',
    'isolateId': 'isolates/1',
  };

  @override
  Future<Map<String, Object?>> catalog() async {
    catalogReads += 1;
    return <String, Object?>{
      'commands': <Object?>[
        for (final String name in <String>[
          'ui.semantics.tree',
          'ui.semantics.tap',
          'navigation.current',
        ])
          <String, Object?>{'name': name},
      ],
      'uiTargets': const <Object?>[],
    };
  }

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
  }) async {
    if (failNextWith case final Object failure) {
      failNextWith = null;
      return Future<Map<String, Object?>>.error(failure);
    }
    invoked.add(command);
    final String id = requestId ?? 'fake-request';
    if (arguments['identifier'] == 'absent.id') {
      return <String, Object?>{
        'schemaVersion': 1,
        'requestId': id,
        'admission': 'rejected',
        'payload': const <String, Object?>{},
        'rejection': <String, Object?>{
          'code': 'uiSemanticsIdentifierNotFound',
          'details': <String, Object?>{'identifier': 'absent.id'},
        },
      };
    }
    return <String, Object?>{
      'schemaVersion': 1,
      'requestId': id,
      'admission': 'accepted',
      'payload': <String, Object?>{
        'outcome': 'dispatched',
        'source': 'uiObserved',
        'command': command,
        'arguments': arguments,
      },
    };
  }

  @override
  Future<Map<String, Object?>> widgetTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> renderTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> focusTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<void> close() async => closed = true;
}

final class _Session {
  _Session(this.exitCode, this.client, this.connects, this.out, this.err);

  final int exitCode;
  final _FakeClient client;
  final int connects;
  final String out;
  final String err;

  List<String> get lines => const LineSplitter()
      .convert(out)
      .where((String line) => line.isNotEmpty)
      .toList(growable: false);

  List<Map<String, Object?>> get envelopes => lines
      .map((String line) => jsonDecode(line) as Map<String, Object?>)
      .toList(growable: false);
}

Future<_Session> _repl(
  List<String> input, {
  List<String> arguments = const <String>['--json', 'repl'],
  _FakeClient? client,
}) async {
  final _FakeClient fake = client ?? _FakeClient();
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  var connects = 0;
  final int code = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async {
      connects += 1;
      return fake;
    },
    replInput: Stream<String>.fromIterable(input),
    output: out,
    errorOutput: err,
  );
  return _Session(code, fake, connects, out.toString(), err.toString());
}

void main() {
  test('one connection serves every command in the session', () async {
    final _Session session = await _repl(<String>[
      'identity',
      'snapshot',
      'ui semantics tree',
      'ui tap login.submit',
    ]);

    expect(session.connects, 1);
    expect(session.exitCode, PatchbayExitCode.accepted);
    expect(session.envelopes, hasLength(4));
    expect(
      session.envelopes.map((Map<String, Object?> row) => row['exitCode']),
      everyElement(PatchbayExitCode.accepted),
    );
    expect(session.client.invoked, <String>[
      'ui.semantics.tree',
      'ui.semantics.tap',
    ]);
    // Clean exit: the session hands the connection back instead of leaking it
    // to process teardown.
    expect(session.client.closed, isTrue);
  });

  test(
    'a rejected line keeps its own exit code and the session alive',
    () async {
      final _Session session = await _repl(<String>[
        'ui tap absent.id',
        'ui tap login.submit',
      ]);

      expect(session.connects, 1);
      expect(session.exitCode, PatchbayExitCode.accepted);
      expect(session.envelopes[0]['exitCode'], PatchbayExitCode.rejected);
      expect(session.envelopes[1]['exitCode'], PatchbayExitCode.accepted);
      // The rejection travels whole, details included.
      final Map<String, Object?> rejection =
          ((session.envelopes[0]['response']!
                  as Map<String, Object?>)['rejection']!)
              as Map<String, Object?>;
      expect(rejection['code'], 'uiSemanticsIdentifierNotFound');
      expect(rejection['details'], isNotEmpty);
    },
  );

  test(
    'a transport failure ends the session instead of reconnecting',
    () async {
      final _FakeClient client = _FakeClient()
        ..failNextWith = const PatchbayTransportException('socketClosed');
      final _Session session = await _repl(<String>[
        'ui semantics tree',
        'ui tap login.submit',
      ], client: client);

      expect(session.exitCode, PatchbayExitCode.transport);
      // The second line must never run: a dead connection may not be silently
      // replaced by a fresh one the operator did not select.
      expect(session.connects, 1);
      expect(session.client.invoked, isEmpty);
      expect(session.client.closed, isTrue);
      expect(session.err, contains('socketClosed'));
      expect(
        session.out,
        '${jsonEncode(const PatchbayErrorEnvelope('socketClosed').toJson())}\n',
      );
    },
  );

  test('terminal failures keep the JSON repl stream line-delimited', () async {
    final List<({Object failure, int exitCode, String code})> cases =
        <({Object failure, int exitCode, String code})>[
          (
            failure: const PatchbayProtocolException(
              'responseSchemaMismatch',
              details: <String, Object?>{'field': 'payload'},
            ),
            exitCode: PatchbayExitCode.protocol,
            code: 'responseSchemaMismatch',
          ),
          (
            failure: const PatchbaySessionException('sessionIdentityMismatch'),
            exitCode: PatchbayExitCode.protocol,
            code: 'sessionIdentityMismatch',
          ),
        ];

    for (final ({Object failure, int exitCode, String code}) testCase
        in cases) {
      final _Session session = await _repl(<String>[
        'ui semantics tree',
        'ui tap login.submit',
      ], client: _FakeClient()..failNextWith = testCase.failure);

      expect(session.exitCode, testCase.exitCode);
      expect(session.out, endsWith('\n'));
      expect(session.lines, hasLength(1));
      expect(session.envelopes.single['error'], <String, Object?>{
        'code': testCase.code,
        'details': testCase.code == 'responseSchemaMismatch'
            ? <String, Object?>{'field': 'payload'}
            : <String, Object?>{},
      });
      expect(session.client.invoked, isEmpty);
      expect(session.client.closed, isTrue);
    }
  });

  test('connection options are refused per line, never reconnected', () async {
    final _Session session = await _repl(<String>[
      '--ws-uri ws://127.0.0.1:1/ws identity',
      '--session other-session identity',
      '--json identity',
      'identity',
    ]);

    expect(session.connects, 1);
    expect(session.exitCode, PatchbayExitCode.accepted);
    for (final Map<String, Object?> envelope in session.envelopes.take(3)) {
      expect(envelope['exitCode'], PatchbayExitCode.usage);
      expect(envelope['error'], contains('repl session'));
    }
    expect(session.envelopes[3]['exitCode'], PatchbayExitCode.accepted);
  });

  test('sensitive input and nesting fail closed inside a session', () async {
    final _Session session = await _repl(<String>[
      '--stdin exec fixture.command',
      'repl',
      'identity',
    ]);

    expect(session.envelopes[0]['exitCode'], PatchbayExitCode.usage);
    expect(session.envelopes[0]['error'], contains('--stdin is unavailable'));
    expect(session.envelopes[1]['exitCode'], PatchbayExitCode.usage);
    expect(session.envelopes[1]['error'], contains('cannot nest'));
    expect(session.envelopes[2]['exitCode'], PatchbayExitCode.accepted);
    expect(session.connects, 1);
  });

  test('exit stops the session and later lines never run', () async {
    final _Session session = await _repl(<String>[
      'ui semantics tree',
      '# a comment is not a command',
      '',
      'exit',
      'ui tap login.submit',
    ]);

    expect(session.exitCode, PatchbayExitCode.accepted);
    expect(session.envelopes, hasLength(1));
    expect(session.client.invoked, <String>['ui.semantics.tree']);
    expect(session.client.closed, isTrue);
  });

  test('a malformed line is a usage result, not a dead session', () async {
    final _Session session = await _repl(<String>[
      'exec "unterminated',
      'identity',
    ]);

    expect(session.envelopes[0]['exitCode'], PatchbayExitCode.usage);
    expect(session.envelopes[0]['error'], contains('unterminated quote'));
    expect(session.envelopes[1]['exitCode'], PatchbayExitCode.accepted);
  });

  test('help is answered locally without touching the connection', () async {
    final _Session session = await _repl(<String>['help ui', 'identity']);

    expect(session.out, contains('Usage: patchbay ui'));
    expect(session.connects, 1);
    expect(session.client.invoked, isEmpty);
  });

  test(
    'describe reads the live catalog without invoking the command',
    () async {
      final _Session session = await _repl(<String>[
        'describe ui.semantics.tree',
      ]);

      expect(session.exitCode, PatchbayExitCode.accepted);
      expect(session.envelopes, hasLength(1));
      final Map<String, Object?> response =
          session.envelopes.single['response']! as Map<String, Object?>;
      expect(
        (response['command']! as Map<String, Object?>)['name'],
        'ui.semantics.tree',
      );
      expect(session.client.catalogReads, 1);
      expect(session.client.invoked, isEmpty);
    },
  );

  test('without --json each line still reports its own exit code', () async {
    final _Session session = await _repl(
      <String>['identity', 'ui tap absent.id'],
      arguments: const <String>['repl'],
    );

    expect(session.lines, hasLength(2));
    expect(session.lines[0], startsWith('[1] exit=0 '));
    expect(session.lines[0], contains('dev.patchbay.fake'));
    expect(session.lines[1], startsWith('[2] exit=5 '));
  });

  test('direct mode is refused before any connection is opened', () async {
    final _Session session = await _repl(
      const <String>[],
      arguments: const <String>[
        '--direct-endpoint',
        'http://127.0.0.1:1/patchbay/direct/v1',
        '--direct-token-stdin',
        '--direct-application-id',
        'dev.patchbay.fake',
        '--direct-app-instance-id',
        'fake-instance',
        'repl',
      ],
    );

    expect(session.exitCode, PatchbayExitCode.usage);
    expect(session.connects, 0);
    expect(session.err, contains('share one stdin'));
  });

  test('repl rejects command options that belong on its lines', () async {
    final _Session session = await _repl(
      const <String>[],
      arguments: const <String>['--args', '{}', 'repl'],
    );

    expect(session.exitCode, PatchbayExitCode.usage);
    expect(session.connects, 0);
  });

  group('tokenizer', () {
    test('keeps quoted JSON and escapes intact', () {
      expect(
        tokenizePatchbayReplLine('exec ns.cmd --args \'{"a": 1}\''),
        <String>['exec', 'ns.cmd', '--args', '{"a": 1}'],
      );
      expect(
        tokenizePatchbayReplLine(r'ui text set f.id 3 "a \"quoted\" word"'),
        <String>['ui', 'text', 'set', 'f.id', '3', 'a "quoted" word'],
      );
      expect(tokenizePatchbayReplLine('  ui   tap   login.submit  '), <String>[
        'ui',
        'tap',
        'login.submit',
      ]);
      expect(tokenizePatchbayReplLine("exec ''"), <String>['exec', '']);
    });

    test('an unterminated quote is refused, not silently truncated', () {
      expect(
        () => tokenizePatchbayReplLine('exec "ns.cmd'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
