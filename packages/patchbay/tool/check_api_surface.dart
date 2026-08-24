// 公共 API surface 门禁。
//
// 0.4.1 的教训：模块拆分把跨文件私有符号提升成了公共 API，而 barrel 文件一个字
// 都没改——只比对 barrel 文本会漏掉。真正的不变量是「从包入口能看见的符号集合」，
// 所以这里按 export / show / hide / part 展开算出该集合，与 golden 逐项比对。
//
// 特别注意 part：part 文件的顶层声明属于宿主库。把 part 改成独立 library 会强制
// 所有跨文件私有符号变公开——0.4.1 的泄漏正是这么来的，因此 part 展开不能省。
//
//   dart run tool/check_api_surface.dart            比对 golden
//   dart run tool/check_api_surface.dart --update   重写 golden（需在 MR 中解释）
import 'dart:convert';
import 'dart:io';

const String _goldenPath = 'tool/api_surface.json';

const List<String> _packages = <String>[
  'patchbay',
  'patchbay_cli',
  'patchbay_flutter',
  'patchbay_transport',
];

final RegExp _decl = RegExp(
  r'^(?:@\w+\s*)?(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+|'
  r'mixin\s+|external\s+|const\s+)*(?:class|enum|extension|mixin|typedef)\s+'
  r'([A-Za-z_]\w*)',
);
final RegExp _func = RegExp(
  r'^[A-Za-z_][\w<>,?\[\]\. ]*\s+([A-Za-z_]\w*)\s*\(',
);
final RegExp _var = RegExp(
  r'^(?:const|final)\s+(?:[A-Za-z_][\w<>,?\[\]\. ]*\s+)?([A-Za-z_]\w*)\s*=',
);
final RegExp _export = RegExp(r"export\s+'([^']+)'([^;]*);", dotAll: true);
final RegExp _part = RegExp(r"^part\s+'([^']+)'\s*;", multiLine: true);
final RegExp _showClause = RegExp(r'show\s+([\w\s,]+)');
final RegExp _hideClause = RegExp(r'hide\s+([\w\s,]+)');

const Set<String> _keywords = <String>{
  'return',
  'if',
  'for',
  'while',
  'switch',
  'import',
  'export',
  'part',
  'else',
  'assert',
  'yield',
  'await',
  'throw',
  'new',
};

/// 规范化相对路径，等价于 posix 的 normpath。
String _resolve(String from, String target) {
  final segments = <String>[
    ...from.split('/')..removeLast(),
    ...target.split('/'),
  ];
  final out = <String>[];
  for (final s in segments) {
    if (s == '.' || s.isEmpty) continue;
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(s);
  }
  return out.join('/');
}

/// 一个文件自身声明的顶层公开符号。
Set<String> _ownPublics(String text) {
  final out = <String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty || line.startsWith(' ') || line.startsWith('//')) continue;
    for (final rx in <RegExp>[_decl, _func, _var]) {
      final m = rx.matchAsPrefix(line);
      if (m == null) continue;
      final name = m.group(1)!;
      if (!name.startsWith('_') && !_keywords.contains(name)) out.add(name);
      break;
    }
  }
  return out;
}

Set<String> _names(String clause) =>
    clause.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

/// 从 [entry] 出发展开 export / part，算出可见的公开符号集合。
Set<String> surfaceOf(String repoRoot, String entry, [Set<String>? seen]) {
  seen ??= <String>{};
  if (!seen.add(entry)) return <String>{};
  final file = File('$repoRoot/$entry');
  if (!file.existsSync()) return <String>{};
  final text = file.readAsStringSync();

  final out = <String>{..._ownPublics(text)};
  // part 的顶层声明属于本库。
  for (final m in _part.allMatches(text)) {
    final p = File('$repoRoot/${_resolve(entry, m.group(1)!)}');
    if (p.existsSync()) out.addAll(_ownPublics(p.readAsStringSync()));
  }

  for (final m in _export.allMatches(text)) {
    final target = m.group(1)!;
    final clause = m.group(2)!;
    if (target.startsWith('package:') || target.startsWith('dart:')) continue;
    var sub = surfaceOf(repoRoot, _resolve(entry, target), seen);
    final show = _showClause.firstMatch(clause);
    final hide = _hideClause.firstMatch(clause);
    if (show != null) {
      final keep = _names(show.group(1)!);
      sub = sub.where(keep.contains).toSet();
    }
    if (hide != null) {
      final drop = _names(hide.group(1)!);
      sub = sub.where((n) => !drop.contains(n)).toSet();
    }
    out.addAll(sub);
  }
  return out;
}

Map<String, List<String>> computeSurface(String repoRoot) =>
    <String, List<String>>{
      for (final pkg in _packages)
        pkg: (surfaceOf(repoRoot, 'packages/$pkg/lib/$pkg.dart').toList()
          ..sort()),
    };

void main(List<String> args) {
  final repoRoot = Directory.current.path;
  final update = args.contains('--update');
  final current = computeSurface(repoRoot);

  final goldenFile = File('$repoRoot/$_goldenPath');
  if (update) {
    goldenFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(current)}\n',
    );
    stdout.writeln('已重写 $_goldenPath');
    for (final e in current.entries) {
      stdout.writeln('  ${e.key}: ${e.value.length} 个公开符号');
    }
    return;
  }

  if (!goldenFile.existsSync()) {
    stderr.writeln('缺少 $_goldenPath，先跑一次 --update 并在 MR 中说明。');
    exitCode = 1;
    return;
  }

  final golden = <String, List<String>>{
    for (final e
        in (jsonDecode(goldenFile.readAsStringSync()) as Map<String, Object?>)
            .entries)
      e.key: <String>[for (final v in e.value! as List<Object?>) v.toString()],
  };

  final failures = <String>[];
  for (final pkg in _packages) {
    final expected = (golden[pkg] ?? const <String>[]).toSet();
    final actual = current[pkg]!.toSet();
    final added = (actual.difference(expected).toList()..sort());
    final removed = (expected.difference(actual).toList()..sort());
    if (added.isEmpty && removed.isEmpty) continue;
    failures.add(
      '$pkg：新增 ${added.length} 个 / 移除 ${removed.length} 个\n'
      '${added.isEmpty ? '' : '    新增: ${added.join(', ')}\n'}'
      '${removed.isEmpty ? '' : '    移除: ${removed.join(', ')}'}',
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('公共 API surface 与 golden 不一致：');
    for (final f in failures) {
      stderr.writeln('  - $f');
    }
    stderr.writeln(
      '\n新增往往来自把 part 改成独立 library、或 wrapper 整库 export 了拆分产物；\n'
      '移除对已发布包是破坏性变更。确属有意变更时跑 --update 并在 MR 中说明理由。',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '公共 API surface 与 golden 一致'
    '（${current.entries.map((e) => '${e.key} ${e.value.length}').join(' / ')}）',
  );
}
