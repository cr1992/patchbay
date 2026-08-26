import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../platform/process_utils.dart';

/// Domain separator baked into every workspace digest.
///
/// It is part of the hashed preimage, not a prefix on the output: a future
/// identity rule gets a new domain string and therefore a disjoint id space,
/// so a v1 and a v2 digest can never collide into "same workspace".
const String patchbayWorkspaceIdentityDomain = 'patchbay-workspace-v1';

/// The value of a session record's `workspaceIdentityVersion` field.
const int patchbayWorkspaceIdentityVersion = 1;

/// Hard budget for the read-only Git probe. One shot, no retry.
const Duration patchbayWorkspaceGitProbeBudget = Duration(seconds: 1);

/// Longest canonical root this CLI will hash or store.
const int patchbayWorkspacePathMaximumLength = 4096;

/// How many scoped pins one session directory may hold.
const int patchbayScopedSelectionMaximumCount = 256;

/// How large one scoped pin file may be.
const int patchbayScopedSelectionMaximumBytes = 1024;

/// What kind of boundary a workspace identity was derived from.
///
/// Deliberately only two: a Git *worktree* (never the repository, never the
/// common dir -- two worktrees of one repo must not collapse into one scope)
/// and a plain directory (the cwd itself, never a guessed project root).
enum PatchbayWorkspaceKind { gitWorktree, directory }

/// Where one session record sits relative to the workspace running the command.
enum PatchbayWorkspaceAffinity {
  /// Provably this workspace: either the record carries a matching digest, or
  /// a legacy record's path recomputes to exactly this identity.
  current,

  /// Provably some other workspace: the record carries a digest that is not
  /// this one. Implicit selection must never return one of these.
  foreign,

  /// Membership could not be proven either way -- a legacy record whose path
  /// moved or no longer resolves, or any record at all when the current
  /// identity itself is unavailable. Treated exactly like [foreign] by every
  /// implicit path; the difference is only what diagnostics may claim.
  legacyUnverified,
}

/// One answer from the read-only `git rev-parse --show-toplevel` probe.
///
/// The three outcomes are kept distinct on purpose. "Outside a repository" is
/// a *positive* answer that licenses [PatchbayWorkspaceKind.directory];
/// "unavailable" (timeout, missing binary, unreadable cwd, anything else) is
/// not, because silently downgrading it to a directory would invent a second
/// identity for a checkout that already has one.
final class PatchbayWorkspaceGitAnswer {
  const PatchbayWorkspaceGitAnswer.toplevel(String path)
    : toplevel = path,
      outsideRepository = false,
      unavailable = false;

  const PatchbayWorkspaceGitAnswer.outsideRepository()
    : toplevel = null,
      outsideRepository = true,
      unavailable = false;

  const PatchbayWorkspaceGitAnswer.unavailable()
    : toplevel = null,
      outsideRepository = false,
      unavailable = true;

  final String? toplevel;
  final bool outsideRepository;
  final bool unavailable;
}

typedef PatchbayWorkspaceGitProbe =
    PatchbayWorkspaceGitAnswer Function(String cwd);
typedef PatchbayWorkspaceRealpath = String Function(String path);

/// The current workspace, or `null` when it cannot be proven.
typedef PatchbayWorkspaceIdentityProbe = PatchbayWorkspaceIdentity? Function();

/// The workspace some *other* path belongs to, or `null` when unprovable.
typedef PatchbayWorkspaceIdentityAt =
    PatchbayWorkspaceIdentity? Function(String path);

/// A host-local, reproducible name for one checkout (PB-050-14).
///
/// [canonicalRoot] is local locating data: it is written only to owner-only
/// session files and never reaches a command response, trace, audit event or
/// error detail. Everything that leaves the process uses [workspaceId] (a
/// fixed-length digest) or the already-redacted workspace *name*.
final class PatchbayWorkspaceIdentity {
  const PatchbayWorkspaceIdentity._({
    required this.kind,
    required this.canonicalRoot,
    required this.workspaceId,
  });

  /// Builds an identity from an already-canonical root, or `null` when that
  /// root fails the shape rules (empty, relative, over-long, control chars).
  static PatchbayWorkspaceIdentity? of({
    required PatchbayWorkspaceKind kind,
    required String canonicalRoot,
    bool? isWindows,
  }) {
    if (!isCanonicalRootShaped(canonicalRoot, isWindows: isWindows)) {
      return null;
    }
    return PatchbayWorkspaceIdentity._(
      kind: kind,
      canonicalRoot: canonicalRoot,
      workspaceId: workspaceIdFor(kind: kind, canonicalRoot: canonicalRoot),
    );
  }

  /// The identity a command started in [cwd] would get.
  ///
  /// Fail-closed at every step: an unavailable Git answer, a non-absolute
  /// toplevel, a failing realpath or a mis-shaped root all yield `null`, and
  /// every implicit selection path then refuses with
  /// `sessionWorkspaceUnavailable` rather than guessing.
  static PatchbayWorkspaceIdentity? at(
    String cwd, {
    PatchbayWorkspaceGitProbe? gitProbe,
    PatchbayWorkspaceRealpath? realpath,
    bool? isWindows,
  }) {
    final PatchbayWorkspaceGitAnswer answer = (gitProbe ?? probeGit)(cwd);
    if (answer.unavailable) return null;
    final PatchbayWorkspaceKind kind = answer.outsideRepository
        ? PatchbayWorkspaceKind.directory
        : PatchbayWorkspaceKind.gitWorktree;
    final String raw = answer.outsideRepository ? cwd : answer.toplevel!;
    // Git is expected to answer with an absolute path; anything else means we
    // are not talking to the tool we think we are.
    if (!_isAbsolute(raw, isWindows)) return null;
    final String canonical;
    try {
      canonical = (realpath ?? _realpath)(raw);
    } on Object {
      return null;
    }
    return of(kind: kind, canonicalRoot: canonical, isWindows: isWindows);
  }

  /// The identity of the process's own working directory.
  ///
  /// [cwd] is a seam, not a parameter callers are expected to pass: reading
  /// the working directory can itself fail (it was deleted underneath us), and
  /// that failure has to fold into the same `null` as every other one.
  static PatchbayWorkspaceIdentity? current({
    String Function()? cwd,
    PatchbayWorkspaceGitProbe? gitProbe,
    PatchbayWorkspaceRealpath? realpath,
    bool? isWindows,
  }) {
    final String started;
    try {
      started = (cwd ?? _currentDirectory)();
    } on Object {
      return null;
    }
    return at(
      started,
      gitProbe: gitProbe,
      realpath: realpath,
      isWindows: isWindows,
    );
  }

  final PatchbayWorkspaceKind kind;

  /// Host-local absolute path with symlinks resolved. Owner-only data.
  final String canonicalRoot;

  /// `sha256:` followed by 64 lowercase hex characters.
  final String workspaceId;

  /// The 64 hex characters alone -- what a scoped pin file name is made of.
  ///
  /// The `sha256:` prefix is deliberately dropped there: a colon is not a
  /// legal Windows file name character.
  String get digest => workspaceId.substring('sha256:'.length);

  /// The digest for a (kind, canonical root) pair.
  ///
  /// Kind is inside the preimage, so the same path seen once as a worktree
  /// and once as a plain directory is two identities -- which is correct: one
  /// of the two readings is wrong, and silently merging them would be the
  /// "guess" this whole feature exists to remove.
  static String workspaceIdFor({
    required PatchbayWorkspaceKind kind,
    required String canonicalRoot,
  }) {
    final Digest digest = sha256.convert(
      utf8.encode(
        '$patchbayWorkspaceIdentityDomain\x00${kind.name}\x00$canonicalRoot',
      ),
    );
    return 'sha256:$digest';
  }

  static final RegExp _workspaceIdShape = RegExp(r'^sha256:[0-9a-f]{64}$');

  static bool isWorkspaceIdShaped(String value) =>
      _workspaceIdShape.hasMatch(value);

  /// Whether [value] may be hashed and stored as a canonical root.
  ///
  /// Checked *before* the path reaches a digest preimage or a JSON field, per
  /// the proposal's "所有路径都在进入文件名或 JSON 前做长度和字符校验".
  static bool isCanonicalRootShaped(String value, {bool? isWindows}) {
    if (value.isEmpty || value.length > patchbayWorkspacePathMaximumLength) {
      return false;
    }
    for (final int unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    return _isAbsolute(value, isWindows);
  }

  /// Environment carrying this identity to a supervised child.
  ///
  /// The child re-derives nothing: `patchbay launch` computes the identity
  /// once, before the child starts, so a child that changes its own working
  /// directory cannot change which workspace its session belongs to.
  Map<String, String> toEnvironment() => <String, String>{
    idKey: workspaceId,
    kindKey: kind.name,
    rootKey: canonicalRoot,
  };

  /// Environment variable names carrying an identity to a supervised child.
  static const String idKey = 'PATCHBAY_LAUNCH_WORKSPACE_ID';
  static const String kindKey = 'PATCHBAY_LAUNCH_WORKSPACE_KIND';
  static const String rootKey = 'PATCHBAY_LAUNCH_WORKSPACE_ROOT';

  /// Reads back [toEnvironment], recomputing the digest rather than trusting
  /// it.
  ///
  /// `identity` is `null` and `invalid` is `false` when none of the three keys
  /// is present -- an older launcher, which is a supported shape. `invalid` is
  /// `true` when they are partially present, mis-shaped, or inconsistent with
  /// each other: that is a broken launch context, not a licence to fall back
  /// to "no workspace", because the child would then write a legacy record
  /// that merely looks old.
  static ({PatchbayWorkspaceIdentity? identity, bool invalid}) fromEnvironment(
    Map<String, String> values,
  ) {
    const ({PatchbayWorkspaceIdentity? identity, bool invalid}) broken = (
      identity: null,
      invalid: true,
    );
    final String? id = values[idKey];
    final String? kind = values[kindKey];
    final String? root = values[rootKey];
    if (id == null && kind == null && root == null) {
      return (identity: null, invalid: false);
    }
    if (id == null || kind == null || root == null) return broken;
    final PatchbayWorkspaceKind? parsed = PatchbayWorkspaceKind.values
        .where((PatchbayWorkspaceKind value) => value.name == kind)
        .firstOrNull;
    if (parsed == null) return broken;
    final PatchbayWorkspaceIdentity? identity = of(
      kind: parsed,
      canonicalRoot: root,
    );
    if (identity == null || identity.workspaceId != id) return broken;
    return (identity: identity, invalid: false);
  }

  /// Runs the read-only Git probe for [cwd].
  ///
  /// `--show-toplevel` on purpose, never `--git-common-dir`: the common dir is
  /// shared by every worktree of one repository, which is precisely the merge
  /// this feature must not make.
  ///
  /// The budget bounds how long an answer stays *acceptable*, not how long the
  /// subprocess may run -- `Process.runSync` has no timeout, the same known
  /// limitation the process-start-time probe already lives with. A wedged Git
  /// therefore blocks the call; a merely slow one is discarded as unavailable.
  static PatchbayWorkspaceGitAnswer probeGit(
    String cwd, {
    ProcessRunner runner = PlatformProcessUtils.defaultRunner,
    Duration budget = patchbayWorkspaceGitProbeBudget,
  }) {
    final Stopwatch watch = Stopwatch()..start();
    final ProcessResult result;
    try {
      result = runner.runSync('git', <String>[
        '-C',
        cwd,
        'rev-parse',
        '--show-toplevel',
      ]);
    } on Object {
      return const PatchbayWorkspaceGitAnswer.unavailable();
    }
    if (watch.elapsed > budget) {
      return const PatchbayWorkspaceGitAnswer.unavailable();
    }
    if (result.exitCode == 0) {
      final String toplevel = '${result.stdout}'.trim();
      if (toplevel.isEmpty) {
        return const PatchbayWorkspaceGitAnswer.unavailable();
      }
      return PatchbayWorkspaceGitAnswer.toplevel(toplevel);
    }
    final String stderr = '${result.stderr}'.toLowerCase();
    // Only these two phrasings are a positive "you are not in a repository".
    // Everything else -- a broken repository, a permissions error, a Git that
    // is not Git -- stays unavailable.
    if (stderr.contains('not a git repository') ||
        stderr.contains('this operation must be run in a work tree')) {
      return const PatchbayWorkspaceGitAnswer.outsideRepository();
    }
    return const PatchbayWorkspaceGitAnswer.unavailable();
  }

  static String _currentDirectory() => Directory.current.path;

  static String _realpath(String path) =>
      Directory(path).resolveSymbolicLinksSync();

  static bool _isAbsolute(String value, bool? isWindows) {
    final bool windows = isWindows ?? Platform.isWindows;
    if (!windows) return value.startsWith('/');
    // A canonical Windows root is either `X:\...` or a UNC `\\server\share`.
    if (value.startsWith(r'\\')) return true;
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  }
}
