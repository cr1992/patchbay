import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release_prep.dart';
import '../fixture/release_prep_fixtures.dart';

void main() {
  group('pubspec 读写', () {
    test('读版本号并原地改写，且幂等', () {
      const String pubspec = '''
name: patchbay
description: d
version: 0.2.1
publish_to: none

environment:
  sdk: '>=3.11.0 <4.0.0'
''';
      expect(readPubspecVersion(pubspec), '0.2.1');
      final String bumped = applyPubspecVersion(pubspec, '0.3.0');
      expect(readPubspecVersion(bumped), '0.3.0');
      expect(applyPubspecVersion(bumped, '0.3.0'), bumped);
      expect(bumped.replaceAll('0.3.0', '0.2.1'), pubspec);
    });

    test('缺 version 字段时抛，不静默补写', () {
      expect(
        () => applyPubspecVersion('name: patchbay\n', '0.3.0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('publish_to / description / repository 按顶层标量读出', () {
      const String pubspec = '''
name: patchbay
description: Consumer-neutral primitives.
version: 0.3.0
repository: https://example.invalid/repo
''';
      expect(readPubspecField(pubspec, 'publish_to'), isNull);
      expect(
        readPubspecField(pubspec, 'description'),
        'Consumer-neutral primitives.',
      );
      expect(
        readPubspecField(pubspec, 'repository'),
        'https://example.invalid/repo',
      );
    });

    test('path 依赖能认出来，hosted 约束不会误报', () {
      const String withPath = '''
name: patchbay_cli
dependencies:
  args: ^2.7.0
  patchbay:
    path: ../patchbay
  patchbay_transport:
    path: ../patchbay_transport
''';
      expect(readPathDependencies(withPath), <String>{
        'patchbay',
        'patchbay_transport',
      });
      expect(readInternalConstraints(withPath), isEmpty);

      const String hosted = '''
name: patchbay_cli
dependencies:
  args: ^2.7.0
  patchbay: ^0.3.0
  patchbay_transport: ^0.3.0
''';
      expect(readPathDependencies(hosted), isEmpty);
      expect(readInternalDependencies(hosted), <String>{
        'patchbay',
        'patchbay_transport',
      });
      expect(readInternalConstraints(hosted), <String, String>{
        'patchbay': '^0.3.0',
        'patchbay_transport': '^0.3.0',
      });
    });

    test('environment 的 flutter 约束不被 dependencies 里的 flutter 块顶掉', () {
      const String pubspec = '''
name: patchbay_flutter
environment:
  sdk: '>=3.11.0 <4.0.0'
  flutter: '>=3.38.0'

dependencies:
  flutter:
    sdk: flutter
''';
      expect(readFlutterConstraint(pubspec), '>=3.38.0');
    });
  });

  group('随版版本引用', () {
    test('常量只改版本值且幂等，缺失或重复时拒绝', () {
      const String source =
          "// keep\nconst String patchbayPackageVersion = '0.2.1';\n// tail\n";
      final String bumped = applyPackageVersionSource(source, '0.3.0');
      expect(
        bumped,
        "// keep\nconst String patchbayPackageVersion = '0.3.0';\n// tail\n",
      );
      expect(applyPackageVersionSource(bumped, '0.3.0'), bumped);
      expect(
        () => applyPackageVersionSource('// missing\n', '0.3.0'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => applyPackageVersionSource('$source$source', '0.3.0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('根 README 只同步 hosted 安装与 AOT 受管锚点，其他版本文本原样保留', () {
      const String readme = '''
> **Project status:** `v0.2.1`, keep
historical patchbay-v0.1.0 stays
  patchbay_flutter: ^0.2.1
curl /releases/download/patchbay-v0.2.1/patchbay-0.2.1-macos-arm64
\$ dart pub global activate patchbay_cli 0.2.1
''';
      final String bumped = applyReadmeVersionReferences(readme, '0.3.0');
      expect(bumped, contains('`v0.3.0`'));
      expect(bumped, contains('patchbay_flutter: ^0.3.0'));
      expect(bumped, contains('/patchbay-v0.3.0/patchbay-0.3.0-macos-arm64'));
      expect(bumped, contains('activate patchbay_cli 0.3.0'));
      expect(bumped, contains('historical patchbay-v0.1.0 stays'));
      expect(applyReadmeVersionReferences(bumped, '0.3.0'), bumped);
    });

    test('README AOT 文件名完整识别 prerelease SemVer，不在连字符处截断', () {
      const String readme = '''
> **Project status:** `v0.3.0`, keep
  patchbay_flutter: ^0.3.0
curl /releases/download/patchbay-v0.3.0/patchbay-0.3.0-macos-arm64
\$ dart pub global activate patchbay_cli 0.3.0
''';

      final String bumped = applyReadmeVersionReferences(readme, '0.4.0-rc.1');

      expect(bumped, contains('`v0.4.0-rc.1`'));
      expect(bumped, contains('patchbay_flutter: ^0.4.0-rc.1'));
      expect(
        bumped,
        contains('/patchbay-v0.4.0-rc.1/patchbay-0.4.0-rc.1-macos-arm64'),
      );
      expect(bumped, contains('activate patchbay_cli 0.4.0-rc.1'));
      expect(applyReadmeVersionReferences(bumped, '0.4.0-rc.1'), bumped);
    });

    test('guide 与 CLI README 使用各自的 hosted 版本锚点', () {
      const String guide = '''
  patchbay_flutter: ^0.3.0
\$ dart pub global activate patchbay_cli 0.3.0
curl /releases/download/patchbay-v0.3.0/patchbay-0.3.0-linux-x64
\$ shasum -a 256 patchbay-0.2.1-linux-x64
\$ chmod +x patchbay-0.2.1-linux-x64
\$ mv patchbay-0.2.1-linux-x64 patchbay
''';
      final String bumpedGuide = applyReleaseDocumentVersionReferences(
        'docs/guide.md',
        guide,
        '0.4.0',
      );
      expect(bumpedGuide, contains('patchbay_flutter: ^0.4.0'));
      expect(bumpedGuide, contains('activate patchbay_cli 0.4.0'));
      expect(bumpedGuide, contains('/patchbay-v0.4.0/patchbay-0.4.0-linux'));
      expect(bumpedGuide, isNot(contains('patchbay-0.2.1-linux-x64')));
      expect(
        RegExp('patchbay-0.4.0-linux-x64').allMatches(bumpedGuide),
        hasLength(4),
      );

      const String cli = '\$ dart pub global activate patchbay_cli 0.3.0\n';
      expect(
        applyReleaseDocumentVersionReferences(
          'packages/patchbay_cli/README.md',
          cli,
          '0.4.0',
        ),
        '\$ dart pub global activate patchbay_cli 0.4.0\n',
      );
    });

    test('README 受管锚点缺失时拒绝，不静默放过结构漂移', () {
      expect(
        () => applyReadmeVersionReferences('# Patchbay\n', '0.3.0'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('协议兼容语料', () {
    test('从 host surface 唯一真源拆出 identity / catalog 并落入版本目录', () {
      final Map<String, String> fixtures = renderCompatibilityFixtures(
        '0.4.0-rc.1',
        hostSurfaceFixture('0.3.0'),
      );

      expect(fixtures.keys, <String>{
        'legacy_host_v0_4_0-rc_1/identity.json',
        'legacy_host_v0_4_0-rc_1/catalog.json',
      });
      expect(jsonDecode(fixtures.values.first)['serverVersion'], '0.4.0-rc.1');
      expect(
        jsonDecode(
          fixtures['legacy_host_v0_4_0-rc_1/catalog.json']!,
        )['catalogDigest'],
        isA<Map<String, Object?>>(),
      );
      expect(
        renderCompatibilityFixtures('0.4.0-rc.1', hostSurfaceFixture('0.3.0')),
        fixtures,
      );

      expect(
        renderCompatibilityCorpusReadme('0.4.0'),
        contains(frozenCorpusMarker),
      );
      expect(renderCompatibilityCorpusReadme('0.4.0-rc.1'), isNull);
    });

    test('source golden 缺面或版本来源漂移时拒绝，不伪造语料', () {
      expect(
        () => renderCompatibilityFixtures('0.4.0', '{}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => renderCompatibilityFixtures(
          '0.4.0',
          hostSurfaceFixture(
            '0.3.0',
          ).replaceFirst('<patchbayPackageVersion>', '手写版本'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('根 CHANGELOG 里每个已发布版本的语料目录都必须带冻结标记', () {
      final String root = repoRoot();
      final List<String> released =
          RegExp(r'^## (\d+\.\d+\.\d+\S*) - ', multiLine: true)
              .allMatches(File('$root/$changelogPath').readAsStringSync())
              .map((match) => match.group(1)!)
              .toList(growable: false);

      expect(released, isNotEmpty, reason: '根 CHANGELOG 应至少有一个已发布版本');

      for (final String version in released) {
        final Directory corpus = Directory(
          '$root/$compatibilityCorpusPath/${compatibilityCorpusDirectory(version)}',
        );
        if (!corpus.existsSync()) continue;
        final File readme = File('${corpus.path}/README.md');
        expect(
          readme.existsSync(),
          isTrue,
          reason: '${corpus.path} 缺 README.md，无法声明冻结',
        );
        expect(
          readme.readAsStringSync(),
          contains(frozenCorpusMarker),
          reason: '$version 已发布，${corpus.path} 必须带 $frozenCorpusMarker 标记',
        );
      }
    });
  });

  group('caret 约束', () {
    test('0.x 走 minor 边界，1.x 走 major 边界', () {
      final Version zeroThreeOne = Version.tryParse('0.3.1')!;
      expect(caretAdmits('^0.3.0', zeroThreeOne), isTrue);
      expect(caretAdmits('^0.3.0', Version.tryParse('0.4.0')!), isFalse);
      expect(caretAdmits('^0.2.0', zeroThreeOne), isFalse);
      expect(caretAdmits('^1.2.0', Version.tryParse('1.9.9')!), isTrue);
      expect(caretAdmits('^1.2.0', Version.tryParse('2.0.0')!), isFalse);
    });

    test('不是 caret 形式就交人工，不猜', () {
      expect(caretAdmits('>=0.3.0 <0.4.0', Version.tryParse('0.3.0')!), isNull);
      expect(caretAdmits('any', Version.tryParse('0.3.0')!), isNull);
    });

    test('接受正式与 prerelease/build SemVer，拒绝缺段或 v 前缀', () {
      expect(Version.tryParse('0.3'), isNull);
      expect(Version.tryParse('v0.3.0'), isNull);
      expect(Version.tryParse('0.3.0-beta').toString(), '0.3.0-beta');
      expect(
        Version.tryParse('0.4.0-rc.1+build.7').toString(),
        '0.4.0-rc.1+build.7',
      );
      expect(Version.tryParse('0.3.0').toString(), '0.3.0');
    });

    test('prerelease 按 SemVer 排序且低于同核正式版本', () {
      expect(
        Version.tryParse(
          '0.4.0-rc.1',
        )!.compareTo(Version.tryParse('0.4.0-rc.2')!),
        isNegative,
      );
      expect(
        Version.tryParse('0.4.0-rc.2')!.compareTo(Version.tryParse('0.4.0')!),
        isNegative,
      );
    });

    test('约束不接纳目标版本才改写，接纳则原样（0.3.1 不动 ^0.3.0）', () {
      const String pubspec = '''
name: patchbay_cli
dependencies:
  args: ^2.7.0
  patchbay: ^0.2.0
  patchbay_transport: ^0.2.0
''';
      final String bumped = applyInternalConstraints(pubspec, '0.3.0');
      expect(readInternalConstraints(bumped), <String, String>{
        'patchbay': '^0.3.0',
        'patchbay_transport': '^0.3.0',
      });
      expect(bumped, contains('  args: ^2.7.0'));
      expect(applyInternalConstraints(bumped, '0.3.0'), bumped);
      expect(applyInternalConstraints(bumped, '0.3.1'), bumped);
      expect(
        readInternalConstraints(applyInternalConstraints(bumped, '0.4.0')),
        <String, String>{'patchbay': '^0.4.0', 'patchbay_transport': '^0.4.0'},
      );
    });
  });

  group('本地 overrides', () {
    test('渲染与回读对得上，条目按字母序', () {
      final String rendered = renderOverrides(<String, String>{
        'patchbay_transport': '../patchbay_transport',
        'patchbay': '../patchbay',
      });
      expect(
        rendered.indexOf('patchbay:'),
        lessThan(rendered.indexOf('patchbay_transport:')),
      );
      expect(readPathOverrides(rendered), <String, String>{
        'patchbay': '../patchbay',
        'patchbay_transport': '../patchbay_transport',
      });
      expect(readPathOverrides(null), isEmpty);
    });

    test('还是 path 依赖时不要求 overrides——那时本来就解析到工作树', () {
      expect(expectedOverrides(releaseInputsFixture()), isEmpty);
    });

    test('改成 hosted 约束后，三处都要 override（含 example 的传递依赖）', () {
      expect(
        expectedOverrides(releaseInputsFixture(publishable: true)),
        <String, Object>{
          'packages/patchbay_cli/pubspec_overrides.yaml': <String, String>{
            'patchbay': '../patchbay',
            'patchbay_transport': '../patchbay_transport',
          },
          'packages/patchbay_flutter/pubspec_overrides.yaml': <String, String>{
            'patchbay': '../patchbay',
          },
          'packages/patchbay_flutter/example/pubspec_overrides.yaml':
              <String, String>{'patchbay': '../../patchbay'},
        },
      );
    });
  });

  group('发布顺序', () {
    test('按依赖拓扑排序，同层字母序', () {
      final List<String> order = publishOrder(<String, Set<String>>{
        'patchbay': <String>{},
        'patchbay_transport': <String>{},
        'patchbay_cli': <String>{'patchbay', 'patchbay_transport'},
        'patchbay_flutter': <String>{'patchbay'},
      });
      expect(order, <String>[
        'patchbay',
        'patchbay_transport',
        'patchbay_cli',
        'patchbay_flutter',
      ]);
    });

    test('依赖方向变了顺序跟着变——顺序是推出来的不是写死的', () {
      final List<String> order = publishOrder(<String, Set<String>>{
        'patchbay': <String>{'patchbay_transport'},
        'patchbay_transport': <String>{},
      });
      expect(order, <String>['patchbay_transport', 'patchbay']);
    });

    test('成环时拒绝给顺序', () {
      expect(
        () => publishOrder(<String, Set<String>>{
          'a': <String>{'b'},
          'b': <String>{'a'},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
