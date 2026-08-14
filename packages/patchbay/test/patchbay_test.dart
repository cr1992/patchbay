import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test('service host registers fixed RPCs and serves identity', () async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      appInstanceId: 'instance-1',
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
      catalog: () async => <String, Object?>{'commands': const <Object?>[]},
      snapshot: () async => <String, Object?>{
        'source': PatchbayFactSource.appRecorded.name,
      },
      invoke: (command, arguments, requestId) async =>
          PatchbayInvocation.rejected(
            requestId: requestId,
            rejection: PatchbayRejection(
              code: 'notRegistered',
              details: <String, Object?>{
                'command': command,
                'argumentCount': arguments.length,
              },
            ),
          ).toJson(),
    )..register();
    host.register();

    expect(handlers.keys, <String>{
      PatchbayServiceHost.identityMethod,
      PatchbayServiceHost.catalogMethod,
      PatchbayServiceHost.snapshotMethod,
      PatchbayServiceHost.invokeMethod,
    });
    final ServiceExtensionResponse response =
        await handlers[PatchbayServiceHost.identityMethod]!(
          PatchbayServiceHost.identityMethod,
          const <String, String>{},
        );
    expect(
      jsonDecode(response.result!),
      containsPair('appInstanceId', 'instance-1'),
    );
  });

  test('service host serves a fixed snapshot RPC', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      appInstanceId: 'instance-2',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => <String, Object?>{
        'source': PatchbayFactSource.appRecorded.name,
      },
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    final ServiceExtensionResponse response = await host.handleSnapshot(
      PatchbayServiceHost.snapshotMethod,
      const <String, String>{},
    );

    expect(
      jsonDecode(response.result!),
      containsPair('source', PatchbayFactSource.appRecorded.name),
    );
  });

  test('service host owns schemaVersion in catalog and snapshot', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => <String, Object?>{
        'schemaVersion': 999,
        'commands': const <Object?>[],
      },
      snapshot: () async => <String, Object?>{'schemaVersion': 999},
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    expect(
      await host.dispatchCatalog(),
      containsPair('schemaVersion', PatchbayServiceHost.schemaVersion),
    );
    expect(
      await host.dispatchSnapshot(),
      containsPair('schemaVersion', PatchbayServiceHost.schemaVersion),
    );
  });

  test('service host rejects duplicate command names in catalog', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => <String, Object?>{
        'commands': const <Object?>[
          <String, Object?>{'name': 'device.select'},
          <String, Object?>{'name': 'device.select'},
        ],
      },
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    await expectLater(host.dispatchCatalog(), throwsStateError);
  });

  test(
    'service host rejects non-descriptor and invalid command names',
    () async {
      for (final Object? command in <Object?>[
        'device.select',
        const <String, Object?>{'name': ' device.select '},
        const <String, Object?>{'name': 'Device.select'},
      ]) {
        final PatchbayServiceHost host = PatchbayServiceHost(
          applicationId: 'dev.patchbay.test',
          registrar: (_, _) {},
          catalog: () async => <String, Object?>{
            'commands': <Object?>[command],
          },
          snapshot: () async => const <String, Object?>{},
          invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
            requestId: requestId,
            rejection: const PatchbayRejection(code: 'notRegistered'),
          ).toJson(),
        );

        await expectLater(host.dispatchCatalog(), throwsStateError);
      }
    },
  );

  test('service host replaces invalid provider invocation envelopes', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, _) async => PatchbayInvocation.accepted(
        requestId: 'provider-generated-id',
      ).toJson(),
    );

    final Map<String, Object?> result = await host.dispatchInvoke(
      'device.select',
      const <String, Object?>{},
      'caller-request-id',
    );

    expect(result['requestId'], 'caller-request-id');
    expect(result['admission'], 'rejected');
    expect(
      (result['rejection']! as Map<String, Object?>)['code'],
      'providerProtocolViolation',
    );
    expect(
      ((result['rejection']! as Map<String, Object?>)['details']!
          as Map<String, Object?>)['reason'],
      'requestIdMismatch',
    );
  });

  test(
    'service host rejects empty request IDs before provider dispatch',
    () async {
      var providerCalled = false;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{},
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async {
          providerCalled = true;
          return PatchbayInvocation.accepted(requestId: requestId).toJson();
        },
      );

      await expectLater(
        host.dispatchInvoke('device.select', const <String, Object?>{}, ''),
        throwsArgumentError,
      );
      expect(providerCalled, isFalse);
    },
  );

  test('service host rejects semantically contradictory envelopes', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async => <String, Object?>{
        ...PatchbayInvocation.accepted(requestId: requestId).toJson(),
        'rejection': const <String, Object?>{'code': 'contradiction'},
      },
    );

    final Map<String, Object?> result = await host.dispatchInvoke(
      'device.select',
      const <String, Object?>{},
      'caller-request-id',
    );
    expect(
      ((result['rejection']! as Map<String, Object?>)['details']!
          as Map<String, Object?>)['reason'],
      'acceptedWithRejection',
    );
  });

  group('Patchbay invocation envelope', () {
    test('expresses admission without completion-like outer fields', () {
      final Map<String, Object?> json = PatchbayInvocation.accepted(
        requestId: 'req-1',
        payload: const <String, Object?>{'outcome': 'observed'},
      ).toJson();

      expect(json['admission'], 'accepted');
      expect(json.keys, isNot(contains(anyOf('ok', 'success', 'executed'))));
    });

    test('rejection keeps a stable code', () {
      final Map<String, Object?> json = PatchbayInvocation.rejected(
        requestId: 'req-2',
        rejection: const PatchbayRejection(
          code: 'startupNotReady',
          details: <String, Object?>{'stage': 'booting'},
        ),
      ).toJson();

      expect(json['admission'], 'rejected');
      expect(json['rejection'], <String, Object?>{
        'code': 'startupNotReady',
        'details': <String, Object?>{'stage': 'booting'},
      });
    });

    test('generated codec round-trips the stable null-bearing envelope', () {
      final Map<String, Object?> json = PatchbayInvocation.accepted(
        requestId: 'req-generated',
      ).toJson();

      expect(json, containsPair('notice', null));
      expect(json, containsPair('jobId', null));
      expect(json, containsPair('rejection', null));
      expect(PatchbayInvocationWire.fromJson(json).toJson(), json);
    });

    test('generated codec rejects values outside the JSON contract', () {
      expect(
        () => PatchbayInvocation.accepted(
          requestId: 'req-invalid-json',
          payload: <String, Object?>{'timestamp': DateTime.utc(2026)},
        ).toJson(),
        throwsFormatException,
      );
    });
  });

  group('Patchbay gates', () {
    test('base rejection prevents consumer gate evaluation', () async {
      var consumerCalls = 0;
      final PatchbayGateEvaluator gates = PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.reject(code: 'hostDisabled'),
        consumerGate: (String _) {
          consumerCalls += 1;
          return const PatchbayGateDecision.allow();
        },
      );

      final PatchbayGateRejection? result = await gates.evaluate(<String>{
        'consumer.ready',
      });

      expect(result?.gateId, 'patchbay.base');
      expect(result?.code, 'hostDisabled');
      expect(consumerCalls, 0);
    });

    test(
      'consumer gates are de-duplicated and evaluated deterministically',
      () async {
        final List<String> calls = <String>[];
        final PatchbayGateEvaluator gates = PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String gateId) {
            calls.add(gateId);
            return gateId == 'b.ready'
                ? const PatchbayGateDecision.reject(code: 'notReady')
                : const PatchbayGateDecision.allow();
          },
        );

        final PatchbayGateRejection? result = await gates.evaluate(<String>[
          'b.ready',
          'a.enabled',
          'b.ready',
        ]);

        expect(calls, <String>['a.enabled', 'b.ready']);
        expect(result?.gateId, 'b.ready');
        expect(result?.code, 'notReady');
      },
    );
  });

  test('UI descriptor serializes dynamic operations and their gates', () {
    const PatchbayUiTargetDescriptor descriptor = PatchbayUiTargetDescriptor(
      id: 'login.phone',
      generation: 3,
      kind: PatchbayUiTargetKind.text,
      mounted: true,
      ambiguous: false,
      operations: <PatchbayUiOperation>{PatchbayUiOperation.textEnter},
      operationGates: <PatchbayUiOperation, Set<String>>{
        PatchbayUiOperation.textEnter: <String>{'app.ready'},
      },
      sensitivePolicy: PatchbaySensitivePolicy.public,
      sideEffect: PatchbaySideEffect.appState,
    );

    expect(descriptor.toJson(), <String, Object?>{
      'id': 'login.phone',
      'generation': 3,
      'kind': 'text',
      'mounted': true,
      'ambiguous': false,
      'operations': <String>['text.enter'],
      'operationGates': <String, Object?>{
        'text.enter': <String>['app.ready'],
      },
      'sensitivePolicy': 'public',
      'sideEffect': 'appState',
      'factSources': <String>['uiObserved'],
    });
  });

  test(
    'domain command descriptor is a complete machine-readable catalog row',
    () {
      const PatchbayCommandDescriptor descriptor = PatchbayCommandDescriptor(
        name: 'device.select',
        summary: 'Select the shared debug device.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        gates: <String>{'consumer.ready'},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'deviceId',
            type: PatchbayParameterType.string,
            required: true,
          ),
        ],
      );

      expect(descriptor.toJson(), containsPair('name', 'device.select'));
      expect(
        descriptor.toJson(),
        containsPair('factSources', <String>['appRecorded']),
      );
      expect(
        descriptor.toJson()['parameters'],
        contains(containsPair('name', 'deviceId')),
      );
    },
  );

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

    // A scripted session must not grow this ledger without bound, but the job
    // still in flight has to stay observable.
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
      // The rendezvous below can only resolve while both callbacks are in
      // flight, so a sweep that awaited one job before starting the next would
      // park on the first callback until its timeout.
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
        if (invocations == 2 && !bothInvoked.isCompleted)
          bothInvoked.complete();
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

  test('cancelAll converges per job instead of serialising timeouts', () async {
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

    final Stopwatch elapsed = Stopwatch()..start();
    final Map<String, PatchbayJobCancelOutcome> outcomes = await jobs.cancelAll(
      reason: 'sessionClosed',
    );
    elapsed.stop();

    // Serialised cancellation would spend one full timeout per stuck callback.
    expect(elapsed.elapsed, lessThan(timeout * 2));
    expect(outcomes, <String, PatchbayJobCancelOutcome>{
      stuckFirst: PatchbayJobCancelOutcome.timedOut,
      stuckSecond: PatchbayJobCancelOutcome.timedOut,
      confirming: PatchbayJobCancelOutcome.cancelled,
      uncancellable: PatchbayJobCancelOutcome.notCancellable,
    });
    // An unanswered callback and a missing callback are both non-evidence, so
    // those jobs must still read as running.
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
          // Yield past the microtask queue so the body's own terminal event
          // lands before this callback confirms the stop.
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
