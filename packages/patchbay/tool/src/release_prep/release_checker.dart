// 定版与发布门禁纯数据判定逻辑。

import 'changelog_manager.dart';
import 'compat_matrix_manager.dart';
import 'constants.dart';
import 'lockfile_checker.dart';
import 'models.dart';
import 'package_topology.dart';
import 'pubspec_scanner.dart';

bool isFrozenHistoricalCorpus(ReleaseInputs inputs, String directory) =>
    inputs.compatibilityCorpus['$directory/README.md']?.contains(
      frozenCorpusMarker,
    ) ??
    false;

/// 定版四件套 + 包内 CHANGELOG + pub 发布静态门的全部判定。
List<ReleaseCheck> evaluateRelease({
  required String version,
  required ReleaseInputs inputs,
  required String? Function(String tag) resolveTag,
}) {
  requireVersion(version);
  return <ReleaseCheck>[
    _checkVersionParity(version, inputs),
    _checkVersionReferences(version, inputs),
    _checkDocumentationCurrent(version, inputs),
    _checkCompatibilityFixture(version, inputs),
    _checkSchemaParity(inputs),
    _checkChangelog(version, inputs),
    _checkPackageChangelogs(version, inputs),
    _checkExampleLock(version, inputs),
    _checkCompatRow(version, inputs),
    _checkCompatBackfill(inputs, resolveTag),
    _checkInternalConstraints(version, inputs),
    _checkLocalOverrides(inputs),
    _checkPublishSwitch(inputs),
    ..._checkPublishManifest(inputs),
  ];
}

ReleaseCheck _checkCompatibilityFixture(String version, ReleaseInputs inputs) {
  final String targetDirectory = compatibilityCorpusDirectory(version);
  if (isFrozenHistoricalCorpus(inputs, targetDirectory)) {
    return ReleaseCheck.skipped(
      'protocol-compat-fixture',
      '$targetDirectory/ 已声明冻结（$frozenCorpusMarker）；不会用当前 host 覆写',
      hard: true,
    );
  }
  late final Map<String, String> expected;
  try {
    expected = renderCompatibilityFixtures(version, inputs.hostSurfaceGolden);
  } on FormatException catch (error) {
    return ReleaseCheck.failed(
      'protocol-compat-fixture',
      '无法从 $hostSurfaceGoldenPath 冻结语料：${error.message}',
      hard: true,
    );
  }
  final String directory = '$targetDirectory/';
  final Set<String> present = inputs.compatibilityCorpus.keys
      .where((path) => path.startsWith(directory))
      .toSet();
  final List<String> problems = <String>[
    for (final MapEntry<String, String> entry in expected.entries)
      if (!present.contains(entry.key))
        '${entry.key}=缺失'
      else if (inputs.compatibilityCorpus[entry.key] != entry.value)
        '${entry.key}=漂移',
    for (final String path
        in present.difference(expected.keys.toSet()).toList()..sort())
      '$path=非受管文件',
  ];
  if (problems.isEmpty) {
    return ReleaseCheck.ok(
      'protocol-compat-fixture',
      '$directory 的 identity / catalog 已冻结且与本版协议面一致',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'protocol-compat-fixture',
    '${problems.join('；')}（`--apply` 可原子生成）',
    hard: true,
  );
}

ReleaseCheck _checkVersionReferences(String version, ReleaseInputs inputs) {
  final stale = <String>[];
  try {
    final String expected = applyPackageVersionSource(
      inputs.packageVersionSource,
      version,
    );
    if (expected != inputs.packageVersionSource) {
      stale.add('patchbayPackageVersion');
    }
  } on FormatException catch (error) {
    stale.add('patchbayPackageVersion（${error.message}）');
  }
  for (final String path in releaseVersionDocumentPaths) {
    final String? readme = inputs.readmes[path];
    if (readme == null) {
      stale.add('$path（缺文件）');
      continue;
    }
    try {
      if (applyReleaseDocumentVersionReferences(path, readme, version) !=
          readme) {
        stale.add(path);
      }
    } on FormatException catch (error) {
      stale.add('$path（${error.message}）');
    }
  }
  if (stale.isEmpty) {
    return ReleaseCheck.ok(
      'version-references',
      '`patchbayPackageVersion` 与当前安装文档的受管版本引用均为 $version',
    );
  }
  return ReleaseCheck.failed(
    'version-references',
    '版本引用未同步到 $version：${stale.join('、')}（`--apply` 可代改）',
    hard: true,
  );
}

ReleaseCheck _checkDocumentationCurrent(String version, ReleaseInputs inputs) {
  final problems = <String>[];
  for (final String path in activePublicDocumentPaths) {
    if (!inputs.readmes.containsKey(path)) problems.add('$path（缺文件）');
  }
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'documentation-current',
      '对外当前文档不完整：${problems.join('、')}',
      hard: true,
    );
  }

  const List<String> stageInconsistentPhrases = <String>[
    'not published to pub.dev yet',
    '尚未发布到 pub.dev',
    'will be published to pub.dev',
    '届时发布到 pub.dev',
    'published on pub.dev',
    '已发布到 pub.dev',
  ];
  for (final MapEntry<String, String> entry in inputs.readmes.entries) {
    for (final String phrase in stageInconsistentPhrases) {
      if (entry.value.toLowerCase().contains(phrase.toLowerCase())) {
        problems.add('${entry.key} 含与定版阶段不一致的声明 `$phrase`');
      }
    }
  }

  final RegExp tagReference = RegExp(
    r'patchbay-v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)',
  );
  for (final String path in activePublicDocumentPaths) {
    final String document = inputs.readmes[path]!;
    for (final RegExpMatch match in tagReference.allMatches(document)) {
      if (match.group(1) != version) {
        problems.add('$path 含旧版当前引用 `${match.group(0)}`');
      }
    }
  }

  final RegExp concreteCommand = RegExp(
    r'(?:patchbay(?:\s+--wait)?\s+exec|Host:\s+exec)\s+([a-z0-9][a-z0-9._-]*)',
    caseSensitive: false,
  );
  for (final String path in activePublicDocumentPaths) {
    for (final RegExpMatch match in concreteCommand.allMatches(
      inputs.readmes[path]!,
    )) {
      final String command = match.group(1)!;
      if (!command.startsWith('example.')) {
        problems.add('$path 含非中性命令示例 `$command`');
      }
    }
  }

  final String architecture =
      inputs.readmes['docs/assets/patchbay-architecture.svg']!;
  for (final String marker in <String>[
    'patchbay',
    'patchbay_transport',
    'patchbay_cli',
    'patchbay_flutter',
    'gesture / inspect / wait',
  ]) {
    if (!architecture.contains(marker)) {
      problems.add('架构 SVG 缺能力/包标记 `$marker`');
    }
  }
  if (!inputs.readmes['docs/assets/patchbay-hero.svg']!.contains(
    'patchbay exec example.job.run',
  )) {
    problems.add('首页 SVG 缺中性命令示例 `patchbay exec example.job.run`');
  }

  if (problems.isEmpty) {
    return ReleaseCheck.ok(
      'documentation-current',
      '当前文档无发布阶段假事实和旧安装口径，双语入口、架构 SVG 与中性示例已纳入门禁',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'documentation-current',
    problems.join('；'),
    hard: true,
  );
}

ReleaseCheck _checkVersionParity(String version, ReleaseInputs inputs) {
  final stale = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) {
      stale.add('$name=缺 pubspec');
      continue;
    }
    final String? actual = readPubspecVersion(manifest.pubspec);
    if (actual != version) stale.add('$name=${actual ?? '缺 version 字段'}');
  }
  if (stale.isEmpty) {
    return ReleaseCheck.ok('version-parity', '四包 version 均为 $version');
  }
  return ReleaseCheck.failed(
    'version-parity',
    '未 bump 到 $version：${stale.join('、')}（`--apply` 可代改）',
  );
}

ReleaseCheck _checkSchemaParity(ReleaseInputs inputs) {
  final int? host = readSchemaVersion(inputs.serviceHost);
  final int? invocation = readSchemaVersion(inputs.invocation);
  if (host == null || invocation == null) {
    return const ReleaseCheck.failed(
      'schema-version-parity',
      '读不到 schemaVersion 常量（service_host.dart / invocation.dart）',
    );
  }
  if (host != invocation) {
    return ReleaseCheck.failed(
      'schema-version-parity',
      'schemaVersion 两处不一致：service_host=$host、invocation=$invocation；'
          '握手会在运行时拒绝，必须先对齐',
    );
  }
  return ReleaseCheck.ok('schema-version-parity', '两处 schemaVersion 同为 $host');
}

ReleaseCheck _checkChangelog(String version, ReleaseInputs inputs) {
  final ChangelogState state = readChangelogState(inputs.changelog, version);
  if (state.released && state.hasUnreleased) {
    return ReleaseCheck.failed(
      'changelog-release',
      '已有 `## $version` 段但仍残留 `## Unreleased` 段；两段内容归属需人工裁定',
    );
  }
  if (state.released && !state.releaseIsNewest) {
    return ReleaseCheck.failed(
      'changelog-release',
      '`## $version` 段不在最前；本表新版本在上',
    );
  }
  if (state.released) {
    return ReleaseCheck.ok(
      'changelog-release',
      '已落款 `## $version - ${state.releaseDate}`',
    );
  }
  if (state.hasUnreleased) {
    return ReleaseCheck.failed(
      'changelog-release',
      '`## Unreleased` 尚未落款成 `## $version - <日期>`（`--apply` 可代改）',
    );
  }
  return ReleaseCheck.failed(
    'changelog-release',
    'CHANGELOG 既无 `## Unreleased` 段也无 `## $version` 段，脚本不代造段落',
  );
}

ReleaseCheck _checkPackageChangelogs(String version, ReleaseInputs inputs) {
  final missing = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) continue;
    if (!packageChangelogMentions(manifest.changelog, version)) {
      missing.add(
        manifest.changelog == null ? '$name 无文件' : '$name 未记 $version',
      );
    }
  }
  if (missing.isEmpty) {
    return ReleaseCheck.ok(
      'package-changelog',
      '四包 CHANGELOG.md 均已记到 $version',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'package-changelog',
    '${missing.join('、')}——pub 校验「CHANGELOG 有没有提当前版本」，没提是 warning，'
        '`--dry-run` 会退 65（`--apply` 可代补）',
    hard: true,
  );
}

ReleaseCheck _checkExampleLock(String version, ReleaseInputs inputs) {
  final Map<String, String> locked = readLockPathVersions(inputs.exampleLock);
  if (locked.isEmpty) {
    return const ReleaseCheck.failed(
      'example-lock',
      '$exampleLockPath 里找不到 path 源的随版包条目',
      hard: true,
    );
  }
  final List<String> stale =
      locked.entries
          .where((entry) => entry.value != version)
          .map((entry) => '${entry.key}=${entry.value}')
          .toList(growable: false)
        ..sort();
  if (stale.isEmpty) {
    return ReleaseCheck.ok(
      'example-lock',
      '$exampleLockPath 已跟到 $version（${locked.keys.join('、')}）',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'example-lock',
    '$exampleLockPath 仍停在 ${stale.join('、')}——0.2.0 定版漏的就是这一项'
        '（`--apply` 可代刷）',
    hard: true,
  );
}

ReleaseCheck _checkCompatRow(String version, ReleaseInputs inputs) {
  final String tag = '$tagPrefix$version';
  final List<CompatRow> rows = parseCompatRows(inputs.compatMatrix);
  CompatRow? target;
  for (final CompatRow row in rows) {
    if (row.tag == tag) target = row;
  }
  if (target == null) {
    return ReleaseCheck.failed(
      'compat-matrix-row',
      '$compatMatrixPath 缺 `$tag` 行——0.2.1 定版漏的就是这一项'
          '（`--apply` 按源码现值生成占位行）',
      hard: true,
    );
  }
  final CompatRow expected = buildCompatRow(version, inputs);
  final drift = <String>[];
  if (target.schemaVersion != expected.schemaVersion) {
    drift.add(
      'schemaVersion 记 ${target.schemaVersion}、源码 ${expected.schemaVersion}',
    );
  }
  if (target.flutterCi != expected.flutterCi) {
    drift.add(
      'Flutter(CI) 记 ${target.flutterCi}、$workflowPath ${expected.flutterCi}',
    );
  }
  if (target.flutterMin != expected.flutterMin) {
    drift.add(
      'Flutter(最低) 记 ${target.flutterMin}、pubspec ${expected.flutterMin}',
    );
  }
  if (rows.isNotEmpty && rows.first.tag != tag) {
    drift.add('`$tag` 行不在表顶（本表新 tag 在上）');
  }
  if (drift.isNotEmpty) {
    return ReleaseCheck.failed(
      'compat-matrix-row',
      '`$tag` 行与源码不符：${drift.join('；')}（脚本不覆盖既有行，请人工修正）',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'compat-matrix-row',
    '`$tag` 行在表顶，schemaVersion / Flutter 三列与源码一致',
    hard: true,
  );
}

ReleaseCheck _checkCompatBackfill(
  ReleaseInputs inputs,
  String? Function(String tag) resolveTag,
) {
  final List<CompatRow> rows = parseCompatRows(inputs.compatMatrix);
  final problems = <String>[];
  final checked = <String>[];
  final unresolved = <String>[];
  for (final CompatRow row in rows) {
    final String? sha = resolveTag(row.tag);
    if (sha == null) {
      unresolved.add(row.tag);
      continue;
    }
    checked.add(row.tag);
    if (row.hasPending) {
      problems.add(
        '`${row.tag}` 已打 tag 但仍有占位符（SHA=${row.commitSha}、consumer=${row.consumers}）',
      );
      continue;
    }
    if (row.commitSha != sha) {
      problems.add('`${row.tag}` 记 ${row.commitSha}、实际 peeled SHA $sha');
    }
  }
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'compat-matrix-backfill',
      '${problems.join('；')}——0.2.1 打完 tag 漏的就是这一步',
      hard: true,
    );
  }
  if (checked.isEmpty) {
    return const ReleaseCheck.skipped(
      'compat-matrix-backfill',
      '没有可解析的 tag（浅克隆或 tag 未拉取），跳过回填核对',
      hard: true,
    );
  }
  final String pending = unresolved.isEmpty
      ? ''
      : '；未打 tag 的行留占位符：${unresolved.join('、')}';
  return ReleaseCheck.ok(
    'compat-matrix-backfill',
    '已打 tag 的 ${checked.length} 行 SHA 与 peeled tag 一致$pending',
    hard: true,
  );
}

ReleaseCheck _checkInternalConstraints(String version, ReleaseInputs inputs) {
  final Version target = Version.tryParse(version)!;
  final problems = <String>[];
  final pathStyle = <String>[];
  var checked = 0;
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) continue;
    final Set<String> asPath = readPathDependencies(
      manifest.pubspec,
    ).where(releasePackages.contains).toSet();
    for (final String dep in asPath.toList()..sort()) {
      pathStyle.add('$name→$dep');
    }
    readInternalConstraints(manifest.pubspec).forEach((dep, constraint) {
      checked += 1;
      final bool? admits = caretAdmits(constraint, target);
      if (admits == null) {
        problems.add('$name 的 $dep 约束 `$constraint` 不是 `^X.Y.Z`，需人工判断');
      } else if (!admits) {
        problems.add('$name 的 $dep 约束 `$constraint` 不接纳 $version');
      }
    });
  }
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'internal-dep-constraints',
      '${problems.join('；')}（`--apply` 可把 caret 约束改写成 `^$version`）',
      hard: true,
    );
  }
  if (pathStyle.isNotEmpty) {
    return ReleaseCheck.skipped(
      'internal-dep-constraints',
      '还有 path 形式的随版依赖，先看 publish-manifest：${pathStyle.join('、')}',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'internal-dep-constraints',
    '$checked 条随版依赖约束均接纳 $version',
    hard: true,
  );
}

ReleaseCheck _checkLocalOverrides(ReleaseInputs inputs) {
  final Map<String, Map<String, String>> expected = expectedOverrides(inputs);
  final Map<String, String?> actual = <String, String?>{
    for (final MapEntry<String, PackageManifest> entry
        in inputs.packages.entries)
      overridesPathOf(entry.key): entry.value.overrides,
    exampleOverridesPath: inputs.exampleOverrides,
  };
  final problems = <String>[];
  expected.forEach((path, wanted) {
    final Map<String, String> present = readPathOverrides(actual[path]);
    final List<String> diff = <String>[];
    wanted.forEach((dep, wantedPath) {
      final String? got = present[dep];
      if (got == null) {
        diff.add('缺 $dep');
      } else if (got != wantedPath) {
        diff.add('$dep 指向 $got、应为 $wantedPath');
      }
    });
    if (diff.isNotEmpty) problems.add('$path：${diff.join('、')}');
  });
  if (problems.isNotEmpty) {
    return ReleaseCheck.failed(
      'local-overrides',
      '${problems.join('；')}——少一条，仓内开发就会从 pub.dev 拉那个包，'
          '工作树里的改动测不到（`--apply` 可代生成）',
      hard: true,
    );
  }
  if (expected.isEmpty) {
    return const ReleaseCheck.skipped(
      'local-overrides',
      '没有需要 override 的随版依赖',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'local-overrides',
    '${expected.length} 处 pubspec_overrides.yaml 指向工作树',
    hard: true,
  );
}

ReleaseCheck _checkPublishSwitch(ReleaseInputs inputs) {
  final List<String> blocked = releasePackages
      .where(
        (name) =>
            readPubspecField(
              inputs.packages[name]?.pubspec ?? '',
              'publish_to',
            ) ==
            'none',
      )
      .toList(growable: false);
  if (blocked.isEmpty) {
    return const ReleaseCheck.ok(
      'publish-switch',
      '四包均未带 `publish_to: none`',
      hard: true,
    );
  }
  return ReleaseCheck.failed(
    'publish-switch',
    '${blocked.join('、')} 仍带 `publish_to: none`，pub 会直接拒收。'
        '开发布开关是仓主的决定：确认要发时跑 `--apply --enable-publish`（默认不动这一行）',
    hard: true,
  );
}

List<ReleaseCheck> _checkPublishManifest(ReleaseInputs inputs) {
  final blockers = <String>[];
  final advisories = <String>[];
  for (final String name in releasePackages) {
    final PackageManifest? manifest = inputs.packages[name];
    if (manifest == null) {
      blockers.add('$name 缺 pubspec');
      continue;
    }
    final String? description = readPubspecField(
      manifest.pubspec,
      'description',
    );
    if (description == null) {
      blockers.add('$name 缺 description');
    } else if (description.length < descriptionMinLength ||
        description.length > descriptionMaxLength) {
      advisories.add(
        '$name 的 description 长 ${description.length} 字符，'
        'pub 要求 $descriptionMinLength–$descriptionMaxLength',
      );
    }
    final Set<String> pathDeps = readPathDependencies(manifest.pubspec);
    if (pathDeps.isNotEmpty) {
      final List<String> sorted = pathDeps.toList()..sort();
      blockers.add('$name 的 ${sorted.join('/')} 还是 path 依赖（发布拒收）');
    }
    for (final String file in requiredPackageFiles) {
      if (!manifest.files.contains(file)) blockers.add('$name 缺 $file');
    }
    for (final String file in advisedPackageFiles) {
      if (!manifest.files.contains(file)) advisories.add('$name 缺 $file');
    }
    if (readPubspecField(manifest.pubspec, 'repository') == null &&
        readPubspecField(manifest.pubspec, 'homepage') == null) {
      advisories.add('$name 缺 repository/homepage');
    }
  }
  return <ReleaseCheck>[
    if (blockers.isEmpty)
      const ReleaseCheck.ok('publish-manifest', '四包已具备 pub 发布形态', hard: true)
    else
      ReleaseCheck.failed(
        'publish-manifest',
        '${blockers.join('；')}。这些是 `dart pub publish` 的 error 级项',
        hard: true,
      ),
    if (advisories.isEmpty)
      const ReleaseCheck.ok(
        'publish-advisories',
        'README / CHANGELOG / repository / description 长度齐备',
        hard: true,
      )
    else
      ReleaseCheck.failed(
        'publish-advisories',
        '${advisories.join('；')}。pub 记 warning，而 `--dry-run` 有 warning 即退 65，'
            '照样挡发布',
        hard: true,
      ),
  ];
}

ReleaseCheck evaluateFormatGate(int? exitCode) {
  if (exitCode == null) {
    return const ReleaseCheck.skipped('format-gate', '未跑排版检查', hard: true);
  }
  if (exitCode != 0) {
    return const ReleaseCheck.failed(
      'format-gate',
      '`dart format --output=none --set-exit-if-changed .` 有漂移；'
          '跑 `dart format .` 后重提',
      hard: true,
    );
  }
  return const ReleaseCheck.ok(
    'format-gate',
    '全仓排版与 dart_style 对齐',
    hard: true,
  );
}

ReleaseCheck evaluatePublishDryRun({
  required Map<String, int> exitCodes,
  required List<String> skipped,
}) {
  final List<String> failed =
      exitCodes.entries
          .where((entry) => entry.value != 0)
          .map((entry) => '${entry.key}(exit=${entry.value})')
          .toList()
        ..sort();
  if (failed.isNotEmpty) {
    return ReleaseCheck.failed(
      'publish-dry-run',
      '`dart pub publish --dry-run` 未过：${failed.join('、')}；'
          '进包目录重跑一遍看 pub 原文（warning 也会退 65）',
      hard: true,
    );
  }
  if (exitCodes.isEmpty) {
    final List<String> sorted = skipped.toList()..sort();
    return ReleaseCheck.skipped(
      'publish-dry-run',
      sorted.isEmpty
          ? '按 `--no-publish-dry-run` 跳过'
          : '发布开关未开或静态门未过（见 publish-switch / publish-manifest），'
                'dry-run 无从跑起：${sorted.join('、')}',
      hard: true,
    );
  }
  return ReleaseCheck.ok(
    'publish-dry-run',
    '${exitCodes.length} 个包 `dart pub publish --dry-run` 通过',
    hard: true,
  );
}
