import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test(
    'job registry records ordered terminal events and cancellation',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        now: () => DateTime.utc(2026, 8, 12),
      );
      final Completer<Map<String, Object?>> pending =
          Completer<Map<String, Object?>>();
      var cancelled = false;
      final String jobId = jobs.start(
        source: PatchbayFactSource.appRecorded,
        operation: 'fixture.wait',
        body: () => pending.future,
        cancel: () => cancelled = true,
      );

      expect(jobs.snapshot(jobId)?.terminal, isFalse);
      expect(await jobs.cancel(jobId, reason: 'consentRevoked'), isTrue);
      expect(cancelled, isTrue);
      expect(jobs.snapshot(jobId)?.terminal, isTrue);
      expect(
        jobs.snapshot(jobId)?.events.map((PatchbayJobEvent e) => e.sequence),
        <int>[1, 2],
      );
      expect(jobs.snapshot(jobId)?.events.last.reason, 'consentRevoked');
      expect(
        jobs.snapshot(jobId)?.events.first.toJson(),
        containsPair('source', PatchbayFactSource.appRecorded.name),
      );
      expect(
        jobs.snapshot(jobId)?.events.first.toJson(),
        containsPair('operation', 'fixture.wait'),
      );
      pending.complete(const <String, Object?>{'ignored': true});
    },
  );

  test('job registry preserves redacted domain failure evidence', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry();
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      operation: 'pairing.ble.pair',
      body: () async => throw const PatchbayJobFailure(
        reason: 'pairingFailed',
        payload: <String, Object?>{
          'terminalState': 'failed',
          'errorCode': 'device.offline',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final PatchbayJobEvent terminal = jobs.snapshot(jobId)!.events.last;
    expect(terminal.phase, PatchbayJobPhase.failed);
    expect(terminal.reason, 'pairingFailed');
    expect(terminal.payload['errorCode'], 'device.offline');
  });

  test('settled jobs are evicted while running jobs are retained', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry(retainedJobs: 3);
    final Completer<Map<String, Object?>> pending =
        Completer<Map<String, Object?>>();
    final String running = jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => pending.future,
    );
    final List<String> settled = <String>[];
    for (var i = 0; i < 6; i += 1) {
      settled.add(
        jobs.start(
          source: PatchbayFactSource.appRecorded,
          body: () async => const <String, Object?>{'ok': true},
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    expect(jobs.snapshot(running), isNotNull);
    expect(jobs.snapshot(settled.first), isNull);
    expect(jobs.snapshot(settled[2]), isNull);
    expect(jobs.snapshot(settled[3]), isNotNull);
    expect(jobs.snapshot(settled.last), isNotNull);
    expect(jobs.runningJobs, 1);
    expect(jobs.settledJobs, 3);
    expect(jobs.totalJobs, 4);
    pending.complete(const <String, Object?>{'ok': true});
  });

  test('job registry enforces a configurable running-job budget', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry(maxRunningJobs: 2);
    final Completer<Map<String, Object?>> first =
        Completer<Map<String, Object?>>();
    final Completer<Map<String, Object?>> second =
        Completer<Map<String, Object?>>();
    jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => first.future,
    );
    jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => second.future,
    );

    expect(
      () => jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () async => const <String, Object?>{},
      ),
      throwsA(
        isA<PatchbayJobCapacityExceeded>().having(
          (PatchbayJobCapacityExceeded error) => error.maxRunningJobs,
          'maxRunningJobs',
          2,
        ),
      ),
    );
    expect(jobs.runningJobs, 2);

    first.complete(const <String, Object?>{});
    await Future<void>.delayed(Duration.zero);
    final String replacement = jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () async => const <String, Object?>{},
    );
    expect(replacement, isNotEmpty);
    second.complete(const <String, Object?>{});
  });

  test('job cancellation timeout leaves completion state unclaimed', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry(
      cancellationTimeout: const Duration(milliseconds: 1),
    );
    final Completer<Map<String, Object?>> body =
        Completer<Map<String, Object?>>();
    final Completer<void> cancellation = Completer<void>();
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => body.future,
      cancel: () => cancellation.future,
    );

    await expectLater(jobs.cancel(jobId), throwsA(isA<TimeoutException>()));
    expect(jobs.snapshot(jobId)?.terminal, isFalse);
    expect(jobs.runningJobs, 1);

    cancellation.complete();
    body.complete(const <String, Object?>{});
  });

  test('job without cancellation capability stays running', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry();
    final Completer<Map<String, Object?>> body =
        Completer<Map<String, Object?>>();
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => body.future,
    );

    expect(await jobs.cancel(jobId), isFalse);
    expect(jobs.snapshot(jobId)?.terminal, isFalse);
    expect(jobs.runningJobs, 1);

    body.complete(const <String, Object?>{});
  });

  test(
    'cancelAll invokes every cancellation callback before awaiting',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        cancellationTimeout: const Duration(seconds: 2),
      );
      final Completer<Map<String, Object?>> firstBody =
          Completer<Map<String, Object?>>();
      final Completer<Map<String, Object?>> secondBody =
          Completer<Map<String, Object?>>();
      final Completer<void> bothInvoked = Completer<void>();
      var invocations = 0;
      Future<void> rendezvous() {
        invocations += 1;
        if (invocations == 2 && !bothInvoked.isCompleted) {
          bothInvoked.complete();
        }
        return bothInvoked.future;
      }

      final String first = jobs.start(
        source: PatchbayFactSource.appRecorded,
        operation: 'fixture.first',
        body: () => firstBody.future,
        cancel: rendezvous,
      );
      final String second = jobs.start(
        source: PatchbayFactSource.appRecorded,
        operation: 'fixture.second',
        body: () => secondBody.future,
        cancel: rendezvous,
      );

      final Map<String, PatchbayJobCancelOutcome> outcomes = await jobs
          .cancelAll(reason: 'sessionClosed');

      expect(invocations, 2);
      expect(outcomes, <String, PatchbayJobCancelOutcome>{
        first: PatchbayJobCancelOutcome.cancelled,
        second: PatchbayJobCancelOutcome.cancelled,
      });
      expect(jobs.snapshot(first)?.events.last.reason, 'sessionClosed');
      expect(jobs.snapshot(second)?.events.last.reason, 'sessionClosed');
      expect(jobs.runningJobs, 0);

      firstBody.complete(const <String, Object?>{});
      secondBody.complete(const <String, Object?>{});
    },
  );

  test('cancelAll converges per job instead of serialising timeouts', () {
    // 逻辑时钟而不是墙钟：cancelAll 的超时走 Zone 计时器（Future.timeout），
    // 在 FakeAsync 里恰好推进一个 cancellationTimeout 就必须收敛——并行收敛在
    // 逻辑时刻 300ms 完成，串行则要到 600ms 才可能完成，鉴别力比原来的
    // 「Stopwatch < timeout*2」严格，且不再随 CI runner 负载漂移（sdk_floor lane
    // 首跑 Linux 时曾因冷环境把 845ms 的真实耗时打穿 600ms 的墙钟断言）。
    FakeAsync().run((FakeAsync async) {
      const Duration timeout = Duration(milliseconds: 300);
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        cancellationTimeout: timeout,
      );
      final Completer<Map<String, Object?>> bodies =
          Completer<Map<String, Object?>>();
      final Completer<void> neverConfirms = Completer<void>();
      final String stuckFirst = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
        cancel: () => neverConfirms.future,
      );
      final String stuckSecond = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
        cancel: () => neverConfirms.future,
      );
      final String confirming = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
        cancel: () {},
      );
      final String uncancellable = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
      );

      Map<String, PatchbayJobCancelOutcome>? outcomes;
      unawaited(
        jobs.cancelAll(reason: 'sessionClosed').then((
          Map<String, PatchbayJobCancelOutcome> value,
        ) {
          outcomes = value;
        }),
      );

      // 差一个 microtask 都不该提前完成；推满一个 timeout 后必须已完成。
      async.elapse(timeout - const Duration(milliseconds: 1));
      expect(outcomes, isNull, reason: 'cancelAll 不应早于 cancellationTimeout 完成');
      async.elapse(const Duration(milliseconds: 1));
      expect(
        outcomes,
        isNotNull,
        reason:
            '并行收敛应在恰好一个 cancellationTimeout 的逻辑时刻完成；'
            '串行化会需要每个卡死 job 各占一个 timeout',
      );

      expect(outcomes, <String, PatchbayJobCancelOutcome>{
        stuckFirst: PatchbayJobCancelOutcome.timedOut,
        stuckSecond: PatchbayJobCancelOutcome.timedOut,
        confirming: PatchbayJobCancelOutcome.cancelled,
        uncancellable: PatchbayJobCancelOutcome.notCancellable,
      });
      expect(jobs.snapshot(stuckFirst)?.terminal, isFalse);
      expect(jobs.snapshot(stuckSecond)?.terminal, isFalse);
      expect(jobs.snapshot(uncancellable)?.terminal, isFalse);
      expect(
        jobs.snapshot(confirming)?.events.last.phase,
        PatchbayJobPhase.cancelled,
      );
      expect(jobs.runningJobs, 3);

      neverConfirms.complete();
      bodies.complete(const <String, Object?>{});
      async.flushMicrotasks();
    });
  });

  test(
    'cancelAll reports a throwing callback without aborting the sweep',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry();
      final Completer<Map<String, Object?>> bodies =
          Completer<Map<String, Object?>>();
      final String throwing = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
        cancel: () => throw StateError('controller detached'),
      );
      final String confirming = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => bodies.future,
        cancel: () {},
      );

      final Map<String, PatchbayJobCancelOutcome> outcomes = await jobs
          .cancelAll(reason: 'sessionClosed');

      expect(outcomes[throwing], PatchbayJobCancelOutcome.callbackFailed);
      expect(outcomes[confirming], PatchbayJobCancelOutcome.cancelled);
      expect(jobs.snapshot(throwing)?.terminal, isFalse);
      expect(jobs.snapshot(confirming)?.terminal, isTrue);
      expect(jobs.runningJobs, 1);

      bodies.complete(const <String, Object?>{});
    },
  );

  test(
    'cancelAll never overwrites a job that reached its own terminal state',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry();
      final String settled = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () async => const <String, Object?>{'ok': true},
        cancel: () {},
      );
      await Future<void>.delayed(Duration.zero);
      final Completer<Map<String, Object?>> racing =
          Completer<Map<String, Object?>>();
      final String racingJob = jobs.start(
        source: PatchbayFactSource.appRecorded,
        body: () => racing.future,
        cancel: () async {
          racing.complete(const <String, Object?>{'ok': true});
          await Future<void>.delayed(Duration.zero);
        },
      );

      final Map<String, PatchbayJobCancelOutcome> outcomes = await jobs
          .cancelAll(reason: 'sessionClosed');

      expect(outcomes.containsKey(settled), isFalse);
      expect(outcomes[racingJob], PatchbayJobCancelOutcome.alreadySettled);
      expect(
        jobs.snapshot(settled)?.events.last.phase,
        PatchbayJobPhase.completed,
      );
      expect(
        jobs.snapshot(racingJob)?.events.map((PatchbayJobEvent e) => e.phase),
        <PatchbayJobPhase>[
          PatchbayJobPhase.running,
          PatchbayJobPhase.completed,
        ],
      );
    },
  );

  test(
    'job wait observes changes without polling and returns generated wire',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry();
      final Completer<Map<String, Object?>> body =
          Completer<Map<String, Object?>>();
      final String jobId = jobs.start(
        source: PatchbayFactSource.deviceReported,
        operation: 'fixture.complete',
        body: () => body.future,
      );

      final Future<PatchbayJobWaitResult?> waiting = jobs.waitForChange(
        jobId,
        afterSequence: 1,
        timeout: const Duration(seconds: 1),
      );
      var completed = false;
      waiting.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      body.complete(const <String, Object?>{'deviceId': 'redacted-fixture'});
      final PatchbayJobWaitResult result = (await waiting)!;
      expect(result.outcome, PatchbayJobWaitOutcome.changed);
      expect(result.snapshot.terminal, isTrue);
      expect(
        PatchbayJobWaitResultWire.fromJson(result.toJson()).outcome,
        PatchbayJobWaitOutcomeWire.changed,
      );
    },
  );

  test('job wait distinguishes timeout and unknown job', () async {
    final PatchbayJobRegistry jobs = PatchbayJobRegistry();
    final Completer<Map<String, Object?>> body =
        Completer<Map<String, Object?>>();
    final String jobId = jobs.start(
      source: PatchbayFactSource.appRecorded,
      body: () => body.future,
    );

    final PatchbayJobWaitResult timedOut = (await jobs.waitForChange(
      jobId,
      afterSequence: 1,
      timeout: const Duration(milliseconds: 1),
    ))!;
    expect(timedOut.outcome, PatchbayJobWaitOutcome.timedOut);
    expect(timedOut.snapshot.terminal, isFalse);
    expect(
      await jobs.waitForChange(
        'missing',
        afterSequence: 0,
        timeout: const Duration(milliseconds: 1),
      ),
      isNull,
    );
    body.complete(const <String, Object?>{});
  });
}
