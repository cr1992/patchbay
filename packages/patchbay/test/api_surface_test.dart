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
        expect((cli['lib/patchbay_client.dart']! as List<Object?>).length, 8);
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
  });
}
