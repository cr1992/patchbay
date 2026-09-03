// PB-060-02 / DG-060-02 的角色编译 fixture。
//
// golden（`tool/api_surface.json`）是**工具按正则展开** export/show 算出来的；
// 这个文件是**编译器**对同一份清单的独立复核。两者只在源码里的 `show` 子句与
// 工具的解析一致时才会同时通过，因此它抓的是「golden 记着、编译器却看不见」和
// 「编译器看得见、golden 没记」这两种漂移——单跑 checker 抓不到。
//
// 正向部分把整份清单写进一条 `import ... show ...`：清单里任何一个名字不再从该
// 入口导出，分析器就报 `undefined_shown_name`。反向部分直接引用别的角色的符号，
// 让它以 `undefined_class` / `undefined_identifier` 失败——不是「应该不可见」，
// 是编译器拒绝。
//
// fixture 写在 `.dart_tool/` 下：包解析照样找得到 `package:patchbay/…`，而本包
// 自己的 `dart analyze` 不会下探到那里，所以「必须编译失败」的反向 fixture 不会
// 把仓库的 analyze 门禁弄红。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String? _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/api_surface.json').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}

Map<String, List<String>> _goldenLibraries(String root, String package) {
  final decoded =
      jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
          as Map<String, Object?>;
  final byLibrary = decoded[package]! as Map<String, Object?>;
  return <String, List<String>>{
    for (final entry in byLibrary.entries)
      entry.key: <String>[
        for (final Object? name in entry.value! as List<Object?>)
          name.toString(),
      ],
  };
}

final class _Analysis {
  const _Analysis(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

Future<_Analysis> _analyzeFixture(String name, String source) async {
  final Directory root = Directory(
    '${Directory.current.path}/.dart_tool/patchbay_api_layers/$name',
  )..createSync(recursive: true);
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final File file = File('${root.path}/fixture.dart')
    ..writeAsStringSync(source);
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>['analyze', file.path],
    workingDirectory: Directory.current.path,
  );
  return _Analysis(result.exitCode, '${result.stdout}\n${result.stderr}');
}

/// 一条 `import ... show <整份清单>;` 的 fixture 源码。
String _showEverything(String library, List<String> symbols) {
  final StringBuffer out = StringBuffer()
    ..writeln('// ignore_for_file: unused_import')
    ..writeln("import 'package:patchbay/$library'")
    ..writeln('    show');
  for (int i = 0; i < symbols.length; i++) {
    out.writeln('        ${symbols[i]}${i == symbols.length - 1 ? ';' : ','}');
  }
  return out.toString();
}

void main() {
  final String? root = _repoRoot();

  group(
    '角色入口的正向可见性（清单逐名可编译）',
    () {
      late Map<String, List<String>> libraries;

      setUp(() {
        libraries = _goldenLibraries(root!, 'patchbay');
      });

      for (final String library in const <String>[
        'patchbay.dart',
        'patchbay_host.dart',
        'patchbay_protocol.dart',
      ]) {
        test(
          '$library 导出 golden 记录的每一个符号',
          () async {
            final List<String> symbols = libraries['lib/$library']!;
            expect(symbols, isNotEmpty);
            final _Analysis analysis = await _analyzeFixture(
              'positive_${library.replaceAll('.dart', '')}',
              _showEverything(library, symbols),
            );
            expect(
              analysis.exitCode,
              0,
              reason:
                  '$library 的 show 清单没有全部解析成功——golden 与源码已经不是同一份'
                  '清单：\n${analysis.output}',
            );
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }
    },
    skip: root == null ? '不在仓库工作树内（发布归档），角色 fixture 不适用' : null,
  );

  group('角色入口的反向不可见性（越界即编译失败）', () {
    test(
      '默认 consumer 入口看不见 host lifecycle 与 raw wire',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          'negative_consumer',
          '''
import 'package:patchbay/patchbay.dart';

void main() {
  // host lifecycle：默认接入者不该在 widget/adapter 文件里拿到它。
  PatchbayServiceHost host;
  PatchbayInvocation invocation;
  PatchbayAuditEvent event;
  PatchbayAdmission admission;
  validatePatchbayResponsePayload(null, null);
  // raw wire 与 client-only protocol 词汇。
  PatchbayInvocationWire wire;
  PatchbayCatalogDigest digest;
  PatchbaySnapshotRequest request;
  patchbayCanonicalJson(const <String, Object?>{});
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayAuditEvent',
          'PatchbayAdmission',
          'validatePatchbayResponsePayload',
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
          'PatchbaySnapshotRequest',
          'patchbayCanonicalJson',
        ]) {
          expect(
            analysis.output,
            contains(symbol),
            reason: '$symbol 必须无法从默认 consumer 入口解析',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'host 入口看得见 host lifecycle，但仍看不见 raw wire',
      () async {
        final _Analysis analysis = await _analyzeFixture('negative_host', '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay_host.dart';

void main() {
  // 正向：host 面确实是 consumer 面的超集。
  print(PatchbayCommandRegistry);
  print(PatchbayServiceHost);
  // 反向：raw wire 与 protocol 词汇不跟着进来。
  PatchbayInvocationWire wire;
  PatchbayCatalogDigest digest;
  PatchbaySnapshotRequest request;
  patchbayCanonicalJson(const <String, Object?>{});
}
''');

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
          'PatchbaySnapshotRequest',
          'patchbayCanonicalJson',
        ]) {
          expect(
            analysis.output,
            contains(symbol),
            reason: '$symbol 必须留在 protocol 入口',
          );
        }
        expect(
          analysis.output,
          isNot(contains('PatchbayCommandRegistry')),
          reason: 'host 入口必须是 consumer 清单的严格超集',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'protocol 入口不 re-export consumer 与 host 清单',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          'negative_protocol',
          '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay_protocol.dart';

void main() {
  // 正向：raw wire 与 protocol 词汇在这里。
  print(PatchbayInvocationWire);
  print(patchbayCanonicalJson(const <String, Object?>{}));
  // 反向：business descriptor 与 host lifecycle 都不在。
  PatchbayCommandRegistry registry;
  PatchbayGateEvaluator gate;
  PatchbayJobRegistry jobs;
  PatchbayServiceHost host;
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayCommandRegistry',
          'PatchbayGateEvaluator',
          'PatchbayJobRegistry',
          'PatchbayServiceHost',
        ]) {
          expect(
            analysis.output,
            contains(symbol),
            reason: '$symbol 不属于 protocol 角色',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
