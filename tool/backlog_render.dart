// 按需把 `docs/backlog.d/` 碎片渲染成一张只读的台账总表。
//
// 这张表是**视图不是真源**，因此不入库：它一旦入库，每个实现 MR 都要重新生成
// 它，相邻行的独立修改又会在三方合并里撞成 hunk 冲突——那正是碎片化要消除的
// 问题。要看全表就现渲一份，看完即弃。
//
// 用法：
//   dart run tool/backlog_render.dart            # 打到 stdout
//   dart run tool/backlog_render.dart --out /tmp/backlog-view.md
import 'dart:io';

import 'backlog_store.dart';

void main(List<String> args) {
  var out = '';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) out = args[i + 1];
    if (args[i].startsWith('--out=')) out = args[i].split('=').last;
  }

  final result = loadBacklog(Directory.current.path);
  if (result.errors.isNotEmpty) {
    stderr.writeln('碎片解析失败，无法渲染：');
    for (final error in result.errors) {
      stderr.writeln('- $error');
    }
    exitCode = 1;
    return;
  }

  final view = renderBacklogView(result.entries);
  if (out.isEmpty) {
    stdout.write(view);
    return;
  }
  File(out).writeAsStringSync(view);
  stdout.writeln('已渲染 ${result.entries.length} 条到 $out');
}
