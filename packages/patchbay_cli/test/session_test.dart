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

  test('unreachable URI is stale and never appears in typed error', () async {
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

    expect(failure, _sessionError('sessionStaleTransport'));
    expect(failure.toString(), isNot(contains('secret-token')));
    expect(store.readAll(), isEmpty);
  });

  test('identity mismatch makes a live PID and reachable URI stale', () async {
    store.write(
      _record(
        'old',
        appInstanceId: 'before-restart',
        isolateId: 'isolates/new',
      ),
    );

    await expectLater(
      PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity('after-restart'),
      ).resolve(),
      throwsA(_sessionError('sessionIdentityMismatch')),
    );
    expect(store.readAll(), isEmpty);
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
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: appInstanceId,
  isolateId: isolateId,
  processId: 4242,
  wsUri: wsUri,
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 12),
  workspacePath: workspacePath,
  deviceId: 'device-1',
);
