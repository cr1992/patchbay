import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'client.dart';

/// Default and hard limits for one client-side VM Service profile window.
const Duration patchbayDefaultPerformanceProfileDuration = Duration(
  seconds: 10,
);
const Duration patchbayMaximumPerformanceProfileDuration = Duration(
  seconds: 60,
);
const int patchbayDefaultPerformanceEventLimit = 10000;
const int patchbayMaximumPerformanceEventLimit = 10000;
const int patchbayMaximumPerformanceBufferBytes = 8 * 1024 * 1024;

/// Stable input to the VM Service performance sampler.
final class PatchbayPerformanceProfileRequest {
  const PatchbayPerformanceProfileRequest({
    this.duration = patchbayDefaultPerformanceProfileDuration,
    this.eventLimit = patchbayDefaultPerformanceEventLimit,
  });

  final Duration duration;
  final int eventLimit;

  void validate() {
    if (duration <= Duration.zero ||
        duration > patchbayMaximumPerformanceProfileDuration) {
      throw const FormatException('--duration-ms must be between 1 and 60000');
    }
    if (eventLimit <= 0 || eventLimit > patchbayMaximumPerformanceEventLimit) {
      throw const FormatException('--sample-limit must be between 1 and 10000');
    }
  }
}

/// Optional profiling surface implemented by transports that can observe it.
///
/// Kept separate from [PatchbayClient] so existing embedders that implement the
/// command client do not break merely because a newer CLI learned a VM-only
/// diagnostic. The CLI checks this capability explicitly and never fabricates
/// VM observations on direct HTTP.
abstract interface class PatchbayProfilingClient {
  Future<Map<String, Object?>> performanceProfile(
    PatchbayPerformanceProfileRequest request,
  );

  Future<Map<String, Object?>> networkProfile();
}

/// The small public-VM-RPC seam used by the sampler and by deterministic tests.
///
/// It deliberately exposes no private RPC and no raw service connection. A
/// source streams one bounded time window; the profiler reduces each event as
/// it arrives and never retains or forwards a raw timeline event.
abstract interface class PatchbayPerformanceVmSource {
  Future<PatchbayTimelineConfiguration> timelineConfiguration();
  Future<void> setTimelineStreams(List<String> streams);
  Future<int> timelineMicros();
  Future<PatchbayHeapMeasurement> memoryUsage(String isolateId);
  Future<PatchbayTimelineSubscription> listenTimeline(
    void Function(List<Map<String, Object?>> events) onEvents,
    void Function(Object error, StackTrace stackTrace) onError,
  );
}

abstract interface class PatchbayTimelineSubscription {
  Future<void> cancel();
}

final class PatchbayTimelineConfiguration {
  const PatchbayTimelineConfiguration({
    required this.availableStreams,
    required this.recordedStreams,
  });

  final List<String> availableStreams;
  final List<String> recordedStreams;
}

final class PatchbayHeapMeasurement {
  const PatchbayHeapMeasurement({
    required this.heapUsageBytes,
    required this.heapCapacityBytes,
    required this.externalUsageBytes,
  });

  final int heapUsageBytes;
  final int heapCapacityBytes;
  final int externalUsageBytes;
}

/// Adapter over only the public `vm_service` RPCs used by this feature.
final class PatchbayVmServicePerformanceSource
    implements PatchbayPerformanceVmSource {
  const PatchbayVmServicePerformanceSource(this.service);

  final VmService service;

  @override
  Future<PatchbayTimelineConfiguration> timelineConfiguration() async {
    final TimelineFlags flags = await service.getVMTimelineFlags();
    return PatchbayTimelineConfiguration(
      availableStreams: List<String>.of(flags.availableStreams ?? const []),
      recordedStreams: List<String>.of(flags.recordedStreams ?? const []),
    );
  }

  @override
  Future<void> setTimelineStreams(List<String> streams) async {
    await service.setVMTimelineFlags(streams);
  }

  @override
  Future<int> timelineMicros() async {
    final Timestamp value = await service.getVMTimelineMicros();
    final int? timestamp = value.timestamp;
    if (timestamp == null || timestamp < 0) {
      throw const PatchbayProtocolException(
        'performanceProfileMalformedVmResponse',
        details: <String, Object?>{'field': 'timestamp'},
      );
    }
    return timestamp;
  }

  @override
  Future<PatchbayHeapMeasurement> memoryUsage(String isolateId) async {
    final MemoryUsage usage = await service.getMemoryUsage(isolateId);
    final int? heapUsage = usage.heapUsage;
    final int? heapCapacity = usage.heapCapacity;
    final int? externalUsage = usage.externalUsage;
    if (heapUsage == null ||
        heapUsage < 0 ||
        heapCapacity == null ||
        heapCapacity < 0 ||
        externalUsage == null ||
        externalUsage < 0) {
      throw const PatchbayProtocolException(
        'performanceProfileMalformedVmResponse',
        details: <String, Object?>{'field': 'memoryUsage'},
      );
    }
    return PatchbayHeapMeasurement(
      heapUsageBytes: heapUsage,
      heapCapacityBytes: heapCapacity,
      externalUsageBytes: externalUsage,
    );
  }

  @override
  Future<PatchbayTimelineSubscription> listenTimeline(
    void Function(List<Map<String, Object?>> events) onEvents,
    void Function(Object error, StackTrace stackTrace) onError,
  ) async {
    final StreamSubscription<Event> subscription = service.onTimelineEvent
        .listen(
          (Event event) {
            onEvents(<Map<String, Object?>>[
              for (final TimelineEvent timelineEvent
                  in event.timelineEvents ?? const <TimelineEvent>[])
                Map<String, Object?>.from(
                  timelineEvent.json ?? const <String, Object?>{},
                ),
            ]);
          },
          onError: (Object _, StackTrace stackTrace) {
            onError(
              const PatchbayTransportException('vmServiceUnavailable'),
              stackTrace,
            );
          },
        );
    try {
      await service.streamListen(EventStreams.kTimeline);
    } on Object {
      await subscription.cancel();
      rethrow;
    }
    return _VmTimelineSubscription(service, subscription);
  }
}

final class _VmTimelineSubscription implements PatchbayTimelineSubscription {
  _VmTimelineSubscription(this._service, this._subscription);

  final VmService _service;
  final StreamSubscription<Event> _subscription;
  var _cancelled = false;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    try {
      await _service.streamCancel(EventStreams.kTimeline);
    } finally {
      await _subscription.cancel();
    }
  }
}

typedef PatchbayProfileDelay = Future<void> Function(Duration duration);

/// Collects one bounded window and reduces it to Patchbay's stable schema.
final class PatchbayVmPerformanceProfiler {
  PatchbayVmPerformanceProfiler({
    required PatchbayPerformanceVmSource source,
    PatchbayProfileDelay delay = Future<void>.delayed,
  }) : _source = source,
       _delay = delay;

  static const List<String> _requiredStreams = <String>[
    'Dart',
    'Embedder',
    'GC',
  ];

  final PatchbayPerformanceVmSource _source;
  final PatchbayProfileDelay _delay;

  Future<Map<String, Object?>> collect({
    required String isolateId,
    required PatchbayPerformanceProfileRequest request,
  }) async {
    request.validate();
    try {
      final PatchbayTimelineConfiguration configuration = await _source
          .timelineConfiguration();
      final List<String> missing = <String>[
        for (final String stream in _requiredStreams)
          if (!configuration.availableStreams.contains(stream)) stream,
      ];
      if (missing.isNotEmpty) {
        throw PatchbayProtocolException(
          'performanceProfilingUnavailable',
          details: <String, Object?>{
            'reason': 'timelineStreamsUnavailable',
            'missingStreams': missing,
          },
        );
      }

      final List<String> originalStreams = List<String>.of(
        configuration.recordedStreams,
      );
      final List<String> profilingStreams = <String>{
        ...originalStreams,
        ..._requiredStreams,
      }.toList()..sort();
      final bool changed = !_sameStrings(originalStreams, profilingStreams);
      if (changed) await _source.setTimelineStreams(profilingStreams);
      try {
        final int startedAtVmMicros = await _source.timelineMicros();
        final PatchbayHeapMeasurement heapBefore = await _source.memoryUsage(
          isolateId,
        );
        final _BoundedTimelineAccumulator events = _BoundedTimelineAccumulator(
          eventLimit: request.eventLimit,
        );
        PatchbayTimelineSubscription? subscription;
        try {
          subscription = await _source.listenTimeline(
            events.addAll,
            events.fail,
          );
          await Future.any<void>(<Future<void>>[
            _delay(request.duration),
            events.limitReached,
          ]);
        } finally {
          await subscription?.cancel();
        }
        final int endedAtVmMicros = await _source.timelineMicros();
        if (endedAtVmMicros < startedAtVmMicros) {
          throw const PatchbayProtocolException(
            'performanceProfileMalformedVmResponse',
            details: <String, Object?>{'field': 'timelineWindow'},
          );
        }
        final PatchbayHeapMeasurement heapAfter = await _source.memoryUsage(
          isolateId,
        );
        return _summarize(
          startedAtVmMicros: startedAtVmMicros,
          endedAtVmMicros: endedAtVmMicros,
          heapBefore: heapBefore,
          heapAfter: heapAfter,
          events: events,
        );
      } finally {
        if (changed) {
          try {
            await _source.setTimelineStreams(originalStreams);
          } on Object {
            throw const PatchbayProtocolException(
              'performanceProfileTimelineRestoreFailed',
            );
          }
        }
      }
    } on RPCError catch (error) {
      if (error.code == RPCErrorKind.kMethodNotFound.code ||
          error.code == RPCErrorKind.kFeatureDisabled.code) {
        throw PatchbayProtocolException(
          'performanceProfilingUnavailable',
          details: <String, Object?>{
            'reason': error.code == RPCErrorKind.kMethodNotFound.code
                ? 'vmRpcUnavailable'
                : 'vmFeatureDisabled',
          },
        );
      }
      if (error.code == RPCErrorKind.kInvalidTimelineRequest.code) {
        throw const PatchbayProtocolException(
          'performanceProfilingUnavailable',
          details: <String, Object?>{'reason': 'timelineRecorderUnavailable'},
        );
      }
      if (error.code == RPCErrorKind.kConnectionDisposed.code) {
        throw const PatchbayTransportException('vmServiceUnavailable');
      }
      throw PatchbayProtocolException(
        'performanceProfileVmRpcFailed',
        details: <String, Object?>{'vmRpcCode': error.code},
      );
    }
  }

  Map<String, Object?> _summarize({
    required int startedAtVmMicros,
    required int endedAtVmMicros,
    required PatchbayHeapMeasurement heapBefore,
    required PatchbayHeapMeasurement heapAfter,
    required _BoundedTimelineAccumulator events,
  }) {
    final _TimelineSummary summary = events.summary;
    return <String, Object?>{
      'schema': 'patchbay.performanceProfile.v1',
      'capability': 'performanceProfile',
      'transport': 'vmService',
      'factSource': 'uiObserved',
      'window': <String, Object?>{
        'startedAtVmMicros': startedAtVmMicros,
        'endedAtVmMicros': endedAtVmMicros,
        'durationMs': (endedAtVmMicros - startedAtVmMicros) ~/ 1000,
      },
      'sampling': <String, Object?>{
        'eventLimit': events.eventLimit,
        'bufferByteLimit': patchbayMaximumPerformanceBufferBytes,
        'receivedEventCount': events.receivedEventCount,
        'sampleCount': events.sampleCount,
        'droppedEventCount': events.droppedEventCount,
        'processedEventBytes': events.processedEventBytes,
        'truncated': events.truncated,
      },
      'frames': <String, Object?>{
        'build': _durationSummary(summary.buildDurations),
        'raster': _durationSummary(summary.rasterDurations),
        'jankThresholdMicros': 16000,
      },
      'heap': <String, Object?>{
        'sampleCount': 2,
        'startUsageBytes': heapBefore.heapUsageBytes,
        'endUsageBytes': heapAfter.heapUsageBytes,
        'deltaUsageBytes': heapAfter.heapUsageBytes - heapBefore.heapUsageBytes,
        'peakObservedUsageBytes':
            heapBefore.heapUsageBytes > heapAfter.heapUsageBytes
            ? heapBefore.heapUsageBytes
            : heapAfter.heapUsageBytes,
        'startCapacityBytes': heapBefore.heapCapacityBytes,
        'endCapacityBytes': heapAfter.heapCapacityBytes,
        'startExternalBytes': heapBefore.externalUsageBytes,
        'endExternalBytes': heapAfter.externalUsageBytes,
      },
      'gc': <String, Object?>{
        'count': summary.newGenerationGcCount + summary.oldGenerationGcCount,
        'newGenerationCount': summary.newGenerationGcCount,
        'oldGenerationCount': summary.oldGenerationGcCount,
      },
    };
  }
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _durationSummary(List<int> values) {
  if (values.isEmpty) {
    return const <String, Object?>{
      'count': 0,
      'jankCount': 0,
      'averageMicros': null,
      'minMicros': null,
      'maxMicros': null,
      'p50Micros': null,
      'p90Micros': null,
      'p99Micros': null,
    };
  }
  final List<int> sorted = List<int>.of(values)..sort();
  final int total = sorted.fold<int>(0, (int sum, int value) => sum + value);
  return <String, Object?>{
    'count': sorted.length,
    'jankCount': sorted.where((int value) => value > 16000).length,
    'averageMicros': total ~/ sorted.length,
    'minMicros': sorted.first,
    'maxMicros': sorted.last,
    'p50Micros': _nearestRank(sorted, 50),
    'p90Micros': _nearestRank(sorted, 90),
    'p99Micros': _nearestRank(sorted, 99),
  };
}

int _nearestRank(List<int> sorted, int percentile) {
  final int rank = ((percentile * sorted.length) + 99) ~/ 100;
  return sorted[rank.clamp(1, sorted.length) - 1];
}

final class _BoundedTimelineAccumulator {
  _BoundedTimelineAccumulator({required this.eventLimit});

  final int eventLimit;
  final _TimelineSummary summary = _TimelineSummary();
  final Completer<void> _limitReached = Completer<void>();
  int receivedEventCount = 0;
  int sampleCount = 0;
  int droppedEventCount = 0;
  int processedEventBytes = 0;
  bool truncated = false;

  Future<void> get limitReached => _limitReached.future;

  void fail(Object error, StackTrace stackTrace) {
    if (!_limitReached.isCompleted) {
      _limitReached.completeError(error, stackTrace);
    }
  }

  void addAll(List<Map<String, Object?>> batch) {
    for (final Map<String, Object?> event in batch) {
      receivedEventCount += 1;
      if (truncated || sampleCount >= eventLimit) {
        _truncate();
        droppedEventCount += 1;
        continue;
      }
      final int eventBytes = _jsonByteLengthCapped(
        event,
        patchbayMaximumPerformanceBufferBytes - processedEventBytes,
      );
      if (processedEventBytes + eventBytes >
          patchbayMaximumPerformanceBufferBytes) {
        _truncate();
        droppedEventCount += 1;
        continue;
      }
      processedEventBytes += eventBytes;
      sampleCount += 1;
      summary.add(event);
      // End the window at the hard event ceiling. We cannot know whether a
      // later batch existed after cancellation, so reaching the ceiling is
      // itself reported as truncation even when this batch ended exactly here.
      if (sampleCount == eventLimit) _truncate();
    }
  }

  void _truncate() {
    truncated = true;
    if (!_limitReached.isCompleted) _limitReached.complete();
  }
}

final class _TimelineSummary {
  final List<int> buildDurations = <int>[];
  final List<int> rasterDurations = <int>[];
  final Map<String, List<int>> _starts = <String, List<int>>{};
  int newGenerationGcCount = 0;
  int oldGenerationGcCount = 0;

  void add(Map<String, Object?> event) {
    final String? name = event['name'] as String?;
    final String? phase = event['ph'] as String?;
    final int? timestamp = _jsonInt(event['ts']);
    final List<int>? target = switch (name) {
      'Frame' => buildDurations,
      'GPURasterizer::Draw' => rasterDurations,
      _ => null,
    };
    if (target != null) {
      final int? completeDuration = _jsonInt(event['dur']);
      if (phase == 'X' && completeDuration != null && completeDuration >= 0) {
        target.add(completeDuration);
      } else if (timestamp != null && phase == 'B') {
        _starts
            .putIfAbsent(_eventKey(event, name!), () => <int>[])
            .add(timestamp);
      } else if (timestamp != null && phase == 'E') {
        final List<int>? stack = _starts[_eventKey(event, name!)];
        if (stack != null && stack.isNotEmpty) {
          final int duration = timestamp - stack.removeLast();
          if (duration >= 0) target.add(duration);
        }
      }
    }

    // Count one collection at its complete event or begin edge, never both.
    if (phase != 'E') {
      if (name == 'CollectNewGeneration') newGenerationGcCount += 1;
      if (name == 'CollectOldGeneration') oldGenerationGcCount += 1;
    }
  }
}

String _eventKey(Map<String, Object?> event, String name) =>
    '$name:${event['pid']}:${event['tid']}';

int? _jsonInt(Object? value) => switch (value) {
  int number => number,
  double number when number.isFinite && number == number.roundToDouble() =>
    number.toInt(),
  _ => null,
};

/// Counts the UTF-8 bytes of JSON without materializing an attacker-sized JSON
/// string. Returning more than [limit] is sufficient for the caller to stop.
int _jsonByteLengthCapped(Object? value, int limit) {
  int stringBytes(String text, int cap) {
    var bytes = 2; // quotes
    for (final int rune in text.runes) {
      bytes += switch (rune) {
        0x22 || 0x5c => 2,
        < 0x20 => 6,
        <= 0x7f => 1,
        <= 0x7ff => 2,
        <= 0xffff => 3,
        _ => 4,
      };
      if (bytes > cap) return cap + 1;
    }
    return bytes;
  }

  int count(Object? node, int remaining) {
    if (remaining < 0) return limit + 1;
    if (node == null) return 4;
    if (node is bool) return node ? 4 : 5;
    if (node is num) return node.toString().length;
    if (node is String) return stringBytes(node, remaining);
    if (node is List<Object?>) {
      var bytes = 2;
      for (var index = 0; index < node.length; index += 1) {
        if (index > 0) bytes += 1;
        bytes += count(node[index], remaining - bytes);
        if (bytes > remaining) return limit + 1;
      }
      return bytes;
    }
    if (node is Map<Object?, Object?>) {
      var bytes = 2;
      var index = 0;
      for (final MapEntry<Object?, Object?> entry in node.entries) {
        if (entry.key is! String) return limit + 1;
        if (index++ > 0) bytes += 1;
        bytes += stringBytes(entry.key! as String, remaining - bytes) + 1;
        bytes += count(entry.value, remaining - bytes);
        if (bytes > remaining) return limit + 1;
      }
      return bytes;
    }
    // VM Service events are JSON. An unexpected runtime object is never
    // stringified because its toString could expose arbitrary application data.
    return limit + 1;
  }

  return count(value, limit);
}
