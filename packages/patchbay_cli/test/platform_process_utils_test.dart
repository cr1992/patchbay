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
        isLinux: false,
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
        isLinux: false,
      );
      // `kill` ran and answered. That is a real verdict, not a shrug.
      expect(alive, isFalse);
    });

    test('POSIX: returns null -- not false -- when `kill` is not on PATH', () {
      // The regression this guards: Debian/Ubuntu `-slim`, distroless and
      // most language base images (`dart:stable` included) ship no `procps`,
      // so `kill` does not exist and `Process.runSync` throws. Answering
      // `false` there declared every live session stale and deleted its
      // record.
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => throw const ProcessException('kill', []),
      );
      final alive = PlatformProcessUtils.isProcessAlive(
        9999,
        runner: fake,
        isWindows: false,
        isLinux: false,
      );
      expect(alive, isNull);
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

    test('Windows: a non-zero tasklist exit is inconclusive, not dead', () {
      // A filtered `tasklist` says "no such task" on stdout and still exits
      // 0, so a non-zero exit is `tasklist` failing -- it says nothing about
      // the process. Nano Server images have no tasklist.exe at all.
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 1, '', 'ERROR'),
      );
      expect(
        PlatformProcessUtils.isProcessAlive(
          4242,
          runner: fake,
          isWindows: true,
        ),
        isNull,
      );
      expect(
        PlatformProcessUtils.isProcessAlive(
          4242,
          runner: FakeProcessRunner(
            syncHandler: (exe, args) =>
                throw const ProcessException('tasklist', []),
          ),
          isWindows: true,
        ),
        isNull,
      );
    });
  });

  group('PlatformProcessUtils.isProcessAlive: Linux procfs', () {
    late Directory procRoot;

    setUp(() {
      procRoot = Directory.systemTemp.createTempSync('patchbay-fake-proc-');
      Directory('${procRoot.path}/self').createSync();
    });

    tearDown(() {
      if (procRoot.existsSync()) procRoot.deleteSync(recursive: true);
    });

    ProcessResult refuse(String exe, List<String> args) =>
        fail('procfs answered; no subprocess should have been spawned');

    test('an existing /proc/<pid> is alive, with no subprocess at all', () {
      Directory('${procRoot.path}/4242').createSync();
      final fake = FakeProcessRunner(syncHandler: refuse);

      expect(
        PlatformProcessUtils.isProcessAlive(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        isTrue,
      );
      // The point of the procfs path is not only correctness on hosts with
      // no `procps`: it also removes a fork/exec per record per command.
      expect(fake.executedSync, isEmpty);
    });

    test('a missing /proc/<pid> is dead -- PID-reuse pruning still works', () {
      expect(
        PlatformProcessUtils.isProcessAlive(
          2147483647,
          runner: FakeProcessRunner(syncHandler: refuse),
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        isFalse,
      );
    });

    test('no procfs mounted falls back to `kill`, never to "dead"', () {
      // A chroot or sandbox can leave `<procRoot>` absent or empty. Reading
      // that as "every PID is dead" is exactly the failure mode being fixed,
      // so the guard is `<procRoot>/self`, not `<procRoot>`.
      final Directory empty = Directory.systemTemp.createTempSync(
        'patchbay-empty-proc-',
      );
      addTearDown(() => empty.deleteSync(recursive: true));
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 0, '', ''),
      );

      expect(
        PlatformProcessUtils.isProcessAlive(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: empty.path,
        ),
        isTrue,
      );
      expect(fake.executedSync.single.executable, 'kill');
    });

    test('the real /proc agrees with this process being alive', () {
      if (!Platform.isLinux) return;
      expect(PlatformProcessUtils.isProcessAlive(pid), isTrue);
      expect(PlatformProcessUtils.isProcessAlive(2147483647), isFalse);
    });
  });

  group('against a real OS process, on whatever this platform is', () {
    // The fakes above pin the branching; this pins the thing the branching is
    // supposed to be *about*. Whichever mechanism this platform ends up using
    // -- procfs, `kill`, `tasklist` -- it has to get both directions right on
    // a process the test itself controls, or `sessions list`/`prune`/resolve
    // are deciding a session's fate on a fiction.
    test('a running child is alive, and a reaped one is not', () async {
      if (Platform.isWindows) return;
      final Process child = await Process.start('/bin/sleep', <String>['30']);
      addTearDown(() {
        child.kill(ProcessSignal.sigkill);
      });

      expect(
        PlatformProcessUtils.isProcessAlive(child.pid),
        isTrue,
        reason: 'a child that has not exited must never be reported dead',
      );

      child.kill(ProcessSignal.sigkill);
      await child.exitCode; // reaped: the PID is genuinely gone now
      expect(
        PlatformProcessUtils.isProcessAlive(child.pid),
        isFalse,
        reason: 'pruning still has to be able to see a dead process',
      );
    });

    test('this process can always see itself', () {
      expect(PlatformProcessUtils.isProcessAlive(pid), isTrue);
    });
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
