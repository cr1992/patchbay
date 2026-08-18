import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

import '../tool/harmony_permission_fixture.dart';

void main() {
  final String fixturePath =
      '../../docs/verification/fixtures/harmonyos-permission-capability-v1.json';
  final String schemaPath =
      '../../docs/verification/fixtures/harmonyos-permission-capability-v1.schema.json';

  test('current HarmonyOS fixture is fail-closed and complete', () {
    final Map<String, Object?> fixture = readHarmonyPermissionFixture(
      fixturePath,
    );
    expect(validateHarmonyPermissionFixture(fixture), isEmpty);
    expect(fixture['supportStatus'], 'unsupported');
  });

  test('blocked matrix cannot publish a verified permission capability', () {
    final Map<String, Object?> fixture = _copyFixture(fixturePath);
    final Map<String, Object?> permissions =
        fixture['permissions']! as Map<String, Object?>;
    final Map<String, Object?> camera =
        permissions['camera']! as Map<String, Object?>;
    final Map<String, Object?> actions =
        camera['actions']! as Map<String, Object?>;
    actions['status'] = 'verified';

    expect(
      validateHarmonyPermissionFixture(fixture),
      contains(
        'permissions.camera must stay unsupported before platform verification',
      ),
    );
  });

  test('example evidence cannot make the platform verified', () {
    final Map<String, Object?> fixture = _copyFixture(fixturePath);
    fixture['supportStatus'] = 'verified';

    expect(
      validateHarmonyPermissionFixture(fixture),
      contains('supportStatus must be verified iff all six moii checks verify'),
    );
  });

  test('schema freezes six checks, moii app and unsupported state', () {
    final Map<String, Object?> schema =
        jsonDecode(File(schemaPath).readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> properties =
        schema['properties']! as Map<String, Object?>;
    final Map<String, Object?> matrix =
        properties['matrix']! as Map<String, Object?>;
    expect((matrix['required']! as List<Object?>).toSet(), harmonyMatrixKeys);

    final Map<String, Object?> defs = schema[r'$defs']! as Map<String, Object?>;
    final Map<String, Object?> baseline =
        defs['baseline']! as Map<String, Object?>;
    final Map<String, Object?> baselineProperties =
        baseline['properties']! as Map<String, Object?>;
    final Map<String, Object?> application =
        baselineProperties['application']! as Map<String, Object?>;
    final Map<String, Object?> applicationProperties =
        application['properties']! as Map<String, Object?>;
    expect(
      (applicationProperties['kind']! as Map<String, Object?>)['const'],
      'moiiApp',
    );
  });

  test('identity and root READMEs do not advertise HarmonyOS support', () {
    expect(
      PatchbayFeature.values.any(
        (PatchbayFeature feature) =>
            feature.name.toLowerCase().contains('harmony'),
      ),
      isFalse,
    );
    for (final String path in <String>[
      '../../README.md',
      '../../README.zh-CN.md',
    ]) {
      final String readme = File(path).readAsStringSync().toLowerCase();
      expect(readme, isNot(contains('harmonyos support: verified')));
      expect(readme, isNot(contains('harmonyos：已支持')));
    }
  });
}

Map<String, Object?> _copyFixture(String path) =>
    jsonDecode(jsonEncode(readHarmonyPermissionFixture(path)))
        as Map<String, Object?>;
