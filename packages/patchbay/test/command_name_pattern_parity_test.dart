/// 命令名正则双份护栏（配合 `command_name_parity_test.dart` 的命令名护栏）。
///
/// 「命令名长什么样」这条规则在仓里写了两遍：运行时的
/// `service_host.dart::_commandName` 用它拒绝非法目录，codegen 的
/// `tool/command_codegen.dart::_commandName` 用它在生成前拒绝非法契约。两份没有
/// 任何编译期绑定，收紧或放宽只改一处的后果是**两侧对同一个名字给出不同判决**：
/// codegen 放行的名字被运行时判成 `invalidCommandName`，整个 catalog 不可用；
/// 反过来则是接入方通过了生成、真机上才发现命令进不了目录。
///
/// 判据是**逐字相等**：两份是同一条规则的两次书写，不存在「一侧更严」的合理情形。
/// 抽取式失效时值会变成 null、相等判断无从谈起，所以抽不到必须显式判失败，不允许
/// 恒绿。
library;

import 'dart:io';

import 'package:test/test.dart';

/// 运行时那份：`static final RegExp _commandName = RegExp(r'…')`。
final RegExp _hostPattern = RegExp(r"_commandName\s*=\s*RegExp\(\s*r'([^']*)'");

/// codegen 那份：`String _commandName(...) { … RegExp(r'…').hasMatch(name) }`。
/// 锚在函数签名上，免得抓到同文件里别的正则。
final RegExp _codegenPattern = RegExp(
  r"String\s+_commandName\([^)]*\)\s*\{[\s\S]{0,400}?RegExp\(\s*r'([^']*)'",
);

String? commandNamePatternIn(String source, RegExp extractor) =>
    extractor.firstMatch(source)?.group(1);

List<String> checkCommandNamePatternParity({
  required String hostSource,
  required String codegenSource,
}) {
  final String? host = commandNamePatternIn(hostSource, _hostPattern);
  final String? codegen = commandNamePatternIn(codegenSource, _codegenPattern);

  final List<String> problems = <String>[];
  // 抽取式失效比漂移更隐蔽：值成了 null，下面的相等判断就没有意义了。
  if (host == null) {
    problems.add('没有从 service_host.dart 抽到 _commandName 正则——抽取式已失效，这道闸当前形同虚设');
  }
  if (codegen == null) {
    problems.add('没有从 tool/command_codegen.dart 抽到 _commandName 正则——抽取式已失效');
  }
  if (problems.isNotEmpty) return problems;

  if (host != codegen) {
    problems.add(
      '命令名正则两处不一致：运行时 `$host`，codegen `$codegen`；'
      '收紧或放宽必须两处同改，否则同一个名字在生成期与运行期判决相反',
    );
  }
  return problems;
}

/// 真仓源码位置（dart test 的 cwd = packages/patchbay）。
/// 文件缺失直接抛异常判红——路径失效不是「没抽到」，同样不允许恒绿。
const String _hostPath = 'lib/src/service_host.dart';
const String _codegenPath = 'tool/command_codegen.dart';

void main() {
  group('checkCommandNamePatternParity 判据', () {
    const String host =
        r"static final RegExp _commandName = RegExp(r'^[a-z]+$');";
    const String codegen =
        "String _commandName(Object? value, String path) {\n"
        "  final name = _nonEmpty(value, path);\n"
        r"  if (!RegExp(r'^[a-z]+$').hasMatch(name)) {"
        "\n    throw FormatException(path);\n  }\n  return name;\n}";

    test('两份逐字相同时通过', () {
      expect(
        checkCommandNamePatternParity(hostSource: host, codegenSource: codegen),
        isEmpty,
      );
    });

    test('只改运行时那份判红', () {
      expect(
        checkCommandNamePatternParity(
          hostSource:
              r"static final RegExp _commandName = RegExp(r'^[a-z][a-z0-9]*$');",
          codegenSource: codegen,
        ),
        contains(contains('两处不一致')),
      );
    });

    test('只改 codegen 那份判红', () {
      expect(
        checkCommandNamePatternParity(
          hostSource: host,
          codegenSource: codegen.replaceAll(r'^[a-z]+$', r'^[A-Za-z]+$'),
        ),
        contains(contains('两处不一致')),
      );
    });

    test('抽取式失效判红而不是恒绿', () {
      expect(
        checkCommandNamePatternParity(
          hostSource: '这里没有任何正则',
          codegenSource: codegen,
        ),
        contains(contains('抽取式已失效')),
      );
      expect(
        checkCommandNamePatternParity(
          hostSource: host,
          codegenSource: '这里同样没有',
        ),
        contains(contains('抽取式已失效')),
      );
    });

    test('codegen 抽取锚在 _commandName 上，不会抓到同文件里别的正则', () {
      // `_identifier` 与 `_typePrefix` 就在同一个文件里紧挨着；抓错一个的话，
      // 这道闸比较的就不是命令名规则了。
      const String noisy =
          "String _identifier(Object? value, String path) {\n"
          r"  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(text)) {"
          "\n  }\n}\n"
          "String _commandName(Object? value, String path) {\n"
          r"  if (!RegExp(r'^[a-z]+$').hasMatch(name)) {"
          "\n  }\n}";
      expect(commandNamePatternIn(noisy, _codegenPattern), r'^[a-z]+$');
    });
  });

  test('真仓源码：运行时与 codegen 的命令名正则逐字一致', () {
    final List<String> problems = checkCommandNamePatternParity(
      hostSource: File(_hostPath).readAsStringSync(),
      codegenSource: File(_codegenPath).readAsStringSync(),
    );

    expect(problems, isEmpty, reason: '命令名语法是协议契约；两处写法必须同改，否则生成期与运行期判决相反');
  });
}
