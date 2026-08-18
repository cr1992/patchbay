/// 命令名跨包一致护栏（从首个 consumer 仓的 Python guard 移植）。
///
/// `'ui.wait'`、`'ui.capture'`、`'navigation.catalog'` 这些字符串在
/// `patchbay_cli`（发起方）、`patchbay_flutter` + `patchbay`（服务方）、以及 CLI
/// 的跨进程测试 fixture host 里各写各的，彼此没有编译期绑定。CLI 的跨进程测试连的
/// 是 fixture，所以服务方改名后 CLI 测试仍然全绿——直到真机上撞出
/// `commandNotRegistered`。本文件把三处钉在一起。
///
/// 判据是**单向包含**：CLI 用的每个名字，服务方与 fixture 都必须真的有；服务方多出
/// CLI 未包装的命令不算漂移。抽取式失效时集合会变空、包含判断恒真，所以空集合必须
/// 显式判失败，不允许恒绿。
library;

import 'dart:io';

import 'package:test/test.dart';

/// 协议命令名形态：`<namespace>.<name>`，namespace 取自现有四个面。
/// 加新 namespace 时这里要一起加——否则新面的名字会静默逃出这道闸。
final RegExp _serviceCommand = RegExp(
  r"'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'",
);

/// 服务方声明命令名的写法：descriptor 的 `name:`、canonical UI descriptor
/// factories 的 `_ui('x', ...)` / `_textDescriptor('x', ...)`、路由前的
/// `command ==`、invoke switch 的 `'x' =>`。这些都算「这个名字在服务方真实存在」。
final List<RegExp> _hostDeclarations = <RegExp>[
  RegExp(r"name:\s*'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'"),
  RegExp(r"_ui\(\s*'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'"),
  RegExp(
    r"_textDescriptor\(\s*'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'",
  ),
  RegExp(r"_gesture\(\s*'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'"),
  RegExp(r"command\s*==\s*'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'"),
  RegExp(r"'((?:ui|navigation|logs|blob)\.[a-z][A-Za-z.]*)'\s*=>"),
];

Set<String> cliServiceCommands(Iterable<String> sources) => <String>{
  for (final String text in sources)
    for (final Match m in _serviceCommand.allMatches(text)) m.group(1)!,
};

Set<String> hostDeclaredCommands(Iterable<String> sources) => <String>{
  for (final String text in sources)
    for (final RegExp pattern in _hostDeclarations)
      for (final Match m in pattern.allMatches(text)) m.group(1)!,
};

List<String> checkCommandNameParity({
  required Iterable<String> cliSources,
  required Iterable<String> hostSources,
  required String fixtureSource,
}) {
  final Set<String> cli = cliServiceCommands(cliSources);
  final Set<String> host = hostDeclaredCommands(hostSources);
  final Set<String> fixture = cliServiceCommands(<String>[fixtureSource]);

  final List<String> problems = <String>[];
  // 抽取式失效比漂移更隐蔽：集合空了，下面两条包含判断会恒真而闸恒绿。
  if (cli.isEmpty) {
    problems.add('没有从 patchbay_cli 抽到任何命令名——抽取式已失效，这道闸当前形同虚设');
  }
  if (host.isEmpty) {
    problems.add('没有从服务方（patchbay_flutter/patchbay）抽到任何命令名——抽取式已失效');
  }
  if (problems.isNotEmpty) return problems;

  final List<String> notInHost = (cli.difference(host)).toList()..sort();
  if (notInHost.isNotEmpty) {
    problems.add(
      'CLI 发送的命令名在服务方不存在：$notInHost；'
      '任一侧改名都必须两侧同改，否则真机上是 commandNotRegistered',
    );
  }
  final List<String> notInFixture = (cli.difference(fixture)).toList()..sort();
  if (notInFixture.isNotEmpty) {
    problems.add(
      'CLI 跨进程测试的 fixture host 不支持：$notInFixture；'
      'fixture 落后于 CLI 时，跨进程用例测的是一个不存在的协议',
    );
  }
  return problems;
}

/// 真仓源码位置（dart test 的 cwd = packages/patchbay）。
/// 文件缺失直接抛异常判红——路径失效不是「没抽到」，同样不允许恒绿。
const String _cliLib = '../patchbay_cli/lib';
const List<String> _hostSourcePaths = <String>[
  '../patchbay_flutter/lib/src/flutter_service_host.dart',
  'lib/src/artifacts.dart',
  // PB-040-06 migrates protocol-owned descriptors here; the Flutter runtime
  // imports these exact objects instead of restating their command names.
  'lib/src/protocol_commands.dart',
  'lib/src/ui_protocol_commands.dart',
];
const String _fixtureHostPath = '../patchbay_cli/test/fixture/host.dart';

void main() {
  group('checkCommandNameParity 判据', () {
    const String host = "name: 'ui.wait'";
    const String fixture = "'ui.wait' =>";

    test('两侧对齐时通过', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>["invoke('ui.wait')"],
          hostSources: const <String>[host],
          fixtureSource: fixture,
        ),
        isEmpty,
      );
    });

    test('canonical UI descriptor factory 算服务方声明', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>[
            "invoke('ui.wait')",
            "invoke('ui.text.set')",
          ],
          hostSources: const <String>[
            "_ui('ui.wait', 'Wait')",
            "_textDescriptor('ui.text.set', 'Set')",
          ],
          fixtureSource: "'ui.wait' =>; 'ui.text.set' =>",
        ),
        isEmpty,
      );
    });

    test('服务方改名后判红', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>["invoke('ui.wait')"],
          hostSources: const <String>["name: 'ui.await'"],
          fixtureSource: fixture,
        ),
        contains(contains('服务方不存在')),
      );
    });

    test('fixture 落后于 CLI 时判红', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>["invoke('ui.wait')"],
          hostSources: const <String>[host],
          fixtureSource: "'ui.stale' =>",
        ),
        contains(contains('fixture host 不支持')),
      );
    });

    test('服务方多出 CLI 未包装的命令不算漂移', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>["invoke('ui.wait')"],
          hostSources: const <String>[host, "name: 'ui.capture'"],
          fixtureSource: fixture,
        ),
        isEmpty,
      );
    });

    test('抽取式失效（空集合）判红而不是恒绿', () {
      expect(
        checkCommandNameParity(
          cliSources: const <String>['没有任何命令名的源码'],
          hostSources: const <String>[host],
          fixtureSource: fixture,
        ),
        contains(contains('抽取式已失效')),
      );
      expect(
        checkCommandNameParity(
          cliSources: const <String>["invoke('ui.wait')"],
          hostSources: const <String>['同样没有命令名'],
          fixtureSource: fixture,
        ),
        contains(contains('抽取式已失效')),
      );
    });
  });

  test('真仓源码：CLI 命令名在服务方与 fixture 均存在', () {
    final List<String> cliSources = Directory(_cliLib)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .map((File f) => f.readAsStringSync())
        .toList(growable: false);
    final List<String> hostSources = _hostSourcePaths
        .map((String p) => File(p).readAsStringSync())
        .toList(growable: false);
    final String fixture = File(_fixtureHostPath).readAsStringSync();

    expect(
      checkCommandNameParity(
        cliSources: cliSources,
        hostSources: hostSources,
        fixtureSource: fixture,
      ),
      isEmpty,
      reason: '任一侧改命令名必须两侧同改；fixture 必须跟上 CLI',
    );
  });
}
