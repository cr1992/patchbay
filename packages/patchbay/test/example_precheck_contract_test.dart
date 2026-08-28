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
        r'[ -n "$NESTED_GEN" ] && [ -n "$COVERED_GEN" ]; then',
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

  test('capture target retries only bounded dynamic remount failures', () {
    final String source = _examplePrecheck().readAsStringSync();
    const String homeStep = "check 'ui wait destination home'";
    const String catalogStep = "check 'catalog capture target available'";
    final int navigationHome = source.indexOf(homeStep);
    final int catalogCheck = source.indexOf(catalogStep);
    final int captureTarget = source.indexOf(
      "check_capture_target 'capture target'",
    );
    final int helper = source.indexOf('check_capture_target()');
    final int helperCatalog = source.indexOf(
      'example_session_cli --json catalog',
      helper,
    );
    final int helperCapture = source.indexOf(
      'example_session_cli --json --output "\$output_path" capture target',
      helper,
    );
    final int helperFrameWait = source.indexOf('wait_next_frame', helper);

    expect(navigationHome, isNonNegative);
    expect(catalogCheck, greaterThan(navigationHome));
    expect(captureTarget, greaterThan(catalogCheck));
    expect(helper, isNonNegative);
    expect(helperCatalog, greaterThan(helper));
    expect(helperCapture, greaterThan(helperCatalog));
    expect(helperFrameWait, greaterThan(helperCapture));
    expect(source, contains('local attempt=1 max_attempts=5'));
    expect(
      source,
      contains('uiTargetUnmounted|uiGenerationStale|captureTargetChanged'),
    );
    expect(source, isNot(contains('CARD_CAPTURE_GEN=')));
  });

  test('navigation waits for the capture key to be released before home', () {
    final String source = _examplePrecheck().readAsStringSync();
    const String detailsStep = "check 'ui wait destination details'";
    const String releaseStep =
        "check_catalog_target_unmounted 'catalog capture target released'";
    const String homeStep = "check 'navigation go home'";
    final int details = source.indexOf(detailsStep);
    final int release = source.indexOf(releaseStep);
    final int home = source.indexOf(homeStep);
    final int helper = source.indexOf('check_catalog_target_unmounted()');
    final int helperCatalog = source.indexOf(
      'example_session_cli --json catalog',
      helper,
    );
    final int helperFrameWait = source.indexOf('wait_next_frame', helper);

    expect(details, isNonNegative);
    expect(release, greaterThan(details));
    expect(home, greaterThan(release));
    expect(helper, isNonNegative);
    expect(helperCatalog, greaterThan(helper));
    expect(helperFrameWait, greaterThan(helperCatalog));
    expect(
      source,
      contains('local attempt=1 max_attempts=30 actual=0 target_state='),
    );
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
