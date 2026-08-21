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

  group('结构棘轮 (PB-041-03)', () {
    late ProcessResult result;

    setUpAll(() {
      result = Process.runSync(Platform.resolvedExecutable, <String>[
        'run',
        'tool/check_structure_ratchet.dart',
      ], workingDirectory: root);
    });

    test('全仓通过体积预算、part 与跨包封装规则', () {
      expect(
        result.exitCode,
        0,
        reason: '结构棘轮失败：\n${result.stderr}\n${result.stdout}',
      );
      expect(result.stdout.toString(), contains('结构棘轮通过'));
    });

    test('欠账表非空时必须被打印出来，不允许静默豁免', () {
      final baseline = File(
        '$root/tool/structure_baseline.json',
      ).readAsStringSync();
      final hasDebt = !RegExp(
        r'"accepted_debt"\s*:\s*\{\s*\}',
      ).hasMatch(baseline);
      if (!hasDebt) return;

      expect(
        result.stdout.toString(),
        contains('尚未偿还的结构欠账'),
        reason: '基线里登记了欠账，但门禁输出没有提示——欠账会被忘掉',
      );
    });
  }, skip: root == null ? '不在仓库工作树内（发布归档），结构门禁不适用' : null);
}
