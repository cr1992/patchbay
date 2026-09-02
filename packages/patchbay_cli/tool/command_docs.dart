import 'dart:io';

import 'package:patchbay_cli/src/command_registry.dart';
import 'package:yaml/yaml.dart';

const String commandReferenceStart =
    '<!-- PATCHBAY_COMMAND_REFERENCE:START -->';
const String commandReferenceEnd = '<!-- PATCHBAY_COMMAND_REFERENCE:END -->';
const String uiMigrationStart = '<!-- PATCHBAY_UI_MIGRATION:START -->';
const String uiMigrationEnd = '<!-- PATCHBAY_UI_MIGRATION:END -->';
const String _managedSkillName = 'use-patchbay';
const String _skillDocument = '../../skills/$_managedSkillName/SKILL.md';
const String _releaseDocument = '../../docs/releases/0.6.0.md';
const String _deprecatedFragment =
    '../../changelog.d/0.6.0/PB-060-01.deprecated.md';

const List<({String path, bool chinese})> _documents =
    <({String path, bool chinese})>[
      (path: 'README.md', chinese: false),
      (path: 'README.zh-CN.md', chinese: true),
    ];

void main(List<String> arguments) {
  exitCode = runCommandDocs(arguments);
}

int runCommandDocs(
  List<String> arguments, {
  Directory? packageDirectory,
  void Function(String message)? writeOutput,
  void Function(String message)? writeError,
}) {
  final Directory root = packageDirectory ?? Directory.current;
  final void Function(String message) output = writeOutput ?? stdout.writeln;
  final void Function(String message) error = writeError ?? stderr.writeln;
  final bool check = arguments.length == 1 && arguments.single == '--check';
  final bool write = arguments.length == 1 && arguments.single == '--write';
  if (!check && !write) {
    error('usage: command_docs (--check|--write)');
    return 64;
  }

  try {
    final List<({File file, String updated})> updates =
        <({File file, String updated})>[];
    for (final ({String path, bool chinese}) document in _documents) {
      final File file = File('${root.path}/${document.path}');
      if (!file.existsSync()) {
        throw FormatException('managed document does not exist: ${file.path}');
      }
      final String current = file.readAsStringSync();
      updates.add((
        file: file,
        updated: replaceCommandReferenceBlock(
          current,
          renderCommandReference(chinese: document.chinese),
          source: file.path,
        ),
      ));
    }
    final File skill = File('${root.path}/$_skillDocument');
    if (!skill.existsSync()) {
      throw FormatException('managed document does not exist: ${skill.path}');
    }
    final String currentSkill = skill.readAsStringSync();
    validateSkillDocument(
      currentSkill,
      source: skill.path,
      expectedName: _managedSkillName,
    );
    final File install = File('${skill.parent.path}/INSTALL.md');
    if (!install.existsSync()) {
      throw FormatException('managed document does not exist: ${install.path}');
    }
    final String updatedSkill = replaceUiMigrationBlock(
      replaceCommandReferenceBlock(
        currentSkill,
        renderSkillStarterCommands(),
        source: skill.path,
      ),
      renderUiMigrationTable(chinese: false),
      source: skill.path,
    );
    updates.add((file: skill, updated: updatedSkill));
    for (final ({String path, bool chinese, String indent}) document
        in <({String path, bool chinese, String indent})>[
          (path: _releaseDocument, chinese: true, indent: ''),
          (path: _deprecatedFragment, chinese: true, indent: '  '),
        ]) {
      final File file = File('${root.path}/${document.path}');
      if (!file.existsSync()) {
        // Release preparation consumes changelog fragments. Keep generating
        // this migration table while the fragment is queued, but do not make
        // the permanent docs generator depend on a released input forever.
        if (document.path == _deprecatedFragment) continue;
        throw FormatException('managed document does not exist: ${file.path}');
      }
      updates.add((
        file: file,
        updated: replaceUiMigrationBlock(
          file.readAsStringSync(),
          renderUiMigrationTable(
            chinese: document.chinese,
            indent: document.indent,
          ),
          source: file.path,
        ),
      ));
    }

    final List<({File file, String updated})> drifted = updates
        .where(
          (({File file, String updated}) update) =>
              update.file.readAsStringSync() != update.updated,
        )
        .toList(growable: false);
    if (check) {
      if (drifted.isNotEmpty) {
        for (final ({File file, String updated}) update in drifted) {
          error('Generated command docs drifted: ${update.file.path}');
        }
        error('Run: dart run tool/command_docs.dart --write');
        return 1;
      }
      output('Generated command documentation is current.');
      return 0;
    }

    // Validate every file and compute every replacement before the first
    // write, so a missing or duplicate marker cannot leave a partial update.
    for (final ({File file, String updated}) update in drifted) {
      update.file.writeAsStringSync(update.updated);
      output('Updated ${update.file.path}');
    }
    return 0;
  } on FormatException catch (error) {
    (writeError ?? stderr.writeln)(
      'Command documentation generation failed: ${error.message}',
    );
    return 1;
  }
}

String renderCommandReference({required bool chinese}) {
  final List<PatchbayFriendlyCommandSpec> commands =
      PatchbayFriendlyCommandRegistry.commands.toList(growable: false)..sort(
        (PatchbayFriendlyCommandSpec left, PatchbayFriendlyCommandSpec right) =>
            left.path.join(' ').compareTo(right.path.join(' ')),
      );
  final StringBuffer out = StringBuffer();
  if (chinese) {
    out
      ..writeln(
        '下表只描述当前 CLI 随包发布的语法。协议命令行来自仓内 descriptor；'
        'client / local 行仍来自 CLI 的显式声明。它不是运行时 capability catalog，'
        '实际可用性请以 `patchbay catalog` 为准。',
      )
      ..writeln()
      ..writeln('| CLI 语法 | 声明来源 | 协议命令 | 状态 / 迁移 |')
      ..writeln('|---|---|---|---|');
  } else {
    out
      ..writeln(
        'This table describes syntax shipped by this CLI. Protocol-backed rows '
        'come from repository descriptors; client and local rows remain '
        'explicit CLI declarations. It is not the runtime capability catalog; '
        'use `patchbay catalog` for actual availability.',
      )
      ..writeln()
      ..writeln(
        '| CLI syntax | Declaration source | Protocol command | '
        'Status / migration |',
      )
      ..writeln('|---|---|---|---|');
  }
  for (final PatchbayFriendlyCommandSpec command in commands) {
    final String syntax = <String>[
      'patchbay',
      ...command.path,
      if (command.usageSuffix.isNotEmpty) command.usageSuffix,
    ].join(' ');
    final String source = command.protocolDescriptor != null
        ? (chinese ? '协议 descriptor' : 'protocol descriptor')
        : _explicitSource(command.target, chinese: chinese);
    final String protocol = _protocolCommands(command);
    final PatchbayUiCommandMigration? migration =
        PatchbayFriendlyCommandRegistry.uiMigrationFor(command.path);
    final String status = migration == null
        ? (chinese ? '当前入口' : 'current')
        : chinese
        ? '0.6.0 deprecated；改用 `patchbay ${_escape(migration.replacement)}`；'
              '1.0 删除'
        : 'deprecated in 0.6.0; use '
              '`patchbay ${_escape(migration.replacement)}`; removed in 1.0';
    out.writeln(
      '| `${_escape(syntax)}` | ${_escape(source)} | '
      '$protocol | $status |',
    );
  }
  return out.toString().trimRight();
}

String renderSkillStarterCommands() {
  const List<String> starterNames = <String>[
    'doctor',
    'identity',
    'catalog',
    'snapshot',
    'describe',
  ];
  final Map<String, PatchbayFriendlyCommandSpec> commands =
      <String, PatchbayFriendlyCommandSpec>{
        for (final PatchbayFriendlyCommandSpec command
            in PatchbayFriendlyCommandRegistry.commands)
          command.name: command,
      };
  final StringBuffer out = StringBuffer()
    ..writeln('Run the smallest read-only sequence that can answer the task:');
  for (final String name in starterNames) {
    final PatchbayFriendlyCommandSpec? command = commands[name];
    if (command == null) {
      throw StateError('Skill starter command is not registered: $name');
    }
    final String syntax = <String>[
      'patchbay',
      ...command.path,
      if (command.usageSuffix.isNotEmpty) command.usageSuffix,
    ].join(' ');
    out.writeln('- `${_escape(syntax)}` — ${command.summary}');
  }
  return out.toString().trimRight();
}

String renderUiMigrationTable({required bool chinese, String indent = ''}) {
  final StringBuffer out = StringBuffer();
  void line(String value) => out.writeln('$indent$value');
  if (chinese) {
    line('| 0.6.0 deprecated 旧入口 | canonical 替代 | 删除版本 |');
  } else {
    line('| Deprecated in 0.6.0 | Canonical replacement | Removal |');
  }
  line('|---|---|---|');
  for (final PatchbayUiCommandMigration migration
      in PatchbayFriendlyCommandRegistry.uiMigrations) {
    line(
      '| `${_escape(migration.legacyCommand)}` | '
      '`${_escape(migration.replacement)}` | 1.0 |',
    );
  }
  return out.toString().trimRight();
}

void validateSkillDocument(
  String document, {
  String source = 'SKILL.md',
  String? expectedName,
}) {
  final RegExpMatch? match = RegExp(
    r'^---\n([\s\S]*?)\n---(?:\n|$)',
  ).firstMatch(document);
  if (match == null) {
    throw FormatException('$source must start with YAML frontmatter');
  }

  final Object? parsed;
  try {
    parsed = loadYaml(match.group(1)!);
  } on YamlException catch (error) {
    throw FormatException('$source has invalid YAML frontmatter: $error');
  }
  if (parsed is! YamlMap) {
    throw FormatException('$source frontmatter must be a YAML map');
  }

  const Set<String> allowed = <String>{
    'name',
    'description',
    'license',
    'allowed-tools',
    'metadata',
  };
  final Set<String> keys = parsed.keys.map((Object? key) => '$key').toSet();
  final List<String> unexpected = keys.difference(allowed).toList()..sort();
  if (unexpected.isNotEmpty) {
    throw FormatException(
      '$source has unsupported frontmatter keys: ${unexpected.join(', ')}',
    );
  }

  final Object? rawName = parsed['name'];
  final Object? rawDescription = parsed['description'];
  if (rawName is! String ||
      !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(rawName) ||
      rawName.length > 64) {
    throw FormatException('$source has an invalid skill name');
  }
  if (expectedName != null && rawName != expectedName) {
    throw FormatException(
      '$source has skill name "$rawName"; expected "$expectedName"',
    );
  }
  if (rawDescription is! String ||
      rawDescription.trim().isEmpty ||
      rawDescription.length > 1024 ||
      rawDescription.contains('<') ||
      rawDescription.contains('>') ||
      rawDescription.trimLeft().startsWith('[TODO:')) {
    throw FormatException('$source has an invalid skill description');
  }
  final String body = document.substring(match.end);
  if (RegExp(
    r'^ {0,3}\[TODO:[^\n]*\][ \t]*$',
    multiLine: true,
  ).hasMatch(body)) {
    throw FormatException('$source contains an unfinished TODO placeholder');
  }
}

String replaceCommandReferenceBlock(
  String document,
  String generated, {
  String source = 'document',
}) {
  final List<int> starts = _markerOffsets(document, commandReferenceStart);
  final List<int> ends = _markerOffsets(document, commandReferenceEnd);
  if (starts.length != 1 || ends.length != 1) {
    throw FormatException(
      '$source must contain exactly one command reference marker pair '
      '(start=${starts.length}, end=${ends.length})',
    );
  }
  final int start = starts.single;
  final int end = ends.single;
  if (end <= start) {
    throw FormatException('$source command reference markers are out of order');
  }
  final int bodyStart = start + commandReferenceStart.length;
  return '${document.substring(0, bodyStart)}\n$generated\n'
      '${document.substring(end)}';
}

String replaceUiMigrationBlock(
  String document,
  String generated, {
  String source = 'document',
}) => _replaceManagedBlock(
  document,
  generated,
  startMarker: uiMigrationStart,
  endMarker: uiMigrationEnd,
  label: 'UI migration',
  source: source,
);

String _replaceManagedBlock(
  String document,
  String generated, {
  required String startMarker,
  required String endMarker,
  required String label,
  required String source,
}) {
  final List<int> starts = _markerOffsets(document, startMarker);
  final List<int> ends = _markerOffsets(document, endMarker);
  if (starts.length != 1 || ends.length != 1) {
    throw FormatException(
      '$source must contain exactly one $label marker pair '
      '(start=${starts.length}, end=${ends.length})',
    );
  }
  final int start = starts.single;
  final int end = ends.single;
  if (end <= start) {
    throw FormatException('$source $label markers are out of order');
  }
  final int bodyStart = start + startMarker.length;
  final int endLineStart = document.lastIndexOf('\n', end - 1) + 1;
  final String endIndent = document.substring(endLineStart, end);
  if (endIndent.trim().isNotEmpty) {
    throw FormatException('$source $label end marker must start its own line');
  }
  return '${document.substring(0, bodyStart)}\n$generated\n'
      '${document.substring(endLineStart)}';
}

List<int> _markerOffsets(String input, String marker) {
  final List<int> offsets = <int>[];
  var from = 0;
  while (true) {
    final int index = input.indexOf(marker, from);
    if (index < 0) return offsets;
    offsets.add(index);
    from = index + marker.length;
  }
}

String _explicitSource(PatchbayCommandTarget target, {required bool chinese}) {
  return switch (target.declarationSource) {
    PatchbayCommandDeclarationSource.local =>
      chinese ? 'local 显式声明' : 'local CLI declaration',
    PatchbayCommandDeclarationSource.client =>
      chinese ? 'client 显式声明' : 'client CLI declaration',
  };
}

String _protocolCommands(PatchbayFriendlyCommandSpec command) {
  final Set<String> commands = switch (command) {
    PatchbayCanonicalUiCommandSpec(:final routes) => <String>{
      for (final PatchbayCanonicalUiRoute route in routes) route.serviceCommand,
    },
    _ when command.serviceCommand != null => <String>{command.serviceCommand!},
    _ => const <String>{},
  };
  if (commands.isEmpty) return '—';
  final List<String> sorted = commands.toList()..sort();
  return sorted.map((String value) => '`${_escape(value)}`').join(' / ');
}

String _escape(String value) => value.replaceAll('|', r'\|');
