import 'package:test/test.dart';

import '../tool/check_pana_budget.dart';

/// 构造一份 pana `--json` 形态的报告。
String _panaJson(List<(String, int, int, String)> sections) {
  final body = sections
      .map(
        (s) =>
            '{"id":"x","title":"${s.$1}","grantedPoints":${s.$2},'
            '"maxPoints":${s.$3},"status":"passed","summary":"${s.$4}"}',
      )
      .join(',');
  return '{"report":{"sections":[$body]}}';
}

/// 当期 pana 满分构成（160 分制）。刻意不在实现里硬编码总分。
const List<(String, int, int, String)> _fullScoreSections = [
  ('Follow Dart file conventions', 30, 30, ''),
  ('Provide documentation', 20, 20, ''),
  ('Platform support', 20, 20, ''),
  ('Pass static analysis', 50, 50, ''),
  ('Support up-to-date dependencies', 40, 40, ''),
];

void main() {
  group('PanaBudgetEvaluator.parsePanaReport (PB-041-01)', () {
    const evaluator = PanaBudgetEvaluator();

    test('满分报告：总分取自 pana 自身的 maxPoints，不硬编码', () {
      final check = evaluator.parsePanaReport(
        'patchbay',
        _panaJson(_fullScoreSections),
      );

      expect(check.isFullScore, isTrue);
      expect(check.grantedPoints, 160);
      expect(check.maxPoints, 160);
      expect(check.issues, isEmpty);
      expect(check.lostSections, isEmpty);
    });

    test('静态分析扣分：判 FAIL 并定位到具体 section', () {
      final sections = [..._fullScoreSections];
      sections[3] = (
        'Pass static analysis',
        40,
        50,
        'INFO: Statements in an if should be enclosed in a block.',
      );

      final check = evaluator.parsePanaReport('patchbay', _panaJson(sections));

      expect(check.isFullScore, isFalse);
      expect(check.grantedPoints, 150);
      expect(check.maxPoints, 160);
      expect(check.lostSections.single.title, 'Pass static analysis');
      expect(check.issues, contains('Pass static analysis: 40/50'));
    });

    test('pana 满分口径变化时跟随，而不是拿旧总分当真', () {
      final check = evaluator.parsePanaReport(
        'patchbay',
        _panaJson(const [('Some future section', 200, 200, '')]),
      );

      expect(check.isFullScore, isTrue);
      expect(check.maxPoints, 200);
    });

    group('fail-closed：拿不到真实分数一律不算通过', () {
      test('输出不是 JSON', () {
        final check = evaluator.parsePanaReport('patchbay', 'not json at all');
        expect(check.isFullScore, isFalse);
        expect(check.issues.single, contains('Failed to parse pana JSON'));
      });

      test('report 缺失', () {
        final check = evaluator.parsePanaReport('patchbay', '{}');
        expect(check.isFullScore, isFalse);
        expect(check.issues.single, contains('no report sections'));
      });

      test('sections 为空数组不得被当成满分', () {
        final check = evaluator.parsePanaReport(
          'patchbay',
          '{"report":{"sections":[]}}',
        );
        expect(check.isFullScore, isFalse);
      });

      test('0/0 不是满分（回归：曾经的假阳性形态）', () {
        final check = evaluator.parsePanaReport(
          'patchbay',
          _panaJson(const [('Empty', 0, 0, '')]),
        );
        expect(check.grantedPoints, 0);
        expect(check.maxPoints, 0);
        expect(check.isFullScore, isFalse, reason: '0 >= 0 成立，但没有真实满分依据，必须判失败');
      });
    });
  });

  group('PanaBudgetEvaluator.parsePubScoreResponse (发布后核对)', () {
    const evaluator = PanaBudgetEvaluator();

    test('grantedPoints == maxPoints 才算通过', () {
      final check = evaluator.parsePubScoreResponse(
        'patchbay',
        '{"grantedPoints":160,"maxPoints":160,"likeCount":10}',
      );
      expect(check.isFullScore, isTrue);
      expect(check.grantedPoints, 160);
    });

    test('扣分与 card.errorMessage 都要冒泡', () {
      final check = evaluator.parsePubScoreResponse(
        'patchbay',
        '{"grantedPoints":110,"maxPoints":160,'
            '"card":{"errorMessage":"Package has analysis issues"}}',
      );
      expect(check.isFullScore, isFalse);
      expect(check.issues, contains('Package has analysis issues'));
      expect(check.issues, contains('Granted points (110) < max points (160)'));
    });

    test('字段缺失按 fail-closed 处理，而不是默认满分', () {
      final check = evaluator.parsePubScoreResponse('patchbay', '{}');
      expect(check.isFullScore, isFalse);
      expect(check.issues.single, contains('missing grantedPoints/maxPoints'));
    });
  });
}
