import 'dart:convert';

import 'package:patchbay/patchbay.dart';

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
      if (request.operation == PatchbayPermissionOperation.capabilities) {
        // `simctl privacy` can only operate a booted Simulator. Merely finding
        // `simctl` on a Mac is not evidence that the explicitly selected
        // device can execute reset: a physical iPhone UDID must not inherit a
        // Simulator capability just because both are visible to Flutter.
        await _selectBootedSimulator(request);
        return acceptedPermissionDriverResponse(
          request,
          capabilities: _capabilities,
          evidence: <PatchbayPermissionEvidence>[
            PatchbayPermissionEvidence(
              factSource: PatchbayPermissionFactSource.deviceReported,
              kind: 'platformTool',
              details: <String, Object?>{
                'executable': xcrunExecutable,
                'simctlAvailable': true,
                'xcuiTestRunnerConfigured': xcuiTestRunner?.isNotEmpty == true,
              },
            ),
          ],
        );
      }
      final String permission = _requiredPermission(request);
      final String applicationId = _requiredApplication(request);
      final String device = await _selectBootedSimulator(request);
      await _verifyApplication(request, device, applicationId);

      if (request.operation == PatchbayPermissionOperation.reset) {
        final PatchbayPlatformCommandResult result =
            await _run(xcrunExecutable, <String>[
              'simctl',
              'privacy',
              device,
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
          ),
          evidence: <PatchbayPermissionEvidence>[
            _evidence('simctlPrivacyReset', device),
          ],
        );
      }
      if (request.operation == PatchbayPermissionOperation.exercise) {
        return _exercise(request, device, applicationId, permission);
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

  PatchbayPermissionCapabilities get _capabilities {
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
                ? const <PatchbayPermissionDecision>{
                    PatchbayPermissionDecision.allow,
                    PatchbayPermissionDecision.deny,
                    PatchbayPermissionDecision.allowOnce,
                  }
                : const <PatchbayPermissionDecision>{},
          ),
      },
    );
  }

  Future<String> _selectBootedSimulator(
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
      if (!devices.contains(requested)) {
        throw const _IosFailure('platformDeviceUnavailable');
      }
      return requested;
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
    String permission,
  ) async {
    final String? runner = xcuiTestRunner;
    final PatchbayPermissionDecision? decision = request.decision;
    if (runner == null || runner.isEmpty || decision == null) {
      throw const _IosFailure('permissionDecisionUnsupported');
    }
    final PatchbayPlatformCommandResult result = await _run(runner, <String>[
      '--device-id',
      device,
      '--application-id',
      applicationId,
      '--permission',
      permission,
      '--decision',
      decision.name,
    ], permissionAdapterTimeout(request));
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout.trim());
    } on FormatException {
      throw const _IosFailure('systemUiUnexpected');
    }
    if (result.exitCode != 0 ||
        decoded is! Map<String, dynamic> ||
        decoded['deviceId'] != device ||
        decoded['applicationId'] != applicationId ||
        decoded['permission'] != permission ||
        decoded['decision'] != decision.name ||
        decoded['handled'] != true ||
        decoded['state'] is! String) {
      throw const _IosFailure('systemUiUnexpected');
    }
    final PatchbayPermissionState state = PatchbayPermissionState.fromWire(
      decoded['state'],
    );
    if (state == PatchbayPermissionState.unknown ||
        decision == PatchbayPermissionDecision.allow &&
            state != PatchbayPermissionState.granted ||
        decision == PatchbayPermissionDecision.allowOnce &&
            state != PatchbayPermissionState.allowOnce ||
        decision == PatchbayPermissionDecision.deny &&
            state != PatchbayPermissionState.denied &&
            state != PatchbayPermissionState.permanentlyDenied) {
      throw const _IosFailure('systemUiUnexpected');
    }
    return acceptedPermissionDriverResponse(
      request,
      after: _status(
        permission,
        state,
        decoded['platformState'] as String? ?? state.name,
      ),
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

  PatchbayPermissionStatus _status(
    String permission,
    PatchbayPermissionState state,
    String platformState,
  ) => PatchbayPermissionStatus(
    permission: permission,
    platformPermission: patchbayIosP0Permissions[permission]!,
    state: state,
    platformState: platformState,
    factSource: PatchbayPermissionFactSource.deviceReported,
    driver: 'ios.simctl-xcuitest',
    driverVersion: '1',
    supportedActions: _capabilities.permissions[permission]!.actions,
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
