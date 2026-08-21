import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production code respects line budgets, no part files, and encapsulation (PB-041-03)', () {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['run', 'tool/check_structure_ratchet.dart'],
      workingDirectory: Directory.current.path.endsWith('packages/patchbay')
          ? '../..'
          : Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'check_structure_ratchet failed:\n${result.stderr}\n${result.stdout}',
    );
    expect(result.stdout.toString(), contains('structure ratchet check passed'));
  });
}
