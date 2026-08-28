import 'dart:io';

import 'package:test/test.dart';

import '../tool/backlog_store.dart';
import '../tool/release_finalize.dart';

String _fixture({
  required String releaseStatus,
  required String releaseVersion,
}) {
  final directory = Directory.systemTemp.createTempSync('check-planning-test-');
  Directory('${directory.path}/docs/releases').createSync(recursive: true);
  Directory('${directory.path}/docs/proposals').createSync(recursive: true);
  Directory(
    '${directory.path}/$backlogFragmentDir',
  ).createSync(recursive: true);
  File('${directory.path}/AGENTS.md').writeAsStringSync('instructions\n');
  File('${directory.path}/CLAUDE.md').writeAsStringSync('@AGENTS.md\n');
  File(
    '${directory.path}/$backlogIndexPath',
  ).writeAsStringSync('# Backlog\n\n条目真源见 `backlog.d/`。\n');
  File('${directory.path}/docs/releases/$releaseVersion.md').writeAsStringSync(
    '# $releaseVersion\n\n'
    '> 状态：$releaseStatus\n\n'
    '### P0：发布阻断\n\n'
    '| 编号 | 关键验收 |\n'
    '|---|---|\n'
    '| PB-999-01 | 已发布范围 |\n',
  );
  return directory.path;
}

void main() {
  final checker = File('../../tool/check_planning.dart').absolute.path;
  final activeVersionMatch = RegExp(
    r'''const\s+_activeVersion\s*=\s*['"]([^'"]+)['"]\s*;''',
  ).firstMatch(File(checker).readAsStringSync());
  if (activeVersionMatch == null) {
    throw FormatException(
      'Could not parse _activeVersion from tool/check_planning.dart.',
      checker,
    );
  }
  final activeVersion = activeVersionMatch.group(1)!;

  ProcessResult runChecker(String root) => Process.runSync(
    Platform.resolvedExecutable,
    <String>['run', checker],
    workingDirectory: root,
  );

  test('finalize 认得的每个状态都在 check_planning 的封闭词表里', () {
    // 回归：`待真机验收` 曾只活在 release_finalize 与发版清单里，不在
    // check_planning 的词表中——同一份台账被两个工具判出相反的合法性，
    // 收尾人一旦按发版清单标注就会撞红。任一侧再漂移，这条立刻转红。
    final body = RegExp(
      r'const\s+_allowedBacklogStatuses\s*=\s*<String>\{([^}]*)\}',
    ).firstMatch(File(checker).readAsStringSync())?.group(1);
    if (body == null) {
      throw FormatException(
        'Could not parse _allowedBacklogStatuses from tool/check_planning.dart.',
        checker,
      );
    }
    final allowed = RegExp(
      "'([^']+)'",
    ).allMatches(body).map((match) => match.group(1)!).toSet();

    expect(allowed, contains(statusVerified));
    expect(allowed, contains(statusEvidencePending));
    expect(allowed, contains(statusInProgress));
  });

  test('已发布计划保留历史 scope，不要求归档条目仍在活跃 backlog', () {
    final root = _fixture(releaseStatus: '已发布', releaseVersion: activeVersion);
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = runChecker(root);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('planning consistency check passed'));
  });

  test('活跃计划仍拒绝 scope 引用不存在的 backlog 条目', () {
    final root = _fixture(releaseStatus: 'RC', releaseVersion: activeVersion);
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = runChecker(root);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('release scope references a missing'));
  });
}
