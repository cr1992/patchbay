import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release_prep.dart';
import '../fixture/release_prep_fixtures.dart';

void main() {
  group('端到端（子进程）', () {
    late Directory repo;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('patchbay-release-');
      materializeInputs(repo, releaseInputsFixture());
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('check 先红，apply 后四件套转绿，再 apply 无改动', () async {
      final ProcessResult red = await execReleasePrepProcess(repo, '--check');
      expect(red.exitCode, 1);
      expect(red.stdout, contains('[未过] example-lock'));
      expect(red.stdout, contains('[未过] compat-matrix-row'));
      expect(red.stdout, contains('[未过] package-changelog'));
      expect(red.stdout, contains('[未过] version-references'));
      expect(red.stdout, contains('[未过] protocol-compat-fixture'));

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
      );
      expect(applied.stdout, contains('[通过] version-parity'));
      expect(applied.stdout, contains('[通过] version-references'));
      expect(applied.stdout, contains('[跳过] protocol-compat-fixture'));
      expect(applied.stdout, contains('[通过] changelog-release'));
      expect(applied.stdout, contains('[通过] example-lock'));
      expect(applied.stdout, contains('[通过] compat-matrix-row'));
      expect(applied.stdout, contains('[通过] package-changelog'));
      expect(applied.stdout, contains('人工项'));
      expect(applied.stdout, contains('git push origin patchbay-v0.3.0'));
      expect(applied.stdout, contains('pub points 是发布硬门'));
      expect(applied.stdout, contains('grantedPoints == maxPoints'));
      expect(applied.stdout, contains('dart pub publish'));
      expect(
        File('${repo.path}/${packageChangelogPathOf('patchbay')}').existsSync(),
        isTrue,
      );

      final ProcessResult again = await execReleasePrepProcess(repo, '--apply');
      expect(again.stdout, contains('apply：无改动'));
    });

    test('apply 稳定聚合后消费碎片、保留 README，重复执行幂等', () async {
      writeFragment(repo, 'PB-040-20.b.added.md', '- B 新增。\n');
      writeFragment(repo, 'PB-040-20.a.added.md', '- A 新增。\n');
      writeFragment(repo, 'PB-040-20.fixed.md', '- 修复问题。\n');

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
      );
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

      final Map<String, List<int>> before = releaseFileBytes(repo);
      final ProcessResult again = await execReleasePrepProcess(repo, '--apply');
      expect(again.stdout, contains('apply：无改动'));
      expect(releaseFileBytes(repo), before);
    });

    test('apply 只消费目标版本目录，保留其他版本队列', () async {
      writeFragment(
        repo,
        'PB-040-20.changed.md',
        '- 只属于 0.4.0。\n',
        version: '0.4.0',
      );
      writeFragment(
        repo,
        'PB-050-01.added.md',
        '- 只属于 0.5.0。\n',
        version: '0.5.0',
      );

      final ProcessResult applied = await execReleasePrepProcess(
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
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult checked = await execReleasePrepProcess(
        repo,
        '--check',
        version: '0.4.0',
      );
      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] changelog-fragments'));
      expect(checked.stdout, contains('碎片必须放入 changelog.d/<version>/'));

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
        version: '0.4.0',
      );
      expect(applied.exitCode, 64);
      expect(releaseFileBytes(repo), before);
      expect(loose.existsSync(), isTrue);
    });

    test('RC 协议语料可重复冻结，正式版本使用独立目录', () async {
      final ProcessResult rc = await execReleasePrepProcess(
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
      final Map<String, List<int>> rcFiles = releaseFileBytes(repo);
      final ProcessResult rcAgain = await execReleasePrepProcess(
        repo,
        '--apply',
        version: '0.4.0-rc.1',
      );
      expect(rcAgain.stdout, contains('apply：无改动'));
      expect(releaseFileBytes(repo), rcFiles);

      materializeInputs(repo, releaseInputsFixture());
      await execReleasePrepProcess(repo, '--apply', version: '0.4.0');
      expect(
        File(
          '${repo.path}/$compatibilityCorpusPath/'
          'legacy_host_v0_4_0/identity.json',
        ).existsSync(),
        isTrue,
      );
    });

    test('check 检出协议语料缺失、内容漂移与非受管文件', () async {
      materializeInputs(repo, releaseInputsFixture(released: true));
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

      final ProcessResult checked = await execReleasePrepProcess(
        repo,
        '--check',
      );

      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] protocol-compat-fixture'));
      expect(checked.stdout, contains('identity.json=漂移'));
      expect(checked.stdout, contains('catalog.json=缺失'));
      expect(checked.stdout, contains('unmanaged.json=非受管文件'));
    });

    test('协议源 golden 畸形时 apply 不写任何发布文件或消费碎片', () async {
      materializeInputs(repo, releaseInputsFixture(hostSurfaceGolden: '{}'));
      writeFragment(repo, 'PB-040-18.changed.md', '- 不应被消费。\n');
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
      );

      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('host surface golden'));
      expect(releaseFileBytes(repo), before);
      expect(
        File(
          '${repo.path}/changelog.d/0.3.0/PB-040-18.changed.md',
        ).existsSync(),
        isTrue,
      );
    });

    test('apply 拒绝用当前 host 覆写已声明冻结的旧版语料', () async {
      materializeInputs(
        repo,
        releaseInputsFixture(
          compatibilityCorpus: const <String, String>{
            'legacy_host_v0_2_0/README.md':
                '# 冻结语料\n\n<!-- $frozenCorpusMarker -->\n',
            'legacy_host_v0_2_0/identity.json': '{}\n',
            'legacy_host_v0_2_0/catalog.json': '{}\n',
          },
        ),
      );
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
        version: '0.2.0',
      );

      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('拒绝用当前 host 覆写'));
      expect(releaseFileBytes(repo), before);
    });

    test('check 会逐项检出 README 或 serverVersion 常量漂移，且保持只读', () async {
      materializeInputs(repo, releaseInputsFixture(released: true));
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
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult checked = await execReleasePrepProcess(
        repo,
        '--check',
      );

      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] version-references'));
      expect(checked.stdout, contains('patchbayPackageVersion'));
      expect(checked.stdout, contains('README.zh-CN.md'));
      expect(releaseFileBytes(repo), before);
    });

    test('碎片校验失败时 check 可诊断，apply 不写文件也不部分删除', () async {
      writeFragment(repo, 'PB-040-20.added.md', '- 合法。\n');
      writeFragment(repo, 'PB-040-20.bad.md', '- 类型非法。\n');
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult checked = await execReleasePrepProcess(
        repo,
        '--check',
      );
      expect(checked.exitCode, 1);
      expect(checked.stdout, contains('[未过] changelog-fragments'));
      expect(checked.stdout, contains('PB-040-20.bad.md'));

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
      );
      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('CHANGELOG 碎片校验失败'));
      expect(releaseFileBytes(repo), before);
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
      materializeInputs(repo, releaseInputsFixture(released: true));
      writeFragment(repo, 'PB-040-20.added.md', '- 不应被消费。\n');
      final Map<String, List<int>> before = releaseFileBytes(repo);

      final ProcessResult applied = await execReleasePrepProcess(
        repo,
        '--apply',
      );
      expect(applied.exitCode, 64);
      expect(applied.stderr, contains('恰好有一个 `## Unreleased`'));
      expect(releaseFileBytes(repo), before);
      expect(
        File('${repo.path}/changelog.d/0.3.0/PB-040-20.added.md').existsSync(),
        isTrue,
      );
    });

    test('apply 会把 hosted 约束与 overrides 一起带到目标版本', () async {
      materializeInputs(repo, releaseInputsFixture(publishable: true));
      await execReleasePrepProcess(repo, '--apply', version: '0.4.0');
      final String cli = File(
        '${repo.path}/${pubspecPathOf('patchbay_cli')}',
      ).readAsStringSync();
      expect(readInternalConstraints(cli), <String, String>{
        'patchbay': '^0.4.0',
        'patchbay_transport': '^0.4.0',
      });
      final ProcessResult check = await execReleasePrepProcess(
        repo,
        '--check',
        version: '0.4.0',
      );
      expect(check.stdout, contains('[通过] internal-dep-constraints'));
      expect(check.stdout, contains('[通过] local-overrides'));
    });

    test('缺 overrides 时 apply 代生成，且不推平已经指对的文件', () async {
      materializeInputs(
        repo,
        releaseInputsFixture(
          publishable: true,
          dropOverrides: <String>{'packages/patchbay_cli'},
        ),
      );
      final File overrides = File(
        '${repo.path}/${overridesPathOf('patchbay_cli')}',
      );
      expect(overrides.existsSync(), isFalse);
      await execReleasePrepProcess(repo, '--apply');
      expect(readPathOverrides(overrides.readAsStringSync()), <String, String>{
        'patchbay': '../patchbay',
        'patchbay_transport': '../patchbay_transport',
      });

      const String handEdited =
          '# 手工加过的注释\ndependency_overrides:\n'
          '  patchbay:\n    path: ../patchbay\n'
          '  patchbay_transport:\n    path: ../patchbay_transport\n';
      overrides.writeAsStringSync(handEdited);
      await execReleasePrepProcess(repo, '--apply');
      expect(overrides.readAsStringSync(), handEdited);
    });

    test('默认 apply 不碰发布开关，--enable-publish 才删', () async {
      final File pubspec = File('${repo.path}/${pubspecPathOf('patchbay')}');
      await execReleasePrepProcess(repo, '--apply');
      expect(pubspec.readAsStringSync(), contains('publish_to: none'));
      final ProcessResult still = await execReleasePrepProcess(repo, '--check');
      expect(still.stdout, contains('[未过] publish-switch'));
      expect(still.stdout, contains('[跳过] publish-dry-run'));

      await execReleasePrepProcess(
        repo,
        '--apply',
        extra: <String>['--enable-publish'],
      );
      expect(pubspec.readAsStringSync(), isNot(contains('publish_to')));
      expect(readPubspecVersion(pubspec.readAsStringSync()), '0.3.0');
    });

    test('--enable-publish 不配 --apply 直接退 64', () async {
      final ProcessResult result = await execReleasePrepProcess(
        repo,
        '--check',
        extra: <String>['--enable-publish'],
      );
      expect(result.exitCode, 64);
    });

    test('包内 CHANGELOG 是根表的投影：apply 后含已发布段、无 Unreleased', () async {
      await execReleasePrepProcess(repo, '--apply');
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
      await execReleasePrepProcess(repo, '--check');
      await execReleasePrepProcess(repo, '--check');
      expect(File('${repo.path}/$changelogPath').readAsStringSync(), before);
    });

    test('参数错按 usage 退 64', () async {
      final ProcessResult result = await execReleasePrepProcess(
        repo,
        '--check',
        version: '0.3',
      );
      expect(result.exitCode, 64);
    });
  });
}
