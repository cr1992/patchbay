import 'dart:math';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'command_registry.dart';
import 'permission_driver.dart';
import 'permission_recovery.dart';
import 'result.dart';
import 'session.dart';

typedef PatchbayPermissionDriverClientFactory =
    PatchbayPermissionDriverClient Function(String executable);

final class PatchbayPermissionCommandOutcome {
  const PatchbayPermissionCommandOutcome(
    this.response,
    this.exitCode,
    this.summary,
  );

  final Map<String, Object?> response;
  final int exitCode;
  final String summary;
}

/// CLI-side permission orchestration that never operates native UI itself.
final class PatchbayPermissionCommandRunner {
  PatchbayPermissionCommandRunner({
    PatchbayPermissionDriverDiscovery? discovery,
    PatchbayPermissionDriverClientFactory? clientFactory,
    PatchbaySessionResolver? sessions,
    PatchbayPermissionRecoveryCoordinator? recovery,
    PatchbayPermissionEventSink? eventSink,
  }) : _discovery = discovery ?? const PatchbayPermissionDriverDiscovery(),
       _clientFactory =
           clientFactory ??
           ((String path) => PatchbayPermissionDriverClient(executable: path)),
       _sessions = sessions,
       _recovery = recovery,
       _eventSink = eventSink ?? ignorePatchbayPermissionEvent;

  final PatchbayPermissionDriverDiscovery _discovery;
  final PatchbayPermissionDriverClientFactory _clientFactory;
  final PatchbaySessionResolver? _sessions;
  final PatchbayPermissionRecoveryCoordinator? _recovery;
  final PatchbayPermissionEventSink _eventSink;

  Future<PatchbayPermissionCommandOutcome> run(
    ArgResults options,
    PatchbayFriendlyInvocation invocation,
  ) async {
    if (invocation.spec == PatchbayFriendlyCommand.permissionDoctor) {
      return _doctor(options);
    }
    final PatchbayPermissionOperation operation = _operation(invocation.spec);
    final Stopwatch elapsed = Stopwatch()..start();
    _validateDetachedSelection(options);
    if (options.option('ws-uri') != null ||
        options.option('direct-endpoint') != null) {
      throw const FormatException(
        '--ws-uri and direct transport options do not select an external '
        'permission driver target; use --session or --device-id with '
        '--application-id',
      );
    }
    final PatchbayPermissionDecision? decision = _decision(
      invocation.arguments['decision'],
    );
    if (operation == PatchbayPermissionOperation.exercise &&
        decision == PatchbayPermissionDecision.allow &&
        (!options.wasParsed('confirm-system-permission') ||
            !options.flag('confirm-system-permission'))) {
      throw const FormatException(
        'permission exercise --decision allow requires the explicit '
        '--confirm-system-permission flag',
      );
    }

    String? deviceId = options.option('device-id');
    String? applicationId = options.option('application-id');
    Map<String, Object?>? sessionRef;
    PatchbayDiscoveredSession? selectedSession;
    final bool mutates = _mutates(operation);
    if (mutates ||
        options.option('session') != null ||
        options.wasParsed('session-dir')) {
      final PatchbayDiscoveredSession session =
          await (_sessions ??
                  PatchbaySessionResolver(
                    store: PatchbaySessionStore(options.option('session-dir')),
                  ))
              .resolve(sessionId: options.option('session'));
      selectedSession = session;
      final PatchbaySessionRecord record = session.record;
      if (mutates &&
          !const <String>{'debug', 'profile'}.contains(record.buildMode)) {
        throw const PatchbayPermissionDriverException(
          'permissionReleaseBuildForbidden',
        );
      }
      if (record.appInstanceId == null ||
          record.appInstanceId != session.identity.appInstanceId ||
          record.applicationId != session.identity.applicationId) {
        throw const PatchbayPermissionDriverException(
          'permissionSessionIdentityMismatch',
        );
      }
      if ((deviceId != null && deviceId != record.deviceId) ||
          (applicationId != null && applicationId != record.applicationId)) {
        throw const PatchbayPermissionDriverException(
          'platformApplicationMismatch',
        );
      }
      deviceId = record.deviceId;
      applicationId = record.applicationId;
      sessionRef = <String, Object?>{
        'sessionId': record.sessionId,
        'appInstanceId': record.appInstanceId,
        'buildMode': record.buildMode,
      };
    }

    final String executable = _discovery.resolve(
      configuredPath: options.option('permission-driver'),
    );
    final String? rawTimeout = options.option('timeout-ms');
    final Duration? requestedTimeout = rawTimeout == null
        ? null
        : Duration(milliseconds: _positiveInt(rawTimeout, '--timeout-ms'));
    final Duration budget = PatchbayPermissionBudget.forOperation(
      operation,
    ).validate(requestedTimeout);
    await _eventSink('permission.preflight', <String, Object?>{
      'operation': operation.name,
      if (invocation.arguments['permission'] case final String permission)
        'permission': permission,
      if (sessionRef?['sessionId'] case final String sessionId)
        'sessionId': sessionId,
      'budgetMs': budget.inMilliseconds,
    });
    final Duration driverBudget = budget - elapsed.elapsed;
    if (driverBudget <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    final String requestId = _requestId();
    final PatchbayPermissionDriverResponse response =
        await PatchbayPermissionDriverRunner(_clientFactory(executable)).run(
          PatchbayPermissionDriverRequest(
            requestId: requestId,
            operation: operation,
            deviceId: deviceId,
            applicationId: applicationId,
            sessionRef: sessionRef,
            permission: invocation.arguments['permission'] as String?,
            policy: operation.name,
            state: _state(invocation.arguments['state']),
            decision: decision,
            timeoutMs: budget.inMilliseconds,
          ),
          timeout: driverBudget,
        );
    await _eventSink('permission.transition', <String, Object?>{
      'stage': 'driverCompleted',
      'operation': operation.name,
      'admission': response.admission,
      if (response.code != null) 'code': response.code,
    });
    PatchbayPermissionRecoveryResult? recovery;
    if (operation == PatchbayPermissionOperation.exercise &&
        response.accepted &&
        selectedSession != null &&
        response.interruption?.handled == true) {
      final PatchbayPermissionInterruption? interruption =
          response.interruption;
      if (interruption != null) {
        await _eventSink('systemUi.detected', <String, Object?>{
          'expected': interruption.expected,
          'handled': interruption.handled,
          if (interruption.permission != null)
            'permission': interruption.permission,
          if (interruption.decision != null)
            'decision': interruption.decision!.name,
        });
        if (interruption.handled) {
          await _eventSink('systemUi.handled', <String, Object?>{
            if (interruption.permission != null)
              'permission': interruption.permission,
            if (interruption.decision != null)
              'decision': interruption.decision!.name,
          });
        }
      }
      final Duration remaining = budget - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw const PatchbayPermissionDriverException('budgetExceeded');
      }
      recovery =
          await (_recovery ??
                  PatchbayPermissionRecoveryCoordinator(
                    sessions:
                        _sessions ??
                        PatchbaySessionResolver(
                          store: PatchbaySessionStore(
                            options.option('session-dir'),
                          ),
                        ),
                    eventSink: _eventSink,
                  ))
              .recover(selectedSession, timeout: remaining);
    }
    final Map<String, Object?> json = <String, Object?>{
      ...response.toJson(),
      if (recovery != null) 'recovery': recovery.toJson(),
    };
    return PatchbayPermissionCommandOutcome(
      json,
      response.accepted ? PatchbayExitCode.accepted : PatchbayExitCode.rejected,
      _summary(response),
    );
  }

  static void _validateDetachedSelection(ArgResults options) {
    final bool device = options.option('device-id') != null;
    final bool application = options.option('application-id') != null;
    if (device != application) {
      throw const FormatException(
        '--device-id and --application-id must be supplied together',
      );
    }
  }

  static bool _mutates(PatchbayPermissionOperation operation) =>
      operation == PatchbayPermissionOperation.normalize ||
      operation == PatchbayPermissionOperation.reset ||
      operation == PatchbayPermissionOperation.exercise;

  static PatchbayPermissionOperation _operation(
    PatchbayFriendlyCommandSpec command,
  ) => switch (command) {
    PatchbayFriendlyCommand.permissionCapabilities =>
      PatchbayPermissionOperation.capabilities,
    PatchbayFriendlyCommand.permissionStatus =>
      PatchbayPermissionOperation.status,
    PatchbayFriendlyCommand.permissionNormalize =>
      PatchbayPermissionOperation.normalize,
    PatchbayFriendlyCommand.permissionReset =>
      PatchbayPermissionOperation.reset,
    PatchbayFriendlyCommand.permissionExercise =>
      PatchbayPermissionOperation.exercise,
    PatchbayFriendlyCommand.permissionFail => PatchbayPermissionOperation.fail,
    _ => throw StateError('not a permission command: ${command.name}'),
  };

  static PatchbayPermissionState? _state(Object? value) => value == null
      ? null
      : PatchbayPermissionState.values.firstWhere(
          (PatchbayPermissionState state) => state.name == value,
        );

  static PatchbayPermissionDecision? _decision(Object? value) => value == null
      ? null
      : PatchbayPermissionDecision.values.firstWhere(
          (PatchbayPermissionDecision decision) => decision.name == value,
        );

  static int _positiveInt(String raw, String label) {
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      throw FormatException('$label must be a positive integer');
    }
    return parsed;
  }

  static String _requestId() =>
      'permission-${DateTime.now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(1 << 32)}';

  static String _summary(PatchbayPermissionDriverResponse response) {
    final PatchbayPermissionStatus? status = response.after ?? response.before;
    if (status != null) {
      return 'permission=${status.permission} state=${status.state.name} '
          'source=${status.factSource.name}';
    }
    if (response.capabilities case final PatchbayPermissionCapabilities value) {
      return 'driver=${value.driver} platform=${value.platform} '
          'permissions=${value.permissions.length}';
    }
    return response.code ?? response.admission;
  }

  Future<PatchbayPermissionCommandOutcome> _doctor(ArgResults options) async {
    _validateDetachedSelection(options);
    String? deviceId = options.option('device-id');
    String? applicationId = options.option('application-id');
    if (options.option('session') != null || options.wasParsed('session-dir')) {
      final PatchbayDiscoveredSession session =
          await (_sessions ??
                  PatchbaySessionResolver(
                    store: PatchbaySessionStore(options.option('session-dir')),
                  ))
              .resolve(sessionId: options.option('session'));
      deviceId = session.record.deviceId;
      applicationId = session.record.applicationId;
    }
    final String executable = _discovery.resolve(
      configuredPath: options.option('permission-driver'),
    );
    final String? rawTimeout = options.option('timeout-ms');
    final Duration timeout = PatchbayPermissionBudget.read.validate(
      rawTimeout == null
          ? null
          : Duration(milliseconds: _positiveInt(rawTimeout, '--timeout-ms')),
    );
    final PatchbayPermissionDriverResponse response =
        await PatchbayPermissionDriverRunner(_clientFactory(executable)).run(
          PatchbayPermissionDriverRequest(
            requestId: _requestId(),
            operation: PatchbayPermissionOperation.capabilities,
            deviceId: deviceId,
            applicationId: applicationId,
            timeoutMs: timeout.inMilliseconds,
          ),
          timeout: timeout,
        );
    final PatchbayPermissionCapabilities? capabilities = response.capabilities;
    final Map<String, Object?> report = <String, Object?>{
      'doctor': <String, Object?>{
        'scope': 'permission',
        'verdict': response.accepted ? 'ok' : 'failed',
        'driver': <String, Object?>{
          'path': executable,
          'protocolVersion': response.protocolVersion,
          if (capabilities != null) ...<String, Object?>{
            'name': capabilities.driver,
            'version': capabilities.driverVersion,
            'platform': capabilities.platform,
          },
        },
        if (capabilities != null)
          'permissions': capabilities.toJson()['permissions'],
        if (response.code != null) 'code': response.code,
        'evidence': <Map<String, Object?>>[
          for (final PatchbayPermissionEvidence evidence in response.evidence)
            evidence.toJson(),
        ],
      },
    };
    return PatchbayPermissionCommandOutcome(
      report,
      response.accepted ? PatchbayExitCode.accepted : PatchbayExitCode.rejected,
      capabilities == null
          ? 'permission driver unavailable code=${response.code}'
          : 'permission driver=${capabilities.driver} path=$executable',
    );
  }
}
