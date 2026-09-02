// 兼容矩阵与协议兼容语料生成。

import 'dart:convert';

import 'constants.dart';
import 'models.dart';
import 'pubspec_scanner.dart';

String requireVersion(String version) {
  if (Version.tryParse(version) == null) {
    throw FormatException('版本号必须是 SemVer（X.Y.Z，可带 prerelease/build）：$version');
  }
  return version;
}

List<CompatRow> parseCompatRows(String markdown) {
  final rows = <CompatRow>[];
  for (final String line in markdown.split('\n')) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) continue;
    final List<String> cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((cell) => _stripCode(cell.trim()))
        .toList(growable: false);
    if (cells.length != 6 || !cells.first.startsWith(tagPrefix)) continue;
    rows.add(
      CompatRow(
        tag: cells[0],
        commitSha: cells[1],
        schemaVersion: cells[2],
        flutterCi: cells[3],
        flutterMin: cells[4],
        consumers: cells[5],
      ),
    );
  }
  return rows;
}

String _stripCode(String cell) =>
    cell.length >= 2 && cell.startsWith('`') && cell.endsWith('`')
    ? cell.substring(1, cell.length - 1)
    : cell;

/// 在「当前记录」表顶插入新行。
String applyCompatMatrixRow(String markdown, CompatRow row) {
  if (parseCompatRows(markdown).any((existing) => existing.tag == row.tag)) {
    return markdown;
  }
  final List<String> lines = markdown.split('\n');
  var insertAt = -1;
  for (var index = 0; index < lines.length; index += 1) {
    final String trimmed = lines[index].trim();
    if (trimmed.startsWith('| `$tagPrefix')) {
      insertAt = index;
      break;
    }
    if (trimmed.startsWith('|-') && trimmed.endsWith('|')) insertAt = index + 1;
  }
  if (insertAt < 0) {
    throw const FormatException('兼容矩阵里找不到「当前记录」表');
  }
  lines.insert(insertAt, row.render());
  return lines.join('\n');
}

/// 源码里的 wire `schemaVersion`。
int? readSchemaVersion(String dartSource) {
  final RegExpMatch? match = RegExp(
    r'static const int schemaVersion = (\d+);',
  ).firstMatch(dartSource);
  return match == null ? null : int.parse(match.group(1)!);
}

/// GitHub Actions 里 CI 实际验证的 Flutter 版本。
String? readCiFlutterVersion(String workflow) {
  final RegExpMatch? match = RegExp(
    r'''^\s*FLUTTER_VERSION:\s*(.+)$''',
    multiLine: true,
  ).firstMatch(workflow);
  return match == null ? null : unquote(match.group(1)!.trim());
}

/// 按源码现值生成目标版本的矩阵行（tag 后才能定的两格留占位符）。
CompatRow buildCompatRow(String version, ReleaseInputs inputs) => CompatRow(
  tag: '$tagPrefix$version',
  commitSha: pendingSha,
  schemaVersion: '${readSchemaVersion(inputs.serviceHost) ?? '?'}',
  flutterCi: readCiFlutterVersion(inputs.workflow) ?? '?',
  flutterMin:
      readFlutterConstraint(inputs.packages['patchbay_flutter']!.pubspec) ??
      '?',
  consumers: pendingConsumers,
);

const JsonEncoder _fixtureJson = JsonEncoder.withIndent('  ');

String compatibilityCorpusDirectory(String version) {
  requireVersion(version);
  return 'legacy_host_v${version.replaceAll('.', '_')}';
}

/// 从当前 host 实际输出的 surface golden 冻结可供未来 CLI 读取的历史语料。
Map<String, String> renderCompatibilityFixtures(
  String version,
  String hostSurfaceGolden,
) {
  requireVersion(version);
  final Object? decoded = jsonDecode(hostSurfaceGolden);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('host surface golden 顶层必须是 JSON object');
  }
  final Object? identityValue = decoded['identity'];
  final Object? catalogValue = decoded['catalog'];
  if (identityValue is! Map<String, Object?> ||
      catalogValue is! Map<String, Object?>) {
    throw const FormatException(
      'host surface golden 必须同时包含 identity / catalog object',
    );
  }
  if (identityValue['serverVersion'] != '<patchbayPackageVersion>') {
    throw const FormatException(
      'host surface golden 的 identity.serverVersion 必须来自 <patchbayPackageVersion>',
    );
  }
  final Map<String, Object?> identity = <String, Object?>{
    ...identityValue,
    'serverVersion': version,
  };
  final String directory = compatibilityCorpusDirectory(version);
  String render(Map<String, Object?> value) =>
      '${_fixtureJson.convert(value)}\n';
  return <String, String>{
    '$directory/identity.json': render(identity),
    '$directory/catalog.json': render(catalogValue),
  };
}

/// 正式版语料随发布准备自动落冻结说明；RC 仍可在同一条定版链上重复生成。
String? renderCompatibilityCorpusReadme(String version) {
  final Version parsedVersion = Version.tryParse(requireVersion(version))!;
  if (parsedVersion.prerelease != null) return null;
  return '''
# 冻结语料：v$version host

<!-- $frozenCorpusMarker -->

本目录由 `release_prep` 在 $version 正式版定版时从真实 host surface 生成并冻结。这里的
`identity.json` 与 `catalog.json` 是已发布协议面的历史事实；后续版本只能读取它们做兼容验证，
不得用当前 host 重新生成或覆写。
''';
}
