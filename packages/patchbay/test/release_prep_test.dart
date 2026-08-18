import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/release_prep.dart';

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
      // 只动 version 行，其余原样。
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
      // 第三方依赖不进随版约束表。
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

    test('README 只同步四个受管锚点，其他版本文本原样保留', () {
      const String readme = '''
> **Project status:** `v0.2.1`, keep
historical patchbay-v0.1.0 stays
      ref: patchbay-v0.2.1
curl /releases/download/patchbay-v0.2.1/patchbay-0.2.1-macos-arm64
--git-ref patchbay-v0.2.1 --git-path packages/patchbay_cli
''';
      final String bumped = applyReadmeVersionReferences(readme, '0.3.0');
      expect(bumped, contains('`v0.3.0`'));
      expect(bumped, contains('ref: patchbay-v0.3.0'));
      expect(bumped, contains('/patchbay-v0.3.0/patchbay-0.3.0-macos-arm64'));
      expect(bumped, contains('--git-ref patchbay-v0.3.0'));
      expect(bumped, contains('historical patchbay-v0.1.0 stays'));
      expect(applyReadmeVersionReferences(bumped, '0.3.0'), bumped);
    });

    test('README AOT 文件名完整识别 prerelease SemVer，不在连字符处截断', () {
      const String readme = '''
> **Project status:** `v0.3.0`, keep
      ref: patchbay-v0.3.0
curl /releases/download/patchbay-v0.3.0/patchbay-0.3.0-macos-arm64
--git-ref patchbay-v0.3.0 --git-path packages/patchbay_cli
''';

      final String bumped = applyReadmeVersionReferences(readme, '0.4.0-rc.1');

      expect(bumped, contains('`v0.4.0-rc.1`'));
      expect(bumped, contains('ref: patchbay-v0.4.0-rc.1'));
      expect(
        bumped,
        contains('/patchbay-v0.4.0-rc.1/patchbay-0.4.0-rc.1-macos-arm64'),
      );
      expect(bumped, contains('--git-ref patchbay-v0.4.0-rc.1'));
      expect(applyReadmeVersionReferences(bumped, '0.4.0-rc.1'), bumped);
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
        _hostSurface('0.3.0'),
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
        renderCompatibilityFixtures('0.4.0-rc.1', _hostSurface('0.3.0')),
        fixtures,
      );
    });

    test('source golden 缺面或版本来源漂移时拒绝，不伪造语料', () {
      expect(
        () => renderCompatibilityFixtures('0.4.0', '{}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => renderCompatibilityFixtures(
          '0.4.0',
          _hostSurface(
            '0.3.0',
          ).replaceFirst('<patchbayPackageVersion>', '手写版本'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    // 已发布版本的协议面是历史事实。语料目录漏掉冻结标记时，`release_prep --version <旧版>`
    // 会拿今天的 host 重新渲染并报漂移，`--apply` 会直接覆写——0.3.0 的语料就这样在 0.4.0
    // 开发期间进入过可被覆写的状态。这条用例把「已发布 = 必须带标记」钉在仓内事实上，
    // 让下一版发布后漏补标记直接变成红灯。
    test('根 CHANGELOG 里每个已发布版本的语料目录都必须带冻结标记', () {
      final String root = _repoRoot();
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
      // 第三方依赖零漂移。
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
      expect(expectedOverrides(_inputs()), isEmpty);
    });

    test('改成 hosted 约束后，三处都要 override（含 example 的传递依赖）', () {
      expect(expectedOverrides(_inputs(publishable: true)), <String, Object>{
        'packages/patchbay_cli/pubspec_overrides.yaml': <String, String>{
          'patchbay': '../patchbay',
          'patchbay_transport': '../patchbay_transport',
        },
        'packages/patchbay_flutter/pubspec_overrides.yaml': <String, String>{
          'patchbay': '../patchbay',
        },
        // example 只 path 依赖 patchbay_flutter，patchbay 是隔一层的 hosted 依赖。
        'packages/patchbay_flutter/example/pubspec_overrides.yaml':
            <String, String>{'patchbay': '../../patchbay'},
      });
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

  group('CHANGELOG 落款', () {
    const String changelog = '''
# Changelog

说明行。

## Unreleased

### Added

- 某条。

## 0.2.1 - 2026-08-14

正文。
''';

    test('Unreleased 落款成版本段，且保留标题后的空行', () {
      final String applied = applyChangelogRelease(
        changelog,
        '0.3.0',
        '2026-08-20',
      );
      expect(applied, contains('## 0.3.0 - 2026-08-20\n\n### Added'));
      expect(applied, isNot(contains('## Unreleased')));
      // 0.2.1 段原样保留，本表历史不被改写。
      expect(applied, contains('## 0.2.1 - 2026-08-14'));

      final ChangelogState state = readChangelogState(applied, '0.3.0');
      expect(state.released, isTrue);
      expect(state.releaseDate, '2026-08-20');
      expect(state.hasUnreleased, isFalse);
      expect(state.releaseIsNewest, isTrue);
    });

    test('已落款则原样返回（apply 幂等）', () {
      final String once = applyChangelogRelease(
        changelog,
        '0.3.0',
        '2026-08-20',
      );
      expect(applyChangelogRelease(once, '0.3.0', '2026-08-20'), once);
    });

    test('既无 Unreleased 也无目标版本段时抛，不代造段落', () {
      expect(
        () => applyChangelogRelease(
          '# Changelog\n\n## 0.2.1 - 2026-08-14\n',
          '0.3.0',
          '2026-08-20',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('版本段不在最前时能判出来', () {
      const String outOfOrder = '''
# Changelog

## 0.2.1 - 2026-08-14

## 0.3.0 - 2026-08-20
''';
      expect(readChangelogState(outOfOrder, '0.3.0').releaseIsNewest, isFalse);
    });
  });

  group('CHANGELOG 碎片', () {
    ChangelogFragment fragment(String name, String content) =>
        parseChangelogFragment(name, utf8.encode(content));

    test('文件名严格遵守 change-id、part 与 type 的封闭格式', () {
      expect(fragment('PB-040-20.cli.added.md', '- 新增命令。').type, 'added');
      expect(fragment('BUG-20260817-01.fixed.md', '- 修复缺陷。').type, 'fixed');
      for (final String invalid in <String>[
        '40.added.md',
        'PB-40-20.added.md',
        'PB-040-20.CLI.added.md',
        'PB-040-20.unknown.md',
        'PB-040-20.added.markdown',
      ]) {
        expect(
          () => fragment(invalid, '- 内容。'),
          throwsA(isA<FormatException>()),
          reason: invalid,
        );
      }
    });

    test('拒绝空正文、非法 UTF-8 与多个顶层项，允许缩进续段', () {
      expect(
        () => fragment('PB-040-20.added.md', '   '),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseChangelogFragment('PB-040-20.added.md', <int>[0xff]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => fragment('PB-040-20.added.md', '- 第一条。\n- 第二条。'),
        throwsA(isA<FormatException>()),
      );
      expect(
        fragment(
          'PB-040-20.added.md',
          '- **Breaking:** 改变行为。\n  请先迁移。',
        ).content,
        contains('请先迁移'),
      );
    });

    test('按类型固定顺序建栏目，同栏目按文件名升序且保留已有正文', () {
      const String root = '''
# Changelog

## Unreleased

### Added

- 已有条目。

## 0.2.1 - 2026-08-14

- 历史。
''';
      final String aggregated =
          aggregateChangelogFragments(root, <ChangelogFragment>[
            fragment('PB-040-20.z.fixed.md', '- Z 修复。'),
            fragment('PB-040-20.changed.md', '- 行为变化。'),
            fragment('PB-040-20.b.added.md', '- B 新增。'),
            fragment('PB-040-20.a.added.md', '- A 新增。'),
            fragment('PB-040-20.security.md', '- 安全收紧。'),
          ]);
      expect(aggregated, contains('- 已有条目。'));
      expect(
        aggregated.indexOf('- A 新增。'),
        lessThan(aggregated.indexOf('- B 新增。')),
      );
      expect(
        aggregated.indexOf('### Added'),
        lessThan(aggregated.indexOf('### Changed')),
      );
      expect(
        aggregated.indexOf('### Changed'),
        lessThan(aggregated.indexOf('### Fixed')),
      );
      expect(
        aggregated.indexOf('### Fixed'),
        lessThan(aggregated.indexOf('### Security')),
      );
      expect(aggregated, contains('## 0.2.1 - 2026-08-14'));
    });

    test('仓内碎片全部位于合法版本目录且正文可解析', () {
      final Directory directory = Directory('${_repoRoot()}/changelog.d');
      for (final FileSystemEntity entry in directory.listSync()) {
        final String name = entry.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        if (name == 'README.md') continue;
        expect(entry, isA<Directory>(), reason: '$name 必须是版本目录');
        expect(() => requireVersion(name), returnsNormally, reason: name);
        for (final FileSystemEntity fragment
            in (entry as Directory).listSync()) {
          expect(fragment, isA<File>(), reason: fragment.path);
          final File file = fragment as File;
          final String fileName = file.uri.pathSegments.last;
          expect(
            () => parseChangelogFragment(fileName, file.readAsBytesSync()),
            returnsNormally,
            reason: '${entry.path}/$fileName',
          );
        }
      }
    });
  });

  group('包内 CHANGELOG', () {
    const String root = '''
# Changelog

根表前言：本文件记录尚未发布和已发布版本的变化。

## Unreleased

### Added

- 还没发的东西。

## 0.3.0 - 2026-08-20

### Added

- 已发的东西。

## 0.2.1 - 2026-08-14

正文。
''';

    test('从根表派生：留全部已发布段、丢 Unreleased、换成自己的前言', () {
      final String derived = derivePackageChangelog(root);
      expect(packageChangelogMentions(derived, '0.3.0'), isTrue);
      expect(derived, contains('## 0.2.1 - 2026-08-14'));
      expect(derived, contains('- 已发的东西。'));
      // pub.dev 的 Changelog tab 读包内这份，历史段落一并带过来。
      expect(
        derived.indexOf('## 0.3.0'),
        lessThan(derived.indexOf('## 0.2.1')),
      );
      expect(derived, isNot(contains('## Unreleased')));
      expect(derived, isNot(contains('- 还没发的东西。')));
      expect(derived, isNot(contains('根表前言')));
      expect(derived, contains('由\n`release_prep --apply` 从根表派生'));
    });

    test('整份重算，跑两遍一致（根表是唯一真源）', () {
      final String once = derivePackageChangelog(root);
      expect(derivePackageChangelog(root), once);
      // 根表新增一段后，派生结果跟着变——不会留下第三份真源。
      final String updated = root.replaceFirst(
        '## 0.3.0 - 2026-08-20',
        '## 0.4.0 - 2026-09-01\n\n新段。\n\n## 0.3.0 - 2026-08-20',
      );
      expect(
        packageChangelogMentions(derivePackageChangelog(updated), '0.4.0'),
        isTrue,
      );
    });

    test('「提没提当前版本」只认版本段标题，前缀相同的版本不算', () {
      const String markdown = '# Changelog\n\n## 0.3.10 - 2026-08-20\n';
      expect(packageChangelogMentions(markdown, '0.3.1'), isFalse);
      expect(packageChangelogMentions(markdown, '0.3.10'), isTrue);
      expect(packageChangelogMentions(null, '0.3.0'), isFalse);
    });

    // 派生产物落在 packages/<包>/ 下，根表里的仓根相对路径在那儿一条都解析不到；
    // pub.dev 的 Changelog tab 读的正是这份文件。
    test('派生产物不留仓内相对链接，锚点跟着路径带走', () {
      const String withLinks = '''
# Changelog

## 0.3.0 - 2026-08-20

- 口径见[发版清单](docs/release-checklist.md)与[协作约定](CONTRIBUTING.md)。
- 锚点也要带走：[使用指南](docs/guide.md#边界)。
- 外链与纯锚点不动：[pub](https://pub.dev)、[本页](#0.3.0---2026-08-20)。
- 围栏里的不是链接：

```sh
echo "[发版清单](docs/release-checklist.md)"
```
''';
      final String derived = derivePackageChangelog(withLinks);
      expect(relativeRepoLinks(derived), isEmpty);
      expect(
        derived,
        contains(
          '[发版清单](https://github.com/cr1992/patchbay/blob/main/'
          'docs/release-checklist.md)',
        ),
      );
      expect(
        derived,
        contains(
          '[使用指南](https://github.com/cr1992/patchbay/blob/main/'
          'docs/guide.md#边界)',
        ),
      );
      expect(derived, contains('[pub](https://pub.dev)'));
      expect(derived, contains('[本页](#0.3.0---2026-08-20)'));
      expect(derived, contains('echo "[发版清单](docs/release-checklist.md)"'));
    });

    // 存量护栏：四包那四份必须是仓根表的当前派生结果，否则 pub 页上又会挂断链。
    test('仓内四包 CHANGELOG 与根表派生一致，且零相对链接', () {
      final String root = _repoRoot();
      final String expected = derivePackageChangelog(
        File('$root/$changelogPath').readAsStringSync(),
      );
      expect(relativeRepoLinks(expected), isEmpty);
      for (final String name in releasePackages) {
        final File file = File('$root/${packageChangelogPathOf(name)}');
        expect(file.existsSync(), isTrue, reason: '$name 缺 CHANGELOG.md');
        final String actual = file.readAsStringSync();
        expect(
          relativeRepoLinks(actual),
          isEmpty,
          reason: '$name 的 CHANGELOG 仍有仓内相对链接，pub.dev 上是断链',
        );
        expect(actual, expected, reason: '$name 的 CHANGELOG 与根表派生不一致');
      }
    });
  });

  group('markdown 链接', () {
    test('相对仓内链接的判别边界', () {
      expect(isRelativeRepoLink('docs/guide.md'), isTrue);
      expect(isRelativeRepoLink('../../README.md#quick-start'), isTrue);
      expect(isRelativeRepoLink('CONTRIBUTING.md'), isTrue);
      expect(isRelativeRepoLink('https://pub.dev'), isFalse);
      expect(isRelativeRepoLink('mailto:a@b.c'), isFalse);
      expect(isRelativeRepoLink('//cdn.example.com/x.png'), isFalse);
      expect(isRelativeRepoLink('#锚点'), isFalse);
      expect(isRelativeRepoLink(''), isFalse);
    });

    test('三种写法都改写：inline、引用式定义、HTML href', () {
      const String markdown = '''
[内联](docs/guide.md) 与 <a href="CONTRIBUTING.md">HTML</a>。

[ref]: docs/design.md#协议演进
''';
      final String out = absolutizeRepoLinks(markdown);
      expect(relativeRepoLinks(out), isEmpty);
      expect(
        out,
        contains(
          '[内联](https://github.com/cr1992/patchbay/blob/main/'
          'docs/guide.md)',
        ),
      );
      expect(
        out,
        contains(
          'href="https://github.com/cr1992/patchbay/blob/main/'
          'CONTRIBUTING.md"',
        ),
      );
      expect(
        out,
        contains(
          '[ref]: https://github.com/cr1992/patchbay/blob/main/'
          'docs/design.md#协议演进',
        ),
      );
    });

    test('改写幂等：跑两遍不叠前缀', () {
      const String markdown = '[x](docs/guide.md)\n';
      final String once = absolutizeRepoLinks(markdown);
      expect(absolutizeRepoLinks(once), once);
    });

    // 棘轮：pub.dev 只渲染发布归档里的这几份 README，相对路径在那里一条都解析不到。
    // 仓根 README 与 docs/ 内部互链不在快照上，故不在此列——它们保持相对，仓内阅读不绑线上。
    test('pub 快照可见的 README 里没有仓内相对链接', () {
      const List<String> pubVisible = <String>[
        'packages/patchbay/README.md',
        'packages/patchbay/README.zh-CN.md',
        'packages/patchbay_cli/README.md',
        'packages/patchbay_cli/README.zh-CN.md',
        'packages/patchbay_flutter/README.md',
        'packages/patchbay_flutter/README.zh-CN.md',
        'packages/patchbay_transport/README.md',
        'packages/patchbay_transport/README.zh-CN.md',
        'packages/patchbay_flutter/example/README.md',
        'packages/patchbay_flutter/example/README.zh-CN.md',
      ];
      final String root = _repoRoot();
      for (final String relative in pubVisible) {
        final File file = File('$root/$relative');
        expect(file.existsSync(), isTrue, reason: '缺 $relative');
        expect(
          relativeRepoLinks(file.readAsStringSync()),
          isEmpty,
          reason: '$relative 的相对链接在 pub.dev 上解析不到，请改成 $repoBlobPrefix 开头的绝对地址',
        );
      }
    });
  });

  group('example/pubspec.lock', () {
    const String lock = '''
# Generated by pub
packages:
  args:
    dependency: transitive
    description:
      name: args
      sha256: "abc"
      url: "https://pub.dev"
    source: hosted
    version: "2.7.0"
  patchbay:
    dependency: transitive
    description:
      path: "../../patchbay"
      relative: true
    source: path
    version: "0.2.1"
  patchbay_flutter:
    dependency: "direct main"
    description:
      path: ".."
      relative: true
    source: path
    version: "0.2.1"
sdks:
  dart: ">=3.11.0 <4.0.0"
''';

    test('只读 path 源的随版包版本', () {
      expect(readLockPathVersions(lock), <String, String>{
        'patchbay': '0.2.1',
        'patchbay_flutter': '0.2.1',
      });
    });

    test('刷版本只动这些格子，hosted 条目零漂移，且幂等', () {
      final String applied = applyLockVersions(lock, '0.3.0');
      expect(readLockPathVersions(applied), <String, String>{
        'patchbay': '0.3.0',
        'patchbay_flutter': '0.3.0',
      });
      // hosted 的 args 保持 2.7.0。
      expect(applied, contains('    version: "2.7.0"'));
      expect(applied, contains('  dart: ">=3.11.0 <4.0.0"'));
      expect(applyLockVersions(applied, '0.3.0'), applied);
    });
  });

  group('兼容矩阵', () {
    const String matrix = '''
# 兼容性矩阵

## 当前记录

| patchbay tag | commit SHA | wire schemaVersion | Flutter（CI 验证） | Flutter（文档最低支持） | 已知 consumer |
|---|---|---|---|---|---|
| `patchbay-v0.2.1` | `d32f45e9d652920902e51f9c3dc25c189d804e46` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×2 |

字段来源：
''';

    test('表头与分隔行不会被当成数据行', () {
      final List<CompatRow> rows = parseCompatRows(matrix);
      expect(rows, hasLength(1));
      expect(rows.single.tag, 'patchbay-v0.2.1');
      expect(rows.single.commitSha, 'd32f45e9d652920902e51f9c3dc25c189d804e46');
      expect(rows.single.schemaVersion, '1');
      expect(rows.single.flutterMin, '>=3.38.0');
      expect(rows.single.hasPending, isFalse);
    });

    test('新行插到表顶，旧行不动', () {
      const CompatRow row = CompatRow(
        tag: 'patchbay-v0.3.0',
        commitSha: pendingSha,
        schemaVersion: '1',
        flutterCi: '3.44.9',
        flutterMin: '>=3.38.0',
        consumers: pendingConsumers,
      );
      final String applied = applyCompatMatrixRow(matrix, row);
      final List<CompatRow> rows = parseCompatRows(applied);
      expect(rows.map((r) => r.tag), <String>[
        'patchbay-v0.3.0',
        'patchbay-v0.2.1',
      ]);
      expect(rows.first.hasPending, isTrue);
    });

    test('同 tag 行已存在时不覆盖——人工回填过的内容不被脚本推平', () {
      const CompatRow row = CompatRow(
        tag: 'patchbay-v0.2.1',
        commitSha: pendingSha,
        schemaVersion: '9',
        flutterCi: '0.0.0',
        flutterMin: '>=0.0.0',
        consumers: pendingConsumers,
      );
      expect(applyCompatMatrixRow(matrix, row), matrix);
    });

    test('渲染体例与现表一致', () {
      const CompatRow row = CompatRow(
        tag: 'patchbay-v0.3.0',
        commitSha: 'abc',
        schemaVersion: '1',
        flutterCi: '3.44.9',
        flutterMin: '>=3.38.0',
        consumers: '待确认',
      );
      expect(
        row.render(),
        '| `patchbay-v0.3.0` | `abc` | 1 | 3.44.9 | `>=3.38.0` | 待确认 |',
      );
    });
  });

  group('源码取值', () {
    test('schemaVersion 与 CI Flutter 版本从真源读出', () {
      expect(readSchemaVersion('  static const int schemaVersion = 3;'), 3);
      expect(readSchemaVersion('无常量'), isNull);
      expect(
        readCiFlutterVersion("env:\n  FLUTTER_VERSION: '3.44.9'\n"),
        '3.44.9',
      );
    });
  });

  group('判定', () {
    test('未 bump / 未落款 / lock 未刷 / 缺矩阵行——四件套全红', () {
      final List<ReleaseCheck> checks = evaluateRelease(
        version: '0.3.0',
        inputs: _inputs(),
        resolveTag: (_) => null,
      );
      expect(_status(checks, 'version-parity'), ReleaseCheckStatus.failed);
      expect(_status(checks, 'changelog-release'), ReleaseCheckStatus.failed);
      expect(_status(checks, 'example-lock'), ReleaseCheckStatus.failed);
      expect(_status(checks, 'compat-matrix-row'), ReleaseCheckStatus.failed);
    });

    test('0.2.0 / 0.2.1 漏过的两项是硬检查', () {
      final List<ReleaseCheck> checks = evaluateRelease(
        version: '0.3.0',
        inputs: _inputs(),
        resolveTag: (_) => null,
      );
      expect(_check(checks, 'example-lock').hard, isTrue);
      expect(_check(checks, 'compat-matrix-row').hard, isTrue);
      expect(_check(checks, 'compat-matrix-backfill').hard, isTrue);
      expect(_check(checks, 'publish-manifest').hard, isTrue);
      expect(_check(checks, 'package-changelog').hard, isTrue);
      expect(_check(checks, 'internal-dep-constraints').hard, isTrue);
      expect(_check(checks, 'local-overrides').hard, isTrue);
    });

    test('四件套补齐后转绿', () {
      final List<ReleaseCheck> checks = evaluateRelease(
        version: '0.3.0',
        inputs: _inputs(released: true),
        resolveTag: (_) => null,
      );
      for (final String id in <String>[
        'version-parity',
        'schema-version-parity',
        'changelog-release',
        'package-changelog',
        'example-lock',
        'compat-matrix-row',
      ]) {
        expect(_status(checks, id), ReleaseCheckStatus.ok, reason: id);
      }
    });

    test('包内 CHANGELOG 没提当前版本就红——pub 会因此退 65', () {
      final ReleaseCheck check = _check(
        evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true, packageChangelogVersion: '0.2.1'),
          resolveTag: (_) => null,
        ),
        'package-changelog',
      );
      expect(check.status, ReleaseCheckStatus.failed);
      expect(check.detail, contains('未记 0.3.0'));
    });

    test('schemaVersion 两处不一致直接红', () {
      final List<ReleaseCheck> checks = evaluateRelease(
        version: '0.3.0',
        inputs: _inputs(released: true, invocationSchema: 2),
        resolveTag: (_) => null,
      );
      expect(
        _status(checks, 'schema-version-parity'),
        ReleaseCheckStatus.failed,
      );
    });

    test('矩阵行的 schemaVersion 与源码漂移时红', () {
      final List<ReleaseCheck> checks = evaluateRelease(
        version: '0.3.0',
        inputs: _inputs(released: true, matrixSchemaCell: '2'),
        resolveTag: (_) => null,
      );
      expect(_status(checks, 'compat-matrix-row'), ReleaseCheckStatus.failed);
    });

    group('tag 后回填', () {
      test('tag 已存在但格子还是占位符——0.2.1 漏的那一步会红', () {
        final List<ReleaseCheck> checks = evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true),
          resolveTag: (tag) => tag == 'patchbay-v0.3.0' ? _sha : null,
        );
        final ReleaseCheck backfill = _check(checks, 'compat-matrix-backfill');
        expect(backfill.status, ReleaseCheckStatus.failed);
        expect(backfill.detail, contains('占位符'));
      });

      test('回填成 peeled SHA 后转绿', () {
        final List<ReleaseCheck> checks = evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true, sha: _sha, consumers: '内部接入方 ×2'),
          resolveTag: (tag) => tag == 'patchbay-v0.3.0' ? _sha : null,
        );
        expect(
          _status(checks, 'compat-matrix-backfill'),
          ReleaseCheckStatus.ok,
        );
      });

      test('填错 SHA 也红', () {
        final List<ReleaseCheck> checks = evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true, sha: 'f' * 40, consumers: '内部接入方 ×2'),
          resolveTag: (tag) => tag == 'patchbay-v0.3.0' ? _sha : null,
        );
        final ReleaseCheck backfill = _check(checks, 'compat-matrix-backfill');
        expect(backfill.status, ReleaseCheckStatus.failed);
        expect(backfill.detail, contains('实际 peeled SHA'));
      });

      test('tag 解析不出时跳过，不误判成红', () {
        final List<ReleaseCheck> checks = evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true),
          resolveTag: (_) => null,
        );
        expect(
          _status(checks, 'compat-matrix-backfill'),
          ReleaseCheckStatus.skipped,
        );
      });
    });

    group('pub 发布门', () {
      test('path 依赖 / 缺 LICENSE 是硬红', () {
        final ReleaseCheck manifest = _check(
          evaluateRelease(
            version: '0.3.0',
            inputs: _inputs(released: true),
            resolveTag: (_) => null,
          ),
          'publish-manifest',
        );
        expect(manifest.status, ReleaseCheckStatus.failed);
        expect(manifest.detail, contains('path 依赖'));
        expect(manifest.detail, contains('缺 LICENSE'));
      });

      test('发布开关单列一项，措辞说明它由仓主翻', () {
        final ReleaseCheck off = _check(
          evaluateRelease(
            version: '0.3.0',
            inputs: _inputs(released: true),
            resolveTag: (_) => null,
          ),
          'publish-switch',
        );
        expect(off.status, ReleaseCheckStatus.failed);
        expect(off.hard, isTrue);
        expect(off.detail, contains('publish_to: none'));
        expect(off.detail, contains('--enable-publish'));
        // publish-manifest 不再重复报这一条，免得两处口径打架。
        expect(
          _check(
            evaluateRelease(
              version: '0.3.0',
              inputs: _inputs(released: true),
              resolveTag: (_) => null,
            ),
            'publish-manifest',
          ).detail,
          isNot(contains('publish_to')),
        );

        expect(
          _status(
            evaluateRelease(
              version: '0.3.0',
              inputs: _inputs(released: true, publishable: true),
              resolveTag: (_) => null,
            ),
            'publish-switch',
          ),
          ReleaseCheckStatus.ok,
        );
      });

      test('删 publish_to 只动那一行，没有该行则原样', () {
        const String pubspec =
            'name: patchbay\nversion: 0.3.0\npublish_to: none\n\nenvironment:\n';
        final String enabled = applyRemovePublishTo(pubspec);
        expect(enabled, 'name: patchbay\nversion: 0.3.0\n\nenvironment:\n');
        expect(applyRemovePublishTo(enabled), enabled);
      });

      test('改成 hosted 约束并补齐包内文件后转绿', () {
        final List<ReleaseCheck> checks = evaluateRelease(
          version: '0.3.0',
          inputs: _inputs(released: true, publishable: true),
          resolveTag: (_) => null,
        );
        for (final String id in <String>[
          'publish-manifest',
          'publish-advisories',
          'internal-dep-constraints',
          'local-overrides',
        ]) {
          expect(_status(checks, id), ReleaseCheckStatus.ok, reason: id);
        }
      });

      test('description 太短是 warning，一样挡发布', () {
        final ReleaseCheck advisories = _check(
          evaluateRelease(
            version: '0.3.0',
            inputs: _inputs(
              released: true,
              publishable: true,
              description: '太短了。',
            ),
            resolveTag: (_) => null,
          ),
          'publish-advisories',
        );
        expect(advisories.status, ReleaseCheckStatus.failed);
        expect(advisories.detail, contains('description'));
        expect(advisories.hard, isTrue);
      });

      test('随版依赖约束停在旧版本时红', () {
        final ReleaseCheck check = _check(
          evaluateRelease(
            version: '0.4.0',
            inputs: _inputs(
              released: true,
              publishable: true,
              version: '0.4.0',
              constraintVersion: '0.3.0',
            ),
            resolveTag: (_) => null,
          ),
          'internal-dep-constraints',
        );
        expect(check.status, ReleaseCheckStatus.failed);
        expect(check.detail, contains('不接纳 0.4.0'));
      });

      test('还是 path 依赖时该项跳过，交给 publish-manifest 说话', () {
        expect(
          _status(
            evaluateRelease(
              version: '0.3.0',
              inputs: _inputs(released: true),
              resolveTag: (_) => null,
            ),
            'internal-dep-constraints',
          ),
          ReleaseCheckStatus.skipped,
        );
      });

      test('override 指错路径或缺条目时红', () {
        final ReleaseCheck missing = _check(
          evaluateRelease(
            version: '0.3.0',
            inputs: _inputs(
              released: true,
              publishable: true,
              dropOverrides: <String>{'packages/patchbay_cli'},
            ),
            resolveTag: (_) => null,
          ),
          'local-overrides',
        );
        expect(missing.status, ReleaseCheckStatus.failed);
        expect(missing.detail, contains('缺 patchbay'));

        final ReleaseCheck wrong = _check(
          evaluateRelease(
            version: '0.3.0',
            inputs: _inputs(
              released: true,
              publishable: true,
              exampleOverridePath: '../patchbay',
            ),
            resolveTag: (_) => null,
          ),
          'local-overrides',
        );
        expect(wrong.status, ReleaseCheckStatus.failed);
        expect(wrong.detail, contains('应为 ../../patchbay'));
      });

      test('排版门禁：有漂移即红，跑不起来才跳过', () {
        expect(evaluateFormatGate(0).status, ReleaseCheckStatus.ok);
        expect(evaluateFormatGate(1).status, ReleaseCheckStatus.failed);
        expect(evaluateFormatGate(null).status, ReleaseCheckStatus.skipped);
        expect(evaluateFormatGate(1).hard, isTrue);
      });

      test('dry-run 判定：有非零退出即红，静态门未过则跳过', () {
        expect(
          evaluatePublishDryRun(
            exitCodes: const <String, int>{'patchbay': 0, 'patchbay_cli': 65},
            skipped: const <String>[],
          ).status,
          ReleaseCheckStatus.failed,
        );
        expect(
          evaluatePublishDryRun(
            exitCodes: const <String, int>{'patchbay': 0},
            skipped: const <String>[],
          ).status,
          ReleaseCheckStatus.ok,
        );
        expect(
          evaluatePublishDryRun(
            exitCodes: const <String, int>{},
            skipped: const <String>['patchbay'],
          ).status,
          ReleaseCheckStatus.skipped,
        );
      });
    });

    test('版本号必须是 SemVer', () {
      expect(() => requireVersion('0.3'), throwsA(isA<FormatException>()));
      expect(() => requireVersion('v0.3.0'), throwsA(isA<FormatException>()));
      expect(requireVersion('0.3.0'), '0.3.0');
      expect(requireVersion('0.4.0-rc.1'), '0.4.0-rc.1');
    });
  });

  group('端到端（子进程）', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('patchbay-release-');
      _materialize(repo, _inputs());
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('check 先红，apply 后四件套转绿，再 apply 无改动', () async {
      final ProcessResult red = await _run(repo, '--check');
      expect(red.exitCode, 1);
      expect(red.stdout, contains('[未过] example-lock'));
      expect(red.stdout, contains('[未过] compat-matrix-row'));
      expect(red.stdout, contains('[未过] package-changelog'));
      expect(red.stdout, contains('[未过] version-references'));
      expect(red.stdout, contains('[未过] protocol-compat-fixture'));

      final ProcessResult applied = await _run(repo, '--apply');
      expect(applied.stdout, contains('[通过] version-parity'));
      expect(applied.stdout, contains('[通过] version-references'));
      expect(applied.stdout, contains('[通过] protocol-compat-fixture'));
      expect(applied.stdout, contains('[通过] changelog-release'));
      expect(applied.stdout, contains('[通过] example-lock'));
      expect(applied.stdout, contains('[通过] compat-matrix-row'));
      expect(applied.stdout, contains('[通过] package-changelog'));
      // tag、push 与发布不由脚本代做。
      expect(applied.stdout, contains('人工项'));
      expect(applied.stdout, contains('git push origin patchbay-v0.3.0'));
      expect(applied.stdout, contains('dart pub publish'));
      expect(
        File('${repo.path}/${packageChangelogPathOf('patchbay')}').existsSync(),
        isTrue,
      );

      final ProcessResult again = await _run(repo, '--apply');
      expect(again.stdout, contains('apply：无改动'));
    });

    test('apply 稳定聚合后消费碎片、保留 README，重复执行幂等', () async {
      _writeFragment(repo, 'PB-040-20.b.added.md', '- B 新增。\n');
      _writeFragment(repo, 'PB-040-20.a.added.md', '- A 新增。\n');
      _writeFragment(repo, 'PB-040-20.fixed.md', '- 修复问题。\n');

      final ProcessResult applied = await _run(repo, '--apply');
      expect(applied.exitCode, isNot(64));
      final String root = File(
        '${repo.path}/$changelogPath',
      ).readAsStringSync();
      expect(root.indexOf('- A 新增。'), lessThan(root.indexOf('- B 新增。')));
      expect(root.indexOf('### Added'), lessThan(root.indexOf('### Fixed')));
      expect(File('${repo.path}/changelog.d/README.md').existsSync(), isTrue);
      expect(
        Directory('${repo.path}/changelog.d').listSync().whereType<File>().map(
          (file) => file.uri.pathSegments.last,
        ),
        <String>['README.md'],
      );

      final Map<String, List<int>> before = _releaseFileBytes(repo);
      final ProcessResult again = await _run(repo, '--apply');
      expect(again.stdout, contains('apply：无改动'));
      expect(_releaseFileBytes(repo), before);
    });

    test('apply 只消费目标版本目录，保留其他版本队列', () async {
      _writeFragment(
        repo,
        'PB-040-20.changed.md',
        '- 只属于 0.4.0。\n',
        version: '0.4.0',
      );
      _writeFragment(
        repo,
        'PB-050-01.added.md',
        '- 只属于 0.5.0。\n',
        version: '0.5.0',
      );

      final ProcessResult applied = await _run(
        repo,
        '--apply',
        version: '0.4.0',
      );

      expect(applied.exitCode, isNot(64));
      final String changelog = File(
        '${repo.path}/$changelogPath',
      ).readAsStringSync();
      expect(changelog, contains('- 只属于 0.4.0。'));
      expect(changelog, isNot(contains('- 只属于 0.5.0。')));
      expect(
        File(
          '${repo.path}/changelog.d/0.4.0/PB-040-20.changed.md',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('${repo.path}/changelog.d/0.5.0/PB-050-01.added.md').existsSync(),
        isTrue,
      );
    });

    test('根目录散落碎片会 fail-closed，不被任何版本消费', () async {
      final File loose = File('${repo.path}/changelog.d/PB-040-20.changed.md')
        ..writeAsStringSync('- 旧布局碎片。\n');
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult checked = await _run(
        repo,
        '--check',
        version: '0.4.0',
      );
      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] changelog-fragments'));
      expect(checked.stdout, contains('碎片必须放入 changelog.d/<version>/'));

      final ProcessResult applied = await _run(
        repo,
        '--apply',
        version: '0.4.0',
      );
      expect(applied.exitCode, 64);
      expect(_releaseFileBytes(repo), before);
      expect(loose.existsSync(), isTrue);
    });

    test('RC 协议语料可重复冻结，正式版本使用独立目录', () async {
      final ProcessResult rc = await _run(
        repo,
        '--apply',
        version: '0.4.0-rc.1',
      );
      expect(rc.exitCode, isNot(64));
      final File rcIdentity = File(
        '${repo.path}/$compatibilityCorpusPath/'
        'legacy_host_v0_4_0-rc_1/identity.json',
      );
      expect(rcIdentity.existsSync(), isTrue);
      expect(
        jsonDecode(rcIdentity.readAsStringSync())['serverVersion'],
        '0.4.0-rc.1',
      );
      final Map<String, List<int>> rcFiles = _releaseFileBytes(repo);
      final ProcessResult rcAgain = await _run(
        repo,
        '--apply',
        version: '0.4.0-rc.1',
      );
      expect(rcAgain.stdout, contains('apply：无改动'));
      expect(_releaseFileBytes(repo), rcFiles);

      // 正式版不能覆盖 RC 语料；每个发布构建留下自己的不可变目录。
      _materialize(repo, _inputs());
      await _run(repo, '--apply', version: '0.4.0');
      expect(
        File(
          '${repo.path}/$compatibilityCorpusPath/'
          'legacy_host_v0_4_0/identity.json',
        ).existsSync(),
        isTrue,
      );
    });

    test('check 检出协议语料缺失、内容漂移与非受管文件', () async {
      _materialize(repo, _inputs(released: true));
      final String directory = compatibilityCorpusDirectory('0.3.0');
      final File identity = File(
        '${repo.path}/$compatibilityCorpusPath/$directory/identity.json',
      );
      identity.writeAsStringSync(
        identity.readAsStringSync().replaceFirst('0.3.0', '0.2.1'),
      );
      File(
        '${repo.path}/$compatibilityCorpusPath/$directory/catalog.json',
      ).deleteSync();
      File(
        '${repo.path}/$compatibilityCorpusPath/$directory/unmanaged.json',
      ).writeAsStringSync('{}\n');

      final ProcessResult checked = await _run(repo, '--check');

      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] protocol-compat-fixture'));
      expect(checked.stdout, contains('identity.json=漂移'));
      expect(checked.stdout, contains('catalog.json=缺失'));
      expect(checked.stdout, contains('unmanaged.json=非受管文件'));
    });

    test('协议源 golden 畸形时 apply 不写任何发布文件或消费碎片', () async {
      _materialize(repo, _inputs(hostSurfaceGolden: '{}'));
      _writeFragment(repo, 'PB-040-18.changed.md', '- 不应被消费。\n');
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult applied = await _run(repo, '--apply');

      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('host surface golden'));
      expect(_releaseFileBytes(repo), before);
      expect(
        File(
          '${repo.path}/changelog.d/0.3.0/PB-040-18.changed.md',
        ).existsSync(),
        isTrue,
      );
    });

    test('apply 拒绝用当前 host 覆写已声明冻结的旧版语料', () async {
      _materialize(
        repo,
        _inputs(
          compatibilityCorpus: const <String, String>{
            'legacy_host_v0_2_0/README.md':
                '# 冻结语料\n\n<!-- $frozenCorpusMarker -->\n',
            'legacy_host_v0_2_0/identity.json': '{}\n',
            'legacy_host_v0_2_0/catalog.json': '{}\n',
          },
        ),
      );
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult applied = await _run(
        repo,
        '--apply',
        version: '0.2.0',
      );

      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('拒绝用当前 host 覆写'));
      expect(_releaseFileBytes(repo), before);
    });

    test('check 会逐项检出 README 或 serverVersion 常量漂移，且保持只读', () async {
      _materialize(repo, _inputs(released: true));
      final File readme = File('${repo.path}/README.zh-CN.md');
      readme.writeAsStringSync(
        readme.readAsStringSync().replaceFirst(
          'patchbay-v0.3.0',
          'patchbay-v0.2.1',
        ),
      );
      final File versionSource = File('${repo.path}/$packageVersionSourcePath');
      versionSource.writeAsStringSync(
        versionSource.readAsStringSync().replaceFirst("'0.3.0'", "'0.2.1'"),
      );
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult checked = await _run(repo, '--check');

      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] version-references'));
      expect(checked.stdout, contains('patchbayPackageVersion'));
      expect(checked.stdout, contains('README.zh-CN.md'));
      expect(_releaseFileBytes(repo), before);
    });

    test('碎片校验失败时 check 可诊断，apply 不写文件也不部分删除', () async {
      _writeFragment(repo, 'PB-040-20.added.md', '- 合法。\n');
      _writeFragment(repo, 'PB-040-20.bad.md', '- 类型非法。\n');
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult checked = await _run(repo, '--check');
      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] changelog-fragments'));
      expect(checked.stdout, contains('PB-040-20.bad.md'));

      final ProcessResult applied = await _run(repo, '--apply');
      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('CHANGELOG 碎片校验失败'));
      expect(_releaseFileBytes(repo), before);
      expect(
        File('${repo.path}/changelog.d/0.3.0/PB-040-20.added.md').existsSync(),
        isTrue,
      );
      expect(
        File('${repo.path}/changelog.d/0.3.0/PB-040-20.bad.md').existsSync(),
        isTrue,
      );
    });

    test('聚合失败时保留碎片与全部发布文件', () async {
      _materialize(repo, _inputs(released: true));
      _writeFragment(repo, 'PB-040-20.added.md', '- 不应被消费。\n');
      final Map<String, List<int>> before = _releaseFileBytes(repo);

      final ProcessResult applied = await _run(repo, '--apply');
      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('恰好有一个 `## Unreleased`'));
      expect(_releaseFileBytes(repo), before);
      expect(
        File('${repo.path}/changelog.d/0.3.0/PB-040-20.added.md').existsSync(),
        isTrue,
      );
    });

    test('apply 会把 hosted 约束与 overrides 一起带到目标版本', () async {
      _materialize(repo, _inputs(publishable: true));
      await _run(repo, '--apply', version: '0.4.0');
      final String cli = File(
        '${repo.path}/${pubspecPathOf('patchbay_cli')}',
      ).readAsStringSync();
      expect(readInternalConstraints(cli), <String, String>{
        'patchbay': '^0.4.0',
        'patchbay_transport': '^0.4.0',
      });
      final ProcessResult check = await _run(repo, '--check', version: '0.4.0');
      expect(check.stdout, contains('[通过] internal-dep-constraints'));
      expect(check.stdout, contains('[通过] local-overrides'));
    });

    test('缺 overrides 时 apply 代生成，且不推平已经指对的文件', () async {
      _materialize(
        repo,
        _inputs(
          publishable: true,
          dropOverrides: <String>{'packages/patchbay_cli'},
        ),
      );
      final File overrides = File(
        '${repo.path}/${overridesPathOf('patchbay_cli')}',
      );
      expect(overrides.existsSync(), isFalse);
      await _run(repo, '--apply');
      expect(readPathOverrides(overrides.readAsStringSync()), <String, String>{
        'patchbay': '../patchbay',
        'patchbay_transport': '../patchbay_transport',
      });

      const String handEdited =
          '# 手工加过的注释\ndependency_overrides:\n'
          '  patchbay:\n    path: ../patchbay\n'
          '  patchbay_transport:\n    path: ../patchbay_transport\n';
      overrides.writeAsStringSync(handEdited);
      await _run(repo, '--apply');
      expect(overrides.readAsStringSync(), handEdited);
    });

    test('默认 apply 不碰发布开关，--enable-publish 才删', () async {
      final File pubspec = File('${repo.path}/${pubspecPathOf('patchbay')}');
      await _run(repo, '--apply');
      expect(pubspec.readAsStringSync(), contains('publish_to: none'));
      final ProcessResult still = await _run(repo, '--check');
      expect(still.stdout, contains('[未过] publish-switch'));
      // 开关没开时不去跑 dry-run：拿到的只会是「本包不可发布」。
      expect(still.stdout, contains('[跳过] publish-dry-run'));

      await _run(repo, '--apply', extra: <String>['--enable-publish']);
      expect(pubspec.readAsStringSync(), isNot(contains('publish_to')));
      expect(readPubspecVersion(pubspec.readAsStringSync()), '0.3.0');
    });

    test('--enable-publish 不配 --apply 直接退 64', () async {
      final ProcessResult result = await _run(
        repo,
        '--check',
        extra: <String>['--enable-publish'],
      );
      expect(result.exitCode, 64);
    });

    test('包内 CHANGELOG 是根表的投影：apply 后含已发布段、无 Unreleased', () async {
      await _run(repo, '--apply');
      final String derived = File(
        '${repo.path}/${packageChangelogPathOf('patchbay_cli')}',
      ).readAsStringSync();
      expect(packageChangelogMentions(derived, '0.3.0'), isTrue);
      expect(derived, isNot(contains('## Unreleased')));
    });

    test('check 只读：跑两遍不改任何文件', () async {
      final String before = File(
        '${repo.path}/$changelogPath',
      ).readAsStringSync();
      await _run(repo, '--check');
      await _run(repo, '--check');
      expect(File('${repo.path}/$changelogPath').readAsStringSync(), before);
    });

    test('参数错按 usage 退 64', () async {
      final ProcessResult result = await _run(repo, '--check', version: '0.3');
      expect(result.exitCode, 64);
    });
  });
}

// ===== 夹具 =====

const String _sha = 'd32f45e9d652920902e51f9c3dc25c189d804e46';

const String _description =
    'Consumer-neutral fixture package used by the release_prep unit tests.';

String _pubspec(
  String name, {
  required bool publishable,
  required String version,
  required String constraintVersion,
  required String description,
}) {
  final bool isFlutter = name == 'patchbay_flutter';
  final bool isCli = name == 'patchbay_cli';
  final StringBuffer out = StringBuffer()
    ..writeln('name: $name')
    ..writeln('description: $description')
    ..writeln('version: $version');
  if (publishable) {
    out.writeln('repository: https://example.invalid/patchbay');
  } else {
    out.writeln('publish_to: none');
  }
  out
    ..writeln()
    ..writeln('environment:')
    ..writeln("  sdk: '>=3.11.0 <4.0.0'");
  if (isFlutter) out.writeln("  flutter: '>=3.38.0'");
  if (isFlutter || isCli) {
    out
      ..writeln()
      ..writeln('dependencies:');
    if (isFlutter) {
      out
        ..writeln('  flutter:')
        ..writeln('    sdk: flutter');
    }
    if (publishable) {
      out.writeln('  patchbay: ^$constraintVersion');
      if (isCli) out.writeln('  patchbay_transport: ^$constraintVersion');
    } else {
      out
        ..writeln('  patchbay:')
        ..writeln('    path: ../patchbay');
      if (isCli) {
        out
          ..writeln('  patchbay_transport:')
          ..writeln('    path: ../patchbay_transport');
      }
    }
  }
  return out.toString();
}

ReleaseInputs _inputs({
  bool released = false,
  bool publishable = false,
  int invocationSchema = 1,
  String matrixSchemaCell = '1',
  String sha = pendingSha,
  String consumers = pendingConsumers,
  String? version,
  String? constraintVersion,
  String? packageChangelogVersion,
  String description = _description,
  String exampleOverridePath = '../../patchbay',
  Set<String> dropOverrides = const <String>{},
  String? hostSurfaceGolden,
  Map<String, String>? compatibilityCorpus,
}) {
  final String resolved = version ?? (released ? '0.3.0' : '0.2.1');
  final String constraints = constraintVersion ?? resolved;
  final String changelogVersion = packageChangelogVersion ?? resolved;
  final String resolvedHostSurface =
      hostSurfaceGolden ?? _hostSurface(resolved);
  final String newRow = released
      ? '| `$tagPrefix$resolved` | `$sha` | $matrixSchemaCell | 3.44.9 '
            '| `>=3.38.0` | $consumers |\n'
      : '';
  String? overridesFor(String name) {
    if (!publishable) return null;
    if (dropOverrides.contains('packages/$name')) return null;
    return switch (name) {
      'patchbay_cli' => renderOverrides(<String, String>{
        'patchbay': '../patchbay',
        'patchbay_transport': '../patchbay_transport',
      }),
      'patchbay_flutter' => renderOverrides(<String, String>{
        'patchbay': '../patchbay',
      }),
      _ => null,
    };
  }

  return ReleaseInputs(
    packages: <String, PackageManifest>{
      for (final String name in releasePackages)
        name: PackageManifest(
          name: name,
          pubspec: _pubspec(
            name,
            publishable: publishable,
            version: resolved,
            constraintVersion: constraints,
            description: description,
          ),
          files: publishable
              ? <String>{'LICENSE', 'README.md', 'CHANGELOG.md'}
              : <String>{},
          overrides: overridesFor(name),
          changelog: released
              ? '# Changelog\n\n## $changelogVersion - 2026-08-14\n\n见根表。\n'
              : null,
        ),
    },
    hostSurfaceGolden: resolvedHostSurface,
    compatibilityCorpus:
        compatibilityCorpus ??
        (released
            ? renderCompatibilityFixtures(resolved, resolvedHostSurface)
            : const <String, String>{}),
    packageVersionSource:
        "const String patchbayPackageVersion = '$resolved';\n",
    readmes: <String, String>{
      'README.md': _releaseReadme(resolved, chinese: false),
      'README.zh-CN.md': _releaseReadme(resolved, chinese: true),
    },
    changelog: released
        ? '# Changelog\n\n## $resolved - 2026-08-14\n\n### Added\n\n- 某条。\n'
        : '# Changelog\n\n## Unreleased\n\n### Added\n\n- 某条。\n',
    examplePubspec:
        'name: patchbay_flutter_example\n'
        'publish_to: none\n'
        '\n'
        'dependencies:\n'
        '  patchbay_flutter:\n'
        '    path: ..\n',
    exampleOverrides: publishable
        ? renderOverrides(<String, String>{'patchbay': exampleOverridePath})
        : null,
    exampleLock:
        '# Generated by pub\n'
        'packages:\n'
        '  patchbay:\n'
        '    dependency: transitive\n'
        '    description:\n'
        '      path: "../../patchbay"\n'
        '      relative: true\n'
        '    source: path\n'
        '    version: "$resolved"\n'
        'sdks:\n'
        '  dart: ">=3.11.0 <4.0.0"\n',
    compatMatrix:
        '# 兼容性矩阵\n\n## 当前记录\n\n'
        '| patchbay tag | commit SHA | wire schemaVersion | Flutter（CI 验证） '
        '| Flutter（文档最低支持） | 已知 consumer |\n'
        '|---|---|---|---|---|---|\n'
        '$newRow'
        '| `patchbay-v0.2.1` | `$_sha` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×2 |\n',
    // 端到端用例会把这两串写进夹具仓，排版门禁要跑它们，因此必须是合法且已对齐的 Dart。
    serviceHost:
        'class ServiceHost {\n  static const int schemaVersion = 1;\n}\n',
    invocation:
        'class Envelope {\n'
        '  static const int schemaVersion = $invocationSchema;\n'
        '}\n',
    workflow: "env:\n  FLUTTER_VERSION: '3.44.9'\n",
  );
}

String _hostSurface(String version) => jsonEncode(<String, Object?>{
  'identity': <String, Object?>{
    'schemaVersion': 1,
    'serverVersion': '<patchbayPackageVersion>',
    'features': <String>['catalogDigest'],
    'applicationId': 'dev.patchbay.fixture.$version',
    'appInstanceId': 'fixture-instance',
    'isolateId': '<runtime>',
  },
  'catalog': <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{'name': 'fixture.command'},
    ],
    'uiTargets': <Object?>[],
    'schemaVersion': 1,
    'catalogDigest': <String, Object?>{
      'algorithm': 'sha256',
      'covers': <String>['commands'],
      'value': 'fixture-digest',
    },
  },
});

String _releaseReadme(String version, {required bool chinese}) =>
    '''
> **${chinese ? '项目状态：' : 'Project status:'}** `v$version`, keep
      ref: patchbay-v$version
curl /releases/download/patchbay-v$version/patchbay-$version-macos-arm64
--git-ref patchbay-v$version --git-path packages/patchbay_cli
''';

/// 从当前目录向上找仓根（CHANGELOG.md + packages/patchbay/pubspec.yaml）。
///
/// `dart test` 在包目录跑、CI 也可能从仓根跑，两种 cwd 都要能定位到真实仓库。
String _repoRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/$changelogPath').existsSync() &&
        File('${directory.path}/${pubspecPathOf('patchbay')}').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('找不到仓根（从 ${Directory.current.path} 向上）');
    }
    directory = parent;
  }
}

void _materialize(Directory repo, ReleaseInputs inputs) {
  void write(String relative, String? content) {
    final File file = File('${repo.path}/$relative');
    if (content == null) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  for (final MapEntry<String, PackageManifest> entry
      in inputs.packages.entries) {
    write(pubspecPathOf(entry.key), entry.value.pubspec);
    write(overridesPathOf(entry.key), entry.value.overrides);
    write(packageChangelogPathOf(entry.key), entry.value.changelog);
  }
  write(hostSurfaceGoldenPath, inputs.hostSurfaceGolden);
  final Directory corpus = Directory('${repo.path}/$compatibilityCorpusPath');
  if (corpus.existsSync()) corpus.deleteSync(recursive: true);
  for (final MapEntry<String, String> entry
      in inputs.compatibilityCorpus.entries) {
    write('$compatibilityCorpusPath/${entry.key}', entry.value);
  }
  write(changelogPath, inputs.changelog);
  write(packageVersionSourcePath, inputs.packageVersionSource);
  for (final MapEntry<String, String> entry in inputs.readmes.entries) {
    write(entry.key, entry.value);
  }
  write(examplePubspecPath, inputs.examplePubspec);
  write(exampleOverridesPath, inputs.exampleOverrides);
  write(exampleLockPath, inputs.exampleLock);
  write(compatMatrixPath, inputs.compatMatrix);
  write(serviceHostPath, inputs.serviceHost);
  write(invocationPath, inputs.invocation);
  write(workflowPath, inputs.workflow);
  write('changelog.d/README.md', '# CHANGELOG 碎片规范\n');
}

void _writeFragment(
  Directory repo,
  String name,
  String content, {
  String version = '0.3.0',
}) {
  final File file = File('${repo.path}/changelog.d/$version/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

Map<String, List<int>> _releaseFileBytes(Directory repo) {
  final paths = <String>[
    changelogPath,
    hostSurfaceGoldenPath,
    packageVersionSourcePath,
    ...releaseReadmePaths,
    exampleLockPath,
    compatMatrixPath,
    for (final String package in releasePackages) ...<String>[
      pubspecPathOf(package),
      packageChangelogPathOf(package),
    ],
    for (final File file in Directory(
      '${repo.path}/changelog.d',
    ).listSync(recursive: true).whereType<File>())
      file.path.substring(repo.path.length + 1),
    if (Directory('${repo.path}/$compatibilityCorpusPath').existsSync())
      for (final File file in Directory(
        '${repo.path}/$compatibilityCorpusPath',
      ).listSync(recursive: true).whereType<File>())
        file.path.substring(repo.path.length + 1),
  ]..sort();
  return <String, List<int>>{
    for (final String path in paths)
      if (File('${repo.path}/$path').existsSync())
        path: File('${repo.path}/$path').readAsBytesSync(),
  };
}

Future<ProcessResult> _run(
  Directory repo,
  String mode, {
  String version = '0.3.0',
  List<String> extra = const <String>[],
}) => Process.run(Platform.resolvedExecutable, <String>[
  'run',
  'tool/release_prep.dart',
  '--version',
  version,
  mode,
  '--date',
  '2026-08-14',
  '--repo-root',
  repo.path,
  // 端到端用例不联网：dry-run 由上面的判定单测覆盖。
  '--no-publish-dry-run',
  ...extra,
]);

ReleaseCheck _check(List<ReleaseCheck> checks, String id) =>
    checks.firstWhere((check) => check.id == id);

ReleaseCheckStatus _status(List<ReleaseCheck> checks, String id) =>
    _check(checks, id).status;
