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
          // PB-060-02：`internal` 是保留键，不是 library 路径——它记的是
          // `lib/src/**` 里没被任何入口导出的公共名。它可以为空（transport 就是），
          // 但**必须存在**：键不在就等于这条门禁对该包没建账。
          expect(
            byLibrary.keys,
            contains('internal'),
            reason: '$pkg 没有 internal 清单，src 里新增公共符号将无人看见',
          );
          for (final entry in byLibrary.entries) {
            if (entry.key == 'internal') continue;
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
          'internal',
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

      // DG-060-02（含 2026-09-03 裁决修订）冻结的分层关系，同样写在 golden 自己
      // 身上。逐名冻结几百个符号会让这个文件变成第二份 golden，所以这里冻结的是
      // **集合之间的关系**：它们才是裁决内容，而且 `--update` 无法自动满足其中任何
      // 一条。
      //
      // 修订②之后关系变了一条：入口自足是硬约束，所以 protocol 与 consumer **有意
      // 重叠**（`patchbayUiWaitCommandDescriptor` 的类型就是 `PatchbayCommandDescriptor`，
      // `PatchbayLogQuery` 的构造函数收 `PatchbayLogLevelWire`）。原来的「三集合互不
      // 相交」不再成立，也不该成立——它当初正是让默认入口不自足的那条规则。
      test('五个入口维持 DG-060-02 修订后的集合关系', () {
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

        // 1. host 是 consumer 的严格超集。
        expect(host.containsAll(consumer), isTrue);
        expect(host.length, greaterThan(consumer.length));

        // 2. 默认 Flutter 面 = core consumer 清单 + 恰好四个 widget 侧自有符号。
        //    「恰好四个」是裁决内容：多一个就说明 host/bridge 又漏回默认面了。
        expect(flutter.difference(consumer), <String>{
          'PatchbayKey',
          'PatchbayRoot',
          'PatchbayRootController',
          'PatchbayUiRegistry',
        });

        // 3. Flutter host 面同时覆盖 core host 面与默认 Flutter 面。
        expect(flutterHost.containsAll(host), isTrue);
        expect(flutterHost.containsAll(flutter), isTrue);

        // 4. 三个角色的代表符号各就各位：这几条是裁决里点名的边界。
        //    host lifecycle 不进默认面。
        for (final symbol in const <String>[
          'PatchbayServiceHost',
          'PatchbayInvocation',
          'PatchbayRejection',
          'PatchbayAdmission',
          'PatchbayAuditEvent',
          'patchbayProjectAuditEvent',
        ]) {
          expect(consumer, isNot(contains(symbol)));
          expect(flutter, isNot(contains(symbol)));
          expect(host, contains(symbol));
        }
        //    只有协议实现者才需要的东西不进 consumer 面，也不进 host 面。
        for (final symbol in const <String>[
          'PatchbayInvocationWire',
          'PatchbayCatalogDigest',
          'patchbayCanonicalJson',
          'PatchbaySnapshotRequest',
        ]) {
          expect(consumer, isNot(contains(symbol)));
          expect(flutter, isNot(contains(symbol)));
          expect(host, isNot(contains(symbol)));
          expect(protocol, contains(symbol));
        }
        //    Flutter 的 service host / bridge / policy 不进 widget 默认面。
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

        // 5. 自足闭包拉进 consumer 面的那几个类型确实在：它们是接入方实现
        //    `PatchbayLogSource` / `PatchbayCommandRegistration.contextAware`
        //    时必须能命名的类型。删掉任何一个，默认入口就又不自足了。
        for (final symbol in const <String>[
          'PatchbayCancellationSignal',
          'PatchbayContextCommandHandler',
          'PatchbayInvocationContext',
          'PatchbayLogLevelWire',
          'PatchbayLogDirectionWire',
          'PatchbayLogRecordWire',
          'PatchbayCliSyntax',
        ]) {
          expect(
            consumer,
            contains(symbol),
            reason: '$symbol 出现在默认面导出符号的公共签名里，必须由默认面导出',
          );
        }
        //    `PatchbayFeature` 是 `PatchbayServiceHost` 三个 factory 的形参，
        //    因此被闭包拉进 host 面，但不该出现在默认 consumer 面。
        expect(host, contains('PatchbayFeature'));
        expect(consumer, isNot(contains('PatchbayFeature')));
      });

      // 生成的 wire 类型必须表态：codegen 不感知 barrel，所以新增一个 `*Wire`
      // 只会静静躺在 `core_wire.g.dart` 里。这条把它接回门禁。
      test('core_wire.g.dart 的每个公共 *Wire 都由 protocol 入口导出', () {
        final decoded =
            jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
                as Map<String, Object?>;
        final protocol = <String>{
          ...(((decoded['patchbay']!
                      as Map<String, Object?>)['lib/patchbay_protocol.dart']!
                  as List<Object?>)
              .map((v) => v.toString())),
        };
        final generated = tool.surfaceOf(
          root!,
          'packages/patchbay/lib/src/generated/core_wire.g.dart',
        );
        final wires = generated.where((n) => n.endsWith('Wire')).toSet();
        expect(wires, isNotEmpty, reason: '一个生成的 wire 类型都没找到，路径变了？');
        expect(
          wires.difference(protocol),
          isEmpty,
          reason:
              '生成的 wire 类型没有进 protocol 入口的 show 清单——codegen 新增类型'
              '必须显式表态，不能只躺在 src/ 里。',
        );
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

  group('internal 清单：封闭 show 之后 src 新增公共符号唯一会被发现的地方', () {
    late Directory fixture;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('patchbay-api-internal-');
    });

    tearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });

    void write(String relative, String body) {
      File('${fixture.path}/$relative')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    test('src 里没被任何入口导出的公共名进 internal，导出了的不进', () {
      write(
        'packages/patchbay/lib/patchbay.dart',
        "export 'src/a.dart' show Exported;\n",
      );
      write(
        'packages/patchbay/lib/src/a.dart',
        'class Exported {}\nclass NotExported {}\nclass _Private {}\n',
      );
      write('packages/patchbay/lib/src/deep/b.dart', 'class AlsoInternal {}\n');

      final internal = tool.computeInternal(fixture.path);

      expect(internal['patchbay'], <String>['AlsoInternal', 'NotExported']);
      expect(internal['patchbay_transport'], isEmpty);
    });

    test('同一个名字被另一个入口导出就不算 internal', () {
      write('packages/patchbay/lib/patchbay.dart', 'class Nothing {}\n');
      write(
        'packages/patchbay/lib/patchbay_host.dart',
        "export 'src/a.dart' show HostOnly;\n",
      );
      write('packages/patchbay/lib/src/a.dart', 'class HostOnly {}\n');

      expect(tool.computeInternal(fixture.path)['patchbay'], isEmpty);
    });
  });

  group('internal 清单的建账与表态（跑真正的 main）', () {
    late Directory fixture;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('patchbay-api-cli-');
      File('${fixture.path}/tool/check_api_surface.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          File('$root/tool/check_api_surface.dart').readAsStringSync(),
        );
      File('${fixture.path}/packages/patchbay/lib/patchbay.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync("export 'src/a.dart' show Exported;\n");
      File('${fixture.path}/packages/patchbay/lib/src/a.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('class Exported {}\nclass Hidden {}\n');
    });

    tearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });

    ProcessResult run(List<String> args) => Process.runSync(
      Platform.resolvedExecutable,
      <String>['tool/check_api_surface.dart', ...args],
      workingDirectory: fixture.path,
    );

    String golden() =>
        File('${fixture.path}/tool/api_surface.json').readAsStringSync();

    test('首次建账要显式 --bootstrap-internal，之后 --update 不再代人表态', () {
      // 没有 golden 时 `--update` 也不肯替作者登记 src 里的公共名。
      final ProcessResult refused = run(<String>['--update']);
      expect(refused.exitCode, 1);
      expect(refused.stderr.toString(), contains('Hidden'));
      expect(
        File('${fixture.path}/tool/api_surface.json').existsSync(),
        isFalse,
        reason: '被拒绝的 --update 不该落盘',
      );

      // 一次性建账。
      final ProcessResult bootstrapped = run(<String>[
        '--update',
        '--bootstrap-internal',
      ]);
      expect(bootstrapped.exitCode, 0);
      expect(golden(), contains('Hidden'));
      expect(run(<String>[]).exitCode, 0);

      // 之后再加一个 src 公共名：普通检查判红，`--update` 判红，
      // `--bootstrap-internal` 也不再放行（键已经存在）。
      File(
        '${fixture.path}/packages/patchbay/lib/src/a.dart',
      ).writeAsStringSync(
        'class Exported {}\nclass Hidden {}\nclass Sneaked {}\n',
      );
      final String before = golden();

      final ProcessResult plain = run(<String>[]);
      expect(plain.exitCode, 1);
      expect(plain.stderr.toString(), contains('Sneaked'));
      expect(
        plain.stderr.toString(),
        contains('加入 consumer/host/protocol 的 show 清单，或登记为 internal'),
      );

      expect(run(<String>['--update']).exitCode, 1);
      expect(run(<String>['--update', '--bootstrap-internal']).exitCode, 1);
      expect(golden(), before, reason: '被拒绝的 --update 不得改写 golden');

      // 显式表态之后才写得进去。
      expect(
        run(<String>['--update', '--accept-internal', 'Sneaked']).exitCode,
        0,
      );
      expect(golden(), contains('Sneaked'));
      expect(run(<String>[]).exitCode, 0);
    });

    test('把新符号加进入口的 show 清单同样解除判红，且不进 internal', () {
      expect(run(<String>['--update', '--bootstrap-internal']).exitCode, 0);
      File(
        '${fixture.path}/packages/patchbay/lib/src/a.dart',
      ).writeAsStringSync(
        'class Exported {}\nclass Hidden {}\nclass Promoted {}\n',
      );
      File(
        '${fixture.path}/packages/patchbay/lib/patchbay.dart',
      ).writeAsStringSync("export 'src/a.dart' show Exported, Promoted;\n");

      expect(run(<String>['--update']).exitCode, 0);
      final decoded = jsonDecode(golden()) as Map<String, Object?>;
      final patchbay = decoded['patchbay']! as Map<String, Object?>;
      expect(patchbay['lib/patchbay.dart'], contains('Promoted'));
      expect(patchbay['internal'], isNot(contains('Promoted')));
    });
  }, skip: root == null ? '不在仓库工作树内（发布归档）' : null);

  group('注释里的 export 不是 export（PB-060-02 / F4）', () {
    late Directory fixture;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('patchbay-api-comment-');
    });

    tearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });

    void write(String relative, String body) {
      File('${fixture.path}/$relative')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    test('文档注释里举例的整库 re-export 不判红，也不进公共面', () {
      // 五个 barrel 都带大段文档注释，注释里举例写 export 是现实写法。
      write('packages/patchbay/lib/patchbay.dart', 'class Consumer {}\n');
      write(
        'packages/patchbay/lib/patchbay_host.dart',
        "/// 反面教材：\n"
            "/// 不要写 export 'package:patchbay/patchbay.dart';\n"
            "/// 那会让对方的整张表进来。\n"
            "// export 'package:patchbay/patchbay.dart';\n"
            'library;\n'
            '\n'
            'class HostOnly {}\n',
      );

      expect(tool.opaquePackageReexports(fixture.path), isEmpty);
      expect(
        tool.computeSurface(
          fixture.path,
        )['patchbay']!['lib/patchbay_host.dart'],
        <String>['HostOnly'],
      );
    });

    test('真正的 export 行不受影响，注释掉的 part 也不算', () {
      write('packages/patchbay/lib/src/extra.dart', 'class FromPart {}\n');
      write(
        'packages/patchbay/lib/patchbay.dart',
        "/// export 'src/extra.dart';\n"
            "// part 'src/extra.dart';\n"
            'library;\n'
            '\n'
            "export 'src/extra.dart' show FromPart;\n"
            '\n'
            'class Consumer {}\n',
      );

      expect(
        tool.computeSurface(fixture.path)['patchbay']!['lib/patchbay.dart'],
        <String>['Consumer', 'FromPart'],
      );
    });

    test('stripLineComments 只剥整行注释，不动含 // 的字符串', () {
      const String source =
          "const String url = 'https://example.com/a';\n"
          "// export 'package:x/y.dart';\n"
          '  /// 缩进的文档注释也剥\n';

      final String stripped = tool.stripLineComments(source);

      expect(stripped, contains("'https://example.com/a'"));
      expect(stripped, isNot(contains('package:x/y.dart')));
      expect(stripped, isNot(contains('缩进的文档注释')));
    });
  });
}
