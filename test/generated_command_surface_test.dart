// BUG-20260904-01：生成产物的公共面自足门禁。
//
// `check_api_surface` 回答「入口导出了哪些名字」，`check_api_closure` 回答「照着一个
// 入口 import 进来，手写代码真的能用吗」。两者都只覆盖**人写的**代码。
// `command_codegen` 产出的 Dart 谁都没覆盖：仓内 `example_commands.g.dart` 只是一份
// sha256 快照，`command_codegen_test.dart` 只做字符串断言，生成的 Dart 从未被 analyze
// 或编译过。于是 PB-060-02 把 `PatchbayRejection` 移出默认面之后，生成器仍然照旧产出
// 引用它、却只 import 默认面的代码——接入方两个合法 `descriptorImport` 取值都编不过，
// 而生成文件带 DO-NOT-MODIFY 标记、手改又会被自身的 codegen 漂移闸判红。
//
// 本条把那块盲区补上：对每个合法 `descriptorImport`，生成一次真 Dart，把它引用的每个
// `Patchbay*` 名字与 `tool/api_surface.json` 里该入口的冻结清单对账。任何一次入口收窄
// 只要漏了生成器，这里立刻红，而不是等接入方换 pin 才炸。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String? _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/api_surface.json').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

/// `descriptorImport` 的合法取值 → 它在 `api_surface.json` 里的坐标。
const Map<String, (String, String)> _entries = <String, (String, String)>{
  'package:patchbay/patchbay_host.dart': ('patchbay', 'lib/patchbay_host.dart'),
  'package:patchbay_flutter/patchbay_flutter_host.dart': (
    'patchbay_flutter',
    'lib/patchbay_flutter_host.dart',
  ),
};

/// 生成产物里出现的 `Patchbay` 前缀标识符。合约自己的 `apiPrefix` 不会撞上它——
/// 仓内 fixture 用 `FixturePatchbay`，正则要求 `Patchbay` 之前不是标识符字符。
final RegExp _patchbaySymbol = RegExp(
  r'(?<![A-Za-z0-9_$])Patchbay[A-Za-z0-9_]+',
);

void main() {
  final String? root = _repoRoot();

  group('生成的命令代码只引用其声明入口导出的名字（BUG-20260904-01）', () {
    late Map<String, dynamic> surface;
    late Map<String, dynamic> contract;

    setUpAll(() {
      if (root == null) return;
      surface =
          jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
              as Map<String, dynamic>;
      contract =
          jsonDecode(
                File(
                  '$root/packages/patchbay/contracts/example_commands.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    for (final MapEntry<String, (String, String)> entry in _entries.entries) {
      test('${entry.key} 的生成产物自足', () {
        if (root == null) {
          fail('未能定位仓库根（tool/api_surface.json）');
        }
        final Directory temporary = Directory.systemTemp.createTempSync(
          'patchbay-generated-surface-',
        );
        addTearDown(() => temporary.deleteSync(recursive: true));

        // 只改 descriptorImport：其余保持仓内 fixture，避免这条测试维护第二份合约。
        final Map<String, dynamic> variant = Map<String, dynamic>.from(contract)
          ..['descriptorImport'] = entry.key;
        final File contractFile = File('${temporary.path}/commands.json')
          ..writeAsStringSync(jsonEncode(variant));
        final File output = File('${temporary.path}/commands.g.dart');

        final ProcessResult generated =
            Process.runSync(Platform.resolvedExecutable, <String>[
              'run',
              'packages/patchbay/tool/command_codegen.dart',
              '--contract',
              contractFile.path,
              '--output',
              output.path,
              '--write',
            ], workingDirectory: root);
        expect(generated.exitCode, 0, reason: generated.stderr.toString());

        final String dart = output.readAsStringSync();
        expect(dart, contains("import '${entry.key}';"));

        final (String package, String library) = entry.value;
        final List<String> exported =
            ((surface[package] as Map<String, dynamic>)[library]
                    as List<dynamic>)
                .cast<String>();

        final Set<String> referenced = _patchbaySymbol
            .allMatches(dart)
            .map((match) => match.group(0)!)
            .toSet();
        // 生成器必须引用点什么，否则这条测试会在生成器退化成空壳时静默通过。
        expect(referenced, isNotEmpty);

        final List<String> missing =
            referenced.where((name) => !exported.contains(name)).toList()
              ..sort();
        expect(
          missing,
          isEmpty,
          reason:
              '生成产物引用了 ${entry.key} 没有导出的名字：$missing。'
              '要么把它们收进该入口，要么让生成器改导出另一个入口——'
              '不能留给接入方，生成文件他们改不了。',
        );
      });
    }

    test('0.5.x 的 consumer 面取值被逐值拒绝并给出唯一替代', () {
      if (root == null) {
        fail('未能定位仓库根（tool/api_surface.json）');
      }
      final Directory temporary = Directory.systemTemp.createTempSync(
        'patchbay-generated-surface-legacy-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));

      const Map<String, String> legacy = <String, String>{
        'package:patchbay/patchbay.dart': 'package:patchbay/patchbay_host.dart',
        'package:patchbay_flutter/patchbay_flutter.dart':
            'package:patchbay_flutter/patchbay_flutter_host.dart',
      };

      for (final MapEntry<String, String> pair in legacy.entries) {
        final Map<String, dynamic> variant = Map<String, dynamic>.from(contract)
          ..['descriptorImport'] = pair.key;
        final File contractFile = File(
          '${temporary.path}/${pair.value.hashCode}.json',
        )..writeAsStringSync(jsonEncode(variant));
        final ProcessResult result =
            Process.runSync(Platform.resolvedExecutable, <String>[
              'run',
              'packages/patchbay/tool/command_codegen.dart',
              '--contract',
              contractFile.path,
              '--output',
              '${temporary.path}/out.g.dart',
              '--write',
            ], workingDirectory: root);
        expect(result.exitCode, isNot(0));
        // 拒绝必须点名替代值：接入方看到的就是这一行，没有第二处可查。
        expect(result.stderr.toString(), contains(pair.value));
      }
    });
  });
}
