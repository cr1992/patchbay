import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

/// A client whose `ui.semantics.tree` answer the test controls directly, so
/// a repl line can be made to trip the PB-050-20 threshold on demand.
final class _TreeClient implements PatchbayClient {
  final List<Map<String, Object?>> semanticsTreePayloads =
      <Map<String, Object?>>[];

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
    final int code = await runPatchbayCli(
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
  });
}
