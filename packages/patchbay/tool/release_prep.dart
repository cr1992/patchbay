// 定版机检与落盘：把「四包 version / CHANGELOG 落款 / example lock / 兼容矩阵」四件套，
// 加上 pub 发布链的静态门与 `--dry-run`，从人工核对变成可反复跑的判定。
//
// 两个模式：
//
// - `--check` 只读幂等，可反复跑，红绿即结论；
// - `--apply` 只改文件，**不打 tag、不推送、不发布**——这三件永远是人的动作。
//   apply 结束后自动重跑一遍判定，并把该由人跑的命令与 tag 后才能回填的项打印成待办清单。
//
// 硬检查的来历：0.2.0 定版漏刷 `example/pubspec.lock`，0.2.1 定版打完 tag 忘了回填兼容矩阵行。
// 这两项在此不降级成提示——缺了直接红。pub 侧的硬检查来历是实测：`dart pub publish --dry-run`
// **只要有一条 warning 就退 65**（缺 LICENSE 是 error，缺 README / CHANGELOG / repository、
// description 不在 60–180 字符都是 warning），所以这些项在此一律按「挡发布」对待。

import 'dart:io';

// ===== 仓内坐标 =====

/// tag 命名前缀，见 CONTRIBUTING.md「发版」。
const String tagPrefix = 'patchbay-v';

/// 兼容矩阵里「tag 之后才能填」的占位符。check 在 tag 已存在时会盯着它转红。
const String pendingSha = '待回填';

/// 兼容矩阵 consumer 列的占位符：patchbay 仓不持有 consumer 侧 pin，必须人工核实。
const String pendingConsumers = '待确认';

/// 四个随 tag 同步定版的包。example 不在其列——它不发布，只跟着刷 lock 与 overrides。
const List<String> releasePackages = <String>[
  'patchbay',
  'patchbay_cli',
  'patchbay_flutter',
  'patchbay_transport',
];

/// pub 发布的 error 级要求：缺了直接「can't be published」。
const List<String> requiredPackageFiles = <String>['LICENSE'];

/// pub 发布的 warning 级要求。实测 `--dry-run` 有 warning 即退 65，故与 error 同等对待。
const List<String> advisedPackageFiles = <String>['README.md', 'CHANGELOG.md'];

/// pub 对 `description` 的长度区间（字符数），越界即 warning。
const int descriptionMinLength = 60;
const int descriptionMaxLength = 180;

String pubspecPathOf(String package) => 'packages/$package/pubspec.yaml';

String overridesPathOf(String package) =>
    'packages/$package/pubspec_overrides.yaml';

String packageChangelogPathOf(String package) =>
    'packages/$package/CHANGELOG.md';

/// 公开镜像上「按仓根相对路径取文件」的前缀。
///
/// 分支钉 `main` 而不是 tag：与 README 语言切换行同口径（见 !38），也和 dio 等主流包一致。
const String repoBlobPrefix = 'https://github.com/cr1992/patchbay/blob/main/';

const String changelogPath = 'CHANGELOG.md';
const String examplePath = 'packages/patchbay_flutter/example';
const String examplePubspecPath = '$examplePath/pubspec.yaml';
const String exampleOverridesPath = '$examplePath/pubspec_overrides.yaml';
const String exampleLockPath = '$examplePath/pubspec.lock';
const String compatMatrixPath = 'docs/compat-matrix.md';
const String serviceHostPath = 'packages/patchbay/lib/src/service_host.dart';
const String invocationPath = 'packages/patchbay/lib/src/invocation.dart';
const String workflowPath = '.github/workflows/ci.yml';

/// 正式发布必须打到 pub.dev。本机常把 `PUB_HOSTED_URL` 指向镜像，那会把 `pub publish`
/// 也一起指过去，所以打印出来的发布命令显式带上 host。
const String canonicalPubHost = 'https://pub.dev';

// ===== 判定模型 =====

enum ReleaseCheckStatus { ok, failed, skipped }

/// 一条判定结果。
///
/// [hard] 标记「历史真漏过」或「pub 会直接挡住发布」的项，不允许降级成提示；[detail] 直接
/// 面向人，红的时候要说清「差什么」和「谁来补」。
final class ReleaseCheck {
  const ReleaseCheck({
    required this.id,
    required this.status,
    required this.detail,
    this.hard = false,
  });

  const ReleaseCheck.ok(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.ok;

  const ReleaseCheck.failed(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.failed;

  const ReleaseCheck.skipped(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.skipped;

  final String id;
  final ReleaseCheckStatus status;
  final String detail;
  final bool hard;

  bool get failed => status == ReleaseCheckStatus.failed;

  String get marker => switch (status) {
    ReleaseCheckStatus.ok => '通过',
    ReleaseCheckStatus.failed => '未过',
    ReleaseCheckStatus.skipped => '跳过',
  };
}

/// 一个待发布包的静态画像：三个文本 + 包根下已存在的文件名。
///
/// 用数据而不是 `Directory` 表达，判定层因此不碰磁盘，单测不需要临时目录。
final class PackageManifest {
  const PackageManifest({
    required this.name,
    required this.pubspec,
    required this.files,
    this.overrides,
    this.changelog,
  });

  final String name;
  final String pubspec;

  /// 包根下的文件名（不含子目录）。用来判 LICENSE / README / CHANGELOG 是否齐备。
  final Set<String> files;

  /// `pubspec_overrides.yaml` 内容；没有该文件时为 null。
  final String? overrides;

  /// 包内 `CHANGELOG.md` 内容；没有该文件时为 null。
  final String? changelog;
}

/// 判定所需的全部输入，全部是文件内容字符串。
final class ReleaseInputs {
  const ReleaseInputs({
    required this.packages,
    required this.changelog,
    required this.examplePubspec,
    required this.exampleOverrides,
    required this.exampleLock,
    required this.compatMatrix,
    required this.serviceHost,
    required this.invocation,
    required this.workflow,
  });

  final Map<String, PackageManifest> packages;
  final String changelog;
  final String examplePubspec;
  final String? exampleOverrides;
  final String exampleLock;
  final String compatMatrix;
  final String serviceHost;
  final String invocation;
  final String workflow;
}

/// 兼容矩阵的一行。
final class CompatRow {
  const CompatRow({
    required this.tag,
    required this.commitSha,
    required this.schemaVersion,
    required this.flutterCi,
    required this.flutterMin,
    required this.consumers,
  });

  final String tag;
  final String commitSha;
  final String schemaVersion;
  final String flutterCi;
  final String flutterMin;
  final String consumers;

  /// tag 之后才能定的格子是否还是占位符。
  bool get hasPending =>
      commitSha == pendingSha || consumers == pendingConsumers;

  /// 按 docs/compat-matrix.md 现行体例渲染：tag / SHA / Flutter 最低支持带反引号。
  String render() =>
      '| `$tag` | `$commitSha` | $schemaVersion | $flutterCi '
      '| `$flutterMin` | $consumers |';
}

// ===== 版本号与 caret 约束 =====

/// 只认本仓在用的 `X.Y.Z`。预发布号 / build 号不在本仓体例内，遇到即当非法。
final class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

  static Version? tryParse(String text) {
    final RegExpMatch? match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    return Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int major;
  final int minor;
  final int patch;

  /// `^X.Y.Z` 的上界：0.x 走 minor 边界，其余走 major 边界。
  Version get caretUpperBound =>
      major == 0 ? Version(0, minor + 1, 0) : Version(major + 1, 0, 0);

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

/// `^X.Y.Z` 形式的约束是否接纳 [version]；不是 caret 形式返回 null（交人工判断）。
bool? caretAdmits(String constraint, Version version) {
  final String trimmed = constraint.trim();
  if (!trimmed.startsWith('^')) return null;
  final Version? base = Version.tryParse(trimmed.substring(1));
  if (base == null) return null;
  return version.compareTo(base) >= 0 &&
      version.compareTo(base.caretUpperBound) < 0;
}

// ===== pubspec：极小段落扫描 =====
//
// 不引 YAML 依赖（patchbay 包运行时只依赖 crypto）。本仓的 pubspec 与 overrides 都是手写的
// 平铺结构，只需要认「顶层键 + 两空格一级子键」这一层。

/// 把 pubspec 切成顶层键 -> 该键下的缩进行。
Map<String, List<String>> topLevelBlocks(String yaml) {
  final blocks = <String, List<String>>{};
  String? current;
  for (final String line in yaml.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final RegExpMatch? top = RegExp(
      r'^([A-Za-z_][A-Za-z0-9_]*):',
    ).firstMatch(line);
    if (top != null) {
      current = top.group(1);
      blocks[current!] = <String>[];
      final String inline = line.substring(top.end).trim();
      if (inline.isNotEmpty) blocks[current]!.add(line);
      continue;
    }
    if (current != null) blocks[current]!.add(line);
  }
  return blocks;
}

/// 读顶层标量字段（`version` / `description` / `publish_to` / `repository`）。
String? readPubspecField(String yaml, String field) {
  final RegExpMatch? match = RegExp(
    '^$field:[ \\t]*(.*)\$',
    multiLine: true,
  ).firstMatch(yaml);
  if (match == null) return null;
  final String raw = match.group(1)!.trim();
  if (raw.isEmpty) return null;
  return _unquote(raw);
}

String? readPubspecVersion(String yaml) => readPubspecField(yaml, 'version');

/// 改写 `version:` 行；找不到就抛，不静默新增（pubspec 缺 version 是另一个问题）。
String applyPubspecVersion(String yaml, String version) {
  final RegExp pattern = RegExp(r'^version:[ \t]*.*$', multiLine: true);
  if (!pattern.hasMatch(yaml)) {
    throw const FormatException('pubspec 缺 version 字段');
  }
  return yaml.replaceFirst(pattern, 'version: $version');
}

/// 删掉 `publish_to: none` 这一行——**发布开关**，只在显式 `--enable-publish` 时执行。
///
/// 这一行是「这个包到底上不上 pub」的唯一物理开关，翻它等于宣布对外发布，属于仓主的决定，
/// 不能顺手夹在定版改动里。没有这一行则原样返回。
String applyRemovePublishTo(String yaml) => yaml.replaceFirst(
  RegExp(r'^publish_to:[ \t]*none[ \t]*\r?\n', multiLine: true),
  '',
);

/// 解析依赖块：依赖名 -> 它下面的缩进行（内联写法则为空表）。
Map<String, List<String>> parseDependencyBlock(String yaml, String blockName) {
  final List<String>? lines = topLevelBlocks(yaml)[blockName];
  if (lines == null) return const <String, List<String>>{};
  final entries = <String, List<String>>{};
  String? current;
  for (final String line in lines) {
    final RegExpMatch? entry = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$',
    ).firstMatch(line);
    if (entry != null) {
      current = entry.group(1);
      entries[current!] = <String>[];
      continue;
    }
    if (current != null && line.startsWith('    ')) entries[current]!.add(line);
  }
  return entries;
}

/// 依赖块里写成一行的条目：依赖名 -> 约束串（块写法的条目不在其中）。
Map<String, String> parseInlineDependencies(String yaml, String blockName) {
  final List<String>? lines = topLevelBlocks(yaml)[blockName];
  if (lines == null) return const <String, String>{};
  final entries = <String, String>{};
  for (final String line in lines) {
    final RegExpMatch? entry = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):[ \t]*(\S.*)$',
    ).firstMatch(line);
    if (entry != null)
      entries[entry.group(1)!] = _unquote(entry.group(2)!.trim());
  }
  return entries;
}

/// `dependencies:` 里用 `path:` 声明的依赖名。pub 发布拒绝 path 依赖。
Set<String> readPathDependencies(String yaml) {
  final result = <String>{};
  parseDependencyBlock(yaml, 'dependencies').forEach((name, lines) {
    if (lines.any((line) => RegExp(r'^\s+path:').hasMatch(line))) {
      result.add(name);
    }
  });
  return result;
}

/// 该包依赖的其他随版包（不论 path 还是 hosted），用来推发布顺序。
Set<String> readInternalDependencies(String yaml) {
  final deps = <String>{
    ...parseDependencyBlock(yaml, 'dependencies').keys,
    ...parseDependencyBlock(yaml, 'dev_dependencies').keys,
  };
  return deps.where(releasePackages.contains).toSet();
}

/// 写成 hosted 约束的随版依赖：依赖名 -> 约束串。发布合法性只认这一种写法。
Map<String, String> readInternalConstraints(String yaml) => <String, String>{
  for (final MapEntry<String, String> entry in parseInlineDependencies(
    yaml,
    'dependencies',
  ).entries)
    if (releasePackages.contains(entry.key)) entry.key: entry.value,
};

/// 把不接纳目标版本的随版依赖约束改写成 `^<版本>`；已接纳的原样保留（0.3.1 不必动 `^0.3.0`）。
String applyInternalConstraints(String yaml, String version) {
  final Version target =
      Version.tryParse(version) ??
      (throw FormatException('版本号必须是 X.Y.Z：$version'));
  var result = yaml;
  readInternalConstraints(yaml).forEach((name, constraint) {
    if (caretAdmits(constraint, target) == true) return;
    result = result.replaceFirst(
      RegExp('^  $name:[ \\t]*\\S.*\$', multiLine: true),
      '  $name: ^$version',
    );
  });
  return result;
}

/// `dependency_overrides:` 里 path 形式的条目：依赖名 -> path 值。
Map<String, String> readPathOverrides(String? yaml) {
  if (yaml == null) return const <String, String>{};
  final result = <String, String>{};
  parseDependencyBlock(yaml, 'dependency_overrides').forEach((name, lines) {
    for (final String line in lines) {
      final RegExpMatch? match = RegExp(
        r'^\s+path:[ \t]*(.+)$',
      ).firstMatch(line);
      if (match != null) result[name] = _unquote(match.group(1)!.trim());
    }
  });
  return result;
}

/// 按「依赖名 -> 相对路径」渲染一份 `pubspec_overrides.yaml`。
///
/// 仓内开发要解析到工作树里的源码，发布出去的 pubspec 又必须是 hosted 约束——两件事由这个
/// 文件调和。它不进发布包（`dart pub publish` 的归档里没有它，实测确认）。
String renderOverrides(Map<String, String> paths) {
  final List<String> names = paths.keys.toList()..sort();
  final StringBuffer out = StringBuffer()
    ..writeln('# 仓内开发用：把随版包解析到工作树，pubspec.yaml 里保留发布合法的 hosted 约束。')
    ..writeln(
      '# 由 `dart run packages/patchbay/bin/release_prep.dart --apply` 维护，勿手改。',
    )
    ..writeln('dependency_overrides:');
  for (final String name in names) {
    out
      ..writeln('  $name:')
      ..writeln('    path: ${paths[name]}');
  }
  return out.toString();
}

/// `environment:` 下的 Flutter 约束（`flutter: '>=3.38.0'`）。
///
/// 只认带引号值的写法，因此不会误命中 `dependencies:` 里 `flutter:\n  sdk: flutter`
/// 那种块写法。
String? readFlutterConstraint(String yaml) {
  final List<String>? environment = topLevelBlocks(yaml)['environment'];
  if (environment == null) return null;
  for (final String line in environment) {
    final RegExpMatch? match = RegExp(
      r'''^\s+flutter:\s*(.+)$''',
    ).firstMatch(line);
    if (match != null) return _unquote(match.group(1)!.trim());
  }
  return null;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

// ===== 发布顺序与本地解析拓扑 =====

/// 按包间依赖拓扑排序，同层按字母序稳定输出。
///
/// 顺序是推出来的，不是写死的：以后加包或改依赖方向，命令清单跟着变。
List<String> publishOrder(Map<String, Set<String>> graph) {
  final remaining = <String, Set<String>>{
    for (final MapEntry<String, Set<String>> entry in graph.entries)
      entry.key: entry.value.where(graph.containsKey).toSet(),
  };
  final ordered = <String>[];
  while (remaining.isNotEmpty) {
    final List<String> ready =
        remaining.entries
            .where((entry) => entry.value.isEmpty)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    if (ready.isEmpty) {
      final List<String> cycle = remaining.keys.toList()..sort();
      throw FormatException('包依赖成环，无法定发布顺序：${cycle.join(' / ')}');
    }
    ordered.addAll(ready);
    for (final String name in ready) {
      remaining.remove(name);
    }
    for (final Set<String> deps in remaining.values) {
      deps.removeAll(ready);
    }
  }
  return ordered;
}

/// 包间依赖图：包名 -> 它依赖的随版包。
Map<String, Set<String>> dependencyGraph(
  ReleaseInputs inputs,
) => <String, Set<String>>{
  for (final MapEntry<String, PackageManifest> entry in inputs.packages.entries)
    entry.key: readInternalDependencies(entry.value.pubspec),
};

/// 从输入直接推四包发布顺序。
List<String> publishOrderOf(ReleaseInputs inputs) =>
    publishOrder(dependencyGraph(inputs));

/// [roots] 在依赖图里的传递闭包（不含 roots 自身）。
Set<String> transitiveDeps(
  Map<String, Set<String>> graph,
  Iterable<String> roots,
) {
  final result = <String>{};
  final queue = <String>[...roots];
  while (queue.isNotEmpty) {
    final String current = queue.removeLast();
    for (final String dep in graph[current] ?? const <String>{}) {
      if (result.add(dep)) queue.add(dep);
    }
  }
  result.removeAll(roots);
  return result;
}

/// path 形式的包间依赖图：这些边不需要 override，pub 本来就解析到工作树。
Map<String, Set<String>> pathDependencyGraph(
  ReleaseInputs inputs,
) => <String, Set<String>>{
  for (final MapEntry<String, PackageManifest> entry in inputs.packages.entries)
    entry.key: readPathDependencies(
      entry.value.pubspec,
    ).where(releasePackages.contains).toSet(),
};

/// 以 [roots] 为解析根时，必须靠 override 才能落到工作树的随版包。
///
/// override 只对「解析的根包」生效，因此根包要把传递依赖里**改成 hosted 约束**的随版包全部
/// 列上：少列一个，那个包就会从 pub.dev 拉，工作树里的改动测不到。仍是 path 边的不必列。
Set<String> overridesNeededFor(ReleaseInputs inputs, Iterable<String> roots) =>
    transitiveDeps(dependencyGraph(inputs), roots)
      ..removeAll(transitiveDeps(pathDependencyGraph(inputs), roots));

/// 每个需要 override 的目录 -> 「依赖名 -> 相对路径」。
///
/// 键是仓根相对的 overrides 文件路径，值是该文件应有的内容骨架。
Map<String, Map<String, String>> expectedOverrides(ReleaseInputs inputs) {
  final result = <String, Map<String, String>>{};
  for (final String name in releasePackages) {
    final Set<String> needed = overridesNeededFor(inputs, <String>[name]);
    if (needed.isEmpty) continue;
    result[overridesPathOf(name)] = <String, String>{
      for (final String dep in needed.toList()..sort()) dep: '../$dep',
    };
  }
  // example 直接 path 依赖 patchbay_flutter；patchbay_flutter 对 patchbay 一旦改成 hosted
  // 约束，不 override 就会从 pub.dev 拉——example 因此也要跟着列传递闭包。
  final Set<String> exampleNeeded = overridesNeededFor(
    inputs,
    readPathDependencies(
      inputs.examplePubspec,
    ).where(releasePackages.contains).toSet(),
  );
  if (exampleNeeded.isNotEmpty) {
    result[exampleOverridesPath] = <String, String>{
      for (final String dep in exampleNeeded.toList()..sort())
        dep: '../../$dep',
    };
  }
  return result;
}

// ===== markdown 链接 =====
//
// pub.dev 单独渲染发布归档里的 README.md 与 CHANGELOG.md，仓内相对路径在那里没有可解析的
// 基准；包内 CHANGELOG 又是从仓根那份派生的，根表里 `docs/guide.md` 这样的路径拷进
// `packages/<包>/CHANGELOG.md` 后连在 GitHub 上都解析不到。两处都靠这里改写成绝对地址。

/// 三种会产生链接的写法，逐行匹配（多行状态由 [_mapRepoLinks] 维护）。
final RegExp _inlineLinkPattern = RegExp(
  r'\]\(([^)\s]+)((?:[ \t]+"[^"]*")?)\)',
);
final RegExp _refDefPattern = RegExp(r'^(\[[^\]]+\]:[ \t]*)(\S+)');
final RegExp _htmlHrefPattern = RegExp(r'(href=")([^"]+)(")');
final RegExp _fencePattern = RegExp(r'^[ \t]*(```|~~~)');

/// 是否是「指向仓内的相对路径」。
///
/// 带 scheme 的（`https:` / `mailto:`）、协议相对的（`//host/...`）、纯锚点跳转（`#节`）
/// 都不算——它们在 pub.dev 上本来就工作。
bool isRelativeRepoLink(String target) {
  if (target.isEmpty) return false;
  if (target.startsWith('#') || target.startsWith('//')) return false;
  return !RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(target);
}

/// 逐行遍历 markdown 的链接目标，用 [map] 的返回值替换。围栏代码块内不动。
String _mapRepoLinks(String markdown, String Function(String target) map) {
  final List<String> lines = markdown.split('\n');
  var inFence = false;
  for (var index = 0; index < lines.length; index += 1) {
    final String line = lines[index];
    if (_fencePattern.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    var rewritten = line.replaceAllMapped(
      _inlineLinkPattern,
      (match) => '](${map(match.group(1)!)}${match.group(2)})',
    );
    rewritten = rewritten.replaceFirstMapped(
      _refDefPattern,
      (match) => '${match.group(1)}${map(match.group(2)!)}',
    );
    rewritten = rewritten.replaceAllMapped(
      _htmlHrefPattern,
      (match) => '${match.group(1)}${map(match.group(2)!)}${match.group(3)}',
    );
    lines[index] = rewritten;
  }
  return lines.join('\n');
}

/// markdown 里全部指向仓内的相对链接（按出现顺序，含重复）。
///
/// 判定与单测都用它：pub 快照上的文件里出现一条就是一条断链。
List<String> relativeRepoLinks(String markdown) {
  final found = <String>[];
  _mapRepoLinks(markdown, (target) {
    if (isRelativeRepoLink(target)) found.add(target);
    return target;
  });
  return found;
}

/// 把 **仓根视角** 的相对链接改写成绝对 GitHub 地址；锚点跟着路径一起带过去。
///
/// 只对「相对仓根」的文本成立（仓根 CHANGELOG.md 就是），因此直接拼前缀不做路径归一。
String absolutizeRepoLinks(String markdown, {String prefix = repoBlobPrefix}) =>
    _mapRepoLinks(
      markdown,
      (target) => isRelativeRepoLink(target) ? '$prefix$target' : target,
    );

// ===== CHANGELOG =====

/// CHANGELOG 相对某个目标版本的状态。
final class ChangelogState {
  const ChangelogState({
    required this.hasUnreleased,
    required this.releaseDate,
    required this.releaseIsNewest,
  });

  /// 是否还留着 `## Unreleased` 段。打完 tag 的 CHANGELOG 不留（见 0.2.0 / 0.2.1 tag）。
  final bool hasUnreleased;

  /// 目标版本段的日期；没有该段则为 null。
  final String? releaseDate;

  /// 目标版本段是否是最靠前的 `## ` 段（本表新版本在上）。
  final bool releaseIsNewest;

  bool get released => releaseDate != null;
}

ChangelogState readChangelogState(String markdown, String version) {
  final List<String> headings = RegExp(r'^## (.+)$', multiLine: true)
      .allMatches(markdown)
      .map((match) => match.group(1)!.trim())
      .toList(growable: false);
  final RegExpMatch? release = RegExp(
    '^## ${RegExp.escape(version)} - (\\S+)[ \\t]*\$',
    multiLine: true,
  ).firstMatch(markdown);
  return ChangelogState(
    hasUnreleased: headings.contains('Unreleased'),
    releaseDate: release?.group(1),
    releaseIsNewest:
        headings.isNotEmpty && headings.first.startsWith('$version - '),
  );
}

/// 把 `## Unreleased` 落款成 `## <版本> - <日期>`。
///
/// 已落款则原样返回（apply 幂等）；两段并存时不猜内容归属，交人工。
String applyChangelogRelease(String markdown, String version, String date) {
  final ChangelogState state = readChangelogState(markdown, version);
  if (state.released) return markdown;
  if (!state.hasUnreleased) {
    throw FormatException('CHANGELOG 既无 `## Unreleased` 段，也无 `## $version` 段');
  }
  // 只吃行内空白：`\s*$` 在 multiLine 下会连同后面的空行一起吞掉，
  // 落款后 `### Added` 会贴到标题上。
  return markdown.replaceFirst(
    RegExp(r'^## Unreleased[ \t]*$', multiLine: true),
    '## $version - $date',
  );
}

/// 包内 CHANGELOG 的前言。pub.dev 每个包页的 Changelog tab 读的是**包内**这份文件，
/// 仓根那份它看不到，所以四包各留一份；正文仍只在仓根维护，这里是派生产物。
const String _packageChangelogPreamble = '''
# Changelog

四个包随同一个 tag 定版，变更正文只在仓库根 [CHANGELOG.md][root] 维护一份。本文件由
`release_prep --apply` 从根表派生（已发布版本段原样拷贝，`Unreleased` 段不带过来），
供 pub.dev 的 Changelog tab 展示；**不要手改，改根表后重跑 apply**。

[root]: https://github.com/cr1992/patchbay/blob/main/CHANGELOG.md
''';

/// 包内 CHANGELOG 是否已记到目标版本。
///
/// pub 的校验就是「CHANGELOG 提没提当前版本」，没提是 warning，`--dry-run` 因此退 65。
bool packageChangelogMentions(String? markdown, String version) =>
    markdown != null &&
    RegExp(
      '^## ${RegExp.escape(version)}( |\$)',
      multiLine: true,
    ).hasMatch(markdown);

/// 从仓根 CHANGELOG 派生包内 CHANGELOG：换掉前言，去掉 `## Unreleased` 段，
/// 把仓内相对链接钉成绝对地址，其余原样。
///
/// 整份重算而不是增量追加：包内那份是根表的投影，重跑 apply 永远能把它拉回一致，
/// 不会出现「根表改了、包内没跟」的第三份真源。
///
/// 链接改写不能省：根表在仓根，`docs/guide.md` 这类路径拷进 `packages/<包>/CHANGELOG.md`
/// 后就落到了包目录下，GitHub 上 404、pub.dev 的 Changelog tab 上同样解析不到。
String derivePackageChangelog(String rootChangelog) {
  final List<RegExpMatch> headings = RegExp(
    r'^## ',
    multiLine: true,
  ).allMatches(rootChangelog).toList(growable: false);
  if (headings.isEmpty) return _packageChangelogPreamble;
  final StringBuffer out = StringBuffer(_packageChangelogPreamble);
  for (var index = 0; index < headings.length; index += 1) {
    final int start = headings[index].start;
    final int end = index + 1 < headings.length
        ? headings[index + 1].start
        : rootChangelog.length;
    final String section = rootChangelog.substring(start, end);
    if (RegExp(r'^## Unreleased[ \t]*$', multiLine: true).hasMatch(section)) {
      continue;
    }
    out
      ..writeln()
      ..write(absolutizeRepoLinks(section).trimRight())
      ..writeln();
  }
  return out.toString();
}

// ===== example/pubspec.lock =====

final class _LockBlock {
  const _LockBlock({
    required this.name,
    required this.source,
    required this.version,
    required this.versionLine,
  });

  final String name;
  final String? source;
  final String? version;
  final int versionLine;
}

List<_LockBlock> _lockBlocks(String lock) {
  final List<String> lines = lock.split('\n');
  final blocks = <_LockBlock>[];
  String? name;
  String? source;
  String? version;
  int versionLine = -1;

  void flush() {
    if (name == null) return;
    blocks.add(
      _LockBlock(
        name: name,
        source: source,
        version: version,
        versionLine: versionLine,
      ),
    );
    source = null;
    version = null;
    versionLine = -1;
  }

  for (var index = 0; index < lines.length; index += 1) {
    final String line = lines[index];
    final RegExpMatch? header = RegExp(
      r'^  ([A-Za-z_][A-Za-z0-9_]*):\s*$',
    ).firstMatch(line);
    if (header != null) {
      flush();
      name = header.group(1);
      continue;
    }
    if (name == null) continue;
    final RegExpMatch? field = RegExp(
      r'^    (source|version):\s*(.+)$',
    ).firstMatch(line);
    if (field != null) {
      if (field.group(1) == 'source') {
        source = _unquote(field.group(2)!.trim());
      } else {
        version = _unquote(field.group(2)!.trim());
        versionLine = index;
      }
    }
    if (RegExp(r'^[A-Za-z_]').hasMatch(line)) flush();
  }
  flush();
  return blocks;
}

/// lock 里 path 源的随版包：包名 -> 记录的版本号。
Map<String, String> readLockPathVersions(String lock) => <String, String>{
  for (final _LockBlock block in _lockBlocks(lock))
    if (block.source == 'path' &&
        block.version != null &&
        releasePackages.contains(block.name))
      block.name: block.version!,
};

/// 把 lock 里 path 源随版包的版本号刷到目标版本。
///
/// 只改这些格子、不重排文件，因此幂等且离线；真正的 `flutter pub get`
/// 复核留在人工清单里。
String applyLockVersions(String lock, String version) {
  final List<String> lines = lock.split('\n');
  for (final _LockBlock block in _lockBlocks(lock)) {
    if (block.source != 'path') continue;
    if (!releasePackages.contains(block.name)) continue;
    if (block.versionLine < 0) continue;
    lines[block.versionLine] = '    version: "$version"';
  }
  return lines.join('\n');
}

// ===== 兼容矩阵 =====

List<CompatRow> parseCompatRows(String markdown) {
  final rows = <CompatRow>[];
  for (final String line in markdown.split('\n')) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) continue;
    final List<String> cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((cell) => _stripCode(cell.trim()))
        .toList(growable: false);
    // 表头与分隔行的第一格不是 tag，靠这一条自然滤掉。
    if (cells.length != 6 || !cells.first.startsWith(tagPrefix)) continue;
    rows.add(
      CompatRow(
        tag: cells[0],
        commitSha: cells[1],
        schemaVersion: cells[2],
        flutterCi: cells[3],
        flutterMin: cells[4],
        consumers: cells[5],
      ),
    );
  }
  return rows;
}

String _stripCode(String cell) =>
    cell.length >= 2 && cell.startsWith('`') && cell.endsWith('`')
    ? cell.substring(1, cell.length - 1)
    : cell;

/// 在「当前记录」表顶插入新行。
///
/// 已存在同 tag 行时原样返回——人工回填过的行不被脚本覆盖。
String applyCompatMatrixRow(String markdown, CompatRow row) {
  if (parseCompatRows(markdown).any((existing) => existing.tag == row.tag)) {
    return markdown;
  }
  final List<String> lines = markdown.split('\n');
  var insertAt = -1;
  for (var index = 0; index < lines.length; index += 1) {
    final String trimmed = lines[index].trim();
    if (trimmed.startsWith('| `$tagPrefix')) {
      insertAt = index;
      break;
    }
    if (trimmed.startsWith('|-') && trimmed.endsWith('|')) insertAt = index + 1;
  }
  if (insertAt < 0) {
    throw const FormatException('兼容矩阵里找不到「当前记录」表');
  }
  lines.insert(insertAt, row.render());
  return lines.join('\n');
}

/// 源码里的 wire `schemaVersion`。
int? readSchemaVersion(String dartSource) {
  final RegExpMatch? match = RegExp(
    r'static const int schemaVersion = (\d+);',
  ).firstMatch(dartSource);
  return match == null ? null : int.parse(match.group(1)!);
}

/// GitHub Actions 里 CI 实际验证的 Flutter 版本。
String? readCiFlutterVersion(String workflow) {
  final RegExpMatch? match = RegExp(
    r'''^\s*FLUTTER_VERSION:\s*(.+)$''',
    multiLine: true,
  ).firstMatch(workflow);
  return match == null ? null : _unquote(match.group(1)!.trim());
}

/// 按源码现值生成目标版本的矩阵行（tag 后才能定的两格留占位符）。
CompatRow buildCompatRow(String version, ReleaseInputs inputs) => CompatRow(
  tag: '$tagPrefix$version',
  commitSha: pendingSha,
  schemaVersion: '${readSchemaVersion(inputs.serviceHost) ?? '?'}',
  flutterCi: readCiFlutterVersion(inputs.workflow) ?? '?',
  flutterMin:
      readFlutterConstraint(inputs.packages['patchbay_flutter']!.pubspec) ??
      '?',
  consumers: pendingConsumers,
);

// ===== 判定 =====

String requireVersion(String version) {
  if (Version.tryParse(version) == null) {
    throw FormatException('版本号必须是 X.Y.Z：$version');
  }
  return version;
}

/// 定版四件套 + 包内 CHANGELOG + pub 发布静态门的全部判定。
///
/// [resolveTag] 把 tag 解析成 peeled commit SHA（解析不出返回 null，例如浅克隆或
/// tag 还没打）。判定层因此不直接调 git，单测可以注入。
List<ReleaseCheck> evaluateRelease({
  required String version,
  required ReleaseInputs inputs,
  required String? Function(String tag) resolveTag,
}) {
  requireVersion(version);
  return <ReleaseCheck>[
    _checkVersionParity(version, inputs),
    _checkSchemaParity(inputs),
    _checkChangelog(version, inputs),
    _checkPackageChangelogs(version, inputs),
    _checkExampleLock(version, inputs),
    _checkCompatRow(version, inputs),
    _checkCompatBackfill(inputs, resolveTag),
    _checkInternalConstraints(version, inputs),
    _checkLocalOverrides(inputs),
    _checkPublishSwitch(inputs),
    ..._checkPublishManifest(inputs),
  ];
}

ReleaseCheck _checkVersionParity(String version, ReleaseInputs inputs) {
  final stale = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) {
      stale.add('$name=缺 pubspec');
      continue;
    }
    final String? actual = readPubspecVersion(manifest.pubspec);
    if (actual != version) stale.add('$name=${actual ?? '缺 version 字段'}');
  }
  if (stale.isEmpty) {
    return ReleaseCheck.ok('version-parity', '四包 version 均为 $version');
  }
  return ReleaseCheck.failed(
    'version-parity',
    '未 bump 到 $version：${stale.join('、')}（`--apply` 可代改）',
  );
}

ReleaseCheck _checkSchemaParity(ReleaseInputs inputs) {
  final int? host = readSchemaVersion(inputs.serviceHost);
  final int? invocation = readSchemaVersion(inputs.invocation);
  if (host == null || invocation == null) {
    return const ReleaseCheck.failed(
      'schema-version-parity',
      '读不到 schemaVersion 常量（service_host.dart / invocation.dart）',
    );
  }
  if (host != invocation) {
    return ReleaseCheck.failed(
      'schema-version-parity',
      'schemaVersion 两处不一致：service_host=$host、invocation=$invocation；'
          '握手会在运行时拒绝，必须先对齐',
    );
  }
  return ReleaseCheck.ok('schema-version-parity', '两处 schemaVersion 同为 $host');
}

ReleaseCheck _checkChangelog(String version, ReleaseInputs inputs) {
  final ChangelogState state = readChangelogState(inputs.changelog, version);
  if (state.released && state.hasUnreleased) {
    return ReleaseCheck.failed(
      'changelog-release',
      '已有 `## $version` 段但仍残留 `## Unreleased` 段；两段内容归属需人工裁定',
    );
  }
  if (state.released && !state.releaseIsNewest) {
    return ReleaseCheck.failed(
      'changelog-release',
      '`## $version` 段不在最前；本表新版本在上',
    );
  }
  if (state.released) {
    return ReleaseCheck.ok(
      'changelog-release',
      '已落款 `## $version - ${state.releaseDate}`',
    );
  }
  if (state.hasUnreleased) {
    return ReleaseCheck.failed(
      'changelog-release',
      '`## Unreleased` 尚未落款成 `## $version - <日期>`（`--apply` 可代改）',
    );
  }
  return ReleaseCheck.failed(
    'changelog-release',
    'CHANGELOG 既无 `## Unreleased` 段也无 `## $version` 段，脚本不代造段落',
  );
}

ReleaseCheck _checkPackageChangelogs(String version, ReleaseInputs inputs) {
  final missing = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) continue;
    if (!packageChangelogMentions(manifest.changelog, version)) {
      missing.add(
        manifest.changelog == null ? '$name 无文件' : '$name 未记 $version',
      );
    }
  }
  if (missing.isEmpty) {
    return ReleaseCheck.ok(
      'package-changelog',
      '四包 CHANGELOG.md 均已记到 $version',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'package-changelog',
    '${missing.join('、')}——pub 校验「CHANGELOG 有没有提当前版本」，没提是 warning，'
        '`--dry-run` 会退 65（`--apply` 可代补）',
    hard: true,
  );
}

ReleaseCheck _checkExampleLock(String version, ReleaseInputs inputs) {
  final Map<String, String> locked = readLockPathVersions(inputs.exampleLock);
  if (locked.isEmpty) {
    return const ReleaseCheck.failed(
      'example-lock',
      '$exampleLockPath 里找不到 path 源的随版包条目',
      hard: true,
    );
  }
  final List<String> stale =
      locked.entries
          .where((entry) => entry.value != version)
          .map((entry) => '${entry.key}=${entry.value}')
          .toList(growable: false)
        ..sort();
  if (stale.isEmpty) {
    return ReleaseCheck.ok(
      'example-lock',
      '$exampleLockPath 已跟到 $version（${locked.keys.join('、')}）',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'example-lock',
    '$exampleLockPath 仍停在 ${stale.join('、')}——0.2.0 定版漏的就是这一项'
        '（`--apply` 可代刷）',
    hard: true,
  );
}

ReleaseCheck _checkCompatRow(String version, ReleaseInputs inputs) {
  final String tag = '$tagPrefix$version';
  final List<CompatRow> rows = parseCompatRows(inputs.compatMatrix);
  CompatRow? target;
  for (final CompatRow row in rows) {
    if (row.tag == tag) target = row;
  }
  if (target == null) {
    return ReleaseCheck.failed(
      'compat-matrix-row',
      '$compatMatrixPath 缺 `$tag` 行——0.2.1 定版漏的就是这一项'
          '（`--apply` 按源码现值生成占位行）',
      hard: true,
    );
  }
  final CompatRow expected = buildCompatRow(version, inputs);
  final drift = <String>[];
  if (target.schemaVersion != expected.schemaVersion) {
    drift.add(
      'schemaVersion 记 ${target.schemaVersion}、源码 ${expected.schemaVersion}',
    );
  }
  if (target.flutterCi != expected.flutterCi) {
    drift.add(
      'Flutter(CI) 记 ${target.flutterCi}、$workflowPath ${expected.flutterCi}',
    );
  }
  if (target.flutterMin != expected.flutterMin) {
    drift.add(
      'Flutter(最低) 记 ${target.flutterMin}、pubspec ${expected.flutterMin}',
    );
  }
  if (rows.isNotEmpty && rows.first.tag != tag) {
    drift.add('`$tag` 行不在表顶（本表新 tag 在上）');
  }
  if (drift.isNotEmpty) {
    return ReleaseCheck.failed(
      'compat-matrix-row',
      '`$tag` 行与源码不符：${drift.join('；')}（脚本不覆盖既有行，请人工修正）',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'compat-matrix-row',
    '`$tag` 行在表顶，schemaVersion / Flutter 三列与源码一致',
    hard: true,
  );
}

ReleaseCheck _checkCompatBackfill(
  ReleaseInputs inputs,
  String? Function(String tag) resolveTag,
) {
  final List<CompatRow> rows = parseCompatRows(inputs.compatMatrix);
  final problems = <String>[];
  final checked = <String>[];
  final unresolved = <String>[];
  for (final CompatRow row in rows) {
    final String? sha = resolveTag(row.tag);
    if (sha == null) {
      unresolved.add(row.tag);
      continue;
    }
    checked.add(row.tag);
    if (row.hasPending) {
      problems.add(
        '`${row.tag}` 已打 tag 但仍有占位符（SHA=${row.commitSha}、consumer=${row.consumers}）',
      );
      continue;
    }
    if (row.commitSha != sha) {
      problems.add('`${row.tag}` 记 ${row.commitSha}、实际 peeled SHA $sha');
    }
  }
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'compat-matrix-backfill',
      '${problems.join('；')}——0.2.1 打完 tag 漏的就是这一步',
      hard: true,
    );
  }
  if (checked.isEmpty) {
    return const ReleaseCheck.skipped(
      'compat-matrix-backfill',
      '没有可解析的 tag（浅克隆或 tag 未拉取），跳过回填核对',
      hard: true,
    );
  }
  final String pending = unresolved.isEmpty
      ? ''
      : '；未打 tag 的行留占位符：${unresolved.join('、')}';
  return ReleaseCheck.ok(
    'compat-matrix-backfill',
    '已打 tag 的 ${checked.length} 行 SHA 与 peeled tag 一致$pending',
    hard: true,
  );
}

ReleaseCheck _checkInternalConstraints(String version, ReleaseInputs inputs) {
  final Version target = Version.tryParse(version)!;
  final problems = <String>[];
  final pathStyle = <String>[];
  var checked = 0;
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) continue;
    final Set<String> asPath = readPathDependencies(
      manifest.pubspec,
    ).where(releasePackages.contains).toSet();
    for (final String dep in asPath.toList()..sort()) {
      pathStyle.add('$name→$dep');
    }
    readInternalConstraints(manifest.pubspec).forEach((dep, constraint) {
      checked += 1;
      final bool? admits = caretAdmits(constraint, target);
      if (admits == null) {
        problems.add('$name 的 $dep 约束 `$constraint` 不是 `^X.Y.Z`，需人工判断');
      } else if (!admits) {
        problems.add('$name 的 $dep 约束 `$constraint` 不接纳 $version');
      }
    });
  }
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'internal-dep-constraints',
      '${problems.join('；')}（`--apply` 可把 caret 约束改写成 `^$version`）',
      hard: true,
    );
  }
  if (pathStyle.isNotEmpty) {
    return ReleaseCheck.skipped(
      'internal-dep-constraints',
      '还有 path 形式的随版依赖，先看 publish-manifest：${pathStyle.join('、')}',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'internal-dep-constraints',
    '$checked 条随版依赖约束均接纳 $version',
    hard: true,
  );
}

ReleaseCheck _checkLocalOverrides(ReleaseInputs inputs) {
  final Map<String, Map<String, String>> expected = expectedOverrides(inputs);
  final Map<String, String?> actual = <String, String?>{
    for (final MapEntry<String, PackageManifest> entry
        in inputs.packages.entries)
      overridesPathOf(entry.key): entry.value.overrides,
    exampleOverridesPath: inputs.exampleOverrides,
  };
  final problems = <String>[];
  expected.forEach((path, wanted) {
    final Map<String, String> present = readPathOverrides(actual[path]);
    final List<String> diff = <String>[];
    wanted.forEach((dep, wantedPath) {
      final String? got = present[dep];
      if (got == null) {
        diff.add('缺 $dep');
      } else if (got != wantedPath) {
        diff.add('$dep 指向 $got、应为 $wantedPath');
      }
    });
    if (diff.isNotEmpty) problems.add('$path：${diff.join('、')}');
  });
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'local-overrides',
      '${problems.join('；')}——少一条，仓内开发就会从 pub.dev 拉那个包，'
          '工作树里的改动测不到（`--apply` 可代生成）',
      hard: true,
    );
  }
  if (expected.isEmpty) {
    return const ReleaseCheck.skipped(
      'local-overrides',
      '没有需要 override 的随版依赖',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'local-overrides',
    '${expected.length} 处 pubspec_overrides.yaml 指向工作树',
    hard: true,
  );
}

/// 发布开关：四包的 `publish_to: none` 还在不在。
///
/// 单列一项而不是混进 publish-manifest，因为它和别的项性质不同——别的项是「还没做完」，
/// 它是「要不要对外发布」，翻它的是仓主，不是脚本，也不是随手一个定版 MR。
ReleaseCheck _checkPublishSwitch(ReleaseInputs inputs) {
  final List<String> blocked = releasePackages
      .where(
        (name) =>
            readPubspecField(
              inputs.packages[name]?.pubspec ?? '',
              'publish_to',
            ) ==
            'none',
      )
      .toList(growable: false);
  if (blocked.isEmpty) {
    return const ReleaseCheck.ok(
      'publish-switch',
      '四包均未带 `publish_to: none`',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'publish-switch',
    '${blocked.join('、')} 仍带 `publish_to: none`，pub 会直接拒收。'
        '开发布开关是仓主的决定：确认要发时跑 `--apply --enable-publish`（默认不动这一行）',
    hard: true,
  );
}

List<ReleaseCheck> _checkPublishManifest(ReleaseInputs inputs) {
  final blockers = <String>[];
  final advisories = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) {
      blockers.add('$name 缺 pubspec');
      continue;
    }
    final String? description = readPubspecField(
      manifest.pubspec,
      'description',
    );
    if (description == null) {
      blockers.add('$name 缺 description');
    } else if (description.length < descriptionMinLength ||
        description.length > descriptionMaxLength) {
      advisories.add(
        '$name 的 description 长 ${description.length} 字符，'
        'pub 要求 $descriptionMinLength–$descriptionMaxLength',
      );
    }
    final Set<String> pathDeps = readPathDependencies(manifest.pubspec);
    if (pathDeps.isNotEmpty) {
      final List<String> sorted = pathDeps.toList()..sort();
      blockers.add('$name 的 ${sorted.join('/')} 还是 path 依赖（发布拒收）');
    }
    for (final String file in requiredPackageFiles) {
      if (!manifest.files.contains(file)) blockers.add('$name 缺 $file');
    }
    for (final String file in advisedPackageFiles) {
      if (!manifest.files.contains(file)) advisories.add('$name 缺 $file');
    }
    if (readPubspecField(manifest.pubspec, 'repository') == null &&
        readPubspecField(manifest.pubspec, 'homepage') == null) {
      advisories.add('$name 缺 repository/homepage');
    }
  }
  return <ReleaseCheck>[
    if (blockers.isEmpty)
      const ReleaseCheck.ok('publish-manifest', '四包已具备 pub 发布形态', hard: true)
    else
      ReleaseCheck.failed(
        'publish-manifest',
        '${blockers.join('；')}。这些是 `dart pub publish` 的 error 级项',
        hard: true,
      ),
    if (advisories.isEmpty)
      const ReleaseCheck.ok(
        'publish-advisories',
        'README / CHANGELOG / repository / description 长度齐备',
        hard: true,
      )
    else
      ReleaseCheck.failed(
        'publish-advisories',
        '${advisories.join('；')}。pub 记 warning，而 `--dry-run` 有 warning 即退 65，'
            '照样挡发布',
        hard: true,
      ),
  ];
}

/// 由 IO 层跑完 `dart format --output=none --set-exit-if-changed .` 后折成判定。
///
/// 排版自 !25 起是 CI 门禁（GitLab 与 GitHub 两边的 `dart_packages` 都跑），定版前先在本地
/// 判一次，省得 tag 都打完了才被门禁拦下。
ReleaseCheck evaluateFormatGate(int? exitCode) {
  if (exitCode == null) {
    return const ReleaseCheck.skipped('format-gate', '未跑排版检查', hard: true);
  }
  if (exitCode != 0) {
    return const ReleaseCheck.failed(
      'format-gate',
      '`dart format --output=none --set-exit-if-changed .` 有漂移；'
          '跑 `dart format .` 后重提',
      hard: true,
    );
  }
  return const ReleaseCheck.ok(
    'format-gate',
    '全仓排版与 dart_style 对齐',
    hard: true,
  );
}

/// 由 IO 层跑完 `dart pub publish --dry-run` 后，把结果折成一条判定。
///
/// [exitCodes] 是实际跑过的包；[skipped] 是因静态门已红而没必要付网络代价的包。
ReleaseCheck evaluatePublishDryRun({
  required Map<String, int> exitCodes,
  required List<String> skipped,
}) {
  final List<String> failed =
      exitCodes.entries
          .where((entry) => entry.value != 0)
          .map((entry) => '${entry.key}(exit=${entry.value})')
          .toList()
        ..sort();
  if (failed.isNotEmpty) {
    return ReleaseCheck.failed(
      'publish-dry-run',
      '`dart pub publish --dry-run` 未过：${failed.join('、')}；'
          '进包目录重跑一遍看 pub 原文（warning 也会退 65）',
      hard: true,
    );
  }
  if (exitCodes.isEmpty) {
    final List<String> sorted = skipped.toList()..sort();
    return ReleaseCheck.skipped(
      'publish-dry-run',
      sorted.isEmpty
          ? '按 `--no-publish-dry-run` 跳过'
          : '发布开关未开或静态门未过（见 publish-switch / publish-manifest），'
                'dry-run 无从跑起：${sorted.join('、')}',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'publish-dry-run',
    '${exitCodes.length} 个包 `dart pub publish --dry-run` 通过',
    hard: true,
  );
}

// ===== 人工清单 =====

/// tag / push / 发布 / 回填这些脚本永远不代做的动作。
List<String> manualSteps(String version, ReleaseInputs inputs) {
  final String tag = '$tagPrefix$version';
  return <String>[
    '给 CHANGELOG 的 `## $version` 段补一句批次摘要（体例见 0.2.1 段）。',
    '门禁全绿后按 CONTRIBUTING.md「发版」顺序走：GitHub 合并 → 回推 GitLab → 再打 tag。',
    '打 tag（origin 已配双推，一条命令同时到 GitLab 与 GitHub）：\n'
        '      git tag -a $tag -m \'patchbay $version\'\n'
        '      git push origin $tag',
    '核对双端同 tag 同 commit：\n'
        '      git ls-remote --tags origin $tag\n'
        '      git ls-remote --tags github $tag',
    '回填兼容矩阵 `$tag` 行的两个占位符：\n'
        '      git rev-parse $tag^{}   # 填 commit SHA 列（annotated tag 必须 peeled）\n'
        '      「已知 consumer」列的 `$pendingConsumers` 换成向 consumer 仓核实后的口径',
    '回填后重跑本脚本确认转绿：\n'
        '      dart run packages/patchbay/bin/release_prep.dart --version $version --check',
    '复核 example lock 与真实解析一致（脚本只改版本格子，不跑 pub）：\n'
        '      (cd $examplePath && flutter pub get)\n'
        '      git diff --exit-code $exampleLockPath',
    '开发布开关（仓主决定，一次性）：四包的 `publish_to: none` 不删，pub 直接拒收，'
        'dry-run 也跑不起来。确认 $version 对外发布后：\n'
        '      dart run packages/patchbay/bin/release_prep.dart --version $version --apply --enable-publish\n'
        '      # 等价于人工删掉四包 pubspec 的 `publish_to: none` 一行',
    '按发布顺序逐包发布（凭据由人提供；显式指定 host，本机 `PUB_HOSTED_URL` 常指向镜像）：\n'
        '${publishOrderOf(inputs).map((name) => '      (cd packages/$name && PUB_HOSTED_URL=$canonicalPubHost dart pub publish)').join('\n')}',
    'consumer 换 pin：git pin 的接入方不能只改 tag。四包改成 hosted 约束后，'
        '「patchbay_flutter 从 git、patchbay 也从 git」会被 pub 判成 source 冲突，'
        '接入方要么整体改用 pub.dev 版本，要么在自己仓加 `dependency_overrides` 把四包统一指回 git。'
        '口径见 docs/release-checklist.md。',
    '发布落地后把安装口径改到 pub.dev（README 的 git ref 安装说明、docs/guide.md 的'
        '「尚未发布到 pub.dev」一句）。',
    '真机验收：见 docs/release-checklist.md 对应一节。',
  ];
}

// ===== IO 外壳 =====

void main(List<String> arguments) {
  try {
    _run(arguments);
  } on FormatException catch (error) {
    stderr.writeln('release_prep：${error.message}');
    exitCode = 64;
  }
}

const String _usage = '''
用法：
  dart run packages/patchbay/bin/release_prep.dart --version X.Y.Z (--check|--apply)

可选：
  --date YYYY-MM-DD        CHANGELOG 落款日期，默认今天
  --repo-root <path>       仓根，默认从当前目录向上找
  --no-publish-dry-run     跳过 `dart pub publish --dry-run`（离线时用）
  --enable-publish         仅配合 --apply：删掉四包的 `publish_to: none`。
                           这是「对外发布」的开关，默认不动，由仓主显式点。
''';

final class _Options {
  const _Options({
    required this.version,
    required this.apply,
    required this.date,
    required this.repoRoot,
    required this.publishDryRun,
    required this.enablePublish,
  });

  final String version;
  final bool apply;
  final String date;
  final String repoRoot;
  final bool publishDryRun;
  final bool enablePublish;

  static _Options parse(List<String> arguments) {
    String? version;
    String? date;
    String? repoRoot;
    var check = false;
    var apply = false;
    var publishDryRun = true;
    var enablePublish = false;
    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--version':
          version = arguments.elementAtOrNull(++index);
        case '--date':
          date = arguments.elementAtOrNull(++index);
        case '--repo-root':
          repoRoot = arguments.elementAtOrNull(++index);
        case '--check':
          check = true;
        case '--apply':
          apply = true;
        case '--no-publish-dry-run':
          publishDryRun = false;
        case '--enable-publish':
          enablePublish = true;
        case '--help' || '-h':
          stdout.write(_usage);
          exit(0);
        default:
          throw FormatException('未知参数 ${arguments[index]}\n$_usage');
      }
    }
    if (version == null || check == apply) {
      throw const FormatException(
        '缺 --version，或 --check/--apply 未二选一\n$_usage',
      );
    }
    if (enablePublish && !apply) {
      throw const FormatException('--enable-publish 只能配合 --apply（check 不改文件）');
    }
    requireVersion(version);
    if (date != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw FormatException('--date 必须是 YYYY-MM-DD：$date');
    }
    return _Options(
      version: version,
      apply: apply,
      date: date ?? _today(),
      repoRoot: repoRoot ?? _findRepoRoot(),
      publishDryRun: publishDryRun,
      enablePublish: enablePublish,
    );
  }
}

String _today() {
  final DateTime now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String _findRepoRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/$changelogPath').existsSync() &&
        File('${directory.path}/${pubspecPathOf('patchbay')}').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw const FormatException(
        '找不到仓根（向上没看到 CHANGELOG.md + packages/patchbay）',
      );
    }
    directory = parent;
  }
}

ReleaseInputs _read(String root) {
  String read(String relative) {
    final File file = File('$root/$relative');
    if (!file.existsSync()) throw FormatException('缺文件：$relative');
    return file.readAsStringSync();
  }

  String? readOptional(String relative) {
    final File file = File('$root/$relative');
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  return ReleaseInputs(
    packages: <String, PackageManifest>{
      for (final String name in releasePackages)
        name: PackageManifest(
          name: name,
          pubspec: read(pubspecPathOf(name)),
          files: Directory('$root/packages/$name')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .toSet(),
          overrides: readOptional(overridesPathOf(name)),
          changelog: readOptional(packageChangelogPathOf(name)),
        ),
    },
    changelog: read(changelogPath),
    examplePubspec: read(examplePubspecPath),
    exampleOverrides: readOptional(exampleOverridesPath),
    exampleLock: read(exampleLockPath),
    compatMatrix: read(compatMatrixPath),
    serviceHost: read(serviceHostPath),
    invocation: read(invocationPath),
    workflow: read(workflowPath),
  );
}

String? _gitPeeledSha(String root, String tag) {
  try {
    final ProcessResult result = Process.runSync('git', <String>[
      '-C',
      root,
      'rev-parse',
      '--verify',
      '--quiet',
      '$tag^{commit}',
    ]);
    if (result.exitCode != 0) return null;
    final String out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on ProcessException {
    return null;
  }
}

void _run(List<String> arguments) {
  final _Options options = _Options.parse(arguments);
  final String root = options.repoRoot;
  String? resolveTag(String tag) => _gitPeeledSha(root, tag);

  if (options.apply) {
    _applyToDisk(root, options);
  }

  final ReleaseInputs inputs = _read(root);
  final List<ReleaseCheck> checks = evaluateRelease(
    version: options.version,
    inputs: inputs,
    resolveTag: resolveTag,
  );
  bool green(String id) =>
      checks.any((check) => check.id == id && !check.failed);
  final ReleaseCheck dryRun = _publishDryRun(
    root,
    enabled: options.publishDryRun,
    // 带着 `publish_to: none` 跑 dry-run 只会拿到一条「本包不可发布」，没有信息量。
    ready: green('publish-switch') && green('publish-manifest'),
  );
  final List<ReleaseCheck> all = <ReleaseCheck>[
    ...checks,
    _formatGate(root),
    dryRun,
  ];

  stdout
    ..writeln(
      '定版核对：patchbay ${options.version}（tag $tagPrefix${options.version}）',
    )
    ..writeln(
      '模式：${options.apply ? 'apply（已改文件，未打 tag、未推送、未发布）' : 'check（只读）'}',
    )
    ..writeln();
  for (final ReleaseCheck check in all) {
    stdout.writeln(
      '  [${check.marker}] ${check.id.padRight(24)}'
      '${check.hard ? '（硬）' : '　　　'} ${check.detail}',
    );
  }

  stdout
    ..writeln()
    ..writeln('发布顺序（按包间依赖推导）：${publishOrderOf(inputs).join(' → ')}')
    ..writeln()
    ..writeln('人工项——脚本不打 tag、不推送、不代发布：');
  final List<String> steps = manualSteps(options.version, inputs);
  for (var index = 0; index < steps.length; index += 1) {
    stdout.writeln('  ${index + 1}. ${steps[index]}');
  }

  final String? host = Platform.environment['PUB_HOSTED_URL'];
  if (host != null && host.isNotEmpty && host != canonicalPubHost) {
    stdout.writeln(
      '\n注意：本机 PUB_HOSTED_URL=$host（镜像）。dry-run 与 publish 都会走它，'
      '正式发布请按上面命令显式指定 $canonicalPubHost。',
    );
  }

  final int failures = all.where((check) => check.failed).length;
  stdout
    ..writeln()
    ..writeln(
      failures == 0 ? '结论：机检项全绿，剩下的是上面的人工项。' : '结论：$failures 项未过，见上方 [未过]。',
    );
  if (failures > 0) exitCode = 1;
}

void _applyToDisk(String root, _Options options) {
  final ReleaseInputs inputs = _read(root);
  final changed = <String>[];

  void write(String relative, String? before, String after) {
    if (before == after) return;
    final File file = File('$root/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(after);
    changed.add(relative);
  }

  // 根表先落款，包内那份才能从「已含目标版本段」的根表派生。
  final String rootChangelog = applyChangelogRelease(
    inputs.changelog,
    options.version,
    options.date,
  );
  write(changelogPath, inputs.changelog, rootChangelog);

  for (final String name in releasePackages) {
    final PackageManifest manifest = inputs.packages[name]!;
    var pubspec = applyInternalConstraints(
      applyPubspecVersion(manifest.pubspec, options.version),
      options.version,
    );
    if (options.enablePublish) pubspec = applyRemovePublishTo(pubspec);
    write(pubspecPathOf(name), manifest.pubspec, pubspec);
    write(
      packageChangelogPathOf(name),
      manifest.changelog,
      derivePackageChangelog(rootChangelog),
    );
  }
  expectedOverrides(inputs).forEach((path, paths) {
    final String? before = path == exampleOverridesPath
        ? inputs.exampleOverrides
        : inputs.packages[path.split('/')[1]]?.overrides;
    final String after = renderOverrides(paths);
    // 已经指对的文件不重写：手工加的注释与额外条目不被推平。
    final Map<String, String> present = readPathOverrides(before);
    final bool satisfied = paths.entries.every(
      (entry) => present[entry.key] == entry.value,
    );
    if (!satisfied) write(path, before, after);
  });
  write(
    exampleLockPath,
    inputs.exampleLock,
    applyLockVersions(inputs.exampleLock, options.version),
  );
  write(
    compatMatrixPath,
    inputs.compatMatrix,
    applyCompatMatrixRow(
      inputs.compatMatrix,
      buildCompatRow(options.version, inputs),
    ),
  );

  stdout
    ..writeln(
      changed.isEmpty ? 'apply：无改动（已是目标状态）' : 'apply：改了 ${changed.length} 个文件',
    )
    ..writeAll(changed.map((path) => '  - $path\n'))
    ..writeln();
}

ReleaseCheck _formatGate(String root) {
  try {
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['format', '--output=none', '--set-exit-if-changed', '.'],
      workingDirectory: root,
    );
    return evaluateFormatGate(result.exitCode);
  } on ProcessException {
    return evaluateFormatGate(null);
  }
}

ReleaseCheck _publishDryRun(
  String root, {
  required bool enabled,
  required bool ready,
}) {
  if (!enabled) {
    return evaluatePublishDryRun(
      exitCodes: const <String, int>{},
      skipped: const <String>[],
    );
  }
  if (!ready) {
    return evaluatePublishDryRun(
      exitCodes: const <String, int>{},
      skipped: releasePackages,
    );
  }
  final exitCodes = <String, int>{};
  for (final String name in releasePackages) {
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['pub', 'publish', '--dry-run'],
      workingDirectory: '$root/packages/$name',
    );
    exitCodes[name] = result.exitCode;
  }
  return evaluatePublishDryRun(exitCodes: exitCodes, skipped: const <String>[]);
}

extension<T> on List<T> {
  T? elementAtOrNull(int index) =>
      index >= 0 && index < length ? this[index] : null;
}
