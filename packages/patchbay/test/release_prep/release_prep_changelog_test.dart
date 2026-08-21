import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release_prep.dart';
import '../fixture/release_prep_fixtures.dart';

void main() {
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
      final Directory directory = Directory('${repoRoot()}/changelog.d');
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

<!-- PUB_CHANGELOG:START -->
### Added

- Added a released feature.
<!-- PUB_CHANGELOG:END -->

## 0.2.1 - 2026-08-14

正文。
''';

    test('从根表派生：只留英文 pub 摘要、丢 Unreleased、换前言', () {
      final String derived = derivePackageChangelog(root);
      expect(packageChangelogMentions(derived, '0.3.0'), isTrue);
      expect(derived, isNot(contains('## 0.2.1 - 2026-08-14')));
      expect(derived, contains('- Added a released feature.'));
      expect(derived, isNot(contains('## Unreleased')));
      expect(derived, isNot(contains('- 还没发的东西。')));
      expect(derived, isNot(contains('根表前言')));
      expect(derived, contains('Generated by `release_prep --apply`'));
      expect(derived, isNot(contains('PUB_CHANGELOG')));
    });

    test('整份重算，跑两遍一致（根表是唯一真源）', () {
      final String once = derivePackageChangelog(root);
      expect(derivePackageChangelog(root), once);
      final String updated = root.replaceFirst(
        '## 0.3.0 - 2026-08-20',
        '## 0.4.0 - 2026-09-01\n\n'
            '<!-- PUB_CHANGELOG:START -->\n'
            'Added another release.\n'
            '<!-- PUB_CHANGELOG:END -->\n\n'
            '## 0.3.0 - 2026-08-20',
      );
      expect(
        packageChangelogMentions(derivePackageChangelog(updated), '0.4.0'),
        isTrue,
      );
    });

    test('当前版本没有英文 pub 摘要时不会被误判已记录', () {
      const String missing = '''
# Changelog

## 0.4.0 - 2026-09-01

只有中文详细变更。
''';
      expect(
        packageChangelogMentions(derivePackageChangelog(missing), '0.4.0'),
        isFalse,
      );
    });

    test('「提没提当前版本」只认版本段标题，前缀相同的版本不算', () {
      const String markdown = '# Changelog\n\n## 0.3.10 - 2026-08-20\n';
      expect(packageChangelogMentions(markdown, '0.3.1'), isFalse);
      expect(packageChangelogMentions(markdown, '0.3.10'), isTrue);
      expect(packageChangelogMentions(null, '0.3.0'), isFalse);
    });

    test('派生产物不留仓内相对链接，锚点跟着路径带走', () {
      const String withLinks = '''
# Changelog

## 0.3.0 - 2026-08-20

<!-- PUB_CHANGELOG:START -->
- 口径见[发版清单](docs/release-checklist.md)与[协作约定](CONTRIBUTING.md)。
- 锚点也要带走：[使用指南](docs/guide.md#边界)。
- 外链与纯锚点不动：[pub](https://pub.dev)、[本页](#0.3.0---2026-08-20)。
- 围栏里的不是链接：

```sh
echo "[发版清单](docs/release-checklist.md)"
```
<!-- PUB_CHANGELOG:END -->
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

    test('仓内四包 CHANGELOG 与根表派生一致，且零相对链接', () {
      final String root = repoRoot();
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
      final String root = repoRoot();
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
}
