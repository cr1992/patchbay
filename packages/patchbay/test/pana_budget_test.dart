import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/check_pana_budget.dart';

void main() {
  group('PanaBudgetEvaluator (PB-041-01)', () {
    const evaluator = PanaBudgetEvaluator();

    test('validates full score for compliant package structures', () {
      final tempDir = Directory.systemTemp.createTempSync('pana-test-');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final pkgDir = Directory('${tempDir.path}/packages/test_pkg')
        ..createSync(recursive: true);
      File('${pkgDir.path}/LICENSE').writeAsStringSync('BSD-3-Clause License');
      File('${pkgDir.path}/README.md').writeAsStringSync(
        '# Test Pkg\n\nThis is a compliant test package description with absolute links https://pub.dev.\n',
      );
      File(
        '${pkgDir.path}/CHANGELOG.md',
      ).writeAsStringSync('# Changelog\n\n## 1.0.0\n- Initial.\n');
      File('${pkgDir.path}/pubspec.yaml').writeAsStringSync('''
name: test_pkg
description: A test package for pana scoring evaluation.
version: 1.0.0
repository: https://github.com/cr1992/patchbay
environment:
  sdk: ">=3.0.0 <4.0.0"
''');

      final check = evaluator.evaluateLocalPackage(tempDir.path, 'test_pkg');
      expect(check.isFullScore, isTrue);
      expect(check.grantedPoints, 140);
      expect(check.issues, isEmpty);
    });

    test(
      'penalizes missing LICENSE, relative links in README, and missing repo',
      () {
        final tempDir = Directory.systemTemp.createTempSync('pana-test-');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final pkgDir = Directory('${tempDir.path}/packages/bad_pkg')
          ..createSync(recursive: true);
        // No LICENSE
        File('${pkgDir.path}/README.md').writeAsStringSync(
          '# Bad Pkg\n\nSee [guide](docs/guide.md) for details.\n',
        );
        File('${pkgDir.path}/CHANGELOG.md').writeAsStringSync('# Changelog\n');
        File('${pkgDir.path}/pubspec.yaml').writeAsStringSync('''
name: bad_pkg
version: 1.0.0
environment:
  sdk: ">=3.0.0 <4.0.0"
''');

        final check = evaluator.evaluateLocalPackage(tempDir.path, 'bad_pkg');
        expect(check.isFullScore, isFalse);
        expect(check.issues, anyElement(contains('Missing or empty LICENSE')));
        expect(check.issues, anyElement(contains('relative repository links')));
        expect(
          check.issues,
          anyElement(contains('Missing or empty description')),
        );
        expect(check.issues, anyElement(contains('Missing repository')));
        expect(check.grantedPoints, lessThan(100));
      },
    );

    test('parses pub.dev Score API response correctly', () {
      const fullScoreJson = '''
{
  "grantedPoints": 140,
  "maxPoints": 140,
  "likeCount": 10,
  "popularityScore": 0.8
}
''';
      final check = evaluator.parsePubScoreResponse('patchbay', fullScoreJson);
      expect(check.isFullScore, isTrue);
      expect(check.grantedPoints, 140);
      expect(check.maxPoints, 140);

      const penaltyJson = '''
{
  "grantedPoints": 110,
  "maxPoints": 140,
  "card": {
    "errorMessage": "Package has analysis issues"
  }
}
''';
      final failedCheck = evaluator.parsePubScoreResponse(
        'patchbay',
        penaltyJson,
      );
      expect(failedCheck.isFullScore, isFalse);
      expect(failedCheck.issues, contains('Package has analysis issues'));
    });
  });
}
