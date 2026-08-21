// PB-041-01：pub.dev 评分预算门禁。
//
// 本脚本**只报告 pana 与 pub.dev 实际给出的分数**，不做任何本地启发式打分。
// 历史教训：早期版本用「文件是否存在」自行加减分并恒定输出 140/140，
// 与 pana 真实结果（当期满分 160）脱节，导致分支实际丢分却报 PASS。
//
// 两种口径：
//   默认        对工作树内的包跑当期 pana，要求每个 section 满分。
//   --published 发布后核对 pub.dev Scores API 的 grantedPoints == maxPoints。
//
// 任一环节拿不到真实分数一律 fail-closed，绝不降级为「假定满分」。
import 'dart:convert';
import 'dart:io';

/// 单个 pana section（如 "Pass static analysis"）的得分。
final class PanaSection {
  const PanaSection({
    required this.title,
    required this.grantedPoints,
    required this.maxPoints,
    required this.summary,
  });

  final String title;
  final int grantedPoints;
  final int maxPoints;
  final String summary;

  bool get isFullScore => grantedPoints >= maxPoints;
}

/// 一个包的评分结论。
final class PanaPackageCheck {
  const PanaPackageCheck({
    required this.name,
    required this.source,
    required this.maxPoints,
    required this.grantedPoints,
    required this.sections,
    required this.issues,
  });

  /// 拿不到真实分数时的 fail-closed 结论。
  factory PanaPackageCheck.unavailable(
    String name,
    String source,
    String reason,
  ) => PanaPackageCheck(
    name: name,
    source: source,
    maxPoints: 0,
    grantedPoints: 0,
    sections: const <PanaSection>[],
    issues: <String>[reason],
  );

  final String name;
  final String source;
  final int maxPoints;
  final int grantedPoints;
  final List<PanaSection> sections;
  final List<String> issues;

  /// 满分要求 maxPoints > 0：0/0 只可能来自「没拿到分数」，不算通过。
  bool get isFullScore =>
      maxPoints > 0 && grantedPoints >= maxPoints && issues.isEmpty;

  /// 丢分的 section，用于定位扣分点。
  List<PanaSection> get lostSections =>
      sections.where((s) => !s.isFullScore).toList();
}

final class PanaBudgetEvaluator {
  const PanaBudgetEvaluator();

  /// 发布顺序即依赖顺序，下游依赖上游。
  static const List<String> releasePackages = <String>[
    'patchbay',
    'patchbay_transport',
    'patchbay_cli',
    'patchbay_flutter',
  ];

  /// 解析 `pana --json` 的输出。满分口径完全取自 pana 自身的 maxPoints，
  /// 不在本地硬编码总分——pana 改版式时这里不会说谎。
  PanaPackageCheck parsePanaReport(String packageName, String panaJson) {
    final Map<String, Object?> data;
    try {
      data = jsonDecode(panaJson) as Map<String, Object?>;
    } on Object catch (e) {
      return PanaPackageCheck.unavailable(
        packageName,
        'pana',
        'Failed to parse pana JSON output: $e',
      );
    }

    final report = data['report'] as Map<String, Object?>?;
    final rawSections = report?['sections'] as List<Object?>?;
    if (rawSections == null || rawSections.isEmpty) {
      return PanaPackageCheck.unavailable(
        packageName,
        'pana',
        'pana output contains no report sections',
      );
    }

    final sections = <PanaSection>[];
    var granted = 0;
    var max = 0;
    for (final raw in rawSections) {
      final s = raw as Map<String, Object?>;
      final section = PanaSection(
        title: (s['title'] ?? 'unknown').toString(),
        grantedPoints: (s['grantedPoints'] as num?)?.toInt() ?? 0,
        maxPoints: (s['maxPoints'] as num?)?.toInt() ?? 0,
        summary: (s['summary'] ?? '').toString(),
      );
      sections.add(section);
      granted += section.grantedPoints;
      max += section.maxPoints;
    }

    final issues = <String>[
      for (final s in sections)
        if (!s.isFullScore) '${s.title}: ${s.grantedPoints}/${s.maxPoints}',
    ];

    return PanaPackageCheck(
      name: packageName,
      source: 'pana',
      maxPoints: max,
      grantedPoints: granted,
      sections: sections,
      issues: issues,
    );
  }

  /// 解析 pub.dev Scores API 响应（发布后核对用）。
  PanaPackageCheck parsePubScoreResponse(
    String packageName,
    String jsonResponse,
  ) {
    try {
      final data = jsonDecode(jsonResponse) as Map<String, Object?>;
      final grantedPoints = (data['grantedPoints'] as num?)?.toInt();
      final maxPoints = (data['maxPoints'] as num?)?.toInt();
      if (grantedPoints == null || maxPoints == null) {
        return PanaPackageCheck.unavailable(
          packageName,
          'pub.dev',
          'Score API response is missing grantedPoints/maxPoints',
        );
      }

      final issues = <String>[];
      final card = data['card'] as Map<String, Object?>?;
      if (card != null && card['errorMessage'] != null) {
        issues.add(card['errorMessage']!.toString());
      }
      if (grantedPoints < maxPoints) {
        issues.add('Granted points ($grantedPoints) < max points ($maxPoints)');
      }

      return PanaPackageCheck(
        name: packageName,
        source: 'https://pub.dev/packages/$packageName',
        maxPoints: maxPoints,
        grantedPoints: grantedPoints,
        sections: const <PanaSection>[],
        issues: issues,
      );
    } on Object catch (e) {
      return PanaPackageCheck.unavailable(
        packageName,
        'pub.dev',
        'Failed to parse score response: $e',
      );
    }
  }
}

/// 在 [packageDir] 上跑当期 pana，返回其 JSON 输出；失败返回 null。
String? _runPana(String packageDir, Duration timeout) {
  final ProcessResult result;
  try {
    result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['pub', 'global', 'run', 'pana', '--no-warning', '--json', '.'],
      workingDirectory: packageDir,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException catch (e) {
    stderr.writeln('  pana 启动失败：$e');
    return null;
  }

  final out = result.stdout as String;
  if (out.trim().isEmpty) {
    stderr.writeln('  pana 无输出（exit=${result.exitCode}）：');
    stderr.writeln('  ${result.stderr}');
    return null;
  }
  return out;
}

Future<String?> _fetchPubScore(String packageName) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse('https://pub.dev/api/packages/$packageName/score');
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('  pub.dev score API 返回 ${response.statusCode}');
      return null;
    }
    return await response.transform(utf8.decoder).join();
  } on Object catch (e) {
    stderr.writeln('  pub.dev score API 请求失败：$e');
    return null;
  } finally {
    client.close(force: true);
  }
}

void _printCheck(PanaPackageCheck check) {
  final status = check.isFullScore ? 'PASS' : 'FAIL';
  stdout.writeln(
    '[$status] ${check.name} '
    '(${check.grantedPoints}/${check.maxPoints} pts, 来源 ${check.source})',
  );
  for (final s in check.lostSections) {
    stdout.writeln('  - ${s.title}: ${s.grantedPoints}/${s.maxPoints}');
    for (final line in s.summary.split('\n')) {
      if (line.startsWith('INFO:') ||
          line.startsWith('WARNING:') ||
          line.startsWith('ERROR:')) {
        stdout.writeln('      $line');
      }
    }
  }
  for (final issue in check.issues) {
    if (check.lostSections.any((s) => issue.startsWith(s.title))) continue;
    stdout.writeln('  - $issue');
  }
}

Future<void> main(List<String> args) async {
  const evaluator = PanaBudgetEvaluator();
  final repoRoot = Directory.current.path;
  final published = args.contains('--published');

  final only = <String>[];
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--package') only.add(args[i + 1]);
  }
  final targets = only.isEmpty
      ? PanaBudgetEvaluator.releasePackages
      : PanaBudgetEvaluator.releasePackages
            .where(only.contains)
            .toList(growable: false);

  stdout.writeln('=== Pana Scoring Budget Verification (PB-041-01) ===');
  stdout.writeln(
    published ? '口径：pub.dev Scores API（发布后核对）' : '口径：对工作树内的包跑当期 pana（每包数分钟）',
  );

  final results = <PanaPackageCheck>[];
  for (final pkg in targets) {
    stdout.writeln('\n--- $pkg ---');
    if (published) {
      final body = await _fetchPubScore(pkg);
      results.add(
        body == null
            ? PanaPackageCheck.unavailable(
                pkg,
                'pub.dev',
                'Could not retrieve pub.dev score (fail-closed)',
              )
            : evaluator.parsePubScoreResponse(pkg, body),
      );
    } else {
      final dir = Directory('$repoRoot/packages/$pkg');
      if (!dir.existsSync()) {
        results.add(
          PanaPackageCheck.unavailable(
            pkg,
            'packages/$pkg',
            'Package directory does not exist',
          ),
        );
      } else {
        final output = _runPana(dir.path, const Duration(minutes: 15));
        results.add(
          output == null
              ? PanaPackageCheck.unavailable(
                  pkg,
                  'packages/$pkg',
                  'pana 未能产出分数（是否已 `dart pub global activate pana`？）'
                      '——fail-closed，不假定满分',
                )
              : evaluator.parsePanaReport(pkg, output),
        );
      }
    }
    _printCheck(results.last);
  }

  final failed = results.where((c) => !c.isFullScore).toList();
  if (failed.isNotEmpty) {
    stderr.writeln(
      '\nPana budget check FAILED: '
      '${failed.map((c) => c.name).join(', ')} 未达满分或未取到真实分数。',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '\n全部 ${results.length} 个发布包达成满分预算 '
    '(${results.first.grantedPoints}/${results.first.maxPoints})。',
  );
}
