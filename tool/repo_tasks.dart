// Patchbay 仓库任务的单一真源。
//
// GitLab、GitHub Actions 与本地开发都只选择这里的任务；包清单从根
// pub workspace 读取，避免三处各自维护一份包循环。
import 'dart:io';

final class RepoPackage {
  const RepoPackage({
    required this.name,
    required this.path,
    required this.publishTo,
    required this.resolution,
    required this.usesFlutter,
  });

  final String name;
  final String path;
  final String? publishTo;
  final String? resolution;
  final bool usesFlutter;
}

final class RepoWorkspace {
  const RepoWorkspace({required this.rootPackage, required this.members});

  final RepoPackage rootPackage;
  final List<RepoPackage> members;

  static RepoWorkspace discover(String root) {
    final File rootPubspec = File('$root/pubspec.yaml');
    if (!rootPubspec.existsSync()) {
      throw const FormatException('仓根缺 pubspec.yaml');
    }
    final String yaml = rootPubspec.readAsStringSync();
    final RepoPackage rootPackage = _readPackage(yaml, '.');
    final List<String> memberPaths = _readWorkspacePaths(yaml);
    if (memberPaths.isEmpty) {
      throw const FormatException('根 pubspec.yaml 的 workspace 不能为空');
    }

    final members = <RepoPackage>[];
    for (final String relative in memberPaths) {
      if (relative.startsWith('/') || relative.split('/').contains('..')) {
        throw FormatException('workspace 成员必须是仓内相对路径：$relative');
      }
      final File pubspec = File('$root/$relative/pubspec.yaml');
      if (!pubspec.existsSync()) {
        throw FormatException('workspace 成员缺 pubspec.yaml：$relative');
      }
      members.add(_readPackage(pubspec.readAsStringSync(), relative));
    }
    return RepoWorkspace(rootPackage: rootPackage, members: members);
  }

  static RepoPackage _readPackage(String yaml, String path) => RepoPackage(
    name:
        _readTopLevelScalar(yaml, 'name') ??
        (throw FormatException('$path/pubspec.yaml 缺 name')),
    path: path,
    publishTo: _readTopLevelScalar(yaml, 'publish_to'),
    resolution: _readTopLevelScalar(yaml, 'resolution'),
    usesFlutter: _topLevelBlock(
      yaml,
      'environment',
    ).any((line) => RegExp(r'^  flutter:').hasMatch(line)),
  );
}

final class RepoCommand {
  const RepoCommand(
    this.executable,
    this.arguments, {
    this.workingDirectory = '.',
    this.environment = const <String, String>{},
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;

  String get display {
    final String command = <String>[executable, ...arguments].join(' ');
    return workingDirectory == '.'
        ? command
        : '(cd $workingDirectory && $command)';
  }
}

final class CoverageReport {
  const CoverageReport({
    required this.name,
    required this.workingDirectory,
    required this.usesFlutter,
    required this.requiresRawJson,
  });

  final String name;
  final String workingDirectory;
  final bool usesFlutter;
  final bool requiresRawJson;

  String get outputDirectory {
    if (workingDirectory == '.') return 'coverage/$name';
    final int depth = workingDirectory
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .length;
    return '${List<String>.filled(depth, '..').join('/')}/coverage/$name';
  }

  String get rootRelativeDirectory => 'coverage/$name';
}

List<CoverageReport> coverageReportsFor(RepoWorkspace workspace) =>
    <CoverageReport>[
      for (final RepoPackage package in workspace.members)
        CoverageReport(
          name: package.name,
          workingDirectory: package.path,
          usesFlutter: package.usesFlutter,
          requiresRawJson: !package.usesFlutter,
        ),
      const CoverageReport(
        name: 'patchbay_flutter_example',
        workingDirectory: 'packages/patchbay_flutter/example',
        usesFlutter: true,
        requiresRawJson: false,
      ),
    ];

final class RepoTaskCatalog {
  RepoTaskCatalog(this.workspace, {Map<String, String>? environment})
    : environment = environment ?? Platform.environment;

  final RepoWorkspace workspace;
  final Map<String, String> environment;

  static const List<String> taskNames = <String>[
    'dart-packages',
    'flutter-package',
    'codegen-drift',
    'coverage',
    'sdk-floor',
    'check',
    'release',
  ];

  List<RepoPackage> get _dartPackages => <RepoPackage>[
    workspace.rootPackage,
    ...workspace.members.where((member) => !member.usesFlutter),
  ];

  List<RepoPackage> get _flutterPackages => workspace.members
      .where((member) => member.usesFlutter)
      .toList(growable: false);

  List<RepoCommand> commandsFor(
    String task, {
    List<String> taskArguments = const <String>[],
  }) => switch (task) {
    'dart-packages' => _dartPackageCommands(includeRepositoryChecks: true),
    'flutter-package' => _flutterPackageCommands(),
    'codegen-drift' => _codegenCommands(),
    'coverage' => _coverageCommands(),
    'sdk-floor' => <RepoCommand>[
      const RepoCommand('flutter', <String>['--version']),
      const RepoCommand('dart', <String>['pub', 'get']),
      ..._dartPackageCommands(includeRepositoryChecks: false),
      ..._flutterPackageCommands(),
    ],
    'check' => <RepoCommand>[
      ..._dartPackageCommands(includeRepositoryChecks: true),
      ..._flutterPackageCommands(),
      ..._codegenCommands(),
    ],
    'release' => <RepoCommand>[
      RepoCommand('dart', <String>[
        'run',
        'tool/release_prep.dart',
        ...taskArguments,
      ]),
    ],
    _ => throw FormatException('未知仓库任务：$task；可选：${taskNames.join(', ')}'),
  };

  List<RepoCommand> _dartPackageCommands({
    required bool includeRepositoryChecks,
  }) {
    final String? timeout = environment['PATCHBAY_DART_TEST_TIMEOUT'];
    return <RepoCommand>[
      if (includeRepositoryChecks) ...<RepoCommand>[
        const RepoCommand('dart', <String>[
          'format',
          '--output=none',
          '--set-exit-if-changed',
          '.',
        ]),
        const RepoCommand('dart', <String>['run', 'tool/check_planning.dart']),
      ],
      for (final RepoPackage package in _dartPackages) ...<RepoCommand>[
        RepoCommand('dart', const <String>[
          'analyze',
          '--fatal-infos',
        ], workingDirectory: package.path),
        RepoCommand('dart', <String>[
          'test',
          '--reporter=failures-only',
          if (timeout != null && timeout.isNotEmpty) '--timeout=$timeout',
        ], workingDirectory: package.path),
      ],
    ];
  }

  List<RepoCommand> _flutterPackageCommands() => <RepoCommand>[
    for (final RepoPackage package in _flutterPackages) ...<RepoCommand>[
      RepoCommand('flutter', const <String>[
        'analyze',
      ], workingDirectory: package.path),
      RepoCommand('flutter', const <String>[
        'test',
        '--reporter=failures-only',
      ], workingDirectory: package.path),
    ],
    const RepoCommand('flutter', <String>[
      'pub',
      'get',
    ], workingDirectory: 'packages/patchbay_flutter/example'),
    const RepoCommand('flutter', <String>[
      'analyze',
    ], workingDirectory: 'packages/patchbay_flutter/example'),
    const RepoCommand('flutter', <String>[
      'test',
      '--reporter=failures-only',
    ], workingDirectory: 'packages/patchbay_flutter/example'),
  ];

  List<RepoCommand> _coverageCommands() {
    final String? timeout = environment['PATCHBAY_DART_TEST_TIMEOUT'];
    return <RepoCommand>[
      for (final CoverageReport report in coverageReportsFor(workspace))
        if (report.usesFlutter)
          RepoCommand('flutter', <String>[
            'test',
            '--coverage',
            '--branch-coverage',
            '--coverage-path=${report.outputDirectory}/lcov.info',
            '--reporter=failures-only',
          ], workingDirectory: report.workingDirectory)
        else
          RepoCommand('dart', <String>[
            'run',
            'coverage:test_with_coverage',
            '--branch-coverage',
            '--scope-output=${report.name}',
            '--out=${report.outputDirectory}',
            '--',
            '--reporter=failures-only',
            if (timeout != null && timeout.isNotEmpty) '--timeout=$timeout',
          ], workingDirectory: report.workingDirectory),
    ];
  }

  List<RepoCommand> _codegenCommands() => const <RepoCommand>[
    RepoCommand('dart', <String>[
      'run',
      'packages/patchbay/bin/wire_codegen.dart',
      '--contract',
      'packages/patchbay/contracts/core_wire.json',
      '--output',
      'packages/patchbay/lib/src/generated/core_wire.g.dart',
      '--check',
    ]),
    RepoCommand('dart', <String>[
      'run',
      'packages/patchbay/bin/command_codegen.dart',
      '--contract',
      'packages/patchbay/contracts/example_commands.json',
      '--output',
      'packages/patchbay/contracts/example_commands.g.dart',
      '--check',
    ]),
    RepoCommand('dart', <String>[
      'run',
      'tool/protocol_cli_codegen.dart',
      '--check',
    ], workingDirectory: 'packages/patchbay_cli'),
    RepoCommand('dart', <String>[
      'run',
      'tool/command_docs.dart',
      '--check',
    ], workingDirectory: 'packages/patchbay_cli'),
  ];
}

Future<int> runRepoTask(
  String root,
  String task,
  List<String> taskArguments,
) async {
  final RepoTaskCatalog catalog = RepoTaskCatalog(RepoWorkspace.discover(root));
  final List<CoverageReport> coverageReports = task == 'coverage'
      ? coverageReportsFor(catalog.workspace)
      : const <CoverageReport>[];
  if (coverageReports.isNotEmpty) {
    prepareCoverageReports(root, coverageReports);
  }
  for (final RepoCommand command in catalog.commandsFor(
    task,
    taskArguments: taskArguments,
  )) {
    stdout.writeln('== ${command.display} ==');
    final Process process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory == '.'
          ? root
          : '$root/${command.workingDirectory}',
      environment: command.environment.isEmpty ? null : command.environment,
      mode: ProcessStartMode.inheritStdio,
    );
    final int result = await process.exitCode;
    if (result != 0) {
      stderr.writeln('仓库任务 $task 失败：${command.display}（退出码 $result）');
      return result;
    }
  }
  if (coverageReports.isNotEmpty) {
    normalizeCoverageReports(root, coverageReports);
    for (final String summary in validateCoverageReports(
      root,
      coverageReports,
    )) {
      stdout.writeln(summary);
    }
  }
  stdout.writeln('仓库任务 $task 通过');
  return 0;
}

void prepareCoverageReports(String root, Iterable<CoverageReport> reports) {
  for (final CoverageReport report in reports) {
    final Directory directory = Directory(
      '$root/${report.rootRelativeDirectory}',
    )..createSync(recursive: true);
    for (final String name in <String>[
      'lcov.info',
      if (report.requiresRawJson) 'coverage.json',
    ]) {
      final File stale = File('${directory.path}/$name');
      if (stale.existsSync()) stale.deleteSync();
    }
  }
}

void normalizeCoverageReports(String root, Iterable<CoverageReport> reports) {
  final String rootPath = Directory(root).absolute.path;
  final String rootPrefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  for (final CoverageReport report in reports) {
    final File lcov = File('$root/${report.rootRelativeDirectory}/lcov.info');
    if (!lcov.existsSync()) continue;
    final Uri packageRoot = Directory(
      '$root/${report.workingDirectory}',
    ).absolute.uri;
    final List<String> normalized = lcov
        .readAsLinesSync()
        .map((line) {
          if (!line.startsWith('SF:')) return line;
          final String source = line.substring('SF:'.length);
          final Uri sourceUri = Uri.file(source, windows: Platform.isWindows);
          final Uri resolvedSource =
              (sourceUri.isAbsolute
                      ? sourceUri
                      : packageRoot.resolveUri(sourceUri))
                  .normalizePath();
          final String absolute = File.fromUri(resolvedSource).absolute.path;
          if (!absolute.startsWith(rootPrefix)) {
            throw FormatException('${report.name} 的 LCOV source 不在仓库内：$source');
          }
          final String relative = absolute
              .substring(rootPrefix.length)
              .replaceAll(Platform.pathSeparator, '/');
          return 'SF:$relative';
        })
        .toList(growable: false);
    lcov.writeAsStringSync('${normalized.join('\n')}\n');
  }
}

List<String> validateCoverageReports(
  String root,
  Iterable<CoverageReport> reports,
) {
  final List<String> summaries = <String>[];
  for (final CoverageReport report in reports) {
    final String directory = '$root/${report.rootRelativeDirectory}';
    final File lcov = File('$directory/lcov.info');
    if (!lcov.existsSync()) {
      throw FormatException('${report.name} 缺 coverage/lcov.info');
    }
    final String contents = lcov.readAsStringSync();
    final List<String> sources = RegExp(
      r'^SF:(.+)$',
      multiLine: true,
    ).allMatches(contents).map((match) => match.group(1)!).toList();
    final String expectedPrefix = report.workingDirectory == '.'
        ? 'lib/'
        : '${report.workingDirectory}/lib/';
    if (sources.isEmpty || !contents.contains('end_of_record')) {
      throw FormatException('${report.name} 的 coverage/lcov.info 为空或格式无效');
    }
    if (sources.any((source) => !source.startsWith(expectedPrefix))) {
      throw FormatException('${report.name} 的 LCOV source 未规范化到包内 lib/');
    }
    if (report.requiresRawJson) {
      final File raw = File('$directory/coverage.json');
      if (!raw.existsSync() || raw.lengthSync() == 0) {
        throw FormatException('${report.name} 缺 coverage/coverage.json');
      }
    }
    final List<RegExpMatch> lines = RegExp(
      r'^DA:\d+,(\d+)',
      multiLine: true,
    ).allMatches(contents).toList(growable: false);
    final int coveredLines = lines
        .where((match) => int.parse(match.group(1)!) > 0)
        .length;
    final List<RegExpMatch> branches = RegExp(
      r'^BRDA:[^,]+,[^,]+,[^,]+,([^\r\n]+)$',
      multiLine: true,
    ).allMatches(contents).toList(growable: false);
    final int coveredBranches = branches.where((match) {
      final String taken = match.group(1)!;
      return taken != '-' && (int.tryParse(taken) ?? 0) > 0;
    }).length;
    final int branchCount = branches.length;
    summaries.add(
      'coverage ${report.name}: ${sources.length} files, '
      'lines $coveredLines/${lines.length}, '
      'branches $coveredBranches/$branchCount',
    );
  }
  return summaries;
}

String? _readTopLevelScalar(String yaml, String key) {
  final RegExpMatch? match = RegExp(
    '^$key:[ \\t]*(.+)\$',
    multiLine: true,
  ).firstMatch(yaml);
  if (match == null) return null;
  final String value = match.group(1)!.trim();
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

List<String> _topLevelBlock(String yaml, String key) {
  final List<String> result = <String>[];
  var inBlock = false;
  for (final String line in yaml.split('\n')) {
    if (!inBlock) {
      if (line.trimRight() == '$key:') inBlock = true;
      continue;
    }
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      break;
    }
    result.add(line);
  }
  return result;
}

List<String> _readWorkspacePaths(String yaml) =>
    _topLevelBlock(yaml, 'workspace')
        .map((line) => RegExp(r'^  -\s+(.+)$').firstMatch(line)?.group(1))
        .whereType<String>()
        .toList(growable: false);

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.first == '--help') {
    stdout.writeln(
      '用法：dart run tool/repo_tasks.dart <${RepoTaskCatalog.taskNames.join('|')}> [任务参数]',
    );
    return;
  }
  if (arguments.first == '--list') {
    stdout.writeAll(RepoTaskCatalog.taskNames.map((task) => '$task\n'));
    return;
  }

  try {
    exitCode = await runRepoTask(
      Directory.current.absolute.path,
      arguments.first,
      arguments.skip(1).toList(growable: false),
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  }
}
