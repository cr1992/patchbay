import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('committed protocol CLI registration is current', () async {
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'tool/protocol_cli_codegen.dart', '--check'],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
