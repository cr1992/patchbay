// PB-041-03：结构棘轮门禁。
//
// 与计划口径一致的四条硬规则：
//   1. 硬上限：生产文件 800 行、测试文件 1000 行。
//   2. 严格预算：不在基线内的文件（即新建/完成拆分的文件）生产 600 行、测试 700 行。
//   3. 棘轮：基线内的历史超限文件只准变小，不准增长。
//   4. 结构：禁止手写 part 碎片、禁止跨包 src/ 私有导入、禁止领域目录间的循环依赖。
//
// 基线只收录 main 上就已超限的历史文件。新文件不会被自动收编——要么拆到预算内，
// 要么显式写进 accepted_debt 并给出理由，让欠账可见、可计数、可回收。
import 'dart:convert';
import 'dart:io';

const String _baselinePath = 'tool/structure_baseline.json';

const List<String> _packages = <String>[
  'patchbay',
  'patchbay_cli',
  'patchbay_flutter',
  'patchbay_transport',
];

/// 参与体积与结构检查的目录。相比旧版新增 tool/ 与 example/，
/// 避免「刚拆完的工具代码落在门禁盲区里又涨回去」。
const List<String> _scanSubdirs = <String>['lib', 'test', 'tool', 'example'];

final class Baseline {
  const Baseline({
    required this.strictProd,
    required this.strictTest,
    required this.hardProd,
    required this.hardTest,
    required this.legacy,
    required this.acceptedDebt,
  });

  factory Baseline.load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('结构基线缺失：$path（不可跳过，跳过等于门禁失效）');
    }
    final data = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return Baseline(
      strictProd: (data['strict_prod_budget'] as num).toInt(),
      strictTest: (data['strict_test_budget'] as num).toInt(),
      hardProd: (data['hard_prod_budget'] as num).toInt(),
      hardTest: (data['hard_test_budget'] as num).toInt(),
      legacy: <String, int>{
        for (final e in (data['legacy'] as Map<String, Object?>).entries)
          e.key: (e.value as num).toInt(),
      },
      acceptedDebt: <String, DebtEntry>{
        for (final e
            in (data['accepted_debt'] as Map<String, Object?>? ?? const {})
                .entries)
          e.key: DebtEntry.fromJson(e.value as Map<String, Object?>),
      },
    );
  }

  final int strictProd;
  final int strictTest;
  final int hardProd;
  final int hardTest;
  final Map<String, int> legacy;
  final Map<String, DebtEntry> acceptedDebt;
}

/// 一条已接受的结构欠账：冻结在当时的行数，并写明由谁偿还。
/// 欠账不等于豁免——依然受硬上限约束，且只准变小。
final class DebtEntry {
  const DebtEntry({
    required this.lines,
    required this.reason,
    required this.owedBy,
  });

  factory DebtEntry.fromJson(Map<String, Object?> json) => DebtEntry(
    lines: (json['lines'] as num).toInt(),
    reason: (json['reason'] ?? '').toString(),
    owedBy: (json['owed_by'] ?? '未指派').toString(),
  );

  final int lines;
  final String reason;
  final String owedBy;
}

final class Violation {
  const Violation(this.rule, this.message);
  final String rule;
  final String message;
}

/// 归一化成仓库相对路径，保证与基线 key 可比。
String _rel(String path, String repoRoot) {
  var p = path.replaceAll('\\', '/');
  final root = repoRoot.replaceAll('\\', '/');
  if (p.startsWith(root)) p = p.substring(root.length);
  return p.startsWith('/') ? p.substring(1) : p;
}

bool _isTestFile(String rel) => rel.contains('/test/');

/// 收集所有待检查的 dart 文件。
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
  return out..sort();
}

/// 体积三规则：硬上限、严格预算、棘轮。
void _checkSize(
  String rel,
  int lines,
  Baseline baseline,
  List<Violation> violations,
) {
  final isTest = _isTestFile(rel);
  final hard = isTest ? baseline.hardTest : baseline.hardProd;
  final strict = isTest ? baseline.strictTest : baseline.strictProd;

  // 硬上限对谁都成立，欠账也不例外。
  if (lines > hard) {
    violations.add(Violation('hard-budget', '$rel: $lines 行 > 硬上限 $hard 行'));
    return;
  }

  final debt = baseline.acceptedDebt[rel];
  if (debt != null) {
    if (lines > debt.lines) {
      violations.add(
        Violation(
          'debt-growth',
          '$rel: $lines 行 > 欠账冻结的 ${debt.lines} 行'
              '（${debt.owedBy} 的欠账只准还，不准加）',
        ),
      );
    }
    return;
  }

  final recorded = baseline.legacy[rel];
  if (recorded == null) {
    if (lines > strict) {
      violations.add(
        Violation(
          'strict-budget',
          '$rel: $lines 行 > 新建/拆分文件预算 $strict 行'
              '（拆到预算内，或写进 accepted_debt 并说明理由）',
        ),
      );
    }
    return;
  }

  if (lines > recorded) {
    violations.add(
      Violation('ratchet', '$rel: $lines 行 > 基线锁定的 $recorded 行——历史超限文件只准变小'),
    );
  }
}

/// 结构两规则：手写 part 碎片、跨包 src/ 私有导入。
void _checkDirectives(
  String rel,
  List<String> lines,
  List<Violation> violations,
) {
  final isGenerated = rel.endsWith('.g.dart');
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (!isGenerated && !_isTestFile(rel)) {
      if (t.startsWith('part ') && !t.contains('.g.dart')) {
        violations.add(Violation('part', '$rel:${i + 1}: 禁止手写 `part` 碎片'));
      }
      if (t.startsWith('part of ')) {
        violations.add(Violation('part', '$rel:${i + 1}: 禁止手写 `part of`'));
      }
    }
    if (!t.startsWith('import ') && !t.startsWith('export ')) continue;
    // 跨包私有导入在 lib/test/tool 全域检查——旧版只查 lib/，
    // 恰好漏掉了测试里 `../../../tool/` 这类越出包根的引用。
    for (final other in _packages) {
      if (rel.startsWith('packages/$other/')) continue;
      if (t.contains("package:$other/src/")) {
        violations.add(
          Violation('cross-package', '$rel:${i + 1}: 禁止导入 $other/src/ 私有实现'),
        );
      }
    }
    if (t.contains('../../../')) {
      violations.add(
        Violation('escapes-package', '$rel:${i + 1}: 相对导入越出包根，发布归档里会悬空'),
      );
    }
  }
}

/// 领域目录（`lib/src/<domain>/`）之间的循环依赖。
/// 文件级环在 Dart 里合法且常见，这里只判架构意义上的目录环。
String? _domainOf(String rel) {
  final m = RegExp(r'^packages/([^/]+)/lib/src/([^/]+)/').firstMatch(rel);
  if (m == null) return null;
  return '${m.group(1)}::${m.group(2)}';
}

void _checkDomainCycles(
  Map<String, List<String>> fileLines,
  List<Violation> violations,
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
          violations.add(
            Violation('domain-cycle', '领域目录循环依赖：${cycle.join(" -> ")}'),
          );
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

void main(List<String> args) {
  final verbose = args.contains('--verbose');
  final repoRoot = Directory.current.path;

  final Baseline baseline;
  try {
    baseline = Baseline.load('$repoRoot/$_baselinePath');
  } on Object catch (e) {
    stderr.writeln('结构棘轮无法启动：$e');
    exitCode = 1;
    return;
  }

  final violations = <Violation>[];
  final fileLines = <String, List<String>>{};
  var prodCount = 0;
  var testCount = 0;

  for (final rel in _collectFiles(repoRoot)) {
    final lines = File('$repoRoot/$rel').readAsLinesSync();
    fileLines[rel] = lines;
    if (rel.endsWith('.g.dart')) continue;

    if (_isTestFile(rel)) {
      testCount++;
    } else {
      prodCount++;
    }
    _checkSize(rel, lines.length, baseline, violations);
    _checkDirectives(rel, lines, violations);
  }
  _checkDomainCycles(fileLines, violations);

  for (final entry in baseline.legacy.entries) {
    if (!File('$repoRoot/${entry.key}').existsSync() && verbose) {
      stdout.writeln('  [基线] ${entry.key} 已消失，可从基线移除');
    }
  }

  if (baseline.acceptedDebt.isNotEmpty) {
    stdout.writeln(
      '⚠ 已接受但尚未偿还的结构欠账 ${baseline.acceptedDebt.length} 项'
      '（已冻结行数，只准还不准加）：',
    );
    for (final e in baseline.acceptedDebt.entries) {
      stdout.writeln(
        '  - ${e.key} @ ${e.value.lines} 行'
        '［${e.value.owedBy}］${e.value.reason}',
      );
    }
  }

  if (violations.isNotEmpty) {
    final byRule = <String, List<Violation>>{};
    for (final v in violations) {
      (byRule[v.rule] ??= <Violation>[]).add(v);
    }
    stderr.writeln('结构棘轮 FAILED（${violations.length} 项）：');
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
    '结构棘轮通过（生产 $prodCount 个 / 测试 $testCount 个；'
    '基线锁定 ${baseline.legacy.length} 个历史超限文件）',
  );
}
