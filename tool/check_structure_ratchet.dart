// PB-041-03：结构门禁。
//
// 分两类，权重不同：
//
// **硬规则（判红）** —— 与文件长短无关的结构性错误，靠人眼评审抓不住：
//   1. 跨包 src/ 私有导入；
//   2. 越出包根的相对导入（在 pub 发布归档里会悬空）；
//   3. 领域目录之间的循环依赖。
//
// 这里**不再禁止手写 `part`**。早期版本把 part 一律判红，本意是防止有人靠拆 part
// 碎片绕过体积门禁；体积改成警戒线之后这个动机已经不存在，而该规则真实造成过一次
// 公共 API 回归：为了消掉 part，capture/gesture 桥被改成独立 library，Dart 随即把
// 所有跨文件私有符号提升为公开。part 是 Dart 里唯一能跨文件共享私有符号的机制，
// 属于正当封装手段。真正要守的不变量由 `check_api_surface.dart` 负责。
//
// **警戒线（只告警，不阻断）** —— 体积指标。要不要拆得看内容，不能看数字，
// 所以这里只负责把可疑的地方摆出来，判断权在评审：
//   - 单文件超过 800 行（测试 1000 行）；
//   - 单函数超过 150 行 —— 比文件长度更有信号：文件长往往只是成员多且内聚，
//     而函数长基本一定是职责堆叠。实测本仓有 254 行的函数藏在 680 行的文件里，
//     只看文件长度会漏掉；反之 700 行的内聚 bridge 拆开纯属仪式。
//   - 基线内文件相比记录值变长。
import 'dart:convert';
import 'dart:io';

const String _baselinePath = 'tool/structure_baseline.json';

const List<String> _packages = <String>[
  'patchbay',
  'patchbay_cli',
  'patchbay_flutter',
  'patchbay_transport',
];

const List<String> _scanSubdirs = <String>['lib', 'test', 'tool', 'example'];

final class Baseline {
  const Baseline({
    required this.fileWarnProd,
    required this.fileWarnTest,
    required this.functionWarn,
    required this.legacy,
  });

  factory Baseline.load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('结构基线缺失：$path');
    }
    final data = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return Baseline(
      fileWarnProd: (data['file_warn_prod'] as num).toInt(),
      fileWarnTest: (data['file_warn_test'] as num).toInt(),
      functionWarn: (data['function_warn'] as num).toInt(),
      legacy: <String, int>{
        for (final e in (data['legacy'] as Map<String, Object?>).entries)
          e.key: (e.value as num).toInt(),
      },
    );
  }

  final int fileWarnProd;
  final int fileWarnTest;
  final int functionWarn;

  /// 已知的长文件与当时的行数，用于「相比基线变长」的告警。
  final Map<String, int> legacy;
}

final class Finding {
  const Finding(this.rule, this.message, {this.weight = 0});
  final String rule;
  final String message;
  final int weight;
}

String _rel(String path, String repoRoot) {
  var p = path.replaceAll('\\', '/');
  final root = repoRoot.replaceAll('\\', '/');
  if (p.startsWith(root)) p = p.substring(root.length);
  return p.startsWith('/') ? p.substring(1) : p;
}

bool _isTestFile(String rel) =>
    rel.startsWith('test/') || rel.contains('/test/');

List<String> _collectFiles(String repoRoot) {
  final out = <String>[];
  void walk(Directory dir) {
    if (!dir.existsSync()) return;
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.contains('/.dart_tool/') || e.path.contains('/build/')) {
        continue;
      }
      out.add(_rel(e.path, repoRoot));
    }
  }

  for (final pkg in _packages) {
    for (final sub in _scanSubdirs) {
      walk(Directory('$repoRoot/packages/$pkg/$sub'));
    }
  }
  walk(Directory('$repoRoot/tool'));
  walk(Directory('$repoRoot/test'));
  return out..sort();
}

// ---------------------------------------------------------------- 硬规则

void _checkStructure(String rel, List<String> lines, List<Finding> hard) {
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (!t.startsWith('import ') && !t.startsWith('export ')) continue;
    for (final other in _packages) {
      if (rel.startsWith('packages/$other/')) continue;
      if (t.contains("package:$other/src/")) {
        hard.add(
          Finding('cross-package', '$rel:${i + 1}: 禁止导入 $other/src/ 私有实现'),
        );
      }
    }
    if (t.contains('../../../')) {
      hard.add(Finding('escapes-package', '$rel:${i + 1}: 相对导入越出包根，发布归档里会悬空'));
    }
  }
}

String? _domainOf(String rel) {
  final m = RegExp(r'^packages/([^/]+)/lib/src/([^/]+)/').firstMatch(rel);
  return m == null ? null : '${m.group(1)}::${m.group(2)}';
}

void _checkDomainCycles(
  Map<String, List<String>> fileLines,
  List<Finding> hard,
) {
  final graph = <String, Set<String>>{};
  for (final entry in fileLines.entries) {
    final from = _domainOf(entry.key);
    if (from == null) continue;
    final pkg = from.split('::').first;
    for (final raw in entry.value) {
      final t = raw.trim();
      if (!t.startsWith('import ') && !t.startsWith('export ')) continue;
      String? target;
      final rel = RegExp(r"'\.\./([^/']+)/").firstMatch(t);
      if (rel != null) target = '$pkg::${rel.group(1)}';
      final abs = RegExp("package:$pkg/src/([^/']+)/").firstMatch(t);
      if (abs != null) target = '$pkg::${abs.group(1)}';
      if (target == null || target == from) continue;
      (graph[from] ??= <String>{}).add(target);
    }
  }

  final reported = <String>{};
  final state = <String, int>{};
  final stack = <String>[];
  void dfs(String node) {
    state[node] = 1;
    stack.add(node);
    for (final next in graph[node] ?? const <String>{}) {
      if (state[next] == 1) {
        final cycle = stack.sublist(stack.indexOf(next))..add(next);
        final key = (cycle.toList()..sort()).join('|');
        if (reported.add(key)) {
          hard.add(Finding('domain-cycle', '领域目录循环依赖：${cycle.join(" -> ")}'));
        }
      } else if (state[next] == null) {
        dfs(next);
      }
    }
    stack.removeLast();
    state[node] = 2;
  }

  for (final node in graph.keys.toList()..sort()) {
    if (state[node] == null) dfs(node);
  }
}

// ---------------------------------------------------------------- 警戒线

/// 去掉字符串字面量与行注释，避免其中的花括号干扰配对。
String _stripLiterals(String line) {
  var s = line.replaceAll(RegExp(r"'(\\.|[^'\\])*'"), "''");
  s = s.replaceAll(RegExp(r'"(\\.|[^"\\])*"'), '""');
  final comment = s.indexOf('//');
  return comment < 0 ? s : s.substring(0, comment);
}

final RegExp _signature = RegExp(
  r'^\s*(?:@\w+\s+)?(?:static\s+|external\s+|abstract\s+)*'
  r'[A-Za-z_][\w<>,?\[\]\. ]*\s+_?\w+\(',
);

/// 用花括号配对量出函数体行数。只用于告警，允许粗糙。
///
/// 只扫生产代码：测试文件的 `main()` 本质是用例容器，长度等同文件长度，
/// 既与文件警戒线重复，也不属于「职责堆叠」——按 docs/code-structure.md
/// 的「同构成员集合」条目，它不该因为长而被拆。
void _scanFunctions(
  String rel,
  List<String> lines,
  int threshold,
  List<Finding> warn,
) {
  var i = 0;
  while (i < lines.length) {
    if (!_signature.hasMatch(lines[i]) ||
        lines[i].trimLeft().startsWith('//')) {
      i++;
      continue;
    }
    var depth = 0;
    var opened = false;
    var j = i;
    while (j < lines.length && j - i < 1200) {
      final s = _stripLiterals(lines[j]);
      if (!opened && s.contains(';') && !s.contains('{')) break;
      depth += '{'.allMatches(s).length - '}'.allMatches(s).length;
      if (s.contains('{')) opened = true;
      if (opened && depth <= 0) {
        final length = j - i + 1;
        if (length > threshold) {
          warn.add(
            Finding(
              'long-function',
              '$rel:${i + 1}: ${lines[i].trim().replaceAll(RegExp(r'\s+'), ' ')}'
                  ' —— $length 行',
              weight: length,
            ),
          );
        }
        break;
      }
      j++;
    }
    i = j > i ? j : i + 1;
  }
}

void main(List<String> args) {
  final repoRoot = Directory.current.path;
  final quiet = args.contains('--quiet');
  final verbose = args.contains('--verbose');

  final Baseline baseline;
  try {
    baseline = Baseline.load('$repoRoot/$_baselinePath');
  } on Object catch (e) {
    stderr.writeln('结构门禁无法启动：$e');
    exitCode = 1;
    return;
  }

  final hard = <Finding>[];
  final warn = <Finding>[];
  final fileLines = <String, List<String>>{};
  var prodCount = 0;
  var testCount = 0;

  for (final rel in _collectFiles(repoRoot)) {
    final lines = File('$repoRoot/$rel').readAsLinesSync();
    fileLines[rel] = lines;
    if (rel.endsWith('.g.dart')) continue;

    _isTestFile(rel) ? testCount++ : prodCount++;
    _checkStructure(rel, lines, hard);
    if (!_isTestFile(rel)) {
      _scanFunctions(rel, lines, baseline.functionWarn, warn);
    }

    final limit = _isTestFile(rel)
        ? baseline.fileWarnTest
        : baseline.fileWarnProd;
    if (lines.length > limit) {
      warn.add(
        Finding(
          'long-file',
          '$rel: ${lines.length} 行 > 警戒线 $limit 行',
          weight: lines.length,
        ),
      );
    }

    final recorded = baseline.legacy[rel];
    if (recorded != null && lines.length > recorded) {
      warn.add(
        Finding(
          'grew',
          '$rel: ${lines.length} 行，比基线记录的 $recorded 行更长',
          weight: lines.length - recorded,
        ),
      );
    }
  }
  _checkDomainCycles(fileLines, hard);

  if (warn.isNotEmpty && !quiet) {
    final byRule = <String, List<Finding>>{};
    for (final w in warn) {
      (byRule[w.rule] ??= <Finding>[]).add(w);
    }
    stdout.writeln('警戒线提示（不阻断，拆不拆看内容）：');
    for (final rule in byRule.keys) {
      final items = byRule[rule]!..sort((a, b) => b.weight.compareTo(a.weight));
      stdout.writeln('  [$rule] ${items.length} 处');
      final shown = verbose ? items : items.take(10).toList();
      for (final item in shown) {
        stdout.writeln('    - ${item.message}');
      }
      if (items.length > shown.length) {
        stdout.writeln(
          '    … 另有 ${items.length - shown.length} 处，用 --verbose 查看',
        );
      }
    }
    stdout.writeln('');
  }

  if (hard.isNotEmpty) {
    final byRule = <String, List<Finding>>{};
    for (final v in hard) {
      (byRule[v.rule] ??= <Finding>[]).add(v);
    }
    stderr.writeln('结构硬规则 FAILED（${hard.length} 项）：');
    for (final rule in byRule.keys) {
      stderr.writeln('  [$rule]');
      for (final v in byRule[rule]!) {
        stderr.writeln('    - ${v.message}');
      }
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '结构硬规则通过（生产 $prodCount 个 / 测试 $testCount 个文件；'
    '${warn.length} 条警戒线提示）',
  );
}
