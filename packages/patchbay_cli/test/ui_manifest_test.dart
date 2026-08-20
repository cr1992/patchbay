import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// One catalog row, built by the same descriptor a real host publishes.
///
/// Hand-writing the JSON here would make the fixture a second opinion about the
/// wire shape, free to stay green while the contract moved.
Map<String, Object?> _target(
  String id, {
  PatchbayUiTargetKind kind = PatchbayUiTargetKind.text,
  bool mounted = true,
  bool sensitive = false,
  bool ambiguous = false,
  int generation = 1,
}) => PatchbayUiTargetDescriptor(
  id: id,
  generation: generation,
  kind: kind,
  mounted: mounted,
  ambiguous: ambiguous,
  operations: const <PatchbayUiOperation>{},
  operationGates: const <PatchbayUiOperation, Set<String>>{},
  sensitivePolicy: sensitive
      ? PatchbaySensitivePolicy.redacted
      : PatchbaySensitivePolicy.public,
  sideEffect: PatchbaySideEffect.appState,
).toJson();

Map<String, Object?> _semanticsNode(
  int nodeId, {
  required int generation,
  required String identifier,
  int? parentNodeId,
  int depth = 0,
  List<int> children = const <int>[],
}) => <String, Object?>{
  'nodeId': nodeId,
  'generation': generation,
  'parentNodeId': parentNodeId,
  'depth': depth,
  'identifier': identifier,
  'label': '',
  'flags': <Object?>[],
  'actions': <Object?>[],
  'invisible': false,
  'userActionsBlocked': false,
  'rect': <String, Object?>{'left': 0, 'top': 0, 'width': 1, 'height': 1},
  'rectCoordinateSpace': 'globalLogicalPixels',
  'children': children,
};

Map<String, Object?> _semanticsPayload(
  List<Map<String, Object?>> nodes, {
  int treeRevision = 1,
  bool truncated = false,
}) => <String, Object?>{
  'outcome': 'observed',
  'source': 'uiObserved',
  'treeRevision': treeRevision,
  'rootNodeId': nodes.isEmpty ? 0 : nodes.first['nodeId'],
  'truncated': truncated,
  'nodeCount': nodes.length,
  'nodes': nodes,
};

/// A client whose catalog carries [uiTargets] and whose `navigation.current`
/// reports [destination].
FakePatchbayClient _client({
  List<Object?> uiTargets = const <Object?>[],
  String? destination,
  bool navigationCataloged = true,
  Map<String, Object?>? navigationResponse,
  Map<String, Object?>? semanticsPayload,
}) => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    if (navigationCataloged)
      const <String, Object?>{'name': 'navigation.current'},
    if (semanticsPayload != null)
      const <String, Object?>{'name': 'ui.semantics.tree'},
  ],
  uiTargets: uiTargets,
  handle: (String command, Map<String, Object?> arguments) async {
    if (command == 'ui.semantics.tree' && semanticsPayload != null) {
      return fakeAccepted(semanticsPayload);
    }
    // A host that does not catalog the command answers the same way for it as
    // for any other name it never registered.
    if (command != 'navigation.current' || !navigationCataloged) {
      return fakeCommandNotRegistered();
    }
    return navigationResponse ??
        fakeAccepted(<String, Object?>{
          'outcome': 'observed',
          'source': 'appRecorded',
          'navigationRevision': 3,
          'destinationId': destination,
        });
  },
);

typedef CliRun = ({int exitCode, String stdout, String stderr});

/// Runs one `ui verify-manifest` against [client] with [manifest] on disk.
Future<CliRun> _run(
  FakePatchbayClient client,
  String manifest, {
  bool json = true,
  String extension = '.json',
}) async {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-manifest',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final File file = File('${directory.path}/targets$extension')
    ..writeAsStringSync(manifest);
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    <String>[if (json) '--json', 'ui', 'verify-manifest', file.path],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, stdout: out.toString(), stderr: err.toString());
}

Future<CliRun> _emit(FakePatchbayClient client, {bool json = true}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    <String>[if (json) '--json', 'ui', 'targets', '--emit-manifest'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, stdout: out.toString(), stderr: err.toString());
}

Map<String, Object?> _report(CliRun run) =>
    jsonDecode(run.stdout) as Map<String, Object?>;

List<Object?> _group(CliRun run, String name) =>
    _report(run)[name]! as List<Object?>;

Map<String, Object?> _stats(CliRun run) =>
    _report(run)['stats']! as Map<String, Object?>;

/// The example the guide points at, located from wherever the runner started.
File _exampleManifest() {
  Directory directory = Directory.current.absolute;
  while (true) {
    final File candidate = File(
      '${directory.path}/docs/examples/ui-targets-manifest.json',
    );
    if (candidate.existsSync()) return candidate;
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      fail('docs/examples/ui-targets-manifest.json was not found');
    }
    directory = parent;
  }
}

void main() {
  group('live manifest emission', () {
    test('emits a stable v2 draft for only mounted targets', () async {
      final FakePatchbayClient client = _client(
        destination: 'settings',
        uiTargets: <Object?>[
          _target('settings.zeta', sensitive: true),
          _target('settings.hidden', mounted: false),
          _target('settings.alpha', kind: PatchbayUiTargetKind.capture),
        ],
      );

      final CliRun first = await _emit(client);
      final CliRun second = await _emit(client);

      expect(first.exitCode, PatchbayExitCode.accepted, reason: first.stderr);
      expect(second.stdout, first.stdout);
      expect(_report(first), <String, Object?>{
        'version': 2,
        'coverage': 'mountedOnly',
        'destinations': <Object?>[
          <String, Object?>{
            'id': 'settings',
            'targets': <Object?>[
              <String, Object?>{
                'namespace': 'catalogTarget',
                'id': 'settings.alpha',
                'kind': 'capture',
                'sensitive': false,
              },
              <String, Object?>{
                'namespace': 'catalogTarget',
                'id': 'settings.zeta',
                'kind': 'text',
                'sensitive': true,
              },
            ],
          },
        ],
      });
    });

    test('the emitted draft can be fed directly to verification', () async {
      final FakePatchbayClient client = _client(
        destination: 'login',
        uiTargets: <Object?>[
          _target('login.submit'),
          _target('login.password', sensitive: true),
        ],
      );
      final CliRun emitted = await _emit(client);

      final CliRun verified = await _run(client, emitted.stdout);

      expect(verified.exitCode, PatchbayExitCode.accepted);
      expect(_stats(verified)['checked'], 2);
      expect(_report(verified)['destination'], 'login');
    });

    test('human mode still prints the editable JSON document', () async {
      final CliRun run = await _emit(
        _client(destination: 'login'),
        json: false,
      );

      expect(run.exitCode, PatchbayExitCode.accepted);
      expect(jsonDecode(run.stdout), containsPair('version', 2));
      expect(run.stdout, contains('\n  "coverage": "mountedOnly"'));
    });

    test('refuses to invent a destination for the draft', () async {
      final CliRun run = await _emit(_client());

      expect(run.exitCode, PatchbayExitCode.protocol);
      final Map<String, Object?> error =
          _report(run)['error']! as Map<String, Object?>;
      expect(error['code'], 'manifestDestinationUnavailable');
    });

    test('a missing navigation capability stays a catalog refusal', () async {
      final CliRun run = await _emit(_client(navigationCataloged: false));

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(_report(run)['destinationSource'], 'navigation.current');
      expect(_report(run)['admission'], 'rejected');
    });

    test('v2 refuses unknown namespaces', () {
      expect(
        () => PatchbayUiManifest.parse(
          '{"version":2,"coverage":"mountedOnly","destinations":['
          '{"id":"login","targets":[{"namespace":"futureNamespace",'
          '"id":"login.submit"}]}]}',
        ),
        throwsA(
          isA<PatchbayUiManifestException>().having(
            (PatchbayUiManifestException error) => error.details['field'],
            'field',
            r'$.destinations[0].targets[0].namespace',
          ),
        ),
      );
    });
  });

  group('JSON and safe YAML input', () {
    test('v1 and v2 normalize to the same manifest model', () {
      for (final (String jsonDocument, String yamlDocument)
          in <(String, String)>[
            (
              '{"version":1,"targets":[{"id":"login.submit",'
                  '"kind":"text","sensitive":false}]}',
              'version: 1\ntargets:\n'
                  '  - id: login.submit\n'
                  '    kind: text\n'
                  '    sensitive: false\n',
            ),
            (
              '{"version":2,"coverage":"mountedOnly","destinations":['
                  '{"id":"login","targets":[{"namespace":"catalogTarget",'
                  '"id":"login.submit","kind":"text","sensitive":false}]}]}',
              'version: 2\ncoverage: mountedOnly\ndestinations:\n'
                  '  - id: login\n'
                  '    targets:\n'
                  '      - namespace: catalogTarget\n'
                  '        id: login.submit\n'
                  '        kind: text\n'
                  '        sensitive: false\n',
            ),
          ]) {
        final PatchbayUiManifest jsonManifest = PatchbayUiManifest.parseSource(
          jsonDocument,
          format: PatchbayUiManifestFormat.json,
        );
        final PatchbayUiManifest yamlManifest = PatchbayUiManifest.parseSource(
          yamlDocument,
          format: PatchbayUiManifestFormat.yaml,
        );

        expect(
          yamlManifest.entries.map((entry) => entry.toJson()),
          jsonManifest.entries.map((entry) => entry.toJson()),
        );
      }
    });

    test('.yaml and .yml select YAML without content guessing', () async {
      const String manifest =
          'version: 1\ntargets:\n  - id: login.submit\n    kind: text\n';
      for (final String extension in <String>['.yaml', '.yml']) {
        final CliRun run = await _run(
          _client(uiTargets: <Object?>[_target('login.submit')]),
          manifest,
          extension: extension,
        );
        expect(run.exitCode, PatchbayExitCode.accepted, reason: extension);
      }
    });

    test('unknown extension fails closed before dialing', () async {
      final FakePatchbayClient client = _client();
      final CliRun run = await _run(
        client,
        '{"targets":[]}',
        extension: '.txt',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      expect(
        (_report(run)['error']! as Map<String, Object?>)['code'],
        'manifestFormatUnsupported',
      );
      expect(client.catalogReads, 0);
    });

    test(
      'YAML syntax error reports one-based location without content',
      () async {
        const String secret = 'secret-target-value';
        final CliRun run = await _run(
          _client(),
          'version: 1\ntargets:\n  - id: $secret\n    kind: [\n',
          extension: '.yaml',
        );

        expect(run.exitCode, PatchbayExitCode.usage);
        final Map<String, Object?> error =
            _report(run)['error']! as Map<String, Object?>;
        expect(error['code'], 'manifestInvalid');
        final Map<String, Object?> details =
            error['details']! as Map<String, Object?>;
        expect(details['line'], isA<int>());
        expect(details['column'], isA<int>());
        expect(jsonEncode(error), isNot(contains(secret)));
        expect(run.stderr, isNot(contains(secret)));
      },
    );

    test('aliases, including an expansion bomb, are refused', () async {
      final CliRun run = await _run(
        _client(),
        'version: 1\n'
        'seed: &seed {id: login.submit, kind: text}\n'
        'targets: [*seed, *seed, *seed, *seed]\n',
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          ((_report(run)['error']! as Map<String, Object?>)['details']!
              as Map<String, Object?>);
      expect(details['reason'], 'YAML aliases are not supported');
      expect(details['line'], isA<int>());
      expect(details['column'], isA<int>());
    });

    test(
      'unknown custom tags are refused without echoing their value',
      () async {
        const String secret = 'private-tag-payload';
        final CliRun run = await _run(
          _client(),
          'version: 1\ntargets:\n  - id: !private $secret\n    kind: text\n',
          extension: '.yaml',
        );

        expect(run.exitCode, PatchbayExitCode.usage);
        final Map<String, Object?> error =
            _report(run)['error']! as Map<String, Object?>;
        final Map<String, Object?> details =
            error['details']! as Map<String, Object?>;
        expect(error['code'], 'manifestInvalid');
        expect(details['line'], isA<int>());
        expect(details['column'], isA<int>());
        expect(jsonEncode(error), isNot(contains(secret)));
      },
    );

    test('duplicate YAML mapping keys fail at the second key', () async {
      final CliRun run = await _run(
        _client(),
        'version: 1\ntargets: []\ntargets: []\n',
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          _report(run)['error']! as Map<String, Object?>;
      final Map<String, Object?> details =
          error['details']! as Map<String, Object?>;
      expect(error['code'], 'manifestInvalid');
      expect(details['reason'], 'YAML mapping keys must be unique');
      expect(details['line'], 3);
      expect(details['column'], 1);
    });

    test('depth and node budgets fail before schema interpretation', () {
      final String deep =
          'value: ${List<String>.filled(patchbayUiManifestMaximumDepth, '[').join()}'
          '0${List<String>.filled(patchbayUiManifestMaximumDepth, ']').join()}';
      expect(
        () => PatchbayUiManifest.parseSource(
          deep,
          format: PatchbayUiManifestFormat.yaml,
        ),
        throwsA(
          isA<PatchbayUiManifestException>()
              .having((error) => error.code, 'code', 'manifestResourceLimit')
              .having(
                (error) => error.details['reason'],
                'reason',
                'manifest depth limit exceeded',
              ),
        ),
      );

      final String manyNodes =
          'values: [${List<String>.filled(patchbayUiManifestMaximumNodes, '0').join(',')}]';
      expect(
        () => PatchbayUiManifest.parseSource(
          manyNodes,
          format: PatchbayUiManifestFormat.yaml,
        ),
        throwsA(
          isA<PatchbayUiManifestException>()
              .having((error) => error.code, 'code', 'manifestResourceLimit')
              .having(
                (error) => error.details['reason'],
                'reason',
                'manifest node limit exceeded',
              ),
        ),
      );
    });

    test('mapping keys count toward the YAML node budget', () {
      final int keyCount = patchbayUiManifestMaximumNodes ~/ 2 + 10;
      final String entries = List<String>.generate(
        keyCount,
        (int index) => 'k${index.toRadixString(36)}:0',
      ).join(',');

      expect(
        () => PatchbayUiManifest.parseSource(
          'values: {$entries}',
          format: PatchbayUiManifestFormat.yaml,
        ),
        throwsA(
          isA<PatchbayUiManifestException>()
              .having((error) => error.code, 'code', 'manifestResourceLimit')
              .having(
                (error) => error.details['reason'],
                'reason',
                'manifest node limit exceeded',
              ),
        ),
      );
    });

    test('byte budget is checked before parsing', () async {
      final CliRun run = await _run(
        _client(),
        List<String>.filled(patchbayUiManifestMaximumBytes + 1, 'x').join(),
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      expect(
        (_report(run)['error']! as Map<String, Object?>)['code'],
        'manifestResourceLimit',
      );
    });

    test('schema collection budgets apply after either decoder', () {
      void expectLimit(Map<String, Object?> document, String reason) {
        expect(
          () => PatchbayUiManifest.parse(jsonEncode(document)),
          throwsA(
            isA<PatchbayUiManifestException>()
                .having((error) => error.code, 'code', 'manifestResourceLimit')
                .having((error) => error.details['reason'], 'reason', reason),
          ),
        );
      }

      expectLimit(<String, Object?>{
        'version': 2,
        'coverage': 'mountedOnly',
        'destinations': <Object?>[
          for (
            var index = 0;
            index <= patchbayUiManifestMaximumDestinations;
            index += 1
          )
            <String, Object?>{'id': 'screen-$index', 'targets': <Object?>[]},
        ],
      }, 'manifest destination limit exceeded');

      expectLimit(<String, Object?>{
        'version': 2,
        'coverage': 'mountedOnly',
        'destinations': <Object?>[
          <String, Object?>{
            'id': 'screen',
            'targets': <Object?>[
              for (
                var index = 0;
                index <= patchbayUiManifestMaximumTargetsPerDestination;
                index += 1
              )
                <String, Object?>{
                  'namespace': 'catalogTarget',
                  'id': 'screen.target-$index',
                  'kind': 'text',
                },
            ],
          },
        ],
      }, 'manifest per-destination target limit exceeded');

      expectLimit(<String, Object?>{
        'version': 2,
        'coverage': 'mountedOnly',
        'destinations': <Object?>[
          for (var screen = 0; screen < 11; screen += 1)
            <String, Object?>{
              'id': 'screen-$screen',
              'targets': <Object?>[
                for (var target = 0; target < 1000; target += 1)
                  <String, Object?>{
                    'namespace': 'catalogTarget',
                    'id': 'screen-$screen.target-$target',
                    'kind': 'text',
                  },
              ],
            },
        ],
      }, 'manifest target limit exceeded');
    });
  });

  group('semanticsIdentifier manifest namespace', () {
    const String semanticsManifest =
        '{"version":2,"coverage":"mountedOnly","destinations":['
        '{"id":"login","targets":[{"namespace":"semanticsIdentifier",'
        '"id":"login.submit"}]}]}';

    test('v2 keeps semantics fields independent from catalog kind', () {
      final PatchbayUiManifest manifest = PatchbayUiManifest.parse(
        semanticsManifest,
      );

      expect(manifest.entries, isEmpty);
      expect(manifest.semanticsEntries.single.id, 'login.submit');

      for (final String forbidden in <String>[
        '"kind":"text"',
        '"sensitive":false',
      ]) {
        expect(
          () => PatchbayUiManifest.parse(
            semanticsManifest.replaceFirst(
              '"id":"login.submit"',
              '"id":"login.submit",$forbidden',
            ),
          ),
          throwsA(
            isA<PatchbayUiManifestException>().having(
              (error) => error.code,
              'code',
              'manifestInvalid',
            ),
          ),
        );
      }
    });

    test(
      'v1 remains catalog-only even when the App exposes Semantics',
      () async {
        final FakePatchbayClient client = _client(
          uiTargets: <Object?>[_target('login.title')],
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(4, generation: 2, identifier: 'login.title'),
          ]),
        );

        final CliRun run = await _run(
          client,
          '{"version":1,"targets":['
          '{"id":"login.title","kind":"text","sensitive":false}]}',
        );

        expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
        expect(client.calls, isEmpty);
        expect(_report(run).containsKey('semantics'), isFalse);
      },
    );

    test('unknown and cross-namespace ids fail closed', () {
      expect(
        () => PatchbayUiManifest.parse(
          semanticsManifest.replaceFirst(
            'semanticsIdentifier',
            'unknownNamespace',
          ),
        ),
        throwsA(
          isA<PatchbayUiManifestException>().having(
            (error) => error.code,
            'code',
            'manifestInvalid',
          ),
        ),
      );
      expect(
        () => PatchbayUiManifest.parse(
          '{"version":2,"coverage":"mountedOnly","destinations":['
          '{"id":"login","targets":[{"namespace":"catalogTarget",'
          '"id":"shared","kind":"text"}]},'
          '{"id":"settings","targets":['
          '{"namespace":"semanticsIdentifier","id":"shared"}]}]}',
        ),
        throwsA(
          isA<PatchbayUiManifestException>()
              .having((error) => error.code, 'code', 'manifestInvalid')
              .having(
                (error) => error.details['reason'],
                'reason',
                'a target id cannot cross manifest namespaces',
              ),
        ),
      );
    });

    test('nested identifiers retain generation and tree fact source', () async {
      final CliRun run = await _run(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(
              1,
              generation: 1,
              identifier: '',
              children: const <int>[2],
            ),
            _semanticsNode(
              2,
              generation: 7,
              identifier: 'login.submit',
              parentNodeId: 1,
              depth: 1,
            ),
          ], treeRevision: 9),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      final Map<String, Object?> semantics =
          _report(run)['semantics']! as Map<String, Object?>;
      expect(semantics['command'], 'ui.semantics.tree');
      expect(semantics['source'], 'uiObserved');
      expect(semantics['treeRevision'], 9);
      expect(
        (semantics['observed']! as List<Object?>).single,
        containsPair('generation', 7),
      );
    });

    test('an unmounted identifier is a manifest deviation', () async {
      final CliRun run = await _run(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(const <Map<String, Object?>>[]),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      final Map<String, Object?> missing =
          (_group(run, 'declaredNotMounted').single as Map<String, Object?>);
      expect(missing['namespace'], 'semanticsIdentifier');
      expect(missing['runtime'], 'unmounted');
      expect(missing['code'], 'uiSemanticsIdentifierNotFound');
    });

    test('duplicate live identifiers fail closed with a stable code', () async {
      final CliRun run = await _run(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(1, generation: 2, identifier: 'login.submit'),
            _semanticsNode(2, generation: 3, identifier: 'login.submit'),
          ]),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      final Map<String, Object?> semantics =
          _report(run)['semantics']! as Map<String, Object?>;
      final Map<String, Object?> ambiguity =
          (semantics['identifierAmbiguous']! as List<Object?>).single
              as Map<String, Object?>;
      expect(ambiguity['code'], 'uiSemanticsIdentifierAmbiguous');
      expect(ambiguity['matchCount'], 2);
    });

    test('replacement generation comes only from each live snapshot', () {
      int observedGeneration(Map<String, Object?> payload) {
        final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
          manifest: PatchbayUiManifest.parse(semanticsManifest),
          runtime: const <PatchbayUiTargetDescriptorWire>[],
          currentDestination: 'login',
          semantics: decodePatchbayManifestSemantics(payload),
        );
        return report.semanticsObserved.single.match.generation;
      }

      expect(
        observedGeneration(
          _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(8, generation: 1, identifier: 'login.submit'),
          ], treeRevision: 4),
        ),
        1,
      );
      expect(
        observedGeneration(
          _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(12, generation: 2, identifier: 'login.submit'),
          ], treeRevision: 5),
        ),
        2,
      );
    });

    test('catalog and semantics namespaces reconcile independently', () async {
      final CliRun run = await _run(
        _client(
          destination: 'login',
          uiTargets: <Object?>[_target('login.title')],
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(3, generation: 4, identifier: 'login.submit'),
          ]),
        ),
        '{"version":2,"coverage":"mountedOnly","destinations":['
        '{"id":"login","targets":[{"namespace":"catalogTarget",'
        '"id":"login.title","kind":"text","sensitive":false},'
        '{"namespace":"semanticsIdentifier","id":"login.submit"}]}]}',
      );

      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(_group(run, 'declaredNotMounted'), isEmpty);
      expect(_group(run, 'mountedNotDeclared'), isEmpty);
    });

    test(
      'missing Semantics capability is explicit and never guessed',
      () async {
        final CliRun run = await _run(
          _client(destination: 'login'),
          semanticsManifest,
        );

        expect(run.exitCode, PatchbayExitCode.protocol);
        expect(
          (_report(run)['error']! as Map<String, Object?>)['code'],
          'manifestSemanticsUnavailable',
        );
      },
    );

    test('a truncated tree cannot prove identifier absence', () async {
      final CliRun run = await _run(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(
            const <Map<String, Object?>>[],
            truncated: true,
          ),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(
        (_report(run)['error']! as Map<String, Object?>)['code'],
        'manifestSemanticsTreeTruncated',
      );
    });

    test('live emission includes only unique attached identifiers', () async {
      final CliRun run = await _emit(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(2, generation: 6, identifier: 'login.submit'),
          ]),
        ),
      );

      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      final List<Object?> targets =
          (((_report(run)['destinations']! as List<Object?>).single
                  as Map<String, Object?>)['targets']!
              as List<Object?>);
      expect(targets.single, <String, Object?>{
        'namespace': 'semanticsIdentifier',
        'id': 'login.submit',
      });
    });

    test('live emission refuses an ambiguous identifier draft', () async {
      final CliRun run = await _emit(
        _client(
          destination: 'login',
          semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
            _semanticsNode(2, generation: 1, identifier: 'login.submit'),
            _semanticsNode(3, generation: 2, identifier: 'login.submit'),
          ]),
        ),
      );

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(
        (_report(run)['error']! as Map<String, Object?>)['code'],
        'manifestSemanticsIdentifierAmbiguous',
      );
    });

    test(
      'live emission refuses a cross-namespace identifier conflict draft',
      () async {
        final CliRun run = await _emit(
          _client(
            destination: 'login',
            uiTargets: <Object?>[_target('login.submit')],
            semanticsPayload: _semanticsPayload(<Map<String, Object?>>[
              _semanticsNode(2, generation: 1, identifier: 'login.submit'),
            ]),
          ),
        );

        expect(run.exitCode, PatchbayExitCode.protocol);
        expect(
          (_report(run)['error']! as Map<String, Object?>)['code'],
          'manifestNamespaceConflict',
        );
      },
    );
  });

  group('manifest parsing is fail-closed', () {
    test('a file that is not JSON names the syntax failure', () async {
      final CliRun run = await _run(_client(), 'targets: []');
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          _report(run)['error']! as Map<String, Object?>;
      expect(error['code'], 'manifestInvalid');
      final Map<String, Object?> details =
          error['details']! as Map<String, Object?>;
      expect(details['reason'], contains('not valid JSON'));
      expect(details['line'], 1);
      expect(details['column'], isA<int>());
      expect(run.stderr, contains('patchbay manifest error: manifestInvalid'));
    });

    test('a missing file is reported as unreadable, not as empty', () async {
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      final int exitCode = await runPatchbayCli(
        <String>[
          '--json',
          'ui',
          'verify-manifest',
          '${Directory.systemTemp.path}/patchbay-absent-manifest.json',
        ],
        connect: (_) async => _client(),
        output: out,
        errorOutput: err,
      );
      expect(exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          (jsonDecode(out.toString()) as Map<String, Object?>)['error']!
              as Map<String, Object?>;
      expect(error['code'], 'manifestUnreadable');
      expect(
        (error['details']! as Map<String, Object?>)['path'],
        contains('patchbay-absent-manifest.json'),
      );
    });

    test('a bad manifest outranks a machine with no session', () async {
      // The dial used to come first, so authoring a manifest on a laptop with
      // no App running answered every mistake in the file with
      // `sessionDirectoryEmpty`: true about the session, silent about the
      // thing the author can actually fix from where they are sitting. The
      // file is wrong regardless of which device happens to be plugged in.
      final Directory directory = Directory.systemTemp.createTempSync(
        'patchbay-manifest-offline',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final File file = File('${directory.path}/targets.json')
        ..writeAsStringSync('{"targets": [{"id": "a.b", "kind": "tap"}]}');
      var dialled = false;
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();

      final int exitCode = await runPatchbayCli(
        <String>['--json', 'ui', 'verify-manifest', file.path],
        connect: (_) async {
          dialled = true;
          throw const PatchbaySessionException('sessionDirectoryEmpty');
        },
        output: out,
        errorOutput: err,
      );

      expect(exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          (jsonDecode(out.toString()) as Map<String, Object?>)['error']!
              as Map<String, Object?>;
      expect(error['code'], 'manifestInvalid');
      expect(
        (error['details']! as Map<String, Object?>)['field'],
        r'$.targets[0].kind',
      );
      expect(err.toString(), isNot(contains('sessionDirectoryEmpty')));
      // Not merely reported first: the dial never happens at all, so the
      // ordering cannot regress into "connect, then prefer the parse error".
      expect(dialled, isFalse);
    });

    test('an undeclared key is refused rather than ignored', () async {
      final CliRun run = await _run(
        _client(),
        '{"targets": [{"id": "a.b", "kind": "text", "screen": "login"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          (_report(run)['error']! as Map<String, Object?>)['details']!
              as Map<String, Object?>;
      expect(details['unexpected'], <String>['screen']);
      expect(details['field'], r'$.targets[0]');
    });

    test('kind accepts only the words a catalog row can publish', () async {
      final CliRun run = await _run(
        _client(),
        '{"targets": [{"id": "a.b", "kind": "tap"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          (_report(run)['error']! as Map<String, Object?>)['details']!
              as Map<String, Object?>;
      expect(details['field'], r'$.targets[0].kind');
      for (final PatchbayUiTargetKindWire kind
          in PatchbayUiTargetKindWire.values) {
        expect(details['reason'], contains(kind.name));
      }
    });

    test('a required field is named, with its path', () async {
      for (final (String document, String field) in <(String, String)>[
        ('{"targets": [{"kind": "text"}]}', r'$.targets[0].id'),
        ('{"targets": [{"id": "a.b"}]}', r'$.targets[0].kind'),
        ('{"targets": {}}', r'$.targets'),
        ('[]', r'$'),
        ('{"version": 3, "targets": []}', r'$.version'),
        (
          '{"targets": [{"id": "a.b", "kind": "text", "sensitive": "yes"}]}',
          r'$.targets[0].sensitive',
        ),
      ]) {
        final CliRun run = await _run(_client(), document);
        expect(run.exitCode, PatchbayExitCode.usage, reason: document);
        final Map<String, Object?> error =
            _report(run)['error']! as Map<String, Object?>;
        expect(error['code'], 'manifestInvalid', reason: document);
        expect(
          (error['details']! as Map<String, Object?>)['field'],
          field,
          reason: document,
        );
      }
    });

    test('one id may repeat only across distinct destinations', () async {
      final CliRun accepted = await _run(
        _client(
          uiTargets: <Object?>[_target('app.back')],
          destination: 'login',
        ),
        '{"targets": ['
        '{"id": "app.back", "kind": "text", "destination": "login"},'
        '{"id": "app.back", "kind": "text", "destination": "settings"}]}',
      );
      expect(accepted.exitCode, PatchbayExitCode.accepted);

      for (final String document in <String>[
        '{"targets": ['
            '{"id": "app.back", "kind": "text"},'
            '{"id": "app.back", "kind": "text"}]}',
        '{"targets": ['
            '{"id": "app.back", "kind": "text"},'
            '{"id": "app.back", "kind": "text", "destination": "login"}]}',
        '{"targets": ['
            '{"id": "app.back", "kind": "text", "destination": "login"},'
            '{"id": "app.back", "kind": "capture", "destination": "login"}]}',
      ]) {
        final CliRun run = await _run(_client(), document);
        expect(run.exitCode, PatchbayExitCode.usage, reason: document);
        final Map<String, Object?> details =
            (_report(run)['error']! as Map<String, Object?>)['details']!
                as Map<String, Object?>;
        expect(details['reason'], contains('distinct destination'));
        expect(details['id'], 'app.back');
      }
    });
  });

  group('the three deviation groups', () {
    test('an agreeing manifest exits zero and reports nothing', () async {
      final CliRun run = await _run(
        _client(
          uiTargets: <Object?>[
            _target('login.phone'),
            _target('login.password', sensitive: true),
            _target('app.shell', kind: PatchbayUiTargetKind.capture),
          ],
        ),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text"},'
        '{"id": "login.password", "kind": "text", "sensitive": true},'
        '{"id": "app.shell", "kind": "capture"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(_group(run, 'declaredNotMounted'), isEmpty);
      expect(_group(run, 'mountedNotDeclared'), isEmpty);
      expect(_group(run, 'propertyMismatch'), isEmpty);
      expect(_stats(run)['checked'], 3);
    });

    test('declared but not mounted separates absent from unmounted', () async {
      final CliRun run = await _run(
        _client(uiTargets: <Object?>[_target('login.phone', mounted: false)]),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text"},'
        '{"id": "login.otp", "kind": "text"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(_group(run, 'declaredNotMounted'), <Object?>[
        <String, Object?>{
          'id': 'login.phone',
          'kind': 'text',
          'sensitive': false,
          'runtime': 'unmounted',
        },
        <String, Object?>{
          'id': 'login.otp',
          'kind': 'text',
          'sensitive': false,
          'runtime': 'absent',
        },
      ]);
      expect(_stats(run)['declaredNotMounted'], 2);
    });

    test('mounted but not declared lists only mounted rows', () async {
      final CliRun run = await _run(
        _client(
          uiTargets: <Object?>[
            _target('login.phone'),
            _target('login.debug', generation: 4),
            // Registered but unmounted and undeclared: evidence of nothing.
            _target('login.legacy', mounted: false),
          ],
        ),
        '{"targets": [{"id": "login.phone", "kind": "text"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(_group(run, 'mountedNotDeclared'), <Object?>[
        <String, Object?>{
          'id': 'login.debug',
          'kind': 'text',
          'sensitive': false,
          'generation': 4,
        },
      ]);
    });

    test('property mismatch names every field that disagrees', () async {
      final CliRun run = await _run(
        _client(
          uiTargets: <Object?>[
            _target(
              'login.password',
              kind: PatchbayUiTargetKind.capture,
              sensitive: false,
            ),
          ],
        ),
        '{"targets": ['
        '{"id": "login.password", "kind": "text", "sensitive": true}]}',
      );
      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(_group(run, 'propertyMismatch'), <Object?>[
        <String, Object?>{
          'id': 'login.password',
          'fields': <Object?>[
            <String, Object?>{
              'field': 'kind',
              'declared': 'text',
              'runtime': 'capture',
            },
            <String, Object?>{
              'field': 'sensitive',
              'declared': true,
              'runtime': false,
            },
          ],
        },
      ]);
      // Mount state and declared properties are independent axes; the target is
      // mounted, so only the drift is reported.
      expect(_group(run, 'declaredNotMounted'), isEmpty);
    });

    test(
      'a target mounted twice is noticed without becoming a deviation',
      () async {
        final CliRun run = await _run(
          _client(
            uiTargets: <Object?>[_target('login.phone', ambiguous: true)],
          ),
          '{"targets": [{"id": "login.phone", "kind": "text"}]}',
        );
        expect(run.exitCode, PatchbayExitCode.accepted);
        expect(_report(run)['notices'], <Object?>[
          <String, Object?>{'code': 'uiTargetAmbiguous', 'id': 'login.phone'},
        ]);
      },
    );
  });

  group('destination filtering', () {
    test('only entries scoped to the current destination are checked', () async {
      final FakePatchbayClient client = _client(
        uiTargets: <Object?>[_target('login.phone')],
        destination: 'login',
      );
      final CliRun run = await _run(
        client,
        '{"targets": ['
        '{"id": "login.phone", "kind": "text", "destination": "login"},'
        '{"id": "settings.nickname", "kind": "text", "destination": "settings"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(_group(run, 'declaredNotMounted'), isEmpty);
      expect(_stats(run), containsPair('skippedOutOfScope', 1));
      expect(_stats(run), containsPair('checked', 1));
      expect(_report(run)['destination'], 'login');
      expect(_report(run)['destinationSource'], 'navigation.current');
    });

    test('an id declared for another screen is not undeclared', () async {
      // The runtime carries a target whose only declaration is scoped
      // elsewhere. It is declared — reporting it as a surplus would contradict
      // the manifest the operator just handed over.
      final CliRun run = await _run(
        _client(
          uiTargets: <Object?>[_target('settings.nickname')],
          destination: 'login',
        ),
        '{"targets": ['
        '{"id": "settings.nickname", "kind": "text", "destination": "settings"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(_group(run, 'mountedNotDeclared'), isEmpty);
    });

    test(
      'a manifest that scopes nothing never reads the destination',
      () async {
        final FakePatchbayClient client = _client(
          uiTargets: <Object?>[_target('login.phone')],
        );
        final CliRun run = await _run(
          client,
          '{"targets": [{"id": "login.phone", "kind": "text"}]}',
        );
        expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
        expect(client.calls, isEmpty);
        expect(_report(run)['destinationSource'], isNull);
      },
    );

    test('an unsettled destination skips every scoped entry', () async {
      final CliRun run = await _run(
        _client(uiTargets: <Object?>[_target('login.phone')]),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text", "destination": "login"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(_report(run)['destination'], isNull);
      // Read, and the App had nothing to report — a different fact from "the
      // manifest scopes nothing", which is why the source is still recorded.
      expect(_report(run)['destinationSource'], 'navigation.current');
      expect(_stats(run), containsPair('skippedOutOfScope', 1));
    });

    test('a refused destination read is reported as itself', () async {
      // The scoped half cannot be reconciled without the current destination,
      // so neither refusal is resolved into a verdict about a screen nobody
      // named. Each keeps the class the App's own answer earned.
      const String manifest =
          '{"targets": ['
          '{"id": "login.phone", "kind": "text", "destination": "login"}]}';

      final CliRun absent = await _run(
        _client(
          uiTargets: <Object?>[_target('login.phone')],
          navigationCataloged: false,
        ),
        manifest,
      );
      expect(absent.exitCode, PatchbayExitCode.protocol);
      expect(_report(absent)['destinationSource'], 'navigation.current');
      expect(_report(absent)['schema'], isNull);

      final CliRun gated = await _run(
        _client(
          uiTargets: <Object?>[_target('login.phone')],
          navigationResponse: const <String, Object?>{
            'admission': 'rejected',
            'rejection': <String, Object?>{
              'code': 'navigationLifecycleNotResumed',
              'details': <String, Object?>{'lifecycleState': 'paused'},
            },
          },
        ),
        manifest,
      );
      expect(gated.exitCode, PatchbayExitCode.rejected);
      expect(_report(gated)['destinationSource'], 'navigation.current');
      expect(_report(gated)['schema'], isNull);
    });
  });

  test('a catalog the CLI cannot read is a protocol error', () async {
    final CliRun run = await _run(
      _client(
        uiTargets: <Object?>[
          const <String, Object?>{'id': 'a.b'},
        ],
      ),
      '{"targets": [{"id": "a.b", "kind": "text"}]}',
    );
    expect(run.exitCode, PatchbayExitCode.protocol);
    final Map<String, Object?> error =
        _report(run)['error']! as Map<String, Object?>;
    expect(error['code'], 'catalogUiTargetsContractViolated');
  });

  test('the human rendering carries the deviations, not only counts', () async {
    final CliRun run = await _run(
      _client(
        uiTargets: <Object?>[
          _target('login.debug', generation: 4),
          _target('login.phone', kind: PatchbayUiTargetKind.capture),
        ],
      ),
      '{"targets": ['
      '{"id": "login.phone", "kind": "text"},'
      '{"id": "login.otp", "kind": "text"}]}',
      json: false,
    );
    expect(run.exitCode, PatchbayExitCode.verificationDeviation);
    expect(run.stdout, contains('login.otp'));
    expect(run.stdout, contains('absent from the catalog'));
    expect(run.stdout, contains('login.debug'));
    expect(run.stdout, contains('declared=text runtime=capture'));
  });

  test(
    'a repl line with an unreadable manifest does not end the session',
    () async {
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      final int exitCode = await runPatchbayCli(
        <String>['--json', 'repl'],
        connect: (_) async => _client(uiTargets: <Object?>[_target('a.b')]),
        replInput: Stream<String>.fromIterable(<String>[
          'ui verify-manifest ${Directory.systemTemp.path}/patchbay-absent.json',
          'catalog',
        ]),
        output: out,
        errorOutput: err,
      );
      expect(exitCode, PatchbayExitCode.accepted);
      final List<Map<String, Object?>> lines = out
          .toString()
          .trim()
          .split('\n')
          .map((String line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      expect(lines, hasLength(2));
      expect(lines.first['exitCode'], PatchbayExitCode.usage);
      expect(lines.first['error'], contains('manifestUnreadable'));
      // The session survived: the line after it still ran on the same connection.
      expect(lines.last['exitCode'], PatchbayExitCode.accepted);
    },
  );

  test('a repl line summarises one report on one line', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'patchbay-manifest-repl',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File(
      '${directory.path}/targets.json',
    ).writeAsStringSync('{"targets": [{"id": "login.otp", "kind": "text"}]}');
    final StringBuffer out = StringBuffer();
    final int exitCode = await runPatchbayCli(
      <String>['repl'],
      connect: (_) async => _client(),
      replInput: Stream<String>.fromIterable(<String>[
        'ui verify-manifest ${directory.path}/targets.json',
      ]),
      output: out,
      errorOutput: StringBuffer(),
    );
    expect(exitCode, PatchbayExitCode.accepted);
    expect(out.toString().trim().split('\n'), hasLength(1));
    expect(
      out.toString(),
      contains('exit=${PatchbayExitCode.verificationDeviation}'),
    );
    expect(out.toString(), contains('uiManifest declaredNotMounted=1'));
  });

  test('the documented example is a manifest this CLI accepts', () {
    // The guide points operators at this file; a sample the parser refuses
    // would be a contract the documentation and the implementation disagree on.
    final PatchbayUiManifest manifest = PatchbayUiManifest.parse(
      _exampleManifest().readAsStringSync(),
    );
    expect(manifest.entries, isNotEmpty);
    expect(manifest.usesDestinations, isTrue);
  });
}
