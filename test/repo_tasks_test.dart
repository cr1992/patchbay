import 'dart:io';

import 'package:test/test.dart';

import '../tool/repo_tasks.dart';

void main() {
  final Directory root = Directory.current;

  test('根 package 私有且 workspace 只收四个发布包', () {
    final RepoWorkspace workspace = RepoWorkspace.discover(root.path);

    expect(workspace.rootPackage.name, 'patchbay_repo');
    expect(workspace.rootPackage.publishTo, 'none');
    expect(workspace.members.map((member) => member.name), <String>[
      'patchbay',
      'patchbay_cli',
      'patchbay_flutter',
      'patchbay_transport',
    ]);
    expect(
      workspace.members.every((member) => member.resolution == 'workspace'),
      isTrue,
    );
    expect(
      workspace.members
          .where((member) => member.usesFlutter)
          .map((member) => member.name),
      <String>['patchbay_flutter'],
    );
  });

  test('仓内发布包不再依赖各包 overrides 命中候选代码', () {
    expect(
      File('packages/patchbay_cli/pubspec_overrides.yaml').existsSync(),
      isFalse,
    );
    expect(
      File('packages/patchbay_flutter/pubspec_overrides.yaml').existsSync(),
      isFalse,
    );
    expect(
      File(
        'packages/patchbay_flutter/example/pubspec_overrides.yaml',
      ).existsSync(),
      isTrue,
      reason: 'example 保持 workspace 外 consumer 解析，仍需独立覆盖传递依赖',
    );
  });

  test('repo-only 工具不再进入 patchbay 发布包', () {
    final String analysisOptions = File(
      'analysis_options.yaml',
    ).readAsStringSync();
    expect(
      analysisOptions,
      contains('- packages/**'),
      reason: '根私有包不能抢先分析尚未解析的 workspace 外 example',
    );
    final String flutterAnalysisOptions = File(
      'packages/patchbay_flutter/analysis_options.yaml',
    ).readAsStringSync();
    expect(
      flutterAnalysisOptions,
      contains('- example/**'),
      reason: 'Flutter member 先只分析自身，example 由独立 consumer 任务覆盖',
    );

    for (final String name in <String>[
      'check_api_surface',
      'check_pana_budget',
      'check_structure_ratchet',
      'release_finalize',
      'release_prep',
    ]) {
      expect(File('tool/$name.dart').existsSync(), isTrue, reason: name);
      expect(
        File('packages/patchbay/bin/$name.dart').existsSync(),
        isFalse,
        reason: '$name 是仓库治理工具，不是发布包 executable',
      );
      expect(
        File('packages/patchbay/tool/$name.dart').existsSync(),
        isFalse,
        reason: '$name 的实现应由根私有 package 持有',
      );
    }
  });

  test('GitLab 与 GitHub CI 只选择仓内任务，不再各写包循环', () {
    final String gitlab = File('.gitlab-ci.yml').readAsStringSync();
    final String github = File('.github/workflows/ci.yml').readAsStringSync();

    for (final String task in <String>[
      'dart-packages',
      'flutter-package',
      'codegen-drift',
      'sdk-floor',
      'coverage',
    ]) {
      final String invocation = 'dart run tool/repo_tasks.dart $task';
      expect(gitlab, contains(invocation));
      expect(github, contains(invocation));
    }
    expect(gitlab, isNot(contains('for p in patchbay')));
    expect(github, isNot(contains('for p in patchbay')));
    expect(gitlab, contains('allow_failure: true'));
    expect(gitlab, contains('- coverage/'));
    expect(gitlab, contains('dependencies: []'));
    expect(github, contains('continue-on-error: true'));
    expect(github, contains('actions/upload-artifact@v4'));
    expect(github, contains('path: coverage/'));
  });

  test('任务从 workspace 分类生成包级命令', () {
    final RepoWorkspace workspace = RepoWorkspace.discover(root.path);
    final RepoTaskCatalog catalog = RepoTaskCatalog(workspace);

    expect(
      catalog
          .commandsFor('dart-packages')
          .where((command) => command.arguments.contains('test'))
          .map((command) => command.workingDirectory),
      <String>[
        '.',
        'packages/patchbay',
        'packages/patchbay_cli',
        'packages/patchbay_transport',
      ],
    );
    expect(
      catalog
          .commandsFor('flutter-package')
          .where((command) => command.arguments.contains('test'))
          .map((command) => command.workingDirectory),
      <String>[
        'packages/patchbay_flutter',
        'packages/patchbay_flutter/example',
      ],
    );
  });

  test('coverage 任务为四个发布 package 与 example 生成独立 branch LCOV', () {
    final RepoWorkspace workspace = RepoWorkspace.discover(root.path);
    final RepoTaskCatalog catalog = RepoTaskCatalog(workspace);
    final List<RepoCommand> commands = catalog.commandsFor('coverage');

    final List<RepoCommand> dartCoverage = commands
        .where(
          (command) =>
              command.executable == 'dart' &&
              command.arguments.contains('coverage:test_with_coverage'),
        )
        .toList(growable: false);
    expect(dartCoverage.map((command) => command.workingDirectory), <String>[
      'packages/patchbay',
      'packages/patchbay_cli',
      'packages/patchbay_transport',
    ]);
    for (final RepoCommand command in dartCoverage) {
      expect(command.arguments, contains('--branch-coverage'));
      expect(
        command.arguments.any((argument) => argument.startsWith('--out=')),
        isTrue,
      );
      expect(
        command.arguments.any(
          (argument) => argument.startsWith('--scope-output='),
        ),
        isTrue,
      );
    }

    final List<RepoCommand> flutterCoverage = commands
        .where(
          (command) =>
              command.executable == 'flutter' &&
              command.arguments.contains('--coverage'),
        )
        .toList(growable: false);
    expect(flutterCoverage.map((command) => command.workingDirectory), <String>[
      'packages/patchbay_flutter',
      'packages/patchbay_flutter/example',
    ]);
    for (final RepoCommand command in flutterCoverage) {
      expect(command.arguments, contains('--branch-coverage'));
      expect(
        command.arguments.any(
          (argument) => argument.startsWith('--coverage-path='),
        ),
        isTrue,
      );
    }
  });

  test('coverage 输出规范化后要求五份 LCOV 与三份 Dart raw JSON', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'patchbay-repo-coverage-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));

    final List<CoverageReport> reports = coverageReportsFor(
      RepoWorkspace.discover(root.path),
    );
    for (final CoverageReport report in reports) {
      final Directory directory = Directory(
        '${temporary.path}/coverage/${report.name}',
      )..createSync(recursive: true);
      final String source =
          '${temporary.path}/${report.workingDirectory}/lib/example.dart';
      File('${directory.path}/lcov.info').writeAsStringSync(
        'TN:${report.name}\nSF:$source\nDA:1,1\nend_of_record\n',
      );
      if (report.requiresRawJson) {
        File('${directory.path}/coverage.json').writeAsStringSync('{}\n');
      }
    }

    normalizeCoverageReports(temporary.path, reports);
    expect(
      () => validateCoverageReports(temporary.path, reports),
      returnsNormally,
    );
    for (final CoverageReport report in reports) {
      final String lcov = File(
        '${temporary.path}/coverage/${report.name}/lcov.info',
      ).readAsStringSync();
      expect(lcov, isNot(contains(temporary.path)));
      expect(lcov, contains('SF:${report.workingDirectory}/lib/example.dart'));
    }
    File(
      '${temporary.path}/coverage/patchbay_cli/lcov.info',
    ).writeAsStringSync('');
    expect(
      () => validateCoverageReports(temporary.path, reports),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('patchbay_cli'),
        ),
      ),
    );
  });
}
