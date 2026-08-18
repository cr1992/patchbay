import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-session-test-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('empty session directory fails with a stable type', () async {
    await expectLater(
      PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('instance-1'),
      ).resolve(),
      throwsA(_sessionError('sessionDirectoryEmpty')),
    );
  });

  test(
    'provisional record is atomically completed from runtime identity',
    () async {
      store.write(_record('one'));

      final resolved = await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('instance-1'),
      ).resolve();

      expect(resolved.record.appInstanceId, 'instance-1');
      expect(resolved.record.isolateId, 'isolates/1');
      expect(store.readAll().single.isComplete, isTrue);
      expect(
        directory.listSync().where((entity) => entity.path.contains('.tmp-')),
        isEmpty,
      );
    },
  );

  test(
    'dead PID is stale even when URI and old identity are present',
    () async {
      store.write(
        _record('dead', appInstanceId: 'instance-1', isolateId: 'isolates/1'),
      );

      await expectLater(
        PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => false,
          identityProbe: (_) async => _identity('instance-1'),
        ).resolve(),
        throwsA(_sessionError('sessionStaleProcess')),
      );
      expect(store.readAll(), isEmpty);
    },
  );

  test('secret-bearing records use owner-only POSIX permissions', () {
    if (Platform.isWindows) return;
    store.write(_record('permissions'));

    expect(_mode(directory.path), '700');
    expect(_mode(directory.listSync().whereType<File>().single.path), '600');
  });

  test('record file is owner-only before any secret reaches it', () {
    if (Platform.isWindows) return;
    // 上面那条只看写完之后的最终态——chmod 放在 write 之后也照样绿。真正要钉的是
    // 「文件还没有内容的时候就已经收紧」：记录里带的是 VM Service 认证 URI，
    // 按 umask 创建（通常 0644）再 chmod，中间那一小段窗口里它是可读的。
    final file = createRestrictedFileSync(
      '${directory.path}${Platform.pathSeparator}probe.tmp',
    );
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    expect(file.lengthSync(), 0, reason: '断言必须发生在写入内容之前');
    expect(_mode(file.path), '600');
  });

  test('restricted create refuses to write through a planted path', () {
    // 会话目录默认落在世界可写的系统临时目录下，别人先把同名文件放好就能读到内容。
    final path = '${directory.path}${Platform.pathSeparator}planted.tmp';
    File(path).writeAsStringSync('planted by another user');

    expect(
      () => createRestrictedFileSync(path),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('unreachable URI is reported without discarding the session', () async {
    const secret = 'ws://127.0.0.1:1/secret-token/ws';
    store.write(_record('unreachable', wsUri: secret));

    Object? failure;
    try {
      await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => throw StateError('socket $secret'),
      ).resolve();
    } on Object catch (error) {
      failure = error;
    }

    expect(failure, _sessionError('sessionUnreachable'));
    expect(failure.toString(), isNot(contains('secret-token')));
    // A momentarily unreachable App is not a dead session: the launcher writes
    // the record once per run, so discarding it here would be unrecoverable.
    expect(store.readAll(), hasLength(1));
  });

  test('a foreign application on the same URI is discarded', () async {
    store.write(_record('old', appInstanceId: 'before-restart'));

    await expectLater(
      PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => const PatchbayRuntimeIdentity(
          schemaVersion: 1,
          applicationId: 'dev.patchbay.other',
          appInstanceId: 'after-restart',
          isolateId: 'isolates/new',
        ),
      ).resolve(),
      throwsA(_sessionError('sessionIdentityMismatch')),
    );
    expect(store.readAll(), isEmpty);
  });

  test('hot restart re-pins the record instead of discarding it', () async {
    store.write(
      _record(
        'old',
        appInstanceId: 'before-restart',
        isolateId: 'isolates/old',
      ),
    );

    final PatchbayDiscoveredSession resolved = await PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      identityProbe: (_) async => _identity('after-restart'),
    ).resolve();

    // Same app, same live process, new instance: pressing `r` must not cost
    // the CLI its session.
    expect(resolved.identity.appInstanceId, 'after-restart');
    expect(store.readAll().single.appInstanceId, 'after-restart');
    expect(store.readAll().single.isolateId, 'isolates/new');
  });

  test(
    'hot restart provisional replacement accepts the new identity',
    () async {
      store.write(
        _record(
          'restart',
          appInstanceId: 'before-restart',
          isolateId: 'isolates/old',
        ),
      );
      store.write(_record('restart'));

      final resolved = await PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('after-restart'),
      ).resolve();

      expect(resolved.record.appInstanceId, 'after-restart');
    },
  );

  test('multiple worktree sessions fail closed with selectable IDs', () async {
    store.write(_record('worktree-a', workspacePath: '/repo/a'));
    store.write(_record('worktree-b', workspacePath: '/repo/b'));
    final resolver = PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      identityProbe: (_) async => _identity('instance-1'),
    );

    await expectLater(
      resolver.resolve(),
      throwsA(
        isA<PatchbaySessionException>()
            .having((error) => error.code, 'code', 'sessionAmbiguous')
            .having(
              (error) => error.choices.join(' '),
              'choices',
              allOf(contains('worktree-a'), contains('worktree-b')),
            ),
      ),
    );
    expect(
      (await resolver.resolve(sessionId: 'worktree-b')).record.sessionId,
      'worktree-b',
    );
  });

  group('sticky selection', () {
    // The priority chain is `--session` > pinned > unique, and each rung is
    // pinned down separately: a bug that collapses two of them still looks
    // correct from the third.
    test('an explicit --session outranks the pinned session', () async {
      store.write(_record('worktree-a', workspacePath: '/repo/a'));
      store.write(_record('worktree-b', workspacePath: '/repo/b'));
      store.writeSelection('worktree-b');

      final PatchbayDiscoveredSession resolved = await _resolver(
        store,
      ).resolve(sessionId: 'worktree-a');

      expect(resolved.record.sessionId, 'worktree-a');
      // Naming one session for one command must not re-pin anything.
      expect(store.readSelection(), 'worktree-b');
    });

    test(
      'the pinned session decides what would otherwise be ambiguous',
      () async {
        store.write(_record('worktree-a', workspacePath: '/repo/a'));
        store.write(_record('worktree-b', workspacePath: '/repo/b'));
        store.writeSelection('worktree-b');

        final PatchbayDiscoveredSession resolved = await _resolver(
          store,
        ).resolve();

        expect(resolved.record.sessionId, 'worktree-b');
      },
    );

    test('a single session still resolves with nothing pinned', () async {
      store.write(_record('only'));

      expect(store.readSelection(), isNull);
      expect((await _resolver(store).resolve()).record.sessionId, 'only');
    });

    test(
      'a pin with no record left fails closed instead of guessing',
      () async {
        store.write(_record('worktree-a', workspacePath: '/repo/a'));
        store.write(_record('worktree-b', workspacePath: '/repo/b'));
        store.writeSelection('worktree-gone');

        await expectLater(
          _resolver(store).resolve(),
          throwsA(
            isA<PatchbaySessionException>()
                .having((error) => error.code, 'code', 'sessionSelectionStale')
                .having((error) => error.hint, 'hint', contains('prune')),
          ),
        );
        // Neither live session was silently substituted, and the pin is still
        // there: clearing it here would make the *next* command guess instead.
        expect(store.readSelection(), 'worktree-gone');
      },
    );

    test('a pinned session whose process died fails closed', () async {
      store.write(_record('alive', workspacePath: '/repo/a'));
      store.write(_record('dead', workspacePath: '/repo/b', processId: 4243));
      store.writeSelection('dead');

      await expectLater(
        PatchbaySessionResolver(
          store: store,
          pidProbe: (int processId) => processId != 4243,
          identityProbe: (_) async => _identity('instance-1'),
        ).resolve(),
        throwsA(
          isA<PatchbaySessionException>()
              .having((error) => error.code, 'code', 'sessionStaleProcess')
              .having((error) => error.hint, 'hint', contains('prune')),
        ),
      );
      expect(store.readAll().single.sessionId, 'alive');
    });

    test('ambiguity points at the command that would fix it', () async {
      store.write(_record('worktree-a', workspacePath: '/repo/a'));
      store.write(_record('worktree-b', workspacePath: '/repo/b'));

      await expectLater(
        _resolver(store).resolve(),
        throwsA(
          isA<PatchbaySessionException>()
              .having((error) => error.code, 'code', 'sessionAmbiguous')
              .having((error) => error.hint, 'hint', contains('session use')),
        ),
      );
    });

    test('a corrupt selection is discarded rather than obeyed', () {
      store.write(_record('only'));
      final File selection = File(
        '${directory.path}${Platform.pathSeparator}selected-session',
      )..writeAsStringSync('{"schemaVersion": 1, "sessionId": 42}');

      expect(store.readSelection(), isNull);
      // Discarded, not left to be re-read as something else next time.
      expect(selection.existsSync(), isFalse);
    });

    test('the selection file is not mistaken for a session record', () {
      store.write(_record('only'));
      store.writeSelection('only');

      // `readAll` deletes every `.json` file it cannot parse as a record, so a
      // selection stored under that extension would erase itself on first read.
      expect(store.readAll().map((record) => record.sessionId), <String>[
        'only',
      ]);
      expect(store.readSelection(), 'only');
    });
  });

  group('sessions list / prune / use', () {
    test('a listing never carries the URI authentication token', () {
      store.write(
        _record('worktree-a', wsUri: 'ws://127.0.0.1:1234/SeCrEt=/ws'),
      );

      final PatchbaySessionListing listing = _resolver(
        store,
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.live);
      // Host and port identify the record; the path is the credential.
      expect(listing.label, contains('ws://127.0.0.1:1234'));
      expect(listing.label, isNot(contains('SeCrEt')));
      expect(jsonEncode(listing.toJson()), isNot(contains('SeCrEt')));
      expect(listing.toJson()['endpoint'], 'ws://127.0.0.1:1234');
      expect(listing.toJson()['deviceId'], 'device-1');
    });

    test('a record with no URI yet is listed as pending', () {
      store.write(_record('starting', wsUri: null));

      final PatchbaySessionListing listing = _resolver(
        store,
      ).inventory().single;

      expect(listing.status, PatchbaySessionStatus.pending);
      expect(listing.toJson()['endpoint'], isNull);
    });

    test('prune removes dead records and keeps live ones', () {
      store.write(_record('alive'));
      store.write(_record('dead', processId: 4243));
      store.writeSelection('alive');

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (int processId) => processId != 4243,
      ).prune();

      expect(result.removed, <String>['dead']);
      expect(result.remaining.single.record.sessionId, 'alive');
      expect(result.selectionCleared, isFalse);
      expect(store.readSelection(), 'alive');
    });

    test('prune unpins only when it removed the pinned record', () {
      store.write(_record('alive'));
      store.write(_record('dead', processId: 4243));
      store.writeSelection('dead');

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (int processId) => processId != 4243,
      ).prune();

      expect(result.selectionCleared, isTrue);
      expect(store.readSelection(), isNull);
    });

    test('prune deterministically removes an expired pending record', () {
      final DateTime now = DateTime.utc(2026, 8, 18);
      const PatchbayLaunchContext context = PatchbayLaunchContext(
        sessionDirectory: '/unused',
        launchId: 'launch-expired',
        ownerPid: 4242,
      );
      store.write(
        context.pendingRecord(
          sessionId: 'expired',
          applicationId: 'dev.patchbay.fixture',
          processId: 4242,
          buildMode: 'debug',
          createdAt: now.subtract(const Duration(minutes: 6)),
          workspacePath: '/repo/worktree',
          deviceId: 'device-1',
        ),
      );
      store.writeSelection('expired');

      final PatchbaySessionPruneResult result = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        clock: () => now,
      ).prune();

      expect(result.removed, <String>['expired']);
      expect(result.selectionCleared, isTrue);
      expect(store.readSelection(), isNull);
    });

    test('use refuses an id that has no record', () {
      store.write(_record('worktree-a'));

      expect(
        () => _resolver(store).select('worktree-z'),
        throwsA(_sessionError('sessionNotFound')),
      );
      expect(store.readSelection(), isNull);
    });

    test('use refuses to pin a record whose process is gone', () {
      store.write(_record('dead', processId: 4243));

      expect(
        () => PatchbaySessionResolver(
          store: store,
          pidProbe: (int processId) => processId != 4243,
        ).select('dead'),
        throwsA(_sessionError('sessionStaleProcess')),
      );
      expect(store.readSelection(), isNull);
    });
  });

  test('live provisional record without URI is reported as pending', () async {
    store.write(_record('pending', wsUri: null));

    await expectLater(
      PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('instance-1'),
      ).resolve(),
      throwsA(_sessionError('sessionPending')),
    );
  });

  test('pending second worktree prevents implicit selection', () async {
    store.write(_record('ready'));
    store.write(_record('starting', wsUri: null));

    await expectLater(
      PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('instance-1'),
      ).resolve(),
      throwsA(_sessionError('sessionAmbiguous')),
    );
  });
}

String _mode(String path) {
  final result = Platform.isMacOS
      ? Process.runSync('stat', ['-f', '%Lp', path])
      : Process.runSync('stat', ['-c', '%a', path]);
  expect(result.exitCode, 0);
  return result.stdout.toString().trim();
}

/// A resolver whose probes both answer "alive and the same App".
PatchbaySessionResolver _resolver(PatchbaySessionStore store) =>
    PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      identityProbe: (_) async => _identity('instance-1'),
    );

Matcher _sessionError(String code) =>
    isA<PatchbaySessionException>().having((error) => error.code, 'code', code);

PatchbayRuntimeIdentity _identity(String instance) => PatchbayRuntimeIdentity(
  schemaVersion: 1,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: instance,
  isolateId: instance == 'instance-1' ? 'isolates/1' : 'isolates/new',
);

PatchbaySessionRecord _record(
  String id, {
  String? appInstanceId,
  String? isolateId,
  String? wsUri = 'ws://127.0.0.1:1234/auth/ws',
  String workspacePath = '/repo/worktree',
  int processId = 4242,
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: appInstanceId,
  isolateId: isolateId,
  processId: processId,
  wsUri: wsUri,
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 12),
  workspacePath: workspacePath,
  deviceId: 'device-1',
);
