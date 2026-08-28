import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

/// A client whose `ui.semantics.tree` answer the test controls directly, so
/// a repl line can be made to trip the PB-050-20 threshold on demand.
final class _TreeClient implements PatchbayClient {
  final List<Map<String, Object?>> semanticsTreePayloads =
      <Map<String, Object?>>[];

  /// Counts every `invoke` call, so a test that must prove a line's RPC
  /// never went out (F6) has something firmer to assert than "the response
  /// looks empty".
  int invokeCount = 0;

  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'dev.patchbay.fake',
    'appInstanceId': 'fake-instance',
    'isolateId': 'isolates/1',
  };

  @override
  Future<Map<String, Object?>> catalog() async => <String, Object?>{
    'commands': const <Object?>[
      <String, Object?>{'name': 'ui.semantics.tree'},
    ],
    'uiTargets': const <Object?>[],
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
  }) async {
    invokeCount += 1;
    final Map<String, Object?> payload = semanticsTreePayloads.isEmpty
        ? const <String, Object?>{'outcome': 'observed', 'nodes': <Object?>[]}
        : semanticsTreePayloads.removeAt(0);
    return <String, Object?>{
      'schemaVersion': 1,
      'requestId': requestId ?? 'fake-request',
      'admission': 'accepted',
      'payload': payload,
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
  Future<void> close() async {}
}

Map<String, Object?> _bigTreePayload({int nodeCount = 3000}) =>
    <String, Object?>{
      'outcome': 'observed',
      'treeRevision': 1,
      'nodeCount': nodeCount,
      'nodes': <Object?>[
        for (var i = 0; i < nodeCount; i += 1)
          <String, Object?>{'nodeId': i, 'identifier': 'node-$i-padding-text'},
      ],
    };

final class _Session {
  _Session(this.exitCode, this.out, this.err);
  final int exitCode;
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

void main() {
  late Directory outputDir;

  setUp(() {
    outputDir = Directory.systemTemp.createTempSync('patchbay-repl-outputs-');
  });
  tearDown(() => outputDir.deleteSync(recursive: true));

  Future<_Session> repl(
    List<String> input, {
    required List<String> arguments,
    required _TreeClient client,
  }) async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int code = await runPatchbayCliWithSeams(
      arguments,
      connect: (_) async => client,
      replInput: Stream<String>.fromIterable(input),
      output: out,
      errorOutput: err,
      environment: <String, String>{'PATCHBAY_OUTPUT_DIR': outputDir.path},
    );
    return _Session(code, out.toString(), err.toString());
  }

  group('PB-050-21: --view in repl', () {
    test(
      'session-level --view brief applies to every line by default',
      () async {
        final _TreeClient client = _TreeClient();
        final _Session session = await repl(
          <String>['ui semantics tree'],
          arguments: <String>['--json', '--view', 'brief', 'repl'],
          client: client,
        );

        expect(session.exitCode, PatchbayExitCode.accepted);
        expect(session.envelopes, hasLength(1));
        final Map<String, Object?> response =
            session.envelopes.single['response']! as Map<String, Object?>;
        expect(response.containsKey('localView'), isTrue);
        expect(
          (response['localView']! as Map<String, Object?>)['view'],
          'brief',
        );
      },
    );

    test('a line-level --view full overrides the session default for that '
        'line only', () async {
      final _TreeClient client = _TreeClient();
      final _Session session = await repl(
        <String>[
          'ui semantics tree',
          '--view full ui semantics tree',
          'ui semantics tree',
        ],
        arguments: <String>['--json', '--view', 'brief', 'repl'],
        client: client,
      );

      expect(session.exitCode, PatchbayExitCode.accepted);
      expect(session.envelopes, hasLength(3));
      for (final int index in <int>[0, 2]) {
        final Map<String, Object?> response =
            session.envelopes[index]['response']! as Map<String, Object?>;
        expect(
          response.containsKey('localView'),
          isTrue,
          reason: 'line $index',
        );
      }
      final Map<String, Object?> overridden =
          session.envelopes[1]['response']! as Map<String, Object?>;
      expect(overridden.containsKey('localView'), isFalse);
    });

    test(
      '--view brief on a line requires the session itself to be --json',
      () async {
        final _TreeClient client = _TreeClient();
        final _Session session = await repl(
          <String>['--view brief ui semantics tree'],
          arguments: <String>['repl'],
          client: client,
        );

        expect(session.exitCode, PatchbayExitCode.accepted);
        expect(session.out, contains('exit=${PatchbayExitCode.usage}'));
        expect(session.err, contains('--view brief requires --json'));
      },
    );
  });

  group('PB-050-20: spilling in repl', () {
    test('a line over the threshold spills, and the single-line JSON '
        'contract still holds', () async {
      final _TreeClient client = _TreeClient()
        ..semanticsTreePayloads.add(_bigTreePayload());
      final _Session session = await repl(
        <String>['ui semantics tree'],
        arguments: <String>['--json', 'repl'],
        client: client,
      );

      expect(session.exitCode, PatchbayExitCode.accepted);
      expect(session.lines, hasLength(1));
      final Map<String, Object?> envelope = session.envelopes.single;
      expect(envelope['line'], 1);
      expect(envelope['command'], <String>['ui', 'semantics', 'tree']);
      final Map<String, Object?> response =
          envelope['response']! as Map<String, Object?>;
      expect(response['localArtifact'], isNotNull);
      final String path =
          (response['localArtifact']! as Map<String, Object?>)['path']!
              as String;
      expect(File(path).existsSync(), isTrue);
    });

    test('two spilling lines in the same session both keep their files — '
        'retention never deletes what this run just wrote', () async {
      final _TreeClient client = _TreeClient()
        ..semanticsTreePayloads.addAll(<Map<String, Object?>>[
          _bigTreePayload(nodeCount: 3000),
          _bigTreePayload(nodeCount: 3001),
        ]);
      final _Session session = await repl(
        <String>['ui semantics tree', 'ui semantics tree'],
        arguments: <String>['--json', 'repl'],
        client: client,
      );

      expect(session.exitCode, PatchbayExitCode.accepted);
      final List<String> paths = session.envelopes
          .map(
            (Map<String, Object?> e) =>
                ((e['response']! as Map<String, Object?>)['localArtifact']!
                        as Map<String, Object?>)['path']!
                    as String,
          )
          .toList();
      expect(paths.toSet(), hasLength(2));
      for (final String path in paths) {
        expect(File(path).existsSync(), isTrue);
      }
    });

    test('--max-inline-bytes is overridable per line', () async {
      final _TreeClient client = _TreeClient()
        ..semanticsTreePayloads.addAll(<Map<String, Object?>>[
          _bigTreePayload(),
          _bigTreePayload(),
        ]);
      final _Session session = await repl(
        <String>['ui semantics tree', '--max-inline-bytes 0 ui semantics tree'],
        arguments: <String>['--json', 'repl'],
        client: client,
      );

      expect(session.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> firstResponse =
          session.envelopes[0]['response']! as Map<String, Object?>;
      final Map<String, Object?> secondResponse =
          session.envelopes[1]['response']! as Map<String, Object?>;
      expect(firstResponse['localArtifact'], isNotNull);
      expect(secondResponse.containsKey('localArtifact'), isFalse);
      expect(
        (secondResponse['payload']! as Map<String, Object?>)['nodes'],
        isA<List<Object?>>(),
      );
    });

    test(
      'F6: a malformed per-line --max-inline-bytes fails as usage before '
      'that line ever reaches the App, and the next line still runs',
      () async {
        final _TreeClient client = _TreeClient();
        final _Session session = await repl(
          <String>[
            '--max-inline-bytes not-a-number ui semantics tree',
            'ui semantics tree',
          ],
          arguments: <String>['--json', 'repl'],
          client: client,
        );

        expect(session.exitCode, PatchbayExitCode.accepted);
        expect(session.envelopes[0]['exitCode'], PatchbayExitCode.usage);
        expect(
          session.envelopes[0]['error'],
          contains('--max-inline-bytes must be a non-negative integer'),
        );
        expect(session.envelopes[1]['exitCode'], PatchbayExitCode.accepted);
        // Exactly one RPC went out — the one from the second, well-formed
        // line. The first line's bad ceiling never reached the App.
        expect(client.invokeCount, 1);
      },
    );

    test(
      'human (non-json) repl prints the existing artifact summary line',
      () async {
        final _TreeClient client = _TreeClient()
          ..semanticsTreePayloads.add(_bigTreePayload());
        final _Session session = await repl(
          <String>['ui semantics tree'],
          arguments: <String>['repl'],
          client: client,
        );

        expect(session.exitCode, PatchbayExitCode.accepted);
        expect(
          session.out,
          matches(
            RegExp(r'^\[1\] exit=0 artifact=.+ length=\d+ verified=true\n$'),
          ),
        );
      },
    );

    test(
      'F5: a local artifact write failure fails only that line — the '
      'session keeps consuming lines after it instead of splitting',
      () async {
        // A plain file occupying the exact path the writer would need to
        // create as a directory forces `Directory(...).createSync(recursive:
        // true)` to fail deterministically — this simulates a permission
        // failure or a full disk without depending on either.
        final Directory blockerParent = Directory.systemTemp.createTempSync(
          'patchbay-repl-unwritable-',
        );
        addTearDown(() => blockerParent.deleteSync(recursive: true));
        final File blocker = File('${blockerParent.path}/blocked');
        blocker.createSync();

        // Only the first line's payload is over the spill threshold. The
        // second line falls back to `_TreeClient`'s tiny default payload
        // (empty `nodes`) once the queue is drained — small enough that it
        // never attempts to spill at all, so its success proves the
        // connection (and the RPC round trip) still works rather than
        // merely proving a second write against the same broken directory
        // happened to fail identically.
        final _TreeClient client = _TreeClient()
          ..semanticsTreePayloads.add(_bigTreePayload());
        final StringBuffer out = StringBuffer();
        final StringBuffer err = StringBuffer();
        final int exitCode = await runPatchbayCliWithSeams(
          <String>['--json', 'repl'],
          connect: (_) async => client,
          replInput: Stream<String>.fromIterable(<String>[
            'ui semantics tree',
            'ui semantics tree',
          ]),
          output: out,
          errorOutput: err,
          environment: <String, String>{'PATCHBAY_OUTPUT_DIR': blocker.path},
        );

        final _Session session = _Session(
          exitCode,
          out.toString(),
          err.toString(),
        );
        expect(session.exitCode, PatchbayExitCode.accepted);
        expect(session.lines, hasLength(2));

        final Map<String, Object?> failedLine = session.envelopes[0];
        expect(failedLine['exitCode'], PatchbayExitCode.protocol);
        expect(failedLine['error'], <String, Object?>{
          'code': 'localArtifactWriteFailed',
          'details': <String, Object?>{},
        });

        // The next line runs normally over the same connection: a disk
        // failure says nothing about whether the connection is still good.
        final Map<String, Object?> nextLine = session.envelopes[1];
        expect(nextLine['exitCode'], PatchbayExitCode.accepted);
        final Map<String, Object?> nextResponse =
            nextLine['response']! as Map<String, Object?>;
        expect(nextResponse.containsKey('localArtifact'), isFalse);
        expect(
          (nextResponse['payload']! as Map<String, Object?>)['nodes'],
          isEmpty,
        );
      },
    );
  });
}
