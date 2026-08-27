// `docs/backlog.d/` 碎片台账的解析、渲染与等价校验基元。
//
// 为什么住在包内 `tool/` 而不是仓根 `tool/`：`release_finalize` 随包发布
// （`bin/` 只做转发），它必须读写同一份碎片；共享代码一旦越出包根，pub 依赖方
// 就拿不到。仓根 `tool/check_planning.dart` 按相对路径引用本文件，
// 与既有 `tool/*.dart` 转发脚本跨目录相对引用是同一姿势。
//
// 本文件只依赖 `dart:io`，仓根没有 pubspec 也能被 `dart run` 直接执行。
import 'dart:io';

/// 碎片目录（相对仓根）。
const String backlogFragmentDir = 'docs/backlog.d';

/// 台账入口文档（相对仓根）。迁移后它只剩说明与目录指引，不再承载条目行。
const String backlogIndexPath = 'docs/backlog.md';

/// 未排期条目的目标版本字面量。表格一直用全角破折号，碎片沿用同一字面量。
const String unscheduledTarget = '—';

/// 空表占位单元格。渲染空章节时用它复刻既有表格形态。
const String emptySectionPlaceholder = '（暂无）';

/// 列标记：`#` 前缀表示该列取碎片正文的同名 `## 小节`。
const String colIdAndTitle = 'id+title';
const String colId = 'id';
const String colTitle = 'title';
const String colTarget = 'target';
const String colStatus = 'status';

final RegExp _targetPattern = RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$');
final RegExp _frontmatterField = RegExp(r'^([a-z][a-z0-9_-]*): (.*)$');
final RegExp _sectionHeading = RegExp(r'^## (.+)$');
final RegExp _markdownLink = RegExp(r'\]\(([^)\s]+)\)');
final RegExp _pbId = RegExp(r'^PB-\d{3}-\d{2}$');
final RegExp _dgId = RegExp(r'^DG-\d{3}-\d{2}$');
final RegExp _bugId = RegExp(r'^BUG-\d{8}-\d{2}$');
final RegExp _docId = RegExp(r'^DOC-\d{8}-\d{2}$');

/// 条目种类。种类不写进 frontmatter——它由编号前缀唯一决定，与 changelog.d
/// 「身份写在文件名里」保持同一惯例。
enum BacklogKind {
  bug('缺陷'),
  feature('特性'),
  docDebt('文档债'),
  designGate('design-gate');

  const BacklogKind(this.label);

  final String label;
}

/// 一个 markdown 章节的表格形态：标题、表头与列布局。
final class BacklogSectionSpec {
  const BacklogSectionSpec({
    required this.kind,
    required this.heading,
    required this.headerCells,
    required this.columns,
    required this.idPattern,
  });

  final BacklogKind kind;
  final String heading;
  final List<String> headerCells;

  /// 列布局。取值是 [colId] / [colTitle] / [colIdAndTitle] / [colTarget] /
  /// [colStatus]，或 `#<小节名>`（取碎片正文的同名 `## 小节`）。
  final List<String> columns;
  final RegExp idPattern;

  int get columnCount => headerCells.length;

  bool get hasTarget => columns.contains(colTarget);

  bool get hasStatus => columns.contains(colStatus);

  /// 碎片正文的 `## 小节` 名，按列顺序。
  List<String> get bodySections => <String>[
    for (final column in columns)
      if (column.startsWith('#')) column.substring(1),
  ];

  List<String> get fieldNames => <String>[
    colId,
    colTitle,
    if (hasTarget) colTarget,
    if (hasStatus) colStatus,
  ];

  String get separatorLine => '|${List.filled(columnCount, '---').join('|')}|';

  String get headerLine => renderRow(headerCells);

  /// 空表占位行，形态与既有表格逐字节一致（两列时是 `| （暂无） | |`）。
  String get placeholderLine =>
      '| $emptySectionPlaceholder${' |' * columnCount}';
}

/// 四个章节的表格契约。顺序即 `docs/backlog.md` 迁移前的章节顺序。
final List<BacklogSectionSpec> backlogSections = <BacklogSectionSpec>[
  BacklogSectionSpec(
    kind: BacklogKind.bug,
    heading: '## 缺陷',
    headerCells: <String>['条目', '动机 / 证据', '状态'],
    columns: <String>[colIdAndTitle, '#动机', colStatus],
    idPattern: _bugId,
  ),
  BacklogSectionSpec(
    kind: BacklogKind.feature,
    heading: '## 特性',
    headerCells: <String>['编号', '条目', '动机 / 出处', '目标版本', '状态', 'Proposal / 备注'],
    columns: <String>[colId, colTitle, '#动机', colTarget, colStatus, '#备注'],
    idPattern: _pbId,
  ),
  BacklogSectionSpec(
    kind: BacklogKind.docDebt,
    heading: '## 文档债（快赢，可随任意批次走）',
    headerCells: <String>['条目', '动机 / 出处'],
    columns: <String>[colIdAndTitle, '#动机'],
    idPattern: _docId,
  ),
  BacklogSectionSpec(
    kind: BacklogKind.designGate,
    heading: '## design-gate（需仓主裁决后动工）',
    headerCells: <String>['编号', '裁决点', '目标版本', '状态', 'Proposal'],
    columns: <String>[colId, colTitle, colTarget, colStatus, '#Proposal'],
    idPattern: _dgId,
  ),
];

BacklogSectionSpec? specForId(String id) {
  for (final spec in backlogSections) {
    if (spec.idPattern.hasMatch(id)) return spec;
  }
  return null;
}

BacklogSectionSpec specForKind(BacklogKind kind) =>
    backlogSections.firstWhere((spec) => spec.kind == kind);

/// 一条台账条目。frontmatter 字段与短列一一对应，长文本列住在正文小节。
final class BacklogEntry {
  const BacklogEntry({
    required this.id,
    required this.spec,
    required this.title,
    required this.sections,
    this.target,
    this.status,
    this.path = '',
  });

  final String id;
  final BacklogSectionSpec spec;
  final String title;

  /// 正文小节内容，**碎片形态**（仓内链接带 `../` 前缀）。
  final Map<String, String> sections;
  final String? target;
  final String? status;

  /// 碎片文件路径；内存构造时为空串。
  final String path;

  BacklogKind get kind => spec.kind;

  /// 取某个小节的**文档根形态**（链接相对 `docs/`），供既有校验直接复用。
  String docsSection(String name) => toDocsLinks(sections[name] ?? '');

  /// 最后一个正文小节的文档根形态：特性是「备注」，design-gate 是「Proposal」。
  String get docsProposalCell => docsSection(spec.bodySections.last);

  BacklogEntry copyWith({String? target, String? status}) => BacklogEntry(
    id: id,
    spec: spec,
    title: title,
    sections: sections,
    target: target ?? this.target,
    status: status ?? this.status,
    path: path,
  );

  /// 渲染成表格单元格（文档根形态）。
  List<String> rowCells() => <String>[
    for (final column in spec.columns)
      switch (column) {
        colIdAndTitle => '$id：$title',
        colId => id,
        colTitle => title,
        colTarget => target ?? unscheduledTarget,
        colStatus => status ?? '',
        _ => docsSection(column.substring(1)),
      },
  ];

  String renderRowLine() => renderRow(rowCells());

  /// 渲染成碎片文件内容。
  String renderFragment() {
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('$colId: $id')
      ..writeln('$colTitle: $title');
    if (spec.hasTarget) {
      buffer.writeln('$colTarget: ${target ?? unscheduledTarget}');
    }
    if (spec.hasStatus) buffer.writeln('$colStatus: ${status ?? ''}');
    buffer.writeln('---');
    for (final name in spec.bodySections) {
      buffer
        ..writeln()
        ..writeln('## $name')
        ..writeln()
        ..writeln(sections[name] ?? '');
    }
    return buffer.toString();
  }
}

/// 加载结果：解析成功的条目 + 结构性错误（已带文件名前缀）。
final class BacklogLoadResult {
  const BacklogLoadResult(this.entries, this.errors);

  final List<BacklogEntry> entries;
  final List<String> errors;

  Map<String, BacklogEntry> byId() => <String, BacklogEntry>{
    for (final entry in entries) entry.id: entry,
  };

  List<BacklogEntry> ofKind(BacklogKind kind) =>
      entries.where((entry) => entry.kind == kind).toList();
}

/// 读入 `<repoRoot>/docs/backlog.d/` 下的全部碎片。
///
/// 只做结构性判定（frontmatter 形态、必填字段、文件名与编号一致、单行小节、
/// 链接前缀）；状态词表、design-gate 对账等语义规则留给 `check_planning`。
BacklogLoadResult loadBacklog(String repoRoot) {
  final directory = Directory('$repoRoot/$backlogFragmentDir');
  if (!directory.existsSync()) {
    return BacklogLoadResult(const <BacklogEntry>[], <String>[
      '$backlogFragmentDir: 碎片目录不存在',
    ]);
  }

  final entries = <BacklogEntry>[];
  final errors = <String>[];
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .where((file) => _basename(file.path) != 'README.md')
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final name = _basename(file.path);
    final result = parseFragment(
      name: name,
      content: file.readAsStringSync(),
      path: '$backlogFragmentDir/$name',
    );
    errors.addAll(result.errors);
    entries.addAll(result.entries);
  }

  entries.sort((a, b) => a.id.compareTo(b.id));
  return BacklogLoadResult(entries, errors);
}

/// 解析单个碎片。`name` 是文件名（含 `.md`），用于校验文件名与编号一致。
BacklogLoadResult parseFragment({
  required String name,
  required String content,
  required String path,
}) {
  final errors = <String>[];
  void fail(String message) => errors.add('$path: $message');

  final lines = content.split('\n');
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    fail('碎片必须以 `---` frontmatter 开头');
    return BacklogLoadResult(const <BacklogEntry>[], errors);
  }

  final fields = <String, String>{};
  var cursor = 1;
  var closed = false;
  for (; cursor < lines.length; cursor++) {
    final line = lines[cursor].trimRight();
    if (line == '---') {
      closed = true;
      cursor++;
      break;
    }
    final match = _frontmatterField.firstMatch(line);
    if (match == null) {
      fail('frontmatter 只接受 `key: value` 单行字段，实际是「$line」');
      continue;
    }
    final key = match.group(1)!;
    if (fields.containsKey(key)) fail('frontmatter 字段 `$key` 重复');
    fields[key] = match.group(2)!.trim();
  }
  if (!closed) {
    fail('frontmatter 缺少结束的 `---`');
    return BacklogLoadResult(const <BacklogEntry>[], errors);
  }

  final id = fields[colId] ?? '';
  if (id.isEmpty) {
    fail('frontmatter 缺少 `id`');
    return BacklogLoadResult(const <BacklogEntry>[], errors);
  }
  if (name != '$id.md') {
    fail('文件名必须是 `$id.md`，与 frontmatter 的 `id` 一致');
  }
  final spec = specForId(id);
  if (spec == null) {
    fail('编号 `$id` 不属于任何已知前缀（BUG / PB / DOC / DG）');
    return BacklogLoadResult(const <BacklogEntry>[], errors);
  }

  for (final field in spec.fieldNames) {
    if ((fields[field] ?? '').isEmpty) {
      fail('${spec.kind.label}碎片缺少必填字段 `$field`');
    }
  }
  for (final key in fields.keys) {
    if (!spec.fieldNames.contains(key)) {
      fail(
        '${spec.kind.label}碎片不接受字段 `$key`；'
        '允许的字段是 ${spec.fieldNames.join(' / ')}',
      );
    }
  }
  final target = fields[colTarget];
  if (spec.hasTarget &&
      target != null &&
      target.isNotEmpty &&
      target != unscheduledTarget &&
      !_targetPattern.hasMatch(target)) {
    fail('`target` 只接受 SemVer 或 `$unscheduledTarget`，实际是「$target」');
  }

  final sections = _parseSections(
    lines.sublist(cursor),
    spec: spec,
    fail: fail,
  );
  _validateFragmentLinks(sections, fail);

  if (errors.isNotEmpty) {
    return BacklogLoadResult(const <BacklogEntry>[], errors);
  }

  return BacklogLoadResult(<BacklogEntry>[
    BacklogEntry(
      id: id,
      spec: spec,
      title: fields[colTitle]!,
      sections: sections,
      target: spec.hasTarget ? target : null,
      status: spec.hasStatus ? fields[colStatus] : null,
      path: path,
    ),
  ], errors);
}

Map<String, String> _parseSections(
  List<String> lines, {
  required BacklogSectionSpec spec,
  required void Function(String) fail,
}) {
  final collected = <String, List<String>>{};
  String? current;
  for (final raw in lines) {
    final line = raw.trimRight();
    final heading = _sectionHeading.firstMatch(line);
    if (heading != null) {
      current = heading.group(1)!.trim();
      if (collected.containsKey(current)) fail('小节 `## $current` 重复');
      collected[current] = <String>[];
      continue;
    }
    if (line.trim().isEmpty) continue;
    if (current == null) {
      fail('frontmatter 之后、第一个 `## 小节` 之前不允许有正文');
      continue;
    }
    collected[current]!.add(line);
  }

  final sections = <String, String>{};
  for (final name in spec.bodySections) {
    final body = collected.remove(name);
    if (body == null) {
      fail('${spec.kind.label}碎片缺少 `## $name` 小节');
      continue;
    }
    if (body.isEmpty) {
      fail('`## $name` 不能为空');
      continue;
    }
    if (body.length > 1) {
      fail(
        '`## $name` 必须只有一行——它渲染成表格的一个单元格；'
        '需要展开请写进 Proposal 或验证报告，并在此只留指针',
      );
      continue;
    }
    final cell = body.single.trim();
    if (cell.contains('|')) {
      fail('`## $name` 不能包含 `|`——它会破坏渲染出的表格行');
      continue;
    }
    sections[name] = cell;
  }
  for (final name in collected.keys) {
    fail(
      '${spec.kind.label}碎片不接受小节 `## $name`；'
      '允许的小节是 ${spec.bodySections.map((s) => '## $s').join(' / ')}',
    );
  }
  return sections;
}

void _validateFragmentLinks(
  Map<String, String> sections,
  void Function(String) fail,
) {
  for (final section in sections.entries) {
    for (final match in _markdownLink.allMatches(section.value)) {
      final target = match.group(1)!;
      if (isExternalLink(target) || target.startsWith('../')) continue;
      fail(
        '`## ${section.key}` 的仓内链接必须以 `../` 开头'
        '（碎片位于 `$backlogFragmentDir/`），实际是「$target」',
      );
    }
  }
}

/// 表格行渲染：`| a | b | c |`。
String renderRow(List<String> cells) => '| ${cells.join(' | ')} |';

/// 表格行解析：把一行的单元格还原成条目。与 [BacklogEntry.rowCells] 互逆——
/// 迁移脚本的往返等价证明就建立在这一对函数上。
///
/// 返回 `null` 表示这一行不规整（列数不符、编号缺失或不匹配前缀），
/// 调用方必须如实报告，不得静默丢弃。
BacklogEntry? entryFromRowCells(
  BacklogSectionSpec spec,
  List<String> cells, {
  String path = '',
}) {
  if (cells.length != spec.columnCount) return null;

  String? id;
  String? title;
  String? target;
  String? status;
  final sections = <String, String>{};

  for (var i = 0; i < spec.columns.length; i++) {
    final column = spec.columns[i];
    final cell = cells[i];
    switch (column) {
      case colIdAndTitle:
        final split = cell.indexOf('：');
        if (split <= 0) return null;
        id = cell.substring(0, split).trim();
        title = cell.substring(split + 1).trim();
      case colId:
        id = cell;
      case colTitle:
        title = cell;
      case colTarget:
        target = cell;
      case colStatus:
        status = cell;
      default:
        sections[column.substring(1)] = toFragmentLinks(cell);
    }
  }

  if (id == null || title == null || title.isEmpty) return null;
  if (!spec.idPattern.hasMatch(id)) return null;

  return BacklogEntry(
    id: id,
    spec: spec,
    title: title,
    sections: sections,
    target: spec.hasTarget ? target : null,
    status: spec.hasStatus ? status : null,
    path: path,
  );
}

/// 渲染某一章节的完整表格（表头 + 分隔行 + 按编号升序的条目行）。
List<String> renderSectionTable(
  BacklogSectionSpec spec,
  List<BacklogEntry> entries,
) {
  final rows = entries.where((entry) => entry.kind == spec.kind).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return <String>[
    spec.headerLine,
    spec.separatorLine,
    if (rows.isEmpty)
      spec.placeholderLine
    else
      for (final entry in rows) entry.renderRowLine(),
  ];
}

/// 按需渲染的完整表格视图（仅供阅读，不是真源）。
String renderBacklogView(List<BacklogEntry> entries) {
  final buffer = StringBuffer()
    ..writeln('# 问题与特性台账（渲染视图）')
    ..writeln()
    ..writeln(
      '> 本视图由 `dart run tool/backlog_render.dart` 从 '
      '`$backlogFragmentDir/` 渲染，**不是真源**，不要提交。'
      '条目真源是碎片文件，权责与维护规则见 `$backlogIndexPath`。',
    );
  for (final spec in backlogSections) {
    buffer
      ..writeln()
      ..writeln(spec.heading)
      ..writeln();
    for (final line in renderSectionTable(spec, entries)) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// 链接形态转换
//
// 表格活在 `docs/`，碎片活在 `docs/backlog.d/`，同一个仓内相对链接在两处差一
// 层 `../`。两个方向互为逆运算：docs → fragment 恒加一层，fragment → docs 恒
// 去一层；解析期又强制碎片里的仓内链接必须带 `../`，因此往返可证等价。
// ---------------------------------------------------------------------------

bool isExternalLink(String target) =>
    target.startsWith('http://') ||
    target.startsWith('https://') ||
    target.startsWith('mailto:') ||
    target.startsWith('#') ||
    target.startsWith('/');

/// `docs/` 相对 → 碎片相对。
String toFragmentLinks(String text) =>
    text.replaceAllMapped(_markdownLink, (match) {
      final target = match.group(1)!;
      return isExternalLink(target) ? match.group(0)! : '](../$target)';
    });

/// 碎片相对 → `docs/` 相对。
String toDocsLinks(String text) =>
    text.replaceAllMapped(_markdownLink, (match) {
      final target = match.group(1)!;
      if (isExternalLink(target)) return match.group(0)!;
      final stripped = target.startsWith('../') ? target.substring(3) : target;
      return ']($stripped)';
    });

String _basename(String path) =>
    path.split(Platform.pathSeparator).last.split('/').last;
