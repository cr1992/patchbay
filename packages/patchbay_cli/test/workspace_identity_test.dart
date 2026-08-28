/// PB-050-14 验证节第一组：workspace identity。
///
/// 钉死的是「什么算同一个工作区」这条判据本身：同一 checkout 的子目录必须收敛到同一个
/// id；两个共享 Git common dir 的 worktree 必须**不同**（common dir / 仓库名恰恰是会把
/// 它们合并回一个作用域的候选，已被 Proposal 否决）；symlink 必须收敛；非 Git 目录以
/// cwd 本身为界，不按 pubspec / 父目录猜项目边界；cwd、realpath、Git 探测三条失败路径
/// 一律 fail-closed（identity 为 unavailable），不猜、不退回任何"全局"语义。
library;

import 'dart:io';

import 'package:patchbay_cli/src/platform/process_utils.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('patchbay-workspace-id-');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  group('git worktree identity', () {
    test('every subdirectory of one checkout gets the same id', () {
      final Directory checkout = _gitCheckout(temporary, 'repo');
      final Directory nested = Directory('${checkout.path}/lib/src/deep')
        ..createSync(recursive: true);

      final PatchbayWorkspaceIdentity? root = PatchbayWorkspaceIdentity.at(
        checkout.path,
      );
      final PatchbayWorkspaceIdentity? deep = PatchbayWorkspaceIdentity.at(
        nested.path,
      );

      expect(root, isNotNull);
      expect(root!.kind, PatchbayWorkspaceKind.gitWorktree);
      expect(deep, isNotNull);
      // The whole point: a command run three directories down is still the
      // same workspace, so a pin taken at the root keeps working.
      expect(deep!.workspaceId, root.workspaceId);
      expect(deep.canonicalRoot, root.canonicalRoot);
    }, skip: _gitSkip);

    test('two worktrees sharing one common dir get different ids', () {
      final Directory checkout = _gitCheckout(temporary, 'repo');
      final Directory second = Directory('${temporary.path}/second');
      _git(checkout.path, <String>[
        'worktree',
        'add',
        '-b',
        'other',
        second.path,
      ]);

      final PatchbayWorkspaceIdentity? first = PatchbayWorkspaceIdentity.at(
        checkout.path,
      );
      final PatchbayWorkspaceIdentity? other = PatchbayWorkspaceIdentity.at(
        second.path,
      );

      expect(first, isNotNull);
      expect(other, isNotNull);
      // `--git-common-dir` is identical for these two; `--show-toplevel` is
      // the only read-only probe that tells them apart, which is exactly why
      // the proposal forbids the common dir as an identity input.
      expect(other!.workspaceId, isNot(first!.workspaceId));
      expect(other.kind, PatchbayWorkspaceKind.gitWorktree);
    }, skip: _gitSkip);

    test('a symlinked route into a checkout converges on the same id', () {
      final Directory checkout = _gitCheckout(temporary, 'repo');
      final Link link = Link('${temporary.path}/alias')
        ..createSync(checkout.path);

      final PatchbayWorkspaceIdentity? direct = PatchbayWorkspaceIdentity.at(
        checkout.path,
      );
      final PatchbayWorkspaceIdentity? viaLink = PatchbayWorkspaceIdentity.at(
        link.path,
      );

      expect(viaLink, isNotNull);
      expect(viaLink!.workspaceId, direct!.workspaceId);
    }, skip: _gitSkip);
  });

  group('directory identity', () {
    test('a non-Git cwd is bounded by the cwd itself', () {
      final Directory project = Directory('${temporary.path}/plain/pkg/sub')
        ..createSync(recursive: true);
      File('${temporary.path}/plain/pubspec.yaml').writeAsStringSync('name: x');

      final PatchbayWorkspaceIdentity? identity = PatchbayWorkspaceIdentity.at(
        project.path,
        gitProbe: (_) => const PatchbayWorkspaceGitAnswer.outsideRepository(),
      );

      expect(identity, isNotNull);
      expect(identity!.kind, PatchbayWorkspaceKind.directory);
      // A `pubspec.yaml` two levels up must not widen the scope: package
      // boundaries are a guess, the cwd is a fact.
      expect(identity.canonicalRoot, project.resolveSymbolicLinksSync());
    });

    test('kind is part of the digest, not just the path', () {
      const String root = '/canonical/root';
      expect(
        PatchbayWorkspaceIdentity.workspaceIdFor(
          kind: PatchbayWorkspaceKind.directory,
          canonicalRoot: root,
        ),
        isNot(
          PatchbayWorkspaceIdentity.workspaceIdFor(
            kind: PatchbayWorkspaceKind.gitWorktree,
            canonicalRoot: root,
          ),
        ),
      );
    });

    test('the digest is byte-for-byte reproducible on this host', () {
      final String first = PatchbayWorkspaceIdentity.workspaceIdFor(
        kind: PatchbayWorkspaceKind.gitWorktree,
        canonicalRoot: '/canonical/root',
      );
      final String second = PatchbayWorkspaceIdentity.workspaceIdFor(
        kind: PatchbayWorkspaceKind.gitWorktree,
        canonicalRoot: '/canonical/root',
      );

      expect(first, second);
      expect(PatchbayWorkspaceIdentity.isWorkspaceIdShaped(first), isTrue);
      expect(first, matches(RegExp(r'^sha256:[0-9a-f]{64}$')));
    });
  });

  group('fail-closed', () {
    test('a deleted cwd yields no identity', () {
      final Directory gone = Directory('${temporary.path}/gone')..createSync();
      gone.deleteSync();

      expect(
        PatchbayWorkspaceIdentity.at(
          gone.path,
          gitProbe: (_) => const PatchbayWorkspaceGitAnswer.outsideRepository(),
        ),
        isNull,
      );
    });

    test('a cwd that cannot even be read yields no identity', () {
      expect(
        PatchbayWorkspaceIdentity.current(
          cwd: () => throw const FileSystemException('cwd is gone'),
        ),
        isNull,
      );
    });

    test('a realpath failure yields no identity', () {
      expect(
        PatchbayWorkspaceIdentity.at(
          temporary.path,
          gitProbe: (_) => const PatchbayWorkspaceGitAnswer.outsideRepository(),
          realpath: (_) => throw const FileSystemException('realpath refused'),
        ),
        isNull,
      );
    });

    test('an unavailable git probe is not downgraded to a directory', () {
      // Timeouts and exec failures are *not* "not a git repository": treating
      // them as a plain directory would silently invent a second identity for
      // a checkout that already has one.
      expect(
        PatchbayWorkspaceIdentity.at(
          temporary.path,
          gitProbe: (_) => const PatchbayWorkspaceGitAnswer.unavailable(),
        ),
        isNull,
      );
    });

    test('a non-absolute git toplevel is refused', () {
      expect(
        PatchbayWorkspaceIdentity.at(
          temporary.path,
          gitProbe: (_) => const PatchbayWorkspaceGitAnswer.toplevel('../rel'),
        ),
        isNull,
      );
    });

    test('a control character or over-long root is refused', () {
      expect(
        PatchbayWorkspaceIdentity.of(
          kind: PatchbayWorkspaceKind.directory,
          canonicalRoot: '/root/with\x00nul',
        ),
        isNull,
      );
      expect(
        PatchbayWorkspaceIdentity.of(
          kind: PatchbayWorkspaceKind.directory,
          canonicalRoot: '/${'a' * patchbayWorkspacePathMaximumLength}',
        ),
        isNull,
      );
      expect(
        PatchbayWorkspaceIdentity.of(
          kind: PatchbayWorkspaceKind.directory,
          canonicalRoot: 'relative/path',
        ),
        isNull,
      );
    });

    test('the git probe budget is bounded and declared', () {
      expect(patchbayWorkspaceGitProbeBudget, const Duration(seconds: 1));
    });

    test('an answer that arrives after the budget is discarded', () {
      // The runner *does* answer, and with a perfectly good toplevel -- it
      // just answers too late. A budget that only ever fired on an exec
      // failure would be no budget at all, so this is asserted on the one
      // shape that separates the two: a successful but slow probe.
      final PatchbayWorkspaceGitAnswer answer =
          PatchbayWorkspaceIdentity.probeGit(
            temporary.path,
            runner: _SlowRunner(
              const Duration(milliseconds: 40),
              ProcessResult(0, 0, '${temporary.path}\n', ''),
            ),
            budget: const Duration(milliseconds: 1),
          );

      expect(answer.unavailable, isTrue);
      expect(answer.toplevel, isNull);
      expect(answer.outsideRepository, isFalse);
      // And the identity built on that probe is unavailable too, rather than
      // falling back to "plain directory" -- see the test above.
      expect(
        PatchbayWorkspaceIdentity.at(
          temporary.path,
          gitProbe: (String cwd) => PatchbayWorkspaceIdentity.probeGit(
            cwd,
            runner: _SlowRunner(
              const Duration(milliseconds: 40),
              ProcessResult(0, 0, '${temporary.path}\n', ''),
            ),
            budget: const Duration(milliseconds: 1),
          ),
        ),
        isNull,
      );
    });

    test('the same answer inside the budget is accepted', () {
      // The control for the test above: nothing about the *content* of the
      // answer made it unavailable, only the time it took.
      PatchbayWorkspaceGitAnswer probe(String cwd) =>
          PatchbayWorkspaceIdentity.probeGit(
            cwd,
            runner: _SlowRunner(
              Duration.zero,
              ProcessResult(0, 0, '${temporary.path}\n', ''),
            ),
          );

      expect(probe(temporary.path).unavailable, isFalse);
      expect(probe(temporary.path).toplevel, temporary.path);

      final PatchbayWorkspaceIdentity? identity = PatchbayWorkspaceIdentity.at(
        temporary.path,
        gitProbe: probe,
      );
      expect(identity, isNotNull);
      expect(identity!.kind, PatchbayWorkspaceKind.gitWorktree);
      expect(identity.canonicalRoot, temporary.resolveSymbolicLinksSync());
    });
  });

  group('real git probe', () {
    test('reports "outside a repository" distinctly from unavailable', () {
      final Directory plain = Directory('${temporary.path}/plain')
        ..createSync();
      // A temp dir under the system temp root is not inside any checkout on a
      // normal machine; if it somehow is, the probe must at least not claim
      // unavailable.
      final PatchbayWorkspaceGitAnswer answer =
          PatchbayWorkspaceIdentity.probeGit(plain.path);

      expect(answer.unavailable, isFalse);
    }, skip: _gitSkip);

    test('finds the toplevel of a real checkout', () {
      final Directory checkout = _gitCheckout(temporary, 'repo');
      final PatchbayWorkspaceGitAnswer answer =
          PatchbayWorkspaceIdentity.probeGit(checkout.path);

      expect(answer.outsideRepository, isFalse);
      expect(answer.unavailable, isFalse);
      expect(answer.toplevel, isNotNull);
    }, skip: _gitSkip);
  });
}

/// A runner that blocks for [delay] before returning [result].
///
/// `Process.runSync` has no timeout, so the probe's budget can only ever be a
/// judgement about an answer already in hand. Blocking synchronously is
/// therefore the faithful shape: it is exactly what a slow Git does to the
/// calling command.
final class _SlowRunner implements ProcessRunner {
  const _SlowRunner(this.delay, this.result);

  final Duration delay;
  final ProcessResult result;

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    if (delay > Duration.zero) sleep(delay);
    return result;
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => throw UnimplementedError();
}

final String? _gitSkip = _hasGit() ? null : 'git is not available on this host';

bool _hasGit() {
  try {
    return Process.runSync('git', <String>['--version']).exitCode == 0;
  } on Object {
    return false;
  }
}

Directory _gitCheckout(Directory parent, String name) {
  final Directory root = Directory('${parent.path}/$name')..createSync();
  _git(root.path, <String>['init', '-q', '-b', 'main']);
  File('${root.path}/seed.txt').writeAsStringSync('seed');
  _git(root.path, <String>['add', 'seed.txt']);
  _git(root.path, <String>[
    '-c',
    'user.email=fixture@example.com',
    '-c',
    'user.name=fixture',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '-q',
    '-m',
    'seed',
  ]);
  return root;
}

void _git(String cwd, List<String> arguments) {
  final ProcessResult result = Process.runSync('git', <String>[
    '-C',
    cwd,
    ...arguments,
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'git ${arguments.join(' ')} failed: ${result.stderr}',
  );
}
