import 'dart:io';

import 'package:test/test.dart';

import '../tool/backlog_store.dart';

const _feature =
    '---\n'
    'id: PB-050-13\n'
    'title: CLI 公共 API surface 收口\n'
    'target: 0.5.0\n'
    'status: 实现中\n'
    '---\n'
    '\n'
    '## 动机\n'
    '\n'
    '根 barrel 暴露实现 seam\n'
    '\n'
    '## 备注\n'
    '\n'
    '[收口](../proposals/0.5.0/cli-public-api-surface.md)；DG-050-07 已裁决\n';

BacklogLoadResult _parse(String content, {String name = 'PB-050-13.md'}) =>
    parseFragment(name: name, content: content, path: name);

List<String> _errorsOf(String content, {String name = 'PB-050-13.md'}) =>
    _parse(content, name: name).errors;

void main() {
  group('碎片解析', () {
    test('解析出全部字段与小节，并把仓内链接还原成文档根形态', () {
      final entry = _parse(_feature).entries.single;

      expect(entry.id, 'PB-050-13');
      expect(entry.kind, BacklogKind.feature);
      expect(entry.title, 'CLI 公共 API surface 收口');
      expect(entry.target, '0.5.0');
      expect(entry.status, '实现中');
      expect(entry.docsSection('动机'), '根 barrel 暴露实现 seam');
      expect(
        entry.docsProposalCell,
        '[收口](proposals/0.5.0/cli-public-api-surface.md)；DG-050-07 已裁决',
      );
    });

    test('文件名与 frontmatter 的 id 不一致判红', () {
      expect(
        _errorsOf(_feature, name: 'PB-050-99.md'),
        contains(contains('文件名必须是 `PB-050-13.md`')),
      );
    });

    test('缺必填字段判红', () {
      final withoutStatus = _feature.replaceFirst('status: 实现中\n', '');
      expect(_errorsOf(withoutStatus), contains(contains('缺少必填字段 `status`')));
    });

    test('多写字段判红——字段是封闭集', () {
      final extra = _feature.replaceFirst(
        'status: 实现中\n',
        'status: 实现中\nowner: 某人\n',
      );
      expect(_errorsOf(extra), contains(contains('不接受字段 `owner`')));
    });

    test('缺小节与多写小节都判红', () {
      final without = _feature.replaceFirst('## 备注', '## 其它');
      final errors = _errorsOf(without);
      expect(errors, contains(contains('缺少 `## 备注` 小节')));
      expect(errors, contains(contains('不接受小节 `## 其它`')));
    });

    test('小节写成多行判红——它渲染成表格的一个单元格', () {
      final wrapped = _feature.replaceFirst(
        '根 barrel 暴露实现 seam\n',
        '根 barrel\n暴露实现 seam\n',
      );
      expect(_errorsOf(wrapped), contains(contains('必须只有一行')));
    });

    test('小节含 `|` 判红——会破坏渲染出的表格行', () {
      final piped = _feature.replaceFirst('根 barrel', '根 | barrel');
      expect(_errorsOf(piped), contains(contains('不能包含 `|`')));
    });

    test('仓内链接缺 `../` 前缀判红', () {
      final flat = _feature.replaceFirst('](../proposals/', '](proposals/');
      expect(_errorsOf(flat), contains(contains('必须以 `../` 开头')));
    });

    test('target 只接受 SemVer 或未排期字面量', () {
      expect(
        _errorsOf(_feature.replaceFirst('target: 0.5.0', 'target: 下个版本')),
        contains(contains('只接受 SemVer')),
      );
      expect(
        _errorsOf(
          _feature.replaceFirst('target: 0.5.0', 'target: $unscheduledTarget'),
        ),
        isEmpty,
      );
    });

    test('未知编号前缀判红', () {
      final unknown = _feature
          .replaceFirst('id: PB-050-13', 'id: XX-050-13')
          .replaceFirst('target: 0.5.0\n', '');
      expect(
        _errorsOf(unknown, name: 'XX-050-13.md'),
        contains(contains('不属于任何已知前缀')),
      );
    });

    test('frontmatter 缺结束分隔符判红', () {
      expect(
        _errorsOf('---\nid: PB-050-13\ntitle: x\n'),
        contains(contains('缺少结束的 `---`')),
      );
    });
  });

  group('表格往返', () {
    test('四类条目的行都能 cells -> 碎片 -> cells 逐字节还原', () {
      final samples = <BacklogKind, List<String>>{
        BacklogKind.bug: <String>['BUG-20260826-01：权限误判', '真机实测证据', '已验证'],
        BacklogKind.feature: <String>[
          'PB-050-13',
          'CLI 公共 API 收口',
          '根 barrel 暴露 seam',
          '0.5.0',
          '实现中',
          '[收口](proposals/0.5.0/cli-public-api-surface.md)；DG-050-07',
        ],
        BacklogKind.docDebt: <String>['DOC-20260827-01：补一段说明', '出处指针'],
        BacklogKind.designGate: <String>[
          'DG-050-07',
          '公共 API 收口边界',
          unscheduledTarget,
          '已裁决',
          '[收口](proposals/0.5.0/cli-public-api-surface.md)',
        ],
      };

      for (final sample in samples.entries) {
        final spec = specForKind(sample.key);
        final entry = entryFromRowCells(spec, sample.value)!;
        expect(entry.rowCells(), sample.value, reason: '${sample.key}');

        final reparsed = parseFragment(
          name: '${entry.id}.md',
          content: entry.renderFragment(),
          path: '${entry.id}.md',
        );
        expect(reparsed.errors, isEmpty, reason: '${sample.key}');
        expect(reparsed.entries.single.rowCells(), sample.value);
      }
    });

    test('列数不符或编号不合法的行返回 null，由调用方如实报告', () {
      final spec = specForKind(BacklogKind.feature);
      expect(entryFromRowCells(spec, <String>['PB-050-13', '标题']), isNull);
      expect(
        entryFromRowCells(spec, <String>[
          'PB-13',
          't',
          'm',
          '0.5.0',
          '实现中',
          '—',
        ]),
        isNull,
      );
      expect(
        entryFromRowCells(specForKind(BacklogKind.bug), <String>[
          'BUG-20260826-01 缺全角冒号',
          'm',
          '已验证',
        ]),
        isNull,
      );
    });

    test('链接改写两个方向互为逆运算', () {
      const docs = '见 [a](proposals/x.md) 与 [b](https://example.com/y)';
      expect(toDocsLinks(toFragmentLinks(docs)), docs);
      expect(
        toFragmentLinks(docs),
        '见 [a](../proposals/x.md) 与 [b](https://example.com/y)',
      );
    });

    test('空章节渲染成既有表格的占位行形态', () {
      expect(
        renderSectionTable(
          specForKind(BacklogKind.docDebt),
          const <BacklogEntry>[],
        ).last,
        '| $emptySectionPlaceholder | |',
      );
    });
  });

  group('仓内真实碎片', () {
    test('全部可解析，且每条都能渲染成列数正确的表格行', () {
      final root = Directory.current.uri.resolve('../../').toFilePath();
      if (!Directory('$root/$backlogFragmentDir').existsSync()) return;

      final backlog = loadBacklog(root);
      expect(backlog.errors, isEmpty);
      expect(backlog.entries, isNotEmpty);
      for (final entry in backlog.entries) {
        expect(
          entry.rowCells().length,
          entry.spec.columnCount,
          reason: entry.id,
        );
        expect(entry.renderRowLine(), startsWith('| '));
      }
    });
  });
}
