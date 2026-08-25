import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:yaml/yaml.dart';

const String commandReferenceStart =
    '<!-- PATCHBAY_COMMAND_REFERENCE:START -->';
const String commandReferenceEnd = '<!-- PATCHBAY_COMMAND_REFERENCE:END -->';
const String _managedSkillName = 'use-patchbay';
const String _skillDocument = '../../skills/$_managedSkillName/SKILL.md';

const List<({String path, bool chinese})> _documents =
    <({String path, bool chinese})>[
      (path: '../../README.md', chinese: false),
      (path: '../../README.zh-CN.md', chinese: true),
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
    updates.add((
      file: skill,
      updated: replaceCommandReferenceBlock(
        currentSkill,
        renderSkillStarterCommands(),
        source: skill.path,
      ),
    ));

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
      ..writeln('| CLI 语法 | 声明来源 | 协议命令 |')
      ..writeln('|---|---|---|');
  } else {
    out
      ..writeln(
        'This table describes syntax shipped by this CLI. Protocol-backed rows '
        'come from repository descriptors; client and local rows remain '
        'explicit CLI declarations. It is not the runtime capability catalog; '
        'use `patchbay catalog` for actual availability.',
      )
      ..writeln()
      ..writeln('| CLI syntax | Declaration source | Protocol command |')
      ..writeln('|---|---|---|');
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
    final String protocol = command.serviceCommand == null
        ? '—'
        : '`${_escape(command.serviceCommand!)}`';
    out.writeln(
      '| `${_escape(syntax)}` | ${_escape(source)} | '
      '$protocol |',
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

String _escape(String value) => value.replaceAll('|', r'\|');
