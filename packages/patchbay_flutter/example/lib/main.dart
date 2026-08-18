import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

const String exampleApplicationId = 'dev.patchbay.example';
const String incrementCommand = 'example.counter.increment';
const String counterSemanticsId = 'example.counter.value';
const String incrementSemanticsId = 'example.counter.increment';
const String noteTargetId = 'example.note';

/// Semantics identifier of the anchored-gesture surface (press-hold / drag).
const String gestureSurfaceSemanticsId = 'example.gesture.surface';

/// Semantics identifier of the scrollable list used for fling / drag paths.
const String gestureListSemanticsId = 'example.gesture.list';

/// Stable destination IDs the example router exposes to `navigation.*`.
const String homeDestinationId = 'example.home';
const String detailsDestinationId = 'example.details';

/// The single consumer gate this example declares. Everything the host may
/// execute passes it, so an unknown gate ID stays a rejection rather than a
/// silently allowed write.
const String exampleWriteGate = 'example.uiWrite';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final ExampleCounterModel model = ExampleCounterModel();
  final PatchbayUiRegistry registry = PatchbayUiRegistry();
  final ExampleRouter router = ExampleRouter();
  final PatchbayKey noteKey = PatchbayKey.text(
    noteTargetId,
    registry: registry,
  );

  // Host construction is inside a compile-time false release branch. The Key
  // remains the same GlobalKey kind in every mode; only debug registrations
  // and service callbacks are removed from release reachability.
  if (!kReleaseMode) {
    PatchbayExampleHost(
      model: model,
      registry: registry,
      router: router,
    ).register();
  }

  runApp(PatchbayExampleApp(model: model, noteKey: noteKey, router: router));
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
  PatchbayExampleHost({
    required ExampleCounterModel model,
    required PatchbayUiRegistry registry,
    required ExampleRouter router,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    bool Function()? isAppResumed,
  }) : _model = model,
       _router = router,
       bridge = PatchbayFlutterBridge(
         gates: const PatchbayGateEvaluator(
           baseGate: _allowBaseGate,
           consumerGate: _exampleConsumerGate,
         ),
         registry: registry,
         isAppResumed: isAppResumed,
         semanticsActionPolicy: _semanticsActionPolicy,
         gesturePolicy: _gesturePolicy,
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
       ) {
    _service = PatchbayFlutterServiceHost(
      applicationId: exampleApplicationId,
      appInstanceId: appInstanceId,
      bridge: bridge,
      registrar: registrar,
      domainCatalog: _catalog,
      snapshot: _snapshot,
      domainInvoke: _invoke,
    );
  }

  static const PatchbayCommandDescriptor _incrementDescriptor =
      PatchbayCommandDescriptor(
        name: incrementCommand,
        summary: 'Increment the example consumer counter.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      );

  final ExampleCounterModel _model;
  final ExampleRouter _router;
  final PatchbayFlutterBridge bridge;
  late final PatchbayFlutterServiceHost _service;

  String get appInstanceId => _service.appInstanceId;

  void register() => _service.register();

  Future<Map<String, Object?>> _catalog() async => <String, Object?>{
    'commands': <Object?>[_incrementDescriptor.toJson()],
  };

  Future<Map<String, Object?>> _snapshot() async => <String, Object?>{
    'source': PatchbayFactSource.appRecorded.name,
    'counter': _model.value,
    'navigation': <String, Object?>{
      'destinationId': _router.current,
      'revision': _router.revision,
    },
    'keepAwake': <String, Object?>{
      'held': exampleKeepAwake.held,
      'applications': exampleKeepAwake.applications,
    },
  };

  Future<Map<String, Object?>> _invoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    if (command != incrementCommand) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: 'commandNotRegistered',
          details: <String, Object?>{'command': command},
        ),
      ).toJson();
    }
    if (arguments.isNotEmpty) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'invalidArguments'),
      ).toJson();
    }
    _model.increment();
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.appRecorded.name,
        'counter': _model.value,
      },
    ).toJson();
  }

  void dispose() => bridge.dispose();
}

FutureOr<PatchbayGateDecision> _allowBaseGate() =>
    const PatchbayGateDecision.allow();

/// Only the one gate this example declares is allowed; anything else stays a
/// typed rejection so a policy that names an unknown gate cannot write.
FutureOr<PatchbayGateDecision> _exampleConsumerGate(String id) =>
    id == exampleWriteGate
    ? const PatchbayGateDecision.allow()
    : PatchbayGateDecision.reject(
        code: 'unknownConsumerGate',
        notice: 'No consumer gate named $id.',
      );

/// Executable semantics actions are opt-in per target.
///
/// The increment button is the only actionable node. The counter value is a
/// read-only live region: allowing a tap there would let a caller "press" a
/// label and read the result as a domain effect.
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
  return const PatchbaySemanticsActionDecision.reject(
    rejectionNotice: 'Only the increment button accepts semantics actions.',
  );
}

/// Anchored gestures are allowed on the two surfaces built for them, with
/// budgets small enough that a runaway path is rejected rather than replayed.
PatchbayGestureDecision _gesturePolicy(
  PatchbayGestureTarget target,
  PatchbayGestureKind gesture,
) {
  const Set<String> surfaces = <String>{
    gestureSurfaceSemanticsId,
    gestureListSemanticsId,
  };
  if (!surfaces.contains(target.identifier)) {
    return const PatchbayGestureDecision.reject(
      rejectionNotice: 'This example only opens its two gesture surfaces.',
    );
  }
  if (gesture == PatchbayGestureKind.fling &&
      target.identifier == gestureSurfaceSemanticsId) {
    return const PatchbayGestureDecision.reject(
      rejectionNotice: 'The press-hold surface does not accept a fling.',
    );
  }
  return const PatchbayGestureDecision.allow(
    gateIds: <String>{exampleWriteGate},
    maxDurationMs: 4000,
    maxPathPoints: 32,
    maxVelocity: 8000,
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
      ];

  Future<void> back() async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return;
    navigator.pop();
    _land(homeDestinationId);
  }

  Future<void> _go(String destination) async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.pushNamedAndRemoveUntil(
      destination,
      (Route<Object?> route) => false,
    );
    _land(destination);
  }

  Future<void> _push(String destination) async {
    final NavigatorState? navigator = navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.pushNamed(destination);
    _land(destination);
  }

  void _land(String destination) {
    _current = destination;
    _revision += 1;
  }
}

final class PatchbayExampleApp extends StatefulWidget {
  const PatchbayExampleApp({
    required this.model,
    required this.noteKey,
    required this.router,
    super.key,
  });

  final ExampleCounterModel model;
  final PatchbayKey noteKey;
  final ExampleRouter router;

  @override
  State<PatchbayExampleApp> createState() => _PatchbayExampleAppState();
}

final class _PatchbayExampleAppState extends State<PatchbayExampleApp> {
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: widget.router.navigatorKey,
    initialRoute: homeDestinationId,
    routes: <String, WidgetBuilder>{
      homeDestinationId: (BuildContext context) => _ExampleHomeScreen(
        model: widget.model,
        noteKey: widget.noteKey,
        noteController: _noteController,
      ),
      detailsDestinationId: (BuildContext context) =>
          const _ExampleDetailsScreen(),
    },
  );
}

final class _ExampleHomeScreen extends StatelessWidget {
  const _ExampleHomeScreen({
    required this.model,
    required this.noteKey,
    required this.noteController,
  });

  final ExampleCounterModel model;
  final PatchbayKey noteKey;
  final TextEditingController noteController;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Patchbay example')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ValueListenableBuilder<int>(
            valueListenable: model,
            builder: (BuildContext context, int count, Widget? child) =>
                Semantics(
                  identifier: counterSemanticsId,
                  label: 'Counter value',
                  value: '$count',
                  liveRegion: true,
                  child: Text('Count: $count'),
                ),
          ),
          const SizedBox(height: 16),
          Semantics(
            identifier: incrementSemanticsId,
            button: true,
            child: ElevatedButton(
              onPressed: model.increment,
              child: const Text('Increment'),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: noteKey,
            controller: noteController,
            decoration: const InputDecoration(labelText: 'Debug note'),
          ),
          const SizedBox(height: 16),
          const _ExampleGestureSurface(),
          const SizedBox(height: 16),
          const Expanded(child: _ExampleGestureList()),
        ],
      ),
    ),
  );
}

/// Press-hold / drag target. It reports what it observed so a CLI-driven
/// gesture can be verified from the App side instead of from a screenshot.
final class _ExampleGestureSurface extends StatefulWidget {
  const _ExampleGestureSurface();

  @override
  State<_ExampleGestureSurface> createState() => _ExampleGestureSurfaceState();
}

final class _ExampleGestureSurfaceState extends State<_ExampleGestureSurface> {
  String _observed = 'none';

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: gestureSurfaceSemanticsId,
    label: 'Gesture surface',
    value: _observed,
    child: GestureDetector(
      onLongPress: () => setState(() => _observed = 'longPress'),
      onPanUpdate: (DragUpdateDetails details) =>
          setState(() => _observed = 'pan'),
      child: Container(
        height: 96,
        alignment: Alignment.center,
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Text('gesture surface: $_observed'),
      ),
    ),
  );
}

/// Scrollable list for fling and multi-segment drag paths.
final class _ExampleGestureList extends StatelessWidget {
  const _ExampleGestureList();

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: gestureListSemanticsId,
    label: 'Gesture list',
    child: ListView.builder(
      itemCount: 60,
      itemBuilder: (BuildContext context, int index) =>
          ListTile(dense: true, title: Text('row $index')),
    ),
  );
}

final class _ExampleDetailsScreen extends StatelessWidget {
  const _ExampleDetailsScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Details')),
    body: Center(
      child: Semantics(
        identifier: 'example.details.body',
        child: Text('Second destination'),
      ),
    ),
  );
}
