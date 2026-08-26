import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// End-to-end coverage for PB-050-20 (tree-artifact spilling) and PB-050-21
/// (`--view brief`) through `runPatchbayCli`, against a fake connection —
/// this is the seam `capture_feature_test.dart` and `repl_test.dart` already
/// use to exercise the real dispatcher rather than a re-implementation of it.
void main() {
  late Directory outputDir;

  setUp(() {
    outputDir = Directory.systemTemp.createTempSync('patchbay-tree-e2e-');
  });
  tearDown(() => outputDir.deleteSync(recursive: true));

  Map<String, Object?> bigSemanticsTreePayload({int nodeCount = 3000}) =>
      <String, Object?>{
        'outcome': 'observed',
        'source': 'uiObserved',
        'treeRevision': 87,
        'rootNodeId': 1,
        'truncated': false,
        'nodeCount': nodeCount,
        'nodes': <Object?>[
          for (var i = 0; i < nodeCount; i += 1)
            <String, Object?>{
              'nodeId': i,
              'identifier': 'semantics-node-$i-with-some-padding-text',
              'rect': <String, Object?>{
                'left': 0,
                'top': i,
                'width': 100,
                'height': 20,
              },
            },
        ],
      };

  FakePatchbayClient semanticsTreeClient(Map<String, Object?> payload) =>
      FakePatchbayClient(
        commands: const <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.semantics.tree'},
        ],
        handle: (String command, Map<String, Object?> arguments) async =>
            fakeAccepted(payload),
      );

  Future<({int exitCode, String out, String err})> run(
    List<String> args,
    FakePatchbayClient client, {
    Map<String, String>? environment,
  }) async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int exitCode = await runPatchbayCli(
      args,
      connect: (_) async => client,
      output: out,
      errorOutput: err,
      environment:
          environment ??
          <String, String>{'PATCHBAY_OUTPUT_DIR': outputDir.path},
    );
    return (exitCode: exitCode, out: out.toString(), err: err.toString());
  }

  group('PB-050-20: automatic spill by default threshold', () {
    test('a response under the default threshold is byte-identical to the '
        'same call with spilling impossible (--max-inline-bytes at a very '
        'high ceiling)', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload(
        nodeCount: 2,
      );
      final result = await run(<String>[
        '--json',
        'ui',
        'semantics',
        'tree',
      ], semanticsTreeClient(payload));
      final neverSpills = await run(<String>[
        '--json',
        '--max-inline-bytes',
        '999999999',
        'ui',
        'semantics',
        'tree',
      ], semanticsTreeClient(payload));

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.out, neverSpills.out);
      expect(result.out, contains('"nodeId": 0'));
      expect(outputDir.listSync(), isEmpty);
    });

    test('a response over the default threshold spills, and the receipt is '
        'independently verifiable on disk', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload();
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final result = await run(<String>[
        '--json',
        'ui',
        'semantics',
        'tree',
      ], client);

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> decoded =
          jsonDecode(result.out) as Map<String, Object?>;
      final Map<String, Object?> responsePayload =
          decoded['payload']! as Map<String, Object?>;
      // Bounded facts stay inline so a caller can act without reading the
      // file back.
      expect(responsePayload['treeRevision'], 87);
      expect(responsePayload['nodeCount'], 3000);
      expect(responsePayload['truncated'], false);

      final Map<String, Object?> nodesReceipt =
          responsePayload['nodes']! as Map<String, Object?>;
      expect(nodesReceipt['origin'], 'cliRendered');
      expect(nodesReceipt.containsKey('blobId'), isFalse);
      expect(nodesReceipt['contentType'], 'application/json');
      expect(nodesReceipt['verified'], true);

      final Map<String, Object?> localArtifact =
          decoded['localArtifact']! as Map<String, Object?>;
      expect(localArtifact, nodesReceipt);

      final File onDisk = File(localArtifact['path']! as String);
      expect(onDisk.existsSync(), isTrue);
      final List<int> bytes = onDisk.readAsBytesSync();
      expect(sha256.convert(bytes).toString(), localArtifact['sha256']);
      expect(bytes.length, localArtifact['length']);
      expect(
        utf8.decode(bytes),
        const JsonEncoder.withIndent('  ').convert(payload['nodes']),
      );

      // Stdout is now well under the threshold — the whole point of the
      // spill.
      expect(utf8.encode(result.out).length, lessThan(65536));
    });

    test('--max-inline-bytes 0 restores the previous unconditional inline '
        'output, byte-identical to a ceiling too high to ever trip', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload();
      final zero = await run(<String>[
        '--json',
        '--max-inline-bytes',
        '0',
        'ui',
        'semantics',
        'tree',
      ], semanticsTreeClient(payload));
      final neverSpills = await run(<String>[
        '--json',
        '--max-inline-bytes',
        '999999999',
        'ui',
        'semantics',
        'tree',
      ], semanticsTreeClient(payload));

      expect(zero.exitCode, PatchbayExitCode.accepted);
      expect(zero.out, neverSpills.out);
      expect(zero.out, contains('"nodeId": 0'));
      expect(outputDir.listSync(), isEmpty);
    });

    test(
      'an explicit --output always spills, even under the inline ceiling',
      () async {
        final Map<String, Object?> payload = bigSemanticsTreePayload(
          nodeCount: 1,
        );
        final FakePatchbayClient client = semanticsTreeClient(payload);
        final File target = File('${outputDir.path}/explicit-nodes.json');
        final result = await run(<String>[
          '--json',
          '--output',
          target.path,
          'ui',
          'semantics',
          'tree',
        ], client);

        expect(result.exitCode, PatchbayExitCode.accepted);
        expect(target.existsSync(), isTrue);
        final Map<String, Object?> decoded =
            jsonDecode(result.out) as Map<String, Object?>;
        expect(
          (decoded['localArtifact']! as Map<String, Object?>)['path'],
          target.path,
        );
      },
    );

    test('--output on an existing path without --force fails with the '
        'existing artifact-download wording', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload(
        nodeCount: 1,
      );
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final File target = File('${outputDir.path}/exists.json')
        ..writeAsStringSync('keep');
      final result = await run(<String>[
        '--json',
        '--output',
        target.path,
        'ui',
        'semantics',
        'tree',
      ], client);

      // A bare `FormatException`, exactly like the existing blob-download
      // path (`artifact_download_test.dart`), so it is a usage error (64)
      // rather than a protocol failure.
      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('--output already exists; use --force'));
      expect(target.readAsStringSync(), 'keep');
    });

    test('a typed-failure response never spills, however large', () async {
      final Map<String, Object?> payload = <String, Object?>{
        ...bigSemanticsTreePayload(),
        'outcome': 'failed',
      };
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final result = await run(<String>[
        '--json',
        'ui',
        'semantics',
        'tree',
      ], client);

      expect(result.exitCode, PatchbayExitCode.typedFailure);
      expect(outputDir.listSync(), isEmpty);
      final Map<String, Object?> decoded =
          jsonDecode(result.out) as Map<String, Object?>;
      expect(
        ((decoded['payload']! as Map<String, Object?>)['nodes']! as List)
            .length,
        3000,
      );
    });

    test('a non-covered command still refuses --output with the existing '
        'wording', () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fakeCommandNotRegistered(),
      );
      final result = await run(<String>[
        '--json',
        '--output',
        '${outputDir.path}/x.json',
        'identity',
      ], client);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('--output is not valid for identity'));
    });

    test('the diagnostic-tree text passthroughs spill as decoded text, not '
        'a JSON string', () async {
      final String dump = 'FocusManager\n  primaryFocus: rootScope\n' * 4000;
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fakeCommandNotRegistered(),
        focusTreeHandler: () async => <String, Object?>{
          'source': 'uiObserved',
          'plane': 'flutterDiagnostic',
          'schema': 'flutterSdkPassthrough',
          'extension': 'ext.flutter.debugDumpFocusTree',
          'format': 'flutterFocusDumpText',
          'data': dump,
          'warnings': const <String>[
            'Flutter diagnostic fields may change with the Flutter SDK.',
          ],
        },
      );
      final result = await run(<String>['--json', 'ui', 'focus-tree'], client);

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> decoded =
          jsonDecode(result.out) as Map<String, Object?>;
      final Map<String, Object?> receipt =
          decoded['data']! as Map<String, Object?>;
      expect(receipt['contentType'], 'text/plain; charset=utf-8');
      final File onDisk = File(receipt['path']! as String);
      expect(onDisk.readAsStringSync(), dump);
    });

    test('human-readable output prints the existing artifact summary line '
        'unchanged', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload();
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final result = await run(<String>['ui', 'semantics', 'tree'], client);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(
        result.out,
        matches(RegExp(r'^artifact=.+ length=\d+ verified=true\n$')),
      );
    });
  });

  group('PB-050-20: the spilled artifact joins the active trace', () {
    late Directory traceSandbox;

    setUp(() {
      traceSandbox = Directory.systemTemp.createTempSync(
        'patchbay-tree-trace-',
      );
    });
    tearDown(() => traceSandbox.deleteSync(recursive: true));

    test('a cliRendered spill is attached, content-addressed, and lands '
        'inside the run that produced it', () async {
      final PatchbayTraceStore store = PatchbayTraceStore(traceSandbox.path);
      final PatchbayTraceManifest trace = store.start(
        name: 'spill',
        cliVersion: 'test',
        activate: true,
      );
      final result = await run(<String>[
        '--trace-dir',
        store.root.path,
        '--json',
        'ui',
        'semantics',
        'tree',
      ], semanticsTreeClient(bigSemanticsTreePayload()));

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> localArtifact =
          (jsonDecode(result.out) as Map<String, Object?>)['localArtifact']!
              as Map<String, Object?>;

      final List<PatchbayTraceEvent> events = store.read(trace.traceId).events;
      final List<String> types = <String>[
        for (final PatchbayTraceEvent event in events) event.type,
      ];
      expect(
        types,
        contains('artifact.attached'),
        reason:
            'a trace taken over a spilling session would otherwise lose the '
            'only copy of what the command observed',
      );
      expect(
        types.indexOf('artifact.attached'),
        lessThan(types.indexOf('command.finished')),
        reason: 'the attachment belongs to the run that produced it',
      );

      final PatchbayTraceEvent attached = events.singleWhere(
        (PatchbayTraceEvent event) => event.type == 'artifact.attached',
      );
      expect(attached.payload['sha256'], localArtifact['sha256']);
      expect(attached.payload['length'], localArtifact['length']);
      expect(attached.payload['contentType'], 'application/json');
      expect(
        attached.payload.containsKey('blobId'),
        isFalse,
        reason: 'a cliRendered member has no host blob to name',
      );
      expect(
        File(
          '${store.root.path}/${trace.traceId}/'
          '${attached.payload['relativePath']}',
        ).readAsStringSync(),
        File(localArtifact['path']! as String).readAsStringSync(),
      );
    });

    test('a repl line attaches before its own command.finished, not after '
        'it', () async {
      final PatchbayTraceStore store = PatchbayTraceStore(traceSandbox.path);
      final PatchbayTraceManifest trace = store.start(
        name: 'repl-spill',
        cliVersion: 'test',
        activate: true,
      );
      final StringBuffer out = StringBuffer();
      final int exitCode = await runPatchbayCli(
        <String>['--trace-dir', store.root.path, '--json', 'repl'],
        connect: (_) async => semanticsTreeClient(bigSemanticsTreePayload()),
        replInput: Stream<String>.fromIterable(<String>['ui semantics tree']),
        output: out,
        errorOutput: StringBuffer(),
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': outputDir.path},
      );

      expect(exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> response =
          (jsonDecode(out.toString().trim())
                  as Map<String, Object?>)['response']!
              as Map<String, Object?>;
      final Map<String, Object?> localArtifact =
          response['localArtifact']! as Map<String, Object?>;

      final List<String> types = <String>[
        for (final PatchbayTraceEvent event in store.read(trace.traceId).events)
          event.type,
      ];
      // Spilling happens at render time, which is after the line's `execute`
      // returned. Closing the run inside `execute` put `command.finished`
      // first, so the attachment read as the first thing the *next* line did.
      expect(
        types.indexOf('artifact.attached'),
        allOf(
          greaterThan(types.indexOf('command.started')),
          lessThan(types.indexOf('command.finished')),
        ),
      );
      final PatchbayTraceEvent attached = store
          .read(trace.traceId)
          .events
          .singleWhere(
            (PatchbayTraceEvent event) => event.type == 'artifact.attached',
          );
      expect(attached.payload['sha256'], localArtifact['sha256']);
    });

    test('a line that spills nothing still closes its own run', () async {
      // The run-closing step moved out of `execute` and into the session's
      // post-render callback; a line with no artifact must still produce one
      // `command.finished`, and the next line must get its own.
      final PatchbayTraceStore store = PatchbayTraceStore(traceSandbox.path);
      final PatchbayTraceManifest trace = store.start(
        name: 'repl-plain',
        cliVersion: 'test',
        activate: true,
      );
      final int exitCode = await runPatchbayCli(
        <String>['--trace-dir', store.root.path, '--json', 'repl'],
        connect: (_) async =>
            semanticsTreeClient(bigSemanticsTreePayload(nodeCount: 1)),
        replInput: Stream<String>.fromIterable(<String>[
          'ui semantics tree',
          'ui semantics tree',
        ]),
        output: StringBuffer(),
        errorOutput: StringBuffer(),
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': outputDir.path},
      );

      expect(exitCode, PatchbayExitCode.accepted);
      final List<PatchbayTraceEvent> events = store.read(trace.traceId).events;
      List<Object?> runIdsOf(String type) => <Object?>[
        for (final PatchbayTraceEvent event in events)
          if (event.type == type) event.payload['commandRunId'],
      ];
      final List<Object?> started = runIdsOf('command.started');
      final List<Object?> finished = runIdsOf('command.finished');

      expect(
        started,
        hasLength(3),
        reason: 'the `repl` invocation itself, plus one run per line',
      );
      expect(
        finished.toSet(),
        started.toSet(),
        reason: 'every run that opened was closed',
      );
      expect(
        finished,
        hasLength(started.length),
        reason: 'and none of them was closed twice',
      );
      expect(
        events.where(
          (PatchbayTraceEvent event) => event.type == 'artifact.attached',
        ),
        isEmpty,
      );
    });
  });

  group('PB-050-21: --view brief', () {
    test('--view brief requires --json', () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fakeCommandNotRegistered(),
      );
      final result = await run(<String>['--view', 'brief', 'identity'], client);

      expect(result.exitCode, PatchbayExitCode.usage);
      expect(result.err, contains('--view brief requires --json'));
    });

    test('--view full without --view is byte-identical to no --view flag '
        'at all', () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fakeCommandNotRegistered(),
      );
      final withDefault = await run(<String>['--json', 'identity'], client);
      final withExplicitFull = await run(<String>[
        '--json',
        '--view',
        'full',
        'identity',
      ], client);

      expect(withExplicitFull.out, withDefault.out);
      expect(withDefault.out, isNot(contains('localView')));
    });

    test('--json --view brief on ui semantics tree elides nodes and lists it '
        'in localView.omitted', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload(
        nodeCount: 2,
      );
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final result = await run(<String>[
        '--json',
        '--view',
        'brief',
        'ui',
        'semantics',
        'tree',
      ], client);

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> decoded =
          jsonDecode(result.out) as Map<String, Object?>;
      final Map<String, Object?> responsePayload =
          decoded['payload']! as Map<String, Object?>;
      expect(responsePayload.containsKey('nodes'), isFalse);
      expect(responsePayload['nodeCount'], 2);
      final Map<String, Object?> localView =
          decoded['localView']! as Map<String, Object?>;
      expect(localView['view'], 'brief');
      expect(localView['projection'], 'ui.semantics.tree');
      expect(localView['omitted'], contains(r'$.payload.nodes'));
    });

    test('PB-050-20 then PB-050-21: past the threshold, brief keeps the '
        'artifact pointer and does not claim to have omitted an already-gone '
        'field', () async {
      final Map<String, Object?> payload = bigSemanticsTreePayload();
      final FakePatchbayClient client = semanticsTreeClient(payload);
      final result = await run(<String>[
        '--json',
        '--view',
        'brief',
        'ui',
        'semantics',
        'tree',
      ], client);

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> decoded =
          jsonDecode(result.out) as Map<String, Object?>;
      expect(decoded['localArtifact'], isNotNull);
      final Map<String, Object?> responsePayload =
          decoded['payload']! as Map<String, Object?>;
      expect(
        responsePayload['nodes'],
        isA<Map<String, Object?>>(),
        reason:
            'the artifact receipt, not the elided value and not the '
            'raw tree',
      );
      final Map<String, Object?> localView =
          decoded['localView']! as Map<String, Object?>;
      expect(
        localView['omitted'],
        isNot(contains(r'$.payload.nodes')),
        reason:
            'nodes is already gone from the document (spilled), so '
            'brief must not also report deleting it',
      );
    });
  });
}
