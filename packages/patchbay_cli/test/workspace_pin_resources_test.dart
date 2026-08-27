/// PB-050-14 验证节第五组：scoped pin 的资源上限与失败注入。
///
/// 这一组只问一件事：**出错时会不会丢东西、会不会退回"全局唯一/全局 latest"**。
/// 原子 rename 前后崩溃、锁竞争、损坏或超长 pin、256 份上限、stale prune——每一格的
/// 期望都是同一个方向：session record 一条不少，pin 要么正确要么没有，绝不猜。
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/session/session_store_seam.dart';
import 'package:test/test.dart';

late Directory directory;

void main() {
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-workspace-pin-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('pin file contract', () {
    test('the file name carries the digest and no colon', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_here, 'here-a');

      final List<String> names = directory
          .listSync()
          .map((FileSystemEntity entity) => entity.uri.pathSegments.last)
          .where((String name) => name.startsWith('selected-session'))
          .toList(growable: false);

      expect(names, hasLength(1));
      expect(names.single, 'selected-session-${_here.digest}');
      // A `.json` suffix would make the record scanner quarantine it; a colon
      // would be an illegal Windows file name.
      expect(names.single, isNot(contains(':')));
      expect(names.single.endsWith('.json'), isFalse);
    });

    test('the pin body cross-checks the workspace it belongs to', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_here, 'here-a');

      final Map<String, Object?> body =
          jsonDecode(_pinBody(_here)) as Map<String, Object?>;

      expect(body['schemaVersion'], 1);
      expect(body['workspaceId'], _here.workspaceId);
      expect(body['sessionId'], 'here-a');
      // Owner-only, like every other secret-adjacent file in this directory.
      if (!Platform.isWindows) expect(_mode(_pinPath(_here)), '600');
    });

    test('a pin whose body names another workspace is discarded', () {
      store.write(_record('here-a'));
      File(_pinPath(_here)).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'workspaceId': _there.workspaceId,
          'sessionId': 'here-a',
        }),
      );

      expect(store.readSelectionFor(_here), isNull);
      // Discarded, not left to be re-read as something else next time.
      expect(File(_pinPath(_here)).existsSync(), isFalse);
      expect(store.readAll(), hasLength(1));
    });

    test('a corrupt pin is discarded and the record survives', () {
      store.write(_record('here-a'));
      File(_pinPath(_here)).writeAsStringSync('{ not json');

      expect(store.readSelectionFor(_here), isNull);
      expect(store.readAll().single.sessionId, 'here-a');
    });

    test('an over-long pin is refused without being read', () {
      store.write(_record('here-a'));
      File(_pinPath(_here)).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'workspaceId': _here.workspaceId,
          'sessionId': 'here-a',
          'padding': 'x' * (patchbayScopedSelectionMaximumBytes + 1),
        }),
      );

      expect(store.readSelectionFor(_here), isNull);
      expect(store.readAll().single.sessionId, 'here-a');
    });

    test('the pin file is never mistaken for a session record', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_here, 'here-a');
      store.writeLegacyGlobalSelection('here-a');

      expect(
        store.readAll().map((PatchbaySessionRecord r) => r.sessionId),
        <String>['here-a'],
      );
      expect(store.quarantinedFiles(), isEmpty);
    });
  });

  group('atomicity and contention', () {
    test('no temp file survives a completed pin write', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_here, 'here-a');

      expect(
        directory.listSync().where(
          (FileSystemEntity entity) => entity.path.contains('.tmp-'),
        ),
        isEmpty,
      );
    });

    test('a crash before the rename leaves the previous pin intact', () {
      store.write(_record('here-a'));
      store.write(_record('here-b'));
      store.writeSelectionFor(_here, 'here-a');

      // Simulate the "temp written, rename never happened" window.
      File('${_pinPath(_here)}.tmp-999-1').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'workspaceId': _here.workspaceId,
          'sessionId': 'here-b',
        }),
      );

      expect(store.readSelectionFor(_here), 'here-a');
      // A stray temp file is not a pin and not a record.
      expect(store.readAll(), hasLength(2));
    });

    test('interrupting the real write path leaves the previous pin intact', () {
      // The test above plants the residue a crash would have left. This one
      // crashes: the interrupt fires inside the store's own write, after the
      // temp file is written and before the rename. That is the difference
      // between "a stray file is ignored" and "the write is atomic".
      store.write(_record('here-a'));
      store.write(_record('here-b'));
      store.writeSelectionFor(_here, 'here-a');
      final String before = _pinBody(_here);

      expect(
        () => runWithAtomicWriteInterrupt(
          (String target) => throw const FileSystemException('power lost'),
          () => store.writeSelectionFor(_here, 'here-b'),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(store.readSelectionFor(_here), 'here-a');
      expect(_pinBody(_here), before);
      // No half-written pin and no orphaned temp left behind either.
      expect(
        directory.listSync().where(
          (FileSystemEntity entity) => entity.path.contains('.tmp-'),
        ),
        isEmpty,
      );
      expect(store.readAll(), hasLength(2));
    });

    test('the new pin is parked in a temp file until the rename', () {
      // What makes the previous test's guarantee possible, asserted directly:
      // at the one moment a crash is observable, the target still holds the
      // old pin and the new content exists only under a temp name. An
      // in-place overwrite would fail this while still passing every
      // "residue is ignored" fixture.
      store.write(_record('here-a'));
      store.write(_record('here-b'));
      store.writeSelectionFor(_here, 'here-a');

      var observed = false;
      runWithAtomicWriteInterrupt((String target) {
        observed = true;
        expect(target, _pinPath(_here));
        expect(
          jsonDecode(File(target).readAsStringSync()),
          containsPair('sessionId', 'here-a'),
          reason: 'the target must not change before the rename',
        );
        final List<File> parked = directory
            .listSync()
            .whereType<File>()
            .where((File file) => file.path.contains('.tmp-'))
            .toList();
        expect(parked, hasLength(1));
        expect(
          jsonDecode(parked.single.readAsStringSync()),
          containsPair('sessionId', 'here-b'),
          reason: 'the new pin must already be fully written',
        );
      }, () => store.writeSelectionFor(_here, 'here-b'));

      expect(observed, isTrue);
      // Returning from the interrupt lets the rename happen, so the write
      // still completes: the seam observes, it does not change the outcome.
      expect(store.readSelectionFor(_here), 'here-b');
      expect(
        directory.listSync().where(
          (FileSystemEntity entity) => entity.path.contains('.tmp-'),
        ),
        isEmpty,
      );
    });

    test('a stale lock file does not block or corrupt the next write', () {
      store.write(_record('here-a'));
      File('${directory.path}/selection.lock').writeAsStringSync('');

      store.writeSelectionFor(_here, 'here-a');

      expect(store.readSelectionFor(_here), 'here-a');
    });

    test('concurrent scoped writes each land in their own workspace', () {
      store.write(_record('here-a'));
      store.write(_record('there-a', workspace: _there));

      store.writeSelectionFor(_here, 'here-a');
      store.writeSelectionFor(_there, 'there-a');

      expect(store.readSelectionFor(_here), 'here-a');
      expect(store.readSelectionFor(_there), 'there-a');
    });
  });

  group('capacity', () {
    test('a 257th distinct workspace is refused, not evicted into', () {
      store.write(_record('here-a'));
      for (
        var index = 0;
        index < patchbayScopedSelectionMaximumCount;
        index++
      ) {
        final PatchbayWorkspaceIdentity filler = _workspace('/filler/$index');
        final PatchbaySessionRecord record = _record(
          'filler-$index',
          workspace: filler,
        );
        store.write(record);
        store.writeSelectionFor(filler, record.sessionId);
      }

      expect(
        () => store.writeSelectionFor(_here, 'here-a'),
        throwsA(
          isA<PatchbaySessionException>().having(
            (PatchbaySessionException error) => error.code,
            'code',
            'sessionSelectionCapacityExceeded',
          ),
        ),
      );
      // Nothing that still has a record was thrown away to make room.
      expect(
        store.scopedSelectionDigests(),
        hasLength(patchbayScopedSelectionMaximumCount),
      );
      expect(store.readSelectionFor(_here), isNull);
    });

    test('re-pinning an existing workspace at the cap still works', () {
      for (
        var index = 0;
        index < patchbayScopedSelectionMaximumCount;
        index++
      ) {
        final PatchbayWorkspaceIdentity filler = _workspace('/filler/$index');
        store.write(_record('filler-$index', workspace: filler));
        store.writeSelectionFor(filler, 'filler-$index');
      }
      final PatchbayWorkspaceIdentity existing = _workspace('/filler/0');
      store.write(_record('filler-replacement', workspace: existing));

      store.writeSelectionFor(existing, 'filler-replacement');

      expect(store.readSelectionFor(existing), 'filler-replacement');
    });

    test('pins whose record is gone are cleared before the cap bites', () {
      store.write(_record('here-a'));
      for (
        var index = 0;
        index < patchbayScopedSelectionMaximumCount;
        index++
      ) {
        final PatchbayWorkspaceIdentity filler = _workspace('/filler/$index');
        store.write(_record('filler-$index', workspace: filler));
        store.writeSelectionFor(filler, 'filler-$index');
        store.remove('filler-$index');
      }

      store.writeSelectionFor(_here, 'here-a');

      expect(store.readSelectionFor(_here), 'here-a');
      expect(store.scopedSelectionDigests(), hasLength(1));
    });
  });

  group('prune', () {
    test('prune clears scoped pins with no record and the retired file', () {
      store.write(_record('here-a'));
      store.write(_record('dead', processId: 4243));
      store.writeSelectionFor(_here, 'here-a');
      store.writeSelectionFor(_there, 'dead');
      store.writeLegacyGlobalSelection('here-a');
      store.migrateLegacyGlobalSelection(_here, adoptable: (_) => false);

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (int processId) => processId != 4243,
        workspaceProbe: () => _here,
        workspaceIdentityAt: (_) => null,
      ).prune();

      expect(result.removed, <String>['dead']);
      expect(store.readSelectionFor(_here), 'here-a');
      // `dead` is gone, so the pin naming it goes with it -- in the *other*
      // workspace, without that workspace having to run anything.
      expect(store.readSelectionFor(_there), isNull);
      expect(
        File('${directory.path}/selected-session.legacy').existsSync(),
        isFalse,
      );
    });

    test('prune reports selectionCleared only for the current workspace', () {
      store.write(_record('dead', processId: 4243));
      store.writeSelectionFor(_there, 'dead');

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (int processId) => processId != 4243,
        workspaceProbe: () => _here,
        workspaceIdentityAt: (_) => null,
      ).prune();

      expect(result.removed, <String>['dead']);
      expect(result.selectionCleared, isFalse);
    });

    test('prune never removes a record that is merely foreign', () {
      store.write(_record('elsewhere', workspace: _there));

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        workspaceProbe: () => _here,
        workspaceIdentityAt: (_) => null,
      ).prune();

      expect(result.removed, isEmpty);
      expect(store.readAll().single.sessionId, 'elsewhere');
    });
  });
}

// --- fixtures -------------------------------------------------------------

final PatchbayWorkspaceIdentity _here = _workspace('/canonical/here');
final PatchbayWorkspaceIdentity _there = _workspace('/canonical/there');

PatchbayWorkspaceIdentity _workspace(String root) =>
    PatchbayWorkspaceIdentity.of(
      kind: PatchbayWorkspaceKind.gitWorktree,
      canonicalRoot: root,
    )!;

String _pinPath(PatchbayWorkspaceIdentity identity) =>
    '${directory.path}${Platform.pathSeparator}'
    'selected-session-${identity.digest}';

String _pinBody(PatchbayWorkspaceIdentity identity) =>
    File(_pinPath(identity)).readAsStringSync();

String _mode(String path) {
  final ProcessResult result = Platform.isMacOS
      ? Process.runSync('stat', <String>['-f', '%Lp', path])
      : Process.runSync('stat', <String>['-c', '%a', path]);
  expect(result.exitCode, 0);
  return result.stdout.toString().trim();
}

PatchbaySessionRecord _record(
  String id, {
  PatchbayWorkspaceIdentity? workspace,
  int processId = 4242,
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: null,
  isolateId: null,
  processId: processId,
  wsUri: 'ws://127.0.0.1:1234/auth/ws',
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 12),
  workspacePath: (workspace ?? _here).canonicalRoot,
  deviceId: 'device-1',
).withWorkspace(workspace ?? _here);
