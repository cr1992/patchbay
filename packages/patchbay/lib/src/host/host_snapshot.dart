import 'dart:async';
import 'dart:convert';

import '../generated/core_wire.g.dart';
import '../invocation.dart';
import '../snapshot.dart';
import 'host_models.dart';
import 'snapshot_payload.dart';

final class HostSnapshotHandler {
  HostSnapshotHandler({
    PatchbaySnapshotSource? snapshotSource,
    PatchbayVersionedSnapshotSource? versionedSnapshotSource,
    PatchbaySnapshotRetentionLimits retention =
        PatchbaySnapshotRetentionLimits.production,
    PatchbaySnapshotPayloadFreezer? snapshotFreezer,
  }) : assert((snapshotSource == null) != (versionedSnapshotSource == null)),
       _snapshot = snapshotSource,
       _versionedSnapshot = versionedSnapshotSource,
       _retention = retention,
       _snapshotFreezer =
           snapshotFreezer ??
           PatchbaySnapshotPayloadFreezer(
             limits: PatchbaySnapshotPayloadLimits.production
                 .withRunCanonicalBytes(retention.effective),
           );

  final PatchbaySnapshotSource? _snapshot;
  final PatchbayVersionedSnapshotSource? _versionedSnapshot;
  final PatchbaySnapshotRetentionLimits _retention;
  final PatchbaySnapshotPayloadFreezer _snapshotFreezer;
  final List<PatchbaySnapshotRevision> _snapshotRevisions =
      <PatchbaySnapshotRevision>[];
  var _nextSnapshotRevision = 0;
  var _retainedCanonicalBytes = 0;
  int? _contentRevision;

  /// The provider sampling this batch of callers shares, if one is running.
  ///
  /// It covers exactly the part that must not be done twice: reading the App,
  /// freezing it and committing a revision. Selection, diff, wait deadlines and
  /// response assembly stay per-caller, because merging those would let one
  /// caller's path or timeout decide another caller's answer.
  Future<PatchbaySnapshotRead>? _sampling;

  /// Canonical UTF-8 bytes currently held by retained revisions.
  int get retainedCanonicalBytes => _retainedCanonicalBytes;

  /// Revisions currently reachable for `fromRevision` diffs.
  int get retainedRevisionCount => _snapshotRevisions.length;

  /// Whether a provider sampling is currently in flight.
  bool get hasSamplingInFlight => _sampling != null;

  Future<Map<String, Object?>> dispatchSnapshot([
    Map<String, Object?>? request,
  ]) async {
    if (request == null) {
      final PatchbaySnapshotRead read = await readSnapshot();
      return read.response;
    }
    if (request.containsKey('fromRevision')) {
      final PatchbaySnapshotDiffRequest diff;
      try {
        diff = PatchbaySnapshotDiffRequest.fromWire(
          PatchbaySnapshotDiffRequestWire.fromJson(request),
        );
      } on FormatException catch (error) {
        return _rejectionEnvelope(
          'invalidSnapshotDiffRequest',
          'The snapshot diff request violates the Patchbay contract.',
          <String, Object?>{'reason': error.message},
        );
      }
      return _diffSnapshot(diff);
    }
    final PatchbaySnapshotRequest selection;
    try {
      selection = PatchbaySnapshotRequest.fromWire(
        PatchbaySnapshotRequestWire.fromJson(request),
      );
    } on FormatException catch (error) {
      return _rejectionEnvelope(
        'invalidSnapshotRequest',
        'The snapshot request violates the Patchbay selection contract.',
        <String, Object?>{'reason': error.message},
      );
    }
    return selection.isWait
        ? _awaitSnapshot(selection)
        : _selectSnapshot(selection);
  }

  Future<Map<String, Object?>> _selectSnapshot(
    PatchbaySnapshotRequest request,
  ) async {
    final PatchbaySnapshotRead read = await readSnapshot();
    if (read.violated) return read.response;
    return <String, Object?>{
      'schemaVersion': 1,
      ...read.metadata,
      'selection': PatchbaySnapshotSelection.resolve(
        read.body,
        request.path,
      ).toJson(),
    };
  }

  Future<Map<String, Object?>> _awaitSnapshot(
    PatchbaySnapshotRequest request,
  ) async {
    final Duration timeout = request.timeout!;
    final PatchbaySnapshotCondition condition = request.until!;
    final Stopwatch elapsed = Stopwatch()..start();
    var polls = 0;
    PatchbaySnapshotSelection? last;
    Map<String, Object?> body = const <String, Object?>{};
    while (true) {
      final PatchbaySnapshotRead? read = await _readSnapshotWithin(
        timeout - elapsed.elapsed,
      );
      // The budget ran out inside a sampling this caller only joined. Nothing
      // was observed, so nothing is reported as observed.
      if (read == null) break;
      if (read.violated) return read.response;
      polls += 1;
      body = read.body;
      last = PatchbaySnapshotSelection.resolve(body, request.path);
      if (elapsed.elapsed > timeout) break;
      if (last.satisfies(condition, request.value)) {
        return <String, Object?>{
          'schemaVersion': 1,
          ...read.metadata,
          'selection': last.toJson(),
          'wait': PatchbaySnapshotWaitWire(
            outcome: 'observed',
            condition: condition.wire,
            timeoutMs: timeout.inMilliseconds,
            elapsedMs: elapsed.elapsed.inMilliseconds,
            pollIntervalMs: patchbaySnapshotPollInterval.inMilliseconds,
            polls: polls,
          ).toJson(),
        };
      }
      final Duration remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < patchbaySnapshotPollInterval
            ? remaining
            : patchbaySnapshotPollInterval,
      );
    }
    return _rejectionEnvelope(
      'snapshotWaitTimeout',
      'The snapshot condition was not observed inside the declared budget.',
      <String, Object?>{
        'path': request.path,
        'condition': condition.name,
        'timeoutMs': timeout.inMilliseconds,
        'elapsedMs': elapsed.elapsed.inMilliseconds,
        'pollIntervalMs': patchbaySnapshotPollInterval.inMilliseconds,
        'polls': polls,
        // Present exactly when a poll resolved something. A wait whose budget
        // was spent inside a shared sampling saw nothing, and reporting a miss
        // it never looked for would read as "the field is absent" instead of
        // "the App never answered".
        if (last
            case final PatchbaySnapshotSelection resolved) ...<String, Object?>{
          'observed': resolved.toJson(),
          if (_unaddressableRoot(resolved, body) case final List<String> keys)
            'availableKeys': keys,
        },
      },
    );
  }

  static List<String>? _unaddressableRoot(
    PatchbaySnapshotSelection selection,
    Map<String, Object?> body,
  ) {
    if (selection.miss != PatchbaySnapshotMiss.missingKey) return null;
    final String root = selection.path.split('.').first;
    if (body.containsKey(root)) return null;
    return body.keys.toList(growable: false)..sort();
  }

  /// Reads the App snapshot, joining a sampling already in flight.
  ///
  /// Deliberately not `async`: the flight has to be published before the caller
  /// gets a chance to run, or two callers arriving in the same turn would each
  /// open one.
  Future<PatchbaySnapshotRead> readSnapshot() {
    final Future<PatchbaySnapshotRead>? joined = _sampling;
    if (joined != null) return joined;
    final Future<PatchbaySnapshotRead> flight = _sampleSnapshot();
    _sampling = flight;
    // Cleared the moment it settles, so a failure is shared by this batch and
    // retried by the next caller rather than cached. Settling is the only thing
    // that clears it: a caller giving up on its own budget says nothing about
    // whether the provider call it was watching is still running.
    unawaited(
      flight.whenComplete(() {
        if (identical(_sampling, flight)) _sampling = null;
      }),
    );
    return flight;
  }

  /// Reads the App snapshot for a caller that has [budget] left of its own.
  ///
  /// Opening a sampling and joining one are not the same wait. A caller that
  /// opens it owns the provider call and keeps the behaviour the budget has
  /// always had: the read runs to completion and the budget then decides
  /// whether that answer is still wanted, so a slow source still reports what
  /// it saw rather than nothing. A caller that *joins* is waiting on somebody
  /// else's provider call, and sharing the sampling must never mean sharing the
  /// budget — so the join is capped by what this caller has left.
  ///
  /// Returns null when the budget ran out before the shared sampling answered.
  /// Nothing is dropped at that moment: the sampling stays the sampling in
  /// flight, because one caller walking away says nothing about whether the
  /// provider call it was watching is still running. Dropping it here is what
  /// would let the next caller open a second provider call against an App that
  /// is already being sampled, and let two samplings commit out of order.
  Future<PatchbaySnapshotRead?> _readSnapshotWithin(Duration budget) async {
    final Future<PatchbaySnapshotRead>? joined = _sampling;
    if (joined == null) return readSnapshot();
    try {
      return await joined.timeout(budget);
    } on TimeoutException {
      return null;
    }
  }

  Future<PatchbaySnapshotRead> _sampleSnapshot() async {
    final Map<String, Object?> declared;
    final int? contentRevision;
    try {
      if (_versionedSnapshot case final PatchbayVersionedSnapshotSource read) {
        final PatchbaySnapshotSample sample = await read();
        final PatchbaySnapshotRead? refused = _refuseRevision(sample);
        if (refused != null) return refused;
        final PatchbaySnapshotRead? reused = _reuseRetained(sample);
        if (reused != null) return reused;
        contentRevision = sample.contentRevision;
        declared = sample.body;
      } else {
        contentRevision = null;
        declared = await _snapshot!();
      }
    } on Object catch (error) {
      return PatchbaySnapshotRead.violated(
        patchbayProviderViolationEnvelope(
          'The App snapshot source failed.',
          <String, Object?>{
            'reason': 'snapshotSourceFailed',
            'error': error.runtimeType.toString(),
          },
        ),
      );
    }
    final PatchbayFrozenSnapshotPayload frozen;
    final Object violationToken = Object();
    try {
      frozen = _snapshotFreezer.freeze(
        declared,
        violationToken: violationToken,
      );
    } on PatchbaySnapshotPayloadViolation catch (error) {
      return _projectPayloadViolation(error, violationToken);
    }
    return _readOf(_commit(frozen, contentRevision));
  }

  /// Turns a freezer violation into the answer that matches which budget it
  /// crossed. A violation carrying a foreign token was thrown by the App
  /// itself, so nothing inside it is trusted.
  PatchbaySnapshotRead _projectPayloadViolation(
    PatchbaySnapshotPayloadViolation error,
    Object violationToken,
  ) {
    if (!error.belongsTo(violationToken)) {
      return PatchbaySnapshotRead.violated(
        patchbayProviderViolationEnvelope(
          'The App snapshot source violates the Patchbay JSON contract.',
          <String, Object?>{
            'reason': 'snapshotPayloadInvalid',
            'failure': 'unsupportedType',
            'path': r'$',
            'type': error.runtimeType.toString(),
          },
        ),
      );
    }
    if (error.kind == PatchbaySnapshotPayloadViolationKind.runBudget) {
      return PatchbaySnapshotRead.violated(
        _rejectionEnvelope(
          'snapshotPayloadTooLarge',
          'The App snapshot exceeds the per-snapshot budget of this host.',
          error.details,
        ),
      );
    }
    return PatchbaySnapshotRead.violated(
      patchbayProviderViolationEnvelope(
        'The App snapshot source violates the Patchbay JSON contract.',
        error.details,
      ),
    );
  }

  /// Refuses a consumer revision that is negative or has gone backwards.
  PatchbaySnapshotRead? _refuseRevision(PatchbaySnapshotSample sample) {
    final int? previous = _contentRevision;
    if (sample.contentRevision >= 0 &&
        (previous == null || sample.contentRevision >= previous)) {
      return null;
    }
    return PatchbaySnapshotRead.violated(
      patchbayProviderViolationEnvelope(
        'The App reported a snapshot revision that is not monotonic.',
        <String, Object?>{
          'reason': 'revisionRegressed',
          'contentRevision': sample.contentRevision,
          if (previous != null) 'previousContentRevision': previous,
        },
      ),
    );
  }

  /// Answers from the retained view when the App says nothing changed.
  ///
  /// The offered body is not read at all: the whole point of the signal is to
  /// skip the traversal, and touching the map would reintroduce the cost while
  /// still not proving anything about it.
  PatchbaySnapshotRead? _reuseRetained(PatchbaySnapshotSample sample) {
    if (_contentRevision != sample.contentRevision) return null;
    if (_snapshotRevisions.isEmpty) return null;
    return _readOf(_snapshotRevisions.last);
  }

  /// Commits [frozen] as a revision and evicts until both budgets hold.
  PatchbaySnapshotRevision _commit(
    PatchbayFrozenSnapshotPayload frozen,
    int? contentRevision,
  ) {
    // A host-observed source has no invalidation signal, so equal canonical
    // content is the only evidence that nothing was committed. A consumer that
    // reports revisions has already told us it committed, and DG-050-01 keeps
    // that fact rather than deduplicating it away.
    final bool dedupe =
        contentRevision == null &&
        _snapshotRevisions.isNotEmpty &&
        _snapshotRevisions.last.canonical == frozen.canonical;
    if (dedupe) {
      final PatchbaySnapshotRevision previous = _snapshotRevisions.last;
      _retainedCanonicalBytes -= previous.canonicalBytes;
      _snapshotRevisions[_snapshotRevisions.length -
          1] = PatchbaySnapshotRevision(
        revision: previous.revision,
        canonical: frozen.canonical,
        canonicalBytes: frozen.canonicalBytes,
        body: frozen.body,
      );
    } else {
      _snapshotRevisions.add(
        PatchbaySnapshotRevision(
          revision: ++_nextSnapshotRevision,
          canonical: frozen.canonical,
          canonicalBytes: frozen.canonicalBytes,
          body: frozen.body,
        ),
      );
    }
    _retainedCanonicalBytes += frozen.canonicalBytes;
    _contentRevision = contentRevision;
    _evict();
    return _snapshotRevisions.last;
  }

  /// Drops the oldest revisions until both budgets hold.
  ///
  /// The newest revision is never dropped: it is the answer being served, and
  /// the configuration cannot admit a snapshot it refuses to hold.
  void _evict() {
    while (_snapshotRevisions.length > 1 &&
        (_snapshotRevisions.length > _retention.maxRetainedRevisions ||
            _retainedCanonicalBytes > _retention.maxRetainedBytes)) {
      _retainedCanonicalBytes -= _snapshotRevisions.removeAt(0).canonicalBytes;
    }
  }

  /// One observation of [revision]: response, body and metadata built from a
  /// single timestamp so no two views of the same read disagree.
  PatchbaySnapshotRead _readOf(PatchbaySnapshotRevision revision) {
    final Map<String, Object?> metadata = <String, Object?>{
      'snapshotRevision': revision.revision,
      'revisionSource': _versionedSnapshot == null
          ? 'hostObserved'
          : 'consumerReported',
      'factSource': PatchbayFactSourceWire.appRecorded.name,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'retainedRevisionLimit': _retention.maxRetainedRevisions,
      'retainedByteLimit': _retention.maxRetainedBytes,
      'snapshotBytes': revision.canonicalBytes,
    };
    return PatchbaySnapshotRead.valid(
      <String, Object?>{...revision.body, 'schemaVersion': 1, ...metadata},
      revision.body,
      metadata,
    );
  }

  PatchbaySnapshotRevision? _retained(int revision) {
    for (final PatchbaySnapshotRevision candidate in _snapshotRevisions) {
      if (candidate.revision == revision) return candidate;
    }
    return null;
  }

  Future<Map<String, Object?>> _diffSnapshot(
    PatchbaySnapshotDiffRequest request,
  ) async {
    // Looked up twice on purpose. Before the read, so a fresh App instance
    // cannot invent a baseline it never served; after it, so a baseline this
    // very read evicted — by count or by the byte budget — is reported as gone
    // instead of answered from a reference the retention no longer holds.
    final bool existed = _retained(request.fromRevision) != null;
    final PatchbaySnapshotRead read = await readSnapshot();
    if (read.violated) return read.response;
    final PatchbaySnapshotRevision? baseline = existed
        ? _retained(request.fromRevision)
        : null;
    if (baseline == null) {
      return _rejectionEnvelope(
        'snapshotRevisionUnavailable',
        'The requested snapshot revision is no longer retained in this App instance.',
        <String, Object?>{
          'fromRevision': request.fromRevision,
          'oldestAvailableRevision': _snapshotRevisions.first.revision,
          'snapshotRevision': _snapshotRevisions.last.revision,
          'retainedRevisionLimit': _retention.maxRetainedRevisions,
          'retainedByteLimit': _retention.maxRetainedBytes,
        },
      );
    }
    final PatchbaySnapshotDiff diff = PatchbaySnapshotDiff.between(
      baseline.body,
      _snapshotRevisions.last.body,
    );
    final Map<String, Object?> response = <String, Object?>{
      'schemaVersion': 1,
      ...read.metadata,
      'fromRevision': request.fromRevision,
      'added': diff.added,
      'changed': diff.changed,
      'removed': diff.removed,
      'limits': const <String, Object?>{
        'maxChanges': patchbaySnapshotDiffMaxChanges,
        'maxEncodedBytes': patchbaySnapshotDiffMaxEncodedBytes,
      },
    };
    final int encodedBytes = utf8.encode(jsonEncode(response)).length;
    if (diff.count > patchbaySnapshotDiffMaxChanges ||
        encodedBytes > patchbaySnapshotDiffMaxEncodedBytes) {
      return _rejectionEnvelope(
        'snapshotDiffLimitExceeded',
        'The snapshot diff exceeds the bounded response budget.',
        <String, Object?>{
          'changes': diff.count,
          'encodedBytes': encodedBytes,
          'maxChanges': patchbaySnapshotDiffMaxChanges,
          'maxEncodedBytes': patchbaySnapshotDiffMaxEncodedBytes,
        },
      );
    }
    return response;
  }

  Map<String, Object?> _rejectionEnvelope(
    String code,
    String notice,
    Map<String, Object?> details,
  ) => <String, Object?>{
    'schemaVersion': 1,
    'admission': PatchbayAdmissionWire.rejected.name,
    'notice': notice,
    'rejection': PatchbayRejection(
      code: code,
      notice: notice,
      details: details,
    ).toJson(),
  };
}
