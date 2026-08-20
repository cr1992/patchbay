/// Release-version drift guard.
///
/// The four package manifests are the version source of truth. Each root README
/// repeats that value in one status line and two copy-pasteable hosted installs; those
/// repetitions are intentional for usability, so CI must keep them aligned.
///
/// There are two root READMEs — the English `README.md` and the Chinese
/// `README.zh-CN.md`. Both repeat the version, so both are checked; guarding
/// only one would let the other drift silently, which is exactly the failure
/// this guard exists to prevent. The status line is the only language-dependent
/// anchor, so it is passed in per file; the two install anchors are language-neutral.
///
/// `patchbayPackageVersion` is the repetition with teeth. The others misprint a
/// document when they drift; this one is served to clients as `serverVersion`,
/// so a stale constant makes every App in the field report a build it is not —
/// and a host lying about itself is worse than one that never reported. Like
/// the install anchors it is language-neutral, so it is checked on every call rather
/// than per README.
library;

import 'dart:io';

import 'package:test/test.dart';

final RegExp _pubspecVersion = RegExp(
  r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)\s*$',
  multiLine: true,
);
final RegExp _readmeStatusVersionZh = RegExp(r'\*\*项目状态：\*\*\s*`v([^`]+)`');
final RegExp _readmeStatusVersionEn = RegExp(
  r'\*\*Project status:\*\*\s*`v([^`]+)`',
);
final RegExp _readmeFlutterVersion = RegExp(
  r'^\s*patchbay_flutter:\s*\^([^\s]+)\s*$',
  multiLine: true,
);
final RegExp _readmeCliVersion = RegExp(
  r'^\$ dart pub global activate patchbay_cli\s+([^\s]+)\s*$',
  multiLine: true,
);
final RegExp _packageVersionConstant = RegExp(
  r"const\s+String\s+patchbayPackageVersion\s*=\s*'([^']+)'",
);

String? _firstCapture(RegExp pattern, String source) =>
    pattern.firstMatch(source)?.group(1);

List<String> checkReleaseVersionParity({
  required Map<String, String> pubspecs,
  required String readme,
  required String versionSource,
  RegExp? statusPattern,
}) {
  final Map<String, String> versions = <String, String>{};
  final List<String> problems = <String>[];

  for (final MapEntry<String, String> entry in pubspecs.entries) {
    final String? version = _firstCapture(_pubspecVersion, entry.value);
    if (version == null) {
      problems.add('${entry.key}: version 字段缺失或不是受支持的 semver');
    } else {
      versions[entry.key] = version;
    }
  }
  if (problems.isNotEmpty) return problems;

  final Set<String> distinct = versions.values.toSet();
  if (distinct.length != 1) {
    problems.add('四包版本不一致：$versions');
    return problems;
  }
  final String expected = distinct.single;

  final Map<String, String?> readmeVersions = <String, String?>{
    '项目状态': _firstCapture(statusPattern ?? _readmeStatusVersionZh, readme),
    'Flutter hosted 版本': _firstCapture(_readmeFlutterVersion, readme),
    'CLI hosted 版本': _firstCapture(_readmeCliVersion, readme),
  };
  for (final MapEntry<String, String?> entry in readmeVersions.entries) {
    if (entry.value == null) {
      problems.add('README ${entry.key} 缺失或抽取式已失效');
    } else if (entry.value != expected) {
      problems.add('README ${entry.key} 为 ${entry.value}，四包版本为 $expected');
    }
  }

  final String? constant = _firstCapture(
    _packageVersionConstant,
    versionSource,
  );
  if (constant == null) {
    problems.add('patchbayPackageVersion 常量缺失或抽取式已失效');
  } else if (constant != expected) {
    problems.add(
      'patchbayPackageVersion 为 $constant，四包版本为 $expected；'
      'host 把它当 serverVersion 报给客户端，漂移即全网 App 谎报自己的构建',
    );
  }
  return problems;
}

const List<String> _pubspecPaths = <String>[
  'pubspec.yaml',
  '../patchbay_cli/pubspec.yaml',
  '../patchbay_flutter/pubspec.yaml',
  '../patchbay_transport/pubspec.yaml',
];

/// Both root READMEs, each with the status-line anchor for its language.
final Map<String, RegExp> _readmePaths = <String, RegExp>{
  '../../README.md': _readmeStatusVersionEn,
  '../../README.zh-CN.md': _readmeStatusVersionZh,
};

const String _versionSourcePath = 'lib/src/version.dart';

void main() {
  const String version = 'version: 1.2.3';
  const Map<String, String> alignedPubspecs = <String, String>{
    'patchbay': version,
    'patchbay_cli': version,
    'patchbay_flutter': version,
    'patchbay_transport': version,
  };
  const String alignedReadme = '''
> **项目状态：** `v1.2.3`
  patchbay_flutter: ^1.2.3
\$ dart pub global activate patchbay_cli 1.2.3
''';
  const String alignedReadmeEn = '''
> **Project status:** `v1.2.3`
  patchbay_flutter: ^1.2.3
\$ dart pub global activate patchbay_cli 1.2.3
''';
  const String alignedVersionSource =
      "const String patchbayPackageVersion = '1.2.3';";

  group('checkReleaseVersionParity', () {
    test('四包与 README 三处版本一致时通过', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadme,
          versionSource: alignedVersionSource,
        ),
        isEmpty,
      );
    });

    test('英文 README 用英文状态式时通过', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadmeEn,
          versionSource: alignedVersionSource,
          statusPattern: _readmeStatusVersionEn,
        ),
        isEmpty,
      );
    });

    test('英文 README 状态行漂移时判红', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadmeEn.replaceFirst('`v1.2.3`', '`v1.2.2`'),
          versionSource: alignedVersionSource,
          statusPattern: _readmeStatusVersionEn,
        ),
        contains(contains('项目状态')),
      );
    });

    test('语言与状态式不匹配时判红，不会因为读不到就放行', () {
      // 英文 README 配中文状态式：抽取不到 = 判红，而不是恒绿。
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadmeEn,
          versionSource: alignedVersionSource,
          statusPattern: _readmeStatusVersionZh,
        ),
        contains(contains('项目状态')),
      );
    });

    test('任一 package 漂移时判红', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: <String, String>{
            ...alignedPubspecs,
            'patchbay_cli': 'version: 1.2.4',
          },
          readme: alignedReadme,
          versionSource: alignedVersionSource,
        ),
        contains(contains('四包版本不一致')),
      );
    });

    test('README 状态或任一 hosted 安装版本漂移时逐项报出', () {
      final List<String> problems = checkReleaseVersionParity(
        pubspecs: alignedPubspecs,
        versionSource: alignedVersionSource,
        readme: alignedReadme
            .replaceFirst('`v1.2.3`', '`v1.2.2`')
            .replaceFirst(
              'patchbay_flutter: ^1.2.3',
              'patchbay_flutter: ^1.2.1',
            )
            .replaceFirst(
              'activate patchbay_cli 1.2.3',
              'activate patchbay_cli 1.2.0',
            ),
      );

      expect(problems, hasLength(3));
      expect(problems, contains(contains('项目状态')));
      expect(problems, contains(contains('Flutter hosted 版本')));
      expect(problems, contains(contains('CLI hosted 版本')));
    });

    test('抽取式失效明确判红，不会恒绿', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: <String, String>{
            ...alignedPubspecs,
            'patchbay': 'name: patchbay',
          },
          readme: alignedReadme,
          versionSource: alignedVersionSource,
        ),
        contains(contains('version 字段缺失')),
      );
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: '# Patchbay',
          versionSource: alignedVersionSource,
        ),
        hasLength(3),
      );
    });

    test('patchbayPackageVersion 漂移时判红', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadme,
          versionSource: "const String patchbayPackageVersion = '1.2.2';",
        ),
        contains(contains('patchbayPackageVersion 为 1.2.2')),
      );
    });

    test('patchbayPackageVersion 抽取式失效判红而不是恒绿', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadme,
          versionSource: '// 常量被改名或删了',
        ),
        contains(contains('patchbayPackageVersion 常量缺失')),
      );
    });

    test('README 与常量同时漂移时两条都报出，不互相掩盖', () {
      // 两个维度各自独立：README 判红不能让常量检查被提前 return 跳过，反之亦然。
      // 合并两个扩展时最容易在这里出错，所以单独钉一条。
      final List<String> problems = checkReleaseVersionParity(
        pubspecs: alignedPubspecs,
        readme: alignedReadme.replaceFirst('`v1.2.3`', '`v1.2.2`'),
        versionSource: "const String patchbayPackageVersion = '1.2.1';",
      );

      expect(problems, contains(contains('项目状态')));
      expect(problems, contains(contains('patchbayPackageVersion 为 1.2.1')));
    });
  });

  group('真仓文件：四包 version 与两份 README、serverVersion 常量一致', () {
    final Map<String, String> pubspecs = <String, String>{
      for (final String path in _pubspecPaths)
        path: File(path).readAsStringSync(),
    };
    final String versionSource = File(_versionSourcePath).readAsStringSync();

    for (final MapEntry<String, RegExp> entry in _readmePaths.entries) {
      test(entry.key, () {
        final File readme = File(entry.key);
        expect(
          readme.existsSync(),
          isTrue,
          reason: '${entry.key} 不存在——语言版本被删或改名时这条必须先红',
        );

        expect(
          checkReleaseVersionParity(
            pubspecs: pubspecs,
            readme: readme.readAsStringSync(),
            versionSource: versionSource,
            statusPattern: entry.value,
          ),
          isEmpty,
          reason:
              'pubspec.yaml 是版本真源；${entry.key} 的状态与可复制 hosted 安装版本、以及 host 报给'
              '客户端的 patchbayPackageVersion 必须随发版同改',
        );
      });
    }
  });
}
