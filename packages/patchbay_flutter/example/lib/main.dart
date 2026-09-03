import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import 'example_app.dart';
import 'example_direct_transport.dart';
import 'example_domain.dart';
import 'example_log_source.dart';

const String exampleApplicationId = 'dev.patchbay.example';
const String counterSemanticsId = 'example.counter.value';
const String incrementSemanticsId = 'example.counter.increment';
const String identifierActionSemanticsId = 'example.identifier.action';
const String noteTargetId = 'example.note';
const String cardCaptureTargetId = 'example.card.capture';
const String semanticsBenchmarkCommand = 'example.benchmark.semanticsProbe';

/// Semantics identifier of the anchored-gesture surface (press-hold / drag).
const String gestureSurfaceSemanticsId = 'example.gesture.surface';

/// Semantics identifier of the scrollable list used for fling / drag paths.
const String gestureListSemanticsId = 'example.gesture.list';

/// Semantics identifier of the deliberately covered tap probe: policy allows
/// it, but an opaque non-modal decoration sits on top, so `ui.gesture.tap`
/// must reject it with `uiGestureTargetObscured` instead of tapping through.
const String gestureCoveredSemanticsId = 'example.gesture.covered';

/// Semantics identifier of the nested horizontal scrollable list.
const String gestureNestedListSemanticsId = 'example.gesture.nested';

/// Stable destination IDs the example router exposes to `navigation.*`.
const String homeDestinationId = 'example.home';
const String detailsDestinationId = 'example.details';

/// PB-050-17: the lazy-paging screen `ui.reveal` is built for.
///
/// It sits on its own destination rather than on the home screen so the
/// existing precheck steps keep driving exactly the surfaces they always did.
const String revealDestinationId = 'example.reveal';

/// Semantics identifier anchoring the reveal list's scroll container.
///
/// The anchor wraps the `ListView`, so the scroll semantics node is its
/// descendant — that is the shape `--container` resolves, and the shape the
/// reveal policy sees as `container.identifier`.
const String revealListSemanticsId = 'example.reveal.list';

/// A row several pages down: it is not mounted until reveal drives the list.
const String revealTargetSemanticsId = 'example.reveal.row.far';

/// A row with semantics but no pointer footprint, so a successful reveal
/// reports `reachability: semanticsOnly` and the caller must select the
/// canonical `ui perform tap ... --via semantics` route.
const String revealSemanticsOnlyRowId = 'example.reveal.row.semanticsOnly';

/// Pinned bottom bar. A row that stops under it stays `obstructed`, so reveal
/// has to keep stepping instead of calling a covered row "revealed".
const String revealOverlaySemanticsId = 'example.reveal.overlay';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final ExampleCounterModel model = ExampleCounterModel();
  final PatchbayUiRegistry registry = PatchbayUiRegistry();
  final ExampleRouter router = ExampleRouter();
  final PatchbayKey noteKey = PatchbayKey.text(
    noteTargetId,
    // `ui.text.set`/`.enter` are `sideEffect: appState` (see the doc comment
    // on `exampleWriteGate`), so they get the same write gate as every other
    // write path in this example.
    operationGates: const <PatchbayUiOperation, Set<String>>{
      PatchbayUiOperation.textSet: <String>{exampleWriteGate},
      PatchbayUiOperation.textEnter: <String>{exampleWriteGate},
    },
    registry: registry,
  );
  final PatchbayKey cardCaptureKey = PatchbayKey.capture(
    cardCaptureTargetId,
    // No `gates:` here on purpose: `ui.capture`/`.capture.diff` are declared
    // `sideEffect: none` / `mode: readOnly` by the shared protocol
    // descriptors, so this target only passes the (always-open) base gate,
    // same as `logs.*`/`blob.*`.
    registry: registry,
  );

  // Host construction is inside a compile-time false release branch. The Key
  // remains the same GlobalKey kind in every mode; only debug registrations
  // and service callbacks are removed from release reachability.
  if (!kReleaseMode) {
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      router: router,
    )..register();

    // 可选的第二条面。默认不启动；只有 --dart-define=patchbay.direct=1 才绑 loopback，
    // 而且仍要操作者显式 adb forward 才能从工作站到达。
    if (ExampleDirectTransport.requested) {
      unawaited(
        ExampleDirectTransport(host: host.service).start().then((
          Object? session,
        ) {
          if (session != null) {
            host.logs.write(
              category: 'transport',
              message: 'direct plane listening',
            );
          }
        }),
      );
    }
  }

  runApp(
    PatchbayExampleApp(
      model: model,
      noteKey: noteKey,
      cardCaptureKey: cardCaptureKey,
      router: router,
    ),
  );
}

final class ExampleCounterModel extends ValueNotifier<int> {
  ExampleCounterModel() : super(0);

  void increment() => value += 1;
}

/// The only consumer adapter in this example.
///
/// It owns the domain descriptor/handler while Patchbay owns transport,
/// identity envelopes, Flutter catalog composition and UI observation.
final class PatchbayExampleHost {
  /// Resolves the single log source before construction: the artifact service
  /// and [logs] must be the same instance, or records written by the app would
  /// never appear in `logs.*`.
  ///
  /// [consumerGate] and [permissions] exist for the same reason [registrar] and
  /// [isAppResumed] do: the composition root is the only place these can be
  /// substituted, and `example_domain_gate_test.dart` has to drive this exact
  /// host with the write gate closed — the state a fresh copy of this example
  /// is in before its author authorizes anything. They default to what the App
  /// actually ships.
  factory PatchbayExampleHost({
    required ExampleCounterModel model,
    required PatchbayUiRegistry registry,
    required ExampleRouter router,
    ExampleLogSource? logs,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    bool Function()? isAppResumed,
    PatchbayConsumerGate? consumerGate,
    ExamplePermissionGateway? permissions,
  }) => PatchbayExampleHost._(
    model: model,
    registry: registry,
    router: router,
    logs: logs ?? ExampleLogSource(),
    appInstanceId: appInstanceId,
    registrar: registrar,
    isAppResumed: isAppResumed,
    consumerGate: consumerGate ?? _exampleConsumerGate,
    permissions: permissions,
  );

  PatchbayExampleHost._({
    required ExampleCounterModel model,
    required PatchbayUiRegistry registry,
    required ExampleRouter router,
    required this.logs,
    required PatchbayConsumerGate consumerGate,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    bool Function()? isAppResumed,
    ExamplePermissionGateway? permissions,
  }) : _model = model,
       _router = router,
       domain = ExampleDomain(
         counter: model,
         logs: logs,
         permissions: permissions,
       ),
       bridge = PatchbayFlutterBridge(
         gates: PatchbayGateEvaluator(
           baseGate: _allowBaseGate,
           consumerGate: consumerGate,
         ),
         registry: registry,
         isAppResumed: isAppResumed,
         semanticsActionPolicy: _semanticsActionPolicy,
         gesturePolicy: _gesturePolicy,
         revealPolicy: exampleRevealPolicy,
         inspectPolicy: const PatchbayInspectPolicy(
           gates: <String>{exampleWriteGate},
           defaultLease: Duration(minutes: 2),
           maxLease: Duration(minutes: 10),
         ),
         keepAwakeGates: const <String>{exampleWriteGate},
         keepAwakeDelegate: exampleKeepAwake.apply,
         navigationAdapter: PatchbayNavigationAdapter(
           destinations: router.destinations,
           current: router.observe,
           back: router.back,
           backGateIds: const <String>{exampleWriteGate},
         ),
         // Empty on purpose: `ui.capture`/`.capture.diff` are declared
         // `sideEffect: none` in the shared protocol descriptors (see the
         // doc comment on `exampleWriteGate`), so this example treats them
         // as read-only diagnostics, same as `logs.*`/`blob.*` below.
         captureGates: const <String>{},
         rootController: PatchbayRootController.instance,
         artifacts: _artifacts(logs, consumerGate),
       ) {
    _service = PatchbayFlutterServiceHost(
      applicationId: exampleApplicationId,
      appInstanceId: appInstanceId,
      bridge: bridge,
      registrar: registrar,
      domainCatalog: _catalog,
      snapshot: _snapshot,
      domainInvokeWithContext: _invokeWithContext,
      // 审计事件只带参数形状与门结果，不带参数值；把它写进 example 自己的日志源，
      // 于是 `logs.*` 里能看到「谁在什么门下调了什么」，而值仍然不出 App。
      auditSink: _audit,
      onAuditSinkError: _auditFailed,
    );
  }

  final ExampleCounterModel _model;
  final ExampleRouter _router;

  /// Example-authored, already-redacted records served by `logs.*`.
  final ExampleLogSource logs;

  /// Domain commands, job ledger and the simulated device controller.
  final ExampleDomain domain;
  final PatchbayFlutterBridge bridge;

  /// Blob store plus log/blob commands. Injecting it is what turns on
  /// `ui.capture`, `ui.capture.diff`, `blob.metadata` and the `logs.*` family;
  /// without it those commands stay absent from the catalog.
  static PatchbayArtifactService _artifacts(
    ExampleLogSource logs,
    PatchbayConsumerGate consumerGate,
  ) => PatchbayArtifactService(
    blobs: PatchbayMemoryBlobStore(),
    gates: PatchbayGateEvaluator(
      baseGate: _allowBaseGate,
      consumerGate: consumerGate,
    ),
    logs: logs,
    // Empty on purpose: `blob.metadata`, `blob.read`, `logs.query`,
    // `logs.export` and `logs.tail` are all declared
    // `mode: PatchbayCommandMode.readOnly` by `PatchbayArtifactService`
    // itself — they read already-recorded facts, they do not write
    // anything. Gating them behind `exampleWriteGate` would contradict
    // this example's own "read-only diagnostics open by default" story,
    // so `gateIds` stays empty and they only pass the base gate below.
    gateIds: const <String>{},
  );
  late final PatchbayFlutterServiceHost _service;

  /// The one host both transports dispatch into.
  PatchbayFlutterServiceHost get service => _service;

  String get appInstanceId => _service.appInstanceId;

  void register() => _service.register();

  Future<Map<String, Object?>> _catalog() async => <String, Object?>{
    'commands': <Object?>[
      for (final PatchbayCommandDescriptor descriptor in domain.descriptors)
        descriptor.toJson(),
      _semanticsBenchmarkDescriptor.toJson(),
    ],
  };

  Future<Map<String, Object?>> _snapshot() async => <String, Object?>{
    'source': PatchbayFactSource.appRecorded.name,
    'counter': _model.value,
    'navigation': <String, Object?>{
      'destinationId': _router.current,
      'revision': _router.revision,
    },
    'device': <String, Object?>{'value': domain.device.value},
    'keepAwake': <String, Object?>{
      'held': exampleKeepAwake.held,
      'applications': exampleKeepAwake.applications,
    },
  };

  Future<Map<String, Object?>> _invokeWithContext(
    String command,
    Map<String, Object?> arguments,
    String requestId,
    PatchbayInvocationContext context,
  ) => command == semanticsBenchmarkCommand
      ? _benchmarkSemantics(arguments, requestId)
      : domain.invokeWithContext(command, arguments, requestId, context);

  Future<Map<String, Object?>> _benchmarkSemantics(
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    final Object? rawSamples = arguments['samples'];
    if (arguments.keys.any((String key) => key != 'samples') ||
        (rawSamples != null && rawSamples is! int)) {
      return _benchmarkRejected(
        requestId,
        'samples must be the only argument and must be an integer',
      );
    }
    final int sampleRuns = (rawSamples as int?) ?? 12;
    if (sampleRuns < 1 || sampleRuns > 50) {
      return _benchmarkRejected(requestId, 'samples must be between 1 and 50');
    }

    final PatchbayInvocation snapshot = await bridge.semantics.snapshot(
      maxNodes: 10000,
    );
    if (snapshot.admission != PatchbayAdmission.accepted) {
      return _benchmarkStageRejected(requestId, 'snapshot', snapshot);
    }
    final int scannedNodes =
        (snapshot.payload['nodes']! as List<Object?>).length;

    const int warmupRuns = 2;
    for (var run = 0; run < warmupRuns; run += 1) {
      await _benchmarkEndOfFrame();
      await _benchmarkMeasure(bridge.semantics.ensureOwner);
      await _benchmarkIdentifierProbe();
      final _ExampleBenchmarkSample wait = await _benchmarkWaitFrame();
      if (wait.value case final PatchbayInvocation invocation
          when invocation.admission != PatchbayAdmission.accepted) {
        return _benchmarkStageRejected(requestId, 'warmupWait', invocation);
      }
    }

    final List<_ExampleBenchmarkSample> endOfFrame =
        <_ExampleBenchmarkSample>[];
    final List<_ExampleBenchmarkSample> ensureOwner =
        <_ExampleBenchmarkSample>[];
    final List<_ExampleBenchmarkSample> probes = <_ExampleBenchmarkSample>[];
    final List<_ExampleBenchmarkSample> waitFrames =
        <_ExampleBenchmarkSample>[];
    for (var run = 0; run < sampleRuns; run += 1) {
      endOfFrame.add(await _benchmarkEndOfFrame());
      ensureOwner.add(await _benchmarkMeasure(bridge.semantics.ensureOwner));
      final _ExampleBenchmarkSample probe = await _benchmarkIdentifierProbe();
      if (probe.value == null) {
        return _benchmarkRejected(requestId, 'Semantics owner unavailable');
      }
      probes.add(probe);
      final _ExampleBenchmarkSample wait = await _benchmarkWaitFrame();
      if (wait.value case final PatchbayInvocation invocation
          when invocation.admission != PatchbayAdmission.accepted) {
        return _benchmarkStageRejected(requestId, 'uiWait', invocation);
      }
      waitFrames.add(wait);
    }

    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.uiObserved.name,
        'buildMode': kProfileMode
            ? 'profile'
            : kDebugMode
            ? 'debug'
            : 'release',
        'scannedNodes': scannedNodes,
        'warmupRuns': warmupRuns,
        'sampleRuns': sampleRuns,
        'metrics': <String, Object?>{
          'endOfFrame': _exampleBenchmarkSummary(endOfFrame),
          'ensureOwner': _exampleBenchmarkSummary(ensureOwner),
          'identifierProbe': <String, Object?>{
            ..._exampleBenchmarkSummary(probes),
            'matchedNodes': 0,
          },
          'uiWaitAdditionalFrame': _exampleBenchmarkSummary(waitFrames),
        },
        'derived': <String, Object?>{
          'unsatisfiedSemanticsWaitFramesPerPoll':
              _exampleMedianFrames(probes) + _exampleMedianFrames(waitFrames),
          'scanExclusiveEstimateMedianUs':
              (_exampleMedianElapsed(probes) -
                      _exampleMedianElapsed(ensureOwner))
                  .clamp(0, 1 << 31),
        },
      },
    ).toJson();
  }

  Future<_ExampleBenchmarkSample> _benchmarkEndOfFrame() =>
      _benchmarkMeasure(() async {
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
        return null;
      });

  Future<_ExampleBenchmarkSample> _benchmarkIdentifierProbe() =>
      _benchmarkMeasure(
        () =>
            bridge.semantics.observeIdentifier('benchmark.missing.identifier'),
      );

  Future<_ExampleBenchmarkSample> _benchmarkWaitFrame() {
    final int before = bridge.frameRevision;
    return _benchmarkMeasure(
      () => bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.frameRevision,
          timeout: const Duration(seconds: 1),
          revision: before,
        ),
      ),
    );
  }

  static Future<_ExampleBenchmarkSample> _benchmarkMeasure(
    Future<Object?> Function() operation,
  ) async {
    var completed = false;
    var frames = 0;
    void countFrame(Duration _) {
      if (completed) return;
      frames += 1;
      SchedulerBinding.instance.addPostFrameCallback(countFrame);
    }

    SchedulerBinding.instance.addPostFrameCallback(countFrame);
    final Stopwatch elapsed = Stopwatch()..start();
    try {
      final Object? value = await operation();
      return _ExampleBenchmarkSample(
        value: value,
        elapsedUs: elapsed.elapsedMicroseconds,
        frames: frames,
      );
    } finally {
      completed = true;
      elapsed.stop();
    }
  }

  static Map<String, Object?> _benchmarkRejected(
    String requestId,
    String reason,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: 'benchmarkInvalid',
      details: <String, Object?>{'reason': reason},
    ),
  ).toJson();

  static Map<String, Object?> _benchmarkStageRejected(
    String requestId,
    String stage,
    PatchbayInvocation invocation,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: 'benchmarkProbeFailed',
      details: <String, Object?>{
        'stage': stage,
        if (invocation.rejection case final PatchbayRejection rejection)
          'cause': rejection.code,
      },
    ),
  ).toJson();

  void _audit(PatchbayAuditEvent event) => logs.write(
    category: 'audit',
    message: event.command,
    fields: <String, Object?>{
      'requestId': event.requestId,
      'gateResult': event.gateResult,
      'parameterShape': event.parameterShape,
      if (event.executionClassification case final String classification)
        'executionClassification': classification,
    },
  );

  // 审计写失败不能把被审计的命令一起拖失败：记一条降级说明，然后继续。
  void _auditFailed(
    Object error,
    StackTrace stackTrace,
    PatchbayAuditEvent event,
  ) => logs.write(
    category: 'audit',
    message: 'audit sink failed',
    level: PatchbayLogLevelWire.warning,
    fields: <String, Object?>{
      'command': event.command,
      'error': error.runtimeType.toString(),
    },
  );

  void dispose() => bridge.dispose();
}

const PatchbayCommandDescriptor _semanticsBenchmarkDescriptor =
    PatchbayCommandDescriptor(
      name: semanticsBenchmarkCommand,
      summary: 'Measure Semantics probe stages in the example App.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'samples',
          type: PatchbayParameterType.integer,
          required: false,
          defaultValue: 12,
        ),
      ],
    );

Map<String, Object?> _exampleBenchmarkSummary(
  List<_ExampleBenchmarkSample> samples,
) => <String, Object?>{
  'medianUs': _exampleMedianElapsed(samples),
  'medianFrames': _exampleMedianFrames(samples),
  'minUs': samples
      .map((_ExampleBenchmarkSample sample) => sample.elapsedUs)
      .reduce((int left, int right) => left < right ? left : right),
  'maxUs': samples
      .map((_ExampleBenchmarkSample sample) => sample.elapsedUs)
      .reduce((int left, int right) => left > right ? left : right),
};

int _exampleMedianElapsed(List<_ExampleBenchmarkSample> samples) =>
    _exampleMedian(samples.map((sample) => sample.elapsedUs));

int _exampleMedianFrames(List<_ExampleBenchmarkSample> samples) =>
    _exampleMedian(samples.map((sample) => sample.frames));

int _exampleMedian(Iterable<int> values) {
  final List<int> sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

final class _ExampleBenchmarkSample {
  const _ExampleBenchmarkSample({
    required this.value,
    required this.elapsedUs,
    required this.frames,
  });

  final Object? value;
  final int elapsedUs;
  final int frames;
}

/// `PatchbayBaseGate` is `FutureOr<PatchbayGateDecision> Function()` — no
/// argument reaches it, for any command. It structurally cannot tell a read
/// from a write; that split only exists in *which* operations declare a
/// consumer gate at all (see `exampleWriteGate`'s doc comment). Keeping this
/// `allow()` is what "shortest integration opens read-only diagnostics by
/// default" means in practice: every read-only command this example exposes
/// (`ui.semantics.tree`, `ui.wait`, `navigation.catalog`/`.current`,
/// `ui.keepAwake.status`, `ui.inspect.status`, `ui.capture`/`.capture.diff`,
/// `blob.*`, `logs.*`, `example.permission.status`, `patchbay.job.get`/
/// `.wait`) declares zero consumer gates.
///
/// Note the asymmetry the host enforces since PB-050-25: read-only *domain*
/// commands skip this gate entirely, while a domain **write** always crosses
/// it — even one that declares no consumer gate of its own. A consumer whose
/// base gate is conditional ("reject until the controller is attached") will
/// therefore see domain writes refused inside those windows, which is the
/// point: the base gate is not optional.
FutureOr<PatchbayGateDecision> _allowBaseGate() =>
    const PatchbayGateDecision.allow();

/// Out-of-the-box behavior for this example's one write gate.
///
/// Every write path on both planes declares `exampleWriteGate` (see its doc
/// comment in `example_domain.dart`), so in a fresh copy of this example this
/// function is the entire write policy — UI operators and the six domain
/// write commands alike. The factory-safe shape is: reject with a code +
/// notice a script can act on, and require the host to opt in by name —
/// [factoryDefaultWriteGateDecision] is that reference implementation,
/// unit-tested directly in `example_consumer_test.dart`.
///
/// This example does **not** call it for `exampleWriteGate`, though — it
/// allows that one gate outright. That is a deliberate, disclosed exception,
/// not the recommended default: `tool/example_precheck.sh` drives
/// `ui.tap`/`ui.action`/`ui.gesture.*`/`navigation.go|push|back`/`ui.inspect.select`/
/// `ui.keepAwake.set`/`ui.text.set|enter` plus the domain write chain on a
/// real device and asserts they succeed (AGENTS.md "验证分两段", stage one),
/// and that precheck's pass/fail contract must not change under this task
/// (PB-050-22). Delete the `exampleWriteGate` special case below and every one
/// of those write paths goes back to the factory default (closed) immediately;
/// `example_domain_gate_test.dart` drives exactly that closed state.
FutureOr<PatchbayGateDecision> _exampleConsumerGate(String id) {
  if (id != exampleWriteGate) {
    return PatchbayGateDecision.reject(
      code: 'unknownConsumerGate',
      notice: 'No consumer gate named $id.',
    );
  }
  // 预检需要：见上面的文档注释。真正的出厂默认是下面这行——删掉本函数里
  // 对 exampleWriteGate 的特判，写路径就会立即回落到它：
  //   return factoryDefaultWriteGateDecision(id);
  return const PatchbayGateDecision.allow();
}

/// The factory-safe default for a write gate this example has not
/// authorized: reject, with a code a script can branch on and a notice that
/// says why and what to do about it.
///
/// `_exampleConsumerGate` above does not call this for `exampleWriteGate` —
/// see its doc comment for why — so this function does not fire anywhere in
/// the example as shipped. It is the reference shape a real consumer should
/// keep, exercised directly by `example_consumer_test.dart` rather than
/// through the running app.
PatchbayGateDecision factoryDefaultWriteGateDecision(String gateId) =>
    PatchbayGateDecision.reject(
      code: 'writeGateClosedByDefault',
      notice:
          'This is a factory-safe default: "$gateId" is a write gate and '
          'stays closed until the host authorizes it here.',
    );

/// Executable semantics actions are opt-in per target.
///
/// The increment button and the explicit identifier-action probe are the only
/// actionable nodes. The counter value remains a read-only live region.
PatchbaySemanticsActionDecision _semanticsActionPolicy(
  PatchbaySemanticsTarget target,
  PatchbaySemanticsAction action,
) {
  if (target.identifier == incrementSemanticsId &&
      action == PatchbaySemanticsAction.tap) {
    return const PatchbaySemanticsActionDecision.allow(
      gateIds: <String>{exampleWriteGate},
    );
  }
  if (target.identifier == identifierActionSemanticsId &&
      const <PatchbaySemanticsAction>{
        PatchbaySemanticsAction.focus,
        PatchbaySemanticsAction.scrollDown,
        PatchbaySemanticsAction.setText,
      }.contains(action)) {
    return const PatchbaySemanticsActionDecision.allow(
      gateIds: <String>{exampleWriteGate},
    );
  }
  // PB-050-17: both rows `ui.reveal` can drive to reveal also opt in to a
  // Semantics tap. `reachability: pointer` is a geometry fact, not gesture
  // authorization: the example keeps pointer gestures scoped to the dedicated
  // surfaces below, so the device precheck explicitly selects the canonical
  // Semantics route after reveal. Both rows land on the same `tapIdentifier`
  // seam and therefore the same policy check.
  if ((target.identifier == revealTargetSemanticsId ||
          target.identifier == revealSemanticsOnlyRowId) &&
      action == PatchbaySemanticsAction.tap) {
    return const PatchbaySemanticsActionDecision.allow(
      gateIds: <String>{exampleWriteGate},
    );
  }
  return const PatchbaySemanticsActionDecision.reject(
    rejectionNotice: 'This example does not allow that semantics action.',
  );
}

/// Anchored gestures are allowed on the dedicated surfaces built for them, with
/// budgets small enough that a runaway path is rejected rather than replayed.
PatchbayGestureDecision _gesturePolicy(
  PatchbayGestureTarget target,
  PatchbayGestureKind gesture,
) {
  const Set<String> surfaces = <String>{
    gestureSurfaceSemanticsId,
    gestureListSemanticsId,
    gestureNestedListSemanticsId,
    gestureCoveredSemanticsId,
  };
  if (!surfaces.contains(target.identifier)) {
    return const PatchbayGestureDecision.reject(
      rejectionNotice: 'This example only opens its gesture surfaces.',
    );
  }
  if (gesture == PatchbayGestureKind.fling &&
      target.identifier == gestureSurfaceSemanticsId) {
    return const PatchbayGestureDecision.reject(
      rejectionNotice: 'The press-hold surface does not accept a fling.',
    );
  }
  // 预算只能相对协议上限**收紧**：`maxVelocity` 的单位是「目标宽/高每秒」，上限 20，
  // 不是设备像素每秒。声明一个越界的预算不会被当成"放宽"，而是让这条 decision 整体非法——
  // 于是该表面上的每一次手势都按 `uiGestureBudgetExceeded` 拒绝，连不带速度的 press-hold
  // 也一起被拒。这里写 8 就是 20 以内的收紧值。
  return const PatchbayGestureDecision.allow(
    gateIds: <String>{exampleWriteGate},
    maxDurationMs: 4000,
    maxPathPoints: 32,
    maxVelocity: 8,
  );
}

/// PB-050-17: driving a scroll container is authorized per container, and the
/// authorization is re-asked before every single step.
///
/// Two things this example deliberately shows:
///
/// - **Only the reveal list is open.** `container.identifier` is the innermost
///   anchor identifier of the container being driven, so any other scrollable
///   on screen — including the gesture list on the home destination — is
///   refused outright. `ui.reveal` is a write, so a fresh copy of this example
///   opens nothing it did not name here.
/// - **Budgets only ever tighten.** 60 steps / 20 s are well inside the host
///   ceilings (200 / 120 s). A request asking for more is *rejected*, not
///   silently clamped, because a clamped `stepBudgetExceeded` reads exactly
///   like "the list really is that long".
///
/// The declared gate is the same `exampleWriteGate` every other write path
/// crosses, and reveal re-evaluates it once per step. A consumer whose gate is
/// interactive should read the note on that gate before wiring one here: a
/// 40-step reveal would ask 41 times.
PatchbayRevealDecision exampleRevealPolicy(
  PatchbaySemanticsTarget container,
  PatchbayRevealDirection direction,
) {
  if (container.identifier != revealListSemanticsId) {
    return const PatchbayRevealDecision.reject(
      rejectionNotice: 'This example only opens its reveal list.',
    );
  }
  return const PatchbayRevealDecision.allow(
    gateIds: <String>{exampleWriteGate},
    maxSteps: 60,
    maxDurationMs: 20000,
  );
}

/// Records what the host asked the platform to do, without pretending the
/// screen is actually awake.
///
/// A real consumer injects the one platform line here (Android
/// `FLAG_KEEP_SCREEN_ON`, iOS `isIdleTimerDisabled`). The example has no
/// tracked platform directory, so it can only account for the request. The
/// protocol already says `source: appRecorded` — it never claims the screen
/// stayed on — so this stub exercises the accounting and lease paths honestly.
final ExampleKeepAwakeRecorder exampleKeepAwake = ExampleKeepAwakeRecorder();

final class ExampleKeepAwakeRecorder {
  bool held = false;
  int applications = 0;

  void apply(bool enabled) {
    held = enabled;
    applications += 1;
  }
}

/// Two destinations over a real `Navigator`, with a monotonic revision.
final class ExampleRouter {
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  int _revision = 0;
  String _current = homeDestinationId;

  int get revision => _revision;
  String get current => _current;

  PatchbayNavigationObservation observe() => PatchbayNavigationObservation(
    revision: _revision,
    destinationId: _current,
  );

  List<PatchbayNavigationDestination> destinations() =>
      <PatchbayNavigationDestination>[
        PatchbayNavigationDestination(
          id: homeDestinationId,
          summary: 'Counter, note field and gesture surfaces.',
          gateIds: const <String>{exampleWriteGate},
          go: () => _go(homeDestinationId),
        ),
        PatchbayNavigationDestination(
          id: detailsDestinationId,
          summary: 'A second screen used by walkthrough verification.',
          gateIds: const <String>{exampleWriteGate},
          go: () => _go(detailsDestinationId),
          push: () => _push(detailsDestinationId),
        ),
        PatchbayNavigationDestination(
          id: revealDestinationId,
          summary:
              'A lazy-paging list under a pinned bar, for scroll-to-reveal.',
          gateIds: const <String>{exampleWriteGate},
          go: () => _go(revealDestinationId),
          push: () => _push(revealDestinationId),
        ),
      ];

  Future<void> back() async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return;
    navigator.pop();
    _land(homeDestinationId);
  }

  // pushNamed / pushNamedAndRemoveUntil 返回的 Future 要等那条路由被 pop 才完成。
  // await 它等于把一次导航请求挂到用户按返回为止：宿主不回答，CLI 只看到
  // appUnresponsive。所以只发起导航并立即记账，不等待路由结果。
  Future<void> _go(String destination) async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      navigator.pushNamedAndRemoveUntil(
        destination,
        (Route<Object?> route) => false,
      ),
    );
    _land(destination);
  }

  Future<void> _push(String destination) async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(navigator.pushNamed(destination));
    _land(destination);
  }

  void _land(String destination) {
    _current = destination;
    _revision += 1;
  }
}
