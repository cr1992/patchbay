import 'dart:io';

import 'package:test/test.dart';

/// 从包目录回到仓库根；发布归档里没有仓库根，此时整组跳过。
String? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/check_structure_ratchet.dart').existsSync() &&
        File('${dir.path}/tool/structure_baseline.json').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

void main() {
  final root = _repoRoot();

  group('结构门禁 (PB-041-03)', () {
    late ProcessResult result;

    setUpAll(() {
      result = Process.runSync(Platform.resolvedExecutable, <String>[
        'run',
        'tool/check_structure_ratchet.dart',
      ], workingDirectory: root);
    });

    test('四类结构硬规则全仓通过', () {
      expect(
        result.exitCode,
        0,
        reason: '结构硬规则失败：\n${result.stderr}\n${result.stdout}',
      );
      expect(result.stdout.toString(), contains('结构硬规则通过'));
    });

    test('体积只是警戒线：命中告警不改变退出码', () {
      final stdout = result.stdout.toString();
      if (!stdout.contains('警戒线提示')) return;

      expect(result.exitCode, 0, reason: '体积不是硬指标，拆不拆看内容——告警不得阻断');
      expect(
        result.stderr.toString(),
        isNot(contains('警戒线')),
        reason: '告警不该写进 stderr，否则 CI 会当成失败信号',
      );
    });

    test('告警必须被打印出来，不能静默吞掉', () {
      // 仓内确实存在超过 150 行的生产函数；门禁若一条都不报，
      // 说明扫描逻辑坏了，而不是代码变干净了。
      expect(
        result.stdout.toString(),
        contains('long-function'),
        reason: '函数长度警戒线没有产出任何提示，扫描可能已失效',
      );
    });
  }, skip: root == null ? '不在仓库工作树内（发布归档），结构门禁不适用' : null);
}
