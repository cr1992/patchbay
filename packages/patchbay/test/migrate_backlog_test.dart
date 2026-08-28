import 'dart:io';

import 'package:test/test.dart';

import '../tool/backlog_store.dart';

final _script = File('../../tool/migrate_backlog.dart').absolute.path;

const _legacy = '''
# 问题与特性台账

> 说明段落，逐字保留。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| BUG-20260826-01：权限误判 | `dumpsys` 只认 runtime 小节 | 已验证 |

## 特性

| 编号 | 条目 | 动机 / 出处 | 目标版本 | 状态 | Proposal / 备注 |
|---|---|---|---|---|---|
| PB-050-13 | CLI 公共 API 收口 | 根 barrel 暴露 seam | 0.5.0 | 实现中 | [收口](proposals/0.5.0/x.md)；DG-050-07 |
| PB-050-26 | 审计事件富化 | 越出授权面 | — | 待排期 | 落地前补 Proposal |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| （暂无） | |

## design-gate（需仓主裁决后动工）

| 编号 | 裁决点 | 目标版本 | 状态 | Proposal |
|---|---|---|---|---|
| DG-050-07 | 公共 API 收口边界 | 0.5.0 | 已裁决 | [收口](proposals/0.5.0/x.md) |

## 维护规则

- 逐字保留的尾段。
''';

String _root(String legacy) {
  final dir = Directory.systemTemp.createTempSync('migrate-backlog-test-');
  Directory('${dir.path}/docs').createSync(recursive: true);
  File('${dir.path}/$backlogIndexPath').writeAsStringSync(legacy);
  return dir.path;
}

ProcessResult _run(String root, {bool apply = false}) => Process.runSync(
  Platform.resolvedExecutable,
  <String>['run', _script, if (apply) '--apply'],
  workingDirectory: root,
);

Set<String> _fragmentIds(String root) {
  final dir = Directory('$root/$backlogFragmentDir');
  if (!dir.existsSync()) return <String>{};
  return dir
      .listSync()
      .whereType<File>()
      .map((file) => file.uri.pathSegments.last)
      .where((name) => name != 'README.md')
      .map((name) => name.substring(0, name.length - 3))
      .toSet();
}

void main() {
  test('四类章节全部拆成碎片，往返等价通过', () {
    final root = _root(_legacy);
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = _run(root, apply: true);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('往返等价：通过'));
    expect(_fragmentIds(root), <String>{
      'BUG-20260826-01',
      'PB-050-13',
      'PB-050-26',
      'DG-050-07',
    });

    final feature = File(
      '$root/$backlogFragmentDir/PB-050-13.md',
    ).readAsStringSync();
    expect(feature, contains('target: 0.5.0'));
    expect(feature, contains('](../proposals/0.5.0/x.md)'));
    expect(
      File('$root/$backlogFragmentDir/PB-050-26.md').readAsStringSync(),
      contains('target: $unscheduledTarget'),
    );
  });

  test('重跑幂等：源里消失的条目会被删除，未变的条目不重写', () {
    final root = _root(_legacy);
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    expect(_run(root, apply: true).exitCode, 0);

    final trimmed = _legacy
        .split('\n')
        .where((line) => !line.startsWith('| PB-050-26 '))
        .join('\n');
    File('$root/$backlogIndexPath').writeAsStringSync(trimmed);

    final second = _run(root, apply: true);
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    expect(second.stdout, contains('未变 3 个'));
    expect(second.stdout, contains('删除 1 个（PB-050-26）'));
    expect(_fragmentIds(root), isNot(contains('PB-050-26')));
  });

  test('缺全角冒号的缺陷行如实报告并阻断，不静默丢弃', () {
    final root = _root(
      _legacy.replaceFirst('BUG-20260826-01：权限误判', 'BUG-20260826-01 权限误判'),
    );
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = _run(root, apply: true);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('无法解析成缺陷条目'));
    expect(result.stderr, contains('未写入碎片'));
    expect(_fragmentIds(root), isEmpty);
  });

  test('列数不符的行如实报告并阻断', () {
    final root = _root(
      _legacy.replaceFirst(
        '| PB-050-26 | 审计事件富化 | 越出授权面 | — | 待排期 | 落地前补 Proposal |',
        '| PB-050-26 | 审计事件富化 | 越出授权面 | 待排期 |',
      ),
    );
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = _run(root, apply: true);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('无法解析成特性条目'));
    expect(_fragmentIds(root), isEmpty);
  });

  test('单元格空白排布不同算无语义差异，不判红', () {
    final root = _root(
      _legacy.replaceFirst('| PB-050-13 | CLI', '|  PB-050-13  |  CLI'),
    );
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = _run(root, apply: true);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('无语义空白差异'));
    expect(result.stdout, contains('往返等价：通过'));
  });

  test('已经迁移过的仓库重跑会明确拒绝，而不是产出空目录', () {
    final root = _root('# 问题与特性台账\n\n条目真源见 `backlog.d/`。\n');
    addTearDown(() => Directory(root).deleteSync(recursive: true));

    final result = _run(root);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('没有找到任何条目行'));
  });
}
