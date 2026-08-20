import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('nested gesture precheck is mandatory and verifies a visual change', () {
    final String source = _examplePrecheck().readAsStringSync();

    expect(
      source,
      contains(
        'ui wait semantics-mounted example.gesture.nested --timeout-ms 10000',
      ),
    );
    expect(
      source,
      contains(
        r'if [ -n "$SURFACE_GEN" ] && [ -n "$LIST_GEN" ] && '
        r'[ -n "$NESTED_GEN" ]; then',
      ),
    );
    expect(source, isNot(contains(r'if [ -n "$NESTED_GEN" ]; then')));
    expect(source, contains("doc['payload']['differenceRatio'] > 0"));
    expect(
      source.indexOf("check 'gesture drag 嵌套水平列表'"),
      lessThan(source.indexOf("check 'gesture fling 在列表面被接受'")),
      reason: 'the outer fling can scroll the nested target offscreen',
    );
  });

  test('capture target refreshes generation after navigation', () {
    final String source = _examplePrecheck().readAsStringSync();
    final int navigationHome = source.indexOf("check 'ui wait destination home'");
    final int catalogCheck = source.indexOf(
      "check 'catalog capture target available'",
    );
    final int generationRefresh = source.indexOf(
      'CARD_CAPTURE_GEN="\$(read_json',
    );
    final int captureTarget = source.indexOf("check 'capture target'");

    expect(navigationHome, isNonNegative);
    expect(catalogCheck, greaterThan(navigationHome));
    expect(generationRefresh, greaterThan(catalogCheck));
    expect(captureTarget, greaterThan(generationRefresh));
    expect(source, isNot(contains(r'if [ -n "$CARD_CAPTURE_GEN" ]; then')));
  });
}

File _examplePrecheck() {
  Directory directory = Directory.current.absolute;
  while (true) {
    final File candidate = File('${directory.path}/tool/example_precheck.sh');
    if (candidate.existsSync()) return candidate;
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('tool/example_precheck.sh not found from test cwd');
    }
    directory = parent;
  }
}
