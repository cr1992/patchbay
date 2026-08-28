import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/keep_awake_policy.dart';
import 'package:patchbay_cli/src/launcher.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
import 'package:test/test.dart';

final class _FakeChild implements PatchbayLaunchChild {
  final Completer<int> completion = Completer<int>();
  @override
  Future<int> get exitCode => completion.future;
  @override
  Stream<List<int>> get stderrBytes => const Stream<List<int>>.empty();
  @override
  Stream<List<int>> get stdoutBytes => const Stream<List<int>>.empty();
  @override
  void terminate() {
    if (!completion.isCompleted) completion.complete(-15);
  }
}

final class _FakeDeadline implements PatchbayLaunchDeadline {
  _FakeDeadline({required bool elapsed}) {
    if (elapsed) completion.complete();
  }

  final Completer<void> completion = Completer<void>();
  bool cancelled = false;

  @override
  Future<void> get elapsed => completion.future;

  @override
  void cancel() => cancelled = true;
}

void main() {
  late DateTime now;
  late PatchbaySessionStore store;
  late List<PatchbayLaunchFrame> frames;
  late Map<String, String> childEnvironment;
  late _FakeChild child;

  setUp(() {
    now = DateTime.utc(2026, 8, 18);
    store = PatchbaySessionStore(
      '${Directory.systemTemp.path}/patchbay-launch-test-${now.microsecondsSinceEpoch}',
    );
    frames = <PatchbayLaunchFrame>[];
    childEnvironment = <String, String>{};
    child = _FakeChild();
  });

  tearDown(() {
    if (store.directory.existsSync()) {
      store.directory.deleteSync(recursive: true);
    }
  });

  PatchbayLauncherSupervisor supervisor({
    required Future<void> Function(Duration) sleep,
    Future<PatchbayRuntimeIdentity> Function(Uri)? identity,
    PatchbayLaunchDeadlineFactory? deadlineFactory,
    PatchbayLaunchKeepAwakeRequest? keepAwakeRequest,
    Duration budget = const Duration(seconds: 2),
  }) => PatchbayLauncherSupervisor(
    store: store,
    budget: budget,
    clock: () => now,
    // PB-050-14: the launcher computes the workspace once, before the child
    // starts, and injects it. Pinned here so the fixture does not depend on
    // where the test process happens to be checked out.
    workspaceProbe: () => _workspace,
    random: () => 0,
    sleep: sleep,
    deadlineFactory: deadlineFactory,
    keepAwakeRequest: keepAwakeRequest,
    startChild: (command, environment) async {
      childEnvironment = environment;
      return child;
    },
    identityProbe: identity ?? (_) async => _identity('instance-1'),
  );

  test('delayed child declaration reaches live then completed', () async {
    var sleeps = 0;
    final PatchbayLauncherSupervisor launcher = supervisor(
      sleep: (Duration duration) async {
        now = now.add(duration);
        sleeps += 1;
        final PatchbayLaunchContext context =
            PatchbayLaunchContext.fromEnvironment(childEnvironment);
        if (sleeps == 1) {
          store.write(_pending(context, now));
        } else if (sleeps == 2) {
          store.write(
            store.readAll().single.withTransport(
              'ws://127.0.0.1:8181/token/ws',
              observedAtMs: now.millisecondsSinceEpoch,
            ),
          );
        } else {
          child.completion.complete(0);
        }
      },
    );

    final PatchbayLaunchResult result = await launcher.run(
      command: const <String>['fake-consumer'],
      launchId: 'launch-a',
      ownerPid: 42,
      onFrame: frames.add,
    );

    expect(result.exitCode, 0);
    expect(
      frames.map((frame) => frame.state),
      containsAllInOrder(<String>[
        'starting',
        'retrying',
        'pending',
        'retrying',
        'connecting',
        'live',
        'completed',
      ]),
    );
    expect(store.readAll().single.state, PatchbaySessionStatus.live);
    expect(store.readAll().single.processId, 1042);
    expect(store.readAll().single.ownerPid, 42);
    expect(childEnvironment[PatchbayLaunchContext.launchIdKey], 'launch-a');
    expect(childEnvironment[PatchbayLaunchContext.ownerPidKey], '42');
  });

  test(
    'launch context is optional only when all ownership keys are absent',
    () {
      expect(PatchbayLaunchContext.tryFromEnvironment(const {}), isNull);
      expect(
        () => PatchbayLaunchContext.tryFromEnvironment(const {
          PatchbayLaunchContext.launchIdKey: 'partial',
        }),
        throwsA(_sessionError('launchContextInvalid')),
      );
    },
  );

  test('child logs redact transport credentials', () {
    expect(
      redactPatchbayLaunchLine(
        'connected ws://127.0.0.1:8181/secret-token/ws successfully',
      ),
      'connected <redacted-uri> successfully',
    );
  });

  test('pending declaration requires the consumer process id', () {
    const PatchbayLaunchContext context = PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-process',
      ownerPid: 42,
    );
    expect(
      () => context.pendingRecord(
        sessionId: 'invalid',
        applicationId: 'dev.patchbay.test',
        processId: 0,
        buildMode: 'debug',
        createdAt: now,
        workspacePath: '/workspace/test',
        deviceId: 'device-1',
      ),
      throwsA(_sessionError('sessionRecordInvalid')),
    );
  });

  test('schema v1 loose reader ignores additive launcher fields', () {
    const PatchbayLaunchContext context = PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-compatible',
      ownerPid: 42,
    );
    store.write(_pending(context, now));

    final File recordFile = store.directory.listSync().whereType<File>().single;
    final Map<String, Object?> json = Map<String, Object?>.from(
      jsonDecode(recordFile.readAsStringSync()) as Map,
    );
    final Map<String, Object?> oldReader = _readAsVersion03(json);

    expect(oldReader['schemaVersion'], 1);
    expect(oldReader['sessionId'], 'session-42');
    expect(recordFile.existsSync(), isTrue);
    expect(json, containsPair('launchId', 'launch-compatible'));
  });

  test('missing declaration exhausts a bounded retry budget', () async {
    var sleeps = 0;
    final PatchbayLaunchResult result =
        await supervisor(
          budget: const Duration(milliseconds: 500),
          sleep: (Duration duration) async {
            sleeps += 1;
            now = now.add(duration);
          },
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-timeout',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(result.exitCode, 6);
    expect(result.frame.state, 'failed');
    expect(result.frame.reasonCode, 'sessionNotDeclared');
    expect(sleeps, lessThan(10), reason: 'retry must not be infinite');
  });

  test(
    'expired owned pending is removed without touching another owner',
    () async {
      final PatchbayLaunchContext owned = const PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-stale',
        ownerPid: 42,
      );
      final PatchbayLaunchContext other = const PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-other',
        ownerPid: 77,
      );
      store
        ..write(_pending(owned, now.subtract(const Duration(minutes: 10))))
        ..write(_pending(other, now));

      final PatchbayLaunchResult result =
          await supervisor(
            sleep: (duration) async => now = now.add(duration),
          ).run(
            command: const <String>['fake-consumer'],
            launchId: 'launch-stale',
            ownerPid: 42,
            onFrame: frames.add,
          );
      expect(result.frame.reasonCode, 'pendingSessionExpired');
      expect(store.readAll().single.launchId, 'launch-other');
    },
  );

  test('crash before ready has deterministic terminal state', () async {
    child.completion.complete(9);
    final PatchbayLaunchResult result =
        await supervisor(
          sleep: (duration) async => now = now.add(duration),
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-crash',
          ownerPid: 42,
          onFrame: frames.add,
        );
    expect(result.exitCode, 6);
    expect(result.frame.reasonCode, 'childExited');
  });

  test(
    'old and corrupt records are never adopted as launcher ownership',
    () async {
      store.write(
        PatchbaySessionRecord(
          sessionId: 'legacy',
          applicationId: 'dev.patchbay.legacy',
          appInstanceId: null,
          isolateId: null,
          processId: 77,
          wsUri: null,
          buildMode: 'debug',
          createdAt: now,
          workspacePath: '/workspace/legacy',
          deviceId: 'legacy-device',
        ),
      );
      store.directory.createSync(recursive: true);
      File('${store.directory.path}/corrupt.json').writeAsStringSync('{');

      final PatchbayLaunchResult result =
          await supervisor(
            budget: const Duration(milliseconds: 200),
            sleep: (duration) async => now = now.add(duration),
          ).run(
            command: const <String>['fake-consumer'],
            launchId: 'launch-new',
            ownerPid: 42,
            onFrame: frames.add,
          );

      expect(result.frame.reasonCode, 'sessionNotDeclared');
      expect(store.readAll().single.sessionId, 'legacy');
      expect(
        File('${store.directory.path}/corrupt.json').existsSync(),
        isFalse,
      );
    },
  );

  test('runtime restart is observed and re-pinned before reuse', () async {
    var identityReads = 0;
    var sleeps = 0;
    final PatchbayLaunchContext context = const PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-restart',
      ownerPid: 42,
    );
    store.write(
      _pending(context, now).withTransport(
        'ws://127.0.0.1:8181/token/ws',
        observedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    final PatchbayLaunchResult result =
        await supervisor(
          identity: (_) async => _identity(
            ++identityReads == 1 ? 'instance-before' : 'instance-after',
          ),
          sleep: (duration) async {
            now = now.add(duration);
            if (++sleeps == 2) child.completion.complete(0);
          },
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-restart',
          ownerPid: 42,
          onFrame: frames.add,
        );
    expect(result.exitCode, 0);
    expect(
      frames.where((frame) => frame.reasonCode == 'sessionRuntimeRestarted'),
      isNotEmpty,
    );
    expect(store.readAll().single.appInstanceId, 'instance-after');
  });

  test('stable live observation uses a five second cadence', () async {
    final List<Duration> waits = <Duration>[];
    final PatchbayLaunchContext context = const PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-stable',
      ownerPid: 42,
    );
    store.write(
      _pending(context, now).withTransport(
        'ws://127.0.0.1:8181/token/ws',
        observedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final PatchbayLaunchResult result =
        await supervisor(
          sleep: (Duration duration) async {
            waits.add(duration);
            now = now.add(duration);
            if (waits.length == 2) child.completion.complete(0);
          },
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-stable',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(result.exitCode, 0);
    expect(waits, <Duration>[
      patchbayLaunchLiveObservationCadence,
      patchbayLaunchLiveObservationCadence,
    ]);
    expect(frames.where((frame) => frame.state == 'live'), hasLength(1));
  });

  test('disconnect restarts recovery at the initial backoff range', () async {
    final List<Duration> waits = <Duration>[];
    var probes = 0;
    final PatchbayLaunchContext context = const PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-disconnect',
      ownerPid: 42,
    );
    store.write(
      _pending(context, now).withTransport(
        'ws://127.0.0.1:8181/token/ws',
        observedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final PatchbayLaunchResult result =
        await supervisor(
          identity: (_) async {
            probes += 1;
            if (probes == 2) throw StateError('temporarily unreachable');
            return _identity('instance-1');
          },
          sleep: (Duration duration) async {
            waits.add(duration);
            now = now.add(duration);
            if (waits.length == 3) child.completion.complete(0);
          },
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-disconnect',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(result.exitCode, 0);
    expect(waits, <Duration>[
      patchbayLaunchLiveObservationCadence,
      const Duration(milliseconds: 100),
      patchbayLaunchLiveObservationCadence,
    ]);
  });

  test('a never-completing probe is bounded by the remaining budget', () async {
    final Completer<PatchbayRuntimeIdentity> probe =
        Completer<PatchbayRuntimeIdentity>();
    late Duration deadlineDuration;
    final PatchbayLaunchContext context = const PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-probe-timeout',
      ownerPid: 42,
    );
    store.write(
      _pending(context, now).withTransport(
        'ws://127.0.0.1:8181/token/ws',
        observedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final PatchbayLaunchResult result =
        await supervisor(
          budget: const Duration(milliseconds: 500),
          identity: (_) => probe.future,
          deadlineFactory: (Duration duration) {
            deadlineDuration = duration;
            return _FakeDeadline(elapsed: true);
          },
          sleep: (_) async => fail('probe timeout must be terminal'),
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-probe-timeout',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(deadlineDuration, const Duration(milliseconds: 500));
    expect(result.frame.state, 'failed');
    expect(result.frame.reasonCode, 'sessionUnreachable');
  });

  test('child crash wins immediately over a pending identity probe', () async {
    final Completer<PatchbayRuntimeIdentity> probe =
        Completer<PatchbayRuntimeIdentity>();
    final PatchbayLaunchContext context = const PatchbayLaunchContext(
      sessionDirectory: '/unused',
      launchId: 'launch-probe-crash',
      ownerPid: 42,
    );
    store.write(
      _pending(context, now).withTransport(
        'ws://127.0.0.1:8181/token/ws',
        observedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    child.completion.complete(9);

    final PatchbayLaunchResult result =
        await supervisor(
          identity: (_) => probe.future,
          deadlineFactory: (_) => _FakeDeadline(elapsed: false),
          sleep: (_) async => fail('child exit must win before polling'),
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-probe-crash',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(result.frame.state, 'failed');
    expect(result.frame.reasonCode, 'childExited');
  });

  test('keep-awake is off by default for a live launcher', () async {
    final List<bool> requests = <bool>[];
    _writeLive(store, now, launchId: 'launch-default-off');

    final PatchbayLaunchResult result =
        await supervisor(
          keepAwakeRequest: (uri, {required enabled, required lease}) async {
            requests.add(enabled);
            return const PatchbayKeepAwakeAttempt(
              success: true,
              state: 'unexpected',
            );
          },
          sleep: (_) async => child.completion.complete(0),
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-default-off',
          ownerPid: 42,
          onFrame: frames.add,
        );

    expect(result.exitCode, 0);
    expect(requests, isEmpty);
  });

  test('live launcher engages, renews at half lease, and releases', () async {
    final List<bool> requests = <bool>[];
    var waits = 0;
    _writeLive(store, now, launchId: 'launch-lease');

    final PatchbayLaunchResult result =
        await supervisor(
          keepAwakeRequest: (uri, {required enabled, required lease}) async {
            requests.add(enabled);
            return PatchbayKeepAwakeAttempt(
              success: true,
              state: enabled
                  ? requests.where((value) => value).length == 1
                        ? 'engaged'
                        : 'renewed'
                  : 'released',
            );
          },
          sleep: (_) async {
            waits += 1;
            now = now.add(const Duration(minutes: 5));
            if (waits == 2) child.completion.complete(0);
          },
        ).run(
          command: const <String>['fake-consumer'],
          launchId: 'launch-lease',
          ownerPid: 42,
          onFrame: frames.add,
          keepAwakePolicy: const PatchbayKeepAwakePolicy(enabled: true),
        );

    expect(result.exitCode, 0);
    expect(requests, <bool>[true, true, false]);
    expect(
      frames.map((frame) => frame.keepAwake?.state).whereType<String>(),
      containsAllInOrder(<String>['engaged', 'renewed', 'released']),
    );
  });

  test(
    'rejected lease does not retry on every live health observation',
    () async {
      var requests = 0;
      var waits = 0;
      _writeLive(store, now, launchId: 'launch-rejected-lease');

      final PatchbayLaunchResult result =
          await supervisor(
            keepAwakeRequest: (uri, {required enabled, required lease}) async {
              requests += 1;
              return const PatchbayKeepAwakeAttempt(
                success: false,
                state: 'renewalRejected',
                reasonCode: 'keepAwakeNotWired',
              );
            },
            sleep: (duration) async {
              waits += 1;
              now = now.add(duration);
              if (waits == 2) child.completion.complete(0);
            },
          ).run(
            command: const <String>['fake-consumer'],
            launchId: 'launch-rejected-lease',
            ownerPid: 42,
            onFrame: frames.add,
            keepAwakePolicy: const PatchbayKeepAwakePolicy(enabled: true),
          );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(requests, 1);
      expect(
        frames.map((frame) => frame.keepAwake?.reasonCode).whereType<String>(),
        <String>['keepAwakeNotWired'],
      );
    },
  );

  test(
    'cancellation releases an engaged lease before child termination',
    () async {
      final List<bool> requests = <bool>[];
      final Completer<void> cancellation = Completer<void>();
      _writeLive(store, now, launchId: 'launch-cancel');

      final PatchbayLaunchResult result =
          await supervisor(
            keepAwakeRequest: (uri, {required enabled, required lease}) async {
              requests.add(enabled);
              if (enabled && !cancellation.isCompleted) cancellation.complete();
              return PatchbayKeepAwakeAttempt(
                success: true,
                state: enabled ? 'engaged' : 'released',
              );
            },
            sleep: (_) => Completer<void>().future,
          ).run(
            command: const <String>['fake-consumer'],
            launchId: 'launch-cancel',
            ownerPid: 42,
            onFrame: frames.add,
            keepAwakePolicy: const PatchbayKeepAwakePolicy(enabled: true),
            cancellation: cancellation.future,
          );

      expect(result.frame.state, 'cancelled');
      expect(result.frame.keepAwake?.state, 'released');
      expect(requests, <bool>[true, false]);
    },
  );

  test(
    'child failure reports an unconfirmed release without hiding it',
    () async {
      final List<bool> requests = <bool>[];
      _writeLive(store, now, launchId: 'launch-child-failure');

      final PatchbayLaunchResult result =
          await supervisor(
            keepAwakeRequest: (uri, {required enabled, required lease}) async {
              requests.add(enabled);
              if (enabled) {
                return const PatchbayKeepAwakeAttempt(
                  success: true,
                  state: 'engaged',
                );
              }
              return const PatchbayKeepAwakeAttempt(
                success: false,
                state: 'releaseUnconfirmed',
                reasonCode: 'keepAwakeTransportUnavailable',
              );
            },
            sleep: (_) async => child.completion.complete(9),
          ).run(
            command: const <String>['fake-consumer'],
            launchId: 'launch-child-failure',
            ownerPid: 42,
            onFrame: frames.add,
            keepAwakePolicy: const PatchbayKeepAwakePolicy(enabled: true),
          );

      expect(result.frame.state, 'failed');
      expect(result.frame.reasonCode, 'childExited');
      expect(result.frame.keepAwake?.success, isFalse);
      expect(result.frame.keepAwake?.state, 'releaseUnconfirmed');
      expect(
        result.frame.keepAwake?.reasonCode,
        'keepAwakeTransportUnavailable',
      );
      expect(requests, <bool>[true, false]);
    },
  );
}

void _writeLive(
  PatchbaySessionStore store,
  DateTime now, {
  required String launchId,
}) {
  final PatchbayLaunchContext context = PatchbayLaunchContext(
    sessionDirectory: store.directory.path,
    launchId: launchId,
    ownerPid: 42,
  );
  store.write(
    _pending(context, now).withTransport(
      'ws://127.0.0.1:8181/token/ws',
      observedAtMs: now.millisecondsSinceEpoch,
    ),
  );
}

PatchbaySessionRecord _pending(PatchbayLaunchContext context, DateTime at) =>
    context.pendingRecord(
      sessionId: 'session-${context.ownerPid}',
      applicationId: 'dev.patchbay.test',
      processId: context.ownerPid + 1000,
      buildMode: 'debug',
      createdAt: at,
      // A workspace-bearing context is the authority and a child reporting a
      // different path would now be refused; a context without one (an older
      // launcher) still has to be told where it ran.
      workspacePath: context.workspace == null
          ? _workspace.canonicalRoot
          : null,
      deviceId: 'device-1',
    );

final PatchbayWorkspaceIdentity _workspace = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/workspace/test',
)!;

PatchbayRuntimeIdentity _identity(String instance) => PatchbayRuntimeIdentity(
  schemaVersion: 1,
  applicationId: 'dev.patchbay.test',
  appInstanceId: instance,
  isolateId: 'isolates/$instance',
);

Map<String, Object?> _readAsVersion03(Map<String, Object?> json) {
  const requiredFields = <String>{
    'schemaVersion',
    'sessionId',
    'applicationId',
    'appInstanceId',
    'isolateId',
    'processId',
    'wsUri',
    'buildMode',
    'createdAt',
    'workspacePath',
    'deviceId',
  };
  if (json['schemaVersion'] != 1 || !requiredFields.every(json.containsKey)) {
    throw const FormatException('0.3 session record invalid');
  }
  return <String, Object?>{
    for (final String field in requiredFields) field: json[field],
  };
}

Matcher _sessionError(String code) => isA<PatchbaySessionException>().having(
  (PatchbaySessionException error) => error.code,
  'code',
  code,
);
