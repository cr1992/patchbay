import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('patchbay-command-test-');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test(
    'write/check freeze descriptors, typed defaults, and dispatch surface',
    () async {
      final File contract = File('${temporary.path}/commands.json')
        ..writeAsStringSync(jsonEncode(_fixtureContract()));
      final File output = File('${temporary.path}/commands.g.dart');

      expect(await _run(contract, output, '--write'), 0);
      final String generated = output.readAsStringSync();
      expect(generated, contains('enum MoiiPatchbayCommandId'));
      expect(generated, contains('int get count'));
      expect(
        generated,
        contains('required T Function(MoiiPatchbayDecodedCommand) fixtureRun'),
      );
      expect(generated, contains("defaultValue: 3"));
      expect(await _run(contract, output, '--check'), 0);

      output.writeAsStringSync('$generated// drift\n');
      expect(await _run(contract, output, '--check'), 1);
    },
  );

  test('new command generates another required business callback', () async {
    final Map<String, Object?> contractJson = _fixtureContract();
    (contractJson['commands']! as List<Object?>).add(<String, Object?>{
      'id': 'fixtureStop',
      'name': 'fixture.stop',
      'summary': 'Stop fixture',
      'profile': 'job',
    });
    final File contract = File('${temporary.path}/commands.json')
      ..writeAsStringSync(jsonEncode(contractJson));
    final File output = File('${temporary.path}/commands.g.dart');

    expect(await _run(contract, output, '--write'), 0);
    expect(
      output.readAsStringSync(),
      contains('required T Function(MoiiPatchbayDecodedCommand) fixtureStop'),
    );
  });

  test('invalid confirmation metadata fails closed', () async {
    final Map<String, Object?> contractJson = _fixtureContract();
    final Map<String, Object?> command =
        (contractJson['commands']! as List<Object?>).single
            as Map<String, Object?>;
    command['confirmationArgument'] = 'missing';
    final File contract = File('${temporary.path}/commands.json')
      ..writeAsStringSync(jsonEncode(contractJson));

    expect(
      await _run(
        contract,
        File('${temporary.path}/commands.g.dart'),
        '--write',
      ),
      64,
    );
  });
}

Map<String, Object?> _fixtureContract() => <String, Object?>{
  'contractVersion': 1,
  'library': 'fixture_commands',
  'profiles': <String, Object?>{
    'job': <String, Object?>{
      'mode': 'job',
      'sideEffect': 'external',
      'factSources': <String>['appRecorded'],
      'gates': <String>['fixture.ready'],
    },
  },
  'commands': <Object?>[
    <String, Object?>{
      'id': 'fixtureRun',
      'name': 'fixture.run',
      'summary': 'Run fixture',
      'profile': 'job',
      'parameters': <Object?>[
        <String, Object?>{'name': 'count', 'type': 'integer', 'default': 3},
      ],
    },
  ],
};

Future<int> _run(File contract, File output, String mode) async {
  final ProcessResult result =
      await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/command_codegen.dart',
        '--contract',
        contract.path,
        '--output',
        output.path,
        mode,
      ]);
  return result.exitCode;
}
