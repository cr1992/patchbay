import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  group('destination navigation', () {
    testWidgets(
      'catalog/current are read-only and go completes after a frame',
      (tester) async {
        final _NavigationState state = _NavigationState();
        var requests = 0;
        final PatchbayFlutterBridge bridge = _bridge(
          adapter: _adapter(
            state,
            goSettings: () {
              requests += 1;
              state.move('settings');
            },
          ),
        );
        addTearDown(bridge.dispose);

        final PatchbayInvocation catalog = await bridge.navigation!.catalog();
        final PatchbayInvocation current = await bridge.navigation!.current();
        expect(catalog.payload['source'], 'appRecorded');
        expect(current.payload['destinationId'], 'home');
        expect(requests, 0);

        final PatchbayInvocation result = await _pumpUntilComplete(
          tester,
          bridge.navigation!.go(
            destinationId: 'settings',
            revision: 1,
            timeout: const Duration(seconds: 1),
          ),
        );

        expect(result.admission, PatchbayAdmission.accepted);
        expect(result.payload, containsPair('outcome', 'arrived'));
        expect(result.payload, containsPair('source', 'uiObserved'));
        expect(result.payload['frameRevision'], isPositive);
        expect(requests, 1);
      },
    );

    testWidgets('redirect, timeout, stale revision, and background are typed', (
      tester,
    ) async {
      final _NavigationState redirected = _NavigationState();
      final PatchbayFlutterBridge redirectBridge = _bridge(
        adapter: _adapter(
          redirected,
          goSettings: () => redirected.move('login'),
        ),
      );
      addTearDown(redirectBridge.dispose);
      final PatchbayInvocation redirect = await _pumpUntilComplete(
        tester,
        redirectBridge.navigation!.go(
          destinationId: 'settings',
          revision: 1,
          timeout: const Duration(seconds: 1),
        ),
      );
      expect(redirect.rejection?.code, 'navigationRedirected');

      final _NavigationState unchanged = _NavigationState();
      final PatchbayFlutterBridge timeoutBridge = _bridge(
        adapter: _adapter(unchanged, goSettings: () {}, pushSettings: () {}),
      );
      addTearDown(timeoutBridge.dispose);
      final Future<PatchbayInvocation> timeoutPending = timeoutBridge
          .navigation!
          .push(
            destinationId: 'settings',
            revision: 1,
            timeout: const Duration(milliseconds: 20),
          );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      final PatchbayInvocation timeout = await _pumpUntilComplete(
        tester,
        timeoutPending,
      );
      expect(timeout.rejection?.code, 'navigationTimeout');

      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      final _NavigationState staleState = _NavigationState();
      final PatchbayFlutterBridge staleBridge = _bridge(
        adapter: _adapter(staleState, goSettings: () {}),
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (_) => gate.future,
        ),
      );
      addTearDown(staleBridge.dispose);
      final Future<PatchbayInvocation> stalePending = staleBridge.navigation!
          .go(
            destinationId: 'settings',
            revision: 1,
            timeout: const Duration(seconds: 1),
          );
      await tester.pump();
      staleState.move('profile');
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation stale = await _pumpUntilComplete(
        tester,
        stalePending,
      );
      expect(stale.rejection?.code, 'navigationRevisionStale');

      final PatchbayFlutterBridge background = _bridge(
        adapter: _adapter(_NavigationState(), goSettings: () {}),
        resumed: () => false,
      );
      addTearDown(background.dispose);
      final PatchbayInvocation backgroundResult = await background.navigation!
          .go(
            destinationId: 'settings',
            revision: 1,
            timeout: const Duration(seconds: 1),
          );
      expect(backgroundResult.rejection?.code, 'navigationLifecycleNotResumed');
    });

    testWidgets('duplicate destination IDs reject and requests serialize', (
      tester,
    ) async {
      final _NavigationState ambiguousState = _NavigationState();
      final PatchbayNavigationAdapter ambiguousAdapter =
          PatchbayNavigationAdapter(
            destinations: () => <PatchbayNavigationDestination>[
              PatchbayNavigationDestination(
                id: 'settings',
                go: () => ambiguousState.move('settings'),
              ),
              PatchbayNavigationDestination(
                id: 'settings',
                go: () => ambiguousState.move('settings'),
              ),
            ],
            current: ambiguousState.observe,
          );
      final PatchbayFlutterBridge ambiguous = _bridge(
        adapter: ambiguousAdapter,
      );
      addTearDown(ambiguous.dispose);
      final PatchbayInvocation catalog = await ambiguous.navigation!.catalog();
      expect(
        (catalog.payload['destinations']! as List<Object?>).single,
        containsPair('ambiguous', true),
      );
      final PatchbayInvocation rejected = await ambiguous.navigation!.go(
        destinationId: 'settings',
        revision: 1,
        timeout: const Duration(seconds: 1),
      );
      expect(rejected.rejection?.code, 'navigationDestinationAmbiguous');

      final _NavigationState serialState = _NavigationState();
      final Completer<void> releaseFirst = Completer<void>();
      var requests = 0;
      final PatchbayFlutterBridge serial = _bridge(
        adapter: _adapter(
          serialState,
          pushSettings: () async {
            requests += 1;
            await releaseFirst.future;
            serialState.move('settings');
          },
        ),
      );
      addTearDown(serial.dispose);
      final Future<PatchbayInvocation> first = serial.navigation!.push(
        destinationId: 'settings',
        revision: 1,
        timeout: const Duration(seconds: 1),
      );
      final Future<PatchbayInvocation> second = serial.navigation!.push(
        destinationId: 'settings',
        revision: 1,
        timeout: const Duration(seconds: 1),
      );
      await tester.pump();
      expect(requests, 1);
      releaseFirst.complete();
      expect(
        (await _pumpUntilComplete(tester, first)).admission,
        PatchbayAdmission.accepted,
      );
      expect(
        (await _pumpUntilComplete(tester, second)).rejection?.code,
        'navigationRevisionStale',
      );
      expect(requests, 1);
    });
  });

  group('ui.wait', () {
    testWidgets('waits for Semantics mounted, value, and unmounted', (
      tester,
    ) async {
      await tester.pumpWidget(_semanticsProbe(value: 'ready'));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      for (final PatchbayUiWaitRequest request in <PatchbayUiWaitRequest>[
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(seconds: 1),
          semanticsIdentifier: 'probe.status',
        ),
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsValue,
          timeout: const Duration(seconds: 1),
          semanticsIdentifier: 'probe.status',
          value: 'ready',
        ),
      ]) {
        final PatchbayInvocation result = await _pumpUntilComplete(
          tester,
          bridge.wait.wait(request),
        );
        expect(result.admission, PatchbayAdmission.accepted);
        expect(result.payload['source'], 'uiObserved');
      }

      final PatchbayInvocation tree = await _pumpUntilComplete(
        tester,
        bridge.semantics.snapshot(),
      );
      final int beforeTree = tree.payload['treeRevision']! as int;
      final Future<PatchbayInvocation> treeChanged = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.treeRevision,
          timeout: const Duration(seconds: 1),
          revision: beforeTree,
        ),
      );
      await tester.pumpWidget(_semanticsProbe(value: 'updated'));
      final PatchbayInvocation treeResult = await _pumpUntilComplete(
        tester,
        treeChanged,
      );
      expect(treeResult.payload['treeRevision'], greaterThan(beforeTree));

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayInvocation unmounted = await _pumpUntilComplete(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.semanticsUnmounted,
            timeout: const Duration(seconds: 1),
            semanticsIdentifier: 'probe.status',
          ),
        ),
      );
      expect(unmounted.admission, PatchbayAdmission.accepted);
      bridge.dispose();
    });

    testWidgets('wait rejects Semantics ambiguity and times out explicitly', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: <Widget>[
              Semantics(
                identifier: 'duplicate',
                container: true,
                child: const SizedBox(width: 10, height: 10),
              ),
              Semantics(
                identifier: 'duplicate',
                container: true,
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final PatchbayInvocation ambiguous = await _pumpUntilComplete(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.semanticsMounted,
            timeout: const Duration(seconds: 1),
            semanticsIdentifier: 'duplicate',
          ),
        ),
      );
      expect(ambiguous.rejection?.code, 'uiSemanticsTargetAmbiguous');

      final Future<PatchbayInvocation> timeoutPending = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(milliseconds: 20),
          semanticsIdentifier: 'missing',
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      final PatchbayInvocation timeout = await _pumpUntilComplete(
        tester,
        timeoutPending,
      );
      expect(timeout.rejection?.code, 'uiWaitTimeout');
      expect(timeout.rejection?.details['timeoutMs'], 20);
      bridge.dispose();
    });

    testWidgets('waits for destination and frame revisions', (tester) async {
      final _NavigationState state = _NavigationState();
      final PatchbayFlutterBridge bridge = _bridge(
        adapter: _adapter(state, goSettings: () {}),
      );
      addTearDown(bridge.dispose);
      final Future<PatchbayInvocation> destination = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.navigationDestination,
          timeout: const Duration(seconds: 1),
          destinationId: 'settings',
          revision: 1,
        ),
      );
      await tester.pump();
      state.move('settings');
      final PatchbayInvocation destinationResult = await _pumpUntilComplete(
        tester,
        destination,
      );
      expect(destinationResult.admission, PatchbayAdmission.accepted);
      expect(destinationResult.payload['navigationRevision'], 2);

      final int beforeFrame = bridge.frameRevision;
      final PatchbayInvocation frame = await _pumpUntilComplete(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.frameRevision,
            timeout: const Duration(seconds: 1),
            revision: beforeFrame,
          ),
        ),
      );
      expect(frame.payload['frameRevision'], greaterThan(beforeFrame));
    });

    testWidgets('wait rejects background lifecycle', (tester) async {
      final PatchbayFlutterBridge bridge = _bridge(resumed: () => false);
      addTearDown(bridge.dispose);
      final PatchbayInvocation result = await bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.frameRevision,
          timeout: const Duration(seconds: 1),
          revision: 0,
        ),
      );
      expect(result.rejection?.code, 'uiWaitLifecycleNotResumed');
    });
  });

  testWidgets('service host publishes stable navigation and wait commands', (
    tester,
  ) async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final _NavigationState state = _NavigationState();
    final PatchbayFlutterBridge bridge = _bridge(
      adapter: _adapter(state, goSettings: () => state.move('settings')),
    );
    addTearDown(bridge.dispose);
    PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.navigation.test',
      bridge: bridge,
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
    ).register();

    final ServiceExtensionResponse response =
        await handlers[PatchbayServiceHost.catalogMethod]!(
          PatchbayServiceHost.catalogMethod,
          const <String, String>{},
        );
    final Map<String, Object?> catalog = Map<String, Object?>.from(
      jsonDecode(response.result!) as Map<String, dynamic>,
    );
    final Set<Object?> names = (catalog['commands']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> command) => command['name'])
        .toSet();

    expect(
      names,
      containsAll(<String>[
        'navigation.catalog',
        'navigation.current',
        'navigation.go',
        'navigation.push',
        'navigation.back',
        'ui.wait',
      ]),
    );

    final ServiceExtensionResponse navigationCatalog =
        await handlers[PatchbayServiceHost.invokeMethod]!(
          PatchbayServiceHost.invokeMethod,
          const <String, String>{
            'command': 'navigation.catalog',
            'requestId': 'catalog-1',
            'args': '{}',
          },
        );
    final Map<String, Object?> envelope = Map<String, Object?>.from(
      jsonDecode(navigationCatalog.result!) as Map<String, dynamic>,
    );
    final Map<String, Object?> payload = Map<String, Object?>.from(
      envelope['payload']! as Map<String, dynamic>,
    );
    expect(
      PatchbayNavigationCatalogWire.fromJson(payload).destinations,
      isNotEmpty,
    );
  });
}

PatchbayFlutterBridge _bridge({
  PatchbayNavigationAdapter? adapter,
  PatchbayGateEvaluator? gates,
  bool Function()? resumed,
}) => PatchbayFlutterBridge(
  gates:
      gates ??
      PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
  registry: PatchbayUiRegistry(),
  navigationAdapter: adapter,
  isAppResumed: resumed ?? () => true,
);

PatchbayNavigationAdapter _adapter(
  _NavigationState state, {
  FutureOr<void> Function()? goSettings,
  FutureOr<void> Function()? pushSettings,
}) => PatchbayNavigationAdapter(
  destinations: () => <PatchbayNavigationDestination>[
    PatchbayNavigationDestination(id: 'home', go: () => state.move('home')),
    PatchbayNavigationDestination(
      id: 'settings',
      gateIds: const <String>{'debug.navigation'},
      go: goSettings,
      push: pushSettings,
    ),
    PatchbayNavigationDestination(id: 'login', go: () => state.move('login')),
    PatchbayNavigationDestination(
      id: 'profile',
      go: () => state.move('profile'),
    ),
  ],
  current: state.observe,
  back: () => state.move('home'),
);

Widget _semanticsProbe({required String value}) => MaterialApp(
  home: Semantics(
    identifier: 'probe.status',
    value: value,
    container: true,
    child: const SizedBox(width: 20, height: 20),
  ),
);

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 100 && !completed; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  if (!completed) throw StateError('operation did not complete in 100 frames');
  return pending;
}

final class _NavigationState {
  String destination = 'home';
  int revision = 1;

  void move(String next) {
    destination = next;
    revision += 1;
  }

  PatchbayNavigationObservation observe() => PatchbayNavigationObservation(
    revision: revision,
    destinationId: destination,
  );
}
