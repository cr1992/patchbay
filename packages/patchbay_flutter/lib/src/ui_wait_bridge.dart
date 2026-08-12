import 'dart:async';

import 'package:patchbay/patchbay.dart';

import 'frame_observer.dart';
import 'navigation_bridge.dart';
import 'semantics_bridge.dart';

/// Bounded Flutter observer for stable Semantics, navigation, and revisions.
final class PatchbayUiWaitBridge {
  PatchbayUiWaitBridge({
    required PatchbayGateEvaluator gates,
    required PatchbaySemanticsBridge semantics,
    required PatchbayFrameObserver frames,
    required bool Function() isAppResumed,
    PatchbayNavigationBridge? navigation,
    String Function()? newRequestId,
  }) : _gates = gates,
       _semantics = semantics,
       _frames = frames,
       _isAppResumed = isAppResumed,
       _navigation = navigation,
       _newRequestId = newRequestId ?? _defaultRequestId;

  final PatchbayGateEvaluator _gates;
  final PatchbaySemanticsBridge _semantics;
  final PatchbayFrameObserver _frames;
  final bool Function() _isAppResumed;
  final PatchbayNavigationBridge? _navigation;
  final String Function() _newRequestId;

  static int _nextRequest = 0;
  static String _defaultRequestId() => 'patchbay-wait-${++_nextRequest}';

  Future<PatchbayInvocation> wait(
    PatchbayUiWaitRequest request, {
    String? requestId,
  }) async {
    final String id = requestId ?? _newRequestId();
    final DateTime started = DateTime.now();
    final DateTime deadline = started.add(request.timeout);
    final _Timed<PatchbayGateRejection?> gated = await _beforeDeadline(
      _gates.evaluate(const <String>{}),
      deadline,
    );
    if (!gated.completed) return _timeout(id, request, started, null);
    final PatchbayGateRejection? gate = gated.value;
    if (gate != null) {
      return PatchbayInvocation.rejected(
        requestId: id,
        rejection: PatchbayRejection(
          code: gate.code,
          notice: gate.notice,
          details: <String, Object?>{'gateId': gate.gateId},
        ),
      );
    }

    _WaitProbe? last;
    while (DateTime.now().isBefore(deadline)) {
      if (!_isAppResumed()) {
        return _rejected(id, 'uiWaitLifecycleNotResumed');
      }
      final _Timed<_WaitProbe> observed = await _beforeDeadline(
        _probe(request),
        deadline,
      );
      if (!observed.completed) break;
      last = observed.value!;
      if (last.rejectionCode != null) {
        return _rejected(
          id,
          last.rejectionCode!,
          details: last.rejectionDetails,
        );
      }
      if (last.satisfied) {
        return PatchbayInvocation.accepted(
          requestId: id,
          payload: PatchbayUiWaitResultWire(
            outcome: 'observed',
            source: PatchbayFactSourceWire.uiObserved,
            condition: request.condition.wire,
            elapsedMs: DateTime.now().difference(started).inMilliseconds,
            semanticsIdentifier: request.semanticsIdentifier,
            nodeId: last.nodeId,
            generation: last.generation,
            value: last.value,
            destinationId: last.destinationId,
            navigationRevision: last.navigationRevision,
            treeRevision: last.treeRevision,
            frameRevision: _frames.revision,
          ).toJson(),
        );
      }
      if (!await _frames.nextFrameBefore(deadline)) break;
    }
    return _timeout(id, request, started, last);
  }

  Future<_WaitProbe> _probe(PatchbayUiWaitRequest request) async {
    switch (request.condition) {
      case PatchbayUiWaitCondition.semanticsMounted ||
          PatchbayUiWaitCondition.semanticsUnmounted ||
          PatchbayUiWaitCondition.semanticsValue:
        final PatchbaySemanticsIdentifierObservation? observation =
            await _semantics.observeIdentifier(request.semanticsIdentifier!);
        if (observation == null) {
          return const _WaitProbe.rejected('uiSemanticsUnavailable');
        }
        final List<PatchbaySemanticsIdentifierMatch> matches =
            observation.matches;
        if (matches.length > 1) {
          return _WaitProbe.rejected(
            'uiSemanticsTargetAmbiguous',
            details: <String, Object?>{
              'semanticsIdentifier': request.semanticsIdentifier,
              'matchCount': matches.length,
            },
          );
        }
        if (request.condition == PatchbayUiWaitCondition.semanticsUnmounted) {
          return _WaitProbe(
            satisfied: matches.isEmpty,
            treeRevision: observation.treeRevision,
          );
        }
        if (matches.isEmpty || matches.single.invisible) {
          return _WaitProbe(
            satisfied: false,
            treeRevision: observation.treeRevision,
          );
        }
        final PatchbaySemanticsIdentifierMatch match = matches.single;
        if (request.condition == PatchbayUiWaitCondition.semanticsValue &&
            match.obscured) {
          return const _WaitProbe.rejected('uiSemanticsValueRedacted');
        }
        return _WaitProbe(
          satisfied:
              request.condition == PatchbayUiWaitCondition.semanticsMounted ||
              match.value == request.value,
          nodeId: match.nodeId,
          generation: match.generation,
          value: request.condition == PatchbayUiWaitCondition.semanticsValue
              ? match.value
              : null,
          treeRevision: observation.treeRevision,
        );
      case PatchbayUiWaitCondition.navigationDestination:
        final PatchbayNavigationBridge? navigation = _navigation;
        if (navigation == null) {
          return const _WaitProbe.rejected('navigationUnavailable');
        }
        final String destinationId = request.destinationId!;
        try {
          if (navigation.destinationIsAmbiguous(destinationId)) {
            return const _WaitProbe.rejected('navigationDestinationAmbiguous');
          }
          if (!navigation.destinationIsRegistered(destinationId)) {
            return const _WaitProbe.rejected('navigationDestinationNotFound');
          }
          final PatchbayNavigationObservation observation = navigation
              .observeForWait();
          return _WaitProbe(
            satisfied:
                observation.destinationId == destinationId &&
                (request.revision == null ||
                    observation.revision > request.revision!),
            destinationId: observation.destinationId,
            navigationRevision: observation.revision,
          );
        } on Object catch (error) {
          return _WaitProbe.rejected(
            'navigationObserverFailed',
            details: <String, Object?>{
              'failureType': error.runtimeType.toString(),
            },
          );
        }
      case PatchbayUiWaitCondition.treeRevision:
        final int? revision = await _semantics.observeTreeRevision();
        if (revision == null) {
          return const _WaitProbe.rejected('uiSemanticsUnavailable');
        }
        return _WaitProbe(
          satisfied: revision > request.revision!,
          treeRevision: revision,
        );
      case PatchbayUiWaitCondition.frameRevision:
        return _WaitProbe(satisfied: _frames.revision > request.revision!);
    }
  }

  static Future<_Timed<T>> _beforeDeadline<T>(
    Future<T> future,
    DateTime deadline,
  ) async {
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return _Timed<T>.timeout();
    try {
      return _Timed<T>.completed(await future.timeout(remaining));
    } on TimeoutException {
      return _Timed<T>.timeout();
    }
  }

  PatchbayInvocation _timeout(
    String requestId,
    PatchbayUiWaitRequest request,
    DateTime started,
    _WaitProbe? last,
  ) => _rejected(
    requestId,
    'uiWaitTimeout',
    details: <String, Object?>{
      'condition': request.condition.name,
      'timeoutMs': request.timeout.inMilliseconds,
      'elapsedMs': DateTime.now().difference(started).inMilliseconds,
      if (last?.treeRevision != null) 'treeRevision': last!.treeRevision,
      if (last?.navigationRevision != null)
        'navigationRevision': last!.navigationRevision,
      'frameRevision': _frames.revision,
    },
  );

  static PatchbayInvocation _rejected(
    String requestId,
    String code, {
    Map<String, Object?> details = const <String, Object?>{},
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, details: details),
  );
}

final class _WaitProbe {
  const _WaitProbe({
    required this.satisfied,
    this.nodeId,
    this.generation,
    this.value,
    this.destinationId,
    this.navigationRevision,
    this.treeRevision,
  }) : rejectionCode = null,
       rejectionDetails = const <String, Object?>{};

  const _WaitProbe.rejected(
    this.rejectionCode, {
    Map<String, Object?> details = const <String, Object?>{},
  }) : satisfied = false,
       nodeId = null,
       generation = null,
       value = null,
       destinationId = null,
       navigationRevision = null,
       treeRevision = null,
       rejectionDetails = details;

  final bool satisfied;
  final int? nodeId;
  final int? generation;
  final String? value;
  final String? destinationId;
  final int? navigationRevision;
  final int? treeRevision;
  final String? rejectionCode;
  final Map<String, Object?> rejectionDetails;
}

final class _Timed<T> {
  const _Timed.completed(T this.value) : completed = true;
  const _Timed.timeout() : completed = false, value = null;

  final bool completed;
  final T? value;
}
