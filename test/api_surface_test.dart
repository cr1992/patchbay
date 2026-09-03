import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/check_api_surface.dart' as tool;

String? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/check_api_surface.dart').existsSync() &&
        File('${dir.path}/tool/api_surface.json').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

void main() {
  final root = _repoRoot();

  group(
    '公共 API surface golden',
    () {
      test('四包公共面与 golden 一致', () {
        final result = Process.runSync(Platform.resolvedExecutable, <String>[
          'run',
          'tool/check_api_surface.dart',
        ], workingDirectory: root);
        expect(
          result.exitCode,
          0,
          reason:
              '公共 API 面漂移：\n${result.stderr}\n'
              '常见来源是把 part 改成独立 library，或 wrapper 整库 export 了拆分产物。',
        );
        expect(result.stdout.toString(), contains('与 golden 一致'));
      });

      test('golden 覆盖四个发布包的每个公开 library 且非空', () {
        final decoded =
            jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
                as Map<String, Object?>;

        // 空 golden 会让门禁恒过——这是最危险的失效形态。PB-050-13 之后总量不再是
        // 有意义的下限（CLI 从 220 收到 10），所以逐包逐 library 判非空：门禁形同
        // 虚设的形态是「某个入口没被记录」，不是「符号总数变少」。
        for (final pkg in const <String>[
          'patchbay',
          'patchbay_cli',
          'patchbay_flutter',
          'patchbay_transport',
        ]) {
          final libraries = decoded[pkg];
          expect(
            libraries,
            isA<Map<String, Object?>>(),
            reason: '$pkg 不在 golden 里，门禁对它形同虚设',
          );
          final byLibrary = libraries! as Map<String, Object?>;
          expect(byLibrary, isNotEmpty, reason: '$pkg 一个公开 library 都没记录');
          for (final entry in byLibrary.entries) {
            expect(
              entry.key,
              startsWith('lib/'),
              reason: '$pkg 的 golden key 必须是包相对的 library 路径',
            );
            expect(
              entry.value! as List<Object?>,
              isNotEmpty,
              reason: '$pkg ${entry.key} 记录为空，等于不设防',
            );
          }
        }

        // DG-050-07 冻结的封闭清单，写在 golden 自己身上：`--update` 可以毫无阻力
        // 地把一个新符号写进 golden，而这条断言是那次改动必须同时解释的地方。
        final cli = decoded['patchbay_cli']! as Map<String, Object?>;
        expect(cli.keys.toSet(), <String>{
          'lib/patchbay_cli.dart',
          'lib/patchbay_client.dart',
        });
        expect(cli['lib/patchbay_cli.dart'], <String>[
          'PatchbayExitCode',
          'runPatchbayCli',
        ]);
        // 逐个名字，不只是数量：只断言 length == 8 时，「删一个清单内符号、加一个
        // 清单外符号、再跑一次 --update」长度仍是 8，测试照样绿——那正是这条断言
        // 存在的理由。顺序是 golden 自己的排序（升序）。
        expect(cli['lib/patchbay_client.dart'], <String>[
          'PatchbayClient',
          'PatchbayProtocolException',
          'PatchbayRuntimeIdentity',
          'PatchbaySnapshotDiffClient',
          'PatchbaySnapshotRequest',
          'PatchbayTransportException',
          'connectPatchbayDirect',
          'connectPatchbayVmService',
        ]);
      });

      // DG-060-02 冻结的分层关系，同样写在 golden 自己身上。逐名冻结 250 个 core
      // 符号会让这个文件变成第二份 golden，所以这里冻结的是**集合之间的关系**：
      // 它们才是裁决内容，而且 `--update` 无法自动满足其中任何一条。
      test('三个 core 入口与两个 Flutter 入口维持 DG-060-02 的集合关系', () {
        final decoded =
            jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
                as Map<String, Object?>;
        Set<String> surfaceOf(String pkg, String library) => <String>{
          ...((decoded[pkg]! as Map<String, Object?>)[library]!
                  as List<Object?>)
              .map((v) => v.toString()),
        };

        final consumer = surfaceOf('patchbay', 'lib/patchbay.dart');
        final host = surfaceOf('patchbay', 'lib/patchbay_host.dart');
        final protocol = surfaceOf('patchbay', 'lib/patchbay_protocol.dart');
        final flutter = surfaceOf(
          'patchbay_flutter',
          'lib/patchbay_flutter.dart',
        );
        final flutterHost = surfaceOf(
          'patchbay_flutter',
          'lib/patchbay_flutter_host.dart',
        );

        // 1. host 是 consumer 的严格超集，多出来的恰好是 host-only 集合。
        expect(host.containsAll(consumer), isTrue);
        expect(host.difference(consumer), hasLength(44));

        // 2. protocol 与另外两个入口互不相交——raw wire 不从默认面或 host 面泄漏。
        expect(protocol.intersection(host), isEmpty);
        expect(protocol.intersection(consumer), isEmpty);

        // 3. 默认 Flutter 面 = core consumer 清单 + 四个 widget 侧自有符号。
        expect(flutter.difference(consumer), <String>{
          'PatchbayKey',
          'PatchbayRoot',
          'PatchbayRootController',
          'PatchbayUiRegistry',
        });

        // 4. Flutter host 面 = core host 清单 ∪ Flutter 自有全集（48 个）。
        expect(flutterHost.containsAll(host), isTrue);
        expect(flutterHost.containsAll(flutter), isTrue);
        expect(flutterHost.difference(host), hasLength(48));
        expect(flutterHost.intersection(protocol), isEmpty);

        // 5. 三个角色的代表符号各就各位：这几条是裁决里点名的边界。
        for (final symbol in const <String>[
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayAuditEvent',
        ]) {
          expect(consumer, isNot(contains(symbol)));
          expect(flutter, isNot(contains(symbol)));
          expect(host, contains(symbol));
        }
        for (final symbol in const <String>[
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
          'patchbayCanonicalJson',
        ]) {
          expect(consumer, isNot(contains(symbol)));
          expect(flutter, isNot(contains(symbol)));
          expect(host, isNot(contains(symbol)));
          expect(protocol, contains(symbol));
        }
        for (final symbol in const <String>[
          'PatchbayFlutterServiceHost',
          'PatchbayFlutterBridge',
          'PatchbayRevealPolicy',
          'PatchbaySemanticsActionPolicy',
          'PatchbayGesturePolicy',
        ]) {
          expect(flutter, isNot(contains(symbol)));
          expect(flutterHost, contains(symbol));
        }
      });
    },
    skip: root == null ? '不在仓库工作树内（发布归档），surface 门禁不适用' : null,
  );

  group('按 library 记录的口径（PB-050-13）', () {
    late Directory fixture;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('patchbay-api-surface-');
    });

    tearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });

    void writeLibrary(String pkg, String name, String body) {
      File('${fixture.path}/packages/$pkg/lib/$name')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    test('每个 lib/*.dart 是自己的一条记录，新增入口即新增公共面', () {
      writeLibrary('patchbay', 'patchbay.dart', 'class Only {}\n');
      writeLibrary('patchbay_cli', 'patchbay_cli.dart', 'class First {}\n');
      writeLibrary('patchbay_cli', 'patchbay_client.dart', 'class Second {}\n');

      final surface = tool.computeSurface(fixture.path);

      expect(surface['patchbay_cli']!.keys.toList(), <String>[
        'lib/patchbay_cli.dart',
        'lib/patchbay_client.dart',
      ]);
      expect(surface['patchbay_cli']!['lib/patchbay_cli.dart'], <String>[
        'First',
      ]);
      expect(surface['patchbay_cli']!['lib/patchbay_client.dart'], <String>[
        'Second',
      ]);
      // 未建目录的包记录为空 map，而不是从 golden 里消失。
      expect(surface['patchbay_transport'], isEmpty);
    });

    test('同名符号不跨 library 折叠', () {
      writeLibrary('patchbay_cli', 'patchbay_cli.dart', 'class Shared {}\n');
      writeLibrary('patchbay_cli', 'patchbay_client.dart', 'class Shared {}\n');

      final surface = tool.computeSurface(fixture.path)['patchbay_cli']!;

      // 折叠成一个集合会让「另一个入口也开始暴露它」变成零 diff。
      expect(surface['lib/patchbay_cli.dart'], <String>['Shared']);
      expect(surface['lib/patchbay_client.dart'], <String>['Shared']);
    });

    test('带 show 的跨包 re-export 记进本包，整库 re-export 不展开', () {
      writeLibrary(
        'patchbay',
        'patchbay.dart',
        'class Kept {}\nclass Other {}\n',
      );
      writeLibrary(
        'patchbay_cli',
        'patchbay_cli.dart',
        "export 'package:patchbay/patchbay.dart' show Kept;\n",
      );
      writeLibrary(
        'patchbay_flutter',
        'patchbay_flutter.dart',
        "export 'package:patchbay/patchbay.dart';\nclass Bridge {}\n",
      );

      final surface = tool.computeSurface(fixture.path);

      expect(surface['patchbay_cli']!['lib/patchbay_cli.dart'], <String>[
        'Kept',
      ]);
      // 整库 re-export 保持 0.4.1 口径：不把对方的表算进本包。
      expect(
        surface['patchbay_flutter']!['lib/patchbay_flutter.dart'],
        <String>['Bridge'],
      );
    });

    // 下面三条是独立证伪复现出的绕过场景，固化成永久用例：每一条在修复前都是
    // 「加一行 / 加一个文件 → golden diff 为 0 → 门禁全绿」。
    test('N1：lib/ 下 src 之外的嵌套目录也是公开入口，不是盲区', () {
      writeLibrary('patchbay_cli', 'patchbay_cli.dart', 'class Entry {}\n');
      // `lib/src/**` 是 pub 的私有约定，外部不该 import——不记。
      writeLibrary('patchbay_cli', 'src/hidden.dart', 'class Hidden {}\n');
      writeLibrary(
        'patchbay_cli',
        'src/deep/hidden.dart',
        'class DeepHidden {}\n',
      );
      // `lib/extra/**` 不是：`import 'package:patchbay_cli/extra/leak.dart'`
      // 完全合法，所以它必须作为一条独立 library 出现在 golden 里。
      writeLibrary('patchbay_cli', 'extra/leak.dart', 'class Leak {}\n');
      // 更深处叫 src 的目录同样不是私有约定。
      writeLibrary(
        'patchbay_cli',
        'extra/src/also_public.dart',
        'class AlsoPublic {}\n',
      );

      final surface = tool.computeSurface(fixture.path)['patchbay_cli']!;

      expect(surface.keys.toList(), <String>[
        'lib/extra/leak.dart',
        'lib/extra/src/also_public.dart',
        'lib/patchbay_cli.dart',
      ]);
      expect(surface['lib/extra/leak.dart'], <String>['Leak']);
      expect(surface['lib/extra/src/also_public.dart'], <String>['AlsoPublic']);
    });

    test('N2：封闭清单 library 的无 show 跨包 re-export 当场判红', () {
      writeLibrary('patchbay', 'patchbay.dart', 'class Everything {}\n');
      writeLibrary('patchbay_cli', 'patchbay_cli.dart', 'class Entry {}\n');
      writeLibrary(
        'patchbay_cli',
        'patchbay_client.dart',
        "export 'package:patchbay/patchbay.dart';\n",
      );

      final violations = tool.opaquePackageReexports(fixture.path);

      // 没有这条规则时：golden 里 patchbay_client.dart 记 0 个符号，diff 为 0，
      // 而实际公共面已经是 patchbay 的整张表。
      expect(violations, hasLength(1));
      expect(
        violations.single,
        contains('patchbay_cli lib/patchbay_client.dart'),
      );
      expect(
        violations.single,
        contains("export 'package:patchbay/patchbay.dart';"),
      );
    });

    test('N2：绕过口子藏在 src/ 深处一样算数，带 show 的不算', () {
      writeLibrary('patchbay', 'patchbay.dart', 'class Everything {}\n');
      writeLibrary(
        'patchbay_cli',
        'patchbay_cli.dart',
        "export 'src/relay.dart';\n",
      );
      writeLibrary(
        'patchbay_cli',
        'src/relay.dart',
        "export 'package:patchbay/patchbay.dart';\n",
      );
      writeLibrary(
        'patchbay_cli',
        'patchbay_client.dart',
        "export 'package:patchbay/patchbay.dart' show Everything;\n",
      );

      final violations = tool.opaquePackageReexports(fixture.path);

      expect(violations, hasLength(1));
      expect(violations.single, contains('patchbay_cli lib/patchbay_cli.dart'));
      // 报的是真正出问题的那个文件，而不是入口 library。
      expect(
        violations.single,
        contains('packages/patchbay_cli/lib/src/relay.dart'),
      );
    });

    // PB-060-02：封闭清单从 CLI 一个包扩到四个包。上一版这里断言的是反面
    // ——`patchbay_flutter` 允许整库 re-export——那正是分层要消灭的那一行。
    test('N3：四个发布包的无 show 跨包 re-export 一律判红', () {
      writeLibrary('patchbay', 'patchbay.dart', 'class Everything {}\n');
      writeLibrary('patchbay', 'patchbay_host.dart', 'class HostOnly {}\n');
      // 四个包各留一处无 show 的整库 re-export，包括 core 自己 re-export 自己的
      // 另一个入口：分层之后「host 入口整库带上 consumer 入口」同样算绕过。
      writeLibrary(
        'patchbay',
        'patchbay_protocol.dart',
        "export 'package:patchbay/patchbay.dart';\n",
      );
      writeLibrary(
        'patchbay_cli',
        'patchbay_cli.dart',
        "export 'package:patchbay/patchbay.dart';\n",
      );
      writeLibrary(
        'patchbay_flutter',
        'patchbay_flutter.dart',
        "export 'package:patchbay/patchbay.dart';\nclass Bridge {}\n",
      );
      writeLibrary(
        'patchbay_transport',
        'patchbay_transport.dart',
        "export 'package:patchbay/patchbay.dart';\n",
      );

      final violations = tool.opaquePackageReexports(fixture.path);

      expect(violations, hasLength(4));
      for (final entry in const <String>[
        'patchbay lib/patchbay_protocol.dart',
        'patchbay_cli lib/patchbay_cli.dart',
        'patchbay_flutter lib/patchbay_flutter.dart',
        'patchbay_transport lib/patchbay_transport.dart',
      ]) {
        expect(
          violations.where((v) => v.startsWith(entry)),
          hasLength(1),
          reason: '$entry 的整库 re-export 必须判红',
        );
      }
    });

    test('N3：四个包的带 show 跨包 re-export 都展开，且都不判红', () {
      writeLibrary(
        'patchbay',
        'patchbay.dart',
        'class Consumer {}\nclass NotShown {}\n',
      );
      writeLibrary(
        'patchbay',
        'patchbay_host.dart',
        "export 'package:patchbay/patchbay.dart' show Consumer;\n"
            'class HostOnly {}\n',
      );
      writeLibrary(
        'patchbay_cli',
        'patchbay_client.dart',
        "export 'package:patchbay/patchbay_protocol.dart' show Request;\n",
      );
      writeLibrary(
        'patchbay_flutter',
        'patchbay_flutter_host.dart',
        "export 'package:patchbay/patchbay_host.dart' show Consumer, HostOnly;\n"
            'class Bridge {}\n',
      );
      writeLibrary(
        'patchbay_transport',
        'patchbay_transport.dart',
        "export 'package:patchbay/patchbay_protocol.dart' show Request;\n"
            'class DirectHost {}\n',
      );

      expect(tool.opaquePackageReexports(fixture.path), isEmpty);

      final surface = tool.computeSurface(fixture.path);

      // 跨包 re-export 的符号名就写在 export 行上，因此不必解析对方包也能记账；
      // 没有 show 的那部分（NotShown）不会跟着漏进来。
      expect(surface['patchbay']!['lib/patchbay_host.dart'], <String>[
        'Consumer',
        'HostOnly',
      ]);
      expect(surface['patchbay_cli']!['lib/patchbay_client.dart'], <String>[
        'Request',
      ]);
      expect(
        surface['patchbay_flutter']!['lib/patchbay_flutter_host.dart'],
        <String>['Bridge', 'Consumer', 'HostOnly'],
      );
      expect(
        surface['patchbay_transport']!['lib/patchbay_transport.dart'],
        <String>['DirectHost', 'Request'],
      );
    });
  });
}
