// 发布顺序与本地解析拓扑。

import 'constants.dart';
import 'models.dart';
import 'pubspec_scanner.dart';

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
Set<String> overridesNeededFor(ReleaseInputs inputs, Iterable<String> roots) =>
    transitiveDeps(dependencyGraph(inputs), roots)
      ..removeAll(transitiveDeps(pathDependencyGraph(inputs), roots));

/// workspace 外的 consumer 验证目录 -> 「依赖名 -> 相对路径」。
///
/// 四个发布包由根 pub workspace 解析到同一工作树，不再各自维护 overrides；example
/// 刻意留在 workspace 外，继续用独立 lock 模拟真实 consumer，因此只为它生成覆盖。
Map<String, Map<String, String>> expectedOverrides(ReleaseInputs inputs) {
  final result = <String, Map<String, String>>{};
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
