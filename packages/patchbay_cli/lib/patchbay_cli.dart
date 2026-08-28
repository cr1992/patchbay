/// The canonical `patchbay_cli` library: run one CLI invocation, read its exit
/// code (PB-050-13, DG-050-07).
///
/// These two symbols are the entire public Dart surface of the CLI process.
/// Everything a run needs is named on the command line, and everything a run
/// answers is on stdout — `--json` prints a stable document, and a failure
/// prints the stable error envelope there instead. Scripts read that JSON; they
/// do not reach for the Dart classes behind it.
///
/// Embedding a Patchbay *connection* in Dart code is a different job with a
/// different, opt-in entry point: `package:patchbay_cli/patchbay_client.dart`.
library;

export 'src/cli.dart' show runPatchbayCli;
export 'src/result.dart' show PatchbayExitCode;
