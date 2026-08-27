/// PB-050-14 验证节第三组：legacy record 与全局 pin 的一次性保守迁移。
///
/// 迁移的方向是**只收紧、不发明**：路径可证明才补写身份；全局 `selected-session` 只被
/// 退役一次，且只有在它指向的记录能证明属于**当前** workspace 时才转成 scoped pin。
/// 两个进程竞领同一份旧文件时只有一个成功——降级后果是"少一个 pin"，而不是"写命令跨区"。
/// 新旧 reader 双向 golden 钉住 additive 契约：`schemaVersion` 恒为 1，老 reader 忽略三
/// 个新字段，新 reader 读老记录不删不改。
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

late Directory directory;

void main() {
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-workspace-mig-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('legacy record adoption', () {
    test('a provable legacy record is adopted and upgraded in place', () async {
      store.write(
        _legacyRecord('legacy', workspacePath: '/canonical/here/sub'),
      );

      final PatchbayDiscoveredSession resolved = await _resolver(
        store,
        // The provider, re-run on the record's own path, lands on the very
        // same checkout the command is running in.
        identityAt: (String path) =>
            path == '/canonical/here/sub' ? _here : null,
      ).resolve();

      expect(resolved.record.sessionId, 'legacy');
      final PatchbaySessionRecord upgraded = store.readAll().single;
      expect(upgraded.workspaceId, _here.workspaceId);
      expect(upgraded.workspaceKind, PatchbayWorkspaceKind.gitWorktree);
      expect(upgraded.workspaceIdentityVersion, 1);
      // The path recorded after the upgrade is the canonical root, not the
      // subdirectory the launcher happened to sit in.
      expect(upgraded.workspacePath, _here.canonicalRoot);
      expect(jsonDecode(_fileOf('legacy'))['schemaVersion'], 1);
    });

    test(
      'an unprovable legacy record is neither adopted nor deleted',
      () async {
        store.write(_legacyRecord('legacy', workspacePath: '/moved/away'));

        await expectLater(
          _resolver(store, identityAt: (_) => null).resolve(),
          throwsA(
            isA<PatchbaySessionException>().having(
              (e) => e.code,
              'code',
              'sessionWorkspaceEmpty',
            ),
          ),
        );
        // Still readable, still legacy, still selectable with an explicit id.
        final PatchbaySessionRecord kept = store.readAll().single;
        expect(kept.workspaceId, isNull);
        expect(
          (await _resolver(
            store,
            identityAt: (_) => null,
          ).resolve(sessionId: 'legacy')).record.sessionId,
          'legacy',
        );
      },
    );

    test(
      'an explicit --session never re-homes the record it reaches',
      () async {
        // The red line of the whole feature, seen from the write side. Crossing
        // checkouts explicitly completes a real handshake, and a handshake
        // proves the App is alive -- never that it belongs *here*. Backfilling
        // the workspace triple off the back of one would silently annex another
        // checkout's session, after which every later command in this checkout
        // would pick it up implicitly, with no `--session` and no warning.
        store.write(_legacyRecord('unprovable', workspacePath: '/moved/away'));
        store.write(_record('declared', workspace: _there));

        final PatchbaySessionResolver resolver = _resolver(
          store,
          identityAt: (_) => null,
        );
        expect(
          (await resolver.resolve(sessionId: 'unprovable')).record.workspaceId,
          isNull,
        );
        expect(
          (await resolver.resolve(sessionId: 'declared')).record.workspaceId,
          _there.workspaceId,
        );

        // A legacy record stays legacy: unproven membership is not upgraded by
        // being reached, only by being provable.
        final PatchbaySessionRecord unprovable = _storedRecord('unprovable');
        expect(unprovable.workspaceId, isNull);
        expect(unprovable.workspaceKind, isNull);
        expect(unprovable.workspaceIdentityVersion, isNull);
        expect(unprovable.workspacePath, '/moved/away');
        expect(
          (jsonDecode(_fileOf('unprovable')) as Map<String, Object?>)
              .containsKey('workspaceId'),
          isFalse,
        );

        // And a record that already names another checkout keeps naming it.
        expect(_storedRecord('declared').workspaceId, _there.workspaceId);
        expect(_storedRecord('declared').workspacePath, _there.canonicalRoot);

        // Neither one became implicitly selectable here.
        await expectLater(
          resolver.resolve(),
          throwsA(
            isA<PatchbaySessionException>().having(
              (e) => e.code,
              'code',
              'sessionWorkspaceEmpty',
            ),
          ),
        );
      },
    );

    test('a moved workspace path degrades to unverified, not to current', () {
      store.write(_legacyRecord('legacy', workspacePath: '/moved/away'));

      final PatchbaySessionListing listing = _resolver(
        store,
        // realpath fails for a path that no longer exists.
        identityAt: (_) => null,
      ).inventory().single;

      expect(listing.toJson()['workspaceAffinity'], 'legacyUnverified');
    });

    test('a record whose digest does not recompute is quarantined', () {
      final File planted = File('${directory.path}/tampered.json');
      planted.writeAsStringSync(
        jsonEncode(<String, Object?>{
          ..._legacyRecord('tampered').toJson(),
          'workspaceIdentityVersion': 1,
          'workspaceKind': 'gitWorktree',
          // A digest that belongs to some *other* root.
          'workspaceId': _there.workspaceId,
        }),
      );

      expect(store.readAll(), isEmpty);
      expect(planted.existsSync(), isFalse);
      expect(store.quarantinedFiles(), hasLength(1));
    });

    test('a half-written workspace triple is quarantined, not half-read', () {
      File('${directory.path}/partial.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          ..._legacyRecord('partial').toJson(),
          'workspaceKind': 'gitWorktree',
        }),
      );

      expect(store.readAll(), isEmpty);
      expect(store.quarantinedFiles(), hasLength(1));
    });
  });

  group('global pin retirement', () {
    test('a global pin proving the current workspace becomes a scoped pin', () {
      store.write(_record('here-a'));
      store.writeLegacyGlobalSelection('here-a');

      final ({bool retired, String? adopted}) outcome = store
          .migrateLegacyGlobalSelection(_here, adoptable: (_) => true);

      expect(outcome.retired, isTrue);
      expect(outcome.adopted, 'here-a');
      expect(store.readSelectionFor(_here), 'here-a');
      expect(store.readLegacyGlobalSelection(), isNull);
      expect(
        File('${directory.path}/selected-session.legacy').existsSync(),
        isTrue,
      );
    });

    test(
      'a global pin naming a foreign record is retired without adoption',
      () {
        store.write(_record('elsewhere', workspace: _there));
        store.writeLegacyGlobalSelection('elsewhere');

        final ({bool retired, String? adopted}) outcome = store
            .migrateLegacyGlobalSelection(_here, adoptable: (_) => false);

        expect(outcome.retired, isTrue);
        expect(outcome.adopted, isNull);
        expect(store.readSelectionFor(_here), isNull);
        // Retiring the pin must never remove the record it pointed at.
        expect(store.readAll().single.sessionId, 'elsewhere');
      },
    );

    test(
      'a global pin naming a missing record is retired without adoption',
      () {
        store.writeLegacyGlobalSelection('gone');

        final ({bool retired, String? adopted}) outcome = store
            .migrateLegacyGlobalSelection(_here, adoptable: (_) => false);

        expect(outcome.retired, isTrue);
        expect(outcome.adopted, isNull);
        expect(store.readSelectionFor(_here), isNull);
      },
    );

    test('only one of two racing workspaces claims the old file', () {
      store.write(_record('here-a'));
      store.writeLegacyGlobalSelection('here-a');

      final ({bool retired, String? adopted}) first = store
          .migrateLegacyGlobalSelection(_here, adoptable: (_) => true);
      final ({bool retired, String? adopted}) second = store
          .migrateLegacyGlobalSelection(_there, adoptable: (_) => true);

      expect(first.retired, isTrue);
      expect(second.retired, isFalse);
      // The loser simply has no pin; it must not inherit the winner's.
      expect(store.readSelectionFor(_there), isNull);
      expect(store.readSelectionFor(_here), 'here-a');
    });

    test('migration runs once, not again on the next command', () async {
      store.write(_record('here-a'));
      store.write(_record('here-b'));
      store.writeLegacyGlobalSelection('here-a');

      expect((await _resolver(store).resolve()).record.sessionId, 'here-a');
      store.clearSelectionFor(_here);

      // The retired file is not re-read; with the pin gone the two current
      // records are ambiguous again.
      await expectLater(
        _resolver(store).resolve(),
        throwsA(
          isA<PatchbaySessionException>().having(
            (e) => e.code,
            'code',
            'sessionAmbiguous',
          ),
        ),
      );
    });

    // The three tests above hand `adoptable` in as a constant, which pins the
    // store's half of the contract but says nothing about the predicate the
    // resolver actually supplies. These drive the real one: reading
    // `selection` is what triggers the one-shot migration.
    test('the resolver refuses to adopt a pin naming a foreign record', () {
      store.write(_record('elsewhere', workspace: _there));
      store.writeLegacyGlobalSelection('elsewhere');

      expect(_resolver(store).selection, isNull);

      // Retired, never adopted -- and the record it named is untouched.
      expect(store.readSelectionFor(_here), isNull);
      expect(store.readLegacyGlobalSelection(), isNull);
      expect(store.readAll().single.sessionId, 'elsewhere');
    });

    test('the resolver refuses to adopt a pin it cannot prove', () {
      store.write(_legacyRecord('legacy', workspacePath: '/moved/away'));
      store.writeLegacyGlobalSelection('legacy');

      // Unprovable is not "probably ours": inheriting a global pin on a
      // record whose path no longer recomputes is exactly the cross-checkout
      // misdirection the retirement exists to end.
      expect(_resolver(store, identityAt: (_) => null).selection, isNull);
      expect(store.readSelectionFor(_here), isNull);
    });

    test('the resolver adopts a pin whose record proves it belongs here', () {
      store.write(
        _legacyRecord('legacy', workspacePath: '/canonical/here/sub'),
      );
      store.writeLegacyGlobalSelection('legacy');

      // The control for the two above: the predicate is not a constant `false`
      // either -- a provable record still keeps its pin across the upgrade.
      expect(
        _resolver(
          store,
          identityAt: (String path) =>
              path == '/canonical/here/sub' ? _here : null,
        ).selection,
        'legacy',
      );
      expect(store.readSelectionFor(_here), 'legacy');
    });

    test('the scoped pin is never written back to the global file', () {
      store.write(_record('here-a'));

      _resolver(store).select('here-a');

      expect(store.readLegacyGlobalSelection(), isNull);
      expect(File('${directory.path}/selected-session').existsSync(), isFalse);
    });
  });

  group('reader compatibility golden', () {
    test('a new record keeps schemaVersion 1 and adds exactly three keys', () {
      store.write(_record('here-a'));

      final Map<String, Object?> json =
          jsonDecode(_fileOf('here-a')) as Map<String, Object?>;

      expect(json['schemaVersion'], 1);
      expect(json['workspaceIdentityVersion'], 1);
      expect(json['workspaceKind'], 'gitWorktree');
      expect(json['workspaceId'], _here.workspaceId);
      // Nothing else moved: the path field keeps its name and now holds the
      // canonical root.
      expect(json['workspacePath'], _here.canonicalRoot);
    });

    test('an old reader ignoring the three keys still parses the record', () {
      store.write(_record('here-a'));
      final Map<String, Object?> json =
          jsonDecode(_fileOf('here-a')) as Map<String, Object?>;

      // Simulate a 0.4.x reader: it only knows the frozen key set.
      final Map<String, Object?> asOldReaderSees = <String, Object?>{
        for (final MapEntry<String, Object?> entry in json.entries)
          if (!entry.key.startsWith('workspaceIdentity') &&
              entry.key != 'workspaceKind' &&
              entry.key != 'workspaceId')
            entry.key: entry.value,
      };

      final PatchbaySessionRecord reparsed = PatchbaySessionRecord.fromJson(
        asOldReaderSees,
      );
      expect(reparsed.sessionId, 'here-a');
      expect(reparsed.workspaceId, isNull);
      expect(reparsed.workspacePath, _here.canonicalRoot);
    });

    test('a new reader round-trips an old record byte-identically', () {
      final PatchbaySessionRecord legacy = _legacyRecord('legacy');
      final Map<String, Object?> before = legacy.toJson();

      final PatchbaySessionRecord reparsed = PatchbaySessionRecord.fromJson(
        before,
      );

      expect(reparsed.toJson(), before);
      expect(before.containsKey('workspaceId'), isFalse);
      expect(before['schemaVersion'], 1);
    });

    test('hot-restart completion preserves the workspace triple', () async {
      store.write(_record('here-a', appInstanceId: 'before'));

      await _resolver(store).resolve();

      final PatchbaySessionRecord completed = store.readAll().single;
      expect(completed.appInstanceId, 'instance-1');
      expect(completed.workspaceId, _here.workspaceId);
    });
  });

  group('launch context', () {
    test('a workspace-bearing context derives the record fields itself', () {
      final PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: directory.path,
        launchId: 'launch-1',
        ownerPid: 4242,
        workspace: _here,
      );

      final PatchbaySessionRecord pending = context.pendingRecord(
        sessionId: 'child',
        applicationId: 'dev.patchbay.fixture',
        processId: 4242,
        buildMode: 'debug',
        createdAt: DateTime.utc(2026, 8, 12),
        deviceId: 'device-1',
      );

      expect(pending.workspaceId, _here.workspaceId);
      expect(pending.workspacePath, _here.canonicalRoot);
    });

    test('a child reporting a different path is refused', () {
      final PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: directory.path,
        launchId: 'launch-1',
        ownerPid: 4242,
        workspace: _here,
      );

      expect(
        () => context.pendingRecord(
          sessionId: 'child',
          applicationId: 'dev.patchbay.fixture',
          processId: 4242,
          buildMode: 'debug',
          createdAt: DateTime.utc(2026, 8, 12),
          workspacePath: '/somewhere/else',
          deviceId: 'device-1',
        ),
        throwsA(
          isA<PatchbaySessionException>().having(
            (e) => e.code,
            'code',
            'sessionWorkspaceMismatch',
          ),
        ),
      );
    });

    test('an old three-field context still writes a legacy record', () {
      const PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-1',
        ownerPid: 4242,
      );

      final PatchbaySessionRecord pending = context.pendingRecord(
        sessionId: 'child',
        applicationId: 'dev.patchbay.fixture',
        processId: 4242,
        buildMode: 'debug',
        createdAt: DateTime.utc(2026, 8, 12),
        workspacePath: '/legacy/worktree',
        deviceId: 'device-1',
      );

      expect(pending.workspaceId, isNull);
      expect(pending.workspacePath, '/legacy/worktree');
    });

    test('the workspace travels through the launch environment', () {
      final PatchbayLaunchContext? parsed =
          PatchbayLaunchContext.tryFromEnvironment(<String, String>{
            PatchbayLaunchContext.sessionDirectoryKey: directory.path,
            PatchbayLaunchContext.launchIdKey: 'launch-1',
            PatchbayLaunchContext.ownerPidKey: '4242',
            ..._here.toEnvironment(),
          });

      expect(parsed?.workspace?.workspaceId, _here.workspaceId);
      expect(parsed?.workspace?.canonicalRoot, _here.canonicalRoot);
    });

    test('a tampered workspace environment is refused, not trusted', () {
      expect(
        () => PatchbayLaunchContext.tryFromEnvironment(<String, String>{
          PatchbayLaunchContext.sessionDirectoryKey: directory.path,
          PatchbayLaunchContext.launchIdKey: 'launch-1',
          PatchbayLaunchContext.ownerPidKey: '4242',
          ..._here.toEnvironment(),
          PatchbayLaunchContext.workspaceRootKey: '/somewhere/else',
        }),
        throwsA(
          isA<PatchbaySessionException>().having(
            (e) => e.code,
            'code',
            'launchContextInvalid',
          ),
        ),
      );
    });
  });
}

// --- fixtures -------------------------------------------------------------

final PatchbayWorkspaceIdentity _here = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/canonical/here',
)!;

final PatchbayWorkspaceIdentity _there = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/canonical/there',
)!;

String _fileOf(String sessionId) =>
    File('${directory.path}/$sessionId.json').readAsStringSync();

PatchbaySessionRecord _storedRecord(String sessionId) =>
    PatchbaySessionRecord.fromJson(
      jsonDecode(_fileOf(sessionId)) as Map<String, Object?>,
    );

PatchbaySessionResolver _resolver(
  PatchbaySessionStore store, {
  PatchbayWorkspaceIdentity? Function(String cwd)? identityAt,
}) => PatchbaySessionResolver(
  store: store,
  pidProbe: (_) => true,
  identityProbe: (_) async => const PatchbayRuntimeIdentity(
    schemaVersion: 1,
    applicationId: 'dev.patchbay.fixture',
    appInstanceId: 'instance-1',
    isolateId: 'isolates/1',
  ),
  workspaceProbe: () => _here,
  workspaceIdentityAt: identityAt ?? (_) => null,
);

PatchbaySessionRecord _record(
  String id, {
  String? appInstanceId,
  PatchbayWorkspaceIdentity? workspace,
}) => _legacyRecord(
  id,
  appInstanceId: appInstanceId,
  workspacePath: (workspace ?? _here).canonicalRoot,
).withWorkspace(workspace ?? _here);

PatchbaySessionRecord _legacyRecord(
  String id, {
  String? appInstanceId,
  String workspacePath = '/canonical/here',
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: appInstanceId,
  isolateId: appInstanceId == null ? null : 'isolates/old',
  processId: 4242,
  wsUri: 'ws://127.0.0.1:1234/auth/ws',
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 12),
  workspacePath: workspacePath,
  deviceId: 'device-1',
);
