import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('patchbay-wire-test-');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test('write and check modes freeze the generated wire output', () async {
    final File contract = File('${temporary.path}/contract.json')
      ..writeAsStringSync(jsonEncode(_fixtureContract()));
    final File output = File('${temporary.path}/wire.g.dart');

    expect(await _run(contract, output, '--write'), 0);
    expect(output.readAsStringSync(), contains('final class FixtureWire'));
    expect(await _run(contract, output, '--check'), 0);

    output.writeAsStringSync('${output.readAsStringSync()}// drift\n');
    expect(await _run(contract, output, '--check'), 1);
  });

  test('unknown contract keys fail as usage errors', () async {
    final Map<String, Object?> invalid = _fixtureContract();
    final List<Object?> types = invalid['types']! as List<Object?>;
    final Map<String, Object?> fixture = types.single as Map<String, Object?>;
    final List<Object?> fields = fixture['fields']! as List<Object?>;
    (fields.single as Map<String, Object?>)['nullabe'] = true;
    final File contract = File('${temporary.path}/invalid.json')
      ..writeAsStringSync(jsonEncode(invalid));

    expect(
      await _run(contract, File('${temporary.path}/wire.g.dart'), '--write'),
      64,
    );
  });
}

Map<String, Object?> _fixtureContract() => <String, Object?>{
  'contractVersion': 1,
  'library': 'fixture_wire',
  'types': <Object?>[
    <String, Object?>{
      'kind': 'object',
      'name': 'FixtureWire',
      'fields': <Object?>[
        <String, Object?>{'name': 'value', 'type': 'String'},
      ],
    },
  ],
};

Future<int> _run(File contract, File output, String mode) async {
  final ProcessResult result =
      await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/wire_codegen.dart',
        '--contract',
        contract.path,
        '--output',
        output.path,
        mode,
      ]);
  return result.exitCode;
}
