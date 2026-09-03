// release_prep 仓内坐标与常量定义。

/// tag 命名前缀，见 CONTRIBUTING.md「发版」。
const String tagPrefix = 'patchbay-v';

/// 兼容矩阵里「tag 之后才能填」的占位符。check 在 tag 已存在时会盯着它转红。
const String pendingSha = '待回填';

/// 兼容矩阵 consumer 列的占位符：patchbay 仓不持有 consumer 侧 pin，必须人工核实。
const String pendingConsumers = '待确认';

/// 四个随 tag 同步定版的包。example 不在其列——它不发布，只跟着刷 lock 与 overrides。
const List<String> releasePackages = <String>[
  'patchbay',
  'patchbay_cli',
  'patchbay_flutter',
  'patchbay_transport',
];

/// pub 发布的 error 级要求：缺了直接「can't be published」。
const List<String> requiredPackageFiles = <String>['LICENSE'];

/// pub 发布的 warning 级要求。实测 `--dry-run` 有 warning 即退 65，故与 error 同等对待。
const List<String> advisedPackageFiles = <String>['README.md', 'CHANGELOG.md'];

/// pub 对 `description` 的长度区间（字符数），越界即 warning。
const int descriptionMinLength = 60;
const int descriptionMaxLength = 180;

String pubspecPathOf(String package) => 'packages/$package/pubspec.yaml';

String overridesPathOf(String package) =>
    'packages/$package/pubspec_overrides.yaml';

String packageChangelogPathOf(String package) =>
    'packages/$package/CHANGELOG.md';

/// 公开镜像上「按仓根相对路径取文件」的前缀。
///
/// 分支钉 `main` 而不是 tag：与 README 语言切换行同口径（见 !38），也和 dio 等主流包一致。
const String repoBlobPrefix = 'https://github.com/cr1992/patchbay/blob/main/';

const String changelogPath = 'CHANGELOG.md';
const String changelogFragmentsPath = 'changelog.d';
const String examplePath = 'packages/patchbay_flutter/example';
const String examplePubspecPath = '$examplePath/pubspec.yaml';
const String exampleOverridesPath = '$examplePath/pubspec_overrides.yaml';
const String exampleLockPath = '$examplePath/pubspec.lock';
const String compatMatrixPath = 'docs/compat-matrix.md';
const String hostSurfaceGoldenPath =
    'packages/patchbay/test/golden/host_surface.json';
const String compatibilityCorpusPath = 'packages/patchbay_cli/test/golden';
const String packageVersionSourcePath =
    'packages/patchbay/lib/src/version.dart';

/// 对外文档中的「当前版本」入口。发版时只改这些文件里的受管版本锚点。
const List<String> releaseVersionDocumentPaths = <String>[
  'README.md',
  'README.zh-CN.md',
  'docs/guide.md',
  'packages/patchbay_cli/README.md',
  'packages/patchbay_cli/README.zh-CN.md',
];

/// 对外当前事实面。历史版本只允许留在 releases / proposals / changelog / 兼容语料中。
const List<String> activePublicDocumentPaths = <String>[
  ...releaseVersionDocumentPaths,
  'packages/patchbay/README.md',
  'packages/patchbay/README.zh-CN.md',
  'packages/patchbay_transport/README.md',
  'packages/patchbay_transport/README.zh-CN.md',
  'packages/patchbay_flutter/README.md',
  'packages/patchbay_flutter/README.zh-CN.md',
  'packages/patchbay_flutter/example/README.md',
  'packages/patchbay_flutter/example/README.zh-CN.md',
  'docs/candidate-validation.md',
  'docs/design.md',
  'docs/assets/patchbay-hero.svg',
  'docs/assets/patchbay-architecture.svg',
  'docs/assets/patchbay-cli-workflows.svg',
];
const String serviceHostPath = 'packages/patchbay/lib/src/service_host.dart';
const String invocationPath = 'packages/patchbay/lib/src/invocation.dart';
const String workflowPath = '.github/workflows/ci.yml';

/// 正式发布必须打到 pub.dev。本机常把 `PUB_HOSTED_URL` 指向镜像，那会把 `pub publish`
/// 也一起指过去，所以打印出来的发布命令显式带上 host。
const String canonicalPubHost = 'https://pub.dev';

/// 语料 README 里声明「这一版已经冻结」的机读标记。
const String frozenCorpusMarker = 'patchbay:frozen-corpus';
