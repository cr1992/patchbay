/// DG-060-05 on the CLI side: `--json describe` stays a transparent
/// passthrough of whatever the catalog row declares (no synthesised
/// `legacyUnknown` in stable JSON); `legacyUnknown` only shows up in the
/// human-readable summary line; and an unknown declared value fails the
/// *whole* catalog before any RPC is sent, matching the host-side
/// fail-closed shape (`packages/patchbay/test/host/
/// interaction_model_catalog_test.dart`).
library;

import 'dart:convert';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
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

      final String text = await _runText(client, <String>[
        'describe',
        'ui.text.set',
      ]);
      expect(text, contains('interactionModel=legacyUnknown'));
      expect(text, contains('not declared by this host'));
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

      final String text = await _runText(client, <String>[
        'describe',
        'ui.text.set',
      ]);
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

        final String text = await _runText(client, <String>[
          'describe',
          'ui.gesture.tap',
        ]);
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

Future<String> _runText(
  FakePatchbayClient client,
  List<String> arguments,
) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return out.toString();
}

final class _JsonRun {
  const _JsonRun(this.exitCode, this.json);

  final int exitCode;
  final Map<String, Object?> json;
}
