import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

const int _declaredTargets = 256;
const int _warmupRuns = 2;
const int _sampleRuns = 12;

void main() {
  testWidgets('PB-050-04 records semantics probe frame amplification', (
    WidgetTester tester,
  ) async {
    var observedFrames = 0;
    tester.binding.addPersistentFrameCallback((Duration _) {
      observedFrames += 1;
    });

    await tester.pumpWidget(_fixedSemanticsTree());
    final PatchbayFlutterBridge bridge = _bridge();
    addTearDown(bridge.dispose);

    final _Measurement<PatchbayInvocation> snapshot = await _measure(
      tester,
      frames: () => observedFrames,
      operation: () => bridge.semantics.snapshot(maxNodes: 10000),
    );
    expect(snapshot.value.admission, PatchbayAdmission.accepted);
    final int scannedNodes =
        (snapshot.value.payload['nodes']! as List<Object?>).length;
    expect(scannedNodes, greaterThanOrEqualTo(_declaredTargets));

    for (var run = 0; run < _warmupRuns; run += 1) {
      await _endOfFrameSample(tester, () => observedFrames);
      await _measure(
        tester,
        frames: () => observedFrames,
        operation: bridge.semantics.ensureOwner,
      );
      await _identifierSample(tester, bridge, () => observedFrames);
      await _waitFrameSample(tester, bridge, () => observedFrames);
    }

    final List<_Measurement<void>> endOfFrame = <_Measurement<void>>[];
    final List<_Measurement<Object?>> ensureOwner = <_Measurement<Object?>>[];
    final List<_Measurement<PatchbaySemanticsIdentifierObservation?>> probes =
        <_Measurement<PatchbaySemanticsIdentifierObservation?>>[];
    final List<_Measurement<PatchbayInvocation>> waitFrames =
        <_Measurement<PatchbayInvocation>>[];

    for (var run = 0; run < _sampleRuns; run += 1) {
      endOfFrame.add(await _endOfFrameSample(tester, () => observedFrames));
      ensureOwner.add(
        await _measure(
          tester,
          frames: () => observedFrames,
          operation: bridge.semantics.ensureOwner,
        ),
      );
      probes.add(await _identifierSample(tester, bridge, () => observedFrames));
      waitFrames.add(
        await _waitFrameSample(tester, bridge, () => observedFrames),
      );
    }

    // PB-050-07 / DG-050-05 之后的 cadence 事实（帧数是稳定断言，不是性能数）：
    // ready owner 的 `ensureOwner` 与 identifier probe 都是**零额外帧**，一次未
    // 满足的 semantics wait poll 因此从 2 帧降到 1 帧。
    expect(endOfFrame.map((sample) => sample.frames), everyElement(1));
    expect(ensureOwner.map((sample) => sample.frames), everyElement(0));
    expect(probes.map((sample) => sample.frames), everyElement(0));
    expect(waitFrames.map((sample) => sample.frames), everyElement(1));
    expect(
      _medianFrames(probes) + _medianFrames(waitFrames),
      1,
      reason: '一次未满足的 semantics wait poll = 1 帧',
    );

    final Map<String, Object?> report = <String, Object?>{
      'schemaVersion': 1,
      'declaredTargets': _declaredTargets,
      'scannedNodes': scannedNodes,
      'warmupRuns': _warmupRuns,
      'sampleRuns': _sampleRuns,
      'metrics': <String, Object?>{
        'endOfFrame': _summary(endOfFrame),
        'ensureOwner': _summary(ensureOwner),
        'identifierProbe': <String, Object?>{
          ..._summary(probes),
          'matchedNodes': 0,
        },
        'uiWaitAdditionalFrame': _summary(waitFrames),
      },
      'derived': <String, Object?>{
        'unsatisfiedSemanticsWaitFramesPerPoll':
            _medianFrames(probes) + _medianFrames(waitFrames),
        'scanExclusiveEstimateMedianUs':
            (_medianElapsed(probes) - _medianElapsed(ensureOwner)).clamp(
              0,
              1 << 31,
            ),
      },
    };

    // A stable prefix lets CI and local runs extract the JSON without parsing
    // the Flutter test reporter. Timing values are evidence, not thresholds.
    // ignore: avoid_print
    print('PB05004_METRICS=${jsonEncode(report)}');
    bridge.dispose();
  });
}

Future<_Measurement<void>> _endOfFrameSample(
  WidgetTester tester,
  int Function() frames,
) => _measure<void>(
  tester,
  frames: frames,
  operation: () async {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  },
);

Future<_Measurement<PatchbaySemanticsIdentifierObservation?>> _identifierSample(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
  int Function() frames,
) async {
  final _Measurement<PatchbaySemanticsIdentifierObservation?> sample =
      await _measure(
        tester,
        frames: frames,
        operation: () =>
            bridge.semantics.observeIdentifier('benchmark.missing.identifier'),
      );
  expect(sample.value, isNotNull);
  expect(sample.value!.matches, isEmpty);
  return sample;
}

Future<_Measurement<PatchbayInvocation>> _waitFrameSample(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
  int Function() frames,
) async {
  final int before = bridge.frameRevision;
  final _Measurement<PatchbayInvocation> sample = await _measure(
    tester,
    frames: frames,
    operation: () => bridge.wait.wait(
      PatchbayUiWaitRequest(
        condition: PatchbayUiWaitCondition.frameRevision,
        timeout: const Duration(seconds: 1),
        revision: before,
      ),
    ),
  );
  expect(sample.value.admission, PatchbayAdmission.accepted);
  expect(sample.value.payload['frameRevision'], greaterThan(before));
  return sample;
}

Future<_Measurement<T>> _measure<T>(
  WidgetTester tester, {
  required int Function() frames,
  required Future<T> Function() operation,
}) async {
  final int before = frames();
  final Stopwatch elapsed = Stopwatch()..start();
  final Future<T> pending = operation();
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  // PB-050-07：先排空微任务再决定是否 pump。零帧操作（ready owner 的 probe）如果
  // 被脚手架无条件 pump 一次，测出来的「帧数」就是脚手架自己的，不是被测行为的。
  await tester.idle();
  for (var pump = 0; pump < 10 && !completed; pump += 1) {
    await tester.pump();
    await tester.idle();
  }
  if (!completed) {
    throw StateError('benchmark operation did not complete in 10 frames');
  }
  final T value = await pending;
  elapsed.stop();
  return _Measurement<T>(
    value: value,
    elapsedUs: elapsed.elapsedMicroseconds,
    frames: frames() - before,
  );
}

Map<String, Object?> _summary(Iterable<_Measurement<Object?>> samples) =>
    <String, Object?>{
      'medianUs': _medianElapsed(samples),
      'medianFrames': _medianFrames(samples),
      'minUs': samples
          .map((sample) => sample.elapsedUs)
          .reduce((left, right) => left < right ? left : right),
      'maxUs': samples
          .map((sample) => sample.elapsedUs)
          .reduce((left, right) => left > right ? left : right),
    };

int _medianElapsed(Iterable<_Measurement<Object?>> samples) =>
    _median(samples.map((sample) => sample.elapsedUs));

int _medianFrames(Iterable<_Measurement<Object?>> samples) =>
    _median(samples.map((sample) => sample.frames));

int _median(Iterable<int> values) {
  final List<int> sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

PatchbayFlutterBridge _bridge() => PatchbayFlutterBridge(
  gates: PatchbayGateEvaluator(
    baseGate: () => const PatchbayGateDecision.allow(),
    consumerGate: (_) => const PatchbayGateDecision.allow(),
  ),
  registry: PatchbayUiRegistry(),
  isAppResumed: () => true,
);

Widget _fixedSemanticsTree() => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var index = 0; index < _declaredTargets; index += 1)
          Semantics(
            identifier: 'benchmark.node.$index',
            container: true,
            explicitChildNodes: true,
            child: const SizedBox(width: 1, height: 1),
          ),
      ],
    ),
  ),
);

final class _Measurement<T> {
  const _Measurement({
    required this.value,
    required this.elapsedUs,
    required this.frames,
  });

  final T value;
  final int elapsedUs;
  final int frames;
}
