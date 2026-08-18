import 'dart:math';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'command_registry.dart';
import 'permission_driver.dart';
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
  }) : _discovery = discovery ?? const PatchbayPermissionDriverDiscovery(),
       _clientFactory =
           clientFactory ??
           ((String path) => PatchbayPermissionDriverClient(executable: path)),
       _sessions = sessions;

  final PatchbayPermissionDriverDiscovery _discovery;
  final PatchbayPermissionDriverClientFactory _clientFactory;
  final PatchbaySessionResolver? _sessions;

  Future<PatchbayPermissionCommandOutcome> run(
    ArgResults options,
    PatchbayFriendlyInvocation invocation,
  ) async {
    final PatchbayPermissionOperation operation = _operation(invocation.spec);
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
      final PatchbaySessionRecord record = session.record;
      if (mutates && record.buildMode == 'release') {
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
          timeout: budget,
        );
    final Map<String, Object?> json = response.toJson();
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
      operation == PatchbayPermissionOperation.exercise;

  static PatchbayPermissionOperation _operation(
    PatchbayFriendlyCommand command,
  ) => switch (command) {
    PatchbayFriendlyCommand.permissionCapabilities =>
      PatchbayPermissionOperation.capabilities,
    PatchbayFriendlyCommand.permissionStatus =>
      PatchbayPermissionOperation.status,
    PatchbayFriendlyCommand.permissionNormalize =>
      PatchbayPermissionOperation.normalize,
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
}
