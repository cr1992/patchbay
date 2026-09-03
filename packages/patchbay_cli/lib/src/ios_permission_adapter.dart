import 'dart:convert';

import 'package:patchbay/patchbay_protocol.dart';

import 'permission_platform_adapter.dart';

const Map<String, String> patchbayIosP0Permissions = <String, String>{
  'camera': 'camera',
  'microphone': 'microphone',
  'locationWhenInUse': 'location',
  'notifications': 'notifications',
};

final class PatchbayIosPermissionAdapter
    implements PatchbayPermissionPlatformAdapter {
  PatchbayIosPermissionAdapter({
    this.xcrunExecutable = 'xcrun',
    this.xcuiTestRunner,
    PatchbayPlatformCommandRunner? runCommand,
  }) : _run = runCommand ?? runPatchbayPlatformCommand;

  final String xcrunExecutable;
  final String? xcuiTestRunner;
  final PatchbayPlatformCommandRunner _run;

  @override
  Future<PatchbayPermissionDriverResponse> handle(
    PatchbayPermissionDriverRequest request,
  ) async {
    try {
      final PatchbayPlatformCommandResult version = await _run(
        xcrunExecutable,
        const <String>['simctl', 'help'],
        permissionAdapterTimeout(request),
      );
      if (version.exitCode != 0) {
        throw const _IosFailure('platformDriverUnavailable');
      }
      final String? simulator = await _selectBootedSimulatorOrNull(request);
      if (request.operation == PatchbayPermissionOperation.capabilities) {
        final PatchbayPermissionCapabilities capabilities;
        final String kind;
        if (simulator != null) {
          capabilities = _simulatorCapabilities;
          kind = 'simctl';
        } else {
          capabilities = await _physicalCapabilities(request);
          kind = 'xcuiTestRunner';
        }
        return acceptedPermissionDriverResponse(
          request,
          capabilities: capabilities,
          evidence: <PatchbayPermissionEvidence>[
            PatchbayPermissionEvidence(
              factSource: PatchbayPermissionFactSource.deviceReported,
              kind: 'platformTool',
              details: <String, Object?>{
                'executable': xcrunExecutable,
                'simctlAvailable': true,
                'xcuiTestRunnerConfigured': xcuiTestRunner?.isNotEmpty == true,
                'selectedBackend': kind,
              },
            ),
          ],
        );
      }
      final String permission = _requiredPermission(request);
      final String applicationId = _requiredApplication(request);
      if (simulator == null) {
        return await _handlePhysical(request, applicationId, permission);
      }
      await _verifyApplication(request, simulator, applicationId);

      if (request.operation == PatchbayPermissionOperation.reset) {
        final PatchbayPlatformCommandResult result =
            await _run(xcrunExecutable, <String>[
              'simctl',
              'privacy',
              simulator,
              'reset',
              patchbayIosP0Permissions[permission]!,
              applicationId,
            ], permissionAdapterTimeout(request));
        if (result.exitCode != 0) {
          throw const _IosFailure('permissionUnsupported');
        }
        return acceptedPermissionDriverResponse(
          request,
          after: _status(
            permission,
            PatchbayPermissionState.notDetermined,
            'simctlReset',
            capabilities: _simulatorCapabilities,
            factSource: PatchbayPermissionFactSource.deviceReported,
          ),
          evidence: <PatchbayPermissionEvidence>[
            _evidence('simctlPrivacyReset', simulator),
          ],
        );
      }
      if (request.operation == PatchbayPermissionOperation.exercise) {
        return await _exercise(
          request,
          simulator,
          applicationId,
          permission,
          capabilities: _simulatorCapabilities,
        );
      }
      // simctl has no public permission status query. Grant/revoke without an
      // independent read would turn an exit code into a false permission fact.
      throw const _IosFailure(
        'permissionUnsupported',
        notice:
            'simctl exposes privacy reset but no authoritative status read; '
            'normalize/status stay unsupported without an explicit test runner',
      );
    } on _IosFailure catch (failure) {
      return rejectedPermissionDriverResponse(
        request,
        failure.code,
        details: failure.details,
        notice: failure.notice,
      );
    }
  }

  PatchbayPermissionCapabilities get _simulatorCapabilities {
    final bool canExercise = xcuiTestRunner?.isNotEmpty == true;
    return PatchbayPermissionCapabilities(
      platform: 'ios',
      driver: 'ios.simctl-xcuitest',
      driverVersion: '1',
      permissions: <String, PatchbayPermissionCapability>{
        for (final String permission in patchbayIosP0Permissions.keys)
          permission: PatchbayPermissionCapability(
            actions: <PatchbayPermissionAction>{
              PatchbayPermissionAction.reset,
              if (canExercise) PatchbayPermissionAction.exercise,
            },
            decisions: canExercise
                ? <PatchbayPermissionDecision>{
                    PatchbayPermissionDecision.allow,
                    PatchbayPermissionDecision.deny,
                    if (permission == 'locationWhenInUse')
                      PatchbayPermissionDecision.allowOnce,
                  }
                : const <PatchbayPermissionDecision>{},
          ),
      },
    );
  }

  Future<String?> _selectBootedSimulatorOrNull(
    PatchbayPermissionDriverRequest request,
  ) async {
    final PatchbayPlatformCommandResult result = await _run(
      xcrunExecutable,
      const <String>['simctl', 'list', 'devices', 'booted', '--json'],
      permissionAdapterTimeout(request),
    );
    if (result.exitCode != 0) {
      throw const _IosFailure('platformDriverUnavailable');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout);
    } on FormatException {
      throw const _IosFailure('platformDriverProtocolError');
    }
    final List<String> devices = <String>[];
    if (decoded is Map<String, dynamic> &&
        decoded['devices'] is Map<Object?, Object?>) {
      for (final Object? rows
          in (decoded['devices']! as Map<Object?, Object?>).values) {
        if (rows is! List<Object?>) continue;
        for (final Object? row in rows) {
          if (row is Map<Object?, Object?> &&
              row['state'] == 'Booted' &&
              row['isAvailable'] != false &&
              row['udid'] is String) {
            devices.add(row['udid']! as String);
          }
        }
      }
    }
    if (request.deviceId case final String requested) {
      return devices.contains(requested) ? requested : null;
    }
    if (devices.length != 1) {
      throw _IosFailure(
        devices.isEmpty
            ? 'platformDeviceUnavailable'
            : 'platformDeviceAmbiguous',
        details: <String, Object?>{'deviceCount': devices.length},
      );
    }
    return devices.single;
  }

  Future<PatchbayPermissionCapabilities> _physicalCapabilities(
    PatchbayPermissionDriverRequest request,
  ) async {
    final String? device = request.deviceId;
    final String? applicationId = request.applicationId;
    if (device == null || applicationId == null || applicationId.isEmpty) {
      throw const _IosFailure('platformDeviceUnavailable');
    }
    final Map<String, dynamic> decoded = await _callRunner(
      request,
      operation: PatchbayPermissionOperation.capabilities,
      device: device,
      applicationId: applicationId,
    );
    _requireRunnerBinding(decoded, device, applicationId);
    final Object? rawCapabilities = decoded['capabilities'];
    if (rawCapabilities is! Map<Object?, Object?>) {
      throw const _IosFailure('platformDriverProtocolError');
    }
    final PatchbayPermissionCapabilities capabilities;
    try {
      capabilities = PatchbayPermissionCapabilities.fromJson(<String, Object?>{
        'platform': 'ios',
        'driver': 'ios.xcuitest',
        'driverVersion': '1',
        'permissions': rawCapabilities,
      });
    } on PatchbayPermissionWireException {
      throw const _IosFailure('platformDriverProtocolError');
    }
    if (capabilities.permissions.isEmpty ||
        capabilities.permissions.keys.any(
          (String permission) =>
              !patchbayIosP0Permissions.containsKey(permission),
        )) {
      throw const _IosFailure('platformDriverProtocolError');
    }
    for (final MapEntry<String, PatchbayPermissionCapability> entry
        in capabilities.permissions.entries) {
      if (entry.key != 'locationWhenInUse' &&
          entry.value.decisions.contains(
            PatchbayPermissionDecision.allowOnce,
          )) {
        throw const _IosFailure('platformDriverProtocolError');
      }
      if (entry.key == 'notifications' &&
          entry.value.actions.contains(PatchbayPermissionAction.reset)) {
        throw const _IosFailure('platformDriverProtocolError');
      }
    }
    return capabilities;
  }

  Future<PatchbayPermissionDriverResponse> _handlePhysical(
    PatchbayPermissionDriverRequest request,
    String applicationId,
    String permission,
  ) async {
    final String? device = request.deviceId;
    if (device == null) {
      throw const _IosFailure('platformDeviceUnavailable');
    }
    final PatchbayPermissionCapabilities capabilities =
        await _physicalCapabilities(request);
    final PatchbayPermissionCapability? permissionCapability =
        capabilities.permissions[permission];
    final PatchbayPermissionAction action = switch (request.operation) {
      PatchbayPermissionOperation.reset => PatchbayPermissionAction.reset,
      PatchbayPermissionOperation.exercise => PatchbayPermissionAction.exercise,
      PatchbayPermissionOperation.status => PatchbayPermissionAction.status,
      PatchbayPermissionOperation.normalize => switch (request.state) {
        PatchbayPermissionState.granted => PatchbayPermissionAction.grant,
        PatchbayPermissionState.notDetermined => PatchbayPermissionAction.reset,
        PatchbayPermissionState.denied ||
        PatchbayPermissionState.permanentlyDenied =>
          PatchbayPermissionAction.revoke,
        _ => throw const _IosFailure('permissionStateUnsupported'),
      },
      PatchbayPermissionOperation.fail => PatchbayPermissionAction.status,
      PatchbayPermissionOperation.capabilities => throw const _IosFailure(
        'permissionOperationInvalid',
      ),
    };
    if (permissionCapability == null ||
        !permissionCapability.actions.contains(action)) {
      throw const _IosFailure('permissionUnsupported');
    }
    if (request.operation == PatchbayPermissionOperation.exercise) {
      final PatchbayPermissionDecision? decision = request.decision;
      if (decision == null ||
          !permissionCapability.decisions.contains(decision)) {
        throw const _IosFailure('permissionDecisionUnsupported');
      }
      return _exercise(
        request,
        device,
        applicationId,
        permission,
        capabilities: capabilities,
      );
    }
    if (request.operation != PatchbayPermissionOperation.reset) {
      throw const _IosFailure('permissionUnsupported');
    }
    final Map<String, dynamic> decoded = await _callRunner(
      request,
      operation: PatchbayPermissionOperation.reset,
      device: device,
      applicationId: applicationId,
      permission: permission,
    );
    final PatchbayPermissionStatus status = _runnerStatus(
      decoded,
      request,
      device,
      applicationId,
      permission,
      capabilities,
    );
    if (status.state != PatchbayPermissionState.notDetermined) {
      throw const _IosFailure('systemUiUnexpected');
    }
    return acceptedPermissionDriverResponse(
      request,
      after: status,
      evidence: <PatchbayPermissionEvidence>[
        _evidence('xcuiProtectedResourceReset', device),
      ],
    );
  }

  Future<void> _verifyApplication(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
  ) async {
    final PatchbayPlatformCommandResult installed = await _run(
      xcrunExecutable,
      <String>['simctl', 'get_app_container', device, applicationId],
      permissionAdapterTimeout(request),
    );
    final PatchbayPlatformCommandResult running = await _run(
      xcrunExecutable,
      <String>['simctl', 'spawn', device, 'launchctl', 'list'],
      permissionAdapterTimeout(request),
    );
    if (installed.exitCode != 0 ||
        installed.stdout.trim().isEmpty ||
        running.exitCode != 0 ||
        !running.stdout.contains(applicationId)) {
      throw const _IosFailure('platformApplicationMismatch');
    }
  }

  Future<PatchbayPermissionDriverResponse> _exercise(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission, {
    required PatchbayPermissionCapabilities capabilities,
  }) async {
    final PatchbayPermissionDecision? decision = request.decision;
    if (decision == null) {
      throw const _IosFailure('permissionDecisionUnsupported');
    }
    final Map<String, dynamic> decoded = await _callRunner(
      request,
      operation: PatchbayPermissionOperation.exercise,
      device: device,
      applicationId: applicationId,
      permission: permission,
      decision: decision,
    );
    final PatchbayPermissionStatus status = _runnerStatus(
      decoded,
      request,
      device,
      applicationId,
      permission,
      capabilities,
    );
    if (decoded['decision'] != decision.name ||
        status.state == PatchbayPermissionState.unknown ||
        decision == PatchbayPermissionDecision.allow &&
            status.state != PatchbayPermissionState.granted ||
        decision == PatchbayPermissionDecision.allowOnce &&
            status.state != PatchbayPermissionState.allowOnce ||
        decision == PatchbayPermissionDecision.deny &&
            status.state != PatchbayPermissionState.denied &&
            status.state != PatchbayPermissionState.permanentlyDenied) {
      throw const _IosFailure('systemUiUnexpected');
    }
    return acceptedPermissionDriverResponse(
      request,
      after: status,
      evidence: <PatchbayPermissionEvidence>[
        _evidence('xcuiProtectedResource', device),
      ],
      interruption: PatchbayPermissionInterruption(
        expected: true,
        handled: true,
        permission: permission,
        decision: decision,
      ),
    );
  }

  Future<Map<String, dynamic>> _callRunner(
    PatchbayPermissionDriverRequest request, {
    required PatchbayPermissionOperation operation,
    required String device,
    required String applicationId,
    String? permission,
    PatchbayPermissionDecision? decision,
  }) async {
    final String? runner = xcuiTestRunner;
    if (runner == null || runner.isEmpty) {
      throw const _IosFailure('platformDeviceUnavailable');
    }
    final PatchbayPlatformCommandResult result = await _run(runner, <String>[
      '--operation',
      operation.name,
      '--device-id',
      device,
      '--application-id',
      applicationId,
      if (permission != null) ...<String>['--permission', permission],
      if (decision != null) ...<String>['--decision', decision.name],
    ], permissionAdapterTimeout(request));
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout.trim());
    } on FormatException {
      throw const _IosFailure('systemUiUnexpected');
    }
    if (result.exitCode != 0 || decoded is! Map<String, dynamic>) {
      throw const _IosFailure('systemUiUnexpected');
    }
    return decoded;
  }

  static void _requireRunnerBinding(
    Map<String, dynamic> decoded,
    String device,
    String applicationId,
  ) {
    if (decoded['deviceId'] != device ||
        decoded['applicationId'] != applicationId) {
      throw const _IosFailure('platformApplicationMismatch');
    }
  }

  PatchbayPermissionStatus _runnerStatus(
    Map<String, dynamic> decoded,
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
    PatchbayPermissionCapabilities capabilities,
  ) {
    _requireRunnerBinding(decoded, device, applicationId);
    if (decoded['permission'] != permission ||
        decoded['handled'] != true ||
        decoded['state'] is! String) {
      throw const _IosFailure('systemUiUnexpected');
    }
    final PatchbayPermissionState state = PatchbayPermissionState.fromWire(
      decoded['state'],
    );
    final PatchbayPermissionFactSource factSource =
        PatchbayPermissionFactSource.fromWire(decoded['factSource']);
    if (state == PatchbayPermissionState.unknown ||
        factSource == PatchbayPermissionFactSource.unknown) {
      throw const _IosFailure('systemUiUnexpected');
    }
    return _status(
      permission,
      state,
      decoded['platformState'] as String? ?? state.name,
      capabilities: capabilities,
      factSource: factSource,
    );
  }

  PatchbayPermissionStatus _status(
    String permission,
    PatchbayPermissionState state,
    String platformState, {
    required PatchbayPermissionCapabilities capabilities,
    required PatchbayPermissionFactSource factSource,
  }) => PatchbayPermissionStatus(
    permission: permission,
    platformPermission: patchbayIosP0Permissions[permission]!,
    state: state,
    platformState: platformState,
    factSource: factSource,
    driver: capabilities.driver,
    driverVersion: '1',
    supportedActions: capabilities.permissions[permission]!.actions,
    requiresRestart: false,
    requiresSettings:
        state == PatchbayPermissionState.permanentlyDenied ||
        state == PatchbayPermissionState.restricted,
    systemUiExpected: false,
  );

  static String _requiredPermission(PatchbayPermissionDriverRequest request) {
    final String? permission = request.permission;
    if (permission == null ||
        !patchbayIosP0Permissions.containsKey(permission)) {
      throw const _IosFailure('permissionUnsupported');
    }
    return permission;
  }

  static String _requiredApplication(PatchbayPermissionDriverRequest request) {
    final String? applicationId = request.applicationId;
    if (applicationId == null || applicationId.isEmpty) {
      throw const _IosFailure('platformApplicationMismatch');
    }
    return applicationId;
  }

  static PatchbayPermissionEvidence _evidence(String kind, String device) =>
      PatchbayPermissionEvidence(
        factSource: PatchbayPermissionFactSource.deviceReported,
        kind: kind,
        details: <String, Object?>{'deviceId': device},
      );
}

final class _IosFailure implements Exception {
  const _IosFailure(
    this.code, {
    this.details = const <String, Object?>{},
    this.notice,
  });

  final String code;
  final Map<String, Object?> details;
  final String? notice;
}
