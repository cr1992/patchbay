// release_prep 数据与判定模型。

import 'constants.dart';

enum ReleaseCheckStatus { ok, failed, skipped }

/// 一条判定结果。
///
/// [hard] 标记「历史真漏过」或「pub 会直接挡住发布」的项，不允许降级成提示；[detail] 直接
/// 面向人，红的时候要说清「差什么」和「谁来补」。
final class ReleaseCheck {
  const ReleaseCheck({
    required this.id,
    required this.status,
    required this.detail,
    this.hard = false,
  });

  const ReleaseCheck.ok(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.ok;

  const ReleaseCheck.failed(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.failed;

  const ReleaseCheck.skipped(this.id, this.detail, {this.hard = false})
    : status = ReleaseCheckStatus.skipped;

  final String id;
  final ReleaseCheckStatus status;
  final String detail;
  final bool hard;

  bool get failed => status == ReleaseCheckStatus.failed;

  String get marker => switch (status) {
    ReleaseCheckStatus.ok => '通过',
    ReleaseCheckStatus.failed => '未过',
    ReleaseCheckStatus.skipped => '跳过',
  };
}

/// 一个待发布包的静态画像：三个文本 + 包根下已存在的文件名。
///
/// 用数据而不是 `Directory` 表达，判定层因此不碰磁盘，单测不需要临时目录。
final class PackageManifest {
  const PackageManifest({
    required this.name,
    required this.pubspec,
    required this.files,
    this.overrides,
    this.changelog,
  });

  final String name;
  final String pubspec;

  /// 包根下的文件名（不含子目录）。用来判 LICENSE / README / CHANGELOG 是否齐备。
  final Set<String> files;

  /// `pubspec_overrides.yaml` 内容；没有该文件时为 null。
  final String? overrides;

  /// 包内 `CHANGELOG.md` 内容；没有该文件时为 null。
  final String? changelog;
}

/// 判定所需的全部输入，全部是文件内容字符串。
final class ReleaseInputs {
  const ReleaseInputs({
    required this.packages,
    required this.hostSurfaceGolden,
    required this.compatibilityCorpus,
    required this.packageVersionSource,
    required this.readmes,
    required this.changelog,
    required this.examplePubspec,
    required this.exampleOverrides,
    required this.exampleLock,
    required this.compatMatrix,
    required this.serviceHost,
    required this.invocation,
    required this.workflow,
  });

  final Map<String, PackageManifest> packages;
  final String hostSurfaceGolden;

  /// `packages/patchbay_cli/test/golden` 下的相对文件路径与内容。
  final Map<String, String> compatibilityCorpus;
  final String packageVersionSource;
  final Map<String, String> readmes;
  final String changelog;
  final String examplePubspec;
  final String? exampleOverrides;
  final String exampleLock;
  final String compatMatrix;
  final String serviceHost;
  final String invocation;
  final String workflow;
}

/// 兼容矩阵的一行。
final class CompatRow {
  const CompatRow({
    required this.tag,
    required this.commitSha,
    required this.schemaVersion,
    required this.flutterCi,
    required this.flutterMin,
    required this.consumers,
  });

  final String tag;
  final String commitSha;
  final String schemaVersion;
  final String flutterCi;
  final String flutterMin;
  final String consumers;

  /// tag 之后才能定的格子是否还是占位符。
  bool get hasPending =>
      commitSha == pendingSha || consumers == pendingConsumers;

  /// 按 docs/compat-matrix.md 现行体例渲染：tag / SHA / Flutter 最低支持带反引号。
  String render() =>
      '| `$tag` | `$commitSha` | $schemaVersion | $flutterCi '
      '| `$flutterMin` | $consumers |';
}

/// 本仓发版使用的 SemVer；RC 与正式版本走同一条定版链。
final class Version implements Comparable<Version> {
  const Version(
    this.major,
    this.minor,
    this.patch, {
    this.prerelease,
    this.build,
  });

  static final RegExp _pattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  static Version? tryParse(String text) {
    final RegExpMatch? match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    return Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      prerelease: match.group(4),
      build: match.group(5),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;
  final String? build;

  /// `^X.Y.Z` 的上界：0.x 走 minor 边界，其余走 major 边界。
  Version get caretUpperBound =>
      major == 0 ? Version(0, minor + 1, 0) : Version(major + 1, 0, 0);

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    final String? left = prerelease;
    final String? right = other.prerelease;
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    final List<String> leftParts = left.split('.');
    final List<String> rightParts = right.split('.');
    for (
      var index = 0;
      index < leftParts.length && index < rightParts.length;
      index += 1
    ) {
      final String leftPart = leftParts[index];
      final String rightPart = rightParts[index];
      if (leftPart == rightPart) continue;
      final int? leftNumber = int.tryParse(leftPart);
      final int? rightNumber = int.tryParse(rightPart);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      return leftPart.compareTo(rightPart);
    }
    return leftParts.length.compareTo(rightParts.length);
  }

  @override
  String toString() =>
      '$major.$minor.$patch'
      '${prerelease == null ? '' : '-$prerelease'}'
      '${build == null ? '' : '+$build'}';
}

/// CHANGELOG 相对某个目标版本的状态。
final class ChangelogState {
  const ChangelogState({
    required this.hasUnreleased,
    required this.releaseDate,
    required this.releaseIsNewest,
  });

  /// 是否还留着 `## Unreleased` 段。打完 tag 的 CHANGELOG 不留（见 0.2.0 / 0.2.1 tag）。
  final bool hasUnreleased;

  /// 目标版本段的日期；没有该段则为 null。
  final String? releaseDate;

  /// 目标版本段是否是最靠前的 `## ` 段（本表新版本在上）。
  final bool releaseIsNewest;

  bool get released => releaseDate != null;
}

/// 一条已经通过文件名、UTF-8 与 Markdown 结构校验的 CHANGELOG 碎片。
final class ChangelogFragment {
  const ChangelogFragment({
    required this.fileName,
    required this.type,
    required this.content,
  });

  final String fileName;
  final String type;
  final String content;
}

final class FragmentScan {
  const FragmentScan({
    required this.version,
    required this.fragments,
    required this.fragmentPaths,
    required this.errors,
  });

  final String version;
  final List<ChangelogFragment> fragments;
  final List<String> fragmentPaths;
  final List<String> errors;
}

final class LockBlock {
  const LockBlock({
    required this.name,
    required this.source,
    required this.version,
    required this.versionLine,
  });

  final String name;
  final String? source;
  final String? version;
  final int versionLine;
}
