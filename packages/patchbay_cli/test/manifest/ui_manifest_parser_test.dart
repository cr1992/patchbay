import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/manifest/manifest_models.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:test/test.dart';

import '../fixture/fake_client.dart';
import '../fixture/ui_manifest_fixtures.dart';

void main() {
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
        final CliRun run = await runManifestCli(
          clientFixture(uiTargets: <Object?>[targetWire('login.submit')]),
          manifest,
          extension: extension,
        );
        expect(run.exitCode, PatchbayExitCode.accepted, reason: extension);
      }
    });

    test('unknown extension fails closed before dialing', () async {
      final FakePatchbayClient client = clientFixture();
      final CliRun run = await runManifestCli(
        client,
        '{"targets":[]}',
        extension: '.txt',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      expect(
        (reportOf(run)['error']! as Map<String, Object?>)['code'],
        'manifestFormatUnsupported',
      );
      expect(client.catalogReads, 0);
    });

    test(
      'YAML syntax error reports one-based location without content',
      () async {
        const String secret = 'secret-target-value';
        final CliRun run = await runManifestCli(
          clientFixture(),
          'version: 1\ntargets:\n  - id: $secret\n    kind: [\n',
          extension: '.yaml',
        );

        expect(run.exitCode, PatchbayExitCode.usage);
        final Map<String, Object?> error =
            reportOf(run)['error']! as Map<String, Object?>;
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
      final CliRun run = await runManifestCli(
        clientFixture(),
        'version: 1\n'
        'seed: &seed {id: login.submit, kind: text}\n'
        'targets: [*seed, *seed, *seed, *seed]\n',
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          ((reportOf(run)['error']! as Map<String, Object?>)['details']!
              as Map<String, Object?>);
      expect(details['reason'], 'YAML aliases are not supported');
      expect(details['line'], isA<int>());
      expect(details['column'], isA<int>());
    });

    test(
      'unknown custom tags are refused without echoing their value',
      () async {
        const String secret = 'private-tag-payload';
        final CliRun run = await runManifestCli(
          clientFixture(),
          'version: 1\ntargets:\n  - id: !private $secret\n    kind: text\n',
          extension: '.yaml',
        );

        expect(run.exitCode, PatchbayExitCode.usage);
        final Map<String, Object?> error =
            reportOf(run)['error']! as Map<String, Object?>;
        final Map<String, Object?> details =
            error['details']! as Map<String, Object?>;
        expect(error['code'], 'manifestInvalid');
        expect(details['line'], isA<int>());
        expect(details['column'], isA<int>());
        expect(jsonEncode(error), isNot(contains(secret)));
      },
    );

    test('duplicate YAML mapping keys fail at the second key', () async {
      final CliRun run = await runManifestCli(
        clientFixture(),
        'version: 1\ntargets: []\ntargets: []\n',
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          reportOf(run)['error']! as Map<String, Object?>;
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
      final CliRun run = await runManifestCli(
        clientFixture(),
        List<String>.filled(patchbayUiManifestMaximumBytes + 1, 'x').join(),
        extension: '.yaml',
      );

      expect(run.exitCode, PatchbayExitCode.usage);
      expect(
        (reportOf(run)['error']! as Map<String, Object?>)['code'],
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

  group('manifest parsing is fail-closed', () {
    test('a file that is not JSON names the syntax failure', () async {
      final CliRun run = await runManifestCli(clientFixture(), 'targets: []');
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> error =
          reportOf(run)['error']! as Map<String, Object?>;
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
      final int exitCode = await runPatchbayCliWithSeams(
        <String>[
          '--json',
          'ui',
          'verify-manifest',
          '${Directory.systemTemp.path}/patchbay-absent-manifest.json',
        ],
        connect: (_) async => clientFixture(),
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
      final Directory directory = Directory.systemTemp.createTempSync(
        'patchbay-manifest-offline',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final File file = File('${directory.path}/targets.json')
        ..writeAsStringSync('{"targets": [{"id": "a.b", "kind": "tap"}]}');
      var dialled = false;
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();

      final int exitCode = await runPatchbayCliWithSeams(
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
      expect(dialled, isFalse);
    });

    test('an undeclared key is refused rather than ignored', () async {
      final CliRun run = await runManifestCli(
        clientFixture(),
        '{"targets": [{"id": "a.b", "kind": "text", "screen": "login"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          (reportOf(run)['error']! as Map<String, Object?>)['details']!
              as Map<String, Object?>;
      expect(details['unexpected'], <String>['screen']);
      expect(details['field'], r'$.targets[0]');
    });

    test('kind accepts only the words a catalog row can publish', () async {
      final CliRun run = await runManifestCli(
        clientFixture(),
        '{"targets": [{"id": "a.b", "kind": "tap"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.usage);
      final Map<String, Object?> details =
          (reportOf(run)['error']! as Map<String, Object?>)['details']!
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
        final CliRun run = await runManifestCli(clientFixture(), document);
        expect(run.exitCode, PatchbayExitCode.usage, reason: document);
        final Map<String, Object?> error =
            reportOf(run)['error']! as Map<String, Object?>;
        expect(error['code'], 'manifestInvalid', reason: document);
        expect(
          (error['details']! as Map<String, Object?>)['field'],
          field,
          reason: document,
        );
      }
    });

    test('one id may repeat only across distinct destinations', () async {
      final CliRun accepted = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[targetWire('app.back')],
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
        final CliRun run = await runManifestCli(clientFixture(), document);
        expect(run.exitCode, PatchbayExitCode.usage, reason: document);
        final Map<String, Object?> details =
            (reportOf(run)['error']! as Map<String, Object?>)['details']!
                as Map<String, Object?>;
        expect(details['reason'], contains('distinct destination'));
        expect(details['id'], 'app.back');
      }
    });
  });
}
