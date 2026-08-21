import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release_finalize.dart';

void main() {
  group('ReleaseFinalizer (PB-041-02)', () {
    const finalizer = ReleaseFinalizer();

    test('generates plan and blocks when unverified items exist without allowDefer', () {
      final tempDir = Directory.systemTemp.createTempSync('finalize-test-');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      Directory('${tempDir.path}/docs/releases').createSync(recursive: true);
      File('${tempDir.path}/docs/releases/0.4.1.md').writeAsStringSync('> 状态：规划中\n');
      File('${tempDir.path}/docs/backlog.md').writeAsStringSync('''
# Backlog

| 编号 | 标题 | 动机 | 目标版本 | 实施状态 | 关联 Proposal / 备忘 |
|---|---|---|---|---|---|
| PB-041-01 | Pana 门禁 | 评分门禁 | 0.4.1 | 已验证 | 无 |
| PB-041-02 | Finalize 工具 | 收尾工具 | 0.4.1 | 实现中 | 无 |
''');

      final plan = finalizer.generatePlan(
        repoRoot: tempDir.path,
        version: '0.4.1',
        allowDefer: false,
      );

      expect(plan.canApply, isFalse);
      expect(plan.blockingReasons, anyElement(contains('PB-041-02 is "实现中"')));
      expect(plan.items.firstWhere((i) => i.id == 'PB-041-01').action, 'ARCHIVE');
      expect(plan.items.firstWhere((i) => i.id == 'PB-041-02').action, 'BLOCK');
    });

    test('allows deferral and applies plan atomically', () {
      final tempDir = Directory.systemTemp.createTempSync('finalize-test-');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      Directory('${tempDir.path}/docs/releases').createSync(recursive: true);
      File('${tempDir.path}/docs/releases/0.4.1.md').writeAsStringSync('> 状态：规划中\n');
      File('${tempDir.path}/docs/backlog.md').writeAsStringSync('''
# Backlog

| 编号 | 标题 | 动机 | 目标版本 | 实施状态 | 关联 Proposal / 备忘 |
|---|---|---|---|---|---|
| PB-041-01 | Pana 门禁 | 评分门禁 | 0.4.1 | 已验证 | 无 |
| PB-041-02 | Finalize 工具 | 收尾工具 | 0.4.1 | 实现中 | 无 |
''');

      final plan = finalizer.generatePlan(
        repoRoot: tempDir.path,
        version: '0.4.1',
        allowDefer: true,
      );

      expect(plan.canApply, isTrue);
      expect(plan.items.firstWhere((i) => i.id == 'PB-041-02').action, 'DEFER');

      final success = finalizer.applyPlan(
        repoRoot: tempDir.path,
        plan: plan,
      );
      expect(success, isTrue);

      final backlog = File('${tempDir.path}/docs/backlog.md').readAsStringSync();
      expect(backlog, isNot(contains('PB-041-01'))); // Archived
      expect(backlog, contains('PB-041-02')); // Deferred
      expect(backlog, contains('待排期'));

      final release = File('${tempDir.path}/docs/releases/0.4.1.md').readAsStringSync();
      expect(release, contains('> 状态：已发布'));
    });
  });
}
