import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../platform/process_utils.dart';
import 'session_models.dart';
import 'session_store.dart';

final class PatchbaySessionResolver {
  PatchbaySessionResolver({
    PatchbaySessionStore? store,
    PatchbayIdentityProbe? identityProbe,
    PatchbayPidProbe? pidProbe,
    PatchbaySessionClock? clock,
  }) : store = store ?? PatchbaySessionStore(),
       _identityProbe = identityProbe ?? _probeIdentity,
       _pidProbe = pidProbe ?? _isProcessAlive,
       _clock = clock ?? DateTime.now;

  final PatchbaySessionStore store;
  final PatchbayIdentityProbe _identityProbe;
  final PatchbayPidProbe _pidProbe;
  final PatchbaySessionClock _clock;

  /// The pinned session id, or `null` when nothing is pinned.
  String? get selection => store.readSelection();

  /// Every record, with the local judgement of what state it is in.
  List<PatchbaySessionListing> inventory() {
    final String? selected = store.readSelection();
    return <PatchbaySessionListing>[
      for (final PatchbaySessionRecord record in store.readAll())
        PatchbaySessionListing(
          record: record,
          status: statusOf(record),
          selected: record.sessionId == selected,
        ),
    ];
  }

  /// Removes records whose process is gone, without dialling anything.
  PatchbaySessionPruneResult prune() {
    final List<String> removed = <String>[];
    for (final PatchbaySessionListing listing in inventory()) {
      if (listing.status != PatchbaySessionStatus.stale) continue;
      store.remove(listing.record.sessionId);
      removed.add(listing.record.sessionId);
    }
    final String? selected = store.readSelection();
    final bool cleared = selected != null && removed.contains(selected);
    if (cleared) store.clearSelection();
    return PatchbaySessionPruneResult(
      removed: removed,
      remaining: inventory(),
      selectionCleared: cleared,
    );
  }

  /// Pins [sessionId] for later commands that pass no `--session`.
  PatchbaySessionListing select(String sessionId) {
    final List<PatchbaySessionRecord> all = store.readAll();
    final PatchbaySessionRecord? record = all
        .where((PatchbaySessionRecord record) => record.sessionId == sessionId)
        .firstOrNull;
    if (record == null) {
      throw PatchbaySessionException(
        'sessionNotFound',
        choices: <String>[
          for (final PatchbaySessionRecord candidate in all)
            candidate.choiceLabel,
        ],
      );
    }
    final PatchbaySessionStatus status = statusOf(record);
    if (status == PatchbaySessionStatus.stale) {
      store.remove(sessionId);
      throw const PatchbaySessionException(
        'sessionStaleProcess',
        hint:
            'that record has no live process; it has been removed — run '
            '`patchbay sessions list` and select from what is left',
      );
    }
    store.writeSelection(sessionId);
    return PatchbaySessionListing(
      record: record,
      status: status,
      selected: true,
    );
  }

  void clearSelection() => store.clearSelection();

  PatchbaySessionStatus statusOf(PatchbaySessionRecord record) {
    if (!_pidProbe(record.processId)) return PatchbaySessionStatus.stale;
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

  /// Selects one session: explicit id first, then the pin, then uniqueness.
  Future<PatchbayDiscoveredSession> resolve({String? sessionId}) async {
    final all = store.readAll();
    if (all.isEmpty) {
      throw const PatchbaySessionException(
        'sessionDirectoryEmpty',
        hint:
            'start the App under `patchbay launch -- <consumer command>` '
            'or connect explicitly with `--ws-uri <uri>`',
      );
    }
    final String? pinned = sessionId == null ? store.readSelection() : null;
    final String? wanted = sessionId ?? pinned;
    final candidates = wanted == null
        ? all
        : all.where((record) => record.sessionId == wanted).toList();
    if (candidates.isEmpty) {
      throw pinned == null
          ? const PatchbaySessionException('sessionNotFound')
          : const PatchbaySessionException(
              'sessionSelectionStale',
              hint: patchbaySessionSelectionStaleHint,
            );
    }

    final valid = <PatchbayDiscoveredSession>[];
    final pending = <PatchbaySessionRecord>[];
    String? lastStaleCode;
    for (final record in candidates) {
      if (!_pidProbe(record.processId)) {
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
      final completed = record.completedWith(identity);
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
      hint: pinned == null ? null : patchbaySessionSelectionStaleHint,
    );
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
}
