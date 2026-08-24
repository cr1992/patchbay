import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../rpc_timeout.dart';
import '../session.dart';
import 'doctor_models.dart';

/// Reads the local session directory and judges what a command would do next.
PatchbayDoctorFinding patchbaySessionDirectoryFinding(ArgResults options) {
  final String? namedEndpoint = options.option('ws-uri') != null
      ? 'ws-uri'
      : options.option('direct-endpoint') != null
      ? 'direct-endpoint'
      : null;
  if (namedEndpoint != null) {
    return skippedFinding(
      PatchbayDoctorCheck.session,
      'the peer was named with --$namedEndpoint, so the session directory is '
      'not consulted',
    );
  }
  final PatchbaySessionStore store = PatchbaySessionStore(
    options.option('session-dir'),
  );
  final List<PatchbaySessionListing> listings;
  try {
    listings = PatchbaySessionResolver(store: store).inventory();
  } on Object catch (failure) {
    return patchbayFailureFinding(PatchbayDoctorCheck.session, failure);
  }
  final String? explicitSession = options.option('session');
  final String? pinned = explicitSession == null ? store.readSelection() : null;
  return patchbaySessionFinding(
    listings: listings,
    explicitSession: explicitSession,
    pinnedSessionId: pinned,
  );
}

/// The session verdict for one directory listing.
PatchbayDoctorFinding patchbaySessionFinding({
  required List<PatchbaySessionListing> listings,
  required String? explicitSession,
  String? pinnedSessionId,
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
    return statusFinding(named, 'the record named by --session', counts());
  }

  if (pinnedSessionId != null) {
    final PatchbaySessionListing? pinned = listings
        .where(
          (PatchbaySessionListing listing) =>
              listing.record.sessionId == pinnedSessionId,
        )
        .firstOrNull;
    if (pinned == null) {
      return PatchbayDoctorFinding(
        check: PatchbayDoctorCheck.session,
        verdict: PatchbayCheckVerdict.failed,
        observed:
            'the pinned session ($pinnedSessionId) was removed from the '
            'session directory',
        cause:
            'that App exited or was pruned; the CLI never silently falls '
            'back to another session',
        action: patchbaySessionSelectionStaleHint,
        details: <String, Object?>{
          ...counts(),
          'code': 'sessionSelectionStale',
          'pinnedSessionId': pinnedSessionId,
        },
      );
    }
    return statusFinding(pinned, 'the pinned record', counts());
  }

  final PatchbaySessionListing? pinned = listings
      .where((PatchbaySessionListing listing) => listing.selected)
      .firstOrNull;
  if (pinned != null) {
    return statusFinding(pinned, 'the pinned record', counts());
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
  return statusFinding(candidates.single, 'the only live record', counts());
}

/// Turns one record's local status into a verdict.
PatchbayDoctorFinding statusFinding(
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
    return const PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.connection,
      verdict: PatchbayCheckVerdict.failed,
      observed: 'the identity handshake answered without an App identity',
      cause: 'the peer is not a Patchbay host, or its schema is incompatible',
      action: 'check that the App registers the Patchbay service host',
      details: <String, Object?>{'code': 'identityValidationFailed'},
    );
  }
  final String? serverVersion;
  final Set<String>? features;
  try {
    serverVersion = patchbayReportedServerVersion(identity);
    features = patchbayDeclaredFeatures(identity);
  } on PatchbayProtocolException catch (failure) {
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.connection,
      verdict: PatchbayCheckVerdict.warning,
      observed:
          'connected to $applicationId (instance $appInstanceId), but the '
          'identity answer carries a malformed serverVersion or features',
      cause:
          'the host writes those protocol-owned fields itself; a wrong type '
          'there is a host bug, not a version difference',
      action:
          'read `patchbay --json identity` and compare it with the wire '
          'contract',
      details: <String, Object?>{
        'applicationId': applicationId,
        'appInstanceId': appInstanceId,
        'code': failure.code,
      },
    );
  }
  return PatchbayDoctorFinding(
    check: PatchbayDoctorCheck.connection,
    verdict: PatchbayCheckVerdict.ok,
    observed: serverVersion == null
        ? 'connected to $applicationId (instance $appInstanceId); the host '
              'does not report its patchbay version'
        : 'connected to $applicationId (instance $appInstanceId) running '
              'patchbay $serverVersion',
    cause: serverVersion == null
        ? 'the App is built against a patchbay older than the one that '
              'introduced serverVersion'
        : null,
    details: <String, Object?>{
      'applicationId': applicationId,
      'appInstanceId': appInstanceId,
      if (identity['schemaVersion'] case final int schema)
        'schemaVersion': schema,
      if (serverVersion != null) 'serverVersion': serverVersion,
      if (features != null) 'features': (features.toList()..sort()),
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
      observed: 'the App refused to serve its catalog${suffixHelper(code)}',
      cause:
          'the host validates the catalog before serving it — a duplicated or '
          'invalid command name takes the whole listing down',
      action:
          'read the rejection details in `patchbay --json catalog` and fix the '
          'offending descriptor in the App',
      details: <String, Object?>{
        if (code is String) 'code': code,
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
    ...patchbayCatalogDigestDetails(catalog),
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

/// What the catalog finding says about the digest the host attached.
Map<String, Object?> patchbayCatalogDigestDetails(
  Map<String, Object?> catalog,
) {
  final PatchbayCatalogDigest? digest = PatchbayCatalogDigest.fromJson(
    catalog['catalogDigest'],
  );
  if (digest == null) return const <String, Object?>{};
  if (!digest.isRecomputable) {
    return <String, Object?>{
      'catalogDigest': digest.value,
      'catalogDigestAlgorithm': digest.algorithm,
      'catalogDigestCovers': digest.covers,
      'catalogDigestCheck': 'unsupported',
      if (!digest.coversFullyRead) 'catalogDigestCoversUnreadable': true,
    };
  }
  final String recomputed = PatchbayCatalogDigest.ofCommands(
    catalog['commands'],
  ).value;
  return <String, Object?>{
    'catalogDigest': digest.value,
    'catalogDigestCheck': digest.value == recomputed
        ? 'verified'
        : 'mismatched',
    if (digest.value != recomputed) 'catalogDigestRecomputed': recomputed,
  };
}

/// Capabilities the host declared but did not deliver in this exchange.
List<PatchbayDoctorWarning> patchbayCapabilityWarnings({
  required Map<String, Object?> identity,
  required Map<String, Object?> catalog,
}) {
  final Set<String>? features;
  try {
    features = patchbayDeclaredFeatures(identity);
  } on PatchbayProtocolException {
    return const <PatchbayDoctorWarning>[];
  }
  if (features == null) return const <PatchbayDoctorWarning>[];
  return <PatchbayDoctorWarning>[
    if (features.contains(PatchbayFeature.catalogDigest.name) &&
        PatchbayCatalogDigest.fromJson(catalog['catalogDigest']) == null &&
        catalog['admission'] != 'rejected')
      const PatchbayDoctorWarning(
        kind: patchbayCapabilityNotHonouredWarningKind,
        path: 'catalogDigest',
        message:
            'the host declares the catalogDigest capability but its catalog '
            'carries no digest, so a consumer cannot tell whether the '
            'declared command surface changed',
      ),
  ];
}

/// Sends the probe and turns its answer into the lifecycle verdict.
Future<PatchbayDoctorFinding> probePatchbayLifecycle(
  PatchbayClient connection,
  Map<String, Object?> catalog, {
  Map<String, Object?> identity = const <String, Object?>{},
}) async {
  if (!catalogDeclares(catalog, patchbayLifecycleProbeCommand)) {
    return skippedFinding(
      PatchbayDoctorCheck.lifecycle,
      'this App does not register $patchbayLifecycleProbeCommand, so there is '
      'no read-only UI probe to gate on the lifecycle',
    );
  }
  final Map<String, Object?> response = await connection.invoke(
    command: patchbayLifecycleProbeCommand,
    arguments: const <String, Object?>{'maxDepth': 0, 'maxNodes': 1},
  );
  return patchbayLifecycleFinding(response, identity: identity);
}

/// The lifecycle verdict for one probe response.
PatchbayDoctorFinding patchbayLifecycleFinding(
  Map<String, Object?> response, {
  Map<String, Object?> identity = const <String, Object?>{},
}) {
  if (response['admission'] != 'rejected') {
    return const PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.lifecycle,
      verdict: PatchbayCheckVerdict.ok,
      observed: 'the App answered a read-only UI probe, so it is resumed',
      details: <String, Object?>{
        'lifecycleState': 'resumed',
        'lifecycleStateSource': patchbayLifecycleStateHostReported,
      },
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
    final String source = state is String
        ? patchbayLifecycleStateHostReported
        : lifecycleFeatureDeclared(identity)
        ? patchbayLifecycleStateNotHonoured
        : patchbayLifecycleStateFeatureUndeclared;
    return PatchbayDoctorFinding(
      check: PatchbayDoctorCheck.lifecycle,
      verdict: PatchbayCheckVerdict.failed,
      observed:
          'the UI plane refused the probe with $code '
          '(lifecycleState=${state is String ? state : 'unknown'})'
          '${lifecycleSourceSuffix(source)}',
      cause:
          'a non-resumed engine produces no frames, so every ui.* and '
          'navigation write is refused fail-closed',
      action: patchbayWakeAction,
      details: <String, Object?>{
        'code': code,
        'lifecycleState': state is String ? state : 'unknown',
        'lifecycleStateSource': source,
      },
    );
  }
  return PatchbayDoctorFinding(
    check: PatchbayDoctorCheck.lifecycle,
    verdict: PatchbayCheckVerdict.warning,
    observed: 'the UI probe was refused${suffixHelper(code)}',
    cause:
        'a consumer gate or the UI bridge refused it; the lifecycle itself is '
        'not what this answer is about',
    action: 'read the gates this command declares in `patchbay --json catalog`',
    details: <String, Object?>{if (code is String) 'code': code},
  );
}

String lifecycleSourceSuffix(String source) => switch (source) {
  patchbayLifecycleStateFeatureUndeclared =>
    ' — this host declares no lifecycle reporting, so the state is not '
        'something it withheld',
  patchbayLifecycleStateNotHonoured =>
    ' — the host declares lifecycle reporting but sent no state, which is a '
        'host bug',
  _ => '',
};

bool lifecycleFeatureDeclared(Map<String, Object?> identity) {
  try {
    return patchbayDeclaredFeatures(
          identity,
        )?.contains(PatchbayFeature.lifecycleState.name) ??
        false;
  } on PatchbayProtocolException {
    return false;
  }
}

/// The banner a session prints when it opens against a non-resumed App.
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
String? patchbayLifecycleBannerFor(Map<String, Object?> response) =>
    patchbayLifecycleBanner(patchbayLifecycleFinding(response));

/// Reads the snapshot and reports any live business session it declares.
Future<List<PatchbayDoctorWarning>> readSnapshotWarnings(
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
            'the snapshot could not be read (${failureCode(failure)}), so '
            'doctor cannot tell whether a business session is live on the '
            'device: $patchbayDestructiveRecoveryWarning',
      ),
    ];
  }
  return patchbayActiveSessionWarnings(snapshot);
}

const int _activeScanDepth = 5;
const int _activeScanLimit = 8;

/// Finds the places where an App's own snapshot says a session is active.
List<PatchbayDoctorWarning> patchbayActiveSessionWarnings(
  Map<String, Object?> snapshot,
) {
  final List<String> paths = <String>[];
  for (final MapEntry<String, Object?> entry in snapshot.entries) {
    if (entry.key == 'schemaVersion') continue;
    collectActivePaths(entry.key, entry.value, paths, 1);
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

void collectActivePaths(
  String path,
  Object? value,
  List<String> found,
  int depth,
) {
  if (found.length >= _activeScanLimit || depth > _activeScanDepth) return;
  if (value is List<Object?>) {
    for (var index = 0; index < value.length; index += 1) {
      collectActivePaths('$path[$index]', value[index], found, depth + 1);
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
    collectActivePaths('$path.$key', entry.value, found, depth + 1);
  }
}

/// Turns one thrown failure into a finding for [check].
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

String failureCode(Object failure) => switch (failure) {
  PatchbayTransportException(:final String code) => code,
  PatchbayProtocolException(:final String code) => code,
  PatchbaySessionException(:final String code) => code,
  _ => '${failure.runtimeType}',
};

PatchbayDoctorFinding skippedFinding(
  PatchbayDoctorCheck check,
  String reason,
) => PatchbayDoctorFinding(
  check: check,
  verdict: PatchbayCheckVerdict.skipped,
  observed: reason,
);

String suffixHelper(Object? code) => code is String ? ': $code' : '';

bool catalogDeclares(Map<String, Object?> catalog, String command) {
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
