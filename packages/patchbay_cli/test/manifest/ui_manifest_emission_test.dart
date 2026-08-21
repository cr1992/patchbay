import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import '../fixture/fake_client.dart';
import '../fixture/ui_manifest_fixtures.dart';

void main() {
  group('live manifest emission', () {
    test('emits a stable v2 draft for only mounted targets', () async {
      final FakePatchbayClient client = clientFixture(
        destination: 'settings',
        uiTargets: <Object?>[
          targetFixture('settings.zeta', sensitive: true),
          targetFixture('settings.hidden', mounted: false),
          targetFixture('settings.alpha', kind: PatchbayUiTargetKind.capture),
        ],
      );

      final CliRun first = await emitManifestCli(client);
      final CliRun second = await emitManifestCli(client);

      expect(first.exitCode, PatchbayExitCode.accepted, reason: first.stderr);
      expect(second.stdout, first.stdout);
      expect(reportOf(first), <String, Object?>{
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
      final FakePatchbayClient client = clientFixture(
        destination: 'login',
        uiTargets: <Object?>[
          targetFixture('login.submit'),
          targetFixture('login.password', sensitive: true),
        ],
      );
      final CliRun emitted = await emitManifestCli(client);

      final CliRun verified = await runManifestCli(client, emitted.stdout);

      expect(verified.exitCode, PatchbayExitCode.accepted);
      expect(statsOf(verified)['checked'], 2);
      expect(reportOf(verified)['destination'], 'login');
    });

    test('human mode still prints the editable JSON document', () async {
      final CliRun run = await emitManifestCli(
        clientFixture(destination: 'login'),
        json: false,
      );

      expect(run.exitCode, PatchbayExitCode.accepted);
      expect(jsonDecode(run.stdout), containsPair('version', 2));
      expect(run.stdout, contains('\n  "coverage": "mountedOnly"'));
    });

    test('refuses to invent a destination for the draft', () async {
      final CliRun run = await emitManifestCli(clientFixture());

      expect(run.exitCode, PatchbayExitCode.protocol);
      final Map<String, Object?> error =
          reportOf(run)['error']! as Map<String, Object?>;
      expect(error['code'], 'manifestDestinationUnavailable');
    });

    test('a missing navigation capability stays a catalog refusal', () async {
      final CliRun run = await emitManifestCli(clientFixture(navigationCataloged: false));

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(reportOf(run)['destinationSource'], 'navigation.current');
      expect(reportOf(run)['admission'], 'rejected');
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

  group('destination filtering', () {
    test('only entries scoped to the current destination are checked', () async {
      final FakePatchbayClient client = clientFixture(
        uiTargets: <Object?>[targetFixture('login.phone')],
        destination: 'login',
      );
      final CliRun run = await runManifestCli(
        client,
        '{"targets": ['
        '{"id": "login.phone", "kind": "text", "destination": "login"},'
        '{"id": "settings.nickname", "kind": "text", "destination": "settings"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(groupOf(run, 'declaredNotMounted'), isEmpty);
      expect(statsOf(run), containsPair('skippedOutOfScope', 1));
      expect(statsOf(run), containsPair('checked', 1));
      expect(reportOf(run)['destination'], 'login');
      expect(reportOf(run)['destinationSource'], 'navigation.current');
    });

    test('an id declared for another screen is not undeclared', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[targetFixture('settings.nickname')],
          destination: 'login',
        ),
        '{"targets": ['
        '{"id": "settings.nickname", "kind": "text", "destination": "settings"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(groupOf(run, 'mountedNotDeclared'), isEmpty);
    });

    test(
      'a manifest that scopes nothing never reads the destination',
      () async {
        final FakePatchbayClient client = clientFixture(
          uiTargets: <Object?>[targetFixture('login.phone')],
        );
        final CliRun run = await runManifestCli(
          client,
          '{"targets": [{"id": "login.phone", "kind": "text"}]}',
        );
        expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
        expect(client.calls, isEmpty);
        expect(reportOf(run)['destinationSource'], isNull);
      },
    );

    test('an unsettled destination skips every scoped entry', () async {
      final CliRun run = await runManifestCli(
        clientFixture(uiTargets: <Object?>[targetFixture('login.phone')]),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text", "destination": "login"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(reportOf(run)['destination'], isNull);
      expect(reportOf(run)['destinationSource'], 'navigation.current');
      expect(statsOf(run), containsPair('skippedOutOfScope', 1));
    });

    test('a refused destination read is reported as itself', () async {
      const String manifest =
          '{"targets": ['
          '{"id": "login.phone", "kind": "text", "destination": "login"}]}';

      final CliRun absent = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[targetFixture('login.phone')],
          navigationCataloged: false,
        ),
        manifest,
      );
      expect(absent.exitCode, PatchbayExitCode.protocol);
      expect(reportOf(absent)['destinationSource'], 'navigation.current');
      expect(reportOf(absent)['schema'], isNull);

      final CliRun gated = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[targetFixture('login.phone')],
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
      expect(reportOf(gated)['destinationSource'], 'navigation.current');
      expect(reportOf(gated)['schema'], isNull);
    });
  });

  test('a catalog the CLI cannot read is a protocol error', () async {
    final CliRun run = await runManifestCli(
      clientFixture(
        uiTargets: <Object?>[
          const <String, Object?>{'id': 'a.b'},
        ],
      ),
      '{"targets": [{"id": "a.b", "kind": "text"}]}',
    );
    expect(run.exitCode, PatchbayExitCode.protocol);
    final Map<String, Object?> error =
        reportOf(run)['error']! as Map<String, Object?>;
    expect(error['code'], 'catalogUiTargetsContractViolated');
  });

  test('the human rendering carries the deviations, not only counts', () async {
    final CliRun run = await runManifestCli(
      clientFixture(
        uiTargets: <Object?>[
          targetFixture('login.debug', generation: 4),
          targetFixture('login.phone', kind: PatchbayUiTargetKind.capture),
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
        connect: (_) async => clientFixture(uiTargets: <Object?>[targetFixture('a.b')]),
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
      connect: (_) async => clientFixture(),
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
    final PatchbayUiManifest manifest = PatchbayUiManifest.parse(
      exampleManifestFile().readAsStringSync(),
    );
    expect(manifest.entries, isNotEmpty);
    expect(manifest.usesDestinations, isTrue);
  });
}
