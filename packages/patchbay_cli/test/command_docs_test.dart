import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import '../tool/command_docs.dart' as docs;

void main() {
  test('generated command reference keeps each declaration source honest', () {
    final String rendered = docs.renderCommandReference(chinese: false);

    expect(
      rendered,
      contains('| `patchbay navigation catalog` | protocol descriptor |'),
    );
    expect(
      rendered,
      contains('| `patchbay identity` | client CLI declaration | — |'),
    );
    expect(
      rendered,
      contains('| `patchbay sessions list` | local CLI declaration | — |'),
    );
    expect(rendered, contains('not the runtime capability catalog'));
  });

  test('every explicit command uses its target authoritative source', () {
    final String rendered = docs.renderCommandReference(chinese: false);

    for (final PatchbayFriendlyCommandSpec command
        in PatchbayFriendlyCommandRegistry.commands.where(
          (PatchbayFriendlyCommandSpec command) =>
              command.protocolDescriptor == null,
        )) {
      final String source = switch (command.target.declarationSource) {
        PatchbayCommandDeclarationSource.client => 'client CLI declaration',
        PatchbayCommandDeclarationSource.local => 'local CLI declaration',
      };
      final String syntax = <String>[
        'patchbay',
        ...command.path,
        if (command.usageSuffix.isNotEmpty) command.usageSuffix,
      ].join(' ').replaceAll('|', r'\|');
      expect(
        rendered,
        contains('| `$syntax` | $source |'),
        reason: '${command.name} must follow ${command.target.name}',
      );
    }
  });

  test(
    'Skill starter commands come from the registry and remain read-only',
    () {
      final String rendered = docs.renderSkillStarterCommands();

      expect(rendered, contains('`patchbay doctor`'));
      expect(rendered, contains('`patchbay identity`'));
      expect(rendered, contains('`patchbay catalog`'));
      expect(rendered, contains('`patchbay snapshot [--path <dot.path>]`'));
      expect(rendered, contains('`patchbay describe <service-command>`'));
      expect(rendered, isNot(contains('`patchbay exec')));
      expect(rendered, isNot(contains('`patchbay ui')));
    },
  );

  test('Skill frontmatter validation accepts the checked-in shape', () {
    expect(
      () => docs.validateSkillDocument('''---
name: use-patchbay
description: Inspect a running App through Patchbay.
---

Instructions.
''', expectedName: 'use-patchbay'),
      returnsNormally,
    );
  });

  test('Skill frontmatter validation fails closed', () {
    for (final String invalid in <String>[
      'instructions only',
      '''---
name: Use_Patchbay
description: Invalid name.
---
''',
      '''---
name: use-patchbay
description: Valid description.
unexpected: true
---
''',
      '''---
name: use-patchbay
description: Valid description.
---

[TODO: finish]
''',
    ]) {
      expect(
        () => docs.validateSkillDocument(invalid, expectedName: 'use-patchbay'),
        throwsFormatException,
        reason: invalid,
      );
    }
  });

  test('managed Skill frontmatter rejects a different valid name', () {
    const String document = '''---
name: another-valid-skill
description: Valid description with a different name.
---
''';

    expect(() => docs.validateSkillDocument(document), returnsNormally);
    expect(
      () => docs.validateSkillDocument(document, expectedName: 'use-patchbay'),
      throwsFormatException,
    );
  });

  test('managed replacement is idempotent and preserves prose', () {
    const String original =
        '''before
${docs.commandReferenceStart}
old rows
${docs.commandReferenceEnd}
after
''';

    final String once = docs.replaceCommandReferenceBlock(
      original,
      'generated rows',
    );
    final String twice = docs.replaceCommandReferenceBlock(
      once,
      'generated rows',
    );

    expect(twice, once);
    expect(once, startsWith('before\n'));
    expect(once, endsWith('after\n'));
    expect(once, isNot(contains('old rows')));
  });

  for (final ({String name, String document}) fixture
      in <({String name, String document})>[
        (name: 'missing markers', document: 'handwritten only'),
        (
          name: 'duplicate markers',
          document:
              '${docs.commandReferenceStart}${docs.commandReferenceStart}'
              '${docs.commandReferenceEnd}',
        ),
        (
          name: 'reversed markers',
          document: '${docs.commandReferenceEnd}${docs.commandReferenceStart}',
        ),
      ]) {
    test('${fixture.name} fails closed', () {
      expect(
        () => docs.replaceCommandReferenceBlock(
          fixture.document,
          'generated',
          source: 'fixture.md',
        ),
        throwsFormatException,
      );
    });
  }

  test('checked-in command documents have no generation drift', () async {
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'tool/command_docs.dart', '--check'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('write is idempotent and check detects managed-block drift', () {
    final _Fixture fixture = _Fixture.create();
    addTearDown(fixture.dispose);

    expect(
      docs.runCommandDocs(
        const <String>['--write'],
        packageDirectory: fixture.packageDirectory,
        writeOutput: (_) {},
      ),
      0,
    );
    final Map<String, String> once = fixture.contents();
    expect(
      docs.runCommandDocs(
        const <String>['--write'],
        packageDirectory: fixture.packageDirectory,
        writeOutput: (_) {},
      ),
      0,
    );
    expect(fixture.contents(), once);
    expect(
      docs.runCommandDocs(
        const <String>['--check'],
        packageDirectory: fixture.packageDirectory,
        writeOutput: (_) {},
      ),
      0,
    );

    fixture.files.first.writeAsStringSync(
      fixture.files.first.readAsStringSync().replaceFirst(
        '| CLI syntax |',
        '| drifted syntax |',
      ),
    );
    expect(
      docs.runCommandDocs(
        const <String>['--check'],
        packageDirectory: fixture.packageDirectory,
        writeError: (_) {},
      ),
      1,
    );
  });

  test('write rejects a missing marker before changing any document', () {
    final _Fixture fixture = _Fixture.create();
    addTearDown(fixture.dispose);
    fixture.files.last.writeAsStringSync('marker missing\n');
    final Map<String, String> before = fixture.contents();

    expect(
      docs.runCommandDocs(
        const <String>['--write'],
        packageDirectory: fixture.packageDirectory,
        writeError: (_) {},
      ),
      1,
    );
    expect(fixture.contents(), before);
  });
}

final class _Fixture {
  _Fixture(this.root, this.packageDirectory, this.files);

  factory _Fixture.create() {
    final Directory root = Directory.systemTemp.createTempSync(
      'patchbay-command-docs-',
    );
    final Directory packageDirectory = Directory(
      '${root.path}/packages/patchbay_cli',
    )..createSync(recursive: true);
    final List<File> files = <File>[
      File('${root.path}/README.md'),
      File('${root.path}/README.zh-CN.md'),
      File('${packageDirectory.path}/README.md'),
      File('${packageDirectory.path}/README.zh-CN.md'),
      File('${root.path}/skills/use-patchbay/SKILL.md'),
    ];
    for (final File file in files) {
      file.parent.createSync(recursive: true);
      final String frontmatter = file.path.endsWith('/SKILL.md')
          ? '''---
name: use-patchbay
description: Inspect a running App through Patchbay.
---

'''
          : '';
      file.writeAsStringSync('''${frontmatter}handwritten before
${docs.commandReferenceStart}
old generated block
${docs.commandReferenceEnd}
handwritten after
''');
    }
    File('${root.path}/skills/use-patchbay/INSTALL.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Install\n');
    return _Fixture(root, packageDirectory, files);
  }

  final Directory root;
  final Directory packageDirectory;
  final List<File> files;

  Map<String, String> contents() => <String, String>{
    for (final File file in files) file.path: file.readAsStringSync(),
  };

  void dispose() => root.deleteSync(recursive: true);
}
