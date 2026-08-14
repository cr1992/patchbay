import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  group('ui.inspect on the real binding', () {
    // The flag under test is global engine state; a leaked `true` would make
    // every later widget test render the inspector overlay.
    setUp(_restoreBindingFlag);
    tearDown(_restoreBindingFlag);

    testWidgets(
      'enabling mounts the on-device inspector, disabling removes it',
      (WidgetTester tester) async {
        final PatchbayInspectBridge inspect = PatchbayInspectBridge(
          gates: _allowGates,
        );
        addTearDown(inspect.dispose);
        await tester.pumpWidget(const MaterialApp(home: Text('home')));
        expect(find.byType(WidgetInspector), findsNothing);

        final Map<String, Object?> enabled = (await inspect.select(
          request: const PatchbayInspectSelectRequestWire(
            enabled: true,
            ttlMs: null,
          ),
          requestId: 'inspect-on',
        )).toJson();
        await tester.pump();

        expect(enabled['admission'], 'accepted', reason: jsonEncode(enabled));
        final Map<String, Object?> payload = _payload(enabled);
        expect(payload['outcome'], 'applied');
        // Not `uiObserved`: writing the flag is the App's own record, not proof
        // that a frame carrying the overlay was seen.
        expect(payload['source'], 'appRecorded');
        expect(payload['selectMode'], isTrue);
        expect(payload['previousSelectMode'], isFalse);
        expect(payload['restoresTo'], isFalse);
        expect(payload['managed'], isTrue);
        expect(payload['leaseMs'], const Duration(minutes: 5).inMilliseconds);
        // The overlay itself, not just the flag: this is what "圈看 widget" needs.
        expect(find.byType(WidgetInspector), findsOneWidget);

        final Map<String, Object?> disabled = (await inspect.select(
          request: const PatchbayInspectSelectRequestWire(
            enabled: false,
            ttlMs: null,
          ),
          requestId: 'inspect-off',
        )).toJson();
        await tester.pump();

        expect(_payload(disabled)['selectMode'], isFalse);
        expect(_payload(disabled)['managed'], isFalse);
        expect(_payload(disabled)['lastRelease'], 'explicitOff');
        expect(find.byType(WidgetInspector), findsNothing);
      },
    );

    testWidgets('an expired lease puts the switch back without a command', (
      WidgetTester tester,
    ) async {
      final PatchbayInspectBridge inspect = PatchbayInspectBridge(
        gates: _allowGates,
        policy: const PatchbayInspectPolicy(defaultLease: Duration(minutes: 1)),
      );
      addTearDown(inspect.dispose);
      await tester.pumpWidget(const MaterialApp(home: Text('home')));

      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: true,
          ttlMs: 30000,
        ),
        requestId: 'inspect-on',
      );
      await tester.pump();
      expect(find.byType(WidgetInspector), findsOneWidget);

      // Nothing sends a command here; only the clock moves. That is the whole
      // point of the lease: a session that stopped talking must not leave the
      // device swallowing every tap.
      await tester.pump(const Duration(seconds: 31));
      expect(find.byType(WidgetInspector), findsNothing);
      expect(inspect.managed, isFalse);

      final Map<String, Object?> status = _payload(
        (await inspect.status(requestId: 'inspect-status')).toJson(),
      );
      expect(status['selectMode'], isFalse);
      expect(status['managed'], isFalse);
      expect(status['lastRelease'], 'leaseExpired');
      expect(status.containsKey('leaseMs'), isFalse);
    });
  });

  group('ui.inspect bridge rules', () {
    testWidgets('a renewal keeps the original baseline and extends the lease', (
      WidgetTester tester,
    ) async {
      final _FakeInspectorSurface surface = _FakeInspectorSurface();
      final PatchbayInspectBridge inspect = PatchbayInspectBridge(
        gates: _allowGates,
        surface: surface,
      );
      addTearDown(inspect.dispose);

      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: true,
          ttlMs: 20000,
        ),
        requestId: 'inspect-on',
      );
      await tester.pump(const Duration(seconds: 15));
      final Map<String, Object?> renewed = _payload(
        (await inspect.select(
          request: const PatchbayInspectSelectRequestWire(
            enabled: true,
            ttlMs: 20000,
          ),
          requestId: 'inspect-renew',
        )).toJson(),
      );
      // The switch Patchbay itself installed must not become the baseline.
      expect(renewed['previousSelectMode'], isTrue);
      expect(renewed['restoresTo'], isFalse);

      await tester.pump(const Duration(seconds: 15));
      expect(surface.selectMode, isTrue, reason: 'the renewal moved the clock');
      await tester.pump(const Duration(seconds: 6));
      expect(surface.selectMode, isFalse);
    });

    testWidgets('an expiring lease does not undo a value someone else set', (
      WidgetTester tester,
    ) async {
      final _FakeInspectorSurface surface = _FakeInspectorSurface();
      final PatchbayInspectBridge inspect = PatchbayInspectBridge(
        gates: _allowGates,
        surface: surface,
      );
      addTearDown(inspect.dispose);

      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: true,
          ttlMs: 10000,
        ),
        requestId: 'inspect-on',
      );
      // DevTools writes the same flag. Turning it off here would be Patchbay
      // reaching over and undoing somebody else's switch.
      surface.selectMode = false;
      await tester.pump(const Duration(seconds: 11));
      expect(surface.selectMode, isFalse);
      expect(surface.writes, <bool>[true, false]);
      expect(inspect.managed, isFalse);
    });

    testWidgets('explicit off wins over a baseline that was already on', (
      WidgetTester tester,
    ) async {
      final _FakeInspectorSurface surface = _FakeInspectorSurface(
        selectMode: true,
      );
      final PatchbayInspectBridge inspect = PatchbayInspectBridge(
        gates: _allowGates,
        surface: surface,
      );
      addTearDown(inspect.dispose);

      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: true,
          ttlMs: 10000,
        ),
        requestId: 'inspect-on',
      );
      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: false,
          ttlMs: null,
        ),
        requestId: 'inspect-off',
      );
      expect(surface.selectMode, isFalse);

      // The lease timer must be gone, not merely ignored: firing it later would
      // restore the baseline over an operator's explicit off.
      await tester.pump(const Duration(seconds: 11));
      expect(surface.selectMode, isFalse);
    });

    test('a lease policy that cannot hold is refused at construction', () {
      expect(
        () => PatchbayInspectBridge(
          gates: _allowGates,
          // A default the ceiling would immediately refuse is a policy that can
          // never grant its own default lease.
          policy: const PatchbayInspectPolicy(
            defaultLease: Duration(minutes: 5),
            maxLease: Duration(minutes: 2),
          ),
          surface: _FakeInspectorSurface(),
        ),
        throwsArgumentError,
      );
    });

    test('dispose releases the switch a torn-down host installed', () async {
      final _FakeInspectorSurface surface = _FakeInspectorSurface();
      final PatchbayInspectBridge inspect = PatchbayInspectBridge(
        gates: _allowGates,
        surface: surface,
      );
      await inspect.select(
        request: const PatchbayInspectSelectRequestWire(
          enabled: true,
          ttlMs: 10000,
        ),
        requestId: 'inspect-on',
      );
      inspect.dispose();
      expect(surface.selectMode, isFalse);
    });

    test(
      'a build that cannot render the overlay is refused, not answered',
      () async {
        for (final PatchbayInspectUnavailableWire reason
            in PatchbayInspectUnavailableWire.values) {
          final PatchbayInspectBridge inspect = PatchbayInspectBridge(
            gates: _allowGates,
            surface: _FakeInspectorSurface(unavailableReason: reason),
          );
          for (final Map<String, Object?> response in <Map<String, Object?>>[
            (await inspect.select(
              request: const PatchbayInspectSelectRequestWire(
                enabled: true,
                ttlMs: null,
              ),
              requestId: 'inspect-on',
            )).toJson(),
            (await inspect.status(requestId: 'inspect-status')).toJson(),
          ]) {
            expect(response['admission'], 'rejected', reason: '$reason');
            final Map<String, Object?> rejection = _rejection(response);
            expect(rejection['code'], 'inspectorUnavailable');
            expect(
              (rejection['details']! as Map<String, Object?>)['reason'],
              reason.name,
            );
          }
        }
      },
    );

    test(
      'a refused build writes nothing and consults no consumer gate',
      () async {
        final _FakeInspectorSurface surface = _FakeInspectorSurface(
          unavailableReason: PatchbayInspectUnavailableWire.notDebugBuild,
        );
        final List<String> asked = <String>[];
        final PatchbayInspectBridge inspect = PatchbayInspectBridge(
          gates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String gateId) {
              asked.add(gateId);
              return const PatchbayGateDecision.allow();
            },
          ),
          policy: const PatchbayInspectPolicy(gates: <String>{'debug.ready'}),
          surface: surface,
        );
        await inspect.select(
          request: const PatchbayInspectSelectRequestWire(
            enabled: true,
            ttlMs: null,
          ),
          requestId: 'inspect-on',
        );
        expect(surface.writes, isEmpty);
        // A consumer gate may do real work; a build that could never render the
        // overlay is refused before anyone is asked for permission.
        expect(asked, isEmpty);
      },
    );

    test(
      'availability lost while a gate awaited is refused, not applied',
      () async {
        final _FakeInspectorSurface surface = _FakeInspectorSurface();
        final PatchbayInspectBridge inspect = PatchbayInspectBridge(
          gates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (_) async {
              // A consumer that injects its own inspector can set this while the
              // gate is still awaiting.
              surface.unavailableReason =
                  PatchbayInspectUnavailableWire.rootInspectorExcluded;
              return const PatchbayGateDecision.allow();
            },
          ),
          policy: const PatchbayInspectPolicy(gates: <String>{'debug.ready'}),
          surface: surface,
        );
        addTearDown(inspect.dispose);

        final Map<String, Object?> response = (await inspect.select(
          request: const PatchbayInspectSelectRequestWire(
            enabled: true,
            ttlMs: null,
          ),
          requestId: 'inspect-on',
        )).toJson();
        expect(_rejection(response)['code'], 'inspectorUnavailable');
        expect(surface.writes, isEmpty);
      },
    );

    test(
      'ttlMs is refused with an off, and above the policy ceiling',
      () async {
        final PatchbayInspectBridge inspect = PatchbayInspectBridge(
          gates: _allowGates,
          surface: _FakeInspectorSurface(),
          policy: const PatchbayInspectPolicy(
            defaultLease: Duration(minutes: 1),
            maxLease: Duration(minutes: 2),
          ),
        );
        addTearDown(inspect.dispose);

        final Map<String, Object?> withOff = _rejection(
          (await inspect.select(
            request: const PatchbayInspectSelectRequestWire(
              enabled: false,
              ttlMs: 1000,
            ),
            requestId: 'inspect-off',
          )).toJson(),
        );
        expect(withOff['code'], 'invalidInspectArguments');
        expect(
          (withOff['details']! as Map<String, Object?>)['reason'],
          contains('enabled is true'),
        );

        final Map<String, Object?> tooLong = _rejection(
          (await inspect.select(
            request: const PatchbayInspectSelectRequestWire(
              enabled: true,
              ttlMs: 120001,
            ),
            requestId: 'inspect-on',
          )).toJson(),
        );
        expect(tooLong['code'], 'invalidInspectArguments');
        expect(
          (tooLong['details']! as Map<String, Object?>)['maxTtlMs'],
          120000,
        );
      },
    );

    test(
      'a closed consumer gate refuses the write and leaves the flag',
      () async {
        final _FakeInspectorSurface surface = _FakeInspectorSurface();
        final PatchbayInspectBridge inspect = PatchbayInspectBridge(
          gates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String gateId) =>
                const PatchbayGateDecision.reject(code: 'inspectNotAllowed'),
          ),
          policy: const PatchbayInspectPolicy(gates: <String>{'debug.ready'}),
          surface: surface,
        );
        addTearDown(inspect.dispose);

        final Map<String, Object?> rejection = _rejection(
          (await inspect.select(
            request: const PatchbayInspectSelectRequestWire(
              enabled: true,
              ttlMs: null,
            ),
            requestId: 'inspect-on',
          )).toJson(),
        );
        expect(rejection['code'], 'inspectNotAllowed');
        expect(
          (rejection['details']! as Map<String, Object?>)['gateId'],
          'debug.ready',
        );
        expect(surface.writes, isEmpty);
      },
    );
  });

  group('ui.inspect through the service host', () {
    test('the commands are absent until the consumer opts in', () async {
      final Map<String, ServiceExtensionHandler> handlers = _register(
        _bridge(inspectPolicy: null),
      );
      expect(
        await _catalogNames(handlers),
        isNot(contains('ui.inspect.select')),
      );
      final Map<String, Object?> response = await _invoke(
        handlers,
        'ui.inspect.select',
        <String, Object?>{'enabled': true},
      );
      expect(_rejection(response)['code'], 'commandNotRegistered');
    });

    test('the descriptors declare the whole contract', () async {
      final Map<String, ServiceExtensionHandler> handlers = _register(
        _bridge(
          inspectPolicy: const PatchbayInspectPolicy(
            gates: <String>{'debug.ready'},
            defaultLease: Duration(minutes: 3),
          ),
        ),
      );
      final Map<String, Object?> catalog = await _call(
        handlers,
        PatchbayServiceHost.catalogMethod,
      );
      final Map<String, Object?> select = _descriptor(
        catalog,
        'ui.inspect.select',
      );
      expect(select['plane'], 'flutterUi');
      expect(select['mode'], 'immediate');
      expect(select['sideEffect'], 'appState');
      expect(select['factSources'], <String>['appRecorded']);
      expect(select['gates'], <String>['debug.ready']);
      expect(select['parameters'], <Object?>[
        containsPair('name', 'enabled'),
        allOf(
          containsPair('name', 'ttlMs'),
          // The declared default is the lease this consumer actually grants.
          containsPair('default', const Duration(minutes: 3).inMilliseconds),
        ),
      ]);

      final Map<String, Object?> status = _descriptor(
        catalog,
        'ui.inspect.status',
      );
      expect(status['mode'], 'readOnly');
      expect(status['sideEffect'], 'none');
      expect(status['factSources'], <String>['appRecorded']);
      expect(status['parameters'], isEmpty);
    });

    test('the host names the argument a request got wrong', () async {
      final Map<String, ServiceExtensionHandler> handlers = _register(
        _bridge(inspectPolicy: const PatchbayInspectPolicy()),
      );

      final Map<String, Object?> missing = await _invoke(
        handlers,
        'ui.inspect.select',
        const <String, Object?>{},
      );
      expect(_rejection(missing)['code'], 'invalidUiArguments');
      expect(
        (_rejection(missing)['details']! as Map<String, Object?>)['missing'],
        <String>['enabled'],
      );

      final Map<String, Object?> unexpected = await _invoke(
        handlers,
        'ui.inspect.select',
        const <String, Object?>{'enabled': true, 'forever': true},
      );
      expect(
        (_rejection(unexpected)['details']!
            as Map<String, Object?>)['unexpected'],
        <String>['forever'],
      );

      final Map<String, Object?> statusArgs = await _invoke(
        handlers,
        'ui.inspect.status',
        const <String, Object?>{'enabled': true},
      );
      expect(_rejection(statusArgs)['code'], 'invalidUiArguments');
    });

    test('an accepted select answers a decodable state', () async {
      final Map<String, ServiceExtensionHandler> handlers = _register(
        _bridge(
          inspectPolicy: const PatchbayInspectPolicy(),
          surface: _FakeInspectorSurface(),
        ),
      );
      final Map<String, Object?> response = await _invoke(
        handlers,
        'ui.inspect.select',
        const <String, Object?>{'enabled': true, 'ttlMs': 60000},
      );
      expect(response['admission'], 'accepted', reason: jsonEncode(response));
      // Decoding through the generated codec is the check that the payload is
      // the declared shape rather than a lookalike map.
      final PatchbayInspectStateWire state = PatchbayInspectStateWire.fromJson(
        _payload(response),
      );
      expect(state.outcome, 'applied');
      expect(state.source, PatchbayFactSourceWire.appRecorded);
      expect(state.selectMode, isTrue);
      expect(state.leaseMs, 60000);
      expect(state.leaseRemainingMs, greaterThan(0));

      final Map<String, Object?> off = await _invoke(
        handlers,
        'ui.inspect.select',
        const <String, Object?>{'enabled': false},
      );
      expect(
        PatchbayInspectStateWire.fromJson(_payload(off)).lastRelease,
        PatchbayInspectReleaseWire.explicitOff,
      );
    });
  });
}

final PatchbayGateEvaluator _allowGates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

void _restoreBindingFlag() {
  WidgetsBinding.instance.debugShowWidgetInspectorOverride = false;
}

PatchbayFlutterBridge _bridge({
  required PatchbayInspectPolicy? inspectPolicy,
  PatchbayInspectorSurface? surface,
}) => PatchbayFlutterBridge(
  registry: PatchbayUiRegistry(),
  gates: _allowGates,
  inspectPolicy: inspectPolicy,
  inspectorSurface: surface,
);

Map<String, ServiceExtensionHandler> _register(PatchbayFlutterBridge bridge) {
  final Map<String, ServiceExtensionHandler> handlers =
      <String, ServiceExtensionHandler>{};
  PatchbayFlutterServiceHost(
    applicationId: 'dev.patchbay.inspect.test',
    bridge: bridge,
    registrar: (String method, ServiceExtensionHandler handler) {
      handlers[method] = handler;
    },
  ).register();
  return handlers;
}

Future<Map<String, Object?>> _call(
  Map<String, ServiceExtensionHandler> handlers,
  String method, [
  Map<String, String> parameters = const <String, String>{},
]) async {
  final ServiceExtensionResponse response = await handlers[method]!(
    method,
    parameters,
  );
  return Map<String, Object?>.from(
    jsonDecode(response.result!) as Map<String, dynamic>,
  );
}

Future<Map<String, Object?>> _invoke(
  Map<String, ServiceExtensionHandler> handlers,
  String command,
  Map<String, Object?> arguments,
) => _call(handlers, PatchbayServiceHost.invokeMethod, <String, String>{
  'command': command,
  'args': jsonEncode(arguments),
  'requestId': 'inspect-request',
});

Future<Set<String>> _catalogNames(
  Map<String, ServiceExtensionHandler> handlers,
) async {
  final Map<String, Object?> catalog = await _call(
    handlers,
    PatchbayServiceHost.catalogMethod,
  );
  return <String>{
    for (final Object? row in catalog['commands']! as List<Object?>)
      (row! as Map<String, Object?>)['name']! as String,
  };
}

Map<String, Object?> _descriptor(Map<String, Object?> catalog, String name) =>
    (catalog['commands']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> row) => row['name'] == name);

Map<String, Object?> _payload(Map<String, Object?> response) =>
    Map<String, Object?>.from(response['payload']! as Map<String, Object?>);

Map<String, Object?> _rejection(Map<String, Object?> response) =>
    Map<String, Object?>.from(response['rejection']! as Map<String, Object?>);

/// A surface with no build mode and no binding, so the rules can be tested.
final class _FakeInspectorSurface implements PatchbayInspectorSurface {
  _FakeInspectorSurface({bool selectMode = false, this.unavailableReason})
    : _selectMode = selectMode;

  bool _selectMode;

  /// Every write the bridge performed, in order — including the ones it must
  /// not have performed.
  final List<bool> writes = <bool>[];

  @override
  PatchbayInspectUnavailableWire? unavailableReason;

  @override
  bool get selectionOnTap => true;

  @override
  bool get selectMode => _selectMode;

  @override
  set selectMode(bool value) {
    writes.add(value);
    _selectMode = value;
  }
}
