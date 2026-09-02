// CHANGELOG 状态读取、碎片解析与包内派生。

import 'dart:convert';
import 'dart:io';

import 'constants.dart';
import 'markdown_links.dart';
import 'models.dart';

ChangelogState readChangelogState(String markdown, String version) {
  final List<String> headings = RegExp(r'^## (.+)$', multiLine: true)
      .allMatches(markdown)
      .map((match) => match.group(1)!.trim())
      .toList(growable: false);
  final RegExpMatch? release = RegExp(
    '^## ${RegExp.escape(version)} - (\\S+)[ \\t]*\$',
    multiLine: true,
  ).firstMatch(markdown);
  return ChangelogState(
    hasUnreleased: headings.contains('Unreleased'),
    releaseDate: release?.group(1),
    releaseIsNewest:
        headings.isNotEmpty && headings.first.startsWith('$version - '),
  );
}

/// 把 `## Unreleased` 落款成 `## <版本> - <日期>`。
String applyChangelogRelease(String markdown, String version, String date) {
  final ChangelogState state = readChangelogState(markdown, version);
  if (state.released) return markdown;
  if (!state.hasUnreleased) {
    throw FormatException('CHANGELOG 既无 `## Unreleased` 段，也无 `## $version` 段');
  }
  return markdown.replaceFirst(
    RegExp(r'^## Unreleased[ \t]*$', multiLine: true),
    '## $version - $date',
  );
}

const List<String> changelogFragmentTypes = <String>[
  'added',
  'changed',
  'deprecated',
  'removed',
  'fixed',
  'security',
];

const Map<String, String> _changelogFragmentHeadings = <String, String>{
  'added': 'Added',
  'changed': 'Changed',
  'deprecated': 'Deprecated',
  'removed': 'Removed',
  'fixed': 'Fixed',
  'security': 'Security',
};

final RegExp _changelogFragmentName = RegExp(
  r'^(PB-[0-9]{3}-[0-9]{2}|BUG-[0-9]{8}-[0-9]{2})'
  r'(\.[a-z0-9][a-z0-9-]*)?\.'
  r'(added|changed|deprecated|removed|fixed|security)\.md$',
);

/// 校验并解析一条碎片。错误信息以文件名开头，便于 CI 直接定位。
ChangelogFragment parseChangelogFragment(String fileName, List<int> bytes) {
  final RegExpMatch? name = _changelogFragmentName.firstMatch(fileName);
  if (name == null) {
    throw FormatException('$fileName：文件名不符合 <change-id>[.<part>].<type>.md 规范');
  }

  late final String decoded;
  try {
    decoded = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw FormatException('$fileName：内容不是合法 UTF-8');
  }
  final String content = decoded.trimRight();
  if (content.isEmpty) throw FormatException('$fileName：正文为空');

  final List<String> lines = content.split(RegExp(r'\r?\n'));
  final RegExp item = RegExp(r'^(?:[-+*]|[0-9]+[.)])[ \t]+\S');
  if (!item.hasMatch(lines.first)) {
    throw FormatException('$fileName：正文必须以一条顶层 Markdown 列表项开始');
  }
  for (var index = 1; index < lines.length; index += 1) {
    final String line = lines[index];
    if (line.trim().isEmpty) continue;
    if (!RegExp(r'^[ \t]+').hasMatch(line)) {
      throw FormatException('$fileName：第 ${index + 1} 行形成第二条顶层内容；只允许首项的缩进续段');
    }
  }

  return ChangelogFragment(
    fileName: fileName,
    type: name.group(3)!,
    content: content,
  );
}

/// 把有效碎片加入 `## Unreleased`。同类碎片只按文件名排序，已有正文原样保留。
String aggregateChangelogFragments(
  String markdown,
  Iterable<ChangelogFragment> fragments,
) {
  final List<ChangelogFragment> sorted = fragments.toList()
    ..sort((left, right) {
      final int type = changelogFragmentTypes
          .indexOf(left.type)
          .compareTo(changelogFragmentTypes.indexOf(right.type));
      return type != 0 ? type : left.fileName.compareTo(right.fileName);
    });
  if (sorted.isEmpty) return markdown;

  final List<RegExpMatch> unreleased = RegExp(
    r'^## Unreleased[ \t]*$',
    multiLine: true,
  ).allMatches(markdown).toList(growable: false);
  if (unreleased.length != 1) {
    throw FormatException(
      '聚合碎片要求 CHANGELOG 恰好有一个 `## Unreleased` 段，实际 ${unreleased.length} 个',
    );
  }
  final int bodyStart = unreleased.single.end;
  final RegExpMatch? nextRelease = RegExp(
    r'^## ',
    multiLine: true,
  ).firstMatch(markdown.substring(bodyStart));
  final int bodyEnd = nextRelease == null
      ? markdown.length
      : bodyStart + nextRelease.start;
  String body = markdown.substring(bodyStart, bodyEnd);

  for (final String type in changelogFragmentTypes) {
    final List<ChangelogFragment> typed = sorted
        .where((fragment) => fragment.type == type)
        .toList(growable: false);
    if (typed.isEmpty) continue;
    final String heading = _changelogFragmentHeadings[type]!;
    final String additions = typed
        .map((fragment) => fragment.content)
        .join('\n\n');
    final RegExp sectionHeading = RegExp(
      '^### ${RegExp.escape(heading)}[ \\t]*\$',
      multiLine: true,
    );
    final RegExpMatch? existing = sectionHeading.firstMatch(body);
    if (existing != null) {
      final RegExpMatch? nextHeading = RegExp(
        r'^### ',
        multiLine: true,
      ).firstMatch(body.substring(existing.end));
      final int sectionEnd = nextHeading == null
          ? body.length
          : existing.end + nextHeading.start;
      final String current = body
          .substring(existing.end, sectionEnd)
          .trimRight();
      final String replacement = '$current\n\n$additions\n\n';
      body = body.replaceRange(existing.end, sectionEnd, replacement);
      continue;
    }

    int insertion = body.length;
    final int typeIndex = changelogFragmentTypes.indexOf(type);
    for (final String later in changelogFragmentTypes.skip(typeIndex + 1)) {
      final RegExpMatch? laterHeading = RegExp(
        '^### ${RegExp.escape(_changelogFragmentHeadings[later]!)}[ \\t]*\$',
        multiLine: true,
      ).firstMatch(body);
      if (laterHeading != null) {
        insertion = laterHeading.start;
        break;
      }
    }
    final String block = '### $heading\n\n$additions\n\n';
    final String before = body.substring(0, insertion).trimRight();
    final String after = body.substring(insertion).trimLeft();
    body = '${before.isEmpty ? '\n\n' : '$before\n\n'}$block$after';
  }

  return markdown.replaceRange(bodyStart, bodyEnd, body);
}

const String _packageChangelogPreamble = '''
# Changelog

The four packages are versioned together. Generated by `release_prep --apply`
from the English pub.dev summaries in the repository changelog. Do not edit
this file directly.

[root]: https://github.com/cr1992/patchbay/blob/main/CHANGELOG.md
''';

const String _pubChangelogStart = '<!-- PUB_CHANGELOG:START -->';
const String _pubChangelogEnd = '<!-- PUB_CHANGELOG:END -->';

/// 包内 CHANGELOG 是否已记到目标版本。
bool packageChangelogMentions(String? markdown, String version) =>
    markdown != null &&
    RegExp(
      '^## ${RegExp.escape(version)}( |\$)',
      multiLine: true,
    ).hasMatch(markdown);

/// 从仓根 CHANGELOG 派生包内 CHANGELOG：换掉前言，去掉 `## Unreleased` 段，
/// 并只投影每个已发布段的英文 pub.dev 摘要。
String derivePackageChangelog(String rootChangelog) {
  final List<RegExpMatch> headings = RegExp(
    r'^## ',
    multiLine: true,
  ).allMatches(rootChangelog).toList(growable: false);
  if (headings.isEmpty) return _packageChangelogPreamble;
  final StringBuffer out = StringBuffer(_packageChangelogPreamble);
  for (var index = 0; index < headings.length; index += 1) {
    final int start = headings[index].start;
    final int end = index + 1 < headings.length
        ? headings[index + 1].start
        : rootChangelog.length;
    final String section = rootChangelog.substring(start, end);
    if (RegExp(r'^## Unreleased[ \t]*$', multiLine: true).hasMatch(section)) {
      continue;
    }
    final List<int> summaryStarts = <int>[
      for (
        var offset = section.indexOf(_pubChangelogStart);
        offset >= 0;
        offset = section.indexOf(
          _pubChangelogStart,
          offset + _pubChangelogStart.length,
        )
      )
        offset,
    ];
    final List<int> summaryEnds = <int>[
      for (
        var offset = section.indexOf(_pubChangelogEnd);
        offset >= 0;
        offset = section.indexOf(
          _pubChangelogEnd,
          offset + _pubChangelogEnd.length,
        )
      )
        offset,
    ];
    if (summaryStarts.isEmpty && summaryEnds.isEmpty) continue;
    if (summaryStarts.length != 1 ||
        summaryEnds.length != 1 ||
        summaryEnds.single <= summaryStarts.single) {
      throw FormatException('CHANGELOG pub.dev summary markers are malformed');
    }
    final int headingEnd = section.indexOf('\n');
    final String heading = headingEnd < 0
        ? section
        : section.substring(0, headingEnd);
    final String summary = section
        .substring(
          summaryStarts.single + _pubChangelogStart.length,
          summaryEnds.single,
        )
        .trim();
    if (summary.isEmpty) {
      throw FormatException('CHANGELOG pub.dev summary must not be empty');
    }
    out
      ..writeln()
      ..writeln(heading.trimRight())
      ..writeln()
      ..write(absolutizeRepoLinks(summary).trimRight())
      ..writeln();
  }
  return out.toString();
}

FragmentScan readChangelogFragments(String root, String version) {
  final Directory directory = Directory('$root/$changelogFragmentsPath');
  if (!directory.existsSync()) {
    return FragmentScan(
      version: version,
      fragments: <ChangelogFragment>[],
      fragmentPaths: <String>[],
      errors: <String>['changelog.d：目录不存在'],
    );
  }
  final List<FileSystemEntity> entries = directory.listSync()
    ..sort((left, right) => left.path.compareTo(right.path));
  final fragments = <ChangelogFragment>[];
  final fragmentPaths = <String>[];
  final errors = <String>[];
  for (final FileSystemEntity entry in entries) {
    final String name = entry.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    if (name == 'README.md') continue;
    if (entry is File) {
      errors.add('$name：碎片必须放入 changelog.d/<version>/ 版本目录');
      continue;
    }
    if (entry is! Directory) {
      errors.add('$name：changelog.d 根目录只允许 README.md 与版本目录');
      continue;
    }
    if (Version.tryParse(name) == null) {
      errors.add('$name：版本目录名必须是 SemVer');
      continue;
    }
    final List<FileSystemEntity> versionEntries = entry.listSync()
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final FileSystemEntity fragmentEntry in versionEntries) {
      final String fileName = fragmentEntry.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      final String relative = '$changelogFragmentsPath/$name/$fileName';
      if (fragmentEntry is! File) {
        errors.add('$relative：版本目录只允许碎片文件');
        continue;
      }
      try {
        final ChangelogFragment fragment = parseChangelogFragment(
          fileName,
          fragmentEntry.readAsBytesSync(),
        );
        if (name == version) {
          fragments.add(fragment);
          fragmentPaths.add(relative);
        }
      } on FormatException catch (error) {
        errors.add('$name/${error.message}');
      } on FileSystemException catch (error) {
        errors.add('$relative：读取失败（${error.message}）');
      }
    }
  }
  return FragmentScan(
    version: version,
    fragments: fragments,
    fragmentPaths: fragmentPaths,
    errors: errors,
  );
}

ReleaseCheck checkChangelogFragments(FragmentScan scan) {
  if (scan.errors.isNotEmpty) {
    return ReleaseCheck.failed(
      'changelog-fragments',
      scan.errors.join('；'),
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'changelog-fragments',
    '${scan.version}：${scan.fragments.length} 个目标碎片格式合法；其他版本队列保留',
    hard: true,
  );
}
