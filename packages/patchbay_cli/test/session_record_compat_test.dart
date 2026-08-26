/// 会话记录兼容用例：老记录喂给新 reader，新记录喂给老 reader 复刻。
///
/// 本地会话文件是仓库的第三个兼容面（见 `docs/design.md`「本地会话文件是第三个兼容
/// 面」）：`schemaVersion` 永远钉在 `1`，新字段一律松读追加、reader 逐键读、不认识的键
/// 忽略。这份用例钉的是 PB-050-18 新增的 `processStartTime` 字段两个方向都不破：
///
/// - **新 CLI 读老记录**：`test/golden/session_record_pre_identity/record.json` 是冻结
///   语料，代表任何 PB-050-18 之前的 CLI / App 写下的记录——没有 `processStartTime`。
///   当前 `PatchbaySessionRecord.fromJson` 必须原样读出，且解析出的会话在 resolver 里
///   必须还是「PID 存活就活着」的老语义，只在诊断里多一个 `identityUnverified` 标注，
///   不会被当场判死。
/// - **老 CLI 读新记录**：复刻 PB-050-18 之前 `fromJson` 的读法（不认识
///   `processStartTime` 这个键，因为当年的代码根本没有查过它），喂给当前实现真的写出
///   来的、带 `processStartTime` 的记录，断言多出来的键被安全忽略，其余字段照常读出。
///   复刻而不是导入，是因为要测的正是「当年那份代码」的行为——那份代码已经不在树里了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

const String _corpus = 'test/golden/session_record_pre_identity';

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'patchbay-session-compat-test-',
    );
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('a record frozen before launch-identity capture still parses', () {
    final Map<String, Object?> json =
        jsonDecode(File('$_corpus/record.json').readAsStringSync())
            as Map<String, Object?>;

    final PatchbaySessionRecord record = PatchbaySessionRecord.fromJson(json);

    expect(record.sessionId, 'legacy-worktree');
    expect(record.applicationId, 'dev.patchbay.fixture');
    expect(record.processId, 4242);
    expect(record.processStartTime, isNull);
  });

  test('a legacy record resolves exactly as before, flagged unverified '
      'rather than killed', () async {
    directory.createSync(recursive: true);
    File(
      '${directory.path}${Platform.pathSeparator}legacy-worktree.json',
    ).writeAsStringSync(File('$_corpus/record.json').readAsStringSync());

    final PatchbaySessionResolver resolver = PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      // PB-050-14: the corpus predates workspace identity, so it can only be
      // selected implicitly by *proving* its recorded path recomputes to the
      // checkout running the command.
      workspaceProbe: () => _legacyWorkspace,
      workspaceIdentityAt: (String path) =>
          path == '/repo/legacy-worktree' ? _legacyWorkspace : null,
      // The probe answering at all must not matter: a legacy record has
      // no captured signature to compare it against.
      processStartTimeProbe: (_) => 'irrelevant-current-signature',
      identityProbe: (_) async => const PatchbayRuntimeIdentity(
        schemaVersion: 1,
        applicationId: 'dev.patchbay.fixture',
        appInstanceId: 'instance-legacy',
        isolateId: 'isolates/legacy',
      ),
    );

    final PatchbaySessionListing listing = resolver.inventory().single;
    expect(listing.status, PatchbaySessionStatus.live);
    expect(listing.identityUnverified, isTrue);

    final PatchbayDiscoveredSession resolved = await resolver.resolve();
    expect(resolved.record.sessionId, 'legacy-worktree');
    // The one-shot upgrade: proven membership is written back so the next
    // command does not have to re-prove it from the filesystem.
    expect(store.readAll().single.workspaceId, _legacyWorkspace.workspaceId);
  });

  test('a legacy record whose path moved is kept, not adopted or deleted', () {
    directory.createSync(recursive: true);
    File(
      '${directory.path}${Platform.pathSeparator}legacy-worktree.json',
    ).writeAsStringSync(File('$_corpus/record.json').readAsStringSync());

    final PatchbaySessionListing listing = PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      workspaceProbe: () => _legacyWorkspace,
      // The recorded directory no longer resolves anywhere.
      workspaceIdentityAt: (_) => null,
    ).inventory().single;

    expect(
      listing.workspaceAffinity,
      PatchbayWorkspaceAffinity.legacyUnverified,
    );
    expect(store.readAll().single.workspaceId, isNull);
  });

  test(
    'a dead legacy record is still judged dead, same as before this change',
    () {
      directory.createSync(recursive: true);
      File(
        '${directory.path}${Platform.pathSeparator}legacy-worktree.json',
      ).writeAsStringSync(File('$_corpus/record.json').readAsStringSync());

      expect(
        () => PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => false,
          workspaceProbe: () => _legacyWorkspace,
          workspaceIdentityAt: (String path) =>
              path == '/repo/legacy-worktree' ? _legacyWorkspace : null,
        ).select('legacy-worktree'),
        throwsA(
          isA<PatchbaySessionException>().having(
            (error) => error.code,
            'code',
            'sessionStaleProcess',
          ),
        ),
      );
    },
  );

  test('the pre-PB-050-18 reader ignores processStartTime on a new record', () {
    final Map<String, Object?> written = PatchbaySessionRecord(
      sessionId: 'new-worktree',
      applicationId: 'dev.patchbay.fixture',
      appInstanceId: 'instance-1',
      isolateId: 'isolates/1',
      processId: 4242,
      wsUri: 'ws://127.0.0.1:1234/auth/ws',
      buildMode: 'debug',
      createdAt: DateTime.utc(2026, 8, 20),
      workspacePath: '/repo/new-worktree',
      deviceId: 'device-1',
      processStartTime: 'Mon Aug 25 00:00:00 2026',
    ).withWorkspace(_newWorkspace).toJson();

    final Map<String, Object?>? legacy = _readTheOldWay(written);

    expect(legacy, isNotNull);
    expect(legacy!['sessionId'], 'new-worktree');
    expect(legacy['processId'], 4242);
    // The old reader's vocabulary simply does not include these keys.
    expect(legacy.containsKey('processStartTime'), isFalse);
    expect(legacy.containsKey('workspaceId'), isFalse);
    expect(legacy.containsKey('workspaceKind'), isFalse);
    expect(legacy.containsKey('workspaceIdentityVersion'), isFalse);
    // PB-050-14 is additive: the record schema version does not move, so the
    // old reader has no reason to reject the file in the first place.
    expect(written['schemaVersion'], 1);
  });
}

/// The checkout the frozen legacy corpus was recorded in.
final PatchbayWorkspaceIdentity _legacyWorkspace = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/repo/legacy-worktree',
)!;

final PatchbayWorkspaceIdentity _newWorkspace = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/repo/new-worktree',
)!;

/// The record reader as it existed before PB-050-18 added `processStartTime`.
///
/// Reproduced rather than imported, per the same reasoning documented on
/// `protocol_compat_test.dart`: this must exercise what a CLI already on
/// disk actually does, not what the current implementation happens to do
/// now that the two have diverged.
Map<String, Object?>? _readTheOldWay(Map<String, Object?> json) {
  final Object? sessionId = json['sessionId'];
  final Object? applicationId = json['applicationId'];
  final Object? processId = json['processId'];
  final Object? buildMode = json['buildMode'];
  final Object? createdAt = json['createdAt'];
  final Object? workspacePath = json['workspacePath'];
  final Object? deviceId = json['deviceId'];
  if (json['schemaVersion'] != 1 ||
      sessionId is! String ||
      applicationId is! String ||
      processId is! int ||
      buildMode is! String ||
      createdAt is! String ||
      workspacePath is! String ||
      deviceId is! String) {
    return null;
  }
  // `processStartTime` is not in this reader's vocabulary at all -- it is
  // simply never looked up, which is the behaviour under test.
  return <String, Object?>{
    'sessionId': sessionId,
    'applicationId': applicationId,
    'processId': processId,
    'buildMode': buildMode,
    'createdAt': createdAt,
    'workspacePath': workspacePath,
    'deviceId': deviceId,
  };
}
