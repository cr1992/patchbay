// 规划文档一致性检查。
//
// 台账真源是 `docs/backlog.d/` 下的每条目一个碎片（见该目录 README）；
// `docs/backlog.md` 只剩说明与目录指引，不再承载条目行。碎片的结构性解析
// 住在根私有 repo-tooling 的 `tool/backlog_store.dart`，与 release_finalize 共用，
// 不进入四个发布包。
import 'dart:io';

import 'backlog_store.dart';

// PB-060-04：活跃版本不再是手写常量。
//
// 它由 `docs/releases/` 的状态派生：非 `已发布` 的计划恰好有一份，那一份就是活跃
// 版本。理由是漂移的成因就在"切换"这个动作上——常量、范围表和 backlog target 是
// 三处独立写入，任何一处忘了改，机检都看不出来。派生之后没有可忘的开关：计划状态
// 一变，对账基准立刻跟着变。
//
// 零个活跃计划是合法状态（刚 finalize 完、下一版还没启动），此时不做范围对账。
const _plannedPlanStatuses = <String>{'规划中', 'RC'};

/// `已发布` 允许带括号后缀——`release_finalize` 会写入欠证据计数。
const _publishedPlanStatusPrefix = '已发布';

/// 已发布版本上仍可保留的终态。
///
/// `已验证` 是完成；`待真机验收` 是实现完成、只差真机/接入方证据（finalize 的
/// EVIDENCE_PENDING 档）。其余状态挂在已发布版本上一定是时间语义漂移：条目要么真
/// 没做完——那它不该继续声称目标是一个已经发出去的版本——要么做完了却没回写状态。
/// 两种都得有人管，而此前没有任何机检位置会问这句。
const _terminalStatusesOnPublishedRelease = <String>{'已验证', '待真机验收'};

/// design-gate 在已发布版本上的终态。DG 的状态词表只有两个值，裁决完即终态。
const _terminalGateStatusesOnPublishedRelease = <String>{'已裁决'};

/// 版本计划里不允许出现的起草期瞬时事实。
///
/// 它们描述的是"写这份计划的那一刻某个分支上有什么"，几小时后就可能不成立；计划是
/// 范围真源，不是分支快照。词表刻意避开会与 `版本分支` 之类正常措辞撞子串的写法
/// （`本分支` 是 `版本分支` 的子串，因此只收带后缀的形态）。
const _transientDraftMarkers = <String>[
  '待裁决稿',
  '并行分支',
  '仓主口径',
  '本稿',
  '本分支 base',
  '本分支上',
];

final _planStatusPattern = RegExp(r'^> 状态：(.+)$', multiLine: true);
final _versionBranchPattern = RegExp(
  r'^> 版本分支：`dev/([^`]+)`[^\n]*',
  multiLine: true,
);
final _semverPattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?$');

/// 反引号包裹的 hex token——即提交 SHA 的常见写法。
///
/// 判据要求**同时**含 `a-f` 字母与数字。只要求含数字会把版本计划里天然存在的日期
/// （`20260831`）、字节数（`1048576`）和长编号一并判成 SHA；只要求含字母又会把
/// `deadbeef` 之外的普通英文词收进来。两者同时要求是把误报压到可接受的最简判据。
/// 代价是全字母短 SHA（`deadbee`）漏过——这是卫生检查而不是安全边界，漏一个不改变
/// 结论，误挡一次 CI 却要人来查，因此宁可漏。
final _backtickCommitToken = RegExp(r'`([a-f0-9]{7,40})`');
final _hexLetter = RegExp(r'[a-f]');
final _hexDigit = RegExp(r'[0-9]');

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
  final releaseDirectory = Directory(_releaseDirectoryPath);

  _validateAgentInstructionEntryPoints(failures);

  if (!indexFile.existsSync() || !releaseDirectory.existsSync()) {
    stderr.writeln('planning check must run from the repository root');
    exitCode = 1;
    return;
  }

  final plans = _loadReleasePlans(failures);
  final activePlan = _resolveActivePlan(plans, failures);
  if (activePlan != null) {
    _validateVersionStartupOrder(activePlan, plans, failures);
    _validateTransientDraftFacts(activePlan, failures);
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

  _validateTargetsResolveToPlans(
    entries: <BacklogEntry>[...pbEntries.values, ...dgEntries.values],
    plans: plans,
    failures: failures,
  );
  _validateNoResidualTargetOnPublishedRelease(
    entries: <BacklogEntry>[...pbEntries.values, ...dgEntries.values],
    plans: plans,
    failures: failures,
  );

  // 双向目标对账只对活跃版本做。已发布计划是版本史：它 scope 里的条目已经由
  // release_finalize 按设计从活跃 backlog 归档，缺 id 不是漂移。
  final releaseScope = activePlan == null
      ? const <String>{}
      : _releaseScope(activePlan, failures);
  if (activePlan != null) {
    final version = activePlan.version;
    final targeted = pbEntries.values
        .where((entry) => entry.target == version)
        .map((entry) => entry.id)
        .toSet();

    for (final id in targeted.difference(releaseScope)) {
      failures.add('$id: target is $version but item is missing from P0/P1/P2');
    }
    for (final id in releaseScope.difference(targeted)) {
      if (!pbEntries.containsKey(id)) {
        failures.add('$id: release scope references a missing backlog item');
      } else {
        failures.add(
          '$id: release scope includes item not targeted at $version',
        );
      }
    }
  }

  _validateProposalDirectory(
    pbIds: pbEntries.keys.toSet(),
    dgIds: dgEntries.keys.toSet(),
    plans: plans,
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
    '(active version ${activePlan?.version ?? 'none'}, '
    '${pbEntries.length} backlog items, ${dgEntries.length} design gates, '
    '${backlog.ofKind(BacklogKind.bug).length} defects, '
    '${releaseScope.length} release entries)',
  );
}

/// 版本计划目录（相对仓根）。
const _releaseDirectoryPath = 'docs/releases';

/// 一份版本计划的规划治理视图：版本号、状态、路径与正文。
final class _ReleasePlan {
  const _ReleasePlan({
    required this.version,
    required this.status,
    required this.path,
    required this.content,
  });

  final String version;
  final String status;
  final String path;
  final String content;

  bool get isPublished => status.startsWith(_publishedPlanStatusPrefix);
}

/// 读入 `docs/releases/` 下的全部版本计划。
///
/// 文件名即版本号——这让"计划存在"和"版本号合法"共用同一个判据，不必再在正文里
/// 维护第二份版本号。
List<_ReleasePlan> _loadReleasePlans(List<String> failures) {
  final files =
      Directory(_releaseDirectoryPath)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final plans = <_ReleasePlan>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    // 与 docs/proposals 的扫描同口径豁免：那边本就有 README，作者容易照搬约定，
    // 而"版本计划文件名必须是完整 SemVer"对一个 README 是误导性报错。
    if (name == 'README.md' || name == '_template.md') continue;
    final version = name.substring(0, name.length - '.md'.length);
    final path = '$_releaseDirectoryPath/$name';
    if (!_semverPattern.hasMatch(version)) {
      failures.add('$path: 版本计划文件名必须是完整 SemVer');
      continue;
    }
    final content = file.readAsStringSync();
    final status = _planStatusPattern.firstMatch(content)?.group(1)?.trim();
    if (status == null) {
      failures.add('$path: 缺少 `> 状态：` 行');
      continue;
    }
    if (!_plannedPlanStatuses.contains(status) &&
        !status.startsWith(_publishedPlanStatusPrefix)) {
      failures.add(
        '$path: 不支持的版本计划状态「$status」；'
        '只接受 ${_plannedPlanStatuses.join(' / ')} 或 '
        '$_publishedPlanStatusPrefix',
      );
      continue;
    }
    plans.add(
      _ReleasePlan(
        version: version,
        status: status,
        path: path,
        content: content,
      ),
    );
  }
  return plans;
}

/// 派生活跃版本：非已发布的计划恰好一份。
///
/// 零份是合法的版本间歇期。两份及以上一定是启动顺序被绕过——上一版还没发布就开了
/// 下一版，此时"范围真源是哪一份"没有答案，后面所有对账都失去基准，因此 fail-closed。
_ReleasePlan? _resolveActivePlan(
  List<_ReleasePlan> plans,
  List<String> failures,
) {
  final active = plans.where((plan) => !plan.isPublished).toList();
  if (active.isEmpty) return null;
  if (active.length > 1) {
    final names = active.map((plan) => plan.version).toList()..sort();
    failures.add(
      '同时存在 ${active.length} 份未发布版本计划（${names.join('、')}）：'
      '新版本必须等上一版发布后再启动，否则范围真源不唯一',
    );
    return null;
  }
  return active.single;
}

/// 版本启动顺序：`main -> dev/<SemVer> -> 范围/Proposal MR`。
///
/// 可机检的部分是两条：活跃计划必须按规范形态声明自己的版本分支从稳定 `main` 创建；
/// 活跃版本号必须严格大于每一个已发布版本。**不可机检的部分要说清**——本检查不验证
/// 声明里的 base SHA 确实是 `main` 的祖先（CI 常为浅克隆，拿不到 `main` 历史），
/// 因此它拦的是"声明缺失或声明了别的起点"，不是"确实从别处拉的但照抄了正确声明"。
void _validateVersionStartupOrder(
  _ReleasePlan active,
  List<_ReleasePlan> plans,
  List<String> failures,
) {
  // 声明行必须唯一。两行声明时，"按正则取一行、按前缀又取另一行"会让版本号校验和
  // 起点校验落在不同行上——一条误报、另一条漏检。先把数量钉住，后面只用同一次匹配。
  final declarationLines = active.content
      .split('\n')
      .where((line) => line.startsWith('> 版本分支：'))
      .toList();
  if (declarationLines.length > 1) {
    failures.add(
      '${active.path}: 出现 ${declarationLines.length} 行 `> 版本分支：` 声明；'
      '版本身份只能有一处',
    );
  }

  final match = _versionBranchPattern.firstMatch(active.content);
  if (match == null) {
    failures.add(
      '${active.path}: 活跃版本计划必须有 `> 版本分支：\\`dev/<SemVer>\\`` 声明行，'
      '写明版本分支从稳定 `main` 创建',
    );
  } else {
    if (match.group(1) != active.version) {
      failures.add(
        '${active.path}: 版本分支声明的是 `dev/${match.group(1)}`，'
        '与计划版本 ${active.version} 不一致',
      );
    }
    if (!match.group(0)!.contains('从稳定 `main`')) {
      failures.add(
        '${active.path}: 版本分支声明必须写明「从稳定 `main`」创建；'
        '范围与 Proposal MR 只能以版本分支为目标',
      );
    }
  }

  for (final plan in plans.where((plan) => plan.isPublished)) {
    if (_compareSemver(active.version, plan.version) <= 0) {
      failures.add(
        '${active.path}: 活跃版本 ${active.version} 不大于已发布版本 '
        '${plan.version}；版本必须从最新稳定 `main` 向前启动',
      );
    }
  }
}

/// 活跃计划不得夹带起草期的分支瞬时事实。
void _validateTransientDraftFacts(_ReleasePlan active, List<String> failures) {
  final lines = active.content.split('\n');
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    for (final marker in _transientDraftMarkers) {
      if (line.contains(marker)) {
        failures.add(
          '${active.path}:${index + 1}: 活跃版本计划不得记录起草期瞬时事实'
          '（命中「$marker」）；分支状态几小时后就可能不成立，'
          '计划是范围真源而不是分支快照',
        );
      }
    }
    // 提交 SHA 只允许出现在版本分支声明行——那一条是版本身份，写定后不再变。
    if (line.startsWith('> 版本分支：')) continue;
    for (final match in _backtickCommitToken.allMatches(line)) {
      final token = match.group(1)!;
      if (!token.contains(_hexLetter) || !token.contains(_hexDigit)) continue;
      failures.add(
        '${active.path}:${index + 1}: 活跃版本计划不得引用提交 SHA `$token`；'
        '除版本分支声明行外，固定 SHA 属候选验收证据，写进计划即刻过期',
      );
    }
  }
}

/// 条目的 `target` 必须解析到一份真实存在的版本计划。
///
/// 未排期用字面量 `—`。指向没有计划文件的版本号是范围漂移：那个版本既没有优先级表
/// 也没有退出条件，条目实际上停在一个不存在的承诺上。
void _validateTargetsResolveToPlans({
  required List<BacklogEntry> entries,
  required List<_ReleasePlan> plans,
  required List<String> failures,
}) {
  final known = plans.map((plan) => plan.version).toSet();
  for (final entry in entries) {
    final target = entry.target;
    if (target == null || target.isEmpty || target == unscheduledTarget) {
      continue;
    }
    if (!known.contains(target)) {
      failures.add(
        '${entry.id}: target $target 没有对应的 '
        '$_releaseDirectoryPath/$target.md 版本计划',
      );
    }
  }
}

/// 已发布版本上不得残留非终态 target。
///
/// 特性与 design-gate 各有自己的终态词表，因此按种类取判据——把 DG 塞进特性的终态集
/// 会让合规的 `已裁决` 全部误报，而漏掉 DG 又是真实覆盖洞：`DG` 碎片同样带 `target`。
void _validateNoResidualTargetOnPublishedRelease({
  required Iterable<BacklogEntry> entries,
  required List<_ReleasePlan> plans,
  required List<String> failures,
}) {
  final published = <String>{
    for (final plan in plans)
      if (plan.isPublished) plan.version,
  };
  for (final entry in entries) {
    final target = entry.target;
    if (target == null || !published.contains(target)) continue;
    final terminal = entry.kind == BacklogKind.designGate
        ? _terminalGateStatusesOnPublishedRelease
        : _terminalStatusesOnPublishedRelease;
    final status = entry.status ?? '';
    if (terminal.contains(status)) continue;
    failures.add(
      '${entry.id}: target $target 已发布，但状态是「$status」；'
      '已发布版本只允许保留终态条目（${terminal.join(' / ')}）——'
      '若实际延期，按延期流程把 target 清成 $unscheduledTarget',
    );
  }
}

/// SemVer 三段比较。预发布后缀不参与——本检查只判版本前进方向。
int _compareSemver(String left, String right) {
  final leftMatch = _semverPattern.firstMatch(left);
  final rightMatch = _semverPattern.firstMatch(right);
  if (leftMatch == null || rightMatch == null) return 0;
  for (var group = 1; group <= 3; group += 1) {
    final difference =
        int.parse(leftMatch.group(group)!) -
        int.parse(rightMatch.group(group)!);
    if (difference != 0) return difference;
  }
  return 0;
}

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

Set<String> _releaseScope(_ReleasePlan plan, List<String> failures) {
  final seen = <String, String>{};
  String? priority;

  for (final rawLine in plan.content.split('\n')) {
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
  required List<_ReleasePlan> plans,
  required List<String> failures,
}) {
  final publishedVersions = <String>{
    for (final plan in plans)
      if (plan.isPublished) plan.version,
  };
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
    // 已发布版本的 Proposal 是决策史：它引用的条目已由 release_finalize 按设计
    // 从活跃 backlog 归档，缺 id 不是漂移。只对活跃版本与 future 的 Proposal
    // 保持双向引用对账——口径与上方 scope 对账的已发布豁免一致。
    final segments = file.uri.pathSegments;
    final versionDirectory = segments.length >= 2
        ? segments[segments.length - 2]
        : '';
    if (publishedVersions.contains(versionDirectory)) continue;
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
