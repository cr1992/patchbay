import 'dart:io';

const _allowedBacklogStatuses = <String>{'待排期', '待裁决', '已排期', '实现中', '已验证'};

const _allowedProposalStatuses = <String>{'提案中', '已接受', '已否决', '已替代'};

final _pbPattern = RegExp(r'^PB-\d{3}-\d{2}$');
final _dgPattern = RegExp(r'^DG-\d{3}-\d{2}$');
final _proposalLinkPattern = RegExp(r'\]\((proposals/[^)]+\.md)\)');

void main() {
  final failures = <String>[];
  final backlogFile = File('docs/backlog.md');
  final releaseFile = File('docs/releases/0.4.0.md');

  if (!backlogFile.existsSync() || !releaseFile.existsSync()) {
    stderr.writeln('planning check must run from the repository root');
    exitCode = 1;
    return;
  }

  final backlogRows = _markdownRows(backlogFile);
  final pbRows = <String, List<String>>{};
  final dgRows = <String, List<String>>{};

  for (final row in backlogRows) {
    final id = row.first;
    if (_pbPattern.hasMatch(id)) {
      if (row.length != 6) {
        failures.add('$id: backlog row must have exactly 6 columns');
        continue;
      }
      if (pbRows.containsKey(id)) {
        failures.add('$id: duplicate backlog id');
      }
      pbRows[id] = row;

      final status = row[4];
      if (!_allowedBacklogStatuses.contains(status)) {
        failures.add('$id: unsupported backlog status "$status"');
      }

      final proposalPaths = _proposalPaths(row[5]);
      final gateIds = _idsIn(row[5], _dgPattern);
      if (status == '待裁决' && proposalPaths.isEmpty) {
        failures.add('$id: 待裁决 item must link a Proposal');
      }
      if (status == '待裁决' && gateIds.isEmpty) {
        failures.add('$id: 待裁决 item must reference a design gate');
      }
      _validateProposalLinks(
        ownerId: id,
        proposalPaths: proposalPaths,
        failures: failures,
      );
    } else if (_dgPattern.hasMatch(id)) {
      if (row.length != 5) {
        failures.add('$id: design-gate row must have exactly 5 columns');
        continue;
      }
      if (dgRows.containsKey(id)) {
        failures.add('$id: duplicate design-gate id');
      }
      dgRows[id] = row;
      _validateProposalLinks(
        ownerId: id,
        proposalPaths: _proposalPaths(row[4]),
        failures: failures,
      );
    }
  }

  for (final entry in pbRows.entries) {
    for (final gateId in _idsIn(entry.value[5], _dgPattern)) {
      if (!dgRows.containsKey(gateId)) {
        failures.add('${entry.key}: references missing design gate $gateId');
      }
    }
  }

  final releaseScope = _releaseScope(releaseFile, failures);
  final targeted = pbRows.entries
      .where((entry) => entry.value[3] == '0.4.0')
      .map((entry) => entry.key)
      .toSet();

  for (final id in targeted.difference(releaseScope)) {
    failures.add('$id: target is 0.4.0 but item is missing from P0/P1/P2');
  }
  for (final id in releaseScope.difference(targeted)) {
    if (!pbRows.containsKey(id)) {
      failures.add('$id: release scope references a missing backlog item');
    } else {
      failures.add('$id: release scope includes item not targeted at 0.4.0');
    }
  }

  _validateProposalDirectory(
    pbRows: pbRows,
    dgRows: dgRows,
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
    '(${pbRows.length} backlog items, ${dgRows.length} design gates, '
    '${releaseScope.length} release entries)',
  );
}

List<List<String>> _markdownRows(File file) {
  final rows = <List<String>>[];
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (!line.startsWith('|') || !line.endsWith('|')) continue;
    final cells = line
        .substring(1, line.length - 1)
        .split('|')
        .map((cell) => cell.trim())
        .toList();
    rows.add(cells);
  }
  return rows;
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
  required Map<String, List<String>> pbRows,
  required Map<String, List<String>> dgRows,
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
      if (!pbRows.containsKey(id)) {
        failures.add('${file.path}: references missing backlog item $id');
      }
    }
    for (final id in _idsIn(content, _dgPattern)) {
      if (!dgRows.containsKey(id)) {
        failures.add('${file.path}: references missing design gate $id');
      }
    }
  }
}
