// PB-041-02：两阶段发布收尾。
//
// 三档计划，缺一不可：
//   ARCHIVE           已验证，可从活跃 backlog 归档。
//   EVIDENCE_PENDING  实现已完成、只差真机/接入方验收证据——既不能归档冒充完成，
//                     也不该和「没动过」的条目混为一谈。
//   DEFER             真正延期到下一轮。
//
// 「实现中」永远不接受批量延期：要延必须逐条 `--defer-item` 点名，
// 避免一个开关把在做的事从版本里抹掉。
import 'dart:io';

/// backlog 状态列的取值。
const String statusVerified = '已验证';
const String statusEvidencePending = '待真机验收';
const String statusInProgress = '实现中';

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
  final String action; // 'ARCHIVE' | 'EVIDENCE_PENDING' | 'DEFER' | 'BLOCK'
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
    bool allowEvidencePending = false,
    Set<String> deferItems = const <String>{},
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
          if (!releaseFile.existsSync())
            'docs/releases/$version.md does not exist',
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

      if (targetVersion != version) continue;

      void add(String action, String reason, {String? blocking}) {
        items.add(
          FinalizeItem(
            id: id,
            title: title,
            status: status,
            action: action,
            reason: reason,
          ),
        );
        if (blocking != null) blockingReasons.add(blocking);
      }

      if (status == statusVerified) {
        add('ARCHIVE', '已验证，可归档');
      } else if (status == statusEvidencePending) {
        // 只差证据的条目单独成档：允许放行时也**不归档**，
        // 以免「未结真机验收」在 backlog 里消失后被当成已完成。
        if (allowEvidencePending) {
          add('EVIDENCE_PENDING', '实现完成，仍欠真机/接入方验收证据；保留在 backlog 不归档');
        } else {
          add(
            'BLOCK',
            '欠验收证据；确认要带着未结证据收尾请显式加 --allow-evidence-pending',
            blocking: '$id 状态为「$status」，真机/接入方验收证据尚未闭合',
          );
        }
      } else if (deferItems.contains(id)) {
        add('DEFER', '按 --defer-item 逐条点名延期');
      } else if (status == statusInProgress) {
        // 计划明确要求：不得批量删除「实现中」。
        add(
          'BLOCK',
          '「$statusInProgress」不接受批量延期，要延请用 --defer-item $id 点名',
          blocking: '$id 仍在实现中，未被逐条点名延期',
        );
      } else if (allowDefer) {
        add('DEFER', '延期到下一轮');
      } else {
        add(
          'BLOCK',
          '未完成条目（$status）需要 --allow-defer 才能延期',
          blocking: '$id 状态为「$status」，且未获准延期',
        );
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

    // 2. 冻结 releases/<version>.md 状态。仍有未结证据时不写「已发布」，
    //    否则版本文档会替未闭合的真机验收背书。
    final pending = plan.items
        .where((item) => item.action == 'EVIDENCE_PENDING')
        .toList();
    if (releaseFile.existsSync()) {
      var content = releaseFile.readAsStringSync();
      final frozen = pending.isEmpty
          ? '> 状态：已发布'
          : '> 状态：已发布（${pending.length} 项仍欠验收证据）';
      content = content.replaceFirst('> 状态：规划中', frozen);
      content = content.replaceFirst('> 状态：RC', frozen);
      if (pending.isNotEmpty) {
        content +=
            '\n\n## 仍欠验收证据\n\n'
            '以下条目实现已完成但真机/接入方验收证据未闭合，不计入本版已交付范围：\n\n'
            '${pending.map((i) => '- ${i.id} ${i.title}').join('\n')}\n';
      }
      releaseFile.writeAsStringSync(content);
    }

    return true;
  }
}

void main(List<String> args) {
  final version = args.isNotEmpty && !args.first.startsWith('--')
      ? args.first
      : '0.4.1';
  final apply = args.contains('--apply');
  final allowDefer = args.contains('--allow-defer');
  final allowEvidencePending = args.contains('--allow-evidence-pending');
  final deferItems = <String>{
    for (final arg in args)
      if (arg.startsWith('--defer-item=')) arg.split('=').last,
  };

  final finalizer = const ReleaseFinalizer();
  final plan = finalizer.generatePlan(
    repoRoot: Directory.current.path,
    version: version,
    allowDefer: allowDefer,
    allowEvidencePending: allowEvidencePending,
    deferItems: deferItems,
  );

  stdout.writeln('=== Release Finalize Plan for $version (PB-041-02) ===\n');

  for (final item in plan.items) {
    stdout.writeln(
      '[${item.action}] ${item.id} (${item.status}) - ${item.title}: ${item.reason}',
    );
  }

  final counts = <String, int>{};
  for (final item in plan.items) {
    counts[item.action] = (counts[item.action] ?? 0) + 1;
  }
  stdout.writeln(
    '\n分档汇总：已发布 ${counts['ARCHIVE'] ?? 0} 项 / '
    '仅缺证据 ${counts['EVIDENCE_PENDING'] ?? 0} 项 / '
    '已延期 ${counts['DEFER'] ?? 0} 项 / '
    '阻断 ${counts['BLOCK'] ?? 0} 项',
  );

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
    stdout.writeln(
      '\nPlan generated successfully. Run with --apply to execute.',
    );
  }
}
