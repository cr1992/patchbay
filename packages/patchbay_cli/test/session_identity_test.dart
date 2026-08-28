/// PB-050-18：会话存活判定从裸 PID 升级为「PID + 进程启动身份」。
///
/// 覆盖三件事：PID 复用（同 PID 存活但启动时间不同）必须判死；启动身份采集不到时必须
/// 降级成旧的纯 PID 判定，而不是 fail-closed 杀掉一个其实还活着的会话；旧记录（没有
/// `processStartTime` 字段）在诊断输出里标注 `identityUnverified`，但存活判断完全不变。
///
/// BUG-20260827-01 追加第四件：PID 探测本身也可能问不到（没有 `procps` 的镜像里
/// `kill` 根本不是可执行文件）。那种「没问到」必须与「问到了，进程不在」区分开，
/// 同样降级成 unverified——把两者压成一个 `false` 会让这类主机上的每条记录都被删。
///
/// PB-050-31 追加第五件：签名字符串本身也可能读不懂。旧格式是 `ps -o lstart=` 的
/// 输出，按**读取方**的时区渲染，同一个活进程跨 shell / cron / CI 容器 / DST 读两次
/// 就得到两个不等的字符串，被判成 PID 复用把活会话删掉。签名改为带 scheme 前缀，
/// 无前缀或 scheme 不同一律降级 unverified；同 scheme 下不等仍照旧判死。
/// 本文件里的签名 fixture 因此带 `v2-posix:` / `v2-linux:` 前缀——断言语义未变，
/// 变的是 fixture 必须是一个真实格式的签名才可能进入「判死」分支。
library;

import 'dart:io';

import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/platform/process_utils.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_resolver.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
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
        store.write(_record('reused', processStartTime: 'v2-posix:launch-a'));

        await expectLater(
          PatchbaySessionResolver(
            store: store,
            workspaceProbe: () => _workspace,
            workspaceIdentityAt: (_) => null,
            pidProbe: (_) => true,
            // The PID answers "alive", but it belongs to a different
            // process now -- the OS recycled it after the original App
            // exited.
            processStartTimeProbe: (_) => 'v2-posix:launch-b',
          ).resolve(),
          throwsA(_sessionError('sessionStaleProcess')),
        );
        expect(store.readAll(), isEmpty);
      },
    );

    test('select() refuses to pin a record whose PID was recycled', () {
      store.write(_record('reused', processStartTime: 'v2-posix:launch-a'));

      final resolver = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:launch-b',
      );

      expect(
        () => resolver.select('reused'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
      expect(store.readSelectionFor(_workspace), isNull);
      expect(store.readAll(), isEmpty);
    });

    test('inventory() marks a PID-reuse collision stale, not unverified', () {
      store.write(_record('reused', processStartTime: 'v2-posix:launch-a'));

      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:launch-b',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.stale);
      // A definite mismatch is a positive answer, not "could not verify".
      expect(listing.identityUnverified, isFalse);
    });

    test('a matching start time is treated as the same process', () async {
      store.write(_record('same', processStartTime: 'v2-posix:launch-a'));

      final resolved = await PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:launch-a',
        identityProbe: (_) async => _identity(),
      ).resolve();

      expect(resolved.record.sessionId, 'same');
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:launch-a',
      ).inventory().single;
      expect(listing.identityUnverified, isFalse);
    });
  });

  group('PB-050-31: a signature it cannot interpret is not a mismatch', () {
    // The defect this group exists for: `processStartTime` used to hold raw
    // `ps -o lstart=` output, which renders in the *reader's* timezone. Two
    // reads of one live process from two shells produced two unequal strings,
    // `_checkProcessIdentity` called that PID reuse, and the record of a
    // running App was deleted. Signatures now carry a scheme tag, and
    // anything unreadable degrades instead of judging.

    test('an unprefixed dev-era record is never judged dead', () async {
      // Exactly the pair the defect produced: same PID, same launch, read
      // under `TZ=UTC` and under `TZ=Asia/Taipei`.
      store.write(
        _record('dev-era', processStartTime: 'Fri Aug 28 01:47:22 2026'),
      );

      final resolved = await PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:Fri Aug 28 09:47:22 2026',
        identityProbe: (_) async => _identity(),
      ).resolve();

      expect(resolved.record.sessionId, 'dev-era');
      expect(store.readAll(), hasLength(1));
    });

    test('and inventory() reports it live and unverified, never stale', () {
      store.write(
        _record('dev-era', processStartTime: 'Fri Aug 28 01:47:22 2026'),
      );

      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:Fri Aug 28 09:47:22 2026',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.live);
      expect(listing.identityUnverified, isTrue);
    });

    test('two known schemes that disagree are not comparable', () {
      // A Linux host that recorded a procfs signature and later probes with
      // procfs unavailable gets a `v2-posix` answer back. Not comparable is
      // not the same as not equal.
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store
          ..write(
            _record(
              'moved',
              processStartTime:
                  'v2-linux:00000000-0000-4000-8000-000000000001:7128607',
            ),
          ),
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:Fri Aug 28 01:47:22 2026',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.live);
      expect(listing.identityUnverified, isTrue);
    });

    test('an unprefixed record is unverified even when the strings match', () {
      // Deliberate. A format this build cannot interpret proves nothing in
      // either direction, so it must not be reported as verified either.
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store
          ..write(
            _record('dev-era', processStartTime: 'Fri Aug 28 01:47:22 2026'),
          ),
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'Fri Aug 28 01:47:22 2026',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.live);
      expect(listing.identityUnverified, isTrue);
    });

    test('a dev-era record with a dead PID is still stale', () {
      // The degrade is scoped to the signature comparison. A PID the OS
      // positively reports as gone is still gone.
      store.write(
        _record('dev-era-dead', processStartTime: 'Fri Aug 28 01:47:22 2026'),
      );

      expect(
        () => PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
          pidProbe: (_) => false,
        ).select('dev-era-dead'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
      expect(store.readAll(), isEmpty);
    });

    test('a procfs signature still detects PID reuse within its scheme', () {
      // The PB-050-18 guard, in the new format: same boot, different tick
      // count means the kernel handed this PID to something else.
      const String bootId = '00000000-0000-4000-8000-000000000001';
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store
          ..write(
            _record('reused', processStartTime: 'v2-linux:$bootId:7128607'),
          ),
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-linux:$bootId:9000000',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.stale);
      expect(listing.identityUnverified, isFalse);
    });

    test('a reboot at the same tick offset is still a different launch', () {
      // Why `boot_id` is part of the signature at all: ticks are counted from
      // boot, so without it a PID reissued at the same offset into a later
      // boot would read as the same process.
      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store
          ..write(
            _record(
              'rebooted',
              processStartTime:
                  'v2-linux:00000000-0000-4000-8000-000000000001:7128607',
            ),
          ),
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) =>
            'v2-linux:00000000-0000-4000-8000-000000000002:7128607',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.stale);
      expect(listing.identityUnverified, isFalse);
    });
  });

  group('start-time probe failure degrades, never fail-closed', () {
    test(
      'a live PID whose start time cannot be captured stays alive, flagged',
      () async {
        store.write(
          _record('unverifiable', processStartTime: 'v2-posix:launch-a'),
        );

        final resolved = await PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
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
        store.write(
          _record('unverifiable', processStartTime: 'v2-posix:launch-a'),
        );

        final PatchbaySessionListing listing = PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
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

  group('PID probe cannot answer, so nothing may be concluded', () {
    // BUG-20260827-01. `PlatformProcessUtils.isProcessAlive` used to collapse
    // "the OS says no" and "there is no `kill` on PATH" into the same `false`.
    // On any image without `procps` -- `dart:stable`, Debian/Ubuntu `-slim`,
    // distroless -- that made every command report `sessionStaleProcess` and
    // delete a record whose App was running the whole time.
    test('an unanswerable PID stays alive, flagged unverified', () async {
      store.write(
        _record('unanswerable', processStartTime: 'v2-posix:launch-a'),
      );

      final resolved = await PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => null,
        // Must never be consulted: with no verdict on the PID there is
        // nothing for a launch signature to be a signature *of*.
        processStartTimeProbe: (_) =>
            fail('the start-time probe must not run without a PID verdict'),
        identityProbe: (_) async => _identity(),
      ).resolve();

      expect(resolved.record.sessionId, 'unanswerable');
      expect(store.readAll(), hasLength(1));
    });

    test('inventory() reports it live and unverified, never stale', () {
      store.write(
        _record('unanswerable', processStartTime: 'v2-posix:launch-a'),
      );

      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => null,
        processStartTimeProbe: (_) => 'v2-posix:launch-b',
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.live);
      expect(listing.identityUnverified, isTrue);
    });

    test('prune() does not delete a record it could not judge', () {
      store.write(
        _record('unanswerable', processStartTime: 'v2-posix:launch-a'),
      );

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => null,
      ).prune();

      expect(result.removed, isEmpty);
      expect(store.readAll(), hasLength(1));
    });

    test('select() still pins it rather than refusing', () {
      store.write(
        _record('unanswerable', processStartTime: 'v2-posix:launch-a'),
      );

      final PatchbaySessionListing listing = PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => null,
      ).select('unanswerable');

      expect(listing.identityUnverified, isTrue);
      expect(store.readSelectionFor(_workspace), 'unanswerable');
    });

    test(
      'an unresolvable pin is not sent to `prune`, which cannot help',
      () async {
        // The hint has to survive being acted on. `prune` only removes records
        // whose status is stale; an unverifiable process reads as alive, and
        // the pending-TTL branch that would otherwise expire the record fires
        // only when there is no wsUri. So the old advice was a loop here.
        store.write(
          _record('unanswerable', processStartTime: 'v2-posix:launch-a'),
        );
        store.writeSelectionFor(_workspace, 'unanswerable');

        await expectLater(
          PatchbaySessionResolver(
            store: store,
            workspaceProbe: () => _workspace,
            workspaceIdentityAt: (_) => null,
            pidProbe: (_) => null,
            identityProbe: (_) async =>
                throw const SocketException('connection refused'),
          ).resolve(),
          throwsA(
            isA<PatchbaySessionException>()
                .having((error) => error.code, 'code', 'sessionUnreachable')
                // Never the imperative. The old hint opened with "run
                // `patchbay sessions prune`", and acting on that here
                // changes nothing.
                .having(
                  (error) => error.hint,
                  'hint',
                  isNot(contains('run `patchbay sessions prune`')),
                )
                // Naming prune in order to rule it out beats omitting it:
                // the operator's next instinct is the command we just
                // disarmed, so the hint should say why it will not work.
                .having(
                  (error) => error.hint,
                  'hint',
                  contains('cannot retire the record'),
                )
                .having(
                  (error) => error.hint,
                  'hint',
                  contains('session use --clear'),
                ),
          ),
        );
        // Still on disk -- precisely why prune would have been a loop.
        expect(store.readAll(), hasLength(1));
      },
    );

    test('a verifiably dead pin still gets the ordinary prune hint', () async {
      // The swap must stay narrow: when the OS did answer, `prune` works and
      // is still the right thing to recommend.
      store.write(
        _record('really-dead', processStartTime: 'v2-posix:launch-a'),
      );
      store.writeSelectionFor(_workspace, 'really-dead');

      await expectLater(
        PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
          pidProbe: (_) => false,
        ).resolve(),
        throwsA(
          isA<PatchbaySessionException>()
              .having((error) => error.code, 'code', 'sessionStaleProcess')
              // The imperative form specifically: the unverifiable-host hint
              // also contains the word "prune", but only in order to rule it
              // out, so a bare contains('prune') would not tell them apart.
              .having(
                (error) => error.hint,
                'hint',
                contains('run `patchbay sessions prune`'),
              ),
        ),
      );
    });

    test('a merely unverified launch identity keeps the prune hint', () async {
      // livenessUnverified is deliberately narrower than identityUnverified:
      // here the PID *was* observed, so the new hint's claim that this host
      // cannot answer the liveness question would be a lie.
      store.write(_record('legacy', processStartTime: null));
      store.writeSelectionFor(_workspace, 'legacy');

      await expectLater(
        PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
          pidProbe: (_) => true,
          identityProbe: (_) async =>
              throw const SocketException('connection refused'),
        ).resolve(),
        throwsA(
          isA<PatchbaySessionException>()
              .having((error) => error.code, 'code', 'sessionUnreachable')
              // The imperative form specifically: the unverifiable-host hint
              // also contains the word "prune", but only in order to rule it
              // out, so a bare contains('prune') would not tell them apart.
              .having(
                (error) => error.hint,
                'hint',
                contains('run `patchbay sessions prune`'),
              ),
        ),
      );
    });

    test(
      'a definite "not running" is still stale -- the guard is not weakened',
      () {
        store.write(
          _record('really-dead', processStartTime: 'v2-posix:launch-a'),
        );

        expect(
          () => PatchbaySessionResolver(
            store: store,
            workspaceProbe: () => _workspace,
            workspaceIdentityAt: (_) => null,
            pidProbe: (_) => false,
          ).select('really-dead'),
          throwsA(_sessionError('sessionStaleProcess')),
        );
        expect(store.readAll(), isEmpty);
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
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
          pidProbe: (_) => true,
          // Whatever the probe answers must not matter: there is nothing on
          // the record to compare it against.
          processStartTimeProbe: (_) => 'anything-at-all',
          identityProbe: (_) async => _identity(),
        ).resolve();
        expect(resolved.record.sessionId, 'legacy');

        final PatchbaySessionListing listing = PatchbaySessionResolver(
          store: store,
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
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
          workspaceProbe: () => _workspace,
          workspaceIdentityAt: (_) => null,
          pidProbe: (_) => false,
        ).select('legacy-dead'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
    });
  });

  group('field round trip', () {
    test('processStartTime survives write/read and completedWith', () async {
      store.write(
        _record('roundtrip', processStartTime: 'v2-posix:launch-signature'),
      );

      expect(
        store.readAll().single.processStartTime,
        'v2-posix:launch-signature',
      );

      final resolved = await PatchbaySessionResolver(
        store: store,
        workspaceProbe: () => _workspace,
        workspaceIdentityAt: (_) => null,
        pidProbe: (_) => true,
        processStartTimeProbe: (_) => 'v2-posix:launch-signature',
        identityProbe: (_) async => _identity(),
      ).resolve();

      // completedWith() must carry the captured signature through, or every
      // resolve() after the first would silently lose it and regress to
      // "always unverified".
      expect(resolved.record.processStartTime, 'v2-posix:launch-signature');
      expect(
        store.readAll().single.processStartTime,
        'v2-posix:launch-signature',
      );
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
        workspacePath: _workspace.canonicalRoot,
        deviceId: 'device-1',
        processRunner: runner,
        isWindows: false,
        // Pinned so this asserts the `ps` fallback on every host: on Linux
        // the probe would otherwise read the real procfs and never reach the
        // runner at all.
        isLinux: false,
      );

      // PB-050-31: what lands on the record is scheme-tagged, so a later
      // reader can tell "different launch" from "format I cannot read".
      expect(record.processStartTime, 'v2-posix:launch-time-x');
      expect(runner.invocations.single.executable, 'ps');
      expect(runner.invocations.single.arguments, [
        '-o',
        'lstart=',
        '-p',
        '4321',
      ]);
      expect(runner.invocations.single.environment, {
        'TZ': 'UTC',
        'LC_ALL': 'C',
      });
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
          workspacePath: _workspace.canonicalRoot,
          deviceId: 'device-1',
          processRunner: runner,
          isWindows: false,
          isLinux: false,
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
          workspacePath: _workspace.canonicalRoot,
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
      processStartTime: 'v2-posix:launch-signature',
    );
    expect(record.toJson()['processStartTime'], 'v2-posix:launch-signature');
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

/// The checkout every record here belongs to: PB-050-18's liveness rules are
/// orthogonal to PB-050-14's affinity rules, so this file keeps one workspace
/// and lets the affinity suite own the cross-checkout matrix.
final PatchbayWorkspaceIdentity _workspace = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/repo/worktree',
)!;

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
  workspacePath: _workspace.canonicalRoot,
  deviceId: 'device-1',
  processStartTime: processStartTime,
).withWorkspace(_workspace);

final class _Invocation {
  const _Invocation(this.executable, this.arguments, this.environment);
  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

final class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner(this._handler);

  final ProcessResult Function(String executable, List<String> arguments)
  _handler;
  final List<_Invocation> invocations = <_Invocation>[];

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    invocations.add(_Invocation(executable, arguments, environment));
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
