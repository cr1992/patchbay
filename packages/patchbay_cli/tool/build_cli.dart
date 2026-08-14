import 'dart:io';

/// Compiles `bin/patchbay.dart` into a self-contained AOT executable.
///
/// The CLI is invoked once per command, so its startup cost is paid on every
/// line a debugging session types. `dart run` pays for a pub freshness check
/// and JIT warmup each time; the AOT executable pays neither, and it is a
/// single file that can be dropped anywhere on `PATH` — which is also what
/// removes the "only runs from the package directory" constraint.
///
/// Paths resolve from the script location, not the working directory, so this
/// runs the same from the repository root and from inside the package.
void main(List<String> arguments) {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final Directory package = _packageRoot();
  final String output =
      options.output ?? '${package.path}/build/${_defaultName()}';

  // A fresh clone has no package config, and `dart compile` cannot resolve
  // the sibling path dependencies without one.
  if (!File('${package.path}/.dart_tool/package_config.json').existsSync()) {
    if (!_run(<String>['pub', 'get'], package)) {
      exitCode = 1;
      return;
    }
  }

  Directory(File(output).parent.path).createSync(recursive: true);
  if (!_run(<String>[
    'compile',
    'exe',
    'bin/patchbay.dart',
    '-o',
    output,
  ], package)) {
    exitCode = 1;
    return;
  }

  final int bytes = File(output).lengthSync();
  stdout
    ..writeln('Built $output (${(bytes / (1 << 20)).toStringAsFixed(1)} MiB)')
    ..writeln(
      'Put it on PATH to call `patchbay` from any directory, '
      'or see docs/guide.md for the pinned `dart pub global activate` install.',
    );
}

/// Runs a Dart SDK subcommand with this script's own SDK.
///
/// `dart` need not be on `PATH` for `dart run tool/build_cli.dart` to have
/// started, so the interpreter that is already running is the only one known
/// to exist.
bool _run(List<String> arguments, Directory workingDirectory) {
  final ProcessResult result = Process.runSync(
    Platform.resolvedExecutable,
    arguments,
    workingDirectory: workingDirectory.path,
  );
  if (result.exitCode != 0) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    stderr.writeln('dart ${arguments.join(' ')} failed (${result.exitCode}).');
    return false;
  }
  return true;
}

/// The `patchbay_cli` directory, resolved from this script rather than cwd.
Directory _packageRoot() => Directory(
  File.fromUri(Platform.script).parent.parent.path,
);

/// The name the command is typed as, so the artifact works by being on `PATH`.
///
/// Release artifacts carry a platform suffix instead, because they end up in
/// one download list together; the workflow passes that name via `--output`.
String _defaultName() => Platform.isWindows ? 'patchbay.exe' : 'patchbay';

final class _Options {
  const _Options({required this.output});

  final String? output;

  static _Options parse(List<String> arguments) {
    String? output;
    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--output':
        case '-o':
          index += 1;
          if (index >= arguments.length) {
            throw const FormatException('--output needs a path');
          }
          output = arguments[index];
        default:
          throw FormatException(
            'usage: build_cli.dart [--output <path>]\n'
            'unknown argument: ${arguments[index]}',
          );
      }
    }
    return _Options(output: output);
  }
}
