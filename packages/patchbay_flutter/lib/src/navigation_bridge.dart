import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:patchbay/patchbay.dart';

import 'frame_observer.dart';

typedef PatchbayNavigationRequest = FutureOr<void> Function();
typedef PatchbayNavigationCatalogSource =
    List<PatchbayNavigationDestination> Function();
typedef PatchbayNavigationObservationSource =
    PatchbayNavigationObservation Function();

/// Consumer-owned mapping from a stable destination ID to existing routing.
///
/// The callbacks must call the consumer's normal router/controller entry
/// points, so existing route guards and redirects remain authoritative.
final class PatchbayNavigationDestination {
  PatchbayNavigationDestination({
    required this.id,
    this.summary,
    Set<String> gateIds = const <String>{},
    this.go,
    this.push,
  }) : gateIds = Set<String>.unmodifiable(gateIds),
       descriptor = PatchbayDestinationDescriptor(
         id: id,
         summary: summary,
         gates: gateIds,
         operations: <PatchbayNavigationOperation>{
           if (go != null) PatchbayNavigationOperation.go,
           if (push != null) PatchbayNavigationOperation.push,
         },
       );

  final String id;
  final String? summary;
  final Set<String> gateIds;
  final PatchbayNavigationRequest? go;
  final PatchbayNavigationRequest? push;
  final PatchbayDestinationDescriptor descriptor;

  PatchbayNavigationRequest? requestFor(
    PatchbayNavigationOperation operation,
  ) => switch (operation) {
    PatchbayNavigationOperation.go => go,
    PatchbayNavigationOperation.push => push,
    PatchbayNavigationOperation.back => null,
  };
}

/// The single navigation adapter injected at the consumer composition root.
final class PatchbayNavigationAdapter {
  const PatchbayNavigationAdapter({
    required this.destinations,
    required this.current,
    this.back,
    this.backGateIds = const <String>{},
  });

  final PatchbayNavigationCatalogSource destinations;
  final PatchbayNavigationObservationSource current;
  final PatchbayNavigationRequest? back;
  final Set<String> backGateIds;
}

/// Serial, revision-fenced destination navigation with UI observation.
final class PatchbayNavigationBridge {
  PatchbayNavigationBridge({
    required PatchbayGateEvaluator gates,
    required PatchbayNavigationAdapter adapter,
    required PatchbayFrameObserver frames,
    required bool Function() isAppResumed,
    String Function()? newRequestId,
  }) : _gates = gates,
       _adapter = adapter,
       _frames = frames,
       _isAppResumed = isAppResumed,
       _newRequestId = newRequestId ?? _defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbayNavigationAdapter _adapter;
  final PatchbayFrameObserver _frames;
  final bool Function() _isAppResumed;
  final String Function() _newRequestId;
  Future<void> _tail = Future<void>.value();

  static int _nextRequest = 0;
  static String _defaultRequestId() => 'patchbay-navigation-${++_nextRequest}';

  Future<PatchbayInvocation> catalog({String? requestId}) async {
    final String id = requestId ?? _newRequestId();
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(id, gate);
    final _AdapterSnapshot snapshot;
    try {
      snapshot = _snapshot();
    } on Object catch (error) {
      return _observerFailed(id, error);
    }
    return PatchbayInvocation.accepted(
      requestId: id,
      payload: PatchbayNavigationCatalogWire(
        outcome: 'cataloged',
        source: PatchbayFactSourceWire.appRecorded,
        navigationRevision: snapshot.observation.revision,
        destinations: snapshot.descriptors
            .map(
              (PatchbayDestinationDescriptor descriptor) => descriptor.toWire(),
            )
            .toList(growable: false),
      ).toJson(),
    );
  }

  Future<PatchbayInvocation> current({String? requestId}) async {
    final String id = requestId ?? _newRequestId();
    final PatchbayGateRejection? gate = await _gates.evaluate(const <String>{});
    if (gate != null) return _gateRejected(id, gate);
    final _AdapterSnapshot snapshot;
    try {
      snapshot = _snapshot();
    } on Object catch (error) {
      return _observerFailed(id, error);
    }
    final PatchbayInvocation? invalid = _validateCurrent(id, snapshot);
    if (invalid != null) return invalid;
    return PatchbayInvocation.accepted(
      requestId: id,
      payload: PatchbayNavigationCurrentWire(
        outcome: 'observed',
        source: PatchbayFactSourceWire.appRecorded,
        navigationRevision: snapshot.observation.revision,
        destinationId: snapshot.observation.destinationId,
      ).toJson(),
    );
  }

  Future<PatchbayInvocation> go({
    required String destinationId,
    required int revision,
    required Duration timeout,
    String? requestId,
  }) => _enqueue(
    () => _navigate(
      operation: PatchbayNavigationOperation.go,
      destinationId: destinationId,
      revision: revision,
      timeout: timeout,
      requestId: requestId ?? _newRequestId(),
    ),
  );

  Future<PatchbayInvocation> push({
    required String destinationId,
    required int revision,
    required Duration timeout,
    String? requestId,
  }) => _enqueue(
    () => _navigate(
      operation: PatchbayNavigationOperation.push,
      destinationId: destinationId,
      revision: revision,
      timeout: timeout,
      requestId: requestId ?? _newRequestId(),
    ),
  );

  Future<PatchbayInvocation> back({
    required int revision,
    required Duration timeout,
    String? requestId,
  }) => _enqueue(
    () => _navigate(
      operation: PatchbayNavigationOperation.back,
      destinationId: null,
      revision: revision,
      timeout: timeout,
      requestId: requestId ?? _newRequestId(),
    ),
  );

  PatchbayNavigationObservation observeForWait() => _snapshot().observation;

  bool destinationIsAmbiguous(String id) =>
      _snapshot().ambiguousIds.contains(id);

  bool destinationIsRegistered(String id) => _snapshot().byId.containsKey(id);

  Future<PatchbayInvocation> _enqueue(
    Future<PatchbayInvocation> Function() body,
  ) {
    final Completer<PatchbayInvocation> result =
        Completer<PatchbayInvocation>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await body());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<PatchbayInvocation> _navigate({
    required PatchbayNavigationOperation operation,
    required String? destinationId,
    required int revision,
    required Duration timeout,
    required String requestId,
  }) async {
    if (revision < 0 ||
        timeout <= Duration.zero ||
        timeout > const Duration(minutes: 2)) {
      return _rejected(requestId, 'invalidNavigationArguments');
    }
    if (!_isAppResumed()) {
      return _rejected(requestId, 'navigationLifecycleNotResumed');
    }

    _ResolvedRequest resolution;
    try {
      resolution = _resolveRequest(operation, destinationId);
    } on Object catch (error) {
      return _observerFailed(requestId, error);
    }
    if (resolution.rejectionCode != null) {
      return _rejected(
        requestId,
        resolution.rejectionCode!,
        details: <String, Object?>{'destinationId': ?destinationId},
      );
    }
    if (resolution.observation.revision != revision) {
      return _revisionStale(requestId, revision, resolution.observation);
    }

    final Set<String> initialGateIds = Set<String>.of(resolution.gateIds);
    final PatchbayGateRejection? gate = await _gates.evaluate(initialGateIds);
    if (gate != null) return _gateRejected(requestId, gate);
    if (!_isAppResumed()) {
      return _rejected(requestId, 'navigationLifecycleNotResumed');
    }

    // Gate evaluation may await. Resolve both the destination callback and the
    // observer revision again before issuing the request.
    try {
      resolution = _resolveRequest(operation, destinationId);
    } on Object catch (error) {
      return _observerFailed(requestId, error);
    }
    if (resolution.rejectionCode != null) {
      return _rejected(requestId, resolution.rejectionCode!);
    }
    if (!setEquals(initialGateIds, resolution.gateIds)) {
      return _rejected(requestId, 'navigationPolicyChanged');
    }
    if (resolution.observation.revision != revision) {
      return _revisionStale(requestId, revision, resolution.observation);
    }

    try {
      await resolution.request!();
    } on Object catch (error) {
      return _rejected(
        requestId,
        'navigationRequestFailed',
        details: <String, Object?>{'failureType': error.runtimeType.toString()},
      );
    }
    return _observeArrival(
      requestId: requestId,
      operation: operation,
      destinationId: destinationId,
      beforeRevision: revision,
      timeout: timeout,
    );
  }

  Future<PatchbayInvocation> _observeArrival({
    required String requestId,
    required PatchbayNavigationOperation operation,
    required String? destinationId,
    required int beforeRevision,
    required Duration timeout,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    PatchbayNavigationObservation? last;
    while (DateTime.now().isBefore(deadline)) {
      if (!_isAppResumed()) {
        return _rejected(requestId, 'navigationLifecycleNotResumed');
      }
      try {
        last = _adapter.current();
      } on Object catch (error) {
        return _observerFailed(requestId, error);
      }
      final bool arrived = switch (operation) {
        PatchbayNavigationOperation.go =>
          last.destinationId == destinationId &&
              last.revision >= beforeRevision,
        PatchbayNavigationOperation.push =>
          last.destinationId == destinationId && last.revision > beforeRevision,
        PatchbayNavigationOperation.back => last.revision > beforeRevision,
      };
      if (arrived) {
        if (!await _frames.nextFrameBefore(deadline)) break;
        if (!_isAppResumed()) {
          return _rejected(requestId, 'navigationLifecycleNotResumed');
        }
        final PatchbayNavigationObservation confirmed;
        try {
          confirmed = _adapter.current();
        } on Object catch (error) {
          return _observerFailed(requestId, error);
        }
        final bool stillArrived = switch (operation) {
          PatchbayNavigationOperation.go || PatchbayNavigationOperation.push =>
            confirmed.destinationId == destinationId &&
                confirmed.revision >= last.revision,
          PatchbayNavigationOperation.back =>
            confirmed.revision >= last.revision &&
                confirmed.destinationId != null,
        };
        if (!stillArrived) {
          return _redirected(requestId, destinationId, confirmed);
        }
        return PatchbayInvocation.accepted(
          requestId: requestId,
          payload: PatchbayNavigationResultWire(
            outcome: 'arrived',
            source: PatchbayFactSourceWire.uiObserved,
            operation: operation.wire,
            requestedDestinationId: destinationId,
            destinationId: confirmed.destinationId!,
            beforeNavigationRevision: beforeRevision,
            afterNavigationRevision: confirmed.revision,
            frameRevision: _frames.revision,
          ).toJson(),
        );
      }
      if (destinationId != null &&
          last.revision > beforeRevision &&
          last.destinationId != destinationId) {
        return _redirected(requestId, destinationId, last);
      }
      if (!await _frames.nextFrameBefore(deadline)) break;
    }
    return _rejected(
      requestId,
      'navigationTimeout',
      details: <String, Object?>{
        'timeoutMs': timeout.inMilliseconds,
        'destinationId': ?destinationId,
        if (last != null) ...<String, Object?>{
          'currentDestinationId': last.destinationId,
          'currentRevision': last.revision,
        },
      },
    );
  }

  _ResolvedRequest _resolveRequest(
    PatchbayNavigationOperation operation,
    String? destinationId,
  ) {
    final _AdapterSnapshot snapshot = _snapshot();
    if (operation == PatchbayNavigationOperation.back) {
      final PatchbayNavigationRequest? request = _adapter.back;
      return request == null
          ? _ResolvedRequest.rejected(
              'navigationOperationUnavailable',
              snapshot.observation,
            )
          : _ResolvedRequest(
              request: request,
              gateIds: _adapter.backGateIds,
              observation: snapshot.observation,
            );
    }
    if (destinationId == null || !snapshot.byId.containsKey(destinationId)) {
      return _ResolvedRequest.rejected(
        'navigationDestinationNotFound',
        snapshot.observation,
      );
    }
    if (snapshot.ambiguousIds.contains(destinationId)) {
      return _ResolvedRequest.rejected(
        'navigationDestinationAmbiguous',
        snapshot.observation,
      );
    }
    final PatchbayNavigationDestination destination =
        snapshot.byId[destinationId]!.single;
    final PatchbayNavigationRequest? request = destination.requestFor(
      operation,
    );
    return request == null
        ? _ResolvedRequest.rejected(
            'navigationOperationUnavailable',
            snapshot.observation,
          )
        : _ResolvedRequest(
            request: request,
            gateIds: destination.gateIds,
            observation: snapshot.observation,
          );
  }

  _AdapterSnapshot _snapshot() {
    final List<PatchbayNavigationDestination> destinations =
        List<PatchbayNavigationDestination>.of(_adapter.destinations());
    final Map<String, List<PatchbayNavigationDestination>> byId =
        <String, List<PatchbayNavigationDestination>>{};
    for (final PatchbayNavigationDestination destination in destinations) {
      byId
          .putIfAbsent(destination.id, () => <PatchbayNavigationDestination>[])
          .add(destination);
    }
    final Set<String> ambiguous = <String>{
      for (final MapEntry<String, List<PatchbayNavigationDestination>> entry
          in byId.entries)
        if (entry.value.length > 1) entry.key,
    };
    final List<PatchbayDestinationDescriptor> descriptors =
        <PatchbayDestinationDescriptor>[
          for (final String id in (byId.keys.toList()..sort()))
            if (ambiguous.contains(id))
              PatchbayDestinationDescriptor(
                id: id,
                summary: byId[id]!.first.summary,
                operations: const <PatchbayNavigationOperation>{},
                gates: const <String>{},
                ambiguous: true,
              )
            else
              byId[id]!.single.descriptor,
        ];
    return _AdapterSnapshot(
      observation: _adapter.current(),
      byId: byId,
      ambiguousIds: ambiguous,
      descriptors: descriptors,
    );
  }

  static PatchbayInvocation? _validateCurrent(
    String requestId,
    _AdapterSnapshot snapshot,
  ) {
    final String? current = snapshot.observation.destinationId;
    if (current == null) return null;
    if (snapshot.ambiguousIds.contains(current)) {
      return _rejected(requestId, 'navigationDestinationAmbiguous');
    }
    if (!snapshot.byId.containsKey(current)) {
      return _rejected(requestId, 'navigationCurrentUnregistered');
    }
    return null;
  }

  static PatchbayInvocation _gateRejected(
    String requestId,
    PatchbayGateRejection gate,
  ) => _rejected(
    requestId,
    gate.code,
    notice: gate.notice,
    details: <String, Object?>{'gateId': gate.gateId},
  );

  static PatchbayInvocation _revisionStale(
    String requestId,
    int expected,
    PatchbayNavigationObservation current,
  ) => _rejected(
    requestId,
    'navigationRevisionStale',
    details: <String, Object?>{
      'expectedRevision': expected,
      'currentRevision': current.revision,
      'currentDestinationId': current.destinationId,
    },
  );

  static PatchbayInvocation _redirected(
    String requestId,
    String? requested,
    PatchbayNavigationObservation current,
  ) => _rejected(
    requestId,
    'navigationRedirected',
    details: <String, Object?>{
      'requestedDestinationId': requested,
      'currentDestinationId': current.destinationId,
      'currentRevision': current.revision,
    },
  );

  static PatchbayInvocation _observerFailed(String requestId, Object error) =>
      _rejected(
        requestId,
        'navigationObserverFailed',
        details: <String, Object?>{'failureType': error.runtimeType.toString()},
      );

  static PatchbayInvocation _rejected(
    String requestId,
    String code, {
    String? notice,
    Map<String, Object?> details = const <String, Object?>{},
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  );
}

final class _AdapterSnapshot {
  const _AdapterSnapshot({
    required this.observation,
    required this.byId,
    required this.ambiguousIds,
    required this.descriptors,
  });

  final PatchbayNavigationObservation observation;
  final Map<String, List<PatchbayNavigationDestination>> byId;
  final Set<String> ambiguousIds;
  final List<PatchbayDestinationDescriptor> descriptors;
}

final class _ResolvedRequest {
  const _ResolvedRequest({
    required this.request,
    required this.gateIds,
    required this.observation,
  }) : rejectionCode = null;

  const _ResolvedRequest.rejected(this.rejectionCode, this.observation)
    : request = null,
      gateIds = const <String>{};

  final PatchbayNavigationRequest? request;
  final Set<String> gateIds;
  final PatchbayNavigationObservation observation;
  final String? rejectionCode;
}
