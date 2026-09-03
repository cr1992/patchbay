/// DG-060-05 on the CLI side: `--json describe` stays a transparent
/// passthrough of whatever the catalog row declares (no synthesised
/// `legacyUnknown` in stable JSON); `legacyUnknown` only shows up in the
/// human-readable summary line; and an unknown declared value fails the
/// *whole* catalog before any RPC is sent, matching the host-side
/// fail-closed shape (`packages/patchbay/test/host/
/// interaction_model_catalog_test.dart`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/support/catalog_descriptor.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

void main() {
  group('describe: interactionModel passthrough', () {
    test('a legacy host row with no interactionModel key stays absent in '
        '--json, and reads legacyUnknown only in the human summary', () async {
      final FakePatchbayClient client = _client(<String, Object?>{
        'name': 'ui.text.set',
        'sideEffect': 'appState',
      });

      final _JsonRun jsonRun = await _runJson(client, <String>[
        '--json',
        'describe',
        'ui.text.set',
      ]);
      expect(jsonRun.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> command =
          jsonRun.json['command']! as Map<String, Object?>;
      expect(command.containsKey('interactionModel'), isFalse);

      final String text = (await _runText(client, <String>[
        'describe',
        'ui.text.set',
      ])).out;
      expect(text, contains('interactionModel=legacyUnknown'));
      // The line must not claim anything about the host's version: on a 0.6.0
      // host every command outside the closed declaring set reads the same
      // way, so it names both causes instead of picking one.
      expect(
        text,
        contains(
          'no interactionModel declared: host predates the field or the '
          'command is outside the declaring set',
        ),
      );
      expect(text, isNot(contains('not declared by this host')));
    });

    test('a declared directTarget value round-trips byte-exact in --json and '
        'reads directTarget in the human summary', () async {
      final FakePatchbayClient client = _client(<String, Object?>{
        'name': 'ui.text.set',
        'sideEffect': 'appState',
        'interactionModel': 'directTarget',
      });

      final _JsonRun jsonRun = await _runJson(client, <String>[
        '--json',
        'describe',
        'ui.text.set',
      ]);
      final Map<String, Object?> command =
          jsonRun.json['command']! as Map<String, Object?>;
      expect(command['interactionModel'], 'directTarget');

      final String text = (await _runText(client, <String>[
        'describe',
        'ui.text.set',
      ])).out;
      expect(text, contains('interactionModel=directTarget'));
      expect(
        text,
        contains(
          'not that a user, pointer or device could '
          'reach the target',
        ),
      );
    });

    test(
      'a declared userLike value reads userLike in the human summary',
      () async {
        final FakePatchbayClient client = _client(<String, Object?>{
          'name': 'ui.gesture.tap',
          'sideEffect': 'appState',
          'interactionModel': 'userLike',
        });

        final String text = (await _runText(client, <String>[
          'describe',
          'ui.gesture.tap',
        ])).out;
        expect(text, contains('interactionModel=userLike'));
        expect(text, contains('no force or ignoreOcclusion'));
      },
    );
  });

  group('unknown interactionModel: whole-catalog provider violation', () {
    test('describe fails closed before reading the requested row', () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.semantics.tree'},
          <String, Object?>{'name': 'ui.text.set', 'interactionModel': 'bogus'},
        ],
        handle: (_, _) async => const <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{},
        },
      );

      // 请求的是完全无关的另一行，证明失效是整份 catalog 级别，不是那一行。
      final _JsonRun result = await _runJson(client, <String>[
        '--json',
        'describe',
        'ui.semantics.tree',
      ]);

      expect(result.exitCode, PatchbayExitCode.protocol);
      final Map<String, Object?> error =
          result.json['error']! as Map<String, Object?>;
      expect(error['code'], 'providerProtocolViolation');
      final Map<String, Object?> details =
          error['details']! as Map<String, Object?>;
      expect(details['reason'], 'invalidCatalogCommands');
    });

    test('exec fails closed before any RPC is sent', () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'device.write',
            'interactionModel': 'bogus',
          },
        ],
        handle: (_, _) async => const <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{},
        },
      );

      final _JsonRun result = await _runJson(client, <String>[
        '--json',
        'exec',
        'device.write',
      ]);

      expect(result.exitCode, PatchbayExitCode.protocol);
      expect(
        (result.json['error']! as Map<String, Object?>)['code'],
        'providerProtocolViolation',
      );
      // Fail-closed happens before the App is ever called.
      expect(client.calls, isEmpty);
    });
  });

  // The independent-review finding this group exists to answer: the validator
  // above was originally reachable only from the dispatch path, so the two
  // commands an operator actually reaches for first — `patchbay catalog` and
  // `doctor` — read the same violating document and reported it as healthy
  // (`--json catalog` exited 0 and printed `interactionModel: "bogus"`
  // verbatim; doctor said ok). PB-050-40 routed both through
  // `validateCatalogDeclarations`; these tests prove the seam now carries
  // PB-050-34's check rather than assuming it does.
  group('direct catalog readers, not just the dispatch path', () {
    // Two rows on purpose: the violating row is not the one a reader is
    // interested in, so a per-row filter would let the document through.
    Map<String, Object?> catalogWithBogusRow() => <String, Object?>{
      'commands': <Object?>[
        <String, Object?>{'name': 'navigation.current', 'summary': 'fine'},
        <String, Object?>{'name': 'ui.text.set', 'interactionModel': 'bogus'},
      ],
      'uiTargets': const <Object?>[],
    };

    FakePatchbayClient bogusClient() => FakePatchbayClient(
      commands: <Map<String, Object?>>[
        <String, Object?>{'name': 'navigation.current', 'summary': 'fine'},
        <String, Object?>{'name': 'ui.text.set', 'interactionModel': 'bogus'},
      ],
      handle: (_, _) async => fakeCommandNotRegistered(),
    );

    test(
      '`--json catalog` exits non-zero instead of printing the row',
      () async {
        final FakePatchbayClient client = bogusClient();

        final _JsonRun result = await _runJson(client, <String>[
          '--json',
          'catalog',
        ]);

        expect(result.exitCode, isNot(PatchbayExitCode.accepted));
        expect(result.exitCode, PatchbayExitCode.protocol);
        final Map<String, Object?> error =
            result.json['error']! as Map<String, Object?>;
        expect(error['code'], 'providerProtocolViolation');
        expect(
          (error['details']! as Map<String, Object?>)['reason'],
          'invalidCatalogCommands',
        );
        // The refused value is never echoed back as if the CLI had accepted it.
        expect(jsonEncode(result.json), isNot(contains('"bogus"')));
      },
    );

    test('`--view brief catalog` refuses the same document', () async {
      final FakePatchbayClient client = bogusClient();

      // `--view brief` is a rendering choice, not a second reader: it must not
      // reach a projection of a catalog the CLI already cannot interpret.
      final _JsonRun result = await _runJson(client, <String>[
        '--json',
        '--view',
        'brief',
        'catalog',
      ]);

      expect(result.exitCode, PatchbayExitCode.protocol);
      expect(
        (result.json['error']! as Map<String, Object?>)['code'],
        'providerProtocolViolation',
      );
    });

    test('doctor names the violation instead of reporting ok', () {
      // Doctor deliberately reads first and judges second (PB-050-40), so the
      // assertion is on the finding it produces, not on a refusal it never
      // makes: the point is only that the verdict is no longer `ok`.
      final PatchbayDoctorFinding finding = patchbayCatalogFinding(
        catalogWithBogusRow(),
      );

      expect(finding.verdict, PatchbayCheckVerdict.failed);
      expect(finding.details['code'], 'providerProtocolViolation');
      expect(finding.details['reason'], 'invalidCatalogCommands');
    });

    test('doctor still passes a catalog whose declarations are readable', () {
      final PatchbayDoctorFinding finding = patchbayCatalogFinding(
        <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'ui.text.set',
              'interactionModel': 'directTarget',
            },
            <String, Object?>{
              'name': 'ui.gesture.tap',
              'interactionModel': 'userLike',
            },
          ],
          'uiTargets': const <Object?>[],
        },
      );

      expect(finding.verdict, isNot(PatchbayCheckVerdict.failed));
    });

    test('a lookup on a catalog that never passed the fetch seam still '
        'refuses', () {
      // Why `CatalogCommandDescriptor.find` keeps its own call rather than
      // leaning on `validateCatalogDeclarations`: the manifest walkthrough
      // re-reads a fresh catalog per screen straight off `connection.catalog()`
      // and drives the invoker with that second, unvalidated document. This
      // pins the lookup itself, with no fetch anywhere in the picture.
      expect(
        () => CatalogCommandDescriptor.find(
          catalogWithBogusRow(),
          'navigation.current',
        ),
        throwsA(
          isA<PatchbayProtocolException>().having(
            (PatchbayProtocolException failure) => failure.code,
            'code',
            'providerProtocolViolation',
          ),
        ),
      );
    });
  });

  group('frozen 0.5.0 host corpus through the whole CLI', () {
    // The 0.5.0 surface was frozen before `interactionModel` existed, so it is
    // the only honest evidence that a real pre-field host still reads cleanly:
    // a hand-written row can be made to say anything, this one cannot be
    // regenerated (`test/golden/legacy_host_v0_5_0/README.md`).
    final Map<String, Object?> frozen =
        jsonDecode(
              File(
                'test/golden/legacy_host_v0_5_0/catalog.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    FakePatchbayClient frozenClient() => FakePatchbayClient(
      commands: <Map<String, Object?>>[
        for (final Object? row in frozen['commands']! as List<Object?>)
          Map<String, Object?>.from(row! as Map<String, Object?>),
      ],
      uiTargets: frozen['uiTargets']! as List<Object?>,
      catalogExtras: <String, Object?>{
        for (final MapEntry<String, Object?> entry in frozen.entries)
          if (entry.key != 'commands' && entry.key != 'uiTargets')
            entry.key: entry.value,
      },
      handle: (_, _) async => fakeCommandNotRegistered(),
    );

    // `domain.ping` is the whole 0.5.0 corpus. That it is not a UI command is
    // the point rather than a gap: `legacyUnknown` covers both a host that
    // predates the field and a command outside the declaring set, and a
    // reader must not tell them apart — which is exactly what the summary
    // line now says.
    const String command = 'domain.ping';

    test('describe reads legacyUnknown and exits 0', () async {
      final _TextRun run = await _runText(frozenClient(), <String>[
        'describe',
        command,
      ]);

      expect(run.exitCode, PatchbayExitCode.accepted);
      expect(run.out, contains('interactionModel=legacyUnknown'));
      expect(
        run.out,
        contains(
          'no interactionModel declared: host predates the field or the '
          'command is outside the declaring set',
        ),
      );
    });

    test('--json describe carries no interactionModel key at all', () async {
      final _JsonRun result = await _runJson(frozenClient(), <String>[
        '--json',
        'describe',
        command,
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      final Map<String, Object?> row =
          result.json['command']! as Map<String, Object?>;
      // Not `null`, not `"legacyUnknown"`: the CLI never synthesises a key the
      // provider did not publish (DG-060-05 transparent passthrough).
      expect(row.containsKey('interactionModel'), isFalse);
      expect(jsonEncode(result.json), isNot(contains('legacyUnknown')));
    });

    test('the frozen catalog itself passes every reader', () async {
      final _JsonRun result = await _runJson(frozenClient(), <String>[
        '--json',
        'catalog',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(
        patchbayCatalogFinding(<String, Object?>{...frozen}).verdict,
        isNot(PatchbayCheckVerdict.failed),
      );
    });
  });
}

FakePatchbayClient _client(Map<String, Object?> row) => FakePatchbayClient(
  commands: <Map<String, Object?>>[row],
  handle: (_, _) async => const <String, Object?>{
    'admission': 'accepted',
    'payload': <String, Object?>{},
  },
);

Future<_JsonRun> _runJson(
  FakePatchbayClient client,
  List<String> arguments,
) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  final String output = out.toString().trim();
  return _JsonRun(
    exitCode,
    output.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(output) as Map<String, dynamic>),
  );
}

Future<_TextRun> _runText(
  FakePatchbayClient client,
  List<String> arguments,
) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return _TextRun(exitCode, out.toString());
}

final class _TextRun {
  const _TextRun(this.exitCode, this.out);

  final int exitCode;
  final String out;
}

final class _JsonRun {
  const _JsonRun(this.exitCode, this.json);

  final int exitCode;
  final Map<String, Object?> json;
}
