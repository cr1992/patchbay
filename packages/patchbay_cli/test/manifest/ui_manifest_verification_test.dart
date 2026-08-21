import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import '../fixture/fake_client.dart';
import '../fixture/ui_manifest_fixtures.dart';

void main() {
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
        final FakePatchbayClient client = clientFixture(
          uiTargets: <Object?>[targetFixture('login.title')],
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(4, generation: 2, identifier: 'login.title'),
          ]),
        );

        final CliRun run = await runManifestCli(
          client,
          '{"version":1,"targets":['
          '{"id":"login.title","kind":"text","sensitive":false}]}',
        );

        expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
        expect(client.calls, isEmpty);
        expect(reportOf(run).containsKey('semantics'), isFalse);
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
      final CliRun run = await runManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(
              1,
              generation: 1,
              identifier: '',
              children: const <int>[2],
            ),
            semanticsNodeFixture(
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
          reportOf(run)['semantics']! as Map<String, Object?>;
      expect(semantics['command'], 'ui.semantics.tree');
      expect(semantics['source'], 'uiObserved');
      expect(semantics['treeRevision'], 9);
      expect(
        (semantics['observed']! as List<Object?>).single,
        containsPair('generation', 7),
      );
    });

    test('an unmounted identifier is a manifest deviation', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(
            const <Map<String, Object?>>[],
          ),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      final Map<String, Object?> missing =
          (groupOf(run, 'declaredNotMounted').single as Map<String, Object?>);
      expect(missing['namespace'], 'semanticsIdentifier');
      expect(missing['runtime'], 'unmounted');
      expect(missing['code'], 'uiSemanticsIdentifierNotFound');
    });

    test('duplicate live identifiers fail closed with a stable code', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(1, generation: 2, identifier: 'login.submit'),
            semanticsNodeFixture(2, generation: 3, identifier: 'login.submit'),
          ]),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      final Map<String, Object?> semantics =
          reportOf(run)['semantics']! as Map<String, Object?>;
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
          semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(8, generation: 1, identifier: 'login.submit'),
          ], treeRevision: 4),
        ),
        1,
      );
      expect(
        observedGeneration(
          semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(12, generation: 2, identifier: 'login.submit'),
          ], treeRevision: 5),
        ),
        2,
      );
    });

    test('catalog and semantics namespaces reconcile independently', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          destination: 'login',
          uiTargets: <Object?>[targetFixture('login.title')],
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(3, generation: 4, identifier: 'login.submit'),
          ]),
        ),
        '{"version":2,"coverage":"mountedOnly","destinations":['
        '{"id":"login","targets":[{"namespace":"catalogTarget",'
        '"id":"login.title","kind":"text","sensitive":false},'
        '{"namespace":"semanticsIdentifier","id":"login.submit"}]}]}',
      );

      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(groupOf(run, 'declaredNotMounted'), isEmpty);
      expect(groupOf(run, 'mountedNotDeclared'), isEmpty);
    });

    test(
      'missing Semantics capability is explicit and never guessed',
      () async {
        final CliRun run = await runManifestCli(
          clientFixture(destination: 'login'),
          semanticsManifest,
        );

        expect(run.exitCode, PatchbayExitCode.protocol);
        expect(
          (reportOf(run)['error']! as Map<String, Object?>)['code'],
          'manifestSemanticsUnavailable',
        );
      },
    );

    test('a truncated tree cannot prove identifier absence', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(
            const <Map<String, Object?>>[],
            truncated: true,
          ),
        ),
        semanticsManifest,
      );

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(
        (reportOf(run)['error']! as Map<String, Object?>)['code'],
        'manifestSemanticsTreeTruncated',
      );
    });

    test('live emission includes only unique attached identifiers', () async {
      final CliRun run = await emitManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(2, generation: 6, identifier: 'login.submit'),
          ]),
        ),
      );

      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      final List<Object?> targets =
          (((reportOf(run)['destinations']! as List<Object?>).single
                  as Map<String, Object?>)['targets']!
              as List<Object?>);
      expect(targets.single, <String, Object?>{
        'namespace': 'semanticsIdentifier',
        'id': 'login.submit',
      });
    });

    test('live emission refuses an ambiguous identifier draft', () async {
      final CliRun run = await emitManifestCli(
        clientFixture(
          destination: 'login',
          semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
            semanticsNodeFixture(2, generation: 1, identifier: 'login.submit'),
            semanticsNodeFixture(3, generation: 2, identifier: 'login.submit'),
          ]),
        ),
      );

      expect(run.exitCode, PatchbayExitCode.protocol);
      expect(
        (reportOf(run)['error']! as Map<String, Object?>)['code'],
        'manifestSemanticsIdentifierAmbiguous',
      );
    });

    test(
      'live emission refuses a cross-namespace identifier conflict draft',
      () async {
        final CliRun run = await emitManifestCli(
          clientFixture(
            destination: 'login',
            uiTargets: <Object?>[targetFixture('login.submit')],
            semanticsPayload: semanticsPayloadFixture(<Map<String, Object?>>[
              semanticsNodeFixture(
                2,
                generation: 1,
                identifier: 'login.submit',
              ),
            ]),
          ),
        );

        expect(run.exitCode, PatchbayExitCode.protocol);
        expect(
          (reportOf(run)['error']! as Map<String, Object?>)['code'],
          'manifestNamespaceConflict',
        );
      },
    );
  });

  group('the three deviation groups', () {
    test('an agreeing manifest exits zero and reports nothing', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[
            targetFixture('login.phone'),
            targetFixture('login.password', sensitive: true),
            targetFixture('app.shell', kind: PatchbayUiTargetKind.capture),
          ],
        ),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text"},'
        '{"id": "login.password", "kind": "text", "sensitive": true},'
        '{"id": "app.shell", "kind": "capture"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.accepted, reason: run.stderr);
      expect(groupOf(run, 'declaredNotMounted'), isEmpty);
      expect(groupOf(run, 'mountedNotDeclared'), isEmpty);
      expect(groupOf(run, 'propertyMismatch'), isEmpty);
      expect(statsOf(run)['checked'], 3);
    });

    test('declared but not mounted separates absent from unmounted', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[targetFixture('login.phone', mounted: false)],
        ),
        '{"targets": ['
        '{"id": "login.phone", "kind": "text"},'
        '{"id": "login.otp", "kind": "text"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(groupOf(run, 'declaredNotMounted'), <Object?>[
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
      expect(statsOf(run)['declaredNotMounted'], 2);
    });

    test('mounted but not declared lists only mounted rows', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[
            targetFixture('login.phone'),
            targetFixture('login.debug', generation: 4),
            targetFixture('login.legacy', mounted: false),
          ],
        ),
        '{"targets": [{"id": "login.phone", "kind": "text"}]}',
      );
      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(groupOf(run, 'mountedNotDeclared'), <Object?>[
        <String, Object?>{
          'id': 'login.debug',
          'kind': 'text',
          'sensitive': false,
          'generation': 4,
        },
      ]);
    });

    test('property mismatch names every field that disagrees', () async {
      final CliRun run = await runManifestCli(
        clientFixture(
          uiTargets: <Object?>[
            targetFixture(
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
      expect(groupOf(run, 'propertyMismatch'), <Object?>[
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
      expect(groupOf(run, 'declaredNotMounted'), isEmpty);
    });

    test(
      'a target mounted twice is noticed without becoming a deviation',
      () async {
        final CliRun run = await runManifestCli(
          clientFixture(
            uiTargets: <Object?>[targetFixture('login.phone', ambiguous: true)],
          ),
          '{"targets": [{"id": "login.phone", "kind": "text"}]}',
        );
        expect(run.exitCode, PatchbayExitCode.accepted);
        expect(reportOf(run)['notices'], <Object?>[
          <String, Object?>{'code': 'uiTargetAmbiguous', 'id': 'login.phone'},
        ]);
      },
    );
  });
}
