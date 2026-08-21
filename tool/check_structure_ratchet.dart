import 'dart:io';

const int _maxProdLineBudget = 800;
const int _maxTestLineBudget = 1000;
const int _modularizedTargetBudget = 600;

final class PackageRule {
  const PackageRule({required this.name, required this.dirPath});

  final String name;
  final String dirPath;
}

const List<PackageRule> _packages = <PackageRule>[
  PackageRule(name: 'patchbay', dirPath: 'packages/patchbay'),
  PackageRule(name: 'patchbay_cli', dirPath: 'packages/patchbay_cli'),
  PackageRule(name: 'patchbay_flutter', dirPath: 'packages/patchbay_flutter'),
  PackageRule(
    name: 'patchbay_transport',
    dirPath: 'packages/patchbay_transport',
  ),
];

void main(List<String> args) {
  final bool verbose = args.contains('--verbose');
  final List<String> failures = <String>[];
  final List<String> notices = <String>[];

  int totalProdFiles = 0;
  int totalTestFiles = 0;
  int maxProdLines = 0;
  String maxProdFile = '';
  int maxTestLines = 0;
  String maxTestFile = '';

  for (final pkg in _packages) {
    final libDir = Directory('${pkg.dirPath}/lib');
    if (libDir.existsSync()) {
      for (final file in libDir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;

        final isGenerated = file.path.endsWith('.g.dart');
        final relativePath = file.path;
        final lines = file.readAsLinesSync();
        final lineCount = lines.length;

        if (!isGenerated) {
          totalProdFiles += 1;
          if (lineCount > maxProdLines) {
            maxProdLines = lineCount;
            maxProdFile = relativePath;
          }

          // Rule 1: Non-generated prod files must not exceed 800 lines
          if (lineCount > _maxProdLineBudget) {
            failures.add(
              '$relativePath: $lineCount lines exceeds production limit of $_maxProdLineBudget lines',
            );
          } else if (lineCount > _modularizedTargetBudget) {
            notices.add(
              '$relativePath: $lineCount lines (target <= $_modularizedTargetBudget)',
            );
          }

          // Rule 2: No hand-written part directives in production code
          for (var i = 0; i < lines.length; i++) {
            final trimmed = lines[i].trim();
            if (trimmed.startsWith('part ') && !trimmed.contains('.g.dart')) {
              failures.add(
                '$relativePath:${i + 1}: hand-written `part` directive forbidden',
              );
            }
            if (trimmed.startsWith('part of ') &&
                !relativePath.endsWith('.g.dart')) {
              failures.add(
                '$relativePath:${i + 1}: hand-written `part of` directive forbidden',
              );
            }
          }
        }

        // Rule 3: Cross-package src/ imports are forbidden
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trim();
          if (trimmed.startsWith('import ') || trimmed.startsWith('export ')) {
            for (final otherPkg in _packages) {
              if (otherPkg.name == pkg.name) continue;
              final forbiddenPrefix = "import 'package:${otherPkg.name}/src/";
              final forbiddenExport = "export 'package:${otherPkg.name}/src/";
              if (trimmed.startsWith(forbiddenPrefix) ||
                  trimmed.startsWith(forbiddenExport)) {
                failures.add(
                  '$relativePath:${i + 1}: cross-package private import from ${otherPkg.name}/src/ is forbidden',
                );
              }
            }
          }
        }
      }
    }

    final testDir = Directory('${pkg.dirPath}/test');
    if (testDir.existsSync()) {
      for (final file in testDir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final relativePath = file.path;
        final lines = file.readAsLinesSync();
        final lineCount = lines.length;

        totalTestFiles += 1;
        if (lineCount > maxTestLines) {
          maxTestLines = lineCount;
          maxTestFile = relativePath;
        }

        // Rule 4: Test files must not exceed 1000 lines
        if (lineCount > _maxTestLineBudget) {
          failures.add(
            '$relativePath: $lineCount lines exceeds test limit of $_maxTestLineBudget lines',
          );
        }
      }
    }
  }

  if (verbose || notices.isNotEmpty) {
    for (final notice in notices) {
      stdout.writeln('  [notice] $notice');
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln(
      'Structure ratchet check FAILED (${failures.length} issues):',
    );
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'structure ratchet check passed '
    '($totalProdFiles prod files [max: $maxProdFile @ $maxProdLines <= $_maxProdLineBudget], '
    '$totalTestFiles test files [max: $maxTestFile @ $maxTestLines <= $_maxTestLineBudget])',
  );
}
