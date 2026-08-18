import 'dart:convert';
import 'dart:io';

const Set<String> harmonyMatrixKeys = <String>{
  'coreFlutterBuild',
  'vmServiceAttach',
  'semanticsLifecycleArtifact',
  'appPermissionApi',
  'uiTestHypium',
  'hdcRecovery',
};

const Set<String> harmonyPermissionKeys = <String>{
  'camera',
  'microphone',
  'locationWhenInUse',
  'notifications',
  'bluetooth',
};

Map<String, Object?> readHarmonyPermissionFixture(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('fixture root must be a JSON object');
  }
  return decoded;
}

List<String> validateHarmonyPermissionFixture(Map<String, Object?> fixture) {
  final List<String> errors = <String>[];
  if (fixture['schemaVersion'] != 1) {
    errors.add('schemaVersion must be 1');
  }
  if (fixture['platform'] != 'harmonyos') {
    errors.add('platform must be harmonyos');
  }

  final Map<String, Object?>? baseline = _map(fixture['baseline']);
  if (baseline == null) {
    errors.add('baseline must be an object');
  } else {
    _requireNonEmpty(baseline, 'recordedAt', 'baseline', errors);
    _requireNonEmpty(baseline, 'patchbayRevision', 'baseline', errors);
    final Map<String, Object?>? flutterSdk = _map(baseline['flutterSdk']);
    final Map<String, Object?>? platformSdk = _map(baseline['platformSdk']);
    final Map<String, Object?>? tools = _map(baseline['tools']);
    final Map<String, Object?>? device = _map(baseline['device']);
    final Map<String, Object?>? application = _map(baseline['application']);
    if (flutterSdk == null) {
      errors.add('baseline.flutterSdk must be an object');
    } else {
      for (final String key in <String>{
        'selectionStatus',
        'distribution',
        'repository',
        'frameworkVersion',
        'frameworkRevision',
        'dartVersion',
      }) {
        _requireNonEmpty(flutterSdk, key, 'baseline.flutterSdk', errors);
      }
    }
    if (platformSdk == null ||
        platformSdk['apiLevel'] is! int ||
        (platformSdk['apiLevel'] as int? ?? 0) < 1) {
      errors.add('baseline.platformSdk.apiLevel must be a positive integer');
    }
    if (tools == null ||
        <String>{'hdcVersion', 'hvigorVersion', 'ohpmVersion'}.any(
          (String key) =>
              tools[key] is! String || (tools[key] as String).isEmpty,
        )) {
      errors.add('baseline.tools must declare hdc/hvigor/ohpm versions');
    }
    if (device == null ||
        !<String>{'available', 'unavailable'}.contains(device['status'])) {
      errors.add('baseline.device.status must be available or unavailable');
    }
    if (application == null ||
        application['kind'] != 'moiiApp' ||
        !<String>{'available', 'unavailable'}.contains(application['status'])) {
      errors.add('baseline.application must describe moiiApp availability');
    }
  }

  final Map<String, Object?>? matrix = _map(fixture['matrix']);
  bool allChecksVerified = true;
  if (matrix == null ||
      matrix.keys.toSet().difference(harmonyMatrixKeys).isNotEmpty ||
      harmonyMatrixKeys.difference(matrix.keys.toSet()).isNotEmpty) {
    errors.add('matrix must contain exactly the six HarmonyOS checks');
    allChecksVerified = false;
  } else {
    for (final String key in harmonyMatrixKeys) {
      final Map<String, Object?>? check = _map(matrix[key]);
      if (check == null) {
        errors.add('matrix.$key must be an object');
        allChecksVerified = false;
        continue;
      }
      final Object? status = check['status'];
      final List<Object?>? blockers = _list(check['blockers']);
      final List<Object?>? evidence = _list(check['evidence']);
      if (!<String>{
        'verified',
        'failed',
        'blockedBySdk',
        'blockedByDevice',
        'notRun',
      }.contains(status)) {
        errors.add('matrix.$key has an invalid status');
      }
      if (blockers == null || evidence == null) {
        errors.add('matrix.$key must declare blockers and evidence arrays');
      }
      if (status == 'verified') {
        if (blockers?.isNotEmpty ?? true) {
          errors.add('matrix.$key verified result cannot retain blockers');
        }
        if (evidence?.isEmpty ?? true) {
          errors.add('matrix.$key verified result requires evidence');
        }
        if (check['scope'] != 'moiiDeviceAcceptance') {
          errors.add('matrix.$key verified result must come from moii app');
        }
      } else {
        allChecksVerified = false;
      }
      if ((status == 'blockedBySdk' || status == 'blockedByDevice') &&
          (blockers?.isEmpty ?? true)) {
        errors.add('matrix.$key blocked result requires a blocker');
      }
    }
  }

  final Object? supportStatus = fixture['supportStatus'];
  if (supportStatus != (allChecksVerified ? 'verified' : 'unsupported')) {
    errors.add('supportStatus must be verified iff all six moii checks verify');
  }

  final Map<String, Object?>? permissions = _map(fixture['permissions']);
  if (permissions == null ||
      permissions.keys.toSet().difference(harmonyPermissionKeys).isNotEmpty ||
      harmonyPermissionKeys.difference(permissions.keys.toSet()).isNotEmpty) {
    errors.add('permissions must contain the P0 set and P1 bluetooth');
  } else {
    for (final String permissionName in harmonyPermissionKeys) {
      final Map<String, Object?>? permission = _map(
        permissions[permissionName],
      );
      if (permission == null) {
        errors.add('permissions.$permissionName must be an object');
        continue;
      }
      final Iterable<Object?> capabilityStates = <Object?>[
        ...?_map(permission['actions'])?.values,
        ...?_map(permission['decisions'])?.values,
      ];
      if (capabilityStates.any(
        (Object? state) => !<String>{'verified', 'unsupported'}.contains(state),
      )) {
        errors.add('permissions.$permissionName has an invalid capability');
      }
      if (supportStatus == 'unsupported' &&
          capabilityStates.any((Object? state) => state != 'unsupported')) {
        errors.add(
          'permissions.$permissionName must stay unsupported before platform verification',
        );
      }
    }
  }
  return errors;
}

Map<String, Object?>? _map(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?>? _list(Object? value) => value is List<Object?> ? value : null;

void _requireNonEmpty(
  Map<String, Object?> value,
  String key,
  String prefix,
  List<String> errors,
) {
  final Object? field = value[key];
  if (field is! String || field.isEmpty) {
    errors.add('$prefix.$key must be a non-empty string');
  }
}
