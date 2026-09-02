// release_prep CLI 入口、磁盘读写与主执行编排。

import 'dart:io';

import 'changelog_manager.dart';
import 'compat_matrix_manager.dart';
import 'constants.dart';
import 'lockfile_checker.dart';
import 'models.dart';
import 'package_topology.dart';
import 'pubspec_scanner.dart';
import 'release_checker.dart';

List<String> manualSteps(String version, ReleaseInputs inputs) {
  final String tag = '$tagPrefix$version';
  return <String>[
    '给 CHANGELOG 的 `## $version` 段补一句批次摘要（体例见 0.2.1 段）。',
    '门禁全绿后按 CONTRIBUTING.md「发版」顺序走：发布 MR 合回 main → 同步同一 SHA 到 GitHub → 再打 tag。',
    '打 tag（origin 已配双推，一条命令同时到 GitLab 与 GitHub）：\n'
        '      git tag -a $tag -m \'patchbay $version\'\n'
        '      git push origin $tag',
    '核对双端同 tag 同 commit：\n'
        '      git ls-remote --tags origin $tag\n'
        '      git ls-remote --tags github $tag',
    '回填兼容矩阵 `$tag` 行的两个占位符：\n'
        '      git rev-parse $tag^{}   # 填 commit SHA 列（annotated tag 必须 peeled）\n'
        '      「已知 consumer」列的 `$pendingConsumers` 换成向 consumer 仓核实后的口径',
    '回填后重跑本脚本确认转绿：\n'
        '      dart run tool/repo_tasks.dart release --version $version --check',
    '复核 example lock 与真实解析一致（脚本只改版本格子，不跑 pub）：\n'
        '      (cd $examplePath && flutter pub get)\n'
        '      git diff --exit-code $exampleLockPath',
    '开发布开关（仓主决定，一次性）：四包的 `publish_to: none` 不删，pub 直接拒收，'
        'dry-run 也跑不起来。确认 $version 对外发布后：\n'
        '      dart run tool/repo_tasks.dart release --version $version --apply --enable-publish\n'
        '      # 等价于人工删掉四包 pubspec 的 `publish_to: none` 一行',
    'pub points 是发布硬门：用 pub.dev 当前版本的 Pana 对待发布包评分，必须满分才继续；'
        '按依赖顺序逐包发布并等待上游版本可解析，再复算下游。每包发布后还要核对 pub.dev Scores API '
        '的 `grantedPoints == maxPoints`。命令、停止条件与例外口径见 docs/release-checklist.md。',
    '按发布顺序逐包发布（凭据由人提供；显式指定 host，本机 `PUB_HOSTED_URL` 常指向镜像）：\n'
        '${publishOrderOf(inputs).map((name) => '      (cd packages/$name && PUB_HOSTED_URL=$canonicalPubHost dart pub publish)').join('\n')}',
    'consumer 换 pin：git pin 的接入方不能只改 tag。四包改成 hosted 约束后，'
        '「patchbay_flutter 从 git、patchbay 也从 git」会被 pub 判成 source 冲突，'
        '接入方要么整体改用 pub.dev 版本，要么在自己仓加 `dependency_overrides` 把四包统一指回 git。'
        '口径见 docs/release-checklist.md。',
    '在打 tag 前确认 `documentation-current` 已绿；当前安装口径、双语入口与 SVG 不留到发布后补。',
    '真机验收：见 docs/release-checklist.md 对应一节。',
  ];
}

const String _usage = '''
用法：
  dart run tool/repo_tasks.dart release --version <SemVer> (--check|--apply)

可选：
  --date YYYY-MM-DD        CHANGELOG 落款日期，默认今天
  --repo-root <path>       仓根，默认从当前目录向上找
  --no-publish-dry-run     跳过 `dart pub publish --dry-run`（离线时用）
  --enable-publish         仅配合 --apply：删掉四包的 `publish_to: none`。
                           这是「对外发布」的开关，默认不动，由仓主显式点。
''';

final class Options {
  const Options({
    required this.version,
    required this.apply,
    required this.date,
    required this.repoRoot,
    required this.publishDryRun,
    required this.enablePublish,
  });

  final String version;
  final bool apply;
  final String date;
  final String repoRoot;
  final bool publishDryRun;
  final bool enablePublish;

  static Options parse(List<String> arguments) {
    String? version;
    String? date;
    String? repoRoot;
    var check = false;
    var apply = false;
    var publishDryRun = true;
    var enablePublish = false;
    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--version':
          version = arguments.elementAtOrNull(++index);
        case '--date':
          date = arguments.elementAtOrNull(++index);
        case '--repo-root':
          repoRoot = arguments.elementAtOrNull(++index);
        case '--check':
          check = true;
        case '--apply':
          apply = true;
        case '--no-publish-dry-run':
          publishDryRun = false;
        case '--enable-publish':
          enablePublish = true;
        case '--help' || '-h':
          stdout.write(_usage);
          exit(0);
        default:
          throw FormatException('未知参数 ${arguments[index]}\n$_usage');
      }
    }
    if (version == null || check == apply) {
      throw const FormatException(
        '缺 --version，或 --check/--apply 未二选一\n$_usage',
      );
    }
    if (enablePublish && !apply) {
      throw const FormatException('--enable-publish 只能配合 --apply（check 不改文件）');
    }
    requireVersion(version);
    if (date != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw FormatException('--date 必须是 YYYY-MM-DD：$date');
    }
    return Options(
      version: version,
      apply: apply,
      date: date ?? _today(),
      repoRoot: repoRoot ?? _findRepoRoot(),
      publishDryRun: publishDryRun,
      enablePublish: enablePublish,
    );
  }
}

String _today() {
  final DateTime now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String _findRepoRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/$changelogPath').existsSync() &&
        File('${directory.path}/${pubspecPathOf('patchbay')}').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw const FormatException(
        '找不到仓根（向上没看到 CHANGELOG.md + packages/patchbay）',
      );
    }
    directory = parent;
  }
}

ReleaseInputs readReleaseInputsFromDisk(String root) {
  String read(String relative) {
    final File file = File('$root/$relative');
    if (!file.existsSync()) throw FormatException('缺文件：$relative');
    return file.readAsStringSync();
  }

  String? readOptional(String relative) {
    final File file = File('$root/$relative');
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Map<String, String> readCompatibilityCorpus() {
    final Directory directory = Directory('$root/$compatibilityCorpusPath');
    if (!directory.existsSync()) return const <String, String>{};
    return <String, String>{
      for (final File file
          in directory.listSync(recursive: true).whereType<File>())
        file.path.substring(directory.path.length + 1): file.readAsStringSync(),
    };
  }

  return ReleaseInputs(
    packages: <String, PackageManifest>{
      for (final String name in releasePackages)
        name: PackageManifest(
          name: name,
          pubspec: read(pubspecPathOf(name)),
          files: Directory('$root/packages/$name')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .toSet(),
          overrides: readOptional(overridesPathOf(name)),
          changelog: readOptional(packageChangelogPathOf(name)),
        ),
    },
    hostSurfaceGolden: read(hostSurfaceGoldenPath),
    compatibilityCorpus: readCompatibilityCorpus(),
    packageVersionSource: read(packageVersionSourcePath),
    readmes: <String, String>{
      for (final String path in activePublicDocumentPaths) path: read(path),
    },
    changelog: read(changelogPath),
    examplePubspec: read(examplePubspecPath),
    exampleOverrides: readOptional(exampleOverridesPath),
    exampleLock: read(exampleLockPath),
    compatMatrix: read(compatMatrixPath),
    serviceHost: read(serviceHostPath),
    invocation: read(invocationPath),
    workflow: read(workflowPath),
  );
}

String? _gitPeeledSha(String root, String tag) {
  try {
    final ProcessResult result = Process.runSync('git', <String>[
      '-C',
      root,
      'rev-parse',
      '--verify',
      '--quiet',
      '$tag^{commit}',
    ]);
    if (result.exitCode != 0) return null;
    final String out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on ProcessException {
    return null;
  }
}

void applyReleaseToDisk(String root, Options options) {
  final FragmentScan fragmentScan = readChangelogFragments(
    root,
    options.version,
  );
  if (fragmentScan.errors.isNotEmpty) {
    throw FormatException('CHANGELOG 碎片校验失败：${fragmentScan.errors.join('；')}');
  }
  final ReleaseInputs inputs = readReleaseInputsFromDisk(root);
  final writes = <String, String>{};

  void stage(String relative, String? before, String after) {
    if (before != after) writes[relative] = after;
  }

  final String aggregated = aggregateChangelogFragments(
    inputs.changelog,
    fragmentScan.fragments,
  );
  final String rootChangelog = applyChangelogRelease(
    aggregated,
    options.version,
    options.date,
  );
  stage(changelogPath, inputs.changelog, rootChangelog);

  final Map<String, String> compatibilityFixtures = <String, String>{
    ...renderCompatibilityFixtures(options.version, inputs.hostSurfaceGolden),
  };
  final String targetCorpusDirectory = compatibilityCorpusDirectory(
    options.version,
  );
  if (renderCompatibilityCorpusReadme(options.version)
      case final String readme) {
    compatibilityFixtures['$targetCorpusDirectory/README.md'] = readme;
  }
  if (isFrozenHistoricalCorpus(inputs, targetCorpusDirectory)) {
    final String corpusDirectory = '$targetCorpusDirectory/';
    final Set<String> present = inputs.compatibilityCorpus.keys
        .where((path) => path.startsWith(corpusDirectory))
        .toSet();
    final bool unchanged =
        present.length == compatibilityFixtures.length &&
        compatibilityFixtures.entries.every(
          (entry) => inputs.compatibilityCorpus[entry.key] == entry.value,
        );
    if (!unchanged) {
      throw FormatException(
        '$targetCorpusDirectory/ 已声明冻结（$frozenCorpusMarker），'
        '内容或目录形状不一致，拒绝用当前 host 覆写',
      );
    }
  }
  for (final MapEntry<String, String> entry in compatibilityFixtures.entries) {
    final String relative = '$compatibilityCorpusPath/${entry.key}';
    stage(relative, inputs.compatibilityCorpus[entry.key], entry.value);
  }
  final String corpusDirectory = '$targetCorpusDirectory/';
  final List<String> obsoleteFixturePaths = inputs.compatibilityCorpus.keys
      .where(
        (path) =>
            path.startsWith(corpusDirectory) &&
            !compatibilityFixtures.containsKey(path),
      )
      .map((path) => '$compatibilityCorpusPath/$path')
      .toList(growable: false);

  stage(
    packageVersionSourcePath,
    inputs.packageVersionSource,
    applyPackageVersionSource(inputs.packageVersionSource, options.version),
  );
  for (final String path in releaseVersionDocumentPaths) {
    final String before = inputs.readmes[path]!;
    stage(
      path,
      before,
      applyReleaseDocumentVersionReferences(path, before, options.version),
    );
  }

  for (final String name in releasePackages) {
    final PackageManifest manifest = inputs.packages[name]!;
    var pubspec = applyInternalConstraints(
      applyPubspecVersion(manifest.pubspec, options.version),
      options.version,
    );
    if (options.enablePublish) pubspec = applyRemovePublishTo(pubspec);
    stage(pubspecPathOf(name), manifest.pubspec, pubspec);
    stage(
      packageChangelogPathOf(name),
      manifest.changelog,
      derivePackageChangelog(rootChangelog),
    );
  }
  expectedOverrides(inputs).forEach((path, paths) {
    final String? before = path == exampleOverridesPath
        ? inputs.exampleOverrides
        : inputs.packages[path.split('/')[1]]?.overrides;
    final String after = renderOverrides(paths);
    final Map<String, String> present = readPathOverrides(before);
    final bool satisfied = paths.entries.every(
      (entry) => present[entry.key] == entry.value,
    );
    if (!satisfied) stage(path, before, after);
  });
  stage(
    exampleLockPath,
    inputs.exampleLock,
    applyLockVersions(inputs.exampleLock, options.version),
  );
  stage(
    compatMatrixPath,
    inputs.compatMatrix,
    applyCompatMatrixRow(
      inputs.compatMatrix,
      buildCompatRow(options.version, inputs),
    ),
  );

  final List<String> fragmentPaths = fragmentScan.fragmentPaths;
  final Set<String> transactionPaths = <String>{
    ...writes.keys,
    ...fragmentPaths,
    ...obsoleteFixturePaths,
  };
  final snapshots = <String, List<int>?>{
    for (final String relative in transactionPaths)
      relative: File('$root/$relative').existsSync()
          ? File('$root/$relative').readAsBytesSync()
          : null,
  };

  try {
    for (final MapEntry<String, String> entry in writes.entries) {
      final File file = File('$root/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value, flush: true);
    }
    for (final String relative in fragmentPaths) {
      File('$root/$relative').deleteSync();
    }
    for (final String relative in obsoleteFixturePaths) {
      File('$root/$relative').deleteSync();
    }
  } on Object catch (error) {
    final rollbackErrors = <String>[];
    for (final String relative in transactionPaths.toList().reversed) {
      final File file = File('$root/$relative');
      try {
        final List<int>? before = snapshots[relative];
        if (before == null) {
          if (file.existsSync()) file.deleteSync();
        } else {
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(before, flush: true);
        }
      } on Object catch (rollbackError) {
        rollbackErrors.add('$relative: $rollbackError');
      }
    }
    throw FormatException(
      'apply 写入失败，已回滚：$error'
      '${rollbackErrors.isEmpty ? '' : '；回滚异常：${rollbackErrors.join('；')}'}',
    );
  }

  final List<String> changed = <String>[
    ...writes.keys,
    ...fragmentPaths.map((path) => '$path（已消费删除）'),
    ...obsoleteFixturePaths.map((path) => '$path（已删除漂移文件）'),
  ];

  stdout
    ..writeln(
      changed.isEmpty ? 'apply：无改动（已是目标状态）' : 'apply：改了 ${changed.length} 个文件',
    )
    ..writeAll(changed.map((path) => '  - $path\n'))
    ..writeln();
}

ReleaseCheck _formatGate(String root) {
  try {
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['format', '--output=none', '--set-exit-if-changed', '.'],
      workingDirectory: root,
    );
    return evaluateFormatGate(result.exitCode);
  } on ProcessException {
    return evaluateFormatGate(null);
  }
}

ReleaseCheck _publishDryRun(
  String root, {
  required bool enabled,
  required bool ready,
}) {
  if (!enabled) {
    return evaluatePublishDryRun(
      exitCodes: const <String, int>{},
      skipped: const <String>[],
    );
  }
  if (!ready) {
    return evaluatePublishDryRun(
      exitCodes: const <String, int>{},
      skipped: releasePackages,
    );
  }
  final exitCodes = <String, int>{};
  for (final String name in releasePackages) {
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['pub', 'publish', '--dry-run'],
      workingDirectory: '$root/packages/$name',
    );
    exitCodes[name] = result.exitCode;
  }
  return evaluatePublishDryRun(exitCodes: exitCodes, skipped: const <String>[]);
}

void runReleasePrep(List<String> arguments) {
  final Options options = Options.parse(arguments);
  final String root = options.repoRoot;
  String? resolveTag(String tag) => _gitPeeledSha(root, tag);

  if (options.apply) {
    applyReleaseToDisk(root, options);
  }

  final FragmentScan fragmentScan = readChangelogFragments(
    root,
    options.version,
  );
  final ReleaseInputs inputs = readReleaseInputsFromDisk(root);
  final List<ReleaseCheck> checks = evaluateRelease(
    version: options.version,
    inputs: inputs,
    resolveTag: resolveTag,
  );
  bool green(String id) =>
      checks.any((check) => check.id == id && !check.failed);
  final ReleaseCheck dryRun = _publishDryRun(
    root,
    enabled: options.publishDryRun,
    ready: green('publish-switch') && green('publish-manifest'),
  );
  final List<ReleaseCheck> all = <ReleaseCheck>[
    checkChangelogFragments(fragmentScan),
    ...checks,
    _formatGate(root),
    dryRun,
  ];

  stdout
    ..writeln(
      '定版核对：patchbay ${options.version}（tag $tagPrefix${options.version}）',
    )
    ..writeln(
      '模式：${options.apply ? 'apply（已改文件，未打 tag、未推送、未发布）' : 'check（只读）'}',
    )
    ..writeln();
  for (final ReleaseCheck check in all) {
    stdout.writeln(
      '  [${check.marker}] ${check.id.padRight(24)}'
      '${check.hard ? '（硬）' : '　　　'} ${check.detail}',
    );
  }

  stdout
    ..writeln()
    ..writeln('发布顺序（按包间依赖推导）：${publishOrderOf(inputs).join(' → ')}')
    ..writeln()
    ..writeln('人工项——脚本不打 tag、不推送、不代发布：');
  final List<String> steps = manualSteps(options.version, inputs);
  for (var index = 0; index < steps.length; index += 1) {
    stdout.writeln('  ${index + 1}. ${steps[index]}');
  }

  final String? host = Platform.environment['PUB_HOSTED_URL'];
  if (host != null && host.isNotEmpty && host != canonicalPubHost) {
    stdout.writeln(
      '\n注意：本机 PUB_HOSTED_URL=$host（镜像）。dry-run 与 publish 都会走它，'
      '正式发布请按上面命令显式指定 $canonicalPubHost。',
    );
  }

  final int failures = all.where((check) => check.failed).length;
  stdout
    ..writeln()
    ..writeln(
      failures == 0 ? '结论：机检项全绿，剩下的是上面的人工项。' : '结论：$failures 项未过，见上方 [未过]。',
    );
  if (failures > 0) exitCode = 1;
}

void main(List<String> arguments) {
  try {
    runReleasePrep(arguments);
  } on FormatException catch (error) {
    stderr.writeln('release_prep：${error.message}');
    exitCode = 64;
  }
}

extension<T> on List<T> {
  T? elementAtOrNull(int index) =>
      index >= 0 && index < length ? this[index] : null;
}
