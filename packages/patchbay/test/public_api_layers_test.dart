// PB-060-02 / DG-060-02 的角色编译 fixture。
//
// golden（`tool/api_surface.json`）是**工具按正则展开** export/show 算出来的；
// 这个文件是**编译器**对同一份清单的独立复核。两者只在源码里的 `show` 子句与
// 工具的解析一致时才会同时通过，因此它抓的是「golden 记着、编译器却看不见」和
// 「编译器看得见、golden 没记」这两种漂移——单跑 checker 抓不到。
//
// 三段：
//
// - 正向清单：把整份 golden 清单写进一条 `import ... show ...`，清单里任何一个名字
//   不再从该入口导出，分析器就报 `undefined_shown_name`；
// - 正向场景：只 import 默认入口，真的去实现一个 `PatchbayLogSource`。修订②之前
//   这一段是红的——`PatchbayCancellationSignal`、`PatchbayLogLevelWire`、
//   `PatchbayLogRecordWire`、`PatchbayContextCommandHandler` 都不在默认面；
// - 反向不可见：引用别的角色的符号，让它以 `undefined_class` 失败。断言按**加引号的
//   精确名**匹配 analyzer 消息，避免 `PatchbayInvocation` 被 `PatchbayInvocationWire`
//   的错误消息顺手满足。
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
      if (entry.key != 'internal')
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

  /// analyzer 的诊断消息把符号名放在单引号里（`Undefined class 'Foo'.`）。
  ///
  /// 用裸子串匹配会让 `PatchbayInvocation` 被 `'PatchbayInvocationWire'` 满足——
  /// 那条反向断言就永远绿，哪怕 `PatchbayInvocation` 真的泄漏进了默认面。
  bool mentions(String symbol) => output.contains("'$symbol'");
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

  group('默认入口的自足场景（修订②的回归）', () {
    test(
      '只 import patchbay.dart 就能实现 PatchbayLogSource 与 context 命令',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          'scenario_consumer',
          '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay.dart';

/// 接入方最典型的一段代码：把自家日志接进 `logs query` / `logs tail`。
///
/// 它需要能命名四个类型：`PatchbayLogQuery`、`PatchbayLogPage`，以及
/// `PatchbayCancellationSignal`（形参）。第一版分层把后者留在 host 入口，于是
/// 接入方照迁移表改完会拿到 undefined_class —— 这个 fixture 就是那条 bug 的回归。
final class ExampleLogSource implements PatchbayLogSource {
  @override
  Future<PatchbayLogPage> query(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) async => throw UnimplementedError();

  @override
  Future<PatchbayLogPage> tail(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) async => throw UnimplementedError();
}

/// `PatchbayRedactedLogRecord` 公开 `wire` 字段，类型必须也在默认面。
PatchbayLogRecordWire wireOf(PatchbayRedactedLogRecord record) => record.wire;

/// `PatchbayLogQuery` 的构造函数收这两个枚举。
PatchbayLogQuery buildQuery(
  PatchbayLogLevelWire level,
  PatchbayLogDirectionWire direction,
) => throw UnimplementedError();

/// `PatchbayCommandRegistration.contextAware` 的必填形参类型。
PatchbayContextCommandHandler? handler;

/// `PatchbayCommandDescriptor.cliSyntax` 的元素类型。
List<PatchbayCliSyntax>? syntax;

/// `PatchbayCommandRegistry.tryDispatch` 的形参类型。
PatchbayInvocationContext? context;

/// `PatchbayMemoryBlobStore.put` 与 `.read` 的签名类型。
PatchbayBlobMetadataWire? metadata;
PatchbayBlobSourceWire? source;
PatchbayBlobChunkWire? chunk;

/// `PatchbayNavigationOperation.wire` 与 `PatchbayDestinationDescriptor.toWire`。
PatchbayNavigationOperationWire? navigation;
PatchbayDestinationDescriptorWire? destination;
''',
        );

        expect(
          analysis.exitCode,
          0,
          reason:
              '默认 consumer 入口不自足——接入方按迁移表改完会拿到 undefined_class：\n'
              '${analysis.output}',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: root == null ? '不在仓库工作树内（发布归档）' : null);

  group('角色入口的反向不可见性（越界即编译失败）', () {
    test(
      '默认 consumer 入口看不见 host lifecycle 与 raw wire',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          'negative_consumer',
          '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay.dart';

void main() {
  // 正向：默认面本来就该有的东西，用来证明这个 fixture 的错误确实来自越界。
  print(PatchbayCommandRegistry);
  print(PatchbayLogSource);
  // host lifecycle：默认接入者不该在 widget/adapter 文件里拿到它。
  PatchbayServiceHost host;
  PatchbayInvocation invocation;
  PatchbayRejection rejection;
  PatchbayAuditEvent event;
  PatchbayAdmission admission;
  validatePatchbayResponsePayload(null, null);
  // raw wire 与 client-only protocol 词汇。
  PatchbayInvocationWire wire;
  PatchbayCatalogDigest digest;
  PatchbaySnapshotRequest request;
  PatchbayFeature feature;
  patchbayCanonicalJson(const <String, Object?>{});
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayRejection',
          'PatchbayAuditEvent',
          'PatchbayAdmission',
          'validatePatchbayResponsePayload',
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
          'PatchbaySnapshotRequest',
          'PatchbayFeature',
          'patchbayCanonicalJson',
        ]) {
          expect(
            analysis.mentions(symbol),
            isTrue,
            reason: '$symbol 必须无法从默认 consumer 入口解析',
          );
        }
        for (final String symbol in const <String>[
          'PatchbayCommandRegistry',
          'PatchbayLogSource',
        ]) {
          expect(
            analysis.mentions(symbol),
            isFalse,
            reason: '$symbol 是默认面的一部分，不该解析失败',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'host 入口看得见 host lifecycle，但仍看不见完整 protocol 面',
      () async {
        final _Analysis analysis = await _analyzeFixture('negative_host', '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay_host.dart';

void main() {
  // 正向：host 面确实是 consumer 面的超集，且带上 PatchbayServiceHost 需要的
  // PatchbayFeature。
  print(PatchbayCommandRegistry);
  print(PatchbayServiceHost);
  print(PatchbayInvocation);
  print(PatchbayFeature);
  // 反向：与 host 无关的 raw wire 与 protocol 词汇不跟着进来。
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
            analysis.mentions(symbol),
            isTrue,
            reason: '$symbol 必须留在 protocol 入口',
          );
        }
        for (final String symbol in const <String>[
          'PatchbayCommandRegistry',
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayFeature',
        ]) {
          expect(
            analysis.mentions(symbol),
            isFalse,
            reason: 'host 入口必须是 consumer 清单的严格超集，并自足到 PatchbayFeature',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'protocol 入口不 re-export host 面，也不带 registry/gate/job',
      () async {
        final _Analysis analysis = await _analyzeFixture(
          'negative_protocol',
          '''
// ignore_for_file: unused_local_variable
import 'package:patchbay/patchbay_protocol.dart';

void main() {
  // 正向：raw wire、protocol 词汇，以及 canonical descriptor 常量的类型。
  print(PatchbayInvocationWire);
  print(PatchbayCommandDescriptor);
  print(patchbayCanonicalJson(const <String, Object?>{}));
  // 反向：注册、门禁、job 与 host lifecycle 都不在。
  PatchbayCommandRegistry registry;
  PatchbayGateEvaluator gate;
  PatchbayJobRegistry jobs;
  PatchbayServiceHost host;
  PatchbayInvocation invocation;
}
''',
        );

        expect(analysis.exitCode, isNot(0));
        for (final String symbol in const <String>[
          'PatchbayCommandRegistry',
          'PatchbayGateEvaluator',
          'PatchbayJobRegistry',
          'PatchbayServiceHost',
          'PatchbayInvocation',
        ]) {
          expect(
            analysis.mentions(symbol),
            isTrue,
            reason: '$symbol 不属于 protocol 角色',
          );
        }
        for (final String symbol in const <String>[
          'PatchbayInvocationWire',
          'PatchbayCommandDescriptor',
          'patchbayCanonicalJson',
        ]) {
          expect(
            analysis.mentions(symbol),
            isFalse,
            reason: '$symbol 是 protocol 入口自足闭包的一部分',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: root == null ? '不在仓库工作树内（发布归档）' : null);
}
