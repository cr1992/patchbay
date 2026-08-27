import 'dart:io';

/// Abstraction over platform process execution for testability and cross-platform consistency.
abstract interface class ProcessRunner {
  ProcessResult runSync(String executable, List<String> arguments);
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// Default [ProcessRunner] delegating directly to [Process].
final class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  ProcessResult runSync(String executable, List<String> arguments) =>
      Process.runSync(executable, arguments);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    mode: mode,
  );
}

/// Cross-platform process and filesystem permission utilities.
abstract final class PlatformProcessUtils {
  static const ProcessRunner defaultRunner = SystemProcessRunner();

  /// Where procfs is mounted on Linux.
  static const String defaultProcRoot = '/proc';

  /// Whether the process with [processId] is currently running -- in three
  /// states, and the third one is the whole point.
  ///
  /// * `true` -- the OS confirmed the process is there.
  /// * `false` -- the OS confirmed it is not.
  /// * `null` -- the question could not be *asked*: the probing tool is not
  ///   on `PATH`, or the query failed for a reason that says nothing about
  ///   the process.
  ///
  /// Callers must treat `null` as "cannot verify", never as "dead", for
  /// exactly the reason [processStartTimeSignature] already documents. A
  /// `bool` return made that mistake unrepresentable in the type and
  /// therefore invisible: Debian/Ubuntu `-slim`, distroless and most
  /// language base images (including `dart:stable`) ship no `procps`, so
  /// `kill` and `ps` do not exist as executables there, `Process.runSync`
  /// threw `ProcessException`, and every live session on such a host was
  /// reported stale and had its record deleted.
  ///
  /// On Linux the answer comes from `/proc/<pid>` and costs no subprocess at
  /// all; `kill -0` / `tasklist` stay the fallback for everything else, and
  /// for a Linux sandbox with no procfs mounted.
  static bool? isProcessAlive(
    int processId, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
    bool? isLinux,
    String procRoot = defaultProcRoot,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    if (!windows && (isLinux ?? Platform.isLinux)) {
      final bool? fromProcfs = _procfsLiveness(processId, procRoot);
      if (fromProcfs != null) return fromProcfs;
    }
    try {
      if (windows) {
        final result = runner.runSync('tasklist', [
          '/FI',
          'PID eq $processId',
          '/NH',
        ]);
        // A filtered `tasklist` reports "no such task" on *stdout* and still
        // exits 0, so a non-zero exit means the tool itself failed -- which
        // is a statement about `tasklist`, not about the process.
        if (result.exitCode != 0) return null;
        return RegExp(
          '(?:^|\\s)$processId(?:\\s|\$)',
          multiLine: true,
        ).hasMatch(result.stdout.toString());
      }
      // `kill` did run and answered: a non-zero exit is a real "not yours to
      // signal" verdict (ESRCH, or EPERM for another user's process -- the
      // pre-existing reading, and session files are owner-only anyway).
      return runner.runSync('kill', ['-0', '$processId']).exitCode == 0;
    } on ProcessException {
      // The tool could not be launched at all. Nothing was learned.
      return null;
    }
  }

  /// Liveness straight from procfs, or `null` when procfs cannot answer.
  ///
  /// Guarded on `<procRoot>/self` rather than `<procRoot>` alone: a chroot or
  /// sandbox that exposes an empty `/proc` directory would otherwise make
  /// every PID look dead. Proving procfs is really mounted for *this*
  /// namespace first keeps that case on the tool-based fallback.
  static bool? _procfsLiveness(int processId, String procRoot) {
    try {
      if (!Directory('$procRoot/self').existsSync()) return null;
      return Directory('$procRoot/$processId').existsSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Captures [processId]'s OS-reported launch time as an opaque signature.
  ///
  /// This is deliberately *not* parsed into a [DateTime]: the two platforms
  /// format it differently (locale-dependent on POSIX, ISO-8601 on Windows
  /// via the explicit `"o"` format below), and reassembling a portable
  /// timestamp buys nothing when every caller only ever needs "is this still
  /// the same launch" — raw string equality answers that exactly as well,
  /// without a parse step that could quietly misread across locales.
  ///
  /// On POSIX, runs `ps -o lstart= -p <pid>`. On Windows, runs PowerShell
  /// `(Get-Process -Id <pid>).StartTime.ToString("o")`.
  ///
  /// Returns `null` when the OS declines to answer: the tool is missing,
  /// exits non-zero, prints nothing, or the process exited between the
  /// caller's liveness check and this call. Callers must treat `null` as
  /// "cannot verify", never as "this is a different process" — that
  /// distinction is what keeps a missing `ps`/PowerShell from fail-closed
  /// killing a live session.
  ///
  /// "The tool is missing" is not hypothetical: slim and distroless Linux
  /// images ship no `procps`, so `ps` is simply absent there and PID-reuse
  /// detection degrades to PID-only on those hosts. [isProcessAlive] answers
  /// from procfs instead and keeps working; this probe has no equally cheap
  /// procfs equivalent that stored records could be compared against,
  /// because the signature they carry was written in `ps` format.
  static String? processStartTimeSignature(
    int processId, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    try {
      final ProcessResult result = windows
          ? runner.runSync('powershell', [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              '(Get-Process -Id $processId).StartTime.ToString("o")',
            ])
          : runner.runSync('ps', ['-o', 'lstart=', '-p', '$processId']);
      if (result.exitCode != 0) return null;
      final String signature = result.stdout.toString().trim();
      return signature.isEmpty ? null : signature;
    } on ProcessException {
      return null;
    }
  }

  /// Creates [path] empty and owner-only (`0600` on POSIX) **before** any content is written.
  static File createRestrictedFileSync(
    String path, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    final file = File(path);
    file.createSync(exclusive: true);
    final windows = isWindows ?? Platform.isWindows;
    if (!windows) {
      runner.runSync('chmod', ['600', file.path]);
    }
    return file;
  }

  /// Ensures a directory has owner-only permissions (`0700` on POSIX).
  static Directory ensureRestrictedDirectorySync(
    Directory directory, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final windows = isWindows ?? Platform.isWindows;
    if (!windows) {
      runner.runSync('chmod', ['700', directory.path]);
    }
    return directory;
  }
}
