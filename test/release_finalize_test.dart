import 'dart:io';

import 'package:test/test.dart';

import '../tool/backlog_store.dart';
import '../tool/release_finalize.dart';

/// 建一个只含台账碎片与版本计划的最小仓库骨架。
String _fixture(List<(String, String)> items) {
  final dir = Directory.systemTemp.createTempSync('finalize-test-');
  Directory('${dir.path}/docs/releases').createSync(recursive: true);
  Directory('${dir.path}/$backlogFragmentDir').createSync(recursive: true);
  File(
    '${dir.path}/docs/releases/0.4.1.md',
  ).writeAsStringSync('# 0.4.1\n\n> 状态：规划中\n');
  for (final (id, status) in items) {
    File(
      '${dir.path}/$backlogFragmentDir/$id.md',
    ).writeAsStringSync(_fragment(id, status));
  }
  return dir.path;
}

String _fragment(String id, String status) =>
    '---\n'
    'id: $id\n'
    'title: 标题$id\n'
    'target: 0.4.1\n'
    'status: $status\n'
    '---\n'
    '\n'
    '## 动机\n'
    '\n'
    '动机\n'
    '\n'
    '## 备注\n'
    '\n'
    '无\n';

Map<String, String> _fragments(String root) {
  final dir = Directory('$root/$backlogFragmentDir');
  return <String, String>{
    for (final file in dir.listSync().whereType<File>())
      file.uri.pathSegments.last: file.readAsStringSync(),
  };
}

void main() {
  const finalizer = ReleaseFinalizer();

  ({String root, ReleaseFinalizePlan plan}) planFor(
    List<(String, String)> items, {
    bool allowDefer = false,
    bool allowEvidencePending = false,
    Set<String> deferItems = const <String>{},
  }) {
    final root = _fixture(items);
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    return (
      root: root,
      plan: finalizer.generatePlan(
        repoRoot: root,
        version: '0.4.1',
        allowDefer: allowDefer,
        allowEvidencePending: allowEvidencePending,
        deferItems: deferItems,
      ),
    );
  }

  group('三档分类 (PB-041-02)', () {
    test('已验证归档，计划可执行', () {
      final r = planFor([('PB-041-01', '已验证')]);
      expect(r.plan.items.single.action, 'ARCHIVE');
      expect(r.plan.canApply, isTrue);
    });

    test('待真机验收默认阻断——未结验收不得冒充完成', () {
      final r = planFor([('PB-041-01', '待真机验收')]);
      expect(r.plan.items.single.action, 'BLOCK');
      expect(r.plan.canApply, isFalse);
      expect(r.plan.blockingReasons.single, contains('验收证据尚未闭合'));
    });

    test('显式放行后成为独立的「仅缺证据」档，而不是并入已延期', () {
      final r = planFor([('PB-041-01', '待真机验收')], allowEvidencePending: true);
      expect(r.plan.items.single.action, 'EVIDENCE_PENDING');
      expect(r.plan.canApply, isTrue);
    });

    test('「实现中」不接受批量延期（回归：--allow-defer 曾能整批抹掉）', () {
      final r = planFor([('PB-041-02', '实现中')], allowDefer: true);
      expect(r.plan.items.single.action, 'BLOCK');
      expect(r.plan.canApply, isFalse);
      expect(r.plan.blockingReasons.single, contains('未被逐条点名延期'));
    });

    test('「实现中」逐条点名后才可延期', () {
      final r = planFor([('PB-041-02', '实现中')], deferItems: {'PB-041-02'});
      expect(r.plan.items.single.action, 'DEFER');
      expect(r.plan.canApply, isTrue);
    });

    test('待排期条目按 --allow-defer 延期', () {
      final r = planFor([('PB-041-09', '待排期')], allowDefer: true);
      expect(r.plan.items.single.action, 'DEFER');
    });

    test('碎片解析失败时阻断，不按半份台账收尾', () {
      final r = planFor([('PB-041-01', '已验证')]);
      File(
        '${r.root}/$backlogFragmentDir/PB-041-77.md',
      ).writeAsStringSync('---\nid: PB-041-77\n---\n');
      final plan = finalizer.generatePlan(repoRoot: r.root, version: '0.4.1');
      expect(plan.canApply, isFalse);
      expect(plan.blockingReasons.first, contains('碎片解析失败'));
    });
  });

  group('applyPlan', () {
    test('归档删除碎片，延期条目清空目标版本', () {
      final r = planFor([
        ('PB-041-01', '已验证'),
        ('PB-041-09', '待排期'),
      ], allowDefer: true);

      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);
      final after = _fragments(r.root);
      expect(after.containsKey('PB-041-01.md'), isFalse);
      expect(after['PB-041-09.md'], contains('status: 待排期'));
      expect(after['PB-041-09.md'], contains('target: $unscheduledTarget'));
      expect(after['PB-041-09.md'], isNot(contains('0.4.1')));
    });

    test('仅缺证据的条目保留碎片，且版本文档不写成干净的「已发布」', () {
      final r = planFor([
        ('PB-041-01', '已验证'),
        ('PB-041-05', '待真机验收'),
      ], allowEvidencePending: true);

      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);

      expect(
        _fragments(r.root).containsKey('PB-041-05.md'),
        isTrue,
        reason: '欠证据的条目一旦被归档消失，就等于冒充完成',
      );

      final release = File(
        '${r.root}/docs/releases/0.4.1.md',
      ).readAsStringSync();
      expect(release, contains('已发布（1 项仍欠验收证据）'));
      expect(release, contains('## 仍欠验收证据'));
      expect(release, contains('PB-041-05'));
    });

    test('全部闭合时版本状态才写成「已发布」', () {
      final r = planFor([('PB-041-01', '已验证')]);
      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);
      final release = File(
        '${r.root}/docs/releases/0.4.1.md',
      ).readAsStringSync();
      expect(release, contains('> 状态：已发布\n'));
      expect(release, isNot(contains('仍欠验收证据')));
    });

    test('计划不可执行时 applyPlan 不落任何改动', () {
      final r = planFor([('PB-041-02', '实现中')]);
      final before = _fragments(r.root);
      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isFalse);
      expect(_fragments(r.root), before);
    });
  });
}
