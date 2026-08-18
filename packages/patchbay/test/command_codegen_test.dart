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
      // The generator must emit only vocabulary the contract declares — no
      // naming from whatever codebase it was extracted from may survive into
      // a consumer's generated file. Both checks derive from the contract
      // itself rather than blacklisting known-bad strings.
      final Set<String> declaredTypes = _declaredTypes(generated);
      expect(declaredTypes, contains('FixturePatchbayCommandId'));
      expect(
        declaredTypes.where(
          (String name) => !name.startsWith('FixturePatchbay'),
        ),
        isEmpty,
        reason: 'every generated type must derive from the contract apiPrefix',
      );
      expect(
        _declaredCommandIds(generated),
        <String>{'fixtureRun'},
        reason: 'command ids must come from the contract, not the generator',
      );
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
      // Sensitivity stays declared — the host reads it out of the catalog —
      // but the generated validator neither exempts nor re-checks the meta
      // key, because the host strips it before a consumer sees the arguments.
      expect(generated, contains('sensitive: true'));
      expect(generated, contains('!declared.containsKey(key)'));
      expect(generated, isNot(contains('inputWasStdin')));
      expect(generated, isNot(contains('sensitiveInputRequiresStdin')));
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

  test('--check agrees from any working directory', () async {
    // The generated header names the contract, and `--check` compares the
    // whole file — so a header that recorded the caller's spelling of the path
    // made the check depend on the directory it ran from and report drift that
    // was not there. Writing from one directory and checking from another is
    // the whole assertion: the two invocations below name the same two files
    // by different relative paths on purpose.
    final File contract = File('${temporary.path}/commands.json')
      ..writeAsStringSync(jsonEncode(_fixtureContract()));
    final File output = File('${temporary.path}/commands.g.dart');
    final String directory = temporary.uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .last;

    expect(
      await _run(
        contract,
        output,
        '--write',
        workingDirectory: temporary.path,
        contractPath: 'commands.json',
        outputPath: 'commands.g.dart',
      ),
      0,
    );
    expect(
      await _run(
        contract,
        output,
        '--check',
        workingDirectory: temporary.parent.path,
        contractPath: '$directory/commands.json',
        outputPath: '$directory/commands.g.dart',
      ),
      0,
    );
  });

  test('the committed example contract is still current', () async {
    // The repo freezes the complete generated surface by digest rather than
    // carrying a large implementation that nothing imports. `--check`
    // recognizes this snapshot while retaining exact-file checks for normal
    // consumer output.
    expect(
      await _run(
        File('contracts/example_commands.json'),
        File('contracts/example_commands.g.dart'),
        '--check',
      ),
      0,
    );
  });

  test('repository snapshot is compact and detects generated drift', () async {
    final File contract = File('${temporary.path}/commands.json')
      ..writeAsStringSync(jsonEncode(_fixtureContract()));
    final File output = File('${temporary.path}/commands.g.dart');

    expect(await _run(contract, output, '--write-snapshot'), 0);
    final String snapshot = output.readAsStringSync();
    expect(snapshot.split('\n'), hasLength(5));
    expect(snapshot, contains('Generated Dart sha256:'));
    expect(await _run(contract, output, '--check'), 0);

    output.writeAsStringSync(snapshot.replaceFirst('sha256:', 'sha256: drift'));
    expect(await _run(contract, output, '--check'), 1);
  });
}

/// Top-level type names the generated file declares.
Set<String> _declaredTypes(String generated) => RegExp(
  r'^(?:enum|class|extension|mixin) (\w+)',
  multiLine: true,
).allMatches(generated).map((RegExpMatch match) => match.group(1)!).toSet();

/// Command-id enum members the generated file declares. Enum members are the
/// comma-separated names before the first `;` of the enum body.
Set<String> _declaredCommandIds(String generated) {
  final RegExpMatch? body = RegExp(
    r'enum FixturePatchbayCommandId \{([^;]*);',
  ).firstMatch(generated);
  if (body == null) return <String>{};
  return body
      .group(1)!
      .split(',')
      .map((String member) => member.trim())
      .where((String member) => member.isNotEmpty)
      .toSet();
}

Map<String, Object?> _fixtureContract() =>
    jsonDecode(File('contracts/example_commands.json').readAsStringSync())
        as Map<String, Object?>;

/// Runs the generator, by default from the package directory `dart test` uses.
///
/// [workingDirectory], [contractPath] and [outputPath] exist for the one case
/// that has to vary them: proving the result does not depend on where the
/// generator was invoked. The generator script is named absolutely whenever the
/// directory moves, so only the two paths under test change.
Future<int> _run(
  File contract,
  File output,
  String mode, {
  String? workingDirectory,
  String? contractPath,
  String? outputPath,
}) async {
  final ProcessResult result =
      await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        workingDirectory == null
            ? 'tool/command_codegen.dart'
            : File('tool/command_codegen.dart').absolute.path,
        '--contract',
        contractPath ?? contract.path,
        '--output',
        outputPath ?? output.path,
        mode,
      ], workingDirectory: workingDirectory);
  return result.exitCode;
}
