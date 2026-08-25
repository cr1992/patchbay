import 'dart:io';

import 'package:patchbay_cli/src/platform/process_utils.dart';
import 'package:test/test.dart';

final class CommandInvocation {
  const CommandInvocation(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

final class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.syncHandler});

  final ProcessResult Function(String executable, List<String> arguments)?
  syncHandler;

  final List<CommandInvocation> executedSync = [];

  @override
  ProcessResult runSync(String executable, List<String> arguments) {
    executedSync.add(CommandInvocation(executable, arguments));
    if (syncHandler != null) return syncHandler!(executable, arguments);
    return ProcessResult(1234, 0, '', '');
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  group('PlatformProcessUtils.isProcessAlive', () {
    test('POSIX: uses kill -0 and checks exit code 0', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 0, '', ''),
      );
      final alive = PlatformProcessUtils.isProcessAlive(
        4242,
        runner: fake,
        isWindows: false,
      );
      expect(alive, isTrue);
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'kill');
      expect(fake.executedSync.single.arguments, ['-0', '4242']);
    });

    test('POSIX: returns false on non-zero exit code', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 1, '', 'No such process'),
      );
      final alive = PlatformProcessUtils.isProcessAlive(
        9999,
        runner: fake,
        isWindows: false,
      );
      expect(alive, isFalse);
    });

    test('POSIX: returns false on ProcessException', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => throw const ProcessException('kill', []),
      );
      final alive = PlatformProcessUtils.isProcessAlive(
        9999,
        runner: fake,
        isWindows: false,
      );
      expect(alive, isFalse);
    });

    test('Windows: uses tasklist and regex matches PID in output', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(
          123,
          0,
          'dart.exe                      4242 Console                    1     45,120 K\n',
          '',
        ),
      );
      final alive = PlatformProcessUtils.isProcessAlive(
        4242,
        runner: fake,
        isWindows: true,
      );
      expect(alive, isTrue);
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'tasklist');
      expect(fake.executedSync.single.arguments, ['/FI', 'PID eq 4242', '/NH']);
    });

    test(
      'Windows: returns false when tasklist output does not contain PID',
      () {
        final fake = FakeProcessRunner(
          syncHandler: (exe, args) => ProcessResult(
            123,
            0,
            'INFO: No tasks are running which match the specified criteria.\n',
            '',
          ),
        );
        final alive = PlatformProcessUtils.isProcessAlive(
          4242,
          runner: fake,
          isWindows: true,
        );
        expect(alive, isFalse);
      },
    );
  });

  group('PlatformProcessUtils.processStartTimeSignature', () {
    test('POSIX: uses ps -o lstart= -p and returns trimmed stdout', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: false,
      );
      expect(signature, 'Mon Aug 25 09:00:00 2026');
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'ps');
      expect(fake.executedSync.single.arguments, [
        '-o',
        'lstart=',
        '-p',
        '4242',
      ]);
    });

    test('POSIX: returns null on non-zero exit code', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 1, '', 'No such process'),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        9999,
        runner: fake,
        isWindows: false,
      );
      expect(signature, isNull);
    });

    test('POSIX: returns null on empty stdout', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 0, '   \n', ''),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: false,
      );
      expect(signature, isNull);
    });

    test('POSIX: returns null on ProcessException', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => throw const ProcessException('ps', []),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: false,
      );
      expect(signature, isNull);
    });

    test('Windows: uses PowerShell Get-Process StartTime', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, '2026-08-25T09:00:00.0000000-07:00\n', ''),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: true,
      );
      expect(signature, '2026-08-25T09:00:00.0000000-07:00');
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'powershell');
      expect(
        fake.executedSync.single.arguments,
        containsAll(<String>['-NoProfile', '-NonInteractive', '-Command']),
      );
      expect(
        fake.executedSync.single.arguments.last,
        contains('Get-Process -Id 4242'),
      );
    });

    test('Windows: returns null on non-zero exit code', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 1, '', 'not found'),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: true,
      );
      expect(signature, isNull);
    });

    test('Windows: returns null on ProcessException', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            throw const ProcessException('powershell', []),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: true,
      );
      expect(signature, isNull);
    });
  });

  group('PlatformProcessUtils restricted permissions', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('process-utils-test-');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('createRestrictedFileSync on POSIX issues chmod 600', () {
      final fake = FakeProcessRunner();
      final targetPath = '${tempDir.path}/secret.session';
      final file = PlatformProcessUtils.createRestrictedFileSync(
        targetPath,
        runner: fake,
        isWindows: false,
      );
      expect(file.existsSync(), isTrue);
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'chmod');
      expect(fake.executedSync.single.arguments, ['600', file.path]);
    });

    test('createRestrictedFileSync on Windows does not issue chmod', () {
      final fake = FakeProcessRunner();
      final targetPath = '${tempDir.path}/secret.session';
      final file = PlatformProcessUtils.createRestrictedFileSync(
        targetPath,
        runner: fake,
        isWindows: true,
      );
      expect(file.existsSync(), isTrue);
      expect(fake.executedSync, isEmpty);
    });

    test('ensureRestrictedDirectorySync on POSIX issues chmod 700', () {
      final fake = FakeProcessRunner();
      final targetDir = Directory('${tempDir.path}/sub-dir');
      final dir = PlatformProcessUtils.ensureRestrictedDirectorySync(
        targetDir,
        runner: fake,
        isWindows: false,
      );
      expect(dir.existsSync(), isTrue);
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'chmod');
      expect(fake.executedSync.single.arguments, ['700', dir.path]);
    });
  });
}
