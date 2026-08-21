import 'dart:io';

final class FinalizeItem {
  const FinalizeItem({
    required this.id,
    required this.title,
    required this.status,
    required this.action,
    required this.reason,
  });

  final String id;
  final String title;
  final String status;
  final String action; // 'ARCHIVE', 'DEFER', 'BLOCK'
  final String reason;
}

final class ReleaseFinalizePlan {
  const ReleaseFinalizePlan({
    required this.version,
    required this.items,
    required this.canApply,
    required this.blockingReasons,
  });

  final String version;
  final List<FinalizeItem> items;
  final bool canApply;
  final List<String> blockingReasons;
}

final class ReleaseFinalizer {
  const ReleaseFinalizer();

  ReleaseFinalizePlan generatePlan({
    required String repoRoot,
    required String version,
    bool allowDefer = false,
  }) {
    final backlogFile = File('$repoRoot/docs/backlog.md');
    final releaseFile = File('$repoRoot/docs/releases/$version.md');

    if (!backlogFile.existsSync() || !releaseFile.existsSync()) {
      return ReleaseFinalizePlan(
        version: version,
        items: const <FinalizeItem>[],
        canApply: false,
        blockingReasons: <String>[
          if (!backlogFile.existsSync()) 'docs/backlog.md does not exist',
          if (!releaseFile.existsSync()) 'docs/releases/$version.md does not exist',
        ],
      );
    }

    final lines = backlogFile.readAsLinesSync();
    final items = <FinalizeItem>[];
    final blockingReasons = <String>[];

    for (final line in lines) {
      if (!line.startsWith('| PB-')) continue;
      final parts = line.split('|').map((s) => s.trim()).toList();
      if (parts.length < 7) continue;

      final id = parts[1];
      final title = parts[2];
      final targetVersion = parts[4];
      final status = parts[5];

      if (targetVersion == version) {
        if (status == '已验证') {
          items.add(
            FinalizeItem(
              id: id,
              title: title,
              status: status,
              action: 'ARCHIVE',
              reason: 'Verified and ready to be archived',
            ),
          );
        } else if (allowDefer) {
          items.add(
            FinalizeItem(
              id: id,
              title: title,
              status: status,
              action: 'DEFER',
              reason: 'Explicitly deferred to next cycle',
            ),
          );
        } else {
          items.add(
            FinalizeItem(
              id: id,
              title: title,
              status: status,
              action: 'BLOCK',
              reason: 'Unverified item ($status) cannot be finalized without --allow-defer',
            ),
          );
          blockingReasons.add(
            'Item $id is "$status" and has no completed verification evidence',
          );
        }
      }
    }

    return ReleaseFinalizePlan(
      version: version,
      items: items,
      canApply: blockingReasons.isEmpty,
      blockingReasons: blockingReasons,
    );
  }

  bool applyPlan({
    required String repoRoot,
    required ReleaseFinalizePlan plan,
  }) {
    if (!plan.canApply) return false;

    final backlogFile = File('$repoRoot/docs/backlog.md');
    final releaseFile = File('$repoRoot/docs/releases/${plan.version}.md');

    // 1. Update backlog.md
    final lines = backlogFile.readAsLinesSync();
    final newLines = <String>[];
    final archiveIds = plan.items
        .where((item) => item.action == 'ARCHIVE')
        .map((item) => item.id)
        .toSet();
    final deferIds = plan.items
        .where((item) => item.action == 'DEFER')
        .map((item) => item.id)
        .toSet();

    for (final line in lines) {
      if (!line.startsWith('| PB-')) {
        newLines.add(line);
        continue;
      }
      final parts = line.split('|').map((s) => s.trim()).toList();
      if (parts.length < 7) {
        newLines.add(line);
        continue;
      }

      final id = parts[1];
      if (archiveIds.contains(id)) {
        // Archived items removed from active backlog table
        continue;
      } else if (deferIds.contains(id)) {
        // Clears target version to "待排期"
        parts[4] = '-';
        parts[5] = '待排期';
        newLines.add('| ${parts.sublist(1, parts.length - 1).join(' | ')} |');
      } else {
        newLines.add(line);
      }
    }
    backlogFile.writeAsStringSync('${newLines.join('\n')}\n');

    // 2. Freeze releases/<version>.md status to 已发布
    if (releaseFile.existsSync()) {
      var content = releaseFile.readAsStringSync();
      content = content.replaceFirst('> 状态：规划中', '> 状态：已发布');
      content = content.replaceFirst('> 状态：RC', '> 状态：已发布');
      releaseFile.writeAsStringSync(content);
    }

    return true;
  }
}

void main(List<String> args) {
  final version = args.isNotEmpty && !args.first.startsWith('--') ? args.first : '0.4.1';
  final apply = args.contains('--apply');
  final allowDefer = args.contains('--allow-defer');

  final finalizer = const ReleaseFinalizer();
  final plan = finalizer.generatePlan(
    repoRoot: Directory.current.path,
    version: version,
    allowDefer: allowDefer,
  );

  stdout.writeln('=== Release Finalize Plan for $version (PB-041-02) ===\n');

  for (final item in plan.items) {
    stdout.writeln('[${item.action}] ${item.id} (${item.status}) - ${item.title}: ${item.reason}');
  }

  if (!plan.canApply) {
    stderr.writeln('\nFinalize plan cannot be applied:');
    for (final reason in plan.blockingReasons) {
      stderr.writeln('  - $reason');
    }
    exitCode = 1;
    return;
  }

  if (apply) {
    final success = finalizer.applyPlan(
      repoRoot: Directory.current.path,
      plan: plan,
    );
    if (success) {
      stdout.writeln('\nSuccessfully applied release finalize for $version.');
    } else {
      stderr.writeln('\nFailed to apply finalize plan.');
      exitCode = 1;
    }
  } else {
    stdout.writeln('\nPlan generated successfully. Run with --apply to execute.');
  }
}
