// example/pubspec.lock 检查与版本改写。

import 'constants.dart';
import 'models.dart';
import 'pubspec_scanner.dart';

List<LockBlock> _lockBlocks(String lock) {
  final List<String> lines = lock.split('\n');
  final blocks = <LockBlock>[];
  String? name;
  String? source;
  String? version;
  int versionLine = -1;

  void flush() {
    if (name == null) return;
    blocks.add(
      LockBlock(
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
        source = unquote(field.group(2)!.trim());
      } else {
        version = unquote(field.group(2)!.trim());
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
  for (final LockBlock block in _lockBlocks(lock))
    if (block.source == 'path' &&
        block.version != null &&
        releasePackages.contains(block.name))
      block.name: block.version!,
};

/// 把 lock 里 path 源随版包的版本号刷到目标版本。
String applyLockVersions(String lock, String version) {
  final List<String> lines = lock.split('\n');
  for (final LockBlock block in _lockBlocks(lock)) {
    if (block.source != 'path') continue;
    if (!releasePackages.contains(block.name)) continue;
    if (block.versionLine < 0) continue;
    lines[block.versionLine] = '    version: "$version"';
  }
  return lines.join('\n');
}
