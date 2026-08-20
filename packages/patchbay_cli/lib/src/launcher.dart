import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:patchbay/patchbay.dart';

import 'client.dart';
import 'keep_awake_policy.dart';
import 'result.dart';
import 'rpc_timeout.dart';
import 'session.dart';

const Duration patchbayLaunchDefaultBudget = Duration(minutes: 2);
const Duration patchbayLaunchMaximumBudget = Duration(minutes: 10);
const Duration patchbayLaunchInitialRetry = Duration(milliseconds: 200);
const Duration patchbayLaunchMaximumRetry = Duration(seconds: 5);
const Duration patchbayLaunchLiveObservationCadence = Duration(seconds: 5);

typedef PatchbayLaunchClock = DateTime Function();
typedef PatchbayLaunchSleep = Future<void> Function(Duration duration);
typedef PatchbayLaunchRandom = double Function();
typedef PatchbayLaunchIdentityProbe =
    Future<PatchbayRuntimeIdentity> Function(Uri uri);
typedef PatchbayLaunchChildStarter =
    Future<PatchbayLaunchChild> Function(
      List<String> command,
      Map<String, String> environment,
    );
typedef PatchbayLaunchDeadlineFactory =
    PatchbayLaunchDeadline Function(Duration duration);
typedef PatchbayLaunchKeepAwakeRequest =
    Future<PatchbayKeepAwakeAttempt> Function(
      Uri uri, {
      required bool enabled,
      required Duration lease,
    });

abstract interface class PatchbayLaunchDeadline {
  Future<void> get elapsed;
  void cancel();
}

sealed class _PatchbayProbeEvent {
  const _PatchbayProbeEvent();
}

final class _PatchbayProbeIdentity extends _PatchbayProbeEvent {
  const _PatchbayProbeIdentity(this.identity);
  final PatchbayRuntimeIdentity identity;
}

final class _PatchbayProbeFailure extends _PatchbayProbeEvent {
  const _PatchbayProbeFailure();
}

final class _PatchbayProbeChildExit extends _PatchbayProbeEvent {
  const _PatchbayProbeChildExit(this.exitCode);
  final int exitCode;
}

final class _PatchbayProbeTimeout extends _PatchbayProbeEvent {
  const _PatchbayProbeTimeout();
}

final class _PatchbayProbeCancelled extends _PatchbayProbeEvent {
  const _PatchbayProbeCancelled();
}

sealed class _PatchbayWaitEvent {
  const _PatchbayWaitEvent();
}

final class _PatchbayWaitElapsed extends _PatchbayWaitEvent {
  const _PatchbayWaitElapsed();
}

final class _PatchbayWaitChildExit extends _PatchbayWaitEvent {
  const _PatchbayWaitChildExit(this.exitCode);
  final int exitCode;
}

final class _PatchbayWaitCancelled extends _PatchbayWaitEvent {
  const _PatchbayWaitCancelled();
}

final RegExp _patchbaySensitiveUri = RegExp(
  r'\b(?:https?|wss?)://[^\s]+',
  caseSensitive: false,
);

/// Removes VM Service authentication URIs before child output reaches logs.
String redactPatchbayLaunchLine(String line) =>
    line.replaceAll(_patchbaySensitiveUri, '<redacted-uri>');

abstract interface class PatchbayLaunchChild {
  Stream<List<int>> get stdoutBytes;
  Stream<List<int>> get stderrBytes;
  Future<int> get exitCode;
  void terminate();
}

final class PatchbayLaunchFrame {
  const PatchbayLaunchFrame({
    required this.launchId,
    required this.state,
    required this.attempt,
    required this.elapsedMs,
    this.sessionId,
    this.nextRetryMs,
    this.reasonCode,
    this.candidateCount,
    this.keepAwake,
  });

  final String launchId;
  final String state;
  final String? sessionId;
  final int attempt;
  final int elapsedMs;
  final int? nextRetryMs;
  final String? reasonCode;
  final int? candidateCount;
  final PatchbayKeepAwakeAttempt? keepAwake;

  Map<String, Object?> toJson() => <String, Object?>{
    'launchId': launchId,
    'state': state,
    if (sessionId != null) 'sessionId': sessionId,
    'attempt': attempt,
    'elapsedMs': elapsedMs,
    if (nextRetryMs != null) 'nextRetryMs': nextRetryMs,
    if (reasonCode != null) 'reasonCode': reasonCode,
    if (candidateCount != null) 'candidateCount': candidateCount,
    if (keepAwake != null) 'keepAwake': keepAwake!.toJson(),
  };
}

final class PatchbayLaunchResult {
  const PatchbayLaunchResult({required this.frame, required this.exitCode});
  final PatchbayLaunchFrame frame;
  final int exitCode;
}

/// Owns one bounded child/session lifecycle without choosing another device.
final class PatchbayLauncherSupervisor {
  PatchbayLauncherSupervisor({
    required this.store,
    PatchbayLaunchChildStarter? startChild,
    PatchbayLaunchIdentityProbe? identityProbe,
    PatchbayLaunchClock? clock,
    PatchbayLaunchSleep? sleep,
    PatchbayLaunchDeadlineFactory? deadlineFactory,
    PatchbayLaunchKeepAwakeRequest? keepAwakeRequest,
    PatchbayLaunchRandom? random,
    this.budget = patchbayLaunchDefaultBudget,
  }) : _startChild = startChild ?? _startProcess,
       _identityProbe = identityProbe ?? _probeIdentity,
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _deadlineFactory = deadlineFactory ?? _TimerLaunchDeadline.new,
       _keepAwakeRequest = keepAwakeRequest ?? _requestKeepAwake,
       _random = random ?? Random.secure().nextDouble {
    if (budget <= Duration.zero || budget > patchbayLaunchMaximumBudget) {
      throw const PatchbaySessionException('launchBudgetInvalid');
    }
  }

  final PatchbaySessionStore store;
  final PatchbayLaunchChildStarter _startChild;
  final PatchbayLaunchIdentityProbe _identityProbe;
  final PatchbayLaunchClock _clock;
  final PatchbayLaunchSleep _sleep;
  final PatchbayLaunchDeadlineFactory _deadlineFactory;
  final PatchbayLaunchKeepAwakeRequest _keepAwakeRequest;
  final PatchbayLaunchRandom _random;
  final Duration budget;

  Future<PatchbayLaunchResult> run({
    required List<String> command,
    required String launchId,
    required int ownerPid,
    required void Function(PatchbayLaunchFrame frame) onFrame,
    void Function(String line)? onHumanLine,
    PatchbayKeepAwakePolicy keepAwakePolicy = const PatchbayKeepAwakePolicy(
      enabled: false,
    ),
    Future<void>? cancellation,
  }) async {
    if (command.isEmpty) {
      throw const FormatException('launch requires a command');
    }
    final DateTime started = _clock().toUtc();
    var attempt = 0;
    var retry = patchbayLaunchInitialRetry;
    var wasLive = false;
    String? sessionId;
    PatchbayRuntimeIdentity? lastIdentity;
    DateTime? retryWindowStarted = started;
    Uri? currentUri;
    bool keepAwakeHeld = false;
    DateTime? keepAwakeRenewAt;
    final Future<void> cancelled = cancellation ?? Completer<void>().future;

    PatchbayLaunchFrame emit(
      String state, {
      String? reasonCode,
      int? nextRetryMs,
      int? candidates,
      PatchbayKeepAwakeAttempt? keepAwake,
    }) {
      final PatchbayLaunchFrame frame = PatchbayLaunchFrame(
        launchId: launchId,
        state: state,
        sessionId: sessionId,
        attempt: attempt,
        elapsedMs: max(0, _clock().toUtc().difference(started).inMilliseconds),
        nextRetryMs: nextRetryMs,
        reasonCode: reasonCode,
        candidateCount: candidates,
        keepAwake: keepAwake,
      );
      onFrame(frame);
      return frame;
    }

    emit('starting');
    final PatchbayLaunchChild child;
    try {
      child = await _startChild(command, <String, String>{
        ...Platform.environment,
        PatchbayLaunchContext.sessionDirectoryKey: store.directory.path,
        PatchbayLaunchContext.launchIdKey: launchId,
        PatchbayLaunchContext.ownerPidKey: '$ownerPid',
      });
    } on Object {
      final frame = emit('failed', reasonCode: 'childStartFailed');
      return PatchbayLaunchResult(
        frame: frame,
        exitCode: PatchbayExitCode.typedFailure,
      );
    }
    final List<StreamSubscription<String>> outputSubscriptions =
        <StreamSubscription<String>>[
          child.stdoutBytes
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (String line) =>
                    (onHumanLine ?? (_) {})(redactPatchbayLaunchLine(line)),
              ),
          child.stderrBytes
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (String line) =>
                    (onHumanLine ?? (_) {})(redactPatchbayLaunchLine(line)),
              ),
        ];
    Future<PatchbayLaunchResult> finish({
      required String state,
      required int exitCode,
      String? reasonCode,
      int? candidates,
      bool terminateChild = false,
    }) async {
      PatchbayKeepAwakeAttempt? release;
      if (keepAwakePolicy.enabled && keepAwakeHeld) {
        final Uri? uri = currentUri;
        release = uri == null
            ? const PatchbayKeepAwakeAttempt(
                success: false,
                state: 'releaseUnconfirmed',
                reasonCode: 'keepAwakeTransportUnavailable',
              )
            : await _keepAwakeRequest(
                uri,
                enabled: false,
                lease: keepAwakePolicy.lease,
              );
        keepAwakeHeld = false;
      }
      _cleanupPending(store.readAll(), launchId, ownerPid);
      if (terminateChild) child.terminate();
      final PatchbayLaunchFrame frame = emit(
        state,
        reasonCode: reasonCode,
        candidates: candidates,
        keepAwake: release,
      );
      return PatchbayLaunchResult(frame: frame, exitCode: exitCode);
    }

    try {
      while (true) {
        final DateTime now = _clock().toUtc();
        final List<PatchbaySessionRecord> all = store.readAll();
        final List<PatchbaySessionRecord> owned = <PatchbaySessionRecord>[
          for (final PatchbaySessionRecord record in all)
            if (record.launchId == launchId && record.ownerPid == ownerPid)
              record,
        ];
        final int candidates = all.length - owned.length;
        if (owned.length > 1) {
          return await finish(
            state: 'failed',
            exitCode: PatchbayExitCode.typedFailure,
            reasonCode: 'launchSessionAmbiguous',
            candidates: candidates,
            terminateChild: true,
          );
        }

        String? reason;
        if (owned.isEmpty) {
          reason = 'sessionNotDeclared';
        } else {
          final PatchbaySessionRecord record = owned.single;
          sessionId = record.sessionId;
          if (record.expiresAtMs case final int expires
              when record.wsUri == null &&
                  expires <= now.millisecondsSinceEpoch) {
            store.remove(record.sessionId);
            return await finish(
              state: 'failed',
              exitCode: PatchbayExitCode.typedFailure,
              reasonCode: 'pendingSessionExpired',
              terminateChild: true,
            );
          }
          final String? rawUri = record.wsUri;
          if (rawUri == null) {
            reason = 'sessionPending';
            emit('pending', candidates: candidates);
          } else {
            attempt += 1;
            final bool reconnecting = !wasLive || retryWindowStarted != null;
            if (reconnecting) emit('connecting', candidates: candidates);
            final DateTime probeWindowStarted = retryWindowStarted ?? now;
            final Duration probeRemaining =
                budget - now.difference(probeWindowStarted);
            if (probeRemaining <= Duration.zero) {
              return await finish(
                state: 'failed',
                exitCode: PatchbayExitCode.typedFailure,
                reasonCode: 'sessionUnreachable',
                terminateChild: true,
              );
            }
            final _PatchbayProbeEvent probe;
            final Uri? uri = _parseTransport(rawUri);
            if (uri == null) {
              probe = const _PatchbayProbeFailure();
            } else {
              final PatchbayLaunchDeadline deadline = _deadlineFactory(
                probeRemaining,
              );
              try {
                probe = await Future.any(<Future<_PatchbayProbeEvent>>[
                  _identityProbe(uri).then<_PatchbayProbeEvent>(
                    _PatchbayProbeIdentity.new,
                    onError: (Object _, StackTrace _) =>
                        const _PatchbayProbeFailure(),
                  ),
                  child.exitCode.then<_PatchbayProbeEvent>(
                    _PatchbayProbeChildExit.new,
                  ),
                  deadline.elapsed.then<_PatchbayProbeEvent>(
                    (_) => const _PatchbayProbeTimeout(),
                  ),
                  cancelled.then<_PatchbayProbeEvent>(
                    (_) => const _PatchbayProbeCancelled(),
                  ),
                ]);
              } finally {
                deadline.cancel();
              }
            }
            if (probe case _PatchbayProbeChildExit(:final exitCode)) {
              final bool accepted = wasLive && exitCode == 0;
              return await finish(
                state: accepted ? 'completed' : 'failed',
                exitCode: accepted
                    ? PatchbayExitCode.accepted
                    : PatchbayExitCode.typedFailure,
                reasonCode: accepted ? null : 'childExited',
              );
            }
            if (probe is _PatchbayProbeTimeout) {
              if (wasLive) {
                emit('disconnected', reasonCode: 'sessionUnreachable');
              }
              return await finish(
                state: 'failed',
                exitCode: PatchbayExitCode.typedFailure,
                reasonCode: 'sessionUnreachable',
                terminateChild: true,
              );
            }
            if (probe is _PatchbayProbeCancelled) {
              return await finish(
                state: 'cancelled',
                exitCode: PatchbayExitCode.typedFailure,
                reasonCode: 'launchCancelled',
                terminateChild: true,
              );
            }
            if (probe case _PatchbayProbeIdentity(:final identity)) {
              if (identity.schemaVersion != PatchbayServiceHost.schemaVersion ||
                  identity.applicationId != record.applicationId) {
                reason = 'sessionIdentityMismatch';
                if (wasLive) emit('disconnected', reasonCode: reason);
              } else {
                final bool restarted =
                    lastIdentity != null &&
                    lastIdentity.appInstanceId != identity.appInstanceId;
                if (restarted) {
                  emit('disconnected', reasonCode: 'sessionRuntimeRestarted');
                  emit('connecting', candidates: candidates);
                  keepAwakeHeld = false;
                  keepAwakeRenewAt = null;
                }
                lastIdentity = identity;
                if (reconnecting || restarted) {
                  store.write(
                    record.completedWith(
                      identity,
                      observedAtMs: now.millisecondsSinceEpoch,
                    ),
                  );
                }
                wasLive = true;
                retryWindowStarted = null;
                if (reconnecting || restarted) {
                  retry = patchbayLaunchInitialRetry;
                }
                currentUri = uri;
                PatchbayKeepAwakeAttempt? keepAwake;
                final bool renewalDue =
                    keepAwakePolicy.enabled &&
                    (keepAwakeRenewAt == null ||
                        !now.isBefore(keepAwakeRenewAt) ||
                        (reconnecting && !keepAwakeHeld));
                if (renewalDue) {
                  keepAwake = await _keepAwakeRequest(
                    uri!,
                    enabled: true,
                    lease: keepAwakePolicy.lease,
                  );
                  // A definitive rejection must not turn the 5-second health
                  // observation into an implicit retry storm. A reconnect or
                  // the next half-lease boundary gives it another bounded try.
                  keepAwakeRenewAt = now.add(keepAwakePolicy.renewalCadence);
                  if (keepAwake.success) {
                    keepAwakeHeld = true;
                  }
                }
                if (reconnecting || restarted || keepAwake != null) {
                  emit('live', candidates: candidates, keepAwake: keepAwake);
                }
              }
            } else {
              reason = 'sessionUnreachable';
              retryWindowStarted ??= now;
              if (wasLive) emit('disconnected', reasonCode: reason);
            }
          }
        }

        if (reason != null) retryWindowStarted ??= now;
        final Duration retryElapsed = now.difference(retryWindowStarted ?? now);
        if (reason != null && retryElapsed >= budget) {
          return await finish(
            state: 'failed',
            exitCode: PatchbayExitCode.typedFailure,
            reasonCode: reason,
            terminateChild: true,
          );
        }
        final int nextMs = reason == null && wasLive
            ? patchbayLaunchLiveObservationCadence.inMilliseconds
            : max(1, (retry.inMilliseconds * (0.5 + 0.5 * _random())).round());
        if (reason != null) {
          emit('retrying', reasonCode: reason, nextRetryMs: nextMs);
        }
        final _PatchbayWaitEvent event = await Future.any(
          <Future<_PatchbayWaitEvent>>[
            child.exitCode.then<_PatchbayWaitEvent>(_PatchbayWaitChildExit.new),
            _sleep(
              Duration(milliseconds: nextMs),
            ).then<_PatchbayWaitEvent>((_) => const _PatchbayWaitElapsed()),
            cancelled.then<_PatchbayWaitEvent>(
              (_) => const _PatchbayWaitCancelled(),
            ),
          ],
        );
        if (event case _PatchbayWaitChildExit(:final exitCode)) {
          final bool accepted = wasLive && exitCode == 0;
          return await finish(
            state: accepted ? 'completed' : 'failed',
            exitCode: accepted
                ? PatchbayExitCode.accepted
                : PatchbayExitCode.typedFailure,
            reasonCode: accepted ? null : 'childExited',
          );
        }
        if (event is _PatchbayWaitCancelled) {
          return await finish(
            state: 'cancelled',
            exitCode: PatchbayExitCode.typedFailure,
            reasonCode: 'launchCancelled',
            terminateChild: true,
          );
        }
        if (reason != null) {
          retry = Duration(
            milliseconds: min(
              retry.inMilliseconds * 2,
              patchbayLaunchMaximumRetry.inMilliseconds,
            ),
          );
        }
      }
    } finally {
      if (keepAwakePolicy.enabled && keepAwakeHeld && currentUri != null) {
        await _keepAwakeRequest(
          currentUri,
          enabled: false,
          lease: keepAwakePolicy.lease,
        );
        keepAwakeHeld = false;
      }
      for (final StreamSubscription<String> subscription
          in outputSubscriptions) {
        await subscription.cancel();
      }
    }
  }

  void _cleanupPending(
    Iterable<PatchbaySessionRecord> records,
    String launchId,
    int ownerPid,
  ) {
    for (final PatchbaySessionRecord record in records) {
      if (record.launchId == launchId &&
          record.ownerPid == ownerPid &&
          record.wsUri == null) {
        store.remove(record.sessionId);
      }
    }
  }

  static Future<PatchbayRuntimeIdentity> _probeIdentity(Uri uri) async {
    final PatchbayConnection connection = await PatchbayConnection.connect(uri);
    try {
      return connection.runtimeIdentity;
    } finally {
      await connection.close();
    }
  }

  static Future<PatchbayKeepAwakeAttempt> _requestKeepAwake(
    Uri uri, {
    required bool enabled,
    required Duration lease,
  }) async {
    PatchbayClient? client;
    try {
      client = PatchbayTimeoutClient(
        await dialPatchbayUnderBudget(
          () => PatchbayConnection.connect(uri),
          rpcTimeout: patchbayDefaultRpcTimeout,
        ),
        rpcTimeout: patchbayDefaultRpcTimeout,
      );
      return await requestPatchbayKeepAwake(
        client,
        enabled: enabled,
        lease: lease,
      );
    } on Object {
      return PatchbayKeepAwakeAttempt(
        success: false,
        state: enabled ? 'renewalUnconfirmed' : 'releaseUnconfirmed',
        reasonCode: 'keepAwakeTransportUnavailable',
      );
    } finally {
      await closePatchbayQuietly(client);
    }
  }

  static Uri? _parseTransport(String raw) {
    try {
      final Uri uri = Uri.parse(raw);
      return const <String>{
                'http',
                'https',
                'ws',
                'wss',
              }.contains(uri.scheme) &&
              uri.host.isNotEmpty
          ? uri
          : null;
    } on FormatException {
      return null;
    }
  }

  static Future<PatchbayLaunchChild> _startProcess(
    List<String> command,
    Map<String, String> environment,
  ) async => _ProcessLaunchChild(
    await Process.start(
      command.first,
      command.sublist(1),
      environment: environment,
    ),
  );
}

final class _ProcessLaunchChild implements PatchbayLaunchChild {
  const _ProcessLaunchChild(this.process);
  final Process process;
  @override
  Stream<List<int>> get stdoutBytes => process.stdout;
  @override
  Stream<List<int>> get stderrBytes => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void terminate() => process.kill(ProcessSignal.sigterm);
}

final class _TimerLaunchDeadline implements PatchbayLaunchDeadline {
  _TimerLaunchDeadline(Duration duration) {
    _timer = Timer(duration, _completion.complete);
  }

  final Completer<void> _completion = Completer<void>();
  late final Timer _timer;

  @override
  Future<void> get elapsed => _completion.future;

  @override
  void cancel() => _timer.cancel();
}
