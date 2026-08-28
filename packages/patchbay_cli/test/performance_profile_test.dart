import 'dart:async';
import 'dart:convert';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/direct_connection.dart';
import 'package:patchbay_cli/src/performance_profile.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fixture/fake_client.dart';

final class _FakeVmSource implements PatchbayPerformanceVmSource {
  _FakeVmSource({
    this.availableStreams = const <String>['Dart', 'Embedder', 'GC'],
    this.events = const <Map<String, Object?>>[],
    this.configurationFailure,
    this.timelineFailure,
  });

  final List<String> availableStreams;
  static const List<String> recordedStreams = <String>['Dart'];
  static const List<int> times = <int>[1000000, 1025000];
  static const List<PatchbayHeapMeasurement> heaps = <PatchbayHeapMeasurement>[
    PatchbayHeapMeasurement(
      heapUsageBytes: 100,
      heapCapacityBytes: 200,
      externalUsageBytes: 10,
    ),
    PatchbayHeapMeasurement(
      heapUsageBytes: 130,
      heapCapacityBytes: 240,
      externalUsageBytes: 12,
    ),
  ];
  final List<Map<String, Object?>> events;
  final Object? configurationFailure;
  final Object? timelineFailure;
  final List<List<String>> streamWrites = <List<String>>[];
  var _timeIndex = 0;
  var _heapIndex = 0;
  bool timelineCancelled = false;

  @override
  Future<PatchbayTimelineConfiguration> timelineConfiguration() async {
    if (configurationFailure case final Object failure) {
      return Future<PatchbayTimelineConfiguration>.error(failure);
    }
    return PatchbayTimelineConfiguration(
      availableStreams: availableStreams,
      recordedStreams: recordedStreams,
    );
  }

  @override
  Future<void> setTimelineStreams(List<String> streams) async {
    streamWrites.add(List<String>.of(streams));
  }

  @override
  Future<int> timelineMicros() async => times[_timeIndex++];

  @override
  Future<PatchbayHeapMeasurement> memoryUsage(String isolateId) async {
    expect(isolateId, 'isolates/1');
    return heaps[_heapIndex++];
  }

  @override
  Future<PatchbayTimelineSubscription> listenTimeline(
    void Function(List<Map<String, Object?>> events) onEvents,
    void Function(Object error, StackTrace stackTrace) onError,
  ) async {
    onEvents(events);
    if (timelineFailure case final Object failure) {
      scheduleMicrotask(() => onError(failure, StackTrace.current));
    }
    return _FakeTimelineSubscription(() => timelineCancelled = true);
  }
}

final class _FakeTimelineSubscription implements PatchbayTimelineSubscription {
  _FakeTimelineSubscription(this._onCancel);

  final void Function() _onCancel;

  @override
  Future<void> cancel() async => _onCancel();
}

Future<Map<String, Object?>> _collect(
  _FakeVmSource source, {
  int eventLimit = 10000,
  PatchbayProfileDelay? delay,
}) =>
    PatchbayVmPerformanceProfiler(
      source: source,
      delay: delay ?? (_) async {},
    ).collect(
      isolateId: 'isolates/1',
      request: PatchbayPerformanceProfileRequest(
        duration: const Duration(milliseconds: 25),
        eventLimit: eventLimit,
      ),
    );

void main() {
  test('public VM fixture is reduced to the stable bounded summary', () async {
    final _FakeVmSource source = _FakeVmSource(
      events: <Map<String, Object?>>[
        <String, Object?>{
          'name': 'Frame',
          'ph': 'X',
          'dur': 8000,
          'ts': 1000001,
          'args': <String, Object?>{'token': 'must-not-escape'},
        },
        <String, Object?>{
          'name': 'Frame',
          'ph': 'X',
          'dur': 17000,
          'ts': 1009000,
        },
        <String, Object?>{
          'name': 'Frame',
          'ph': 'B',
          'ts': 1010000,
          'pid': 1,
          'tid': 2,
        },
        <String, Object?>{
          'name': 'Frame',
          'ph': 'E',
          'ts': 1030000,
          'pid': 1,
          'tid': 2,
        },
        <String, Object?>{
          'name': 'GPURasterizer::Draw',
          'ph': 'X',
          'dur': 4000,
          'ts': 1005000,
        },
        <String, Object?>{
          'name': 'CollectNewGeneration',
          'ph': 'B',
          'ts': 1010000,
        },
        <String, Object?>{
          'name': 'CollectNewGeneration',
          'ph': 'E',
          'ts': 1011000,
        },
        <String, Object?>{
          'name': 'CollectOldGeneration',
          'ph': 'X',
          'dur': 2000,
          'ts': 1015000,
        },
      ],
    );

    final Map<String, Object?> result = await _collect(source);

    expect(result['schema'], 'patchbay.performanceProfile.v1');
    expect(result['transport'], 'vmService');
    expect(result['factSource'], 'uiObserved');
    expect(result['window'], <String, Object?>{
      'startedAtVmMicros': 1000000,
      'endedAtVmMicros': 1025000,
      'durationMs': 25,
    });
    expect(source.timelineCancelled, isTrue);
    expect(source.streamWrites, <List<String>>[
      <String>['Dart', 'Embedder', 'GC'],
      <String>['Dart'],
    ]);

    final frames = result['frames']! as Map<String, Object?>;
    expect(frames['build'], <String, Object?>{
      'count': 3,
      'jankCount': 2,
      'averageMicros': 15000,
      'minMicros': 8000,
      'maxMicros': 20000,
      'p50Micros': 17000,
      'p90Micros': 20000,
      'p99Micros': 20000,
    });
    expect((frames['raster']! as Map)['count'], 1);
    expect(result['heap'], <String, Object?>{
      'sampleCount': 2,
      'startUsageBytes': 100,
      'endUsageBytes': 130,
      'deltaUsageBytes': 30,
      'peakObservedUsageBytes': 130,
      'startCapacityBytes': 200,
      'endCapacityBytes': 240,
      'startExternalBytes': 10,
      'endExternalBytes': 12,
    });
    expect(result['gc'], <String, Object?>{
      'count': 2,
      'newGenerationCount': 1,
      'oldGenerationCount': 1,
    });
    expect(jsonEncode(result), isNot(contains('must-not-escape')));
    expect(jsonEncode(result), isNot(contains('token')));
  });

  test('event count limit truncates deterministically', () async {
    final _FakeVmSource source = _FakeVmSource(
      events: List<Map<String, Object?>>.generate(
        4,
        (int index) => <String, Object?>{
          'name': 'Frame',
          'ph': 'X',
          'dur': index + 1,
          'ts': index,
        },
      ),
    );
    final Map<String, Object?> result = await _collect(source, eventLimit: 2);
    expect(result['sampling'], containsPair('sampleCount', 2));
    expect(result['sampling'], containsPair('droppedEventCount', 2));
    expect(result['sampling'], containsPair('truncated', true));
    final frames = result['frames']! as Map<String, Object?>;
    expect(frames['build'], containsPair('count', 2));
  });

  test(
    'byte limit stops before an oversized event without echoing it',
    () async {
      final String secret = 's' * (patchbayMaximumPerformanceBufferBytes + 1);
      final Map<String, Object?> result = await _collect(
        _FakeVmSource(
          events: <Map<String, Object?>>[
            <String, Object?>{'name': 'Frame', 'args': secret},
          ],
        ),
      );
      expect(result['sampling'], containsPair('sampleCount', 0));
      expect(result['sampling'], containsPair('droppedEventCount', 1));
      expect(result['sampling'], containsPair('processedEventBytes', 0));
      expect(result['sampling'], containsPair('truncated', true));
      expect(jsonEncode(result).length, lessThan(4096));
    },
  );

  test(
    'missing public VM capability is typed and does not mutate flags',
    () async {
      final _FakeVmSource source = _FakeVmSource(
        availableStreams: const <String>['Dart', 'GC'],
      );
      await expectLater(
        _collect(source),
        throwsA(
          isA<PatchbayProtocolException>()
              .having(
                (PatchbayProtocolException error) => error.code,
                'code',
                'performanceProfilingUnavailable',
              )
              .having(
                (PatchbayProtocolException error) =>
                    error.details['missingStreams'],
                'missing streams',
                <String>['Embedder'],
              ),
        ),
      );
      expect(source.streamWrites, isEmpty);
    },
  );

  test('older VM method-not-found is classified by code, not text', () async {
    final _FakeVmSource source = _FakeVmSource(
      configurationFailure: RPCError(
        'getVMTimelineFlags',
        RPCErrorKind.kMethodNotFound.code,
        'localized text that must not be parsed',
      ),
    );
    await expectLater(
      _collect(source),
      throwsA(
        isA<PatchbayProtocolException>()
            .having(
              (PatchbayProtocolException error) => error.code,
              'code',
              'performanceProfilingUnavailable',
            )
            .having(
              (PatchbayProtocolException error) => error.details['reason'],
              'reason',
              'vmRpcUnavailable',
            ),
      ),
    );
  });

  test(
    'cancelled or timed-out window restores prior timeline streams',
    () async {
      final _FakeVmSource source = _FakeVmSource();
      await expectLater(
        _collect(
          source,
          delay: (_) async => throw TimeoutException('fixture cancellation'),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(source.streamWrites, <List<String>>[
        <String>['Dart', 'Embedder', 'GC'],
        <String>['Dart'],
      ]);
    },
  );

  test('timeline stream failure is stable and restores prior flags', () async {
    final _FakeVmSource source = _FakeVmSource(
      timelineFailure: const PatchbayTransportException('vmServiceUnavailable'),
    );
    await expectLater(
      _collect(source, delay: (_) => Completer<void>().future),
      throwsA(
        isA<PatchbayTransportException>().having(
          (PatchbayTransportException error) => error.code,
          'code',
          'vmServiceUnavailable',
        ),
      ),
    );
    expect(source.timelineCancelled, isTrue);
    expect(source.streamWrites, <List<String>>[
      <String>['Dart', 'Embedder', 'GC'],
      <String>['Dart'],
    ]);
  });

  test('CLI forwards stable budgets and returns the VM summary', () async {
    PatchbayPerformanceProfileRequest? received;
    final FakePatchbayClient fake = FakePatchbayClient(
      commands: const <Map<String, Object?>>[],
      handle: (_, _) async => fakeCommandNotRegistered(),
      profilePerformance: (PatchbayPerformanceProfileRequest request) async {
        received = request;
        return <String, Object?>{
          'schema': 'patchbay.performanceProfile.v1',
          'factSource': 'uiObserved',
        };
      },
    );
    final StringBuffer out = StringBuffer();
    final int exitCode = await runPatchbayCliWithSeams(
      <String>[
        '--json',
        '--duration-ms',
        '25',
        '--sample-limit',
        '7',
        'perf',
        'profile',
      ],
      connect: (_) async => fake,
      output: out,
      errorOutput: StringBuffer(),
    );
    expect(exitCode, PatchbayExitCode.accepted);
    expect(received?.duration, const Duration(milliseconds: 25));
    expect(received?.eventLimit, 7);
    expect(
      jsonDecode(out.toString()),
      containsPair('factSource', 'uiObserved'),
    );
  });

  test('direct-style clients cannot fabricate VM performance facts', () async {
    final FakePatchbayClient fake = FakePatchbayClient(
      commands: const <Map<String, Object?>>[],
      handle: (_, _) async => fakeCommandNotRegistered(),
    );
    final StringBuffer out = StringBuffer();
    final int exitCode = await runPatchbayCliWithSeams(
      <String>['--json', '--duration-ms', '1', 'perf', 'profile'],
      connect: (_) async => fake,
      output: out,
      errorOutput: StringBuffer(),
    );
    expect(exitCode, PatchbayExitCode.protocol);
    expect(
      (jsonDecode(out.toString()) as Map)['error'],
      containsPair('code', 'profilingVmServiceRequired'),
    );
  });

  test('direct transport exposes the same stable profiling refusals', () async {
    final PatchbayDirectConnection direct = PatchbayDirectConnection(
      endpoint: Uri.parse(
        'http://127.0.0.1:1${PatchbayDirectConnection.protocolPath}',
      ),
      bearerToken: 'fixture-only',
      schemaVersion: 1,
      applicationId: 'dev.patchbay.fixture',
      appInstanceId: 'instance-1',
    );
    await expectLater(
      direct.performanceProfile(
        const PatchbayPerformanceProfileRequest(
          duration: Duration(milliseconds: 1),
        ),
      ),
      throwsA(
        isA<PatchbayProtocolException>().having(
          (PatchbayProtocolException error) => error.code,
          'code',
          'profilingVmServiceRequired',
        ),
      ),
    );
    await expectLater(
      direct.networkProfile(),
      throwsA(
        isA<PatchbayProtocolException>().having(
          (PatchbayProtocolException error) => error.code,
          'code',
          'networkProfilingUnavailable',
        ),
      ),
    );
    await direct.close();
  });

  test(
    'network profile is a stable refusal and never invokes App commands',
    () async {
      final FakePatchbayClient fake = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fail('net profile must not invoke the App'),
      );
      final StringBuffer out = StringBuffer();
      final int exitCode = await runPatchbayCliWithSeams(
        <String>['--json', 'net', 'profile'],
        connect: (_) async => fake,
        output: out,
        errorOutput: StringBuffer(),
      );
      expect(exitCode, PatchbayExitCode.protocol);
      expect(fake.calls, isEmpty);
      expect(
        (jsonDecode(out.toString()) as Map)['error'],
        containsPair('code', 'networkProfilingUnavailable'),
      );
    },
  );

  test('request budgets fail closed outside the frozen range', () {
    expect(
      () => const PatchbayPerformanceProfileRequest(
        duration: Duration(seconds: 61),
      ).validate(),
      throwsFormatException,
    );
    expect(
      () =>
          const PatchbayPerformanceProfileRequest(eventLimit: 10001).validate(),
      throwsFormatException,
    );
  });
}
