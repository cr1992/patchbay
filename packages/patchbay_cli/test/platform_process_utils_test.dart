import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/platform/process_utils.dart';
import 'package:test/test.dart';

final class CommandInvocation {
  const CommandInvocation(this.executable, this.arguments, this.environment);
  final String executable;
  final List<String> arguments;

  /// The environment overlay the caller pinned, or `null` when it pinned
  /// none. Recorded because PB-050-31's whole POSIX fallback rests on it.
  final Map<String, String>? environment;
}

final class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.syncHandler});

  final ProcessResult Function(String executable, List<String> arguments)?
  syncHandler;

  final List<CommandInvocation> executedSync = [];

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    executedSync.add(CommandInvocation(executable, arguments, environment));
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

/// Synthetic. A real `boot_id` is a per-boot machine identifier and has no
/// business being frozen into a checked-in fixture.
const String _bootId = '00000000-0000-4000-8000-000000000001';

/// Why the `ps`-fallback timezone tests cannot run on a given host.
///
/// Debian/Ubuntu `-slim`, distroless and most language base images ship no
/// `procps`, so `ps` is absent and every probe in that group answers `null`.
/// That has to surface as a skip: reported as a pass, the group would look
/// like standing evidence for a guard it never exercised.
const String _noPsReason =
    'no `ps` on this host (no procps): the `v2-posix` '
    'fallback cannot be exercised here';

/// A `/proc/<pid>/stat` line whose only interesting parts are [comm] (field 2,
/// the parsing hazard) and [startTimeTicks] (field 22, the payload).
String _statLine({required String comm, required int startTimeTicks}) {
  // Fields 3..21 -- state through itrealvalue -- shaped after a real line so
  // an off-by-one in the parser lands on a plausible-looking number instead
  // of failing loudly.
  const List<String> beforeStartTime = <String>[
    'S', '1', '1', '1', '0', '-1', '4194304', '74', '0', '0', //
    '0', '0', '0', '0', '0', '20', '0', '1', '0', //
  ];
  return '4242 ($comm) ${beforeStartTime.join(' ')} '
      '$startTimeTicks 2293760 240\n';
}

/// Runs the command for real, with [hostTz] planted in the child's
/// environment first -- exactly what a shell, cron job or CI container in that
/// timezone does to the CLI process.
///
/// [honourOverlay] is the negative control: `false` drops the caller's pinned
/// environment, reproducing the pre-PB-050-31 behaviour.
final class _HostEnvironmentRunner implements ProcessRunner {
  const _HostEnvironmentRunner(this.hostTz, {required this.honourOverlay});

  final String hostTz;
  final bool honourOverlay;

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) => Process.runSync(
    executable,
    arguments,
    environment: <String, String>{
      'TZ': hostTz,
      if (honourOverlay) ...?environment,
    },
  );

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => throw UnimplementedError();
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
      // A procfs that knows this process is the precondition for trusting it
      // at all -- see the bind-mounted-foreign-procfs test below.
      Directory('${procRoot.path}/$pid').createSync();
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
      // so the guard is a PID lookup inside it, not the directory itself.
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

    test('a procfs from another PID namespace is refused, not believed', () {
      // A container that bind-mounts the parent namespace's /proc into a
      // child PID namespace: `<procRoot>/self` still resolves -- it is a
      // magic symlink answering for whichever namespace owns the mount -- but
      // the PIDs this process knows mean nothing in it. Trusting it would
      // manufacture a brand-new deterministic false-dead, in a case where
      // `kill -0` (which runs in *our* namespace) gets it right. So the
      // guard must be our own PID, and `self` alone must not satisfy it.
      final Directory foreign = Directory.systemTemp.createTempSync(
        'patchbay-foreign-proc-',
      );
      addTearDown(() => foreign.deleteSync(recursive: true));
      Directory('${foreign.path}/self').createSync();
      Directory('${foreign.path}/1').createSync();
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) => ProcessResult(123, 0, '', ''),
      );

      expect(
        PlatformProcessUtils.isProcessAlive(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: foreign.path,
        ),
        isTrue,
        reason: 'must fall through to `kill`, not read the foreign procfs',
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
    test('POSIX: pins TZ and LC_ALL, and tags the scheme', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: false,
        isLinux: false,
      );
      expect(signature, 'v2-posix:Mon Aug 25 09:00:00 2026');
      expect(fake.executedSync, hasLength(1));
      expect(fake.executedSync.single.executable, 'ps');
      expect(fake.executedSync.single.arguments, [
        '-o',
        'lstart=',
        '-p',
        '4242',
      ]);
      // PB-050-31. Both are load-bearing and were measured separately: `TZ`
      // shifts the rendered clock, and `LC_ALL` rewrites the month/day names
      // even with `TZ` already pinned. Dropping either one leaves a way for
      // two readers of the same record to disagree.
      expect(fake.executedSync.single.environment, {
        'TZ': 'UTC',
        'LC_ALL': 'C',
      });
    });

    test('POSIX: collapses padding rather than persisting it', () {
      // BSD `ps` pads `lstart` on the right and renders single-digit days
      // with a double space. Neither carries information, and both would
      // otherwise be frozen into a persisted identity.
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, '  Fri Aug  8 09:00:00 2026    \n', ''),
      );
      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: false,
        ),
        'v2-posix:Fri Aug 8 09:00:00 2026',
      );
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
        isLinux: false,
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
        isLinux: false,
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
        isLinux: false,
      );
      expect(signature, isNull);
    });

    test('Windows: converts to UTC before formatting, and tags it', () {
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, '2026-08-25T16:00:00.0000000Z\n', ''),
      );
      final signature = PlatformProcessUtils.processStartTimeSignature(
        4242,
        runner: fake,
        isWindows: true,
      );
      expect(signature, 'v2-win:2026-08-25T16:00:00.0000000Z');
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
      // Without this the `"o"` round-trip format keeps the machine's local
      // UTC offset, which is the Windows shape of the same defect.
      expect(
        fake.executedSync.single.arguments.last,
        contains('.ToUniversalTime()'),
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

  group('processStartTimeSignature: Linux procfs', () {
    late Directory procRoot;

    setUp(() {
      procRoot = Directory.systemTemp.createTempSync('patchbay-fake-proc-sig-');
      Directory('${procRoot.path}/$pid').createSync();
      File(
        '${procRoot.path}/sys/kernel/random/boot_id',
      ).createSync(recursive: true);
      File(
        '${procRoot.path}/sys/kernel/random/boot_id',
      ).writeAsStringSync('$_bootId\n');
    });

    tearDown(() {
      if (procRoot.existsSync()) procRoot.deleteSync(recursive: true);
    });

    void writeStat(int processId, String stat) {
      Directory('${procRoot.path}/$processId').createSync();
      File('${procRoot.path}/$processId/stat').writeAsStringSync(stat);
    }

    ProcessResult refuse(String exe, List<String> args) =>
        fail('procfs answered; no subprocess should have been spawned');

    test('reads starttime ticks and boot id, spawning nothing', () {
      writeStat(4242, _statLine(comm: 'sleep', startTimeTicks: 7128607));
      final fake = FakeProcessRunner(syncHandler: refuse);

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-linux:$_bootId:7128607',
      );
      expect(fake.executedSync, isEmpty);
    });

    test('a comm containing spaces and parentheses still parses', () {
      // `comm` is the executable basename, unescaped and unquoted beyond the
      // wrapping parentheses; the kernel permits spaces and `)` inside it.
      // Splitting the whole line on whitespace, or cutting at the *first*
      // `)`, shifts every later field -- and reading some other number as
      // the start time produces a value that changes, i.e. looks exactly
      // like a PID-reuse collision.
      writeStat(4243, _statLine(comm: 'my app (beta)', startTimeTicks: 99));

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4243,
          runner: FakeProcessRunner(syncHandler: refuse),
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-linux:$_bootId:99',
      );
    });

    test('a comm that is only spaces and digits does not shift the field', () {
      writeStat(4244, _statLine(comm: '4242) S 1 2 3', startTimeTicks: 555));

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4244,
          runner: FakeProcessRunner(syncHandler: refuse),
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-linux:$_bootId:555',
      );
    });

    test('a truncated stat line falls back rather than guessing', () {
      writeStat(4245, '4245 (sleep) S 1 1 1 0 -1\n');
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4245,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-posix:Mon Aug 25 09:00:00 2026',
      );
      expect(fake.executedSync.single.executable, 'ps');
    });

    test('a missing boot_id falls back -- ticks alone can collide', () {
      // Ticks are counted from boot, so without a boot identity a PID
      // reissued at the same offset into a *later* boot reads as the same
      // launch. A weaker signature is worse than the `ps` fallback.
      File('${procRoot.path}/sys/kernel/random/boot_id').deleteSync();
      writeStat(4246, _statLine(comm: 'sleep', startTimeTicks: 42));
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4246,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-posix:Mon Aug 25 09:00:00 2026',
      );
    });

    test('a boot_id that is not a UUID falls back too', () {
      // BUG-20260828-01, write side. Persisting it would be worse than
      // useless: the reader's payload contract would refuse it forever, so
      // the record would compare `unverifiable` for its whole life and
      // silently carry no PID-reuse guard at all. `ps` may still answer.
      File(
        '${procRoot.path}/sys/kernel/random/boot_id',
      ).writeAsStringSync('not-a-uuid\n');
      writeStat(4247, _statLine(comm: 'sleep', startTimeTicks: 42));
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4247,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: procRoot.path,
        ),
        'v2-posix:Mon Aug 25 09:00:00 2026',
      );
      expect(fake.executedSync.single.executable, 'ps');
    });

    test('a procfs from another PID namespace is refused, not believed', () {
      final Directory foreign = Directory.systemTemp.createTempSync(
        'patchbay-foreign-proc-sig-',
      );
      addTearDown(() => foreign.deleteSync(recursive: true));
      Directory('${foreign.path}/self').createSync();
      Directory('${foreign.path}/4242').createSync();
      File(
        '${foreign.path}/4242/stat',
      ).writeAsStringSync(_statLine(comm: 'other', startTimeTicks: 1));
      File(
        '${foreign.path}/sys/kernel/random/boot_id',
      ).createSync(recursive: true);
      File(
        '${foreign.path}/sys/kernel/random/boot_id',
      ).writeAsStringSync('$_bootId\n');
      final fake = FakeProcessRunner(
        syncHandler: (exe, args) =>
            ProcessResult(123, 0, 'Mon Aug 25 09:00:00 2026\n', ''),
      );

      expect(
        PlatformProcessUtils.processStartTimeSignature(
          4242,
          runner: fake,
          isWindows: false,
          isLinux: true,
          procRoot: foreign.path,
        ),
        'v2-posix:Mon Aug 25 09:00:00 2026',
        reason: 'those PIDs mean nothing here; `ps` runs in our namespace',
      );
    });

    test('the real /proc answers for this process, stably', () {
      if (!Platform.isLinux) return;
      final String? first = PlatformProcessUtils.processStartTimeSignature(pid);
      expect(first, startsWith('v2-linux:'));
      // Same process, second call: an identity that drifts between two reads
      // one instant apart cannot be an identity at all.
      expect(PlatformProcessUtils.processStartTimeSignature(pid), first);
      expect(
        PlatformProcessUtils.processStartTimeSignature(2147483647),
        isNull,
      );
    });
  });

  group('PlatformProcessUtils.compareStartTimeSignatures', () {
    test('same scheme, same payload is the same launch', () {
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'v2-linux:$_bootId:7128607',
          'v2-linux:$_bootId:7128607',
        ),
        PatchbayStartTimeMatch.same,
      );
    });

    test('same scheme, different payload is PID reuse -- still judged', () {
      // The PB-050-18 guard this change must not weaken.
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'v2-linux:$_bootId:7128607',
          'v2-linux:$_bootId:9000000',
        ),
        PatchbayStartTimeMatch.different,
      );
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'v2-posix:Mon Aug 25 09:00:00 2026',
          'v2-posix:Mon Aug 25 09:00:01 2026',
        ),
        PatchbayStartTimeMatch.different,
      );
    });

    test('an unprefixed dev-era value is unverifiable, never different', () {
      // Records written during 0.5.0 development carry raw `ps` output. Two
      // such strings differing is exactly what the timezone defect produced
      // for a *live* process, so this pair must never reach "different".
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'Fri Aug 28 01:47:22 2026',
          'Fri Aug 28 09:47:22 2026',
        ),
        PatchbayStartTimeMatch.unverifiable,
      );
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          '2026-08-25T09:00:00.0000000-07:00',
          '2026-08-25T09:00:00.0000000+08:00',
        ),
        PatchbayStartTimeMatch.unverifiable,
      );
    });

    test('an unprefixed value stays unverifiable even when it matches', () {
      // Deliberate: a value in a format this build cannot interpret proves
      // nothing in *either* direction, so it must not be reported verified.
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'Fri Aug 28 01:47:22 2026',
          'Fri Aug 28 01:47:22 2026',
        ),
        PatchbayStartTimeMatch.unverifiable,
      );
    });

    test('an unknown future scheme degrades instead of judging', () {
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'v9-something:abc',
          'v2-posix:Mon Aug 25 09:00:00 2026',
        ),
        PatchbayStartTimeMatch.unverifiable,
      );
    });

    test('two different known schemes are not comparable', () {
      // A Linux host that wrote a procfs signature and later reads it with
      // procfs unavailable gets a `v2-posix` probe back. Not comparable is
      // not the same as not equal.
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          'v2-linux:$_bootId:7128607',
          'v2-posix:Mon Aug 25 09:00:00 2026',
        ),
        PatchbayStartTimeMatch.unverifiable,
      );
    });

    test('an empty or scheme-less string is unverifiable, not different', () {
      for (final pair in <List<String>>[
        <String>['', 'v2-posix:Mon Aug 25 09:00:00 2026'],
        <String>[':leading', 'v2-posix:Mon Aug 25 09:00:00 2026'],
        <String>['v2-posix:Mon Aug 25 09:00:00 2026', 'no-colon-at-all'],
      ]) {
        expect(
          PlatformProcessUtils.compareStartTimeSignatures(pair[0], pair[1]),
          PatchbayStartTimeMatch.unverifiable,
          reason: 'pair: $pair',
        );
      }
    });

    test('a live process compares equal to itself, end to end', () async {
      if (Platform.isWindows) return;
      final Process child = await Process.start('/bin/sleep', <String>['30']);
      addTearDown(() => child.kill(ProcessSignal.sigkill));

      final String? recorded = PlatformProcessUtils.processStartTimeSignature(
        child.pid,
      );
      expect(recorded, isNotNull);
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(
          recorded!,
          PlatformProcessUtils.processStartTimeSignature(child.pid)!,
        ),
        PatchbayStartTimeMatch.same,
      );
    });
  });

  group('BUG-20260828-01: a scheme tag is a claim, not proof', () {
    // The gap PB-050-31 left behind. The comparison recognised the scheme and
    // then trusted whatever followed it, so a corrupted record such as
    // `v2-linux:garbage` compared "same scheme, unequal payload" against a
    // healthy probe -- `different`, which the resolver reads as PID reuse and
    // answers by deleting the record of a session whose App is still running.
    // A malformed payload is the same kind of fact as an unknown scheme:
    // nothing can be concluded from it, in either direction.

    // One signature per scheme, in exactly the form this build writes.
    const String linuxOk = 'v2-linux:$_bootId:7128607';
    const String posixOk = 'v2-posix:Mon Aug 25 09:00:00 2026';
    const String winOk = 'v2-win:2026-08-25T16:00:00.0000000Z';

    // Each healthy signature against the corruptions of its own scheme.
    const Map<String, List<String>> corrupt = <String, List<String>>{
      linuxOk: <String>[
        'v2-linux:',
        'v2-linux:garbage',
        // Truncated writes, which is what a corrupted record actually looks
        // like: the boot id survived, the tick count did not.
        'v2-linux:$_bootId',
        'v2-linux:$_bootId:',
        // `int.tryParse` accepts all three of these; field 22 is none of them.
        'v2-linux:$_bootId:71x8607',
        'v2-linux:$_bootId:-7128607',
        'v2-linux:$_bootId:+7128607',
        'v2-linux:$_bootId:7128607:7128607',
        'v2-linux:not-a-uuid:7128607',
        'v2-linux:0000000-0000-4000-8000-000000000001:7128607',
        'v2-linux:$_bootId\u0000:7128607',
      ],
      posixOk: <String>[
        'v2-posix:',
        // An opaque placeholder is not an `lstart`. Listed first because it
        // is what this repo's own session fixtures used to hold: a value
        // that looks harmless and was trusted as a comparable identity.
        'v2-posix:launch-a',
        // Truncation, one field at a time. A half-written record compared
        // against the intact one it came from is exactly the shape that used
        // to reach `different`.
        'v2-posix:Mon Aug 25 09:00:00',
        'v2-posix:Mon Aug 25 09:00:00 202',
        'v2-posix:Mon Aug 25 09:00 2026',
        'v2-posix:Aug 25 09:00:00 2026',
        'v2-posix:Mon Aug 09:00:00 2026',
        'v2-posix:on Aug 25 09:00:00 2026',
        'v2-posix:Mon Aug 25 09:00:00 2026 extra',
        // Field widths `ps` cannot produce under the pinned `LC_ALL=C`: the
        // clock is two-digit, the day at most two.
        'v2-posix:Mon Aug 125 09:00:00 2026',
        'v2-posix:Mon Aug 25 9:00:00 2026',
        // The writer trims and collapses, so none of these three can be its
        // output -- each is a value that was mangled after it was written.
        'v2-posix: Mon Aug 25 09:00:00 2026',
        'v2-posix:Mon Aug 25 09:00:00 2026 ',
        'v2-posix:Mon Aug  25 09:00:00 2026',
        // Control characters are not `\s`, so the collapse would have left
        // them in place: seeing one means the value is not ours.
        'v2-posix:Mon Aug 25\u000009:00:00 2026',
        'v2-posix:Mon Aug 25\n09:00:00 2026',
        'v2-posix:Mon Aug 25 09:00:00 2026\u007f',
      ],
      winOk: <String>[
        'v2-win:',
        'v2-win:garbage',
        // A local offset instead of `Z` is the Windows shape of the
        // PB-050-31 defect itself: two readers in two timezones would
        // disagree about one live process. Not comparable, by construction.
        'v2-win:2026-08-25T16:00:00.0000000-07:00',
        // `"o"` is fixed width: seven fractional digits, always. Three, none
        // and eight are each something that happened to the string after it
        // was written, and a truncated copy must not compare `different`
        // against the intact one it came from.
        'v2-win:2026-08-25T16:00:00.000Z',
        'v2-win:2026-08-25T16:00:00Z',
        'v2-win:2026-08-25T16:00:00.00000000Z',
        'v2-win:2026-08-25T16:00:00.0000000',
        'v2-win:2026-08-25T16:00:00',
        'v2-win:2026-08-25 16:00:00.0000000Z',
        'v2-win:2026-08-25T16:00:00.0000000Z\u0000',
      ],
    };

    test(
      'a malformed payload never reaches "different", in either direction',
      () {
        corrupt.forEach((String healthy, List<String> broken) {
          for (final String value in broken) {
            expect(
              PlatformProcessUtils.compareStartTimeSignatures(value, healthy),
              PatchbayStartTimeMatch.unverifiable,
              reason: 'recorded ${jsonEncode(value)} vs probe $healthy',
            );
            expect(
              PlatformProcessUtils.compareStartTimeSignatures(healthy, value),
              PatchbayStartTimeMatch.unverifiable,
              reason: 'record $healthy vs probe ${jsonEncode(value)}',
            );
          }
        });
      },
    );

    test('two malformed payloads stay unverifiable, equal or not', () {
      // Byte-identical included, deliberately: a value this build cannot
      // interpret proves nothing in *either* direction, so it must not be
      // reported as a verified identity either.
      corrupt.forEach((_, List<String> broken) {
        for (final String value in broken) {
          expect(
            PlatformProcessUtils.compareStartTimeSignatures(value, value),
            PatchbayStartTimeMatch.unverifiable,
            reason: 'identical malformed pair: ${jsonEncode(value)}',
          );
        }
        for (final String other in broken.skip(1)) {
          expect(
            PlatformProcessUtils.compareStartTimeSignatures(
              broken.first,
              other,
            ),
            PatchbayStartTimeMatch.unverifiable,
            reason: 'malformed pair: ${jsonEncode(other)}',
          );
        }
      });
    });

    test('well-formed pairs still decide -- the PID-reuse guard is intact', () {
      // The other half of the contract: adding a payload check must not cost
      // a single `same` or `different` verdict the fix already earned.
      const Map<String, String> otherLaunch = <String, String>{
        linuxOk: 'v2-linux:$_bootId:9000000',
        posixOk: 'v2-posix:Mon Aug 25 09:00:01 2026',
        winOk: 'v2-win:2026-08-25T16:00:01.0000000Z',
      };
      otherLaunch.forEach((String healthy, String reused) {
        expect(
          PlatformProcessUtils.compareStartTimeSignatures(healthy, healthy),
          PatchbayStartTimeMatch.same,
          reason: healthy,
        );
        expect(
          PlatformProcessUtils.compareStartTimeSignatures(healthy, reused),
          PatchbayStartTimeMatch.different,
          reason: '$healthy vs $reused',
        );
      });
    });

    test('the payload contracts admit everything their writers emit', () {
      // Over-strictness has a cost of its own -- every rejected legal value
      // silently forfeits the PID-reuse guard for that record -- so the
      // boundaries the writers can actually reach are pinned here.
      const List<List<String>> sameLaunch = <List<String>>[
        // PID 1 legitimately starts at tick 0.
        <String>['v2-linux:$_bootId:0', 'v2-linux:$_bootId:0'],
        // The kernel prints boot_id in lowercase; hex case is not a fact
        // about the boot, so it is not asserted.
        <String>[
          'v2-linux:00000000-0000-4000-8000-00000000ABCD:7128607',
          'v2-linux:00000000-0000-4000-8000-00000000ABCD:7128607',
        ],
        // BSD pads a single-digit day with a second space and the writer's
        // collapse removes it, so a one-digit day is a shape the writer
        // really does emit -- on exactly the platform this suite usually
        // runs on.
        <String>[
          'v2-posix:Fri Aug 8 09:00:00 2026',
          'v2-posix:Fri Aug 8 09:00:00 2026',
        ],
        <String>[
          'v2-posix:Mon Aug 25 09:00:00 2026',
          'v2-posix:Mon Aug 25 09:00:00 2026',
        ],
        // Midnight, where every field is at its low end: still full width,
        // because `LC_ALL=C` zero-pads the clock.
        <String>[
          'v2-posix:Thu Jan 1 00:00:00 2026',
          'v2-posix:Thu Jan 1 00:00:00 2026',
        ],
        // `"o"` renders seven fractional digits, and a whole second renders
        // them as zeros rather than omitting them.
        <String>[
          'v2-win:2026-08-25T16:00:00.0000000Z',
          'v2-win:2026-08-25T16:00:00.0000000Z',
        ],
      ];
      for (final List<String> pair in sameLaunch) {
        expect(
          PlatformProcessUtils.compareStartTimeSignatures(pair[0], pair[1]),
          PatchbayStartTimeMatch.same,
          reason: 'pair: $pair',
        );
      }
    });

    test('a real procfs signature satisfies its own payload contract', () {
      // The contract is read off the writer, so the writer is what proves it:
      // a synthetic fixture could agree with a rule that the kernel does not.
      // Reported as a skip rather than an early `return`: on a non-Linux host
      // this would otherwise be a green no-op standing in for evidence it
      // never produced.
      if (!Platform.isLinux) {
        return markTestSkipped('procfs is a Linux fact; no `/proc` here');
      }
      final String? real = PlatformProcessUtils.processStartTimeSignature(pid);
      expect(real, isNotNull);
      expect(
        PlatformProcessUtils.compareStartTimeSignatures(real!, real),
        PatchbayStartTimeMatch.same,
        reason: 'this build must be able to read back what it just wrote',
      );
    });
  });

  group(
    'PB-050-31: the same launch, read from a different timezone',
    () {
      // The defect itself, against the real `ps` on whatever this platform is.
      // `ps -o lstart=` renders in the *calling environment's* timezone, so a
      // record written by a UTC cron job and read from an Asia/Taipei shell
      // produced two unequal signatures for one live process. The resolver read
      // "unequal" as PID reuse and deleted the record of a running App.
      //
      // `isLinux: false` forces the `ps` fallback even on Linux: procfs is
      // TZ-free by construction and would prove nothing about this path.
      late Process child;

      setUp(() async {
        child = await Process.start('/bin/sleep', <String>['30']);
      });

      tearDown(() {
        child.kill(ProcessSignal.sigkill);
      });

      String? probe(String hostTz, {required bool pinned}) =>
          PlatformProcessUtils.processStartTimeSignature(
            child.pid,
            runner: _HostEnvironmentRunner(hostTz, honourOverlay: pinned),
            isWindows: false,
            isLinux: false,
          );

      test('three host timezones produce one identical signature', () {
        final String? utc = probe('UTC', pinned: true);
        // Reported as skipped, never as passed: a slim image with no `procps`
        // makes every probe here `null`, and an early `return` would turn all
        // three of these tests into green no-ops that assert nothing.
        if (utc == null) return markTestSkipped(_noPsReason);
        expect(utc, startsWith('v2-posix:'));
        expect(probe('Asia/Taipei', pinned: true), utc);
        expect(probe('America/New_York', pinned: true), utc);
        expect(probe('Australia/Lord_Howe', pinned: true), utc);
      });

      test('and the guard is real: dropping the pin brings the defect back', () {
        // A negative control. Without it the test above would keep passing on a
        // host whose `ps` happens to ignore `TZ`, and would therefore stop
        // being evidence of anything.
        final String? utc = probe('UTC', pinned: false);
        if (utc == null) return markTestSkipped(_noPsReason);
        expect(probe('Asia/Taipei', pinned: false), isNot(utc));
        expect(probe('America/New_York', pinned: false), isNot(utc));
      });

      test('and comparing across those timezones never says "different"', () {
        final String? written = probe('UTC', pinned: true);
        if (written == null) return markTestSkipped(_noPsReason);
        final String read = probe('Asia/Taipei', pinned: true)!;
        expect(
          PlatformProcessUtils.compareStartTimeSignatures(written, read),
          PatchbayStartTimeMatch.same,
        );
      });
    },
    skip: Platform.isWindows ? 'POSIX `ps` path' : null,
  );

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
