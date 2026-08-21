import 'dart:io';

import 'package:test/test.dart';

import '../tool/release_finalize.dart';

/// 建一个只含 backlog 与版本计划的最小仓库骨架。
String _fixture(List<String> rows) {
  final dir = Directory.systemTemp.createTempSync('finalize-test-');
  Directory('${dir.path}/docs/releases').createSync(recursive: true);
  File(
    '${dir.path}/docs/releases/0.4.1.md',
  ).writeAsStringSync('# 0.4.1\n\n> 状态：规划中\n');
  File('${dir.path}/docs/backlog.md').writeAsStringSync(
    '# Backlog\n\n'
    '| 编号 | 标题 | 动机 | 目标版本 | 实施状态 | 关联 |\n'
    '|---|---|---|---|---|---|\n'
    '${rows.join('\n')}\n',
  );
  return dir.path;
}

String _row(String id, String status) =>
    '| $id | 标题$id | 动机 | 0.4.1 | $status | 无 |';

void main() {
  const finalizer = ReleaseFinalizer();

  ({String root, ReleaseFinalizePlan plan}) planFor(
    List<String> rows, {
    bool allowDefer = false,
    bool allowEvidencePending = false,
    Set<String> deferItems = const <String>{},
  }) {
    final root = _fixture(rows);
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
      final r = planFor([_row('PB-041-01', '已验证')]);
      expect(r.plan.items.single.action, 'ARCHIVE');
      expect(r.plan.canApply, isTrue);
    });

    test('待真机验收默认阻断——未结验收不得冒充完成', () {
      final r = planFor([_row('PB-041-01', '待真机验收')]);
      expect(r.plan.items.single.action, 'BLOCK');
      expect(r.plan.canApply, isFalse);
      expect(r.plan.blockingReasons.single, contains('验收证据尚未闭合'));
    });

    test('显式放行后成为独立的「仅缺证据」档，而不是并入已延期', () {
      final r = planFor([
        _row('PB-041-01', '待真机验收'),
      ], allowEvidencePending: true);
      expect(r.plan.items.single.action, 'EVIDENCE_PENDING');
      expect(r.plan.canApply, isTrue);
    });

    test('「实现中」不接受批量延期（回归：--allow-defer 曾能整批抹掉）', () {
      final r = planFor([_row('PB-041-02', '实现中')], allowDefer: true);
      expect(r.plan.items.single.action, 'BLOCK');
      expect(r.plan.canApply, isFalse);
      expect(r.plan.blockingReasons.single, contains('未被逐条点名延期'));
    });

    test('「实现中」逐条点名后才可延期', () {
      final r = planFor([_row('PB-041-02', '实现中')], deferItems: {'PB-041-02'});
      expect(r.plan.items.single.action, 'DEFER');
      expect(r.plan.canApply, isTrue);
    });

    test('待排期条目按 --allow-defer 延期', () {
      final r = planFor([_row('PB-041-09', '待排期')], allowDefer: true);
      expect(r.plan.items.single.action, 'DEFER');
    });
  });

  group('applyPlan', () {
    test('归档移出 backlog，延期条目清空目标版本', () {
      final r = planFor([
        _row('PB-041-01', '已验证'),
        _row('PB-041-09', '待排期'),
      ], allowDefer: true);

      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);
      final backlog = File('${r.root}/docs/backlog.md').readAsStringSync();
      expect(backlog, isNot(contains('PB-041-01')));
      expect(backlog, contains('PB-041-09'));
      expect(backlog, contains('待排期'));
    });

    test('仅缺证据的条目保留在 backlog，且版本文档不写成干净的「已发布」', () {
      final r = planFor([
        _row('PB-041-01', '已验证'),
        _row('PB-041-05', '待真机验收'),
      ], allowEvidencePending: true);

      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);

      final backlog = File('${r.root}/docs/backlog.md').readAsStringSync();
      expect(backlog, contains('PB-041-05'), reason: '欠证据的条目一旦被归档消失，就等于冒充完成');

      final release = File(
        '${r.root}/docs/releases/0.4.1.md',
      ).readAsStringSync();
      expect(release, contains('已发布（1 项仍欠验收证据）'));
      expect(release, contains('## 仍欠验收证据'));
      expect(release, contains('PB-041-05'));
    });

    test('全部闭合时版本状态才写成「已发布」', () {
      final r = planFor([_row('PB-041-01', '已验证')]);
      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isTrue);
      final release = File(
        '${r.root}/docs/releases/0.4.1.md',
      ).readAsStringSync();
      expect(release, contains('> 状态：已发布\n'));
      expect(release, isNot(contains('仍欠验收证据')));
    });

    test('计划不可执行时 applyPlan 不落任何改动', () {
      final r = planFor([_row('PB-041-02', '实现中')]);
      final before = File('${r.root}/docs/backlog.md').readAsStringSync();
      expect(finalizer.applyPlan(repoRoot: r.root, plan: r.plan), isFalse);
      expect(File('${r.root}/docs/backlog.md').readAsStringSync(), before);
    });
  });
}
