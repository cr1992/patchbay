import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../platform/process_utils.dart';
import 'session_models.dart';
import 'session_store.dart';
import 'workspace_identity.dart';
import 'workspace_selection.dart';

final class PatchbaySessionResolver {
  PatchbaySessionResolver({
    PatchbaySessionStore? store,
    PatchbayIdentityProbe? identityProbe,
    PatchbayPidProbe? pidProbe,
    String? Function(int processId)? processStartTimeProbe,
    PatchbaySessionClock? clock,
    PatchbayWorkspaceIdentityProbe? workspaceProbe,
    PatchbayWorkspaceIdentityAt? workspaceIdentityAt,
  }) : store = store ?? PatchbaySessionStore(),
       _identityProbe = identityProbe ?? _probeIdentity,
       _pidProbe = pidProbe ?? _isProcessAlive,
       _processStartTimeProbe = processStartTimeProbe ?? _probeProcessStartTime,
       _clock = clock ?? DateTime.now,
       _workspaceProbe = workspaceProbe ?? PatchbayWorkspaceIdentity.current,
       _workspaceIdentityAt =
           workspaceIdentityAt ?? PatchbayWorkspaceIdentity.at;

  final PatchbaySessionStore store;
  final PatchbayIdentityProbe _identityProbe;
  final PatchbayPidProbe _pidProbe;
  final String? Function(int processId) _processStartTimeProbe;
  final PatchbaySessionClock _clock;
  final PatchbayWorkspaceIdentityProbe _workspaceProbe;
  final PatchbayWorkspaceIdentityAt _workspaceIdentityAt;

  PatchbayWorkspaceIdentity? _workspace;
  bool _workspaceProbed = false;
  bool _legacyPinMigrated = false;

  /// The workspace this resolver speaks for, computed at most once.
  ///
  /// One probe per command: the Git call behind it is cheap but it is still a
  /// subprocess, and re-deriving it mid-command would also let a command that
  /// changes directory change which sessions it may see.
  PatchbayWorkspaceIdentity? get workspace {
    if (!_workspaceProbed) {
      _workspaceProbed = true;
      _workspace = _workspaceProbe();
    }
    return _workspace;
  }

  /// The scoped pin that applies here, or `null` when nothing is pinned.
  ///
  /// Never another workspace's pin, and never the retired global one.
  String? get selection {
    final PatchbayWorkspaceIdentity? identity = workspace;
    if (identity == null) return null;
    _migrateLegacyPinOnce(identity);
    return store.readSelectionFor(identity);
  }

  /// The whole directory, classified once for this workspace.
  ///
  /// This is the shared kernel input every surface uses -- resolver, local
  /// session commands, doctor and trace -- so none of them re-derives
  /// "who counts as ours" on its own.
  PatchbayWorkspaceScope scope() => PatchbayWorkspaceSelectionKernel.scope(
    records: store.readAll(),
    identity: workspace,
    scopedSelection: selection,
    identityAt: _workspaceIdentityAt,
  );

  /// Every record, with the local judgement of what state it is in.
  List<PatchbaySessionListing> inventory() {
    final PatchbayWorkspaceScope scope = this.scope();
    final String? selected = scope.scopedSelection;
    final List<PatchbaySessionListing> listings = <PatchbaySessionListing>[];
    for (final PatchbayWorkspaceCandidate candidate in scope.candidates) {
      final PatchbaySessionRecord record = candidate.record;
      final _ProcessIdentityCheck check = _checkProcessIdentity(record);
      listings.add(
        PatchbaySessionListing(
          record: record,
          status: _statusFor(record, check),
          // A pin only marks the record it names *in this workspace*: a
          // foreign record with the same id is still not what a command here
          // would use.
          selected: record.sessionId == selected && candidate.isCurrent,
          identityUnverified: check.identityUnverified,
          workspaceAffinity: candidate.affinity,
        ),
      );
    }
    return listings;
  }

  /// Removes records whose process is gone, without dialling anything.
  PatchbaySessionPruneResult prune() {
    final String? pinnedHere = selection;
    final List<String> removed = <String>[];
    for (final PatchbaySessionListing listing in inventory()) {
      if (listing.status != PatchbaySessionStatus.stale) continue;
      store.remove(listing.record.sessionId);
      removed.add(listing.record.sessionId);
    }
    // Pins are cleaned by record existence, machine-wide: a checkout whose
    // App died does not have to run `prune` itself to stop pointing at it.
    store.pruneScopedSelections();
    final bool cleared = pinnedHere != null && removed.contains(pinnedHere);
    return PatchbaySessionPruneResult(
      removed: removed,
      remaining: inventory(),
      selectionCleared: cleared,
    );
  }

  /// Pins [sessionId] for later commands that pass no `--session`.
  PatchbaySessionListing select(String sessionId) {
    final PatchbayWorkspaceScope scope = this.scope();
    final PatchbayWorkspaceSelectionPlan plan =
        PatchbayWorkspaceSelectionKernel.pin(scope, sessionId);
    if (plan.refusal case final PatchbaySessionException refusal) {
      throw refusal;
    }
    final PatchbaySessionRecord record = plan.records.single;
    final _ProcessIdentityCheck check = _checkProcessIdentity(record);
    final PatchbaySessionStatus status = _statusFor(record, check);
    if (status == PatchbaySessionStatus.stale) {
      store.remove(sessionId);
      throw const PatchbaySessionException(
        'sessionStaleProcess',
        hint:
            'that record has no live process; it has been removed — run '
            '`patchbay sessions list` and select from what is left',
      );
    }
    store.writeSelectionFor(scope.identity!, sessionId);
    return PatchbaySessionListing(
      record: record,
      status: status,
      selected: true,
      identityUnverified: check.identityUnverified,
      workspaceAffinity: PatchbayWorkspaceAffinity.current,
    );
  }

  void clearSelection() {
    final PatchbayWorkspaceIdentity? identity = workspace;
    if (identity == null) return;
    store.clearSelectionFor(identity);
  }

  /// Retires the pre-PB-050-14 global pin, once per process.
  ///
  /// Conservative on purpose: the old file only becomes this workspace's
  /// scoped pin when the record it names can be *proven* to live here.
  /// Everything else -- foreign, missing, or an unprovable legacy path --
  /// simply loses the pin. That costs one `session use`; the alternative
  /// costs a write command sent to another checkout's device.
  void _migrateLegacyPinOnce(PatchbayWorkspaceIdentity identity) {
    if (_legacyPinMigrated) return;
    _legacyPinMigrated = true;
    store.migrateLegacyGlobalSelection(
      identity,
      adoptable: (String sessionId) {
        final PatchbaySessionRecord? record = store
            .readAll()
            .where(
              (PatchbaySessionRecord record) => record.sessionId == sessionId,
            )
            .firstOrNull;
        if (record == null) return false;
        return PatchbayWorkspaceSelectionKernel.classify(
              record,
              identity,
              identityAt: _workspaceIdentityAt,
            ) ==
            PatchbayWorkspaceAffinity.current;
      },
    );
  }

  PatchbaySessionStatus statusOf(PatchbaySessionRecord record) =>
      _statusFor(record, _checkProcessIdentity(record));

  /// The wsUri/TTL half of status classification, given an already-computed
  /// process-identity verdict. Split out so [inventory], [select] and
  /// [statusOf] all derive status from exactly one probe round-trip per
  /// record instead of three call sites each dialling `ps`/`tasklist` (and,
  /// now, the start-time probe) on their own.
  PatchbaySessionStatus _statusFor(
    PatchbaySessionRecord record,
    _ProcessIdentityCheck check,
  ) {
    if (!check.alive) return PatchbaySessionStatus.stale;
    final int? expiresAtMs = record.expiresAtMs;
    if (record.wsUri == null &&
        expiresAtMs != null &&
        expiresAtMs <= _clock().toUtc().millisecondsSinceEpoch) {
      return PatchbaySessionStatus.stale;
    }
    return record.wsUri == null
        ? PatchbaySessionStatus.pending
        : PatchbaySessionStatus.live;
  }

  /// Checks whether [record]'s process is still alive and, when the record
  /// captured a launch-time signature (PB-050-18), still the same process.
  ///
  /// A record with no captured signature (written before PB-050-18) is
  /// judged on the PID alone, exactly as before this change, and flagged
  /// [_ProcessIdentityCheck.identityUnverified] for diagnostics only. The
  /// same degrade applies when the OS declines to answer the current probe:
  /// this never fails closed and kills a session it merely could not verify.
  _ProcessIdentityCheck _checkProcessIdentity(PatchbaySessionRecord record) {
    if (!_pidProbe(record.processId)) {
      return const _ProcessIdentityCheck(
        alive: false,
        identityUnverified: false,
      );
    }
    final String? expected = record.processStartTime;
    if (expected == null) {
      return const _ProcessIdentityCheck(alive: true, identityUnverified: true);
    }
    final String? current = _processStartTimeProbe(record.processId);
    if (current == null) {
      return const _ProcessIdentityCheck(alive: true, identityUnverified: true);
    }
    // A live PID whose current launch signature no longer matches what this
    // record captured is not this record's process any more -- the OS has
    // recycled the PID for something else, and the original App is gone.
    return _ProcessIdentityCheck(
      alive: current == expected,
      identityUnverified: false,
    );
  }

  /// Selects one session.
  ///
  /// Two shapes, and only two. An explicit [sessionId] is the single sanctioned
  /// way to reach across checkouts: it matches on the global inventory, still
  /// completes every liveness and runtime-identity check, and writes no pin.
  /// Everything else goes through the workspace kernel, which will refuse
  /// before it will guess.
  Future<PatchbayDiscoveredSession> resolve({String? sessionId}) async {
    final List<PatchbaySessionRecord> candidates;
    final bool pinned;
    if (sessionId != null) {
      final List<PatchbaySessionRecord> all = store.readAll();
      if (all.isEmpty) {
        throw const PatchbaySessionException(
          'sessionDirectoryEmpty',
          hint:
              'start the App under `patchbay launch -- <consumer command>` '
              'or connect explicitly with `--ws-uri <uri>`',
        );
      }
      candidates = all
          .where(
            (PatchbaySessionRecord record) => record.sessionId == sessionId,
          )
          .toList();
      if (candidates.isEmpty) {
        throw const PatchbaySessionException('sessionNotFound');
      }
      pinned = false;
    } else {
      final PatchbayWorkspaceSelectionPlan plan =
          PatchbayWorkspaceSelectionKernel.implicit(scope());
      if (plan.refusal case final PatchbaySessionException refusal) {
        throw refusal;
      }
      candidates = plan.records;
      pinned = plan.fromScopedPin;
    }

    final valid = <PatchbayDiscoveredSession>[];
    final pending = <PatchbaySessionRecord>[];
    String? lastStaleCode;
    for (final record in candidates) {
      if (!_checkProcessIdentity(record).alive) {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionStaleProcess';
        continue;
      }
      final rawUri = record.wsUri;
      if (rawUri == null) {
        pending.add(record);
        continue;
      }
      final Uri uri;
      try {
        uri = Uri.parse(rawUri);
        if (!const {'http', 'https', 'ws', 'wss'}.contains(uri.scheme)) {
          throw const FormatException();
        }
      } on FormatException {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionStaleTransport';
        continue;
      }
      final PatchbayRuntimeIdentity identity;
      try {
        identity = await _identityProbe(uri);
      } on PatchbayProtocolException {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionIdentityMismatch';
        continue;
      } on Object {
        lastStaleCode = 'sessionUnreachable';
        continue;
      }
      if (identity.schemaVersion != PatchbayServiceHost.schemaVersion ||
          identity.applicationId != record.applicationId) {
        store.remove(record.sessionId);
        lastStaleCode = 'sessionIdentityMismatch';
        continue;
      }
      if ((record.appInstanceId != null &&
              identity.appInstanceId != record.appInstanceId) ||
          (record.isolateId != null &&
              identity.isolateId != record.isolateId)) {
        lastStaleCode = 'sessionRuntimeRestarted';
      }
      final completed = _upgradedWorkspace(record.completedWith(identity));
      store.write(completed);
      valid.add(
        PatchbayDiscoveredSession(record: completed, identity: identity),
      );
    }

    if (valid.length + pending.length > 1) {
      throw PatchbaySessionException(
        'sessionAmbiguous',
        choices: <String>[
          ...valid.map((candidate) => candidate.record.choiceLabel),
          ...pending.map((record) => record.choiceLabel),
        ],
        hint: patchbaySessionAmbiguousHint,
      );
    }
    if (valid.length == 1) return valid.single;
    if (pending.isNotEmpty) {
      throw const PatchbaySessionException('sessionPending');
    }
    throw PatchbaySessionException(
      lastStaleCode ?? 'sessionNotFound',
      hint: pinned ? patchbaySessionSelectionStaleHint : null,
    );
  }

  /// Backfills the workspace triple onto a legacy record that just proved,
  /// through a completed handshake, that it belongs here.
  ///
  /// Only ever an upgrade, never a re-assignment: a record that already names
  /// a workspace keeps it, and one whose membership is unproven is left
  /// exactly as it was for an explicit `--session` to reach.
  PatchbaySessionRecord _upgradedWorkspace(PatchbaySessionRecord record) {
    if (record.hasWorkspaceIdentity) return record;
    final PatchbayWorkspaceIdentity? identity = workspace;
    if (identity == null) return record;
    if (PatchbayWorkspaceSelectionKernel.classify(
          record,
          identity,
          identityAt: _workspaceIdentityAt,
        ) !=
        PatchbayWorkspaceAffinity.current) {
      return record;
    }
    return record.withWorkspace(identity);
  }

  static Future<PatchbayRuntimeIdentity> _probeIdentity(Uri uri) async {
    final connection = await PatchbayConnection.connect(uri);
    try {
      return connection.runtimeIdentity;
    } finally {
      await connection.close();
    }
  }

  static bool _isProcessAlive(int processId) =>
      PlatformProcessUtils.isProcessAlive(processId);

  static String? _probeProcessStartTime(int processId) =>
      PlatformProcessUtils.processStartTimeSignature(processId);
}

/// One record's process-liveness verdict, split from the wsUri/TTL logic in
/// [PatchbaySessionResolver._statusFor] so every caller pays for exactly one
/// PID probe (and, when applicable, one start-time probe) per record.
final class _ProcessIdentityCheck {
  const _ProcessIdentityCheck({
    required this.alive,
    required this.identityUnverified,
  });

  /// `false` means this record's process is gone -- either the PID has no
  /// running process, or a live PID's current launch signature no longer
  /// matches what the record captured (a PID-reuse collision).
  final bool alive;

  /// See [PatchbaySessionListing.identityUnverified].
  final bool identityUnverified;
}
