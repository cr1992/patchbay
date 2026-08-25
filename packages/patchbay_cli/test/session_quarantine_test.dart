/// PB-050-19：`readAll` 遇到解析失败的会话记录不再删除，改为隔离。
///
/// 背景见 `docs/design.md`「本地会话文件是第三个兼容面」：会话目录没有 wire 面那层
/// `schemaVersionMismatch` 兜底，旧行为是把解析不了的文件直接删掉——这意味着升级一次
/// 记录字段，装老 CLI 的机器就会悄悄删掉新 launcher 刚写下的记录，操作者只看到「会话
/// 不见了」。这份用例钉住新行为：损坏文件被移到旁边而不是删除，重复扫描不会重复处理，
/// 隔离动作本身失败也不能挡住正常记录被读到。
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'patchbay-session-quarantine-test-',
    );
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('a file that is not valid JSON is quarantined, not deleted', () {
    directory.createSync(recursive: true);
    final File corrupt = File(
      '${directory.path}${Platform.pathSeparator}broken.json',
    )..writeAsStringSync('{not valid json');

    expect(store.readAll(), isEmpty);

    expect(corrupt.existsSync(), isFalse, reason: '原文件名不应该继续存在');
    final List<File> quarantined = store.quarantinedFiles();
    expect(quarantined, hasLength(1));
    expect(quarantined.single.path, startsWith(corrupt.path));
    expect(quarantined.single.path, isNot(endsWith('.json')));
    expect(quarantined.single.readAsStringSync(), '{not valid json');
  });

  test('a JSON file that is not a record object is quarantined', () {
    directory.createSync(recursive: true);
    File(
      '${directory.path}${Platform.pathSeparator}not-a-record.json',
    ).writeAsStringSync(jsonEncode(<Object?>[1, 2, 3]));

    expect(store.readAll(), isEmpty);
    expect(store.quarantinedFiles(), hasLength(1));
  });

  test('a record whose schemaVersion has moved on is quarantined', () {
    directory.createSync(recursive: true);
    File(
      '${directory.path}${Platform.pathSeparator}future.json',
    ).writeAsStringSync(jsonEncode(<String, Object?>{'schemaVersion': 999}));

    expect(store.readAll(), isEmpty);
    expect(store.quarantinedFiles(), hasLength(1));
  });

  test(
    'a record whose sessionId does not match its filename is quarantined',
    () {
      directory.createSync(recursive: true);
      final PatchbaySessionRecord record = _record('right-id');
      final File misnamed = File(
        '${directory.path}${Platform.pathSeparator}wrong-id.json',
      )..writeAsStringSync(jsonEncode(record.toJson()));

      expect(store.readAll(), isEmpty);
      expect(misnamed.existsSync(), isFalse);
      expect(store.quarantinedFiles(), hasLength(1));
    },
  );

  test('a repeated readAll does not reprocess an already-quarantined file', () {
    directory.createSync(recursive: true);
    File(
      '${directory.path}${Platform.pathSeparator}broken.json',
    ).writeAsStringSync('not json at all');

    expect(store.readAll(), isEmpty);
    final List<File> firstPass = store.quarantinedFiles();
    expect(firstPass, hasLength(1));

    // A second scan must not try to reparse (and re-quarantine) the file
    // that already moved aside: it no longer ends in `.json`, so the
    // directory scan skips it outright -- there is nothing left to process.
    final List<PatchbaySessionRecord> second = store.readAll();
    expect(second, isEmpty);
    expect(store.quarantinedFiles(), hasLength(1));
    expect(store.quarantinedFiles().single.path, firstPass.single.path);
  });

  test('a valid record next to a quarantined one still reads normally', () {
    directory.createSync(recursive: true);
    store.write(_record('alive'));
    File(
      '${directory.path}${Platform.pathSeparator}broken.json',
    ).writeAsStringSync('garbage');

    final List<PatchbaySessionRecord> records = store.readAll();
    expect(records.map((record) => record.sessionId), <String>['alive']);
    expect(store.quarantinedFiles(), hasLength(1));
  });

  test('quarantinedFiles() is empty when the directory does not exist', () {
    // `createTempSync` already creates the directory; delete it back out to
    // exercise the "never created at all" path `readAll` also handles.
    directory.deleteSync(recursive: true);
    expect(directory.existsSync(), isFalse);
    expect(store.quarantinedFiles(), isEmpty);
  });

  test('two corrupt files with the same original name both quarantine', () {
    // Simulates a crash-loop: something keeps writing a broken record under
    // the same session id. Each quarantined copy must be kept, not silently
    // overwrite the previous one -- the point of keeping evidence is to see
    // that it happened more than once.
    directory.createSync(recursive: true);
    final String path =
        '${directory.path}${Platform.pathSeparator}looping.json';
    File(path).writeAsStringSync('garbage-1');
    expect(store.readAll(), isEmpty);
    expect(store.quarantinedFiles(), hasLength(1));

    File(path).writeAsStringSync('garbage-2');
    expect(store.readAll(), isEmpty);
    expect(store.quarantinedFiles(), hasLength(2));
    expect(
      store.quarantinedFiles().map((file) => file.readAsStringSync()),
      containsAll(<String>['garbage-1', 'garbage-2']),
    );
  });

  test(
    'a quarantine failure does not block reading the rest of the directory',
    () {
      // Permission bits behave differently enough on Windows that this
      // probe is POSIX-only; the degrade behaviour under test (readAll must
      // not abort the scan) is exercised on every platform by the "best
      // effort" contract documented on _quarantineFile, this just proves it
      // concretely where the failure is easy to force.
      if (Platform.isWindows) return;
      directory.createSync(recursive: true);
      store.write(_record('alive'));
      File(
        '${directory.path}${Platform.pathSeparator}broken.json',
      ).writeAsStringSync('garbage');

      // Remove write permission on the directory itself: listing and
      // reading file contents only need read+execute, but renaming (what
      // quarantining does) needs write on the containing directory.
      Process.runSync('chmod', ['500', directory.path]);
      try {
        late List<PatchbaySessionRecord> records;
        expect(() => records = store.readAll(), returnsNormally);
        expect(records.map((record) => record.sessionId), <String>['alive']);
      } finally {
        Process.runSync('chmod', ['700', directory.path]);
      }
    },
  );
}

PatchbaySessionRecord _record(String id) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: null,
  isolateId: null,
  processId: 4242,
  wsUri: null,
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 20),
  workspacePath: '/repo/worktree',
  deviceId: 'device-1',
);
