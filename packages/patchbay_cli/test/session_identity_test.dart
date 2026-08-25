/// PB-050-18：会话存活判定从裸 PID 升级为「PID + 进程启动身份」。
///
/// 覆盖三件事：PID 复用（同 PID 存活但启动时间不同）必须判死；启动身份采集不到时必须
/// 降级成旧的纯 PID 判定，而不是 fail-closed 杀掉一个其实还活着的会话；旧记录（没有
/// `processStartTime` 字段）在诊断输出里标注 `identityUnverified`，但存活判断完全不变。
library;

import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/platform/process_utils.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'patchbay-session-identity-test-',
    );
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('PID reuse', () {
    test(
      'a live PID whose start time no longer matches is judged dead',
      () async {
        store.write(_record('reused', processStartTime: 'launch-a'));

        await expectLater(
          PatchbaySessionResolver(
            store: store,
            pidProbe: (_) => true,
            // The PID answers "alive", but it belongs to a different
            // process now -- the OS recycled it after the original App
            // exited.
            processStartTimeProbe: (_) => 'launch-b',
          ).resolve(),
          throwsA(_sessionError('sessionStaleProcess')),
        );
        expect(store.readAll(), isEmpty);
      },
    );

    test('select() refuses to pin a record whose PID was recycled', () {
      store.write(_record('reused', processStartTime: 'launch-a'));

      final resolver = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'launch-b',
      );

      expect(
        () => resolver.select('reused'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
      expect(store.readSelection(), isNull);
      expect(store.readAll(), isEmpty);
    });

    test('inventory() marks a PID-reuse collision stale, not unverified', () {
      store.write(_record('reused', processStartTime: 'launch-a'));

      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'launch-b',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.stale);
      // A definite mismatch is a positive answer, not "could not verify".
      expect(listing.identityUnverified, isFalse);
    });

    test('a matching start time is treated as the same process', () async {
      store.write(_record('same', processStartTime: 'launch-a'));

      final resolved = await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'launch-a',
        identityProbe: (_) async => _identity(),
      ).resolve();

      expect(resolved.record.sessionId, 'same');
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'launch-a',
      ).inventory().single;
      expect(listing.identityUnverified, isFalse);
    });
  });

  group('start-time probe failure degrades, never fail-closed', () {
    test(
      'a live PID whose start time cannot be captured stays alive, flagged',
      () async {
        store.write(_record('unverifiable', processStartTime: 'launch-a'));

        final resolved = await PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => true,
          // The OS declined to answer (missing tool, sandboxed platform,
          // parse failure) -- this must never be treated as a mismatch.
          processStartTimeProbe: (_) => null,
          identityProbe: (_) async => _identity(),
        ).resolve();

        expect(resolved.record.sessionId, 'unverifiable');
      },
    );

    test(
      'such a record is reported unverified, not killed, in inventory()',
      () {
        store.write(_record('unverifiable', processStartTime: 'launch-a'));

        final PatchbaySessionListing listing = PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => true,
          processStartTimeProbe: (_) => null,
        ).inventory().single;

        expect(listing.status, PatchbaySessionStatus.live);
        expect(listing.identityUnverified, isTrue);
        expect(listing.label, contains('identityUnverified'));
        expect(listing.toJson()['identityUnverified'], isTrue);
      },
    );
  });

  group('legacy records without a captured launch identity', () {
    test(
      'resolve() and inventory() behave exactly as before this change',
      () async {
        store.write(_record('legacy', processStartTime: null));

        final resolved = await PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => true,
          // Whatever the probe answers must not matter: there is nothing on
          // the record to compare it against.
          processStartTimeProbe: (_) => 'anything-at-all',
          identityProbe: (_) async => _identity(),
        ).resolve();
        expect(resolved.record.sessionId, 'legacy');

        final PatchbaySessionListing listing = PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => true,
          processStartTimeProbe: (_) => 'anything-at-all',
        ).inventory().single;
        expect(listing.status, PatchbaySessionStatus.live);
        expect(listing.identityUnverified, isTrue);
      },
    );

    test('a dead PID is still stale regardless of the missing field', () {
      store.write(_record('legacy-dead', processStartTime: null));

      expect(
        () => PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => false,
        ).select('legacy-dead'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
    });
  });

  group('field round trip', () {
    test('processStartTime survives write/read and completedWith', () async {
      store.write(_record('roundtrip', processStartTime: 'launch-signature'));

      expect(store.readAll().single.processStartTime, 'launch-signature');

      final resolved = await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'launch-signature',
        identityProbe: (_) async => _identity(),
      ).resolve();

      // completedWith() must carry the captured signature through, or every
      // resolve() after the first would silently lose it and regress to
      // "always unverified".
      expect(resolved.record.processStartTime, 'launch-signature');
      expect(store.readAll().single.processStartTime, 'launch-signature');
    });

    test('pendingRecord() captures the signature at creation time', () {
      const PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-1',
        ownerPid: 4242,
      );
      final _FakeProcessRunner runner = _FakeProcessRunner(
        (executable, arguments) => ProcessResult(0, 0, 'launch-time-x', ''),
      );

      final PatchbaySessionRecord record = context.pendingRecord(
        sessionId: 'created',
        applicationId: 'dev.patchbay.fixture',
        processId: 4321,
        buildMode: 'debug',
        createdAt: DateTime.utc(2026, 8, 25),
        workspacePath: '/repo/worktree',
        deviceId: 'device-1',
        processRunner: runner,
        isWindows: false,
      );

      expect(record.processStartTime, 'launch-time-x');
      expect(runner.invocations.single.executable, 'ps');
      expect(runner.invocations.single.arguments, [
        '-o',
        'lstart=',
        '-p',
        '4321',
      ]);
    });

    test(
      'pendingRecord() leaves processStartTime null when the probe fails',
      () {
        const PatchbayLaunchContext context = PatchbayLaunchContext(
          sessionDirectory: '/unused',
          launchId: 'launch-1',
          ownerPid: 4242,
        );
        final _FakeProcessRunner runner = _FakeProcessRunner(
          (executable, arguments) => ProcessResult(0, 1, '', 'no such process'),
        );

        final PatchbaySessionRecord record = context.pendingRecord(
          sessionId: 'created',
          applicationId: 'dev.patchbay.fixture',
          processId: 4321,
          buildMode: 'debug',
          createdAt: DateTime.utc(2026, 8, 25),
          workspacePath: '/repo/worktree',
          deviceId: 'device-1',
          processRunner: runner,
          isWindows: false,
        );

        expect(record.processStartTime, isNull);
      },
    );

    test('invalid processId is still rejected before any probe runs', () {
      const PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-1',
        ownerPid: 4242,
      );
      final _FakeProcessRunner runner = _FakeProcessRunner(
        (executable, arguments) =>
            fail('processId <= 0 must fail before probing'),
      );

      expect(
        () => context.pendingRecord(
          sessionId: 'invalid',
          applicationId: 'dev.patchbay.fixture',
          processId: 0,
          buildMode: 'debug',
          createdAt: DateTime.utc(2026, 8, 25),
          workspacePath: '/repo/worktree',
          deviceId: 'device-1',
          processRunner: runner,
        ),
        throwsA(_sessionError('sessionRecordInvalid')),
      );
      expect(runner.invocations, isEmpty);
    });
  });

  test('toJson omits processStartTime entirely when absent (additive)', () {
    final PatchbaySessionRecord record = _record(
      'no-identity',
      processStartTime: null,
    );
    expect(record.toJson().containsKey('processStartTime'), isFalse);
  });

  test('toJson includes processStartTime when captured', () {
    final PatchbaySessionRecord record = _record(
      'with-identity',
      processStartTime: 'launch-signature',
    );
    expect(record.toJson()['processStartTime'], 'launch-signature');
  });

  test('fromJson rejects a non-string, empty processStartTime', () {
    final Map<String, Object?> json = _record(
      'x',
      processStartTime: null,
    ).toJson()..['processStartTime'] = '';

    expect(
      () => PatchbaySessionRecord.fromJson(json),
      throwsA(_sessionError('sessionRecordInvalid')),
    );
  });
}

Matcher _sessionError(String code) =>
    isA<PatchbaySessionException>().having((error) => error.code, 'code', code);

PatchbayRuntimeIdentity _identity() => const PatchbayRuntimeIdentity(
  schemaVersion: 1,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: 'instance-1',
  isolateId: 'isolates/1',
);

PatchbaySessionRecord _record(
  String id, {
  String? processStartTime,
  int processId = 4242,
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: null,
  isolateId: null,
  processId: processId,
  wsUri: 'ws://127.0.0.1:1234/auth/ws',
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 20),
  workspacePath: '/repo/worktree',
  deviceId: 'device-1',
  processStartTime: processStartTime,
);

final class _Invocation {
  const _Invocation(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

final class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner(this._handler);

  final ProcessResult Function(String executable, List<String> arguments)
  _handler;
  final List<_Invocation> invocations = <_Invocation>[];

  @override
  ProcessResult runSync(String executable, List<String> arguments) {
    invocations.add(_Invocation(executable, arguments));
    return _handler(executable, arguments);
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
  }) => throw UnimplementedError();
}
