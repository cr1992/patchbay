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

  /// Determines whether the process with [processId] is currently alive.
  ///
  /// On Windows, queries `tasklist` by PID.
  /// On POSIX systems, issues `kill -0 <pid>`.
  static bool isProcessAlive(
    int processId, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    try {
      if (windows) {
        final result = runner.runSync('tasklist', [
          '/FI',
          'PID eq $processId',
          '/NH',
        ]);
        return result.exitCode == 0 &&
            RegExp(
              '(?:^|\\s)$processId(?:\\s|\$)',
              multiLine: true,
            ).hasMatch(result.stdout.toString());
      }
      return runner.runSync('kill', ['-0', '$processId']).exitCode == 0;
    } on ProcessException {
      return false;
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
