import 'session_models.dart';
import 'workspace_identity.dart';

/// One record, plus where it sits relative to the workspace asking.
final class PatchbayWorkspaceCandidate {
  const PatchbayWorkspaceCandidate({
    required this.record,
    required this.affinity,
  });

  final PatchbaySessionRecord record;
  final PatchbayWorkspaceAffinity affinity;

  bool get isCurrent => affinity == PatchbayWorkspaceAffinity.current;
}

/// The whole session directory, classified once for the current workspace.
///
/// Built by [PatchbayWorkspaceSelectionKernel.scope] and consumed by every
/// surface that has an opinion about which session a command would use:
/// the resolver, `sessions list` / `session use`, `patchbay doctor`, and the
/// trace recorder. They share this so they cannot drift into four slightly
/// different answers about the same directory.
final class PatchbayWorkspaceScope {
  const PatchbayWorkspaceScope({
    required this.identity,
    required this.candidates,
    required this.scopedSelection,
  });

  /// `null` when the current workspace could not be established at all.
  final PatchbayWorkspaceIdentity? identity;

  /// Every record in the directory, in the order the store returned them.
  final List<PatchbayWorkspaceCandidate> candidates;

  /// The scoped pin for [identity], or `null` when nothing is pinned here.
  final String? scopedSelection;

  bool get isEmpty => candidates.isEmpty;

  /// The records an implicit selection is allowed to consider.
  List<PatchbaySessionRecord> get current => <PatchbaySessionRecord>[
    for (final PatchbayWorkspaceCandidate candidate in candidates)
      if (candidate.isCurrent) candidate.record,
  ];

  int countOf(PatchbayWorkspaceAffinity affinity) => candidates
      .where(
        (PatchbayWorkspaceCandidate candidate) =>
            candidate.affinity == affinity,
      )
      .length;

  PatchbayWorkspaceAffinity affinityOf(String sessionId) =>
      candidates
          .where(
            (PatchbayWorkspaceCandidate candidate) =>
                candidate.record.sessionId == sessionId,
          )
          .map((PatchbayWorkspaceCandidate candidate) => candidate.affinity)
          .firstOrNull ??
      PatchbayWorkspaceAffinity.legacyUnverified;

  PatchbaySessionRecord? recordOf(String sessionId) => candidates
      .where(
        (PatchbayWorkspaceCandidate candidate) =>
            candidate.record.sessionId == sessionId,
      )
      .map((PatchbayWorkspaceCandidate candidate) => candidate.record)
      .firstOrNull;
}

/// What the kernel decided *before* anything is dialled.
///
/// Either a narrowed candidate list -- which the caller may still reject on
/// liveness, transport or handshake grounds -- or one stable refusal. The
/// kernel never decides a session is reachable; it only decides who is even
/// allowed to be tried.
final class PatchbayWorkspaceSelectionPlan {
  const PatchbayWorkspaceSelectionPlan.candidates(
    this.records, {
    this.fromScopedPin = false,
  }) : refusal = null;

  const PatchbayWorkspaceSelectionPlan.refused(
    PatchbaySessionException this.refusal,
  ) : records = const <PatchbaySessionRecord>[],
      fromScopedPin = false;

  final List<PatchbaySessionRecord> records;
  final PatchbaySessionException? refusal;

  /// Whether [records] came from this workspace's pin rather than uniqueness.
  final bool fromScopedPin;
}

/// The one place that answers "which sessions may this command consider".
abstract final class PatchbayWorkspaceSelectionKernel {
  /// Classifies one record against [identity].
  ///
  /// A record carrying the additive triple answers for itself. A legacy record
  /// only counts as [PatchbayWorkspaceAffinity.current] when re-running the
  /// identity provider on its own recorded path lands on exactly this
  /// identity -- which also covers the launcher that recorded a subdirectory,
  /// since the provider walks back to the same worktree root. Anything else
  /// (a moved path, an unreadable one, or no current identity at all) is
  /// unproven, and unproven is never selectable implicitly.
  static PatchbayWorkspaceAffinity classify(
    PatchbaySessionRecord record,
    PatchbayWorkspaceIdentity? identity, {
    PatchbayWorkspaceIdentityAt? identityAt,
  }) {
    if (identity == null) return PatchbayWorkspaceAffinity.legacyUnverified;
    final String? declared = record.workspaceId;
    if (declared != null) {
      return declared == identity.workspaceId
          ? PatchbayWorkspaceAffinity.current
          : PatchbayWorkspaceAffinity.foreign;
    }
    final PatchbayWorkspaceIdentity? recomputed =
        (identityAt ?? PatchbayWorkspaceIdentity.at)(record.workspacePath);
    return recomputed != null && recomputed.workspaceId == identity.workspaceId
        ? PatchbayWorkspaceAffinity.current
        : PatchbayWorkspaceAffinity.legacyUnverified;
  }

  static PatchbayWorkspaceScope scope({
    required List<PatchbaySessionRecord> records,
    required PatchbayWorkspaceIdentity? identity,
    required String? scopedSelection,
    PatchbayWorkspaceIdentityAt? identityAt,
  }) => PatchbayWorkspaceScope(
    identity: identity,
    scopedSelection: scopedSelection,
    candidates: <PatchbayWorkspaceCandidate>[
      for (final PatchbaySessionRecord record in records)
        PatchbayWorkspaceCandidate(
          record: record,
          affinity: classify(record, identity, identityAt: identityAt),
        ),
    ],
  );

  /// The selection a command with no `--session` is allowed to attempt.
  static PatchbayWorkspaceSelectionPlan implicit(PatchbayWorkspaceScope scope) {
    // An empty directory is not a workspace verdict at all -- nothing has been
    // launched anywhere -- so it keeps its own long-standing code and hint
    // instead of being reported as "this checkout owns nothing".
    if (scope.isEmpty) {
      return const PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionDirectoryEmpty',
          hint:
              'start the App under `patchbay launch -- <consumer command>`, '
              'connect explicitly with `--ws-uri <uri>`, or if the App '
              'already started on its own, register it with '
              '`patchbay session register`',
        ),
      );
    }
    if (scope.identity == null) {
      return const PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionWorkspaceUnavailable',
          hint: patchbaySessionWorkspaceUnavailableHint,
        ),
      );
    }
    final String? pinned = scope.scopedSelection;
    if (pinned != null) {
      final PatchbaySessionRecord? match = scope.current
          .where((PatchbaySessionRecord record) => record.sessionId == pinned)
          .firstOrNull;
      // A pin that no longer names a record *here* fails closed. Falling back
      // to "the only other session" would change which device the next write
      // lands on without the operator asking for it.
      if (match == null) {
        return const PatchbayWorkspaceSelectionPlan.refused(
          PatchbaySessionException(
            'sessionSelectionStale',
            hint: patchbaySessionSelectionStaleHint,
          ),
        );
      }
      return PatchbayWorkspaceSelectionPlan.candidates(<PatchbaySessionRecord>[
        match,
      ], fromScopedPin: true);
    }
    final List<PatchbaySessionRecord> current = scope.current;
    if (current.isEmpty) {
      return const PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionWorkspaceEmpty',
          hint: patchbaySessionWorkspaceEmptyHint,
        ),
      );
    }
    return PatchbayWorkspaceSelectionPlan.candidates(current);
  }

  /// The record `session use <id>` is allowed to pin here.
  static PatchbayWorkspaceSelectionPlan pin(
    PatchbayWorkspaceScope scope,
    String sessionId,
  ) {
    if (scope.identity == null) {
      return const PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionWorkspaceUnavailable',
          hint: patchbaySessionWorkspaceUnavailableHint,
        ),
      );
    }
    final PatchbaySessionRecord? record = scope.recordOf(sessionId);
    if (record == null) {
      return PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionNotFound',
          choices: choiceLabels(scope),
        ),
      );
    }
    if (scope.affinityOf(sessionId) != PatchbayWorkspaceAffinity.current) {
      return const PatchbayWorkspaceSelectionPlan.refused(
        PatchbaySessionException(
          'sessionWorkspaceMismatch',
          hint: patchbaySessionWorkspaceMismatchHint,
        ),
      );
    }
    return PatchbayWorkspaceSelectionPlan.candidates(<PatchbaySessionRecord>[
      record,
    ]);
  }

  /// Selectable labels for an error's `choices`.
  ///
  /// Current workspace only: offering a foreign session here would invite the
  /// operator to pin the very target this feature exists to keep out of reach.
  static List<String> choiceLabels(PatchbayWorkspaceScope scope) => <String>[
    for (final PatchbaySessionRecord record in scope.current)
      record.choiceLabel,
  ];
}
