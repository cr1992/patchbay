import 'dart:io';

import 'package:test/test.dart';

import '../tool/backlog_store.dart';
import '../tool/release_finalize.dart';

/// A throwaway repository root the planning checker can run against.
///
/// PB-060-04 made the active version *derived* from plan statuses instead of a
/// hand-written constant, so the fixture no longer parses the checker's source
/// to learn which version is active — it declares plans and lets the checker
/// work it out. That is the property under test.
final class _Repo {
  _Repo._(this.root);

  factory _Repo.create() {
    final Directory directory = Directory.systemTemp.createTempSync(
      'check-planning-test-',
    );
    final String root = directory.path;
    Directory('$root/docs/releases').createSync(recursive: true);
    Directory('$root/docs/proposals').createSync(recursive: true);
    Directory('$root/$backlogFragmentDir').createSync(recursive: true);
    File('$root/AGENTS.md').writeAsStringSync('instructions\n');
    File('$root/CLAUDE.md').writeAsStringSync('@AGENTS.md\n');
    File(
      '$root/$backlogIndexPath',
    ).writeAsStringSync('# Backlog\n\n条目真源见 `backlog.d/`。\n');
    return _Repo._(root);
  }

  final String root;

  /// Writes a release plan. [scope] lists the ids to put in the P0 table.
  void plan(
    String version, {
    required String status,
    List<String> scope = const <String>[],
    String branchDeclaration = _defaultBranch,
    String body = '',
  }) {
    final String declaration = branchDeclaration == _defaultBranch
        ? '> 版本分支：`dev/$version`，从稳定 `main` 的 `788214c4` 创建。'
        : branchDeclaration;
    final StringBuffer buffer = StringBuffer()
      ..writeln('# $version')
      ..writeln()
      ..writeln('> 状态：$status');
    if (declaration.isNotEmpty) {
      buffer
        ..writeln('>')
        ..writeln(declaration);
    }
    buffer
      ..writeln()
      ..writeln('### P0：发布阻断')
      ..writeln()
      ..writeln('| 编号 | 关键验收 |')
      ..writeln('|---|---|');
    for (final String id in scope) {
      buffer.writeln('| $id | 验收 |');
    }
    if (body.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(body);
    }
    File(
      '$root/docs/releases/$version.md',
    ).writeAsStringSync(buffer.toString());
  }

  /// Writes a `PB` backlog fragment.
  void fragment(String id, {required String target, required String status}) {
    File('$root/$backlogFragmentDir/$id.md').writeAsStringSync(
      '---\n'
      'id: $id\n'
      'title: 占位条目\n'
      'target: $target\n'
      'status: $status\n'
      '---\n'
      '\n'
      '## 动机\n'
      '\n'
      '占位动机。\n'
      '\n'
      '## 备注\n'
      '\n'
      '占位备注。\n',
    );
  }

  /// Writes a `DG` backlog fragment.
  void gate(String id, {required String target, required String status}) {
    File('$root/$backlogFragmentDir/$id.md').writeAsStringSync(
      '---\n'
      'id: $id\n'
      'title: 占位裁决点\n'
      'target: $target\n'
      'status: $status\n'
      '---\n'
      '\n'
      '## Proposal\n'
      '\n'
      '占位方案指针。\n',
    );
  }

  ProcessResult run() => Process.runSync(Platform.resolvedExecutable, <String>[
    'run',
    _checker,
  ], workingDirectory: root);

  void dispose() => Directory(root).deleteSync(recursive: true);

  static const String _defaultBranch = '<default>';
}

final String _checker = File('../../tool/check_planning.dart').absolute.path;

String _checkerSource() => File(_checker).readAsStringSync();

void main() {
  test('finalize 认得的每个状态都在 check_planning 的封闭词表里', () {
    // 回归：`待真机验收` 曾只活在 release_finalize 与发版清单里，不在
    // check_planning 的词表中——同一份台账被两个工具判出相反的合法性，
    // 收尾人一旦按发版清单标注就会撞红。任一侧再漂移，这条立刻转红。
    final String? body = RegExp(
      r'const\s+_allowedBacklogStatuses\s*=\s*<String>\{([^}]*)\}',
    ).firstMatch(_checkerSource())?.group(1);
    if (body == null) {
      throw FormatException(
        'Could not parse _allowedBacklogStatuses from tool/check_planning.dart.',
        _checker,
      );
    }
    final Set<String> allowed = RegExp(
      "'([^']+)'",
    ).allMatches(body).map((RegExpMatch match) => match.group(1)!).toSet();

    expect(allowed, contains(statusVerified));
    expect(allowed, contains(statusEvidencePending));
    expect(allowed, contains(statusInProgress));
  });

  test('已发布版本的终态条目在已发布 scope 之外也不判红', () {
    // 全部计划已发布 => 没有活跃版本 => 不做范围对账。这是版本间歇期的合法状态。
    final _Repo repo = _Repo.create();
    addTearDown(repo.dispose);
    repo.plan('0.5.0', status: '已发布', scope: <String>['PB-050-01']);

    final ProcessResult result = repo.run();

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('active version none'));
  });

  test('活跃计划仍拒绝 scope 引用不存在的 backlog 条目', () {
    final _Repo repo = _Repo.create();
    addTearDown(repo.dispose);
    repo.plan('0.6.0', status: 'RC', scope: <String>['PB-060-99']);

    final ProcessResult result = repo.run();

    expect(result.exitCode, 1);
    expect(result.stderr, contains('release scope references a missing'));
  });

  test('活跃版本由计划状态派生，无需手写常量', () {
    final _Repo repo = _Repo.create();
    addTearDown(repo.dispose);
    repo.plan('0.5.0', status: '已发布');
    repo.plan('0.6.0', status: '规划中', scope: <String>['PB-060-01']);
    repo.fragment('PB-060-01', target: '0.6.0', status: '已排期');

    final ProcessResult result = repo.run();

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('active version 0.6.0'));
    expect(
      _checkerSource(),
      isNot(contains('_activeVersion')),
      reason: '手写 active version 常量是漂移来源，不得回潮',
    );
  });

  group('已发布版本残留 target', () {
    test('非终态状态判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.4.0', status: '已发布');
      repo.fragment('PB-040-02', target: '0.4.0', status: '实现中');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('PB-040-02: target 0.4.0 已发布'));
      expect(result.stderr, contains('实现中'));
    });

    for (final String terminal in <String>['已验证', '待真机验收']) {
      test('终态「$terminal」放行', () {
        final _Repo repo = _Repo.create();
        addTearDown(repo.dispose);
        repo.plan('0.4.0', status: '已发布');
        repo.fragment('PB-040-02', target: '0.4.0', status: terminal);

        final ProcessResult result = repo.run();

        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      });
    }

    test('延期回未排期也放行', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.4.0', status: '已发布');
      repo.fragment('PB-040-02', target: unscheduledTarget, status: '待排期');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  });

  group('版本启动顺序', () {
    test('两份未发布计划判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '规划中');
      repo.plan('0.7.0', status: '规划中');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('同时存在 2 份未发布版本计划'));
      expect(result.stderr, contains('0.6.0、0.7.0'));
    });

    test('缺版本分支声明判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '规划中', branchDeclaration: '');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('必须有 `> 版本分支：'));
    });

    test('版本分支声明与计划版本不一致判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan(
        '0.6.0',
        status: '规划中',
        branchDeclaration: '> 版本分支：`dev/0.7.0`，从稳定 `main` 创建。',
      );

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('版本分支声明的是 `dev/0.7.0`'));
    });

    test('未声明从稳定 main 创建判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan(
        '0.6.0',
        status: '规划中',
        branchDeclaration: '> 版本分支：`dev/0.6.0`，从 `dev/0.5.0` 创建。',
      );

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('必须写明「从稳定 `main`」创建'));
    });

    test('活跃版本不大于已发布版本判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '已发布');
      repo.plan('0.5.1', status: '规划中');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('活跃版本 0.5.1 不大于已发布版本 0.6.0'));
    });
  });

  group('草案瞬时事实', () {
    for (final String marker in <String>[
      '待裁决稿',
      '并行分支',
      '仓主口径',
      '本稿',
      '本分支 base',
    ]) {
      test('活跃计划命中「$marker」判红', () {
        final _Repo repo = _Repo.create();
        addTearDown(repo.dispose);
        repo.plan('0.6.0', status: '规划中', body: '说明：$marker 上现有最大编号是 X。');

        final ProcessResult result = repo.run();

        expect(result.exitCode, 1);
        expect(result.stderr, contains('命中「$marker」'));
      });
    }

    test('「版本分支」不因含「本分支」子串误报', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '规划中', body: '所有在版 MR 以该版本分支为目标。');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('正文引用提交 SHA 判红，版本分支声明行放行', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      // 声明行自带 `788214c4`，必须不判红；正文另一枚 SHA 必须判红。
      repo.plan('0.6.0', status: '规划中', body: 'RC 候选钉死 `cb108064`。');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('不得引用提交 SHA `cb108064`'));
      expect(result.stderr, isNot(contains('`788214c4`')));
    });

    test('已发布计划保留历史 SHA 与历史措辞', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan(
        '0.5.0',
        status: '已发布',
        body: '正式版 peeled commit `cb108064`；当时的仓主口径见记录。',
      );

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('日期与计数不被误判成提交 SHA', () {
      // 回归：判据曾只要求"含数字"，于是版本计划里天然存在的日期、字节数和长编号
      // 全部被判成 SHA。计划文档必然要写日期，这类误报会直接误挡 CI。
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan(
        '0.6.0',
        status: '规划中',
        body: '裁决于 `20260831`；上限 `1048576` 字节；条目 `1000000`。',
      );

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('多行版本分支声明判红', () {
      // 回归：版本号校验按正则取行、起点校验按前缀另取一行，两行声明时二者分叉，
      // 一条误报另一条漏检。数量先钉住，后续只用同一次匹配。
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan(
        '0.6.0',
        status: '规划中',
        branchDeclaration: '> 版本分支：待定\n>\n> 版本分支：`dev/0.6.0`，从稳定 `main` 创建。',
      );

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('出现 2 行 `> 版本分支：` 声明'));
    });
  });

  group('已发布版本残留 target：design-gate', () {
    test('DG 非终态判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.4.0', status: '已发布');
      repo.gate('DG-040-01', target: '0.4.0', status: '待裁决');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(result.stderr, contains('DG-040-01: target 0.4.0 已发布'));
      expect(
        result.stderr,
        contains('已裁决'),
        reason: 'DG 必须按自己的终态词表报，不能套用特性的终态集',
      );
    });

    test('DG 已裁决放行', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.4.0', status: '已发布');
      repo.gate('DG-040-01', target: '0.4.0', status: '已裁决');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  });

  test('docs/releases 下的 README 不被当成版本计划', () {
    // docs/proposals 本就有 README，作者容易照搬约定；对 README 报
    // “文件名必须是完整 SemVer”是误导性失败。
    final _Repo repo = _Repo.create();
    addTearDown(repo.dispose);
    repo.plan('0.6.0', status: '规划中');
    File(
      '${repo.root}/docs/releases/README.md',
    ).writeAsStringSync('# 版本计划目录\n\n活跃版本见对应文件。\n');

    final ProcessResult result = repo.run();

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  group('target 解析到版本计划', () {
    test('指向不存在的版本计划判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '规划中');
      repo.fragment('PB-070-01', target: '0.7.0', status: '已排期');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('PB-070-01: target 0.7.0 没有对应的 docs/releases/0.7.0.md'),
      );
    });

    test('未排期字面量放行', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: '规划中');
      repo.fragment('PB-070-01', target: unscheduledTarget, status: '待排期');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  });

  group('Proposal 双向引用', () {
    test('已发布版本的 Proposal 引用归档条目不再判红', () {
      // 回归：finalize 按设计删除已交付碎片后，该版本 Proposal 里的 PB 引用
      // 会悬空。已发布版本的 Proposal 是决策史，口径应与 scope 对账的已发布
      // 豁免一致——否则每次发布收尾都会撞红。
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.5.0', status: '已发布');
      Directory(
        '${repo.root}/docs/proposals/0.5.0',
      ).createSync(recursive: true);
      File(
        '${repo.root}/docs/proposals/0.5.0/archived-refs.md',
      ).writeAsStringSync('# 已交付方案\n\n> 状态：已接受\n\n关联：PB-050-01\n');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('活跃版本的 Proposal 引用缺失条目仍判红', () {
      final _Repo repo = _Repo.create();
      addTearDown(repo.dispose);
      repo.plan('0.6.0', status: 'RC');
      Directory(
        '${repo.root}/docs/proposals/0.6.0',
      ).createSync(recursive: true);
      File(
        '${repo.root}/docs/proposals/0.6.0/dangling-refs.md',
      ).writeAsStringSync('# 活跃方案\n\n> 状态：已接受\n\n关联：PB-060-99\n');

      final ProcessResult result = repo.run();

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('references missing backlog item PB-060-99'),
      );
    });
  });

  test('不支持的版本计划状态判红', () {
    final _Repo repo = _Repo.create();
    addTearDown(repo.dispose);
    repo.plan('0.6.0', status: '待裁决稿');

    final ProcessResult result = repo.run();

    expect(result.exitCode, 1);
    expect(result.stderr, contains('不支持的版本计划状态「待裁决稿」'));
  });
}
