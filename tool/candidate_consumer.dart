// 为仓外 consumer 生成并验证四包同源的候选依赖覆盖。
import 'dart:io';

import 'repo_tasks.dart';

const String _usage = '''
用法：
  dart run tool/repo_tasks.dart candidate-consumer \\
    --repository <git-url> --commit <40位commit-sha> \\
    [--output <pubspec_overrides.yaml> | --verify-lock <pubspec.lock>]

--output 生成 pubspec_overrides.yaml；--verify-lock 只读验证 consumer 的 lock 是否让
四个发布包命中同一仓库、同一固定提交和正确的仓内路径。两种模式必须二选一。
''';

final class CandidateConsumerOptions {
  const CandidateConsumerOptions({
    required this.repository,
    required this.commit,
    required this.output,
    required this.verifyLock,
  });

  final String repository;
  final String commit;
  final String? output;
  final String? verifyLock;

  static CandidateConsumerOptions parse(List<String> arguments) {
    String? repository;
    String? commit;
    String? output;
    String? verifyLock;
    for (var index = 0; index < arguments.length; index += 1) {
      final String argument = arguments[index];
      String nextValue() {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument 缺参数\n$_usage');
        }
        return arguments[++index];
      }

      switch (argument) {
        case '--repository':
          repository = nextValue();
        case '--commit':
          commit = nextValue();
        case '--output':
          output = nextValue();
        case '--verify-lock':
          verifyLock = nextValue();
        default:
          throw FormatException('未知参数 $argument\n$_usage');
      }
    }
    if (repository == null || repository.trim().isEmpty || commit == null) {
      throw FormatException('缺 --repository 或 --commit\n$_usage');
    }
    if (repository.contains(RegExp(r'[\r\n\x00]'))) {
      throw const FormatException('--repository 不能包含换行或 NUL');
    }
    if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(commit)) {
      throw const FormatException(
        '--commit 必须是完整的 40 位 commit SHA，不能用移动分支或短 SHA',
      );
    }
    if ((output == null) == (verifyLock == null)) {
      throw const FormatException('--output 与 --verify-lock 必须二选一');
    }
    return CandidateConsumerOptions(
      repository: repository,
      commit: commit.toLowerCase(),
      output: output,
      verifyLock: verifyLock,
    );
  }
}

String renderCandidateOverrides(
  Iterable<RepoPackage> packages, {
  required String repository,
  required String commit,
}) {
  final List<RepoPackage> sorted = packages.toList(growable: false)
    ..sort(
      (RepoPackage left, RepoPackage right) => left.name.compareTo(right.name),
    );
  final StringBuffer out = StringBuffer()
    ..writeln('# Patchbay 候选验收专用；不要提交到 consumer 仓库。')
    ..writeln('# 四包必须保持同一仓库与同一完整 commit SHA。')
    ..writeln('dependency_overrides:');
  for (final RepoPackage package in sorted) {
    out
      ..writeln('  ${package.name}:')
      ..writeln('    git:')
      ..writeln('      url: ${_yamlScalar(repository)}')
      ..writeln('      ref: ${_yamlScalar(commit)}')
      ..writeln('      path: ${_yamlScalar(package.path)}');
  }
  return out.toString();
}

String _yamlScalar(String value) => "'${value.replaceAll("'", "''")}'";

final class _LockEntry {
  const _LockEntry({required this.source, required this.description});

  final String? source;
  final Map<String, String> description;
}

Map<String, _LockEntry> _readLockEntries(String lock) {
  final Map<String, _LockEntry> entries = <String, _LockEntry>{};
  String? name;
  String? source;
  var inDescription = false;
  var description = <String, String>{};

  void flush() {
    if (name != null) {
      entries[name!] = _LockEntry(
        source: source,
        description: Map<String, String>.unmodifiable(description),
      );
    }
    name = null;
    source = null;
    inDescription = false;
    description = <String, String>{};
  }

  for (final String line in lock.split('\n')) {
    final RegExpMatch? header = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):\s*$',
    ).firstMatch(line);
    if (header != null) {
      flush();
      name = header.group(1);
      continue;
    }
    if (name == null) continue;
    if (line == '    description:') {
      inDescription = true;
      continue;
    }
    final RegExpMatch? sourceField = RegExp(
      r'^    source:\s*(.+)$',
    ).firstMatch(line);
    if (sourceField != null) {
      source = _unquote(sourceField.group(1)!.trim());
      inDescription = false;
      continue;
    }
    if (inDescription) {
      final RegExpMatch? field = RegExp(
        r'^      (path|ref|resolved-ref|url):\s*(.+)$',
      ).firstMatch(line);
      if (field != null) {
        description[field.group(1)!] = _unquote(field.group(2)!.trim());
        continue;
      }
    }
    if (line.isNotEmpty && !line.startsWith(' ')) flush();
  }
  flush();
  return entries;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

List<String> verifyCandidateLock(
  String lock,
  Iterable<RepoPackage> packages, {
  required String repository,
  required String commit,
}) {
  final Map<String, _LockEntry> entries = _readLockEntries(lock);
  final List<String> problems = <String>[];
  for (final RepoPackage package in packages) {
    final _LockEntry? entry = entries[package.name];
    if (entry == null) {
      problems.add('${package.name} 未进入 lock；consumer 必须实际依赖四包链路');
      continue;
    }
    if (entry.source != 'git') {
      problems.add(
        '${package.name} source=${entry.source ?? '<missing>'}，应为 git',
      );
    }
    final Map<String, String> expected = <String, String>{
      'url': repository,
      'ref': commit,
      'resolved-ref': commit,
      'path': package.path,
    };
    for (final MapEntry<String, String> field in expected.entries) {
      final String? actual = entry.description[field.key];
      if (actual != field.value) {
        problems.add(
          '${package.name} ${field.key}=${actual ?? '<missing>'}，应为 ${field.value}',
        );
      }
    }
  }
  return problems;
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  try {
    final CandidateConsumerOptions options = CandidateConsumerOptions.parse(
      arguments,
    );
    final RepoWorkspace workspace = RepoWorkspace.discover(
      Directory.current.absolute.path,
    );
    if (options.verifyLock == null) {
      final String overrides = renderCandidateOverrides(
        workspace.members,
        repository: options.repository,
        commit: options.commit,
      );
      final File output = File(options.output!);
      if (!output.parent.existsSync()) {
        throw FormatException('输出目录不存在：${output.parent.path}');
      }
      output.writeAsStringSync(overrides);
      stdout.writeln('候选四包覆盖已写入 ${output.path}');
      return;
    }
    final File lock = File(options.verifyLock!);
    if (!lock.existsSync()) {
      throw FormatException('lock 文件不存在：${lock.path}');
    }
    final List<String> problems = verifyCandidateLock(
      lock.readAsStringSync(),
      workspace.members,
      repository: options.repository,
      commit: options.commit,
    );
    if (problems.isNotEmpty) {
      stderr.writeln('候选依赖验证失败：');
      stderr.writeAll(problems.map((problem) => '- $problem\n'));
      exitCode = 1;
      return;
    }
    stdout.writeln('候选四包已统一解析到 ${options.commit}');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  }
}
