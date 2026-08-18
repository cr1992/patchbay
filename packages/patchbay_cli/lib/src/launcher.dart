import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:patchbay/patchbay.dart';

import 'client.dart';
import 'result.dart';
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
  });

  final String launchId;
  final String state;
  final String? sessionId;
  final int attempt;
  final int elapsedMs;
  final int? nextRetryMs;
  final String? reasonCode;
  final int? candidateCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'launchId': launchId,
    'state': state,
    if (sessionId != null) 'sessionId': sessionId,
    'attempt': attempt,
    'elapsedMs': elapsedMs,
    if (nextRetryMs != null) 'nextRetryMs': nextRetryMs,
    if (reasonCode != null) 'reasonCode': reasonCode,
    if (candidateCount != null) 'candidateCount': candidateCount,
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
    PatchbayLaunchRandom? random,
    this.budget = patchbayLaunchDefaultBudget,
  }) : _startChild = startChild ?? _startProcess,
       _identityProbe = identityProbe ?? _probeIdentity,
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _deadlineFactory = deadlineFactory ?? _TimerLaunchDeadline.new,
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
  final PatchbayLaunchRandom _random;
  final Duration budget;

  Future<PatchbayLaunchResult> run({
    required List<String> command,
    required String launchId,
    required int ownerPid,
    required void Function(PatchbayLaunchFrame frame) onFrame,
    void Function(String line)? onHumanLine,
  }) async {
    if (command.isEmpty)
      throw const FormatException('launch requires a command');
    final DateTime started = _clock().toUtc();
    var attempt = 0;
    var retry = patchbayLaunchInitialRetry;
    var wasLive = false;
    String? sessionId;
    PatchbayRuntimeIdentity? lastIdentity;
    DateTime? retryWindowStarted = started;

    PatchbayLaunchFrame emit(
      String state, {
      String? reasonCode,
      int? nextRetryMs,
      int? candidates,
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
          final frame = emit(
            'failed',
            reasonCode: 'launchSessionAmbiguous',
            candidates: candidates,
          );
          _cleanupPending(owned, launchId, ownerPid);
          child.terminate();
          return PatchbayLaunchResult(
            frame: frame,
            exitCode: PatchbayExitCode.typedFailure,
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
            final frame = emit('failed', reasonCode: 'pendingSessionExpired');
            child.terminate();
            return PatchbayLaunchResult(
              frame: frame,
              exitCode: PatchbayExitCode.typedFailure,
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
              final frame = emit('failed', reasonCode: 'sessionUnreachable');
              _cleanupPending(owned, launchId, ownerPid);
              child.terminate();
              return PatchbayLaunchResult(
                frame: frame,
                exitCode: PatchbayExitCode.typedFailure,
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
                ]);
              } finally {
                deadline.cancel();
              }
            }
            if (probe case _PatchbayProbeChildExit(:final exitCode)) {
              final bool accepted = wasLive && exitCode == 0;
              final frame = emit(
                accepted ? 'completed' : 'failed',
                reasonCode: accepted ? null : 'childExited',
              );
              _cleanupPending(store.readAll(), launchId, ownerPid);
              return PatchbayLaunchResult(
                frame: frame,
                exitCode: accepted
                    ? PatchbayExitCode.accepted
                    : PatchbayExitCode.typedFailure,
              );
            }
            if (probe is _PatchbayProbeTimeout) {
              if (wasLive) {
                emit('disconnected', reasonCode: 'sessionUnreachable');
              }
              final frame = emit('failed', reasonCode: 'sessionUnreachable');
              _cleanupPending(owned, launchId, ownerPid);
              child.terminate();
              return PatchbayLaunchResult(
                frame: frame,
                exitCode: PatchbayExitCode.typedFailure,
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
                if (reconnecting || restarted) {
                  emit('live', candidates: candidates);
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
          final frame = emit('failed', reasonCode: reason);
          _cleanupPending(owned, launchId, ownerPid);
          child.terminate();
          return PatchbayLaunchResult(
            frame: frame,
            exitCode: PatchbayExitCode.typedFailure,
          );
        }
        final int nextMs = reason == null && wasLive
            ? patchbayLaunchLiveObservationCadence.inMilliseconds
            : max(1, (retry.inMilliseconds * (0.5 + 0.5 * _random())).round());
        if (reason != null) {
          emit('retrying', reasonCode: reason, nextRetryMs: nextMs);
        }
        final Object event = await Future.any<Object>(<Future<Object>>[
          child.exitCode.then<Object>((int code) => code),
          _sleep(Duration(milliseconds: nextMs)).then<Object>((_) => false),
        ]);
        if (event is int) {
          final bool accepted = wasLive && event == 0;
          final frame = emit(
            accepted ? 'completed' : 'failed',
            reasonCode: accepted ? null : 'childExited',
          );
          _cleanupPending(store.readAll(), launchId, ownerPid);
          return PatchbayLaunchResult(
            frame: frame,
            exitCode: accepted
                ? PatchbayExitCode.accepted
                : PatchbayExitCode.typedFailure,
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
