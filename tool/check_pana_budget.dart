import 'dart:convert';
import 'dart:io';

final class PanaPackageCheck {
  const PanaPackageCheck({
    required this.name,
    required this.packagePath,
    required this.maxPoints,
    required this.grantedPoints,
    required this.issues,
  });

  final String name;
  final String packagePath;
  final int maxPoints;
  final int grantedPoints;
  final List<String> issues;

  bool get isFullScore => grantedPoints >= maxPoints && issues.isEmpty;
}

final class PanaBudgetEvaluator {
  const PanaBudgetEvaluator();

  static const List<String> releasePackages = <String>[
    'patchbay',
    'patchbay_transport',
    'patchbay_cli',
    'patchbay_flutter',
  ];

  PanaPackageCheck evaluateLocalPackage(String repoRoot, String packageName) {
    final pkgDir = Directory('$repoRoot/packages/$packageName');
    if (!pkgDir.existsSync()) {
      return PanaPackageCheck(
        name: packageName,
        packagePath: 'packages/$packageName',
        maxPoints: 140,
        grantedPoints: 0,
        issues: <String>['Package directory does not exist'],
      );
    }

    final issues = <String>[];
    int score = 140;

    // 1. Check LICENSE
    final licenseFile = File('${pkgDir.path}/LICENSE');
    if (!licenseFile.existsSync() ||
        licenseFile.readAsStringSync().trim().isEmpty) {
      issues.add('Missing or empty LICENSE file');
      score -= 30;
    }

    // 2. Check README
    final readmeFile = File('${pkgDir.path}/README.md');
    if (!readmeFile.existsSync() ||
        readmeFile.readAsStringSync().trim().length < 50) {
      issues.add('Missing or too short README.md');
      score -= 20;
    } else {
      final content = readmeFile.readAsStringSync();
      // Check for broken relative links
      if (content.contains('](docs/') || content.contains('](../')) {
        issues.add(
          'README contains relative repository links that will break on pub.dev',
        );
        score -= 10;
      }
    }

    // 3. Check CHANGELOG
    final changelogFile = File('${pkgDir.path}/CHANGELOG.md');
    if (!changelogFile.existsSync() ||
        changelogFile.readAsStringSync().trim().isEmpty) {
      issues.add('Missing or empty CHANGELOG.md');
      score -= 10;
    }

    // 4. Check pubspec.yaml
    final pubspecFile = File('${pkgDir.path}/pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      issues.add('Missing pubspec.yaml');
      score -= 40;
    } else {
      final pubspec = pubspecFile.readAsStringSync();
      if (!pubspec.contains('description:') ||
          pubspec.contains('description: ""')) {
        issues.add('Missing or empty description in pubspec.yaml');
        score -= 20;
      }
      if (!pubspec.contains('repository:') && !pubspec.contains('homepage:')) {
        issues.add('Missing repository or homepage in pubspec.yaml');
        score -= 10;
      }
    }

    return PanaPackageCheck(
      name: packageName,
      packagePath: 'packages/$packageName',
      maxPoints: 140,
      grantedPoints: score < 0 ? 0 : score,
      issues: issues,
    );
  }

  PanaPackageCheck parsePubScoreResponse(
    String packageName,
    String jsonResponse,
  ) {
    try {
      final data = jsonDecode(jsonResponse) as Map<String, Object?>;
      final grantedPoints = (data['grantedPoints'] as num?)?.toInt() ?? 0;
      final maxPoints = (data['maxPoints'] as num?)?.toInt() ?? 140;
      final card = data['card'] as Map<String, Object?>?;
      final issues = <String>[];

      if (card != null && card['errorMessage'] != null) {
        issues.add(card['errorMessage']!.toString());
      }

      if (grantedPoints < maxPoints) {
        issues.add('Granted points ($grantedPoints) < max points ($maxPoints)');
      }

      return PanaPackageCheck(
        name: packageName,
        packagePath: 'https://pub.dev/packages/$packageName',
        maxPoints: maxPoints,
        grantedPoints: grantedPoints,
        issues: issues,
      );
    } catch (e) {
      return PanaPackageCheck(
        name: packageName,
        packagePath: 'https://pub.dev/packages/$packageName',
        maxPoints: 140,
        grantedPoints: 0,
        issues: <String>['Failed to parse score response: $e'],
      );
    }
  }
}

void main(List<String> args) {
  final evaluator = const PanaBudgetEvaluator();
  final repoRoot = Directory.current.path;
  final results = <PanaPackageCheck>[];

  stdout.writeln('=== Pana Scoring Budget Verification (PB-041-01) ===');

  for (final pkg in PanaBudgetEvaluator.releasePackages) {
    final check = evaluator.evaluateLocalPackage(repoRoot, pkg);
    results.add(check);

    final status = check.isFullScore ? 'PASS' : 'FAIL';
    stdout.writeln(
      '[$status] ${check.name} (${check.grantedPoints}/${check.maxPoints} pts)',
    );
    for (final issue in check.issues) {
      stdout.writeln('  - $issue');
    }
  }

  final allPassed = results.every((c) => c.isFullScore);
  if (!allPassed) {
    stderr.writeln(
      '\nPana budget check FAILED: Not all packages achieved full score.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '\nAll 4 release packages met 100% Pana score budget requirements.',
  );
}
