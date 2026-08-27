import 'package:patchbay_cli/src/sensitive_input.dart';
import 'package:test/test.dart';

void main() {
  test('piped sensitive input does not touch terminal echo', () {
    final List<bool> writes = <bool>[];

    final String value = readSensitiveLine(
      hasTerminal: false,
      readLine: () => 'secret',
      readEchoMode: () => throw StateError('must not read echo mode'),
      writeEchoMode: writes.add,
      writeLineBreak: () {},
    );

    expect(value, 'secret');
    expect(writes, isEmpty);
  });

  test('TTY sensitive input disables echo and restores it', () {
    final List<bool> writes = <bool>[];
    var lineBreaks = 0;

    final String value = readSensitiveLine(
      hasTerminal: true,
      readLine: () => 'secret',
      readEchoMode: () => true,
      writeEchoMode: writes.add,
      writeLineBreak: () => lineBreaks += 1,
    );

    expect(value, 'secret');
    expect(writes, <bool>[false, true]);
    expect(lineBreaks, 1);
  });

  test('TTY sensitive input fails closed when echo cannot be disabled', () {
    expect(
      () => readSensitiveLine(
        hasTerminal: true,
        readLine: () => 'must-not-be-read',
        readEchoMode: () => true,
        writeEchoMode: (_) => throw StateError('unsupported'),
        writeLineBreak: () {},
      ),
      throwsA(
        isA<PatchbaySensitiveInputException>().having(
          (PatchbaySensitiveInputException error) => error.code,
          'code',
          'terminalEchoControlFailed',
        ),
      ),
    );
  });
}
