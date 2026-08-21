import 'dart:io';

import 'package:test/test.dart';

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

      test('golden 覆盖四个发布包且非空', () {
        final golden = File('$root/tool/api_surface.json').readAsStringSync();
        for (final pkg in const <String>[
          'patchbay',
          'patchbay_cli',
          'patchbay_flutter',
          'patchbay_transport',
        ]) {
          expect(
            golden,
            contains('"$pkg"'),
            reason: '$pkg 不在 golden 里，门禁对它形同虚设',
          );
        }
        // 空 golden 会让门禁恒过——这是最危险的失效形态。
        expect(
          RegExp(r'"[A-Za-z_]\w*"').allMatches(golden).length,
          greaterThan(400),
        );
      });
    },
    skip: root == null ? '不在仓库工作树内（发布归档），surface 门禁不适用' : null,
  );
}
