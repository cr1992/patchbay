import 'dart:io';

import 'package:test/test.dart';

String _fixture({
  required String releaseStatus,
  required String releaseVersion,
}) {
  final directory = Directory.systemTemp.createTempSync('check-planning-test-');
  Directory('${directory.path}/docs/releases').createSync(recursive: true);
  Directory('${directory.path}/docs/proposals').createSync(recursive: true);
  File('${directory.path}/AGENTS.md').writeAsStringSync('instructions\n');
  File('${directory.path}/CLAUDE.md').writeAsStringSync('@AGENTS.md\n');
  File('${directory.path}/docs/backlog.md').writeAsStringSync(
    '# Backlog\n\n'
    '| 编号 | 标题 | 动机 | 目标版本 | 实施状态 | 关联 |\n'
    '|---|---|---|---|---|---|\n',
  );
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
  final activeVersion = RegExp(
    r"const _activeVersion = '([^']+)';",
  ).firstMatch(File(checker).readAsStringSync())!.group(1)!;

  ProcessResult runChecker(String root) => Process.runSync(
    Platform.resolvedExecutable,
    <String>['run', checker],
    workingDirectory: root,
  );

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
