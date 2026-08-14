import 'package:args/args.dart';

import 'client.dart';
import 'result.dart';
import 'rpc_timeout.dart';
import 'session.dart';

/// The four things that have to hold before any other command can work.
///
/// They are ordered as they depend on each other: a session has to be
/// selectable before a connection can be opened, a connection before a catalog
/// can be read, and a catalog before the UI plane can be probed at all. Doctor
/// runs them in this order and marks the rest [PatchbayCheckVerdict.skipped]
/// once one fails, so a report never claims to have checked something it could
/// not reach.
enum PatchbayDoctorCheck {
  /// The local launcher session directory: which records exist, which one a
  /// command without `--session` would pick.
  session,

  /// Dialling the App and completing the identity handshake.
  connection,

  /// Reading the capability listing the App serves.
  catalog,

  /// Whether the App is `resumed`, i.e. whether the UI plane will answer.
  lifecycle,
}

/// What one check concluded.
enum PatchbayCheckVerdict {
  /// Nothing to do.
  ok,

  /// Usable, but something will bite later — an ambiguous session directory,
  /// a gate that is closed, an App that registers no commands.
  warning,

  /// This check is why the CLI cannot drive the App right now.
  failed,

  /// Not run, either because an earlier check failed or because it does not
  /// apply to this invocation. Never a verdict about the thing itself.
  skipped,
}

/// One check's outcome, phrased as observation → cause → action.
///
/// The three parts are deliberately separate fields rather than one sentence:
/// [observed] is what doctor actually saw and is the only part it can promise
/// is true, while [cause] is the likeliest explanation and [action] is advice.
/// Collapsing them would let a guess be read as a measurement, which is the
/// same failure mode the `admission` envelope exists to prevent.
final class PatchbayDoctorFinding {
  const PatchbayDoctorFinding({
    required this.check,
    required this.verdict,
    required this.observed,
    this.cause,
    this.action,
    this.details = const <String, Object?>{},
  });

  final PatchbayDoctorCheck check;
  final PatchbayCheckVerdict verdict;

  /// What doctor saw. A fact, never an inference.
  final String observed;

  /// The likeliest explanation, when one check cannot prove which it is.
  final String? cause;

  /// The next thing to try, phrased as something the operator can run or do.
  final String? action;

  /// Machine-readable specifics: codes, counts, the lifecycle state.
  ///
  /// It carries no URI, token or endpoint, for the same reason the printed
  /// lines do not: doctor output is pasted into tickets and chat.
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'check': check.name,
    'verdict': verdict.name,
    'observed': observed,
    if (cause case final String value) 'cause': value,
    if (action case final String value) 'action': value,
    if (details.isNotEmpty) 'details': details,
  };
}

/// Something doctor noticed that is not one of the four checks.
final class PatchbayDoctorWarning {
  const PatchbayDoctorWarning({
    required this.kind,
    required this.message,
    this.path,
  });

  /// A stable word a script can branch on.
  final String kind;

  /// The sentence an operator reads.
  final String message;

  /// Where in the snapshot the observation came from, when it came from there.
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'message': message,
    if (path case final String value) 'path': value,
  };
}

/// Stable warning kind: the App reports a live business session.
const String patchbayActiveSessionWarningKind = 'activeSession';

/// Stable warning kind: doctor could not read the snapshot at all.
const String patchbaySnapshotUnavailableWarningKind = 'snapshotUnavailable';

/// The sentence every destructive-recovery warning ends with.
///
/// It exists because the recovery an operator reaches for when an App stops
/// answering — force-stop, kill, uninstall — is exactly the action that
/// destroys whatever the device was in the middle of. Doctor is read at
/// precisely that moment, so this is the one place the warning can still
/// arrive in time.
const String patchbayDestructiveRecoveryWarning =
    'do not force-stop, kill or uninstall the App to recover; that would '
    'interrupt live work on the device. Prefer waking the screen, bringing '
    'the App to the foreground, or waiting for the session to end.';

/// The whole diagnosis, in both the shapes the CLI prints.
final class PatchbayDoctorReport {
  const PatchbayDoctorReport({required this.findings, required this.warnings});

  final List<PatchbayDoctorFinding> findings;
  final List<PatchbayDoctorWarning> warnings;

  /// The worst verdict any check reached; [PatchbayCheckVerdict.skipped] never
  /// wins, because a skipped check describes the report rather than the App.
  PatchbayCheckVerdict get verdict {
    if (findings.any(_isFailed)) return PatchbayCheckVerdict.failed;
    if (findings.any(
      (PatchbayDoctorFinding finding) =>
          finding.verdict == PatchbayCheckVerdict.warning,
    )) {
      return PatchbayCheckVerdict.warning;
    }
    return warnings.isEmpty
        ? PatchbayCheckVerdict.ok
        : PatchbayCheckVerdict.warning;
  }

  /// The exit class of the *first* thing that broke.
  ///
  /// Doctor does not invent a code of its own: it reports the class the failed
  /// check would have produced had an ordinary command hit it, so a script
  /// branches on `patchbay doctor` exactly as it branches on the command that
  /// was failing. Warnings alone leave the code at `0` — a warning says
  /// "this will bite later", not "this is broken now".
  int get exitCode {
    for (final PatchbayDoctorFinding finding in findings) {
      if (!_isFailed(finding)) continue;
      return switch (finding.check) {
        PatchbayDoctorCheck.session ||
        PatchbayDoctorCheck.connection => PatchbayExitCode.transport,
        PatchbayDoctorCheck.catalog => PatchbayExitCode.protocol,
        // The App answered and refused: that is a rejection, not a transport
        // or protocol fault.
        PatchbayDoctorCheck.lifecycle => PatchbayExitCode.rejected,
      };
    }
    return PatchbayExitCode.accepted;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'doctor': <String, Object?>{
      'verdict': verdict.name,
      'checks': <Map<String, Object?>>[
        for (final PatchbayDoctorFinding finding in findings) finding.toJson(),
      ],
      'warnings': <Map<String, Object?>>[
        for (final PatchbayDoctorWarning warning in warnings) warning.toJson(),
      ],
    },
  };

  /// The human rendering: one line per check, indented cause/action beneath.
  String render() {
    final StringBuffer output = StringBuffer('patchbay doctor\n\n');
    for (final PatchbayDoctorFinding finding in findings) {
      output.writeln(
        '  ${finding.verdict.name.padRight(8)}'
        '${finding.check.name.padRight(12)}${finding.observed}',
      );
      if (finding.cause case final String cause) {
        output.writeln('  ${''.padRight(8)}cause       $cause');
      }
      if (finding.action case final String action) {
        output.writeln('  ${''.padRight(8)}action      $action');
      }
    }
    for (final PatchbayDoctorWarning warning in warnings) {
      output
        ..writeln()
        ..writeln('  !! ${warning.message}');
    }
    return (output
          ..writeln()
          ..writeln('  verdict: ${verdict.name}'))
        .toString();
  }

  static bool _isFailed(PatchbayDoctorFinding finding) =>
      finding.verdict == PatchbayCheckVerdict.failed;
}

/// Runs every check against one App and returns what it found.
///
/// Nothing here throws for a condition doctor is supposed to diagnose: a dead
/// session directory, an unresponsive peer and a refused catalog are its
/// output, not its failure mode. Usage errors still throw, because a
/// mistyped command is not a finding about the App.
///
/// [connect] is the same seam `runPatchbayCli` uses, so doctor dials exactly
/// the way the command it is diagnosing would have dialled.
Future<PatchbayDoctorReport> runPatchbayDoctor({
  required ArgResults options,
  required Future<PatchbayClient> Function(ArgResults options) connect,
  required Duration rpcTimeout,
}) async {
  final PatchbayDoctorFinding session = patchbaySessionDirectoryFinding(
    options,
  );
  final List<PatchbayDoctorFinding> findings = <PatchbayDoctorFinding>[session];
  final List<PatchbayDoctorWarning> warnings = <PatchbayDoctorWarning>[];

  // A session check that failed has already established there is nothing to
  // dial. Dialling anyway would spend the RPC budget re-deriving what the
  // directory said, and would report it a second time in weaker words.
  if (session.verdict == PatchbayCheckVerdict.failed) {
    return PatchbayDoctorReport(
      findings: <PatchbayDoctorFinding>[
        session,
        _skipped(
          PatchbayDoctorCheck.connection,
          'no session resolves, so there is nothing to dial',
        ),
        _skipped(PatchbayDoctorCheck.catalog, _noConnection),
        _skipped(PatchbayDoctorCheck.lifecycle, _noConnection),
      ],
      warnings: warnings,
    );
  }

  PatchbayClient? connection;
  try {
    connection = PatchbayTimeoutClient(
      await dialPatchbayUnderBudget(
        () => connect(options),
        rpcTimeout: rpcTimeout,
      ),
      rpcTimeout: rpcTimeout,
    );
    final Map<String, Object?> identity = await connection.identity();
    findings.add(patchbayIdentityFinding(identity));
  } on Object catch (failure) {
    findings.add(
      patchbayFailureFinding(PatchbayDoctorCheck.connection, failure),
    );
    findings.addAll(<PatchbayDoctorFinding>[
      _skipped(PatchbayDoctorCheck.catalog, _noConnection),
      _skipped(PatchbayDoctorCheck.lifecycle, _noConnection),
    ]);
    // The one warning that must survive a failed connection: an operator whose
    // App stopped answering is one keystroke away from force-stopping it, and
    // doctor just proved it cannot tell them whether that would destroy live
    // work.
    warnings.add(
      const PatchbayDoctorWarning(
        kind: patchbaySnapshotUnavailableWarningKind,
        message:
            'the App is unreachable, so doctor cannot tell whether a business '
            'session is live on the device: $patchbayDestructiveRecoveryWarning',
      ),
    );
    return PatchbayDoctorReport(findings: findings, warnings: warnings);
  }

  try {
    final Map<String, Object?> catalog = await connection.catalog();
    findings.add(patchbayCatalogFinding(catalog));
    warnings.addAll(await _readSnapshotWarnings(connection));
    findings.add(await probePatchbayLifecycle(connection, catalog));
  } on Object catch (failure) {
    // Reaching here means an RPC after the handshake stopped answering. The
    // check that was in flight is unknown to this frame, so the failure is
    // reported against the catalog — the first thing it could have been — and
    // the rest are skipped rather than guessed.
    findings.add(patchbayFailureFinding(PatchbayDoctorCheck.catalog, failure));
    findings.add(
      _skipped(
        PatchbayDoctorCheck.lifecycle,
        'the catalog read did not answer',
      ),
    );
  } finally {
    await closePatchbayQuietly(connection);
  }
  return PatchbayDoctorReport(findings: findings, warnings: warnings);
}

/// Reads the local session directory and judges what a command would do next.
///
/// This runs before any dial and cannot fail the way a connection can: it is
/// the check an operator needs precisely when nothing else works.
PatchbayDoctorFinding patchbaySessionDirectoryFinding(ArgResults options) {
  final String? namedEndpoint = options.option('ws-uri') != null
      ? 'ws-uri'
      : options.option('direct-endpoint') != null
      ? 'direct-endpoint'
      : null;
  if (namedEndpoint != null) {
    return _skipped(
      PatchbayDoctorCheck.session,
      'the peer was named with --$namedEndpoint, so the session directory is '
      'not consulted',
    );
  }
  final List<PatchbaySessionListing> listings;
  try {
    listings = PatchbaySessionResolver(
      store: PatchbaySessionStore(options.option('session-dir')),
    ).inventory();
  } on Object catch (failure) {
    return patchbayFailureFinding(PatchbayDoctorCheck.session, failure);
  }
  return patchbaySessionFinding(
    listings: listings,
    explicitSession: options.option('session'),
  );
}

/// The session verdict for one directory listing. Pure, so every branch of the
/// three-level selection chain is testable without a filesystem.
PatchbayDoctorFinding patchbaySessionFinding({
  required List<PatchbaySessionListing> listings,
  required String? explicitSession,
}) {
  Map<String, Object?> counts() => <String, Object?>{
    'records': listings.length,
    for (final PatchbaySessionStatus status in PatchbaySessionStatus.values)
      status.name: listings
          .where((PatchbaySessionListing listing) => listing.status == status)
          .length,
  };

  if (listings.isEmpty) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the session directory holds no records',
      cause:
          'the App was not started through a Patchbay launcher, it has not '
          'written its record yet, or --session-dir points somewhere else',
      action:
          'start the App through the launcher, or connect explicitly with '
          '--ws-uri <vm-service-uri>',
      details: counts(),
    );
  }

  if (explicitSession != null) {
    final PatchbaySessionListing? named = listings
        .where(
          (PatchbaySessionListing listing) =>
              listing.record.sessionId == explicitSession,
        )
        .firstOrNull;
    if (named == null) {
      return PatchbayDoctorFinding(
        check: PatchbayDoctorCheck.session,
        verdict: PatchbayCheckVerdict.failed,
        observed: 'no record matches --session $explicitSession',
        cause: 'the id is misspelled, or that record was already pruned',
        action: 'run `patchbay sessions list` and pick from what is there',
        details: counts(),
      );
    }
    return _statusFinding(named, 'the record named by --session', counts());
  }

  final PatchbaySessionListing? pinned = listings
      .where((PatchbaySessionListing listing) => listing.selected)
      .firstOrNull;
  if (pinned != null) {
    return _statusFinding(pinned, 'the pinned record', counts());
  }

  final List<PatchbaySessionListing> candidates = listings
      .where(
        (PatchbaySessionListing listing) =>
            listing.status != PatchbaySessionStatus.stale,
      )
      .toList(growable: false);
  if (candidates.isEmpty) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.failed,
      observed:
          'every one of the ${listings.length} records belongs to a process '
          'that is gone',
      cause: 'those Apps exited; the launcher writes one record per run',
      action: 'run `patchbay sessions prune`, then start the App again',
      details: counts(),
    );
  }
  if (candidates.length > 1) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.warning,
      observed:
          '${candidates.length} sessions are selectable and none is pinned',
      cause:
          'commands without --session refuse to choose between them '
          '(sessionAmbiguous)',
      action: patchbaySessionAmbiguousHint,
      details: counts(),
    );
  }
  return _statusFinding(candidates.single, 'the only live record', counts());
}

/// Turns one record's local status into a verdict.
PatchbayDoctorFinding _statusFinding(
  PatchbaySessionListing listing,
  String subject,
  Map<String, Object?> counts,
) {
  final Map<String, Object?> details = <String, Object?>{
    ...counts,
    'sessionId': listing.record.sessionId,
    'status': listing.status.name,
  };
  return switch (listing.status) {
    // `live` is a local judgement — the process exists and a URI was written.
    // Whether the peer answers is the connection check's business, and it is
    // the next thing doctor does.
    PatchbaySessionStatus.live => PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.ok,
      observed: '$subject (${listing.record.sessionId}) is live',
      details: details,
    ),
    PatchbaySessionStatus.pending => PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.warning,
      observed:
          '$subject (${listing.record.sessionId}) has no transport URI yet',
      cause: 'the App is still starting, or the launcher has not written it',
      action: 'wait for the App to finish starting, then re-run',
      details: details,
    ),
    PatchbaySessionStatus.stale => PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.session,
      verdict: PatchbayCheckVerdict.failed,
      observed:
          '$subject (${listing.record.sessionId}) belongs to a process that '
          'is gone',
      cause: 'that App exited; the CLI never silently picks a different one',
      action: patchbaySessionSelectionStaleHint,
      details: details,
    ),
  };
}

/// The connection verdict for a completed identity handshake.
PatchbayDoctorFinding patchbayIdentityFinding(Map<String, Object?> identity) {
  final Object? applicationId = identity['applicationId'];
  final Object? appInstanceId = identity['appInstanceId'];
  if (applicationId is! String || appInstanceId is! String) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.connection,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the identity handshake answered without an App identity',
      cause: 'the peer is not a Patchbay host, or its schema is incompatible',
      action: 'check that the App registers the Patchbay service host',
      details: <String, Object?>{'code': 'identityValidationFailed'},
    );
  }
  return PatchbayDoctorFinding(
    check: PatchbayDoctorCheck.connection,
    verdict: PatchbayCheckVerdict.ok,
    observed: 'connected to $applicationId (instance $appInstanceId)',
    details: <String, Object?>{
      'applicationId': applicationId,
      'appInstanceId': appInstanceId,
      if (identity['schemaVersion'] case final int schema)
        'schemaVersion': schema,
    },
  );
}

/// The catalog verdict for one catalog response.
PatchbayDoctorFinding patchbayCatalogFinding(Map<String, Object?> catalog) {
  if (catalog['admission'] == 'rejected') {
    final Object? rejection = catalog['rejection'];
    final Map<Object?, Object?> envelope = rejection is Map<Object?, Object?>
        ? rejection
        : const <Object?, Object?>{};
    final Object? code = envelope['code'];
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.catalog,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the App refused to serve its catalog${_suffix(code)}',
      cause:
          'the host validates the catalog before serving it — a duplicated or '
          'invalid command name takes the whole listing down',
      action:
          'read the rejection details in `patchbay --json catalog` and fix the '
          'offending descriptor in the App',
      details: <String, Object?>{
        if (code is String) 'code': code,
        // Host data, passed through unchanged: the host already said which
        // descriptor it refused, and re-deriving that here would only add a
        // second opinion.
        if (envelope['details'] case final Object value) 'rejection': value,
      },
    );
  }
  final Object? commands = catalog['commands'];
  if (commands is! List<Object?>) {
    return const PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.catalog,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the catalog carries no commands list',
      cause: 'the peer answered, but not with a Patchbay catalog envelope',
      action: 'read `patchbay --json catalog` and compare it with the protocol',
      details: <String, Object?>{'code': 'catalogContractViolated'},
    );
  }
  final Object? uiTargets = catalog['uiTargets'];
  final int targets = uiTargets is List<Object?> ? uiTargets.length : 0;
  final Map<String, Object?> details = <String, Object?>{
    'commands': commands.length,
    'uiTargets': targets,
  };
  if (commands.isEmpty) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.catalog,
      verdict: PatchbayCheckVerdict.warning,
      observed: 'the App registers no commands at all',
      cause:
          'the bridges and the domain adapter were compiled out, or the '
          'composition root registered the host without them',
      action: 'check the debug-only registration in the App composition root',
      details: details,
    );
  }
  return PatchbayDoctorFinding(
    check: PatchbayDoctorCheck.catalog,
    verdict: PatchbayCheckVerdict.ok,
    observed:
        'the App registers ${commands.length} commands and $targets UI targets',
    details: details,
  );
}

/// The protocol name doctor sends to find out whether the UI plane answers.
///
/// It is the cheapest read-only command the Flutter bridge gates on the
/// lifecycle: it declares `readOnly` / no side effect, and the bounds below
/// ask for the smallest tree the bridge will build. Doctor sends a real
/// command rather than asking for a state field because "is the App resumed"
/// is only interesting as "will a UI command be answered", and that is the
/// same gate this command passes through.
const String patchbayLifecycleProbeCommand = 'ui.semantics.tree';

/// Sends the probe and turns its answer into the lifecycle verdict.
Future<PatchbayDoctorFinding> probePatchbayLifecycle(
  PatchbayClient connection,
  Map<String, Object?> catalog,
) async {
  if (!_catalogDeclares(catalog, patchbayLifecycleProbeCommand)) {
    return _skipped(
      PatchbayDoctorCheck.lifecycle,
      'this App does not register $patchbayLifecycleProbeCommand, so there is '
      'no read-only UI probe to gate on the lifecycle',
    );
  }
  final Map<String, Object?> response = await connection.invoke(
    command: patchbayLifecycleProbeCommand,
    arguments: const <String, Object?>{'maxDepth': 0, 'maxNodes': 1},
  );
  return patchbayLifecycleFinding(response);
}

/// The lifecycle verdict for one probe response.
PatchbayDoctorFinding patchbayLifecycleFinding(Map<String, Object?> response) {
  if (response['admission'] != 'rejected') {
    return const PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.lifecycle,
      verdict: PatchbayCheckVerdict.ok,
      observed: 'the App answered a read-only UI probe, so it is resumed',
      details: <String, Object?>{'lifecycleState': 'resumed'},
    );
  }
  final Object? rejection = response['rejection'];
  final Map<Object?, Object?> envelope = rejection is Map<Object?, Object?>
      ? rejection
      : const <Object?, Object?>{};
  final Object? code = envelope['code'];
  final Object? rejectionDetails = envelope['details'];
  final Object? state = rejectionDetails is Map<Object?, Object?>
      ? rejectionDetails['lifecycleState']
      : null;
  if (code is String && code.endsWith('LifecycleNotResumed')) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.lifecycle,
      verdict: PatchbayCheckVerdict.failed,
      observed:
          'the UI plane refused the probe with $code '
          '(lifecycleState=${state is String ? state : 'unknown'})',
      cause:
          'a non-resumed engine produces no frames, so every ui.* and '
          'navigation write is refused fail-closed',
      action: patchbayWakeAction,
      details: <String, Object?>{
        'code': code,
        'lifecycleState': state is String ? state : 'unknown',
      },
    );
  }
  return PatchbayDoctorFinding(
    check: PatchbayDoctorCheck.lifecycle,
    verdict: PatchbayCheckVerdict.warning,
    observed: 'the UI probe was refused${_suffix(code)}',
    cause:
        'a consumer gate or the UI bridge refused it; the lifecycle itself is '
        'not what this answer is about',
    action: 'read the gates this command declares in `patchbay --json catalog`',
    details: <String, Object?>{if (code is String) 'code': code},
  );
}

/// What to do about an App that is not resumed, per platform.
///
/// It names the commands rather than describing them because the operator is
/// reading this while the thing they were doing is blocked, and because the
/// CLI deliberately runs none of them itself: waking a device is the platform
/// tooling's job, not Patchbay's.
const String patchbayWakeAction =
    'Android: `adb shell input keyevent KEYCODE_WAKEUP` then unlock, and '
    '`adb shell svc power stayon usb` to stop it recurring. '
    'iOS: wake the device by hand (there is no system stay-awake command). '
    'Desktop: click the App window — an unfocused window is not resumed.';

/// The banner a session prints when it opens against a non-resumed App.
///
/// Returns `null` for anything that is not a lifecycle refusal: a session that
/// opens normally must stay silent, and a probe that failed for another reason
/// is the next command's news to break, not this banner's.
String? patchbayLifecycleBanner(PatchbayDoctorFinding finding) {
  if (finding.check != PatchbayDoctorCheck.lifecycle) return null;
  if (finding.verdict != PatchbayCheckVerdict.failed) return null;
  return <String>[
    'patchbay preflight: ${finding.observed}.',
    '  UI reads and writes will be refused until the App is resumed.',
    '  ${finding.action ?? patchbayWakeAction}',
    '  Run `patchbay doctor` for the full picture.',
  ].join('\n');
}

/// The banner for one command response, or `null` for anything else.
///
/// This is how a session warns without sending anything: the lifecycle is read
/// out of a refusal the App produced anyway, rather than out of a probe of the
/// CLI's own. That distinction is not stylistic — the only read-only command
/// gated on the lifecycle builds the semantics tree, which calls
/// `ensureSemantics()` and schedules frames. Doctor may do that because an
/// operator asked it to and its help says so; a session that merely opened may
/// not change the App it is about to observe.
String? patchbayLifecycleBannerFor(Map<String, Object?> response) =>
    patchbayLifecycleBanner(patchbayLifecycleFinding(response));

/// Reads the snapshot and reports any live business session it declares.
Future<List<PatchbayDoctorWarning>> _readSnapshotWarnings(
  PatchbayClient connection,
) async {
  final Map<String, Object?> snapshot;
  try {
    snapshot = await connection.snapshot();
  } on Object catch (failure) {
    return <PatchbayDoctorWarning>[
      PatchbayDoctorWarning(
        kind: patchbaySnapshotUnavailableWarningKind,
        message:
            'the snapshot could not be read (${_failureCode(failure)}), so '
            'doctor cannot tell whether a business session is live on the '
            'device: $patchbayDestructiveRecoveryWarning',
      ),
    ];
  }
  return patchbayActiveSessionWarnings(snapshot);
}

/// How many nested keys below the snapshot root the scan will walk.
///
/// Bounded because the snapshot is consumer data of unknown shape and this is
/// a diagnosis: a scan that could recurse without limit would turn "tell me
/// what is wrong" into another thing that hangs. Five levels reaches
/// `domain.a.b.c.d.active` and stops.
const int _activeScanDepth = 5;

/// How many active paths one report names before it stops listing them.
const int _activeScanLimit = 8;

/// Finds the places where an App's own snapshot says a session is active.
///
/// The rule is one word: a boolean `active` that is `true`, anywhere inside a
/// top-level snapshot domain. Doctor cannot know a consumer's vocabulary —
/// domain names never enter these packages — so it reads the App's data
/// structurally and reports the path it matched, letting the operator judge a
/// false positive in one glance. Nothing here upgrades a match into a fact
/// about the device: it is a warning about what recovery to avoid, and it says
/// which field it came from.
List<PatchbayDoctorWarning> patchbayActiveSessionWarnings(
  Map<String, Object?> snapshot,
) {
  final List<String> paths = <String>[];
  for (final MapEntry<String, Object?> entry in snapshot.entries) {
    // Protocol-owned, and never a business session.
    if (entry.key == 'schemaVersion') continue;
    _collectActivePaths(entry.key, entry.value, paths, 1);
  }
  return <PatchbayDoctorWarning>[
    for (final String path in paths)
      PatchbayDoctorWarning(
        kind: patchbayActiveSessionWarningKind,
        path: path,
        message:
            'the App reports an active session at `$path`: '
            '$patchbayDestructiveRecoveryWarning',
      ),
  ];
}

void _collectActivePaths(
  String path,
  Object? value,
  List<String> found,
  int depth,
) {
  if (found.length >= _activeScanLimit || depth > _activeScanDepth) return;
  if (value is List<Object?>) {
    for (var index = 0; index < value.length; index += 1) {
      _collectActivePaths('$path[$index]', value[index], found, depth + 1);
    }
    return;
  }
  if (value is! Map<Object?, Object?>) return;
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (found.length >= _activeScanLimit) return;
    final Object? key = entry.key;
    if (key is! String) continue;
    if (key == 'active' && entry.value == true) {
      found.add('$path.$key');
      continue;
    }
    _collectActivePaths('$path.$key', entry.value, found, depth + 1);
  }
}

/// Turns one thrown failure into a finding for [check].
///
/// The classification mirrors `runPatchbayCli`'s own error arms so doctor
/// names a failure exactly as the command it is diagnosing would have named
/// it. An unrecognised failure contributes its type and nothing else: socket
/// exceptions echo endpoints, and a VM Service URI carries its auth token.
PatchbayDoctorFinding patchbayFailureFinding(
  PatchbayDoctorCheck check,
  Object failure,
) => switch (failure) {
  PatchbayTransportException(:final String code)
      when code == patchbayAppUnresponsiveCode =>
    PatchbayDoctorFinding(
      check: check,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the App did not answer within the RPC budget ($code)',
      cause:
          'the process is alive but stopped answering — a screen-off device '
          'whose system froze the App is the observed case',
      action:
          '$patchbayWakeAction Raise --transport-timeout-ms if the App is only '
          'slow.',
      details: const <String, Object?>{
        'code': patchbayAppUnresponsiveCode,
        'hint': patchbayAppUnresponsiveHint,
      },
    ),
  PatchbayTransportException(:final String code) => PatchbayDoctorFinding(
    check: check,
    verdict: PatchbayCheckVerdict.failed,
    observed: 'the transport failed with $code',
    cause: 'nothing is listening, or the recorded endpoint no longer serves it',
    action: 'run `patchbay sessions prune`, then start the App again',
    details: <String, Object?>{'code': code},
  ),
  PatchbaySessionException(:final String code, :final String? hint) =>
    PatchbayDoctorFinding(
      check: check,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'session selection failed with $code',
      cause:
          'the selected record does not resolve to a reachable App; the CLI '
          'never falls back to another one',
      action: hint ?? 'run `patchbay sessions list` and select again',
      details: <String, Object?>{'code': code, if (hint != null) 'hint': hint},
    ),
  PatchbayProtocolException(:final String code) => PatchbayDoctorFinding(
    check: check,
    verdict: PatchbayCheckVerdict.failed,
    observed: 'the peer answered, but not compatibly ($code)',
    cause:
        'the App runs a different Patchbay schema, or the record now points at '
        'a different App',
    action:
        'align the App and CLI versions, then run `patchbay sessions prune`',
    details: <String, Object?>{'code': code},
  ),
  _ => PatchbayDoctorFinding(
    check: check,
    verdict: PatchbayCheckVerdict.failed,
    observed: 'the transport failed with ${failure.runtimeType}',
    cause: 'the endpoint refused the connection or the App is not running',
    action:
        'check that the App is running, then run `patchbay sessions list` to '
        'see what the launcher recorded',
    details: <String, Object?>{'type': '${failure.runtimeType}'},
  ),
};

String _failureCode(Object failure) => switch (failure) {
  PatchbayTransportException(:final String code) => code,
  PatchbayProtocolException(:final String code) => code,
  PatchbaySessionException(:final String code) => code,
  _ => '${failure.runtimeType}',
};

/// Why the checks downstream of a connection did not run.
const String _noConnection = 'there is no connection to reach the App with';

PatchbayDoctorFinding _skipped(PatchbayDoctorCheck check, String reason) =>
    PatchbayDoctorFinding(
      check: check,
      verdict: PatchbayCheckVerdict.skipped,
      observed: reason,
    );

String _suffix(Object? code) => code is String ? ': $code' : '';

bool _catalogDeclares(Map<String, Object?> catalog, String command) {
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return false;
  for (final Object? row in rows) {
    if (row is Map<Object?, Object?> && row['name'] == command) return true;
  }
  return false;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
