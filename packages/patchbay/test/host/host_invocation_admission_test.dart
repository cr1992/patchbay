import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  group('Patchbay host stdin provenance', () {
    const PatchbayCommandDescriptor bind = PatchbayCommandDescriptor(
      name: 'device.bind',
      summary: 'Bind a device using credentials.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.external,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'deviceId',
          type: PatchbayParameterType.string,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'password',
          type: PatchbayParameterType.string,
          sensitive: true,
        ),
        PatchbayParameterDescriptor(
          name: 'apiKey',
          type: PatchbayParameterType.string,
          sensitive: true,
        ),
      ],
    );
    const PatchbayCommandDescriptor uiWrite = PatchbayCommandDescriptor(
      name: 'ui.text.set',
      summary: 'Framework-served UI text write.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'text',
          type: PatchbayParameterType.string,
          required: true,
        ),
      ],
    );

    late List<Map<String, Object?>> forwarded;

    setUp(() => forwarded = <Map<String, Object?>>[]);

    PatchbayServiceHost hostWith(PatchbayCatalogSource catalog) =>
        PatchbayServiceHost(
          applicationId: 'dev.patchbay.test',
          registrar: (_, _) {},
          catalog: catalog,
          snapshot: () async => const <String, Object?>{},
          invoke: (_, Map<String, Object?> arguments, String requestId) async {
            forwarded.add(arguments);
            return PatchbayInvocation.accepted(requestId: requestId).toJson();
          },
        );

    PatchbayCatalogSource declaring(List<PatchbayCommandDescriptor> commands) =>
        () async => <String, Object?>{
          'commands': <Object?>[
            for (final PatchbayCommandDescriptor command in commands)
              command.toJson(),
          ],
        };

    test('meta key never reaches a consumer adapter', () async {
      final Map<String, Object?> arguments = <String, Object?>{
        'deviceId': 'device-1',
        'password': 'hunter2',
        'inputWasStdin': true,
      };
      final Map<String, Object?> result = await hostWith(
        declaring(<PatchbayCommandDescriptor>[bind]),
      ).dispatchInvoke('device.bind', arguments, 'req-1');

      expect(result['admission'], 'accepted');
      expect(forwarded.single, <String, Object?>{
        'deviceId': 'device-1',
        'password': 'hunter2',
      });
      expect(arguments, containsPair('inputWasStdin', true));
    });

    test('sensitive arguments without stdin provenance fail closed', () async {
      final Map<String, Object?> result =
          await hostWith(
            declaring(<PatchbayCommandDescriptor>[bind]),
          ).dispatchInvoke('device.bind', <String, Object?>{
            'deviceId': 'device-1',
            'password': 'hunter2',
            'apiKey': 'ak-1',
          }, 'req-2');

      final Map<String, Object?> rejection =
          result['rejection']! as Map<String, Object?>;
      expect(result['admission'], 'rejected');
      expect(rejection['code'], 'sensitiveInputRequiresStdin');
      expect(
        (rejection['details']! as Map<String, Object?>)['parameters'],
        <String>['apiKey', 'password'],
      );
      expect(forwarded, isEmpty);
    });

    test('only an exact true attests stdin provenance', () async {
      final Map<String, Object?> result =
          await hostWith(
            declaring(<PatchbayCommandDescriptor>[bind]),
          ).dispatchInvoke('device.bind', <String, Object?>{
            'password': 'hunter2',
            'inputWasStdin': 'true',
          }, 'req-3');

      expect(
        (result['rejection']! as Map<String, Object?>)['code'],
        'sensitiveInputRequiresStdin',
      );
      expect(forwarded, isEmpty);
    });

    test(
      'a sensitive parameter this request omits is not a violation',
      () async {
        final PatchbayServiceHost host = hostWith(
          declaring(<PatchbayCommandDescriptor>[bind]),
        );

        expect(
          (await host.dispatchInvoke('device.bind', <String, Object?>{
            'deviceId': 'device-1',
          }, 'req-4'))['admission'],
          'accepted',
        );
        expect(
          (await host.dispatchInvoke('device.bind', <String, Object?>{
            'deviceId': 'device-1',
            'password': null,
          }, 'req-5'))['admission'],
          'accepted',
        );
        expect(forwarded, hasLength(2));
      },
    );

    test('the Flutter UI plane keeps the flag for its own bridge', () async {
      await hostWith(
        declaring(<PatchbayCommandDescriptor>[uiWrite]),
      ).dispatchInvoke('ui.text.set', <String, Object?>{
        'text': 'secret',
        'inputWasStdin': true,
      }, 'req-6');

      expect(forwarded.single, containsPair('inputWasStdin', true));
    });

    test('an undeclared command also loses the meta key', () async {
      await hostWith(
        declaring(const <PatchbayCommandDescriptor>[]),
      ).dispatchInvoke('device.unknown', <String, Object?>{
        'value': 1,
        'inputWasStdin': true,
      }, 'req-7');

      expect(forwarded.single, <String, Object?>{'value': 1});
    });

    test('an unreadable catalog rejects instead of dispatching', () async {
      final Map<String, Object?> result =
          await hostWith(
            () async => throw StateError('catalog source is broken'),
          ).dispatchInvoke('device.bind', <String, Object?>{
            'password': 'hunter2',
          }, 'req-8');

      final Map<String, Object?> rejection =
          result['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'providerProtocolViolation');
      expect(
        (rejection['details']! as Map<String, Object?>)['reason'],
        'catalogUnavailable',
      );
      expect(forwarded, isEmpty);
    });

    test(
      'an argument-free legacy command survives an unreadable catalog',
      () async {
        final Map<String, Object?> result = await hostWith(
          () async => throw StateError('catalog source is broken'),
        ).dispatchInvoke('device.ping', const <String, Object?>{}, 'req-9');

        expect(result['admission'], 'accepted');
        expect(forwarded.single, isEmpty);
      },
    );
  });

  group('Patchbay invocation envelope', () {
    test('expresses admission without completion-like outer fields', () {
      final Map<String, Object?> json = PatchbayInvocation.accepted(
        requestId: 'req-1',
        payload: const <String, Object?>{'outcome': 'observed'},
      ).toJson();

      expect(json['admission'], 'accepted');
      expect(json.keys, isNot(contains(anyOf('ok', 'success', 'executed'))));
    });

    test('rejection keeps a stable code', () {
      final Map<String, Object?> json = PatchbayInvocation.rejected(
        requestId: 'req-2',
        rejection: const PatchbayRejection(
          code: 'startupNotReady',
          details: <String, Object?>{'stage': 'booting'},
        ),
      ).toJson();

      expect(json['admission'], 'rejected');
      expect(json['rejection'], <String, Object?>{
        'code': 'startupNotReady',
        'details': <String, Object?>{'stage': 'booting'},
      });
    });

    test('generated codec round-trips the stable null-bearing envelope', () {
      final Map<String, Object?> json = PatchbayInvocation.accepted(
        requestId: 'req-generated',
      ).toJson();

      expect(json, containsPair('notice', null));
      expect(json, containsPair('jobId', null));
      expect(json, containsPair('rejection', null));
      expect(PatchbayInvocationWire.fromJson(json).toJson(), json);
    });

    test('generated codec rejects values outside the JSON contract', () {
      expect(
        () => PatchbayInvocation.accepted(
          requestId: 'req-invalid-json',
          payload: <String, Object?>{'timestamp': DateTime.utc(2026)},
        ).toJson(),
        throwsFormatException,
      );
    });
  });

  group('Patchbay gates', () {
    test('base rejection prevents consumer gate evaluation', () async {
      var consumerCalls = 0;
      final PatchbayGateEvaluator gates = PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.reject(code: 'hostDisabled'),
        consumerGate: (String _) {
          consumerCalls += 1;
          return const PatchbayGateDecision.allow();
        },
      );

      final PatchbayGateRejection? result = await gates.evaluate(<String>{
        'consumer.ready',
      });

      expect(result?.gateId, 'patchbay.base');
      expect(result?.code, 'hostDisabled');
      expect(consumerCalls, 0);
    });

    test(
      'consumer gates are de-duplicated and evaluated deterministically',
      () async {
        final List<String> calls = <String>[];
        final PatchbayGateEvaluator gates = PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String gateId) {
            calls.add(gateId);
            return gateId == 'b.ready'
                ? const PatchbayGateDecision.reject(code: 'notReady')
                : const PatchbayGateDecision.allow();
          },
        );

        final PatchbayGateRejection? result = await gates.evaluate(<String>[
          'b.ready',
          'a.enabled',
          'b.ready',
        ]);

        expect(calls, <String>['a.enabled', 'b.ready']);
        expect(result?.gateId, 'b.ready');
        expect(result?.code, 'notReady');
      },
    );
  });

  test('UI descriptor serializes dynamic operations and their gates', () {
    const PatchbayUiTargetDescriptor descriptor = PatchbayUiTargetDescriptor(
      id: 'login.phone',
      generation: 3,
      kind: PatchbayUiTargetKind.text,
      mounted: true,
      ambiguous: false,
      operations: <PatchbayUiOperation>{PatchbayUiOperation.textEnter},
      operationGates: <PatchbayUiOperation, Set<String>>{
        PatchbayUiOperation.textEnter: <String>{'app.ready'},
      },
      sensitivePolicy: PatchbaySensitivePolicy.public,
      sideEffect: PatchbaySideEffect.appState,
    );

    expect(descriptor.toJson(), <String, Object?>{
      'id': 'login.phone',
      'generation': 3,
      'kind': 'text',
      'mounted': true,
      'ambiguous': false,
      'operations': <String>['text.enter'],
      'operationGates': <String, Object?>{
        'text.enter': <String>['app.ready'],
      },
      'sensitivePolicy': 'public',
      'sideEffect': 'appState',
      'factSources': <String>['uiObserved'],
    });
  });

  test(
    'domain command descriptor is a complete machine-readable catalog row',
    () {
      const PatchbayCommandDescriptor descriptor = PatchbayCommandDescriptor(
        name: 'device.select',
        summary: 'Select the shared debug device.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        gates: <String>{'consumer.ready'},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'deviceId',
            type: PatchbayParameterType.string,
            required: true,
          ),
        ],
      );

      expect(descriptor.toJson(), containsPair('name', 'device.select'));
      expect(
        descriptor.toJson(),
        containsPair('factSources', <String>['appRecorded']),
      );
      expect(
        descriptor.toJson()['parameters'],
        contains(containsPair('name', 'deviceId')),
      );
    },
  );
}
