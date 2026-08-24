import 'dart:convert';

import '../catalog_digest.dart';
import '../generated/core_wire.g.dart';
import '../invocation.dart';
import '../snapshot.dart';
import 'host_models.dart';

final class HostSnapshotHandler {
  HostSnapshotHandler({required PatchbaySnapshotSource snapshotSource})
    : _snapshot = snapshotSource;

  final PatchbaySnapshotSource _snapshot;
  final List<PatchbaySnapshotRevision> _snapshotRevisions =
      <PatchbaySnapshotRevision>[];
  var _nextSnapshotRevision = 0;

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
      final PatchbaySnapshotRead read = await readSnapshot();
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
        'observed': last.toJson(),
        if (_unaddressableRoot(last, body) case final List<String> keys)
          'availableKeys': keys,
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

  Future<PatchbaySnapshotRead> readSnapshot() async {
    final Map<String, Object?> declared;
    try {
      declared = await _snapshot();
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
    final String canonical = patchbayCanonicalJson(declared);
    PatchbaySnapshotRevision revision;
    if (_snapshotRevisions.isNotEmpty &&
        _snapshotRevisions.last.canonical == canonical) {
      revision = _snapshotRevisions.last;
    } else {
      revision = PatchbaySnapshotRevision(
        revision: ++_nextSnapshotRevision,
        canonical: canonical,
        body: Map<String, Object?>.from(
          jsonDecode(canonical) as Map<String, Object?>,
        ),
      );
      _snapshotRevisions.add(revision);
      if (_snapshotRevisions.length > patchbaySnapshotRevisionRetention) {
        _snapshotRevisions.removeAt(0);
      }
    }
    final Map<String, Object?> metadata = <String, Object?>{
      'snapshotRevision': revision.revision,
      'revisionSource': 'hostObserved',
      'factSource': PatchbayFactSourceWire.appRecorded.name,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'retainedRevisionLimit': patchbaySnapshotRevisionRetention,
    };
    return PatchbaySnapshotRead.valid(
      <String, Object?>{...declared, 'schemaVersion': 1, ...metadata},
      declared,
      metadata,
    );
  }

  Future<Map<String, Object?>> _diffSnapshot(
    PatchbaySnapshotDiffRequest request,
  ) async {
    PatchbaySnapshotRevision? baseline;
    for (final PatchbaySnapshotRevision candidate in _snapshotRevisions) {
      if (candidate.revision == request.fromRevision) baseline = candidate;
    }
    final PatchbaySnapshotRead read = await readSnapshot();
    if (read.violated) return read.response;
    if (baseline == null) {
      return _rejectionEnvelope(
        'snapshotRevisionUnavailable',
        'The requested snapshot revision is no longer retained in this App instance.',
        <String, Object?>{
          'fromRevision': request.fromRevision,
          'oldestAvailableRevision': _snapshotRevisions.first.revision,
          'snapshotRevision': _snapshotRevisions.last.revision,
          'retainedRevisionLimit': patchbaySnapshotRevisionRetention,
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
