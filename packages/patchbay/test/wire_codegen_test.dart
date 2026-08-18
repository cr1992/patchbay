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
    final Directory package = Directory('${temporary.path}/packages/patchbay')
      ..createSync(recursive: true);
    final File contract = File('${package.path}/contracts/core_wire.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(_fixtureContract()));
    File('${package.path}/lib/src/service_host.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        'final class PatchbayServiceHost {\n'
        '  static const int schemaVersion = 7;\n'
        '}\n',
      );
    File('${temporary.path}/packages/patchbay_cli/lib/client.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('PatchbayFixtureWire.fromJson(json);\n');
    Directory(
      '${temporary.path}/packages/patchbay_transport/lib',
    ).createSync(recursive: true);
    final File output = File('${package.path}/lib/src/generated/wire.g.dart');
    final File golden = File('${package.path}/test/golden/wire_surface.json');

    expect(await _run(contract, output, '--write'), 0);
    expect(
      output.readAsStringSync(),
      contains('final class PatchbayFixtureWire'),
    );
    expect(jsonDecode(golden.readAsStringSync()), <String, Object?>{
      'schemaVersion': 7,
      'strictlyDecodedByShippedClients': <String>['PatchbayFixtureWire'],
      'types': <String, Object?>{
        'PatchbayFixtureWire': <String, Object?>{
          'kind': 'object',
          'fields': <String>['value'],
        },
      },
    });
    expect(await _run(contract, output, '--check'), 0);

    final String generated = output.readAsStringSync();
    final String surface = golden.readAsStringSync();
    expect(await _run(contract, output, '--write'), 0);
    expect(output.readAsStringSync(), generated);
    expect(golden.readAsStringSync(), surface);

    output.writeAsStringSync('${output.readAsStringSync()}// drift\n');
    expect(await _run(contract, output, '--check'), 1);
    expect(await _run(contract, output, '--write'), 0);

    golden.writeAsStringSync('${golden.readAsStringSync()} ');
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

  test('non-core contracts retain single-output generation', () async {
    final File contract = File('${temporary.path}/contract.json')
      ..writeAsStringSync(
        jsonEncode(_fixtureContract(library: 'consumer_wire')),
      );
    final File output = File('${temporary.path}/wire.g.dart');

    expect(await _run(contract, output, '--write'), 0);
    expect(output.existsSync(), isTrue);
    expect(await _run(contract, output, '--check'), 0);
  });
}

Map<String, Object?> _fixtureContract({
  String library = 'patchbay_core_wire',
}) => <String, Object?>{
  'contractVersion': 1,
  'library': library,
  'types': <Object?>[
    <String, Object?>{
      'kind': 'object',
      'name': 'PatchbayFixtureWire',
      'fields': <Object?>[
        <String, Object?>{'name': 'value', 'type': 'String'},
      ],
    },
  ],
};

Future<int> _run(File contract, File output, String mode) async {
  final String generator = File('tool/wire_codegen.dart').absolute.path;
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>[
      'run',
      generator,
      '--contract',
      contract.path,
      '--output',
      output.path,
      mode,
    ],
  );
  return result.exitCode;
}
