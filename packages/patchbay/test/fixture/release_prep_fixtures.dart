import 'dart:convert';
import 'dart:io';

import '../../tool/release_prep.dart';

const String fixtureSha = 'd32f45e9d652920902e51f9c3dc25c189d804e46';

const String fixtureDescription =
    'Consumer-neutral fixture package used by the release_prep unit tests.';

String repoRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/$changelogPath').existsSync() &&
        File('${directory.path}/${pubspecPathOf('patchbay')}').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('找不到仓根（从 ${Directory.current.path} 向上）');
    }
    directory = parent;
  }
}

String pubspecFixture(
  String name, {
  required bool publishable,
  required String version,
  required String constraintVersion,
  required String description,
}) {
  final bool isFlutter = name == 'patchbay_flutter';
  final bool isCli = name == 'patchbay_cli';
  final StringBuffer out = StringBuffer()
    ..writeln('name: $name')
    ..writeln('description: $description')
    ..writeln('version: $version');
  if (publishable) {
    out.writeln('repository: https://example.invalid/patchbay');
  } else {
    out.writeln('publish_to: none');
  }
  out
    ..writeln()
    ..writeln('environment:')
    ..writeln("  sdk: '>=3.11.0 <4.0.0'");
  if (isFlutter) out.writeln("  flutter: '>=3.38.0'");
  if (isFlutter || isCli) {
    out
      ..writeln()
      ..writeln('dependencies:');
    if (isFlutter) {
      out
        ..writeln('  flutter:')
        ..writeln('    sdk: flutter');
    }
    if (publishable) {
      out.writeln('  patchbay: ^$constraintVersion');
      if (isCli) out.writeln('  patchbay_transport: ^$constraintVersion');
    } else {
      out
        ..writeln('  patchbay:')
        ..writeln('    path: ../patchbay');
      if (isCli) {
        out
          ..writeln('  patchbay_transport:')
          ..writeln('    path: ../patchbay_transport');
      }
    }
  }
  return out.toString();
}

String hostSurfaceFixture(String version) => jsonEncode(<String, Object?>{
  'identity': <String, Object?>{
    'schemaVersion': 1,
    'serverVersion': '<patchbayPackageVersion>',
    'features': <String>['catalogDigest'],
    'applicationId': 'dev.patchbay.fixture.$version',
    'appInstanceId': 'fixture-instance',
    'isolateId': '<runtime>',
  },
  'catalog': <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{'name': 'fixture.command'},
    ],
    'uiTargets': <Object?>[],
    'schemaVersion': 1,
    'catalogDigest': <String, Object?>{
      'algorithm': 'sha256',
      'covers': <String>['commands'],
      'value': 'fixture-digest',
    },
  },
});

String releaseReadmeFixture(String version, {required bool chinese}) =>
    '''
> **${chinese ? '项目状态：' : 'Project status:'}** `v$version`, ${chinese ? '已发布到 pub.dev' : 'published on pub.dev'}
  patchbay_flutter: ^$version
curl /releases/download/patchbay-v$version/patchbay-$version-macos-arm64
\$ dart pub global activate patchbay_cli $version
''';

Map<String, String> releaseDocumentsFixture(String version) => <String, String>{
  'README.md': releaseReadmeFixture(version, chinese: false),
  'README.zh-CN.md': releaseReadmeFixture(version, chinese: true),
  'docs/guide.md':
      '''
# Guide
  patchbay_flutter: ^$version
\$ dart pub global activate patchbay_cli $version
curl /releases/download/patchbay-v$version/patchbay-$version-linux-x64
''',
  'packages/patchbay_cli/README.md':
      '# CLI\n\n\$ dart pub global activate patchbay_cli $version\n',
  'packages/patchbay_cli/README.zh-CN.md':
      '# CLI\n\n\$ dart pub global activate patchbay_cli $version\n',
  'packages/patchbay/README.md': '# Core\n',
  'packages/patchbay/README.zh-CN.md': '# Core\n',
  'packages/patchbay_transport/README.md': '# Transport\n',
  'packages/patchbay_transport/README.zh-CN.md': '# Transport\n',
  'packages/patchbay_flutter/README.md': '# Flutter\n',
  'packages/patchbay_flutter/README.zh-CN.md': '# Flutter\n',
  'packages/patchbay_flutter/example/README.md': '# Example\n',
  'packages/patchbay_flutter/example/README.zh-CN.md': '# Example\n',
  'docs/design.md': 'CLI->>Host: exec example.job.run\n',
  'docs/assets/patchbay-hero.svg':
      '<svg><text>patchbay exec example.job.run</text></svg>\n',
  'docs/assets/patchbay-architecture.svg':
      '<svg><text>patchbay</text><text>patchbay_transport</text>'
      '<text>patchbay_cli</text><text>patchbay_flutter</text>'
      '<text>gesture / inspect / wait</text></svg>\n',
};

ReleaseInputs releaseInputsFixture({
  bool released = false,
  bool publishable = false,
  int invocationSchema = 1,
  String matrixSchemaCell = '1',
  String sha = pendingSha,
  String consumers = pendingConsumers,
  String? version,
  String? constraintVersion,
  String? packageChangelogVersion,
  String description = fixtureDescription,
  String exampleOverridePath = '../../patchbay',
  Set<String> dropOverrides = const <String>{},
  String? hostSurfaceGolden,
  Map<String, String>? compatibilityCorpus,
  Map<String, String> documentOverrides = const <String, String>{},
}) {
  final String resolved = version ?? (released ? '0.3.0' : '0.2.1');
  final String constraints = constraintVersion ?? resolved;
  final String changelogVersion = packageChangelogVersion ?? resolved;
  final String resolvedHostSurface =
      hostSurfaceGolden ?? hostSurfaceFixture(resolved);
  final String newRow = released
      ? '| `$tagPrefix$resolved` | `$sha` | $matrixSchemaCell | 3.44.9 '
            '| `>=3.38.0` | $consumers |\n'
      : '';
  String? overridesFor(String name) {
    if (!publishable) return null;
    if (dropOverrides.contains('packages/$name')) return null;
    return switch (name) {
      'patchbay_cli' => renderOverrides(<String, String>{
        'patchbay': '../patchbay',
        'patchbay_transport': '../patchbay_transport',
      }),
      'patchbay_flutter' => renderOverrides(<String, String>{
        'patchbay': '../patchbay',
      }),
      _ => null,
    };
  }

  return ReleaseInputs(
    packages: <String, PackageManifest>{
      for (final String name in releasePackages)
        name: PackageManifest(
          name: name,
          pubspec: pubspecFixture(
            name,
            publishable: publishable,
            version: resolved,
            constraintVersion: constraints,
            description: description,
          ),
          files: publishable
              ? <String>{'LICENSE', 'README.md', 'CHANGELOG.md'}
              : <String>{},
          overrides: overridesFor(name),
          changelog: released
              ? '# Changelog\n\n## $changelogVersion - 2026-08-14\n\n见根表。\n'
              : null,
        ),
    },
    hostSurfaceGolden: resolvedHostSurface,
    compatibilityCorpus:
        compatibilityCorpus ??
        (released
            ? renderCompatibilityFixtures(resolved, resolvedHostSurface)
            : const <String, String>{}),
    packageVersionSource:
        "const String patchbayPackageVersion = '$resolved';\n",
    readmes: <String, String>{
      ...releaseDocumentsFixture(resolved),
      ...documentOverrides,
    },
    changelog: released
        ? '# Changelog\n\n## $resolved - 2026-08-14\n\n'
              '<!-- PUB_CHANGELOG:START -->\n'
              'Added one fixture feature.\n'
              '<!-- PUB_CHANGELOG:END -->\n\n'
              '### Added\n\n- 某条。\n'
        : '# Changelog\n\n## Unreleased\n\n'
              '<!-- PUB_CHANGELOG:START -->\n'
              'Added one fixture feature.\n'
              '<!-- PUB_CHANGELOG:END -->\n\n'
              '### Added\n\n- 某条。\n',
    examplePubspec:
        'name: patchbay_flutter_example\n'
        'publish_to: none\n'
        '\n'
        'dependencies:\n'
        '  patchbay_flutter:\n'
        '    path: ..\n',
    exampleOverrides: publishable
        ? renderOverrides(<String, String>{'patchbay': exampleOverridePath})
        : null,
    exampleLock:
        '# Generated by pub\n'
        'packages:\n'
        '  patchbay:\n'
        '    dependency: transitive\n'
        '    description:\n'
        '      path: "../../patchbay"\n'
        '      relative: true\n'
        '    source: path\n'
        '    version: "$resolved"\n'
        'sdks:\n'
        '  dart: ">=3.11.0 <4.0.0"\n',
    compatMatrix:
        '# 兼容性矩阵\n\n## 当前记录\n\n'
        '| patchbay tag | commit SHA | wire schemaVersion | Flutter（CI 验证） '
        '| Flutter（文档最低支持） | 已知 consumer |\n'
        '|---|---|---|---|---|---|\n'
        '$newRow'
        '| `patchbay-v0.2.1` | `$fixtureSha` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×2 |\n',
    serviceHost:
        'class ServiceHost {\n  static const int schemaVersion = 1;\n}\n',
    invocation:
        'class Envelope {\n'
        '  static const int schemaVersion = $invocationSchema;\n'
        '}\n',
    workflow: "env:\n  FLUTTER_VERSION: '3.44.9'\n",
  );
}

void materializeInputs(Directory repo, ReleaseInputs inputs) {
  void write(String relative, String? content) {
    final File file = File('${repo.path}/$relative');
    if (content == null) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  for (final MapEntry<String, PackageManifest> entry
      in inputs.packages.entries) {
    write(pubspecPathOf(entry.key), entry.value.pubspec);
    write(overridesPathOf(entry.key), entry.value.overrides);
    write(packageChangelogPathOf(entry.key), entry.value.changelog);
  }
  write(hostSurfaceGoldenPath, inputs.hostSurfaceGolden);
  final Directory corpus = Directory('${repo.path}/$compatibilityCorpusPath');
  if (corpus.existsSync()) corpus.deleteSync(recursive: true);
  for (final MapEntry<String, String> entry
      in inputs.compatibilityCorpus.entries) {
    write('$compatibilityCorpusPath/${entry.key}', entry.value);
  }
  write(changelogPath, inputs.changelog);
  write(packageVersionSourcePath, inputs.packageVersionSource);
  for (final MapEntry<String, String> entry in inputs.readmes.entries) {
    write(entry.key, entry.value);
  }
  write(examplePubspecPath, inputs.examplePubspec);
  write(exampleOverridesPath, inputs.exampleOverrides);
  write(exampleLockPath, inputs.exampleLock);
  write(compatMatrixPath, inputs.compatMatrix);
  write(serviceHostPath, inputs.serviceHost);
  write(invocationPath, inputs.invocation);
  write(workflowPath, inputs.workflow);
  write('changelog.d/README.md', '# CHANGELOG 碎片规范\n');
}

void writeFragment(
  Directory repo,
  String name,
  String content, {
  String version = '0.3.0',
}) {
  final File file = File('${repo.path}/changelog.d/$version/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

Map<String, List<int>> releaseFileBytes(Directory repo) {
  final paths = <String>[
    changelogPath,
    hostSurfaceGoldenPath,
    packageVersionSourcePath,
    ...activePublicDocumentPaths,
    exampleLockPath,
    compatMatrixPath,
    for (final String package in releasePackages) ...<String>[
      pubspecPathOf(package),
      packageChangelogPathOf(package),
    ],
    for (final File file in Directory(
      '${repo.path}/changelog.d',
    ).listSync(recursive: true).whereType<File>())
      file.path.substring(repo.path.length + 1),
    if (Directory('${repo.path}/$compatibilityCorpusPath').existsSync())
      for (final File file in Directory(
        '${repo.path}/$compatibilityCorpusPath',
      ).listSync(recursive: true).whereType<File>())
        file.path.substring(repo.path.length + 1),
  ]..sort();
  return <String, List<int>>{
    for (final String path in paths)
      if (File('${repo.path}/$path').existsSync())
        path: File('${repo.path}/$path').readAsBytesSync(),
  };
}

Future<ProcessResult> execReleasePrepProcess(
  Directory repo,
  String mode, {
  String version = '0.3.0',
  List<String> extra = const <String>[],
}) => Process.run(Platform.resolvedExecutable, <String>[
  'run',
  'tool/release_prep.dart',
  '--version',
  version,
  mode,
  '--date',
  '2026-08-14',
  '--repo-root',
  repo.path,
  '--no-publish-dry-run',
  ...extra,
]);

ReleaseCheck checkOf(List<ReleaseCheck> checks, String id) =>
    checks.firstWhere((check) => check.id == id);

ReleaseCheckStatus statusOf(List<ReleaseCheck> checks, String id) =>
    checkOf(checks, id).status;
