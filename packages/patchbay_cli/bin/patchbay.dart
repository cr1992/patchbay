import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';

/// Ends the process on the command's result instead of draining the isolate.
///
/// Giving up on an unresponsive App leaves behind a connection the CLI is no
/// longer waiting for, and the one that matters cannot be cancelled from here:
/// a VM Service WebSocket handshake against a frozen peer never completes, and
/// the socket lives inside `package:vm_service` where there is nothing to
/// close. Returning from `main` hands control to the event loop, which keeps
/// the process alive until the OS finally tears that connection down —
/// measured at 178 seconds against an Android App frozen by the vendor, long
/// after a 30-second budget had decided and printed its answer.
///
/// The decision *is* the result, so the process ends with it. Everything the
/// command had to finish — artifact writes, the response on stdout — is already
/// awaited by the time `runPatchbayCli` returns.
Future<void> main(List<String> arguments) async {
  final int code = await runPatchbayCli(arguments);
  // `exit` does not drain buffered output, and stdout is block-buffered when
  // it is a pipe — exactly how scripts read `--json`.
  await _flush(stdout);
  await _flush(stderr);
  exit(code);
}

/// Flushes without letting the flush itself decide the outcome.
///
/// A closed pipe makes this throw and an unreadable one could make it block;
/// neither may replace the exit code the command already earned.
Future<void> _flush(IOSink sink) async {
  try {
    await sink.flush().timeout(const Duration(seconds: 5));
  } on Object {
    // There is no channel left to report a broken channel on.
  }
}
