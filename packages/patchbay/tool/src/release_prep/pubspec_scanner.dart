// pubspec 与相关版本引用极小扫描与改写。

import 'constants.dart';
import 'models.dart';

/// `^X.Y.Z` 形式的约束是否接纳 [version]；不是 caret 形式返回 null（交人工判断）。
bool? caretAdmits(String constraint, Version version) {
  final String trimmed = constraint.trim();
  if (!trimmed.startsWith('^')) return null;
  final Version? base = Version.tryParse(trimmed.substring(1));
  if (base == null) return null;
  return version.compareTo(base) >= 0 &&
      version.compareTo(base.caretUpperBound) < 0;
}

/// 把 pubspec 切成顶层键 -> 该键下的缩进行。
Map<String, List<String>> topLevelBlocks(String yaml) {
  final blocks = <String, List<String>>{};
  String? current;
  for (final String line in yaml.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final RegExpMatch? top = RegExp(
      r'^([A-Za-z_][A-Za-z0-9_]*):',
    ).firstMatch(line);
    if (top != null) {
      current = top.group(1);
      blocks[current!] = <String>[];
      final String inline = line.substring(top.end).trim();
      if (inline.isNotEmpty) blocks[current]!.add(line);
      continue;
    }
    if (current != null) blocks[current]!.add(line);
  }
  return blocks;
}

/// 读顶层标量字段（`version` / `description` / `publish_to` / `repository`）。
String? readPubspecField(String yaml, String field) {
  final RegExpMatch? match = RegExp(
    '^$field:[ \\t]*(.*)\$',
    multiLine: true,
  ).firstMatch(yaml);
  if (match == null) return null;
  final String raw = match.group(1)!.trim();
  if (raw.isEmpty) return null;
  return unquote(raw);
}

String? readPubspecVersion(String yaml) => readPubspecField(yaml, 'version');

/// 改写 `version:` 行；找不到就抛，不静默新增（pubspec 缺 version 是另一个问题）。
String applyPubspecVersion(String yaml, String version) {
  final RegExp pattern = RegExp(r'^version:[ \t]*.*$', multiLine: true);
  if (!pattern.hasMatch(yaml)) {
    throw const FormatException('pubspec 缺 version 字段');
  }
  return yaml.replaceFirst(pattern, 'version: $version');
}

final RegExp _packageVersionPattern = RegExp(
  r"(const\s+String\s+patchbayPackageVersion\s*=\s*')([^']+)(';)",
);

/// 只改写对外作为 `serverVersion` 暴露的随包版本常量。
///
/// 缺失或出现多份都拒绝，避免在常量改名后静默写入一个无效位置。
String applyPackageVersionSource(String source, String version) {
  final List<RegExpMatch> matches = _packageVersionPattern
      .allMatches(source)
      .toList(growable: false);
  if (matches.length != 1) {
    throw FormatException(
      '应恰好找到一个 patchbayPackageVersion，实际 ${matches.length} 个',
    );
  }
  final RegExpMatch match = matches.single;
  return source.replaceRange(
    match.start,
    match.end,
    '${match.group(1)}$version${match.group(3)}',
  );
}

final List<RegExp> _managedRootReadmeVersionPatterns = <RegExp>[
  RegExp(
    r'(^> \*\*(?:Project status:|项目状态：)\*\* `v)([^`]+)(`)',
    multiLine: true,
  ),
  RegExp(r'(^\s*patchbay_flutter:\s*\^)([^\s]+)(\s*$)', multiLine: true),
  RegExp(
    r'(^\$ dart pub global activate patchbay_cli\s+)([^\s]+)(\s*$)',
    multiLine: true,
  ),
];

final List<RegExp> _managedGuideVersionPatterns = <RegExp>[
  RegExp(r'(^\s*patchbay_flutter:\s*\^)([^\s]+)(\s*$)', multiLine: true),
  RegExp(
    r'(^\$ dart pub global activate patchbay_cli\s+)([^\s]+)(\s*$)',
    multiLine: true,
  ),
];

final List<RegExp> _managedCliReadmeVersionPatterns = <RegExp>[
  RegExp(
    r'(^\$ dart pub global activate patchbay_cli\s+)([^\s]+)(\s*$)',
    multiLine: true,
  ),
];

final RegExp _managedReadmeArtifactPattern = RegExp(
  r'(/releases/download/patchbay-v)([^/]+)(/patchbay-)([^/\s]+?)(-(?:linux|macos|windows)-)',
);

String _applyVersionPatterns(
  String document,
  String version,
  List<RegExp> patterns, {
  required String label,
}) {
  var result = document;
  for (final RegExp pattern in patterns) {
    final List<RegExpMatch> matches = pattern
        .allMatches(result)
        .toList(growable: false);
    if (matches.length != 1) {
      throw FormatException(
        '$label 版本锚点应恰好出现一次，实际 ${matches.length} 个：$pattern',
      );
    }
    final RegExpMatch match = matches.single;
    result = result.replaceRange(
      match.start,
      match.end,
      '${match.group(1)}$version${match.group(3)}',
    );
  }
  return result;
}

String _applyArtifactVersion(String document, String version, String label) {
  final List<RegExpMatch> artifacts = _managedReadmeArtifactPattern
      .allMatches(document)
      .toList(growable: false);
  if (artifacts.length != 1) {
    throw FormatException('$label AOT 下载锚点应恰好出现一次，实际 ${artifacts.length} 个');
  }
  final RegExpMatch artifact = artifacts.single;
  return document.replaceRange(
    artifact.start,
    artifact.end,
    '${artifact.group(1)}$version${artifact.group(3)}$version${artifact.group(5)}',
  );
}

/// 同步根 README 中明确由发版流程管理的状态、hosted 安装与 AOT 下载版本。
///
/// 每个锚点必须恰好出现一次；README 结构漂移时 fail-closed，而不是泛化替换文档里的历史版本。
String applyReadmeVersionReferences(String markdown, String version) {
  final String result = _applyVersionPatterns(
    markdown,
    version,
    _managedRootReadmeVersionPatterns,
    label: 'README',
  );
  return _applyArtifactVersion(result, version, 'README');
}

/// 按文件同步当前文档的受管版本锚点；长期设计文档与 SVG 不做版本替换。
String applyReleaseDocumentVersionReferences(
  String path,
  String document,
  String version,
) => switch (path) {
  'README.md' ||
  'README.zh-CN.md' => applyReadmeVersionReferences(document, version),
  'docs/guide.md' => _applyArtifactVersion(
    _applyVersionPatterns(
      document,
      version,
      _managedGuideVersionPatterns,
      label: path,
    ),
    version,
    path,
  ),
  'packages/patchbay_cli/README.md' ||
  'packages/patchbay_cli/README.zh-CN.md' => _applyVersionPatterns(
    document,
    version,
    _managedCliReadmeVersionPatterns,
    label: path,
  ),
  _ => throw FormatException('不是受管版本文档：$path'),
};

/// 删掉 `publish_to: none` 这一行——**发布开关**，只在显式 `--enable-publish` 时执行。
String applyRemovePublishTo(String yaml) => yaml.replaceFirst(
  RegExp(r'^publish_to:[ \t]*none[ \t]*\r?\n', multiLine: true),
  '',
);

/// 解析依赖块：依赖名 -> 它下面的缩进行（内联写法则为空表）。
Map<String, List<String>> parseDependencyBlock(String yaml, String blockName) {
  final List<String>? lines = topLevelBlocks(yaml)[blockName];
  if (lines == null) return const <String, List<String>>{};
  final entries = <String, List<String>>{};
  String? current;
  for (final String line in lines) {
    final RegExpMatch? entry = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$',
    ).firstMatch(line);
    if (entry != null) {
      current = entry.group(1);
      entries[current!] = <String>[];
      continue;
    }
    if (current != null && line.startsWith('    ')) entries[current]!.add(line);
  }
  return entries;
}

/// 依赖块里写成一行的条目：依赖名 -> 约束串（块写法的条目不在其中）。
Map<String, String> parseInlineDependencies(String yaml, String blockName) {
  final List<String>? lines = topLevelBlocks(yaml)[blockName];
  if (lines == null) return const <String, String>{};
  final entries = <String, String>{};
  for (final String line in lines) {
    final RegExpMatch? entry = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):[ \t]*(\S.*)$',
    ).firstMatch(line);
    if (entry != null) {
      entries[entry.group(1)!] = unquote(entry.group(2)!.trim());
    }
  }
  return entries;
}

/// `dependencies:` 里用 `path:` 声明的依赖名。pub 发布拒绝 path 依赖。
Set<String> readPathDependencies(String yaml) {
  final result = <String>{};
  parseDependencyBlock(yaml, 'dependencies').forEach((name, lines) {
    if (lines.any((line) => RegExp(r'^\s+path:').hasMatch(line))) {
      result.add(name);
    }
  });
  return result;
}

/// 该包依赖的其他随版包（不论 path 还是 hosted），用来推发布顺序。
Set<String> readInternalDependencies(String yaml) {
  final deps = <String>{
    ...parseDependencyBlock(yaml, 'dependencies').keys,
    ...parseDependencyBlock(yaml, 'dev_dependencies').keys,
  };
  return deps.where(releasePackages.contains).toSet();
}

/// 写成 hosted 约束的随版依赖：依赖名 -> 约束串。发布合法性只认这一种写法。
Map<String, String> readInternalConstraints(String yaml) => <String, String>{
  for (final MapEntry<String, String> entry in parseInlineDependencies(
    yaml,
    'dependencies',
  ).entries)
    if (releasePackages.contains(entry.key)) entry.key: entry.value,
};

/// 把不接纳目标版本的随版依赖约束改写成 `^<版本>`；已接纳的原样保留（0.3.1 不必动 `^0.3.0`）。
String applyInternalConstraints(String yaml, String version) {
  final Version target =
      Version.tryParse(version) ??
      (throw FormatException('版本号必须是 X.Y.Z：$version'));
  var result = yaml;
  readInternalConstraints(yaml).forEach((name, constraint) {
    if (caretAdmits(constraint, target) == true) return;
    result = result.replaceFirst(
      RegExp('^  $name:[ \\t]*\\S.*\$', multiLine: true),
      '  $name: ^$version',
    );
  });
  return result;
}

/// `dependency_overrides:` 里 path 形式的条目：依赖名 -> path 值。
Map<String, String> readPathOverrides(String? yaml) {
  if (yaml == null) return const <String, String>{};
  final result = <String, String>{};
  parseDependencyBlock(yaml, 'dependency_overrides').forEach((name, lines) {
    for (final String line in lines) {
      final RegExpMatch? match = RegExp(
        r'^\s+path:[ \t]*(.+)$',
      ).firstMatch(line);
      if (match != null) result[name] = unquote(match.group(1)!.trim());
    }
  });
  return result;
}

/// 按「依赖名 -> 相对路径」渲染一份 `pubspec_overrides.yaml`。
String renderOverrides(Map<String, String> paths) {
  final List<String> names = paths.keys.toList()..sort();
  final StringBuffer out = StringBuffer()
    ..writeln('# 仓内开发用：把随版包解析到工作树，pubspec.yaml 里保留发布合法的 hosted 约束。')
    ..writeln(
      '# 由 `dart run packages/patchbay/bin/release_prep.dart --apply` 维护，勿手改。',
    )
    ..writeln('dependency_overrides:');
  for (final String name in names) {
    out
      ..writeln('  $name:')
      ..writeln('    path: ${paths[name]}');
  }
  return out.toString();
}

/// `environment:` 下的 Flutter 约束（`flutter: '>=3.38.0'`）。
String? readFlutterConstraint(String yaml) {
  final List<String>? environment = topLevelBlocks(yaml)['environment'];
  if (environment == null) return null;
  for (final String line in environment) {
    final RegExpMatch? match = RegExp(
      r'''^\s+flutter:\s*(.+)$''',
    ).firstMatch(line);
    if (match != null) return unquote(match.group(1)!.trim());
  }
  return null;
}

String unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
