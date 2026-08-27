/// PB-050-14 验证节第二组（resolver 选择矩阵）与第四组（local / doctor / trace 同源）。
///
/// 矩阵的每一格都单独钉：一个把 scoped pin 和"当前唯一"折叠成一条路径的 bug，从另一格
/// 看仍然是绿的。贯穿全组的红线只有一条——**任何 implicit 路径都不得返回 foreign
/// record**；跨区只能由显式 `--session` 授权，且不改写任何 pin。
library;

import 'dart:convert';

import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/command_registry.dart';
import 'package:patchbay_cli/src/commands/command_parser.dart';
import 'package:patchbay_cli/src/commands/session_commands.dart';
import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_resolver.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/trace_session_ref.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
import 'package:patchbay_cli/src/session/workspace_selection.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-workspace-aff-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('selection matrix', () {
    test(
      'current scoped pin decides what would otherwise be ambiguous',
      () async {
        store.write(_record('here-a'));
        store.write(_record('here-b'));
        store.writeSelectionFor(_here, 'here-b');

        final PatchbayDiscoveredSession resolved = await _resolver(
          store,
        ).resolve();

        expect(resolved.record.sessionId, 'here-b');
      },
    );

    test('a single current candidate resolves with nothing pinned', () async {
      store.write(_record('only'));
      store.write(_record('elsewhere', workspace: _there));

      final PatchbayDiscoveredSession resolved = await _resolver(
        store,
      ).resolve();

      expect(resolved.record.sessionId, 'only');
    });

    test(
      'two current candidates are ambiguous, and only they are listed',
      () async {
        store.write(_record('here-a'));
        store.write(_record('here-b'));
        store.write(_record('elsewhere', workspace: _there));

        await expectLater(
          _resolver(store).resolve(),
          throwsA(
            isA<PatchbaySessionException>()
                .having((e) => e.code, 'code', 'sessionAmbiguous')
                .having(
                  (e) => e.choices.join(' '),
                  'choices',
                  allOf(
                    contains('here-a'),
                    contains('here-b'),
                    // Offering a foreign session as a "choice" would invite the
                    // operator to pin the wrong device.
                    isNot(contains('elsewhere')),
                  ),
                ),
          ),
        );
      },
    );

    test('a foreign-only directory refuses instead of resolving', () async {
      store.write(_record('elsewhere', workspace: _there));

      await expectLater(
        _resolver(store).resolve(),
        throwsA(
          isA<PatchbaySessionException>()
              .having((e) => e.code, 'code', 'sessionWorkspaceEmpty')
              .having((e) => e.choices, 'choices', isEmpty)
              .having((e) => e.hint, 'hint', contains('--session')),
        ),
      );
      // Refusing must not destroy another workspace's record.
      expect(store.readAll(), hasLength(1));
    });

    test(
      'a stale scoped pin never falls back to the unique candidate',
      () async {
        store.write(_record('here-a'));
        store.writeSelectionFor(_here, 'here-gone');

        await expectLater(
          _resolver(store).resolve(),
          throwsA(
            isA<PatchbaySessionException>()
                .having((e) => e.code, 'code', 'sessionSelectionStale')
                .having((e) => e.hint, 'hint', contains('prune')),
          ),
        );
        expect(store.readSelectionFor(_here), 'here-gone');
      },
    );

    test('a pin naming a foreign record is stale, not honoured', () async {
      store.write(_record('elsewhere', workspace: _there));
      store.writeSelectionFor(_here, 'elsewhere');

      await expectLater(
        _resolver(store).resolve(),
        throwsA(_sessionError('sessionSelectionStale')),
      );
    });

    test(
      'explicit --session crosses workspaces without touching the pin',
      () async {
        store.write(_record('here-a'));
        store.write(_record('elsewhere', workspace: _there));
        store.writeSelectionFor(_here, 'here-a');

        final PatchbayDiscoveredSession resolved = await _resolver(
          store,
        ).resolve(sessionId: 'elsewhere');

        expect(resolved.record.sessionId, 'elsewhere');
        // Crossing once must not re-aim the next command.
        expect(store.readSelectionFor(_here), 'here-a');
        expect(store.readSelectionFor(_there), isNull);
      },
    );

    test('explicit --session still completes the runtime handshake', () async {
      store.write(_record('elsewhere', workspace: _there));

      await expectLater(
        PatchbaySessionResolver(
          store: store,
          pidProbe: (_) => true,
          workspaceProbe: () => _here,
          identityProbe: (_) async => const PatchbayRuntimeIdentity(
            schemaVersion: 1,
            applicationId: 'dev.patchbay.other',
            appInstanceId: 'x',
            isolateId: 'isolates/x',
          ),
        ).resolve(sessionId: 'elsewhere'),
        throwsA(_sessionError('sessionIdentityMismatch')),
      );
    });

    test('a pending current candidate is pending, not ambiguous', () async {
      store.write(_record('starting', wsUri: null));
      store.write(_record('elsewhere', workspace: _there));

      await expectLater(
        _resolver(store).resolve(),
        throwsA(_sessionError('sessionPending')),
      );
    });

    test(
      'an unreachable current candidate does not fall through to foreign',
      () async {
        store.write(_record('here-a'));
        store.write(_record('elsewhere', workspace: _there));

        await expectLater(
          PatchbaySessionResolver(
            store: store,
            pidProbe: (_) => true,
            workspaceProbe: () => _here,
            identityProbe: (_) async => throw StateError('down'),
          ).resolve(),
          throwsA(_sessionError('sessionUnreachable')),
        );
      },
    );

    test('an unavailable identity refuses every implicit path', () async {
      store.write(_record('here-a'));

      final PatchbaySessionResolver resolver = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        workspaceProbe: () => null,
        identityProbe: (_) async => _identity,
      );

      await expectLater(
        resolver.resolve(),
        throwsA(_sessionError('sessionWorkspaceUnavailable')),
      );
      expect(
        () => resolver.select('here-a'),
        throwsA(_sessionError('sessionWorkspaceUnavailable')),
      );
      // Explicit selection does not depend on the current identity at all.
      expect(
        (await resolver.resolve(sessionId: 'here-a')).record.sessionId,
        'here-a',
      );
    });
  });

  group('session use', () {
    test('pins a current record into the scoped pin only', () {
      store.write(_record('here-a'));

      final PatchbaySessionListing pinned = _resolver(store).select('here-a');

      expect(pinned.selected, isTrue);
      expect(store.readSelectionFor(_here), 'here-a');
      expect(store.readSelectionFor(_there), isNull);
      expect(store.readLegacyGlobalSelection(), isNull);
    });

    test('refuses a foreign record with sessionWorkspaceMismatch', () {
      store.write(_record('elsewhere', workspace: _there));

      expect(
        () => _resolver(store).select('elsewhere'),
        throwsA(
          isA<PatchbaySessionException>()
              .having((e) => e.code, 'code', 'sessionWorkspaceMismatch')
              .having((e) => e.hint, 'hint', contains('--session')),
        ),
      );
      expect(store.readSelectionFor(_here), isNull);
      expect(store.readSelectionFor(_there), isNull);
    });

    test('refuses a legacy record whose membership cannot be proven', () {
      store.write(_legacyRecord('legacy', workspacePath: '/gone/worktree'));

      expect(
        () => _resolver(store).select('legacy'),
        throwsA(_sessionError('sessionWorkspaceMismatch')),
      );
    });

    test('--clear only clears the current workspace pin', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_here, 'here-a');
      store.writeSelectionFor(_there, 'elsewhere');

      _resolver(store).clearSelection();

      expect(store.readSelectionFor(_here), isNull);
      expect(store.readSelectionFor(_there), 'elsewhere');
    });

    test('--clear refuses when the workspace cannot be established', () {
      // Pinned while the checkout was knowable...
      store.write(_record('here-a'));
      _resolver(store).select('here-a');
      expect(store.readSelectionFor(_here), 'here-a');

      // ...and now unpinned from a process that cannot tell which checkout it
      // is in. Clearing "the pin that applies here" is meaningless without a
      // "here", so it refuses exactly like `session use <id>` does.
      final PatchbaySessionResolver blind = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        identityProbe: (_) async => _identity,
        workspaceProbe: () => null,
      );

      expect(
        blind.clearSelection,
        throwsA(
          isA<PatchbaySessionException>()
              .having((e) => e.code, 'code', 'sessionWorkspaceUnavailable')
              .having((e) => e.hint, 'hint', contains('--session')),
        ),
      );
      // The pin is still on disk: a silent success here would report "no
      // session was pinned" while every later command kept using `here-a`.
      expect(store.readSelectionFor(_here), 'here-a');
    });

    test('the --clear command reports the refusal instead of success', () {
      store.write(_record('here-a'));
      _resolver(store).select('here-a');

      final ArgResults parsed = patchbayCliParser().parse(<String>[
        '--session-dir',
        directory.path,
        'session',
        'use',
        '--clear',
      ]);
      final PatchbayFriendlyInvocation friendly =
          PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;

      expect(
        () => LocalSessionCommandHandler.useSession(
          PatchbaySessionResolver(
            store: store,
            pidProbe: (_) => true,
            identityProbe: (_) async => _identity,
            workspaceProbe: () => null,
          ),
          friendly,
        ),
        throwsA(_sessionError('sessionWorkspaceUnavailable')),
      );
      expect(store.readSelectionFor(_here), 'here-a');
    });
  });

  group('inventory and affinity', () {
    test('list keeps the global inventory but labels affinity', () {
      store.write(_record('here-a'));
      store.write(_record('elsewhere', workspace: _there));
      store.write(_legacyRecord('legacy', workspacePath: '/gone/worktree'));
      store.writeSelectionFor(_here, 'here-a');

      final List<PatchbaySessionListing> listings = _resolver(
        store,
      ).inventory();

      expect(listings, hasLength(3));
      expect(_affinityOf(listings, 'here-a'), 'current');
      expect(_affinityOf(listings, 'elsewhere'), 'foreign');
      expect(_affinityOf(listings, 'legacy'), 'legacyUnverified');
      // `selected` means "the pin that applies here", not "some pin exists".
      expect(_selectedOf(listings, 'here-a'), isTrue);
      expect(_selectedOf(listings, 'elsewhere'), isFalse);
    });

    test('no output carries an absolute workspace path', () {
      store.write(_record('here-a'));
      store.write(_record('elsewhere', workspace: _there));

      final String rendered = jsonEncode(<Object?>[
        for (final PatchbaySessionListing listing in _resolver(
          store,
        ).inventory())
          listing.toJson(),
      ]);

      expect(rendered, isNot(contains(_here.canonicalRoot)));
      expect(rendered, isNot(contains(_there.canonicalRoot)));
      for (final PatchbaySessionListing listing in _resolver(
        store,
      ).inventory()) {
        expect(listing.label, isNot(contains(_here.canonicalRoot)));
      }
    });

    test('a pin naming a record that is not ours never marks it', () {
      // The id matches the pin exactly, so id equality alone would call this
      // selected. It is not: `selected` means "what a command *here* would
      // use", and a command here would refuse this record outright
      // (`sessionSelectionStale`). Printing `*` next to it -- and answering
      // `selected: "elsewhere"` on the JSON channel -- would tell the operator
      // their next write lands on another checkout's device.
      store.write(_record('elsewhere', workspace: _there));
      store.writeSelectionFor(_here, 'elsewhere');

      final List<PatchbaySessionListing> listings = _resolver(
        store,
      ).inventory();

      expect(_affinityOf(listings, 'elsewhere'), 'foreign');
      expect(_selectedOf(listings, 'elsewhere'), isFalse);
      expect(
        LocalSessionCommandHandler.selectedId(listings),
        isNull,
        reason: 'the JSON `selected` field must agree with the listing',
      );
      expect(
        LocalSessionCommandHandler.sessionLines(listings),
        startsWith(' '),
      );
    });

    test('a pin naming an unprovable legacy record never marks it', () {
      // Same gate, the other unproven affinity: a legacy record whose path no
      // longer recomputes is not "probably ours", it is unproven.
      store.write(_legacyRecord('legacy', workspacePath: '/gone/worktree'));
      store.writeSelectionFor(_here, 'legacy');

      final List<PatchbaySessionListing> listings = _resolver(
        store,
      ).inventory();

      expect(_affinityOf(listings, 'legacy'), 'legacyUnverified');
      expect(_selectedOf(listings, 'legacy'), isFalse);
      expect(LocalSessionCommandHandler.selectedId(listings), isNull);
    });

    test('an unavailable identity proves nothing current', () {
      store.write(_record('here-a'));

      final List<PatchbaySessionListing> listings = PatchbaySessionResolver(
        store: store,
        pidProbe: (_) => true,
        workspaceProbe: () => null,
      ).inventory();

      expect(_affinityOf(listings, 'here-a'), 'legacyUnverified');
      expect(_selectedOf(listings, 'here-a'), isFalse);
    });
  });

  group('local / doctor / trace agree on one fixture', () {
    test(
      'foreign-only: all four surfaces refuse with sessionWorkspaceEmpty',
      () async {
        store.write(_record('elsewhere', workspace: _there));

        // 1) resolver
        await expectLater(
          _resolver(store).resolve(),
          throwsA(_sessionError('sessionWorkspaceEmpty')),
        );

        // 2) the shared kernel every surface consults
        final PatchbayWorkspaceSelectionPlan plan =
            PatchbayWorkspaceSelectionKernel.implicit(_resolver(store).scope());
        expect(plan.refusal?.code, 'sessionWorkspaceEmpty');
        expect(plan.records, isEmpty);

        // 3) doctor
        final PatchbayDoctorFinding finding = patchbaySessionDirectoryFinding(
          _options(directory.path),
          workspaceProbe: () => _here,
        );
        expect(finding.verdict, PatchbayCheckVerdict.failed);
        expect(finding.details['code'], 'sessionWorkspaceEmpty');
        expect(finding.details['foreign'], 1);
        expect(finding.details['current'], 0);
        expect(
          jsonEncode(finding.details),
          isNot(contains(_there.canonicalRoot)),
        );

        // 4) trace
        expect(
          patchbayTraceSessionRef(
            _options(directory.path),
            workspaceProbe: () => _here,
          ),
          isNull,
        );
      },
    );

    test(
      'one current candidate: all four surfaces name the same session',
      () async {
        store.write(_record('here-a'));
        store.write(_record('elsewhere', workspace: _there));

        expect((await _resolver(store).resolve()).record.sessionId, 'here-a');

        final PatchbayWorkspaceSelectionPlan plan =
            PatchbayWorkspaceSelectionKernel.implicit(_resolver(store).scope());
        expect(plan.refusal, isNull);
        expect(plan.records.map((r) => r.sessionId), <String>['here-a']);

        final PatchbayDoctorFinding finding = patchbaySessionDirectoryFinding(
          _options(directory.path),
          workspaceProbe: () => _here,
        );
        expect(finding.details['sessionId'], 'here-a');
        expect(finding.details['current'], 1);
        expect(finding.details['foreign'], 1);

        expect(
          patchbayTraceSessionRef(
            _options(directory.path),
            workspaceProbe: () => _here,
          )?['sessionId'],
          'here-a',
        );
      },
    );

    test('trace stays silent when the kernel is not sure', () {
      store.write(_record('here-a'));
      store.write(_record('here-b'));

      // Two current candidates: recording either one would be a guess the
      // command itself is about to refuse.
      expect(
        patchbayTraceSessionRef(
          _options(directory.path),
          workspaceProbe: () => _here,
        ),
        isNull,
      );
    });

    test('doctor reports the scoped pin, and never a foreign one', () {
      store.write(_record('here-a'));
      store.writeSelectionFor(_there, 'elsewhere');

      final PatchbayDoctorFinding finding = patchbaySessionDirectoryFinding(
        _options(directory.path),
        workspaceProbe: () => _here,
      );

      expect(finding.details['scopedPin'], isNull);
      expect(finding.details['sessionId'], 'here-a');
    });

    test('an explicit --ws-uri still bypasses the session store entirely', () {
      store.write(_record('elsewhere', workspace: _there));

      final PatchbayDoctorFinding finding = patchbaySessionDirectoryFinding(
        _options(directory.path, wsUri: 'ws://127.0.0.1:1/ws'),
        workspaceProbe: () => _here,
      );

      expect(finding.verdict, PatchbayCheckVerdict.skipped);
    });
  });
}

// --- fixtures -------------------------------------------------------------

final PatchbayWorkspaceIdentity _here = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/canonical/checkout-a',
)!;

final PatchbayWorkspaceIdentity _there = PatchbayWorkspaceIdentity.of(
  kind: PatchbayWorkspaceKind.gitWorktree,
  canonicalRoot: '/canonical/checkout-b',
)!;

const PatchbayRuntimeIdentity _identity = PatchbayRuntimeIdentity(
  schemaVersion: 1,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: 'instance-1',
  isolateId: 'isolates/1',
);

PatchbaySessionResolver _resolver(PatchbaySessionStore store) =>
    PatchbaySessionResolver(
      store: store,
      pidProbe: (_) => true,
      identityProbe: (_) async => _identity,
      workspaceProbe: () => _here,
      // No legacy record in these fixtures can be proven from disk.
      workspaceIdentityAt: (_) => null,
    );

ArgResults _options(String sessionDirectory, {String? wsUri}) =>
    patchbayCliParser().parse(<String>[
      '--session-dir',
      sessionDirectory,
      if (wsUri != null) ...<String>['--ws-uri', wsUri],
      'identity',
    ]);

Matcher _sessionError(String code) =>
    isA<PatchbaySessionException>().having((e) => e.code, 'code', code);

String? _affinityOf(List<PatchbaySessionListing> listings, String id) =>
    listings
            .firstWhere(
              (PatchbaySessionListing listing) =>
                  listing.record.sessionId == id,
            )
            .toJson()['workspaceAffinity']
        as String?;

bool _selectedOf(List<PatchbaySessionListing> listings, String id) => listings
    .firstWhere(
      (PatchbaySessionListing listing) => listing.record.sessionId == id,
    )
    .selected;

PatchbaySessionRecord _record(
  String id, {
  String? wsUri = 'ws://127.0.0.1:1234/auth/ws',
  PatchbayWorkspaceIdentity? workspace,
  int processId = 4242,
}) => _legacyRecord(
  id,
  wsUri: wsUri,
  processId: processId,
  workspacePath: (workspace ?? _here).canonicalRoot,
).withWorkspace(workspace ?? _here);

PatchbaySessionRecord _legacyRecord(
  String id, {
  String? wsUri = 'ws://127.0.0.1:1234/auth/ws',
  String workspacePath = '/canonical/checkout-a',
  int processId = 4242,
}) => PatchbaySessionRecord(
  sessionId: id,
  applicationId: 'dev.patchbay.fixture',
  appInstanceId: null,
  isolateId: null,
  processId: processId,
  wsUri: wsUri,
  buildMode: 'debug',
  createdAt: DateTime.utc(2026, 8, 12),
  workspacePath: workspacePath,
  deviceId: 'device-1',
);
