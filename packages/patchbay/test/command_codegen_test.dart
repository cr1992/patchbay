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
      expect(generated, contains("import 'package:patchbay/patchbay.dart';"));
      expect(generated, isNot(contains('patchbay_flutter')));
      expect(generated, contains('enum FixturePatchbayCommandId'));
      expect(generated, isNot(contains('Moii')));
      expect(generated, isNot(contains('bleProvisioning')));
      expect(generated, isNot(contains('wifiSsid')));
      expect(generated, contains('enum FixturePatchbayPermission'));
      expect(generated, contains('FixturePatchbayPermission.fixtureAccess'));
      expect(generated, contains('FixturePatchbayCancellation.fixtureStop'));
      expect(generated, contains('int get count'));
      expect(
        generated,
        contains(
          'required T Function(FixturePatchbayDecodedCommand) fixtureRun',
        ),
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
      contains(
        'required T Function(FixturePatchbayDecodedCommand) fixtureStop',
      ),
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

  test('command fact-source override uses the closed vocabulary', () async {
    final Map<String, Object?> contractJson = _fixtureContract();
    final Map<String, Object?> command =
        (contractJson['commands']! as List<Object?>).single
            as Map<String, Object?>;
    command['factSources'] = <String>['appRuntime'];
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

  test(
    'command names require stable lowercase-starting dotted segments',
    () async {
      final Map<String, Object?> contractJson = _fixtureContract();
      final Map<String, Object?> command =
          (contractJson['commands']! as List<Object?>).single
              as Map<String, Object?>;
      command['name'] = 'Fixture Run';
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
    },
  );

  test('descriptor import is restricted to Patchbay exports', () async {
    final Map<String, Object?> contractJson = _fixtureContract()
      ..['descriptorImport'] = 'package:flutter/widgets.dart';
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
  'contractVersion': 2,
  'apiPrefix': 'FixturePatchbay',
  'descriptorImport': 'package:patchbay/patchbay.dart',
  'permissions': <String>['fixtureAccess'],
  'cancellations': <String>['fixtureStop'],
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
      'permissions': <String>['fixtureAccess'],
      'cancellation': 'fixtureStop',
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
