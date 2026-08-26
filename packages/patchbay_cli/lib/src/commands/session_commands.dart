import 'package:args/args.dart';

import '../command_registry.dart';
import '../session.dart';

/// A local command answer, in both the JSON and human-readable forms the CLI prints.
final class LocalOutcome {
  const LocalOutcome(this.response, this.text);

  final Map<String, Object?> response;
  final String text;
}

/// Handler for local `sessions list`, `sessions prune`, and `session use` commands.
abstract final class LocalSessionCommandHandler {
  /// Runs one session-directory command: no transport, no catalog, no App.
  static LocalOutcome runLocalSessionCommand(ArgResults parsed) {
    validateLocalSessionShape(parsed);
    final PatchbayFriendlyInvocation friendly =
        PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
    final PatchbaySessionResolver sessions = PatchbaySessionResolver(
      store: PatchbaySessionStore(parsed.option('session-dir')),
    );
    return switch (friendly.spec) {
      PatchbayFriendlyCommand.sessionsList => listSessions(sessions),
      PatchbayFriendlyCommand.sessionsPrune => pruneSessions(sessions),
      PatchbayFriendlyCommand.sessionUse => useSession(sessions, friendly),
      _ => throw StateError(
        'unexpected local session command ${friendly.spec.name}',
      ),
    };
  }

  /// Refuses options that suggest talking to an App.
  static void validateLocalSessionShape(ArgResults parsed) {
    for (final String name in const <String>[
      'ws-uri',
      'session',
      'direct-endpoint',
      'direct-token-stdin',
    ]) {
      if (!parsed.wasParsed(name)) continue;
      throw FormatException(
        '--$name does not apply to a session-directory command: it reads the '
        'local launcher records, not a running App',
      );
    }
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
