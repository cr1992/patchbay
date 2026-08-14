/// Release-version drift guard.
///
/// The four package manifests are the version source of truth. Each root README
/// repeats that value in one status line and two copy-pasteable Git refs; those
/// repetitions are intentional for usability, so CI must keep them aligned.
///
/// There are two root READMEs — the English `README.md` and the Chinese
/// `README.zh-CN.md`. Both repeat the version, so both are checked; guarding
/// only one would let the other drift silently, which is exactly the failure
/// this guard exists to prevent. The status line is the only language-dependent
/// anchor, so it is passed in per file; the two Git refs are language-neutral.
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
final RegExp _readmeFlutterRef = RegExp(
  r'^\s*ref:\s*patchbay-v([^\s]+)\s*$',
  multiLine: true,
);
final RegExp _readmeCliRef = RegExp(r'--git-ref\s+patchbay-v([^\s]+)');

String? _firstCapture(RegExp pattern, String source) =>
    pattern.firstMatch(source)?.group(1);

List<String> checkReleaseVersionParity({
  required Map<String, String> pubspecs,
  required String readme,
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
    'Flutter Git ref': _firstCapture(_readmeFlutterRef, readme),
    'CLI --git-ref': _firstCapture(_readmeCliRef, readme),
  };
  for (final MapEntry<String, String?> entry in readmeVersions.entries) {
    if (entry.value == null) {
      problems.add('README ${entry.key} 缺失或抽取式已失效');
    } else if (entry.value != expected) {
      problems.add('README ${entry.key} 为 ${entry.value}，四包版本为 $expected');
    }
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
      ref: patchbay-v1.2.3
    --git-ref patchbay-v1.2.3 --git-path packages/patchbay_cli
''';
  const String alignedReadmeEn = '''
> **Project status:** `v1.2.3`
      ref: patchbay-v1.2.3
    --git-ref patchbay-v1.2.3 --git-path packages/patchbay_cli
''';

  group('checkReleaseVersionParity', () {
    test('四包与 README 三处版本一致时通过', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadme,
        ),
        isEmpty,
      );
    });

    test('英文 README 用英文状态式时通过', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: alignedReadmeEn,
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
        ),
        contains(contains('四包版本不一致')),
      );
    });

    test('README 状态或任一安装 ref 漂移时逐项报出', () {
      final List<String> problems = checkReleaseVersionParity(
        pubspecs: alignedPubspecs,
        readme: alignedReadme
            .replaceFirst('`v1.2.3`', '`v1.2.2`')
            .replaceFirst('ref: patchbay-v1.2.3', 'ref: patchbay-v1.2.1')
            .replaceFirst(
              '--git-ref patchbay-v1.2.3',
              '--git-ref patchbay-v1.2.0',
            ),
      );

      expect(problems, hasLength(3));
      expect(problems, contains(contains('项目状态')));
      expect(problems, contains(contains('Flutter Git ref')));
      expect(problems, contains(contains('CLI --git-ref')));
    });

    test('抽取式失效明确判红，不会恒绿', () {
      expect(
        checkReleaseVersionParity(
          pubspecs: <String, String>{
            ...alignedPubspecs,
            'patchbay': 'name: patchbay',
          },
          readme: alignedReadme,
        ),
        contains(contains('version 字段缺失')),
      );
      expect(
        checkReleaseVersionParity(
          pubspecs: alignedPubspecs,
          readme: '# Patchbay',
        ),
        hasLength(3),
      );
    });
  });

  group('真仓文件：四包 version 与两份 README 的状态及安装 refs 一致', () {
    final Map<String, String> pubspecs = <String, String>{
      for (final String path in _pubspecPaths)
        path: File(path).readAsStringSync(),
    };

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
            statusPattern: entry.value,
          ),
          isEmpty,
          reason: 'pubspec.yaml 是版本真源；${entry.key} 的状态与可复制 Git ref 必须随发版同改',
        );
      });
    }
  });
}
