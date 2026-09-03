// PB-060-02 / DG-060-02 修订②：公共入口自足门禁的回归。
//
// `check_api_surface` 回答「导出了哪些名字」；这一条回答「只 import 这一个入口，
// 导出的东西真的能用吗」。第一版分层在这上面栽过：`PatchbayLogSource` 在默认面，
// 它 `query` 方法形参里的 `PatchbayCancellationSignal` 不在，接入方照着迁移表改完
// 会拿到 `undefined_class`。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String? _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    if (File('${dir.path}/tool/check_api_closure.dart').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return null;
}

void main() {
  final String? root = _repoRoot();

  group(
    '公共入口自足（tool/check_api_closure.dart）',
    () {
      late ProcessResult json;

      setUpAll(() {
        json = Process.runSync(Platform.resolvedExecutable, <String>[
          'run',
          'tool/check_api_closure.dart',
          '--json',
        ], workingDirectory: root);
      });

      test('五个入口的违规集合都为空', () {
        final ProcessResult result = Process.runSync(
          Platform.resolvedExecutable,
          <String>['run', 'tool/check_api_closure.dart'],
          workingDirectory: root,
        );
        expect(
          result.exitCode,
          0,
          reason:
              '公共入口不自足：\n${result.stderr}\n'
              '被引用的类型要么进同一个入口的 show 清单，要么就不该出现在公共签名里。',
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('闭包结果覆盖五个入口，且逐个违规为空', () {
        expect(json.exitCode, 0, reason: json.stderr.toString());
        final decoded =
            jsonDecode(json.stdout.toString()) as Map<String, Object?>;
        expect(decoded.keys.toSet(), <String>{
          'patchbay/lib/patchbay.dart',
          'patchbay/lib/patchbay_host.dart',
          'patchbay/lib/patchbay_protocol.dart',
          'patchbay_flutter/lib/patchbay_flutter.dart',
          'patchbay_flutter/lib/patchbay_flutter_host.dart',
        });
        for (final MapEntry<String, Object?> entry in decoded.entries) {
          final value = entry.value! as Map<String, Object?>;
          expect(
            value['violations'],
            isEmpty,
            reason: '${entry.key} 的公共签名引用了本入口没导出的类型',
          );
          expect(
            value['exported'] as List<Object?>,
            isNotEmpty,
            reason: '${entry.key} 一个符号都没导出，工具八成没解析成功',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('闭包结果与 golden 记录的导出集合逐名一致', () {
        // 两条独立的口径：`check_api_surface` 用正则展开 export/show，
        // `check_api_closure` 用 analyzer 的 element model。两者对同一个入口给出
        // 不同答案，就说明正则那条路解析错了（或者 golden 过期了）。
        final decoded =
            jsonDecode(json.stdout.toString()) as Map<String, Object?>;
        final golden =
            jsonDecode(File('$root/tool/api_surface.json').readAsStringSync())
                as Map<String, Object?>;
        for (final MapEntry<String, Object?> entry in decoded.entries) {
          final List<String> parts = entry.key.split('/');
          final String package = parts.first;
          final String library = parts.sublist(1).join('/');
          final Set<String> fromAnalyzer = <String>{
            ...((entry.value! as Map<String, Object?>)['exported']!
                    as List<Object?>)
                .map((v) => v.toString()),
          };
          final Set<String> fromGolden = <String>{
            ...(((golden[package]! as Map<String, Object?>)[library]!
                    as List<Object?>)
                .map((v) => v.toString())),
          };
          expect(
            fromAnalyzer,
            fromGolden,
            reason: '$package $library：analyzer 与 golden 对导出集合不一致',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    skip: root == null ? '不在仓库工作树内（发布归档），自足门禁不适用' : null,
  );
}
