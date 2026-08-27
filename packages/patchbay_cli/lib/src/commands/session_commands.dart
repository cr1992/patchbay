import 'dart:io';

import 'package:args/args.dart';

import '../command_registry.dart';
import '../platform/process_utils.dart';
import '../session.dart';

/// A local command answer, in both the JSON and human-readable forms the CLI prints.
final class LocalOutcome {
  const LocalOutcome(this.response, this.text);

  final Map<String, Object?> response;
  final String text;
}

/// Handler for the local `sessions`/`session` commands: list, prune, use,
/// register and unregister.
abstract final class LocalSessionCommandHandler {
  /// Runs one session-directory command: no transport, no catalog, no App.
  static LocalOutcome runLocalSessionCommand(ArgResults parsed) {
    final PatchbayFriendlyInvocation friendly =
        PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
    validateLocalSessionShape(parsed, friendly.spec);
    final PatchbaySessionResolver sessions = PatchbaySessionResolver(
      store: PatchbaySessionStore(parsed.option('session-dir')),
    );
    return switch (friendly.spec) {
      PatchbayFriendlyCommand.sessionsList => listSessions(sessions),
      PatchbayFriendlyCommand.sessionsPrune => pruneSessions(sessions),
      PatchbayFriendlyCommand.sessionUse => useSession(sessions, friendly),
      PatchbayFriendlyCommand.sessionRegister => registerSession(
        sessions,
        friendly,
      ),
      PatchbayFriendlyCommand.sessionUnregister => unregisterSession(
        sessions,
        friendly,
      ),
      _ => throw StateError(
        'unexpected local session command ${friendly.spec.name}',
      ),
    };
  }

  /// Refuses options that suggest talking to an App.
  ///
  /// `session register` is the one exception, and only for `--ws-uri`: it
  /// *records* that endpoint for later discovery instead of dialling it, which
  /// is exactly why it can stay a local command. `--session` and the direct
  /// options remain refused there too — naming an existing session, or a
  /// second transport, says nothing about the record being written.
  static void validateLocalSessionShape(
    ArgResults parsed,
    PatchbayFriendlyCommandSpec spec,
  ) {
    final bool records = spec == PatchbayFriendlyCommand.sessionRegister;
    for (final String name in const <String>[
      'ws-uri',
      'session',
      'direct-endpoint',
      'direct-token-stdin',
    ]) {
      if (!parsed.wasParsed(name)) continue;
      if (records && name == 'ws-uri') continue;
      throw FormatException(
        '--$name does not apply to a session-directory command: it works on '
        'the local launcher records, not on a running App',
      );
    }
  }

  /// Writes one record for an App this checkout started outside
  /// `patchbay launch` (PB-050-27).
  ///
  /// Deliberately no handshake: a local session command never dials, so the
  /// declared `applicationId` is reconciled the same way a launcher-declared
  /// record's is — on the first command that actually connects, which removes
  /// the record on a mismatch. What this call does own is the workspace triple:
  /// it is stamped from *this* process's checkout (PB-050-14), which is what
  /// makes the record discoverable here without `--session` and invisible to
  /// other checkouts.
  static LocalOutcome registerSession(
    PatchbaySessionResolver sessions,
    PatchbayFriendlyInvocation friendly,
  ) {
    final Map<String, Object?> arguments = friendly.arguments;
    final int processId = arguments['processId']! as int;
    final String sessionId =
        arguments['sessionId'] as String? ??
        'external-$pid-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    if (sessions.store.readAll().any(
      (PatchbaySessionRecord record) => record.sessionId == sessionId,
    )) {
      throw const PatchbaySessionException(
        'sessionAlreadyRegistered',
        hint:
            'a record with that id already exists: unregister it first, or '
            'omit <session-id> and let the CLI name this one',
      );
    }
    final PatchbayWorkspaceIdentity? workspace = sessions.workspace;
    final DateTime createdAt = DateTime.now().toUtc();
    final PatchbaySessionRecord record = PatchbaySessionRecord(
      sessionId: sessionId,
      applicationId: arguments['applicationId']! as String,
      // Both stay null exactly as a launcher-declared pending record leaves
      // them: they are the App's own answer, and nothing here has asked it.
      appInstanceId: null,
      isolateId: null,
      processId: processId,
      wsUri: arguments['wsUri']! as String,
      buildMode: arguments['buildMode']! as String,
      createdAt: createdAt,
      workspacePath: workspace?.canonicalRoot ?? _currentDirectory(),
      deviceId: arguments['deviceId']! as String,
      // The writer's own claim, and it stays `pending` because this process is
      // not the App: `live` is what a completed handshake promotes it to.
      state: PatchbaySessionStatus.pending,
      // No `expiresAtMs`: the pending TTL bounds "declared but no transport
      // yet", and this record was born with its transport.
      observedAtMs: createdAt.millisecondsSinceEpoch,
      processStartTime: PlatformProcessUtils.processStartTimeSignature(
        processId,
      ),
      workspaceIdentityVersion: workspace == null
          ? null
          : patchbayWorkspaceIdentityVersion,
      workspaceKind: workspace?.kind,
      workspaceId: workspace?.workspaceId,
    );
    sessions.store.write(record);
    final PatchbaySessionListing listing = sessions.inventory().firstWhere(
      (PatchbaySessionListing listing) => listing.record.sessionId == sessionId,
    );
    return LocalOutcome(<String, Object?>{
      'session': listing.toJson(),
    }, 'registered ${listing.label}');
  }

  /// Removes one record by id, and any pin that named it.
  ///
  /// Succeeds when the record is already gone, and says so: this is the
  /// cleanup half of [registerSession], and a trap that runs after
  /// `sessions prune` already removed a dead record must not report a failure
  /// for doing its job. `removed` is the machine-readable answer.
  static LocalOutcome unregisterSession(
    PatchbaySessionResolver sessions,
    PatchbayFriendlyInvocation friendly,
  ) {
    final String sessionId = friendly.arguments['sessionId']! as String;
    final bool existed = sessions.store.readAll().any(
      (PatchbaySessionRecord record) => record.sessionId == sessionId,
    );
    sessions.store.remove(sessionId);
    sessions.store.pruneScopedSelections();
    return LocalOutcome(
      <String, Object?>{'sessionId': sessionId, 'removed': existed},
      existed
          ? 'unregistered $sessionId'
          : 'no session record named $sessionId',
    );
  }

  /// The working directory, for a record that has no provable workspace.
  ///
  /// Reached only when the workspace probe already failed, and it fails closed
  /// for the same reason that probe does: a record has to name *some*
  /// directory, and inventing one would make it claim a checkout it never ran
  /// in.
  static String _currentDirectory() {
    try {
      final String path = Directory.current.path;
      if (path.isNotEmpty) return path;
    } on Object {
      // Falls through to the same refusal as an unreadable directory.
    }
    throw const PatchbaySessionException(
      'sessionWorkspaceUnavailable',
      hint: patchbaySessionWorkspaceUnavailableHint,
    );
  }

  static LocalOutcome listSessions(PatchbaySessionResolver sessions) {
    final List<PatchbaySessionListing> listings = sessions.inventory();
    return LocalOutcome(<String, Object?>{
      'sessions': <Map<String, Object?>>[
        for (final PatchbaySessionListing listing in listings) listing.toJson(),
      ],
      'selected': selectedId(listings),
    }, sessionLines(listings));
  }

  static LocalOutcome pruneSessions(PatchbaySessionResolver sessions) {
    final PatchbaySessionPruneResult result = sessions.prune();
    final String removed = result.removed.isEmpty
        ? 'pruned nothing'
        : 'pruned ${result.removed.length}: ${result.removed.join(', ')}';
    return LocalOutcome(
      <String, Object?>{
        'pruned': result.removed,
        'selectionCleared': result.selectionCleared,
        'sessions': <Map<String, Object?>>[
          for (final PatchbaySessionListing listing in result.remaining)
            listing.toJson(),
        ],
        'selected': selectedId(result.remaining),
      },
      <String>[
        result.selectionCleared
            ? '$removed (the pinned session was among them and is now unpinned)'
            : removed,
        sessionLines(result.remaining),
      ].join('\n'),
    );
  }

  static LocalOutcome useSession(
    PatchbaySessionResolver sessions,
    PatchbayFriendlyInvocation friendly,
  ) {
    if (friendly.arguments['clear'] == true) {
      final String? previous = sessions.selection;
      sessions.clearSelection();
      return LocalOutcome(
        <String, Object?>{'selected': null, 'previous': previous},
        previous == null
            ? 'no session was pinned'
            : 'unpinned $previous; commands without --session now require a '
                  'single discoverable session',
      );
    }
    final PatchbaySessionListing pinned = sessions.select(
      friendly.arguments['sessionId']! as String,
    );
    return LocalOutcome(<String, Object?>{
      'selected': pinned.record.sessionId,
      'session': pinned.toJson(),
    }, 'pinned ${pinned.label}');
  }

  static String? selectedId(List<PatchbaySessionListing> listings) {
    for (final PatchbaySessionListing listing in listings) {
      if (listing.selected) return listing.record.sessionId;
    }
    return null;
  }

  /// The listing block both `sessions list` and `sessions prune` print.
  static String sessionLines(List<PatchbaySessionListing> listings) {
    if (listings.isEmpty) return 'no session records';
    final List<String> lines = <String>[
      for (final PatchbaySessionListing listing in listings)
        '${listing.selected ? '*' : ' '} ${listing.label}',
    ];
    // Only sessions in *this* checkout can be ambiguous, so only they can
    // earn the "pin one" hint: two records that already belong to different
    // checkouts are not a choice the operator has to make.
    final int selectableHere = listings
        .where(
          (PatchbaySessionListing listing) =>
              listing.workspaceAffinity == PatchbayWorkspaceAffinity.current,
        )
        .length;
    if (selectableHere > 1 &&
        !listings.any((PatchbaySessionListing listing) => listing.selected)) {
      lines.add(patchbaySessionAmbiguousHint);
    }
    return lines.join('\n');
  }
}
