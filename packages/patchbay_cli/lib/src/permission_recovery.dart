import 'dart:async';

import 'client.dart';
import 'doctor.dart';
import 'permission_driver.dart';
import 'session.dart';
import 'ui_manifest.dart';

typedef PatchbayPermissionEventSink =
    FutureOr<void> Function(String event, Map<String, Object?> fields);

Future<void> ignorePatchbayPermissionEvent(
  String event,
  Map<String, Object?> fields,
) async {}

typedef PatchbayPermissionConnectionFactory =
    Future<PatchbayClient> Function(Uri uri);
typedef PatchbayPermissionDelay = Future<void> Function(Duration duration);

final class PatchbayPermissionRecoveryResult {
  const PatchbayPermissionRecoveryResult({
    required this.sessionId,
    required this.applicationId,
    required this.previousAppInstanceId,
    required this.appInstanceId,
    required this.catalogRefreshed,
    required this.resolvedTargetCount,
    required this.runtimeRestarted,
  });

  final String sessionId;
  final String applicationId;
  final String? previousAppInstanceId;
  final String appInstanceId;
  final bool catalogRefreshed;
  final int resolvedTargetCount;
  final bool runtimeRestarted;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': 'ready',
    'sessionId': sessionId,
    'applicationId': applicationId,
    'previousAppInstanceId': previousAppInstanceId,
    'appInstanceId': appInstanceId,
    'runtimeRestarted': runtimeRestarted,
    'catalogRefreshed': catalogRefreshed,
    'resolvedTargetCount': resolvedTargetCount,
  };
}

/// Restores the App-side debug channel after an external permission dialog.
///
/// Every retry spends the caller's remaining permission budget. A session is
/// resolved again (refreshing a hot-restarted identity), the UI lifecycle is
/// probed through the real catalog, and current UI targets are decoded again.
/// No command that triggered the permission request is replayed here.
final class PatchbayPermissionRecoveryCoordinator {
  PatchbayPermissionRecoveryCoordinator({
    required this.sessions,
    PatchbayPermissionConnectionFactory? connect,
    PatchbayPermissionDelay? delay,
    PatchbayPermissionEventSink? eventSink,
    this.retryDelay = const Duration(milliseconds: 100),
  }) : _connect = connect ?? _connectVmService,
       _delay = delay ?? Future<void>.delayed,
       _eventSink = eventSink ?? ignorePatchbayPermissionEvent;

  final PatchbaySessionResolver sessions;
  final PatchbayPermissionConnectionFactory _connect;
  final PatchbayPermissionDelay _delay;
  final PatchbayPermissionEventSink _eventSink;
  final Duration retryDelay;

  Future<PatchbayPermissionRecoveryResult> recover(
    PatchbayDiscoveredSession before, {
    required Duration timeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    final Stopwatch elapsed = Stopwatch()..start();
    String lastStage = 'waitingAppResume';
    String? lastCode;

    while (true) {
      final Duration remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw PatchbayPermissionDriverException(
          'budgetExceeded',
          details: <String, Object?>{
            'lastConfirmedStage': lastStage,
            if (lastCode != null) 'lastCode': lastCode,
          },
        );
      }
      PatchbayClient? connection;
      try {
        lastStage = 'reconnecting';
        await _eventSink('permission.transition', <String, Object?>{
          'stage': lastStage,
          'sessionId': before.record.sessionId,
        });
        final PatchbayDiscoveredSession current = await sessions
            .resolve(sessionId: before.record.sessionId)
            .timeout(remaining);
        if (current.identity.applicationId != before.identity.applicationId) {
          throw const PatchbayPermissionDriverException(
            'permissionSessionIdentityMismatch',
          );
        }
        final String? rawUri = current.record.wsUri;
        if (rawUri == null) {
          lastCode = 'sessionPending';
          await _wait(timeout, elapsed);
          continue;
        }
        connection = await _connect(
          Uri.parse(rawUri),
        ).timeout(timeout - elapsed.elapsed);

        lastStage = 'waitingAppResume';
        final Map<String, Object?> identity = await connection
            .identity()
            .timeout(timeout - elapsed.elapsed);
        final Map<String, Object?> catalog = await connection.catalog().timeout(
          timeout - elapsed.elapsed,
        );
        final PatchbayDoctorFinding lifecycle = await probePatchbayLifecycle(
          connection,
          catalog,
          identity: identity,
        ).timeout(timeout - elapsed.elapsed);
        if (lifecycle.verdict != PatchbayCheckVerdict.ok) {
          lastCode = lifecycle.details['code'] as String? ?? 'appDidNotResume';
          await _wait(timeout, elapsed);
          continue;
        }
        await _eventSink('app.resumeObserved', <String, Object?>{
          'sessionId': current.record.sessionId,
          'appInstanceId': current.identity.appInstanceId,
        });

        lastStage = 'refreshCatalog';
        // Decoding is the target re-resolution fence. It rejects malformed or
        // duplicate live targets rather than preserving stale generations.
        final int targets = decodePatchbayCatalogUiTargets(catalog).length;
        lastStage = 'reResolveTargets';
        await _eventSink('permission.transition', <String, Object?>{
          'stage': lastStage,
          'sessionId': current.record.sessionId,
          'targetCount': targets,
        });
        return PatchbayPermissionRecoveryResult(
          sessionId: current.record.sessionId,
          applicationId: current.identity.applicationId,
          previousAppInstanceId: before.identity.appInstanceId,
          appInstanceId: current.identity.appInstanceId,
          runtimeRestarted:
              current.identity.appInstanceId != before.identity.appInstanceId,
          catalogRefreshed: true,
          resolvedTargetCount: targets,
        );
      } on TimeoutException {
        lastCode = 'budgetExceeded';
      } on PatchbayPermissionDriverException {
        rethrow;
      } on PatchbaySessionException catch (failure) {
        lastCode = failure.code;
      } on Object catch (failure) {
        lastCode = failure.runtimeType.toString();
      } finally {
        if (connection != null) {
          try {
            await connection.close();
          } on Object {
            // Recovery has already recorded the authoritative stage; a close
            // failure must not replace it with transport noise.
          }
        }
      }
      await _wait(timeout, elapsed);
    }
  }

  Future<void> _wait(Duration timeout, Stopwatch elapsed) async {
    final Duration remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) return;
    await _delay(
      remaining < retryDelay ? remaining : retryDelay,
    ).timeout(remaining);
  }

  static Future<PatchbayClient> _connectVmService(Uri uri) =>
      PatchbayConnection.connect(uri);
}
