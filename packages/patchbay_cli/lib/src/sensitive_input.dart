import 'dart:io';

final class PatchbaySensitiveInputException implements Exception {
  const PatchbaySensitiveInputException(this.code);

  final String code;
}

/// Reads a secret from stdin without allowing an interactive terminal to echo.
///
/// Piped stdin is already non-echoing and is read directly. On a TTY we fail
/// closed when echo cannot be disabled; silently falling back would put the
/// secret into terminal scrollback and screen recordings.
String readSensitiveStdinLine() => readSensitiveLine(
  hasTerminal: stdin.hasTerminal,
  readLine: stdin.readLineSync,
  readEchoMode: () => stdin.echoMode,
  writeEchoMode: (bool value) => stdin.echoMode = value,
  writeLineBreak: stderr.writeln,
);

String readSensitiveLine({
  required bool hasTerminal,
  required String? Function() readLine,
  required bool Function() readEchoMode,
  required void Function(bool value) writeEchoMode,
  required void Function() writeLineBreak,
}) {
  if (!hasTerminal) return readLine() ?? '';

  late final bool previousEchoMode;
  try {
    previousEchoMode = readEchoMode();
    writeEchoMode(false);
  } on Object {
    throw const PatchbaySensitiveInputException('terminalEchoControlFailed');
  }

  try {
    return readLine() ?? '';
  } finally {
    try {
      writeEchoMode(previousEchoMode);
      writeLineBreak();
    } on Object {
      throw const PatchbaySensitiveInputException('terminalEchoRestoreFailed');
    }
  }
}
