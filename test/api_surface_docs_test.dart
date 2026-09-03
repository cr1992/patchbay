import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// 五个公共入口的符号数在对外文档里各写了一份（README 两语的入口表、guide 的
/// 「选择公共入口」表、design.md 与 code-structure.md 的散文）。数字随每个往
/// 入口清单里加符号的 MR 变化，靠人记得改五处已经漏过一次；这里把它们钉到
/// `tool/api_surface.json` 的 golden 上——golden 变了、文档没跟上就红。
String? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/api_surface.json').existsSync() &&
        File('${dir.path}/docs/guide.md').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

const Map<String, (String, String)> _entries = <String, (String, String)>{
  'patchbay.dart': ('patchbay', 'lib/patchbay.dart'),
  'patchbay_host.dart': ('patchbay', 'lib/patchbay_host.dart'),
  'patchbay_protocol.dart': ('patchbay', 'lib/patchbay_protocol.dart'),
  'patchbay_flutter.dart': ('patchbay_flutter', 'lib/patchbay_flutter.dart'),
  'patchbay_flutter_host.dart': (
    'patchbay_flutter',
    'lib/patchbay_flutter_host.dart',
  ),
};

Map<String, int> _goldenCounts(String root) {
  final Map<String, Object?> golden =
      jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
          as Map<String, Object?>;
  return <String, int>{
    for (final MapEntry<String, (String, String)> e in _entries.entries)
      e.key:
          ((golden[e.value.$1]! as Map<String, Object?>)[e.value.$2]! as List)
              .length,
  };
}

/// 入口表里每行最后一个纯数字单元格就是该入口的符号数。
Map<String, int> _tableCounts(String text) {
  final out = <String, int>{};
  for (final String line in const LineSplitter().convert(text)) {
    if (!line.startsWith('| `package:')) continue;
    for (final String lib in _entries.keys) {
      if (!line.contains('/$lib`')) continue;
      final Iterable<RegExpMatch> cells = RegExp(
        r'\|\s*(\d+)\s*(?=\|)',
      ).allMatches(line);
      if (cells.isNotEmpty) out[lib] = int.parse(cells.last.group(1)!);
    }
  }
  return out;
}

void main() {
  final String? root = _repoRoot();

  group('公共入口符号数与 golden 一致', () {
    late Map<String, int> golden;
    setUpAll(() => golden = _goldenCounts(root!));

    for (final String doc in const <String>[
      'README.md',
      'README.zh-CN.md',
      'docs/guide.md',
    ]) {
      test('$doc 的入口表', () {
        final Map<String, int> counts = _tableCounts(
          File('$root/$doc').readAsStringSync(),
        );
        expect(counts.keys, containsAll(_entries.keys), reason: '$doc 缺入口行');
        expect(counts, golden, reason: '$doc 的符号数与 tool/api_surface.json 不一致');
      });
    }

    test('docs/design.md 的散文', () {
      final String text = File('$root/docs/design.md').readAsStringSync();
      final int consumer = golden['patchbay.dart']!;
      final int host = golden['patchbay_host.dart']!;
      expect(
        text,
        contains('`patchbay.dart` 是 $consumer 符号的默认 consumer façade'),
      );
      expect(
        text,
        contains('追加 ${host - consumer} 个 host\nlifecycle 符号（共 $host）'),
      );
      expect(
        text,
        contains(
          '`patchbay_protocol.dart` 是 ${golden['patchbay_protocol.dart']} 个',
        ),
      );
      expect(
        text,
        contains('`PatchbayUiRegistry`（共 ${golden['patchbay_flutter.dart']}）'),
      );
      expect(
        text,
        contains(
          '`patchbay_flutter_host.dart`（${golden['patchbay_flutter_host.dart']}）',
        ),
      );
    });

    test('docs/code-structure.md 的散文', () {
      final String text = File(
        '$root/docs/code-structure.md',
      ).readAsStringSync();
      expect(
        text,
        contains(
          '当前 consumer ${golden['patchbay.dart']}、host ${golden['patchbay_host.dart']}、'
          'protocol ${golden['patchbay_protocol.dart']}；Flutter 默认 ${golden['patchbay_flutter.dart']}、\n'
          'Flutter host ${golden['patchbay_flutter_host.dart']}',
        ),
      );
    });
  }, skip: root == null ? '仓根不可达' : false);
}
