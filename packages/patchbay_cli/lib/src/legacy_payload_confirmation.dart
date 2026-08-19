import 'dart:io';

/// Decides whether a legacy host's free-form payload **values** may be
/// persisted into a debug trace.
///
/// Old hosts answer without a response schema, so their payloads carry no
/// persistence metadata: the CLI cannot tell a harmless counter from a device
/// identifier. The default therefore records only field shapes, and storing
/// values requires an explicit decision from the operator.
///
/// The decision is deliberately **not** derived from the terminal alone.
/// `stdin.hasTerminal` is a poor proxy for "a human can answer a prompt": on
/// macOS a `</dev/null` stdin — the shape this repo's own automation
/// prescribes — is reported as `StdioType.terminal`, so keying the documented
/// escape hatch on that judgment made the hatch unreachable exactly where
/// automation needs it. An explicit switch is an answer the operator already
/// gave; it is honoured before the environment is inspected at all.
bool confirmLegacyPayloadPersistence({
  required bool includeRequested,
  required bool allowWithoutPrompt,
  required bool stdinTakenByCommand,
  required bool hasTerminal,
  required String? Function() readLine,
  required void Function(String prompt) writePrompt,
}) {
  if (!includeRequested) return false;
  if (stdinTakenByCommand) {
    throw const FormatException(
      '--include-legacy-payload cannot share stdin with command or direct '
      'credential input',
    );
  }
  // The explicit switch wins over any terminal judgment: it is the operator's
  // recorded decision, not a guess about the environment.
  if (allowWithoutPrompt) return true;
  if (!hasTerminal) {
    throw const FormatException(
      '--include-legacy-payload requires a TTY confirmation; automation '
      'must also pass --allow-non-tty-legacy-payload',
    );
  }
  writePrompt(
    'Legacy host payloads have no persistence metadata. Type INCLUDE to '
    'store their re-redacted values: ',
  );
  final String? confirmation = readLine();
  // Distinct from the non-TTY refusal above. Sharing one message cost real
  // debugging time: a prompt that reached end of input looks identical to a
  // stdin that was never interactive, so the reader cannot tell whether the
  // escape hatch was missing or simply never consulted.
  if (confirmation == null) {
    throw const FormatException(
      'legacy payload confirmation reached end of input before an answer; '
      'automation must pass --allow-non-tty-legacy-payload',
    );
  }
  if (confirmation != 'INCLUDE') {
    throw const FormatException('legacy payload confirmation refused');
  }
  return true;
}

/// Binds [confirmLegacyPayloadPersistence] to real process stdio.
bool confirmLegacyPayloadPersistenceFromStdio({
  required bool includeRequested,
  required bool allowWithoutPrompt,
  required bool stdinTakenByCommand,
}) => confirmLegacyPayloadPersistence(
  includeRequested: includeRequested,
  allowWithoutPrompt: allowWithoutPrompt,
  stdinTakenByCommand: stdinTakenByCommand,
  hasTerminal: stdin.hasTerminal,
  readLine: stdin.readLineSync,
  writePrompt: stderr.write,
);
