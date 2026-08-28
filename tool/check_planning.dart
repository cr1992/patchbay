// 规划文档一致性检查。
//
// 台账真源是 `docs/backlog.d/` 下的每条目一个碎片（见该目录 README）；
// `docs/backlog.md` 只剩说明与目录指引，不再承载条目行。碎片的结构性解析
// 住在 `packages/patchbay/tool/backlog_store.dart`——`release_finalize` 随包
// 发布且要读写同一份碎片，共享代码必须留在包内。
import 'dart:io';

import '../packages/patchbay/tool/backlog_store.dart';

const _activeVersion = '0.5.0';

// `待真机验收` 是发布收尾专用状态：`release_finalize` 按它把条目归进
// EVIDENCE_PENDING 档——实现已完成、只差真机/接入方证据，碎片保留不删，需显式
// `--allow-evidence-pending` 才放行；口径见 docs/release-checklist.md 第 10 节。
// 它由人在收尾前标注、由 finalize 消费，finalize 自己不写出这个词。此前它只活在
// finalize 与发版清单里而不在本词表，两个工具对同一份台账的合法取值判断相反；
// 收进词表即消除该分歧，不新增分类。
const _allowedBacklogStatuses = <String>{
  '待排期',
  '待裁决',
  '已排期',
  '实现中',
  '待真机验收',
  '已验证',
};

const _allowedGateStatuses = <String>{'待裁决', '已裁决'};

const _allowedProposalStatuses = <String>{'提案中', '已接受', '已否决', '已替代'};

final _pbPattern = RegExp(r'^PB-\d{3}-\d{2}$');
final _dgPattern = RegExp(r'^DG-\d{3}-\d{2}$');
final _proposalLinkPattern = RegExp(r'\]\((proposals/[^)]+\.md)\)');
final _strayEntryRow = RegExp(r'^\|\s*(?:PB|DG|BUG|DOC)-\d');

void main() {
  final failures = <String>[];
  final indexFile = File(backlogIndexPath);
  final releaseFile = File('docs/releases/$_activeVersion.md');

  _validateAgentInstructionEntryPoints(failures);

  if (!indexFile.existsSync() || !releaseFile.existsSync()) {
    stderr.writeln('planning check must run from the repository root');
    exitCode = 1;
    return;
  }

  final backlog = loadBacklog(Directory.current.path);
  failures.addAll(backlog.errors);

  // 入口文档一旦重新长出条目行，碎片化就白做了：并行 MR 会再次抢写同一个
  // 文件的相邻行。这里 fail-closed 拦住回潮。
  for (final line in indexFile.readAsLinesSync()) {
    if (_strayEntryRow.hasMatch(line.trim())) {
      failures.add('$backlogIndexPath: 条目行必须住在 $backlogFragmentDir/ 碎片里：$line');
    }
  }

  final pbEntries = <String, BacklogEntry>{
    for (final entry in backlog.ofKind(BacklogKind.feature)) entry.id: entry,
  };
  final dgEntries = <String, BacklogEntry>{
    for (final entry in backlog.ofKind(BacklogKind.designGate)) entry.id: entry,
  };

  for (final entry in backlog.entries) {
    final allowed = entry.kind == BacklogKind.designGate
        ? _allowedGateStatuses
        : _allowedBacklogStatuses;
    final status = entry.status;
    if (status != null && !allowed.contains(status)) {
      failures.add('${entry.id}: unsupported backlog status "$status"');
    }
  }

  for (final entry in pbEntries.values) {
    final proposalCell = entry.docsProposalCell;
    final proposalPaths = _proposalPaths(proposalCell);
    final gateIds = _idsIn(proposalCell, _dgPattern);
    if (entry.status == '待裁决' && proposalPaths.isEmpty) {
      failures.add('${entry.id}: 待裁决 item must link a Proposal');
    }
    if (entry.status == '待裁决' && gateIds.isEmpty) {
      failures.add('${entry.id}: 待裁决 item must reference a design gate');
    }
    _validateProposalLinks(
      ownerId: entry.id,
      proposalPaths: proposalPaths,
      failures: failures,
    );
    for (final gateId in gateIds) {
      if (!dgEntries.containsKey(gateId)) {
        failures.add('${entry.id}: references missing design gate $gateId');
      }
    }
  }

  for (final entry in dgEntries.values) {
    _validateProposalLinks(
      ownerId: entry.id,
      proposalPaths: _proposalPaths(entry.docsProposalCell),
      failures: failures,
    );
  }

  final releaseScope = _releaseScope(releaseFile, failures);
  // 已发布计划是版本史，scope 中的已交付条目已经由 release_finalize
  // 从活跃 backlog 归档。只对仍活跃的计划做双向目标对账，否则 finalize
  // 按设计归档后会让本检查稳定报“missing backlog item”。
  if (!_isPublishedRelease(releaseFile)) {
    final targeted = pbEntries.values
        .where((entry) => entry.target == _activeVersion)
        .map((entry) => entry.id)
        .toSet();

    for (final id in targeted.difference(releaseScope)) {
      failures.add(
        '$id: target is $_activeVersion but item is missing from P0/P1/P2',
      );
    }
    for (final id in releaseScope.difference(targeted)) {
      if (!pbEntries.containsKey(id)) {
        failures.add('$id: release scope references a missing backlog item');
      } else {
        failures.add(
          '$id: release scope includes item not targeted at $_activeVersion',
        );
      }
    }
  }

  _validateProposalDirectory(
    pbIds: pbEntries.keys.toSet(),
    dgIds: dgEntries.keys.toSet(),
    failures: failures,
  );

  if (failures.isNotEmpty) {
    stderr.writeln('planning consistency check failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'planning consistency check passed '
    '(${pbEntries.length} backlog items, ${dgEntries.length} design gates, '
    '${backlog.ofKind(BacklogKind.bug).length} defects, '
    '${releaseScope.length} release entries)',
  );
}

bool _isPublishedRelease(File releaseFile) => RegExp(
  r'^> 状态：已发布(?:（.+）)?$',
  multiLine: true,
).hasMatch(releaseFile.readAsStringSync());

void _validateAgentInstructionEntryPoints(List<String> failures) {
  final agents = File('AGENTS.md');
  if (!agents.existsSync() || agents.readAsStringSync().trim().isEmpty) {
    failures.add('AGENTS.md: missing canonical Agent instructions');
  }

  final claude = File('CLAUDE.md');
  if (!claude.existsSync()) {
    failures.add('CLAUDE.md: missing AGENTS.md import');
    return;
  }
  if (claude.readAsStringSync().trim() != '@AGENTS.md') {
    failures.add('CLAUDE.md: must contain only @AGENTS.md');
  }
}

Set<String> _releaseScope(File releaseFile, List<String> failures) {
  final seen = <String, String>{};
  String? priority;

  for (final rawLine in releaseFile.readAsLinesSync()) {
    final line = rawLine.trim();
    final priorityMatch = RegExp(r'^### (P[012])：').firstMatch(line);
    if (priorityMatch != null) {
      priority = priorityMatch.group(1);
      continue;
    }
    if (line.startsWith('### ')) priority = null;
    if (priority == null || !line.startsWith('|') || !line.endsWith('|')) {
      continue;
    }

    final cells = line
        .substring(1, line.length - 1)
        .split('|')
        .map((cell) => cell.trim())
        .toList();
    if (cells.isEmpty || !_pbPattern.hasMatch(cells.first)) continue;

    final id = cells.first;
    if (cells.length != 2) {
      failures.add(
        '$id: release scope row must contain only id and acceptance; '
        'titles belong to backlog',
      );
    }
    final previous = seen[id];
    if (previous != null) {
      failures.add('$id: appears in both $previous and $priority');
    } else {
      seen[id] = priority;
    }
  }
  return seen.keys.toSet();
}

Set<String> _proposalPaths(String cell) => _proposalLinkPattern
    .allMatches(cell)
    .map((match) => match.group(1)!)
    .toSet();

Set<String> _idsIn(String text, RegExp exactPattern) {
  final candidatePattern = exactPattern == _pbPattern
      ? RegExp(r'PB-\d{3}-\d{2}')
      : RegExp(r'DG-\d{3}-\d{2}');
  return candidatePattern
      .allMatches(text)
      .map((match) => match.group(0)!)
      .where(exactPattern.hasMatch)
      .toSet();
}

void _validateProposalLinks({
  required String ownerId,
  required Set<String> proposalPaths,
  required List<String> failures,
}) {
  for (final path in proposalPaths) {
    final file = File('docs/$path');
    if (!file.existsSync()) {
      failures.add('$ownerId: Proposal does not exist: docs/$path');
      continue;
    }
    if (!_idsIn(
      file.readAsStringSync(),
      ownerId.startsWith('PB-') ? _pbPattern : _dgPattern,
    ).contains(ownerId)) {
      failures.add('$ownerId: Proposal docs/$path does not declare this id');
    }
  }
}

void _validateProposalDirectory({
  required Set<String> pbIds,
  required Set<String> dgIds,
  required List<String> failures,
}) {
  final directory = Directory('docs/proposals');
  if (!directory.existsSync()) {
    failures.add('missing docs/proposals directory');
    return;
  }

  final files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.md'))
      .where((file) {
        final name = file.uri.pathSegments.last;
        return name != 'README.md' && name != '_template.md';
      });
  for (final file in files) {
    final content = file.readAsStringSync();
    final status = RegExp(
      r'^> 状态：(.+)$',
      multiLine: true,
    ).firstMatch(content)?.group(1)?.trim();
    if (status == null || !_allowedProposalStatuses.contains(status)) {
      failures.add('${file.path}: missing or unsupported Proposal status');
    }
    for (final id in _idsIn(content, _pbPattern)) {
      if (!pbIds.contains(id)) {
        failures.add('${file.path}: references missing backlog item $id');
      }
    }
    for (final id in _idsIn(content, _dgPattern)) {
      if (!dgIds.contains(id)) {
        failures.add('${file.path}: references missing design gate $id');
      }
    }
  }
}
