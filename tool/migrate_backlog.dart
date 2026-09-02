// 把旧的单文件 `docs/backlog.md` 大表机械拆成 `docs/backlog.d/` 碎片。
//
// 可重跑：它不是一次性手工劳动，而是「以某份旧表为输入，把碎片目录对齐到它」
// 的幂等操作——写入/覆盖源里存在的条目，删除源里已消失的碎片。仍有在途分支
// 继续改老表时，合并后重跑一次即可：
//
//   git show <their-sha>:docs/backlog.md > /tmp/legacy-backlog.md
//   dart run tool/migrate_backlog.dart --source /tmp/legacy-backlog.md --apply
//
// 自检就是往返等价证明：把碎片重新渲染回表格行，逐字节比对输入文件。任何
// 字段丢失、链接改写不可逆或表格形态漂移都会在这里判红，不会静默通过。
//
// 用法：
//   dart run tool/migrate_backlog.dart [--source docs/backlog.md] [--apply]
import 'dart:io';

import 'backlog_store.dart';

final RegExp _separatorCell = RegExp(r'^:?-{3,}:?$');

/// 从旧表解析出的一行。
final class _LegacyRow {
  _LegacyRow({
    required this.lineNumber,
    required this.spec,
    required this.entry,
  });

  final int lineNumber;
  final BacklogSectionSpec spec;
  final BacklogEntry entry;
}

final class _LegacyDocument {
  _LegacyDocument({
    required this.lines,
    required this.rows,
    required this.dataLineNumbers,
    required this.problems,
    required this.sectionsSeen,
  });

  final List<String> lines;
  final List<_LegacyRow> rows;

  /// 行号 -> 该行对应的条目编号；用于原位替换做往返比对。
  final Map<int, String> dataLineNumbers;
  final List<String> problems;
  final Set<BacklogKind> sectionsSeen;
}

void main(List<String> args) {
  final apply = args.contains('--apply');
  var source = backlogIndexPath;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--source' && i + 1 < args.length) source = args[i + 1];
    if (args[i].startsWith('--source=')) source = args[i].split('=').last;
  }

  final sourceFile = File(source);
  if (!sourceFile.existsSync()) {
    stderr.writeln('迁移源不存在：$source');
    exitCode = 1;
    return;
  }

  final text = sourceFile.readAsStringSync();
  final document = _parseLegacy(text);

  if (document.rows.isEmpty && document.problems.isEmpty) {
    stderr.writeln(
      '$source 里没有找到任何条目行。迁移已经完成过一次的仓库属于这种情况——'
      '请用 --source 指向仍是旧表形态的文件。',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('=== backlog 迁移（源：$source）===\n');
  for (final spec in backlogSections) {
    final count = document.rows.where((row) => row.spec == spec).length;
    final seen = document.sectionsSeen.contains(spec.kind);
    stdout.writeln(
      '${spec.heading.substring(3).padRight(28)} '
      '${seen ? '$count 条' : '章节缺失'}',
    );
  }

  if (document.problems.isNotEmpty) {
    stderr.writeln('\n结构不规整、脚本不敢自动处理的行：');
    for (final problem in document.problems) {
      stderr.writeln('  - $problem');
    }
  }

  final roundTrip = _roundTrip(document);
  stdout.writeln(
    '\n往返等价：${roundTrip.fieldDiffs.isEmpty ? '通过' : '失败'}'
    '（${document.rows.length} 行原位重渲，逐字节比对输入）',
  );
  if (roundTrip.whitespaceDiffs.isNotEmpty) {
    stdout.writeln('无语义空白差异（不判红）：');
    for (final diff in roundTrip.whitespaceDiffs) {
      stdout.writeln(diff);
    }
  }
  if (roundTrip.fieldDiffs.isNotEmpty) {
    stderr.writeln('字段内容往返不等价的行：');
    for (final diff in roundTrip.fieldDiffs.take(10)) {
      stderr.writeln(diff);
    }
  }

  _reportOrderDrift(document);

  if (document.problems.isNotEmpty || roundTrip.fieldDiffs.isNotEmpty) {
    stderr.writeln('\n存在未解决问题，未写入碎片。');
    exitCode = 1;
    return;
  }

  if (!apply) {
    stdout.writeln('\n预演完成。加 --apply 才会写入 $backlogFragmentDir/。');
    return;
  }

  _writeFragments(document);
}

_LegacyDocument _parseLegacy(String text) {
  final lines = text.split('\n');
  final rows = <_LegacyRow>[];
  final dataLines = <int, String>{};
  final problems = <String>[];
  final sectionsSeen = <BacklogKind>{};

  BacklogSectionSpec? spec;
  var sawHeader = false;

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    final lineNumber = index + 1;

    if (line.startsWith('## ')) {
      spec = _specForHeading(line);
      if (spec != null) sectionsSeen.add(spec.kind);
      sawHeader = false;
      continue;
    }
    if (spec == null || !line.startsWith('|') || !line.endsWith('|')) continue;

    final cells = _cells(line);
    if (!sawHeader) {
      sawHeader = true;
      if (!_sameCells(cells, spec.headerCells)) {
        problems.add(
          '第 $lineNumber 行：${spec.heading} 的表头与预期不符，'
          '预期 ${spec.headerCells.join(' / ')}，实际 ${cells.join(' / ')}',
        );
      }
      continue;
    }
    if (cells.every(_separatorCell.hasMatch)) continue;
    if (cells.isNotEmpty && cells.first == emptySectionPlaceholder) continue;

    final parsed = entryFromRowCells(spec, cells);
    if (parsed == null) {
      problems.add('第 $lineNumber 行：无法解析成${spec.kind.label}条目：$line');
      continue;
    }
    rows.add(_LegacyRow(lineNumber: lineNumber, spec: spec, entry: parsed));
    dataLines[lineNumber] = parsed.id;
  }

  final seen = <String>{};
  for (final row in rows) {
    if (!seen.add(row.entry.id)) {
      problems.add('${row.entry.id}：编号在旧表中重复出现');
    }
  }

  return _LegacyDocument(
    lines: lines,
    rows: rows,
    dataLineNumbers: dataLines,
    problems: problems,
    sectionsSeen: sectionsSeen,
  );
}

BacklogSectionSpec? _specForHeading(String heading) {
  for (final spec in backlogSections) {
    if (spec.heading == heading) return spec;
  }
  return null;
}

List<String> _cells(String line) => line
    .substring(1, line.length - 1)
    .split('|')
    .map((cell) => cell.trim())
    .toList();

bool _sameCells(List<String> a, List<String> b) =>
    a.length == b.length &&
    List<int>.generate(a.length, (i) => i).every((i) => a[i] == b[i]);

/// 往返比对结果：字段差异判红，纯空白差异只提示。
final class _RoundTrip {
  const _RoundTrip(this.fieldDiffs, this.whitespaceDiffs);

  final List<String> fieldDiffs;
  final List<String> whitespaceDiffs;
}

/// 原位重渲：除条目行外全部逐字复制，条目行换成碎片渲染出的行，再和输入比对。
///
/// 逐字节相等是通过；只有单元格内外的空白排布不同（拆分后逐字段相等）算无语义
/// 差异，只提示不判红；任何字段内容差异一律判红。
_RoundTrip _roundTrip(_LegacyDocument document) {
  final byId = <String, BacklogEntry>{
    for (final row in document.rows) row.entry.id: row.entry,
  };
  final fieldDiffs = <String>[];
  final whitespaceDiffs = <String>[];

  for (var index = 0; index < document.lines.length; index++) {
    final lineNumber = index + 1;
    final id = document.dataLineNumbers[lineNumber];
    if (id == null) continue;
    final source = document.lines[index];
    final rendered = byId[id]!.renderRowLine();
    if (rendered == source) continue;
    if (_sameCells(_cells(source.trim()), byId[id]!.rowCells())) {
      whitespaceDiffs.add('  第 $lineNumber 行（$id）：仅单元格空白排布不同');
      continue;
    }
    fieldDiffs.add(
      '  第 $lineNumber 行（$id）：\n'
      '    原文：$source\n'
      '    重渲：$rendered',
    );
  }
  return _RoundTrip(fieldDiffs, whitespaceDiffs);
}

void _reportOrderDrift(_LegacyDocument document) {
  for (final spec in backlogSections) {
    final sourceOrder = document.rows
        .where((row) => row.spec == spec)
        .map((row) => row.entry.id)
        .toList();
    final canonical = <String>[...sourceOrder]..sort();
    if (_sameCells(sourceOrder, canonical)) continue;
    final moved = <String>[
      for (var i = 0; i < sourceOrder.length; i++)
        if (sourceOrder[i] != canonical[i]) sourceOrder[i],
    ];
    stdout.writeln(
      '行序归一：${spec.heading.substring(3)} 的旧表行序不是编号升序，'
      '碎片视图会按编号排序（受影响编号：${moved.join('、')}）。'
      '字段内容不受影响。',
    );
  }
}

void _writeFragments(_LegacyDocument document) {
  final directory = Directory(backlogFragmentDir);
  directory.createSync(recursive: true);

  final wanted = <String>{};
  var written = 0;
  var unchanged = 0;
  for (final row in document.rows) {
    wanted.add(row.entry.id);
    final file = File('$backlogFragmentDir/${row.entry.id}.md');
    final content = row.entry.renderFragment();
    if (file.existsSync() && file.readAsStringSync() == content) {
      unchanged++;
      continue;
    }
    file.writeAsStringSync(content);
    written++;
  }

  final removed = <String>[];
  for (final file in directory.listSync().whereType<File>()) {
    final name = file.path.split(Platform.pathSeparator).last;
    if (!name.endsWith('.md') || name == 'README.md') continue;
    final id = name.substring(0, name.length - 3);
    if (wanted.contains(id)) continue;
    file.deleteSync();
    removed.add(id);
  }

  stdout.writeln(
    '\n已写入 $backlogFragmentDir/：新增或更新 $written 个，未变 $unchanged 个'
    '${removed.isEmpty ? '' : '，删除 ${removed.length} 个（${removed.join('、')}）'}。',
  );
}
