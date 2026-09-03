// PB-060-02 / DG-060-02 的 Flutter 角色编译 fixture。
//
// 与 `packages/patchbay/test/public_api_layers_test.dart` 同一套机制：正向把整份
// golden 清单写进一条 `import ... show ...` 让编译器逐名复核，反向直接引用别的角色
// 的符号让分析器拒绝。这里额外要证明的是两条 Flutter 侧的裁决：
//
// - 默认面 `patchbay_flutter.dart` 只多出四个 widget 侧符号，service host、bridge
//   与 policy 都不在；
// - `patchbay_flutter_host.dart` 是 core host 面与 Flutter 自有全集的并集，但仍然
//   不 re-export protocol。
//
// `flutter test` 跑在 `flutter_tester` 里，所以 `Platform.resolvedExecutable` 不是
// dart——分析器可执行文件从 `FLUTTER_ROOT` 取。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String? _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/api_surface.json').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}

String? _dartExecutable() {
  final String exe = Platform.resolvedExecutable;
  if (exe.endsWith('/dart') || exe.endsWith(r'\dart.exe')) return exe;
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return null;
  final String candidate = '$flutterRoot/bin/dart';
  return File(candidate).existsSync() ? candidate : null;
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

Future<_Analysis> _analyzeFixture(
  String dart,
  String name,
  String source,
) async {
  final Directory root = Directory(
    '${Directory.current.path}/.dart_tool/patchbay_api_layers/$name',
  )..createSync(recursive: true);
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final File file = File('${root.path}/fixture.dart')
    ..writeAsStringSync(source);
  final ProcessResult result = await Process.run(dart, <String>[
    'analyze',
    file.path,
  ], workingDirectory: Directory.current.path);
  return _Analysis(result.exitCode, '${result.stdout}\n${result.stderr}');
}

String _showEverything(String library, List<String> symbols) {
  final StringBuffer out = StringBuffer()
    ..writeln('// ignore_for_file: unused_import')
    ..writeln("import 'package:patchbay_flutter/$library'")
    ..writeln('    show');
  for (int i = 0; i < symbols.length; i++) {
    out.writeln('        ${symbols[i]}${i == symbols.length - 1 ? ';' : ','}');
  }
  return out.toString();
}

void main() {
  final String? root = _repoRoot();
  final String? dart = _dartExecutable();
  final String? skip = root == null
      ? '不在仓库工作树内（发布归档），角色 fixture 不适用'
      : dart == null
      ? '找不到 dart 可执行文件（FLUTTER_ROOT 未设置）'
      : null;

  group('Flutter 角色入口', () {
    test('两个入口都导出 golden 记录的每一个符号', () async {
      final Map<String, List<String>> libraries = _goldenLibraries(
        root!,
        'patchbay_flutter',
      );
      for (final String library in const <String>[
        'patchbay_flutter.dart',
        'patchbay_flutter_host.dart',
      ]) {
        final List<String> symbols = libraries['lib/$library']!;
        expect(symbols, isNotEmpty);
        final _Analysis analysis = await _analyzeFixture(
          dart!,
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
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      '默认 Flutter 面看不见 service host、bridge、policy 与 raw wire',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          dart!,
          'negative_flutter',
          '''
// ignore_for_file: avoid_print, unused_local_variable
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  // 正向：widget 文件真正需要的四个符号在这里。
  print(PatchbayKey);
  print(PatchbayRoot);
  print(PatchbayRootController);
  print(PatchbayUiRegistry);
  // 反向：组合根才该看见的东西。
  PatchbayFlutterServiceHost host;
  PatchbayFlutterBridge bridge;
  PatchbayRevealPolicy reveal;
  PatchbaySemanticsActionPolicy semantics;
  PatchbayGesturePolicy gesture;
  PatchbayServiceHost core;
  PatchbayInvocation invocation;
  // 反向：raw wire 不从最常用的入口泄漏。
  PatchbayInvocationWire wire;
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayFlutterServiceHost',
          'PatchbayFlutterBridge',
          'PatchbayRevealPolicy',
          'PatchbaySemanticsActionPolicy',
          'PatchbayGesturePolicy',
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayInvocationWire',
        ]) {
          expect(
            analysis.output,
            contains(symbol),
            reason: '$symbol 必须无法从默认 Flutter 入口解析',
          );
        }
        for (final String symbol in const <String>[
          'PatchbayKey',
          'PatchbayRoot',
          'PatchbayUiRegistry',
        ]) {
          expect(
            analysis.output,
            isNot(contains(symbol)),
            reason: '$symbol 是 widget 文件的默认词汇，必须留在默认面',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'Flutter host 面覆盖 core host，但仍不 re-export protocol',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          dart!,
          'negative_flutter_host',
          '''
// ignore_for_file: avoid_print, unused_local_variable
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

void main() {
  // 正向：组合根只要这一个 import 就够——widget 词汇、Flutter host 与 core host
  // 都在。
  print(PatchbayRoot);
  print(PatchbayFlutterServiceHost);
  print(PatchbayServiceHost);
  print(PatchbayCommandRegistry);
  // 反向：raw wire 仍然要显式再 import protocol 入口。
  PatchbayInvocationWire wire;
  PatchbayCatalogDigest digest;
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
        ]) {
          expect(
            analysis.output,
            contains(symbol),
            reason: '$symbol 必须留在 protocol 入口',
          );
        }
        for (final String symbol in const <String>[
          'PatchbayRoot',
          'PatchbayFlutterServiceHost',
          'PatchbayServiceHost',
          'PatchbayCommandRegistry',
        ]) {
          expect(
            analysis.output,
            isNot(contains(symbol)),
            reason: 'Flutter host 面必须同时覆盖默认面与 core host 面',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: skip);
}
