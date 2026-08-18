import 'dart:convert';

import 'package:patchbay/patchbay.dart';

import 'permission_platform_adapter.dart';

const Map<String, String> patchbayAndroidP0Permissions = <String, String>{
  'camera': 'android.permission.CAMERA',
  'microphone': 'android.permission.RECORD_AUDIO',
  'locationWhenInUse': 'android.permission.ACCESS_FINE_LOCATION',
  'notifications': 'android.permission.POST_NOTIFICATIONS',
};

final class PatchbayAndroidPermissionAdapter
    implements PatchbayPermissionPlatformAdapter {
  PatchbayAndroidPermissionAdapter({
    this.adbExecutable = 'adb',
    this.instrumentationRunner,
    PatchbayPlatformCommandRunner? runCommand,
  }) : _run = runCommand ?? runPatchbayPlatformCommand;

  final String adbExecutable;
  final String? instrumentationRunner;
  final PatchbayPlatformCommandRunner _run;

  @override
  Future<PatchbayPermissionDriverResponse> handle(
    PatchbayPermissionDriverRequest request,
  ) async {
    try {
      final PatchbayPlatformCommandResult version = await _run(
        adbExecutable,
        const <String>['version'],
        permissionAdapterTimeout(request),
      );
      if (version.exitCode != 0) {
        throw const _AdapterFailure('platformDriverUnavailable');
      }
      if (request.operation == PatchbayPermissionOperation.capabilities) {
        return acceptedPermissionDriverResponse(
          request,
          capabilities: _capabilities,
          evidence: <PatchbayPermissionEvidence>[
            PatchbayPermissionEvidence(
              factSource: PatchbayPermissionFactSource.deviceReported,
              kind: 'platformTool',
              details: <String, Object?>{
                'executable': adbExecutable,
                'version': version.stdout.split('\n').first.trim(),
                'uiAutomatorRunnerConfigured':
                    instrumentationRunner?.isNotEmpty == true,
              },
            ),
          ],
        );
      }

      final String permission = _requiredPermission(request);
      final String applicationId = _requiredApplication(request);
      final String device = await _selectDevice(request);
      await _verifyApplication(
        request,
        device,
        applicationId,
        requireRunning: _mutates(request.operation),
      );

      if (request.operation == PatchbayPermissionOperation.status ||
          request.operation == PatchbayPermissionOperation.fail) {
        return acceptedPermissionDriverResponse(
          request,
          after: await _status(request, device, applicationId, permission),
          evidence: <PatchbayPermissionEvidence>[
            _evidence('androidPackageManager', device),
          ],
        );
      }
      final PatchbayPermissionStatus before = await _status(
        request,
        device,
        applicationId,
        permission,
      );
      if (request.operation == PatchbayPermissionOperation.reset ||
          request.operation == PatchbayPermissionOperation.normalize &&
              request.state == PatchbayPermissionState.notDetermined) {
        await _reset(request, device, applicationId, permission);
      } else if (request.operation == PatchbayPermissionOperation.normalize) {
        await _normalize(request, device, applicationId, permission);
      } else if (request.operation == PatchbayPermissionOperation.exercise) {
        return _exercise(request, device, applicationId, permission, before);
      } else {
        throw const _AdapterFailure('permissionOperationInvalid');
      }
      return acceptedPermissionDriverResponse(
        request,
        before: before,
        after: await _status(request, device, applicationId, permission),
        evidence: <PatchbayPermissionEvidence>[
          _evidence('androidPackageManagerMutation', device),
        ],
      );
    } on _AdapterFailure catch (failure) {
      return rejectedPermissionDriverResponse(
        request,
        failure.code,
        details: failure.details,
        notice: failure.notice,
      );
    }
  }

  PatchbayPermissionCapabilities get _capabilities {
    final Set<PatchbayPermissionAction> actions = <PatchbayPermissionAction>{
      PatchbayPermissionAction.status,
      PatchbayPermissionAction.grant,
      PatchbayPermissionAction.revoke,
      PatchbayPermissionAction.reset,
      if (instrumentationRunner?.isNotEmpty == true)
        PatchbayPermissionAction.exercise,
    };
    return PatchbayPermissionCapabilities(
      platform: 'android',
      driver: 'android.adb-uiautomator',
      driverVersion: '1',
      permissions: <String, PatchbayPermissionCapability>{
        for (final String permission in patchbayAndroidP0Permissions.keys)
          permission: PatchbayPermissionCapability(
            actions: actions,
            decisions: instrumentationRunner?.isNotEmpty == true
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

  Future<String> _selectDevice(PatchbayPermissionDriverRequest request) async {
    final PatchbayPlatformCommandResult result = await _run(
      adbExecutable,
      const <String>['devices'],
      permissionAdapterTimeout(request),
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('platformDriverUnavailable');
    }
    final List<String> devices = <String>[
      for (final String line in result.stdout.split('\n'))
        if (line.contains('\tdevice')) line.split('\t').first.trim(),
    ];
    if (request.deviceId case final String requested) {
      if (!devices.contains(requested)) {
        throw const _AdapterFailure('platformDeviceUnavailable');
      }
      return requested;
    }
    if (devices.length != 1) {
      throw _AdapterFailure(
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
    String applicationId, {
    required bool requireRunning,
  }) async {
    final PatchbayPlatformCommandResult installed = await _adb(
      request,
      device,
      <String>['shell', 'pm', 'path', applicationId],
    );
    if (installed.exitCode != 0 ||
        !installed.stdout.trim().startsWith('package:')) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
    if (!requireRunning) return;
    final PatchbayPlatformCommandResult running = await _adb(
      request,
      device,
      <String>['shell', 'pidof', applicationId],
    );
    if (running.exitCode != 0 ||
        !RegExp(r'^\d+(?:\s+\d+)*$').hasMatch(running.stdout.trim())) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
  }

  Future<PatchbayPermissionStatus> _status(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
  ) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    final PatchbayPlatformCommandResult result = await _adb(
      request,
      device,
      <String>['shell', 'dumpsys', 'package', applicationId],
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('permissionUnsupported');
    }
    final RegExpMatch? match = RegExp(
      '${RegExp.escape(platformPermission)}:\\s+granted=(true|false),\\s*flags=\\[([^\\]]*)\\]',
    ).firstMatch(result.stdout);
    if (match == null) {
      throw const _AdapterFailure('permissionUnsupported');
    }
    final bool granted = match.group(1) == 'true';
    final Set<String> flags = match
        .group(2)!
        .split(RegExp(r'[|,\s]+'))
        .where((String value) => value.isNotEmpty)
        .toSet();
    final PatchbayPermissionState state = granted
        ? PatchbayPermissionState.granted
        : flags.contains('USER_FIXED')
        ? PatchbayPermissionState.permanentlyDenied
        : flags.contains('USER_SET')
        ? PatchbayPermissionState.denied
        : PatchbayPermissionState.notDetermined;
    final List<String> sortedFlags = flags.toList(growable: false)..sort();
    return PatchbayPermissionStatus(
      permission: permission,
      platformPermission: platformPermission,
      state: state,
      platformState: granted
          ? 'granted'
          : sortedFlags.isEmpty
          ? 'denied'
          : 'denied:${sortedFlags.join('|')}',
      factSource: PatchbayPermissionFactSource.deviceReported,
      driver: 'android.adb-uiautomator',
      driverVersion: '1',
      supportedActions: _capabilities.permissions[permission]!.actions,
      requiresRestart: false,
      requiresSettings: state == PatchbayPermissionState.permanentlyDenied,
      systemUiExpected: false,
    );
  }

  Future<void> _normalize(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
  ) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    final List<String> action = switch (request.state) {
      PatchbayPermissionState.granted => <String>[
        'shell',
        'pm',
        'grant',
        applicationId,
        platformPermission,
      ],
      PatchbayPermissionState.denied => <String>[
        'shell',
        'pm',
        'revoke',
        applicationId,
        platformPermission,
      ],
      _ => throw const _AdapterFailure('permissionStateUnsupported'),
    };
    final PatchbayPlatformCommandResult result = await _adb(
      request,
      device,
      action,
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('permissionUnsupported');
    }
  }

  Future<void> _reset(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
  ) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    await _adb(request, device, <String>[
      'shell',
      'pm',
      'revoke',
      applicationId,
      platformPermission,
    ]);
    for (final String flag in const <String>['user-set', 'user-fixed']) {
      final PatchbayPlatformCommandResult result = await _adb(
        request,
        device,
        <String>[
          'shell',
          'pm',
          'clear-permission-flags',
          applicationId,
          platformPermission,
          flag,
        ],
      );
      if (result.exitCode != 0) {
        throw const _AdapterFailure('permissionUnsupported');
      }
    }
  }

  Future<PatchbayPermissionDriverResponse> _exercise(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
    PatchbayPermissionStatus before,
  ) async {
    final String? runner = instrumentationRunner;
    final PatchbayPermissionDecision? decision = request.decision;
    if (runner == null || runner.isEmpty || decision == null) {
      throw const _AdapterFailure('permissionDecisionUnsupported');
    }
    final PatchbayPlatformCommandResult result =
        await _adb(request, device, <String>[
          'shell',
          'am',
          'instrument',
          '-w',
          '-r',
          '-e',
          'targetPackage',
          applicationId,
          '-e',
          'permission',
          permission,
          '-e',
          'decision',
          decision.name,
          runner,
        ]);
    final String? marker = result.stdout
        .split('\n')
        .where((String line) => line.startsWith('PATCHBAY_RESULT='))
        .map((String line) => line.substring('PATCHBAY_RESULT='.length))
        .firstOrNull;
    if (result.exitCode != 0 || marker == null) {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Decode(marker)));
    } on Object {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['targetPackage'] != applicationId ||
        decoded['permission'] != permission ||
        decoded['decision'] != decision.name ||
        decoded['handled'] != true) {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    return acceptedPermissionDriverResponse(
      request,
      before: before,
      after: await _status(request, device, applicationId, permission),
      evidence: <PatchbayPermissionEvidence>[
        _evidence('androidUiAutomator', device),
      ],
      interruption: PatchbayPermissionInterruption(
        expected: true,
        handled: true,
        permission: permission,
        decision: decision,
      ),
    );
  }

  Future<PatchbayPlatformCommandResult> _adb(
    PatchbayPermissionDriverRequest request,
    String device,
    List<String> arguments,
  ) => _run(adbExecutable, <String>[
    '-s',
    device,
    ...arguments,
  ], permissionAdapterTimeout(request));

  static String _requiredPermission(PatchbayPermissionDriverRequest request) {
    final String? permission = request.permission;
    if (permission == null ||
        !patchbayAndroidP0Permissions.containsKey(permission)) {
      throw const _AdapterFailure('permissionUnsupported');
    }
    return permission;
  }

  static String _requiredApplication(PatchbayPermissionDriverRequest request) {
    final String? applicationId = request.applicationId;
    if (applicationId == null || applicationId.isEmpty) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
    return applicationId;
  }

  static bool _mutates(PatchbayPermissionOperation operation) =>
      operation == PatchbayPermissionOperation.normalize ||
      operation == PatchbayPermissionOperation.reset ||
      operation == PatchbayPermissionOperation.exercise;

  static PatchbayPermissionEvidence _evidence(String kind, String device) =>
      PatchbayPermissionEvidence(
        factSource: PatchbayPermissionFactSource.deviceReported,
        kind: kind,
        details: <String, Object?>{'deviceId': device},
      );
}

final class _AdapterFailure implements Exception {
  const _AdapterFailure(this.code, {this.details = const <String, Object?>{}});

  final String code;
  final Map<String, Object?> details;
  String? get notice => null;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
