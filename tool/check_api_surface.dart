// 公共 API surface 门禁。
//
// 0.4.1 的教训：模块拆分把跨文件私有符号提升成了公共 API，而 barrel 文件一个字
// 都没改——只比对 barrel 文本会漏掉。真正的不变量是「从包入口能看见的符号集合」，
// 所以这里按 export / show / hide / part 展开算出该集合，与 golden 逐项比对。
//
// 特别注意 part：part 文件的顶层声明属于宿主库。把 part 改成独立 library 会强制
// 所有跨文件私有符号变公开——0.4.1 的泄漏正是这么来的，因此 part 展开不能省。
//
// PB-050-13 起 golden 按**公开 library** 记录，而不是每包一份扁平数组：
// `lib/` 下每个 `.dart` 都是一个可被 import 的公开入口，把它们折叠成一个集合会让
// 「哪个入口暴露了它」无法回答，也让同名符号跨 library 相互掩盖。因此这里递归枚举
// `packages/<pkg>/lib/**.dart`，只排除顶层 `lib/src/`（pub 的私有约定只覆盖那一个
// 目录），逐 library 比对；新增一个 library 文件本身就是新增公共面，默认判红。
//
// 封闭清单的包（见 `_closedSurfacePackages`）额外要求「每个 library 的集合都算得
// 出来」：无 `show` 的 `export 'package:…'` 当场判红，`--update` 也挡，否则那一行
// 就是一个 golden diff 恒为 0 的绕过口子。PB-060-02 起四个发布包全在封闭清单里。
//
// 封闭清单还有第二个洞：改成逐名 `show` 之后，`lib/src/` 里新增一个公共 class **谁也
// 看不见**——它不在任何入口的展开集合里，golden diff 为 0，门禁全绿。这比封闭前更弱：
// 封闭前那一行整库 re-export 至少会让新符号进 golden 判红。所以 golden 为每个包多记一份
// `internal` 清单：`lib/src/**` 里未被任何公共 library 导出的公共顶层名。新名字没登记就
// 判红，必须由作者表态——加进某个入口的 `show` 清单，或显式登记为 internal
// （`--update --accept-internal <name>`，`--update` 自己不会代作者登记）。
//
// 另外：注释里出现的 `export '…';`（比如 barrel 顶上的文档注释举例）不是 export。
// 展开前先剥掉整行 `//` / `///` 注释，否则文档注释会污染公共面计算。
//
//   dart run tool/check_api_surface.dart            比对 golden
//   dart run tool/check_api_surface.dart --update   重写 golden（需在 MR 中解释）
//   dart run tool/check_api_surface.dart --update --accept-internal <name>
//                                                   额外登记一个包内公共名（可重复）
//   dart run tool/check_api_surface.dart --update --bootstrap-internal
//                                                   仅当 golden 尚无 internal 键时建账一次
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
final RegExp _lineComment = RegExp(r'^[ \t]*//.*$', multiLine: true);
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

/// 去掉整行 `//` / `///` 注释后的源码。
///
/// 只剥**整行**注释：行尾注释里几乎不会出现 `export '…';`，而行内剥离会破坏包含 `//`
/// 的字符串字面量（`'https://…'`）。文档注释里举例写 export 才是现实脚坑——本仓的五个
/// barrel 都带大段文档注释。
String stripLineComments(String text) => text.replaceAll(_lineComment, '');

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
///
/// [opaqueReexports] 收集本工具**算不出集合**的 re-export：无 `show` 子句的
/// `export 'package:…'`。它们的符号集合由对方包决定，本工具不展开，因此对封闭
/// 清单 library 来说是一个 golden diff 恒为 0 的绕过口子——见
/// [opaquePackageReexports]。传 null 表示调用方不关心（例如只想要符号集合）。
Set<String> surfaceOf(
  String repoRoot,
  String entry, {
  Set<String>? seen,
  List<String>? opaqueReexports,
}) {
  seen ??= <String>{};
  if (!seen.add(entry)) return <String>{};
  final file = File('$repoRoot/$entry');
  if (!file.existsSync()) return <String>{};
  final raw = file.readAsStringSync();
  final out = <String>{..._ownPublics(raw)};
  // 注释里的 `export '…';` 不是 export；`_ownPublics` 自己按行跳注释，所以只有这里要剥。
  final text = stripLineComments(raw);
  // part 的顶层声明属于本库。
  for (final m in _part.allMatches(text)) {
    final p = File('$repoRoot/${_resolve(entry, m.group(1)!)}');
    if (p.existsSync()) out.addAll(_ownPublics(p.readAsStringSync()));
  }

  for (final m in _export.allMatches(text)) {
    final target = m.group(1)!;
    final clause = m.group(2)!;
    final show = _showClause.firstMatch(clause);
    final hide = _hideClause.firstMatch(clause);
    if (target.startsWith('dart:')) continue;
    if (target.startsWith('package:')) {
      // 精确 re-export（带 show）republish 的符号名就写在这一行上，不必解析对方
      // 包就能记进本包的公共面——`patchbay_client.dart` 的 PatchbaySnapshotRequest
      // 正是这种形态，漏记它 golden 就少一个符号。
      //
      // 整库 `export 'package:…'`（无 show）不展开：它的集合由对方包决定，展开
      // 会把对方的整张表算进本包，改变 patchbay_flutter 等既有 golden 的口径。
      // PB-050-13 只收口 CLI，不改另外三个包的公共面，所以这里保持 0.4.1 语义——
      // 但「不展开」等于「记不下来」，所以顺手登记，让封闭清单的包能当场判红。
      if (show != null) {
        out.addAll(_names(show.group(1)!));
      } else {
        opaqueReexports?.add("$entry: export '$target';");
      }
      continue;
    }
    var sub = surfaceOf(
      repoRoot,
      _resolve(entry, target),
      seen: seen,
      opaqueReexports: opaqueReexports,
    );
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

/// `packages/<pkg>/lib` 下的每个公开 library，按包相对路径排序。
///
/// 递归整个 `lib/`，只排除**顶层的** `lib/src/`：pub 与 lint 的私有约定只覆盖那
/// 一个目录，`lib/extra/x.dart` 或 `lib/a/src/b.dart` 外部照样能
/// `import 'package:<pkg>/extra/x.dart'`。早期只扫 `lib/` 一层的版本会让这些
/// 「看起来私有、其实公开」的路径整个从 golden 里消失。
List<String> librariesOf(String repoRoot, String pkg) {
  final root = Directory('$repoRoot/packages/$pkg/lib');
  if (!root.existsSync()) return const <String>[];
  final out = <String>[];
  void walk(Directory dir, String prefix) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is Directory) {
        // 只有 `lib/src/` 是私有约定；更深处叫 src 的目录不是。
        if (prefix.isEmpty && name == 'src') continue;
        walk(entity, '$prefix$name/');
      } else if (entity is File && name.endsWith('.dart')) {
        out.add('lib/$prefix$name');
      }
    }
  }

  walk(root, '');
  return out..sort();
}

/// 采用封闭清单口径的包。
///
/// 这些包的每个公开 library 都必须能被本工具**完整算出**，否则 golden 就不是那份
/// 清单的证据。因此它们不允许出现无 `show` 的跨包整库 re-export——那一行会让对方
/// 包的整张表进入本包公共面，而 golden diff 恒为 0。
///
/// PB-050-13 只把 `patchbay_cli` 纳进来，另外三个包留着 0.4.1 口径；PB-060-02 把
/// core 拆成 consumer / host / protocol 三个入口后，`patchbay_flutter.dart` 的整库
/// re-export 正是分层要消灭的那一行，所以四个包一起纳入：现在**每个**发布包的每个
/// 公开 library 都必须逐名 `show`，golden 才是那份清单的证据。
const Set<String> _closedSurfacePackages = <String>{..._packages};

/// 封闭清单包里所有算不出集合的跨包 re-export，人读格式，每行一条。
List<String> opaquePackageReexports(String repoRoot) {
  final violations = <String>[];
  for (final pkg in _packages) {
    if (!_closedSurfacePackages.contains(pkg)) continue;
    for (final library in librariesOf(repoRoot, pkg)) {
      final found = <String>[];
      surfaceOf(repoRoot, 'packages/$pkg/$library', opaqueReexports: found);
      for (final line in found) {
        violations.add('$pkg $library：$line');
      }
    }
  }
  return violations..sort();
}

/// golden 里保存 internal 清单的保留键；它不是 library 路径，所以不会和 `lib/…` 撞名。
const String internalKey = 'internal';

/// `packages/<pkg>/lib/src/**.dart`，按包相对路径排序。
List<String> internalFilesOf(String repoRoot, String pkg) {
  final root = Directory('$repoRoot/packages/$pkg/lib/src');
  if (!root.existsSync()) return const <String>[];
  final out = <String>[];
  void walk(Directory dir, String prefix) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is Directory) {
        walk(entity, '$prefix$name/');
      } else if (entity is File && name.endsWith('.dart')) {
        out.add('lib/src/$prefix$name');
      }
    }
  }

  walk(root, '');
  return out..sort();
}

/// `lib/src/**` 里**没有**被本包任何公开 library 导出的公共顶层名。
///
/// 封闭清单把「新增一个 src 公共符号」变成了零 diff：它不在任何入口的 `show` 里，
/// 展开集合看不见它。这份清单把它重新变成必须表态的事——要么进某个入口，要么登记在这里。
Map<String, List<String>> computeInternal(String repoRoot) {
  final surface = computeSurface(repoRoot);
  return <String, List<String>>{
    for (final pkg in _packages)
      pkg: () {
        final exported = <String>{
          for (final names in surface[pkg]!.values) ...names,
        };
        final declared = <String>{};
        for (final file in internalFilesOf(repoRoot, pkg)) {
          final f = File('$repoRoot/packages/$pkg/$file');
          if (f.existsSync()) {
            declared.addAll(_ownPublics(f.readAsStringSync()));
          }
        }
        return (declared.difference(exported).toList()..sort());
      }(),
  };
}

Map<String, Map<String, List<String>>> computeSurface(String repoRoot) =>
    <String, Map<String, List<String>>>{
      for (final pkg in _packages)
        pkg: <String, List<String>>{
          for (final library in librariesOf(repoRoot, pkg))
            library: (surfaceOf(repoRoot, 'packages/$pkg/$library').toList()
              ..sort()),
        },
    };

/// 读 golden，同时接受 0.4.1 的扁平数组形态。
///
/// 旧形态一律折算成「该包唯一的 `lib/<pkg>.dart`」，这样一个尚未迁移的 golden 会
/// 得到一条可读的 library 级 diff，而不是崩在类型转换上。
Map<String, Map<String, List<String>>> _readGolden(String text) {
  final decoded = jsonDecode(text) as Map<String, Object?>;
  return <String, Map<String, List<String>>>{
    for (final e in decoded.entries)
      e.key: switch (e.value) {
        final List<Object?> flat => <String, List<String>>{
          'lib/${e.key}.dart': <String>[for (final v in flat) v.toString()],
        },
        final Map<String, Object?> byLibrary => <String, List<String>>{
          for (final l in byLibrary.entries)
            l.key: <String>[
              for (final v in l.value! as List<Object?>) v.toString(),
            ],
        },
        _ => throw FormatException('$_goldenPath 里 ${e.key} 的形态无法识别'),
      },
  };
}

void main(List<String> args) {
  final repoRoot = Directory.current.path;
  final update = args.contains('--update');
  final accepted = <String>{
    for (var i = 0; i < args.length - 1; i++)
      if (args[i] == '--accept-internal') args[i + 1],
  };
  final bootstrapInternal = args.contains('--bootstrap-internal');

  // 先于一切：算不出集合的 re-export 会让后面的 diff 全部失去意义，而且必须**同样
  // 挡住 `--update`** —— 否则「加一行整库 re-export，跑一次 --update」正是这条规则
  // 要防的绕过：golden 无变化、门禁全绿、对方包的整张表已经进了本包公共面。
  final opaque = opaquePackageReexports(repoRoot);
  if (opaque.isNotEmpty) {
    stderr.writeln('封闭清单 library 出现算不出集合的跨包 re-export：');
    for (final line in opaque) {
      stderr.writeln('  - $line');
    }
    stderr.writeln(
      '\n无 show 子句的 `export \'package:…\'` 会把对方包的整张公共面带进本包，而本工具'
      '不展开它，\n因此 golden 记不下来、diff 恒为 0。改成精确 `show A, B;`，或把该符号'
      '在本包重新声明。',
    );
    exitCode = 1;
    return;
  }

  final current = computeSurface(repoRoot);
  final currentInternal = computeInternal(repoRoot);

  final goldenFile = File('$repoRoot/$_goldenPath');
  if (!goldenFile.existsSync() && !update) {
    stderr.writeln('缺少 $_goldenPath，先跑一次 --update 并在 MR 中说明。');
    exitCode = 1;
    return;
  }
  final golden = goldenFile.existsSync()
      ? _readGolden(goldenFile.readAsStringSync())
      : const <String, Map<String, List<String>>>{};

  if (update) {
    // internal 清单**不由 `--update` 代作者登记**：新出现的 src 公共名必须逐个用
    // `--accept-internal <name>` 点名，否则「加一个公共 class、跑一次 --update」又是
    // 一个零成本绕过口子。已消失的名字可以静默清理——那不是公共面变化。
    final unaccepted = <String>[];
    final merged = <String, Map<String, List<String>>>{};
    for (final pkg in _packages) {
      // 首次建账：golden 里**根本没有** internal 键时，允许一次性用
      // `--bootstrap-internal` 落一份基线——这不是「新增了一个符号」，而是把既有实现面
      // 记下来。它是显式的、可 grep 的一次性动作；键存在之后 `--update` 再也不会代
      // 作者登记任何新名字。
      final bootstrapping =
          bootstrapInternal &&
          !(golden[pkg]?.containsKey(internalKey) ?? false);
      final known = (golden[pkg]?[internalKey] ?? const <String>[]).toSet();
      final actual = currentInternal[pkg]!.toSet();
      if (!bootstrapping) {
        for (final name in (actual.difference(known).toList()..sort())) {
          if (!accepted.contains(name)) unaccepted.add('$pkg $name');
        }
      }
      merged[pkg] = <String, List<String>>{
        ...current[pkg]!,
        internalKey: (actual.toList()..sort()),
      };
    }
    if (unaccepted.isNotEmpty) {
      stderr.writeln('`lib/src/**` 出现未登记的公共顶层名，--update 不代你表态：');
      for (final line in unaccepted) {
        stderr.writeln('  - $line');
      }
      stderr.writeln(
        '\n把它加进 consumer / host / protocol 某个入口的 `show` 清单，'
        '或确认它只是包内实现后\n显式登记：'
        '`dart run tool/check_api_surface.dart --update '
        '--accept-internal <name>`（可重复）。',
      );
      exitCode = 1;
      return;
    }
    goldenFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(merged)}\n',
    );
    stdout.writeln('已重写 $_goldenPath');
    for (final e in merged.entries) {
      for (final l in e.value.entries) {
        stdout.writeln(
          '  ${e.key} ${l.key}: ${l.value.length} 个'
          '${l.key == internalKey ? '包内公共名' : '公开符号'}',
        );
      }
    }
    return;
  }

  final failures = <String>[];
  for (final pkg in _packages) {
    final expectedLibraries = <String, List<String>>{...?golden[pkg]}
      ..remove(internalKey);
    final actualLibraries = current[pkg]!;
    // 先比 library 集合：新增入口和删除入口都是公共面变化，且必须在符号 diff 之前
    // 报出来——否则一个新入口会被读成「凭空多了一堆符号」。
    for (final library
        in (actualLibraries.keys.toSet()..removeAll(expectedLibraries.keys))
            .toList()
          ..sort()) {
      failures.add(
        '$pkg：新增公开 library $library'
        '（${actualLibraries[library]!.length} 个符号）',
      );
    }
    for (final library
        in (expectedLibraries.keys.toSet()..removeAll(actualLibraries.keys))
            .toList()
          ..sort()) {
      failures.add('$pkg：移除公开 library $library');
    }
    for (final library in (actualLibraries.keys.toList()..sort())) {
      final expected = (expectedLibraries[library] ?? const <String>[]).toSet();
      if (!expectedLibraries.containsKey(library)) continue;
      final actual = actualLibraries[library]!.toSet();
      final added = (actual.difference(expected).toList()..sort());
      final removed = (expected.difference(actual).toList()..sort());
      if (added.isEmpty && removed.isEmpty) continue;
      failures.add(
        '$pkg $library：新增 ${added.length} 个 / 移除 ${removed.length} 个\n'
        '${added.isEmpty ? '' : '    新增: ${added.join(', ')}\n'}'
        '${removed.isEmpty ? '' : '    移除: ${removed.join(', ')}'}',
      );
    }

    // 再比 internal：封闭 `show` 之后，src 里新增的公共名对入口展开是不可见的，
    // 这份清单是它唯一会被发现的地方。
    final knownInternal = (golden[pkg]?[internalKey] ?? const <String>[])
        .toSet();
    final actualInternal = currentInternal[pkg]!.toSet();
    final newInternal = (actualInternal.difference(knownInternal).toList()
      ..sort());
    final goneInternal = (knownInternal.difference(actualInternal).toList()
      ..sort());
    if (newInternal.isNotEmpty) {
      failures.add(
        '$pkg：`lib/src/**` 新增 ${newInternal.length} 个未登记的公共顶层名\n'
        '    ${newInternal.join(', ')}\n'
        '    → 加入 consumer/host/protocol 的 show 清单，或登记为 internal',
      );
    }
    if (goneInternal.isNotEmpty) {
      failures.add(
        '$pkg：golden 的 internal 清单里有 ${goneInternal.length} 个已不存在的名字\n'
        '    ${goneInternal.join(', ')}\n'
        '    → 跑 --update 清理（删除包内实现不是公共面变化）',
      );
    }
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
    '（${current.entries.map((e) => '${e.key} '
        '${e.value.values.fold<int>(0, (n, s) => n + s.length)}'
        '${e.value.length == 1 ? '' : ' in ${e.value.length} libraries'}').join(' / ')}'
    '；internal '
    '${currentInternal.values.fold<int>(0, (n, s) => n + s.length)} 个）',
  );
}
