import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  group('PatchbayCommandRegistry', () {
    test(
      'one registration drives descriptor, decoder, gate and handler',
      () async {
        final List<String> phases = <String>[];
        final PatchbayCommandRegistry registry = PatchbayCommandRegistry(
          <PatchbayCommandRegistration<Object?>>[
            PatchbayCommandRegistration<int>(
              descriptor: _descriptor('patchbay.echo'),
              decode: (arguments) {
                phases.add('decode');
                final Object? value = arguments['value'];
                if (value is! int) throw const FormatException('value');
                return value;
              },
              gate: (request, requestId) {
                phases.add('gate');
                return null;
              },
              handle: (request, requestId) {
                phases.add('handle');
                return PatchbayInvocation.accepted(
                  requestId: requestId,
                  payload: <String, Object?>{'value': request},
                ).toJson();
              },
            ),
          ],
        );

        expect(registry.descriptors.single.name, 'patchbay.echo');
        expect(registry.handles('patchbay.echo'), isTrue);
        expect(
          await registry.dispatch('patchbay.echo', <String, Object?>{
            'value': 7,
          }, 'request-1'),
          containsPair('payload', <String, Object?>{'value': 7}),
        );
        expect(phases, <String>['decode', 'gate', 'handle']);
      },
    );

    test('gate rejection stops the registered handler', () async {
      var handled = false;
      final PatchbayCommandRegistry registry = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _descriptor('patchbay.gated'),
            decode: (arguments) => arguments,
            gate: (_, requestId) => PatchbayInvocation.rejected(
              requestId: requestId,
              rejection: const PatchbayRejection(code: 'gateClosed'),
            ).toJson(),
            handle: (_, requestId) {
              handled = true;
              return PatchbayInvocation.accepted(requestId: requestId).toJson();
            },
          ),
        ],
      );

      final Map<String, Object?> response = await registry.dispatch(
        'patchbay.gated',
        const <String, Object?>{},
        'request-2',
      );

      expect(handled, isFalse);
      expect(response['rejection'], containsPair('code', 'gateClosed'));
    });

    test('rejects duplicate descriptor names at composition time', () {
      PatchbayCommandRegistration<Map<String, Object?>> registration() =>
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _descriptor('patchbay.same'),
            decode: (arguments) => arguments,
            handle: (_, requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          );

      expect(
        () => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
          registration(),
          registration(),
        ]),
        throwsArgumentError,
      );
    });

    test(
      'unavailable protocol commands stay reserved but unpublished',
      () async {
        final PatchbayCommandRegistry registry =
            PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
              PatchbayCommandRegistration<Map<String, Object?>>(
                descriptor: _descriptor('patchbay.optional'),
                available: false,
                decode: (arguments) => arguments,
                handle: (_, requestId) =>
                    PatchbayInvocation.accepted(requestId: requestId).toJson(),
              ),
            ]);

        expect(registry.descriptors, isEmpty);
        expect(registry.handles('patchbay.optional'), isTrue);
        expect(
          (await registry.dispatch(
            'patchbay.optional',
            const <String, Object?>{},
            'request-3',
          ))['rejection'],
          containsPair('code', 'commandNotRegistered'),
        );
      },
    );
  });

  test(
    'service host composes and dispatches registry before external fallback',
    () async {
      final List<String> externalCalls = <String>[];
      final PatchbayCommandRegistry registry =
          PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
            PatchbayCommandRegistration<Map<String, Object?>>(
              descriptor: _descriptor('patchbay.registered'),
              decode: (arguments) => arguments,
              handle: (arguments, requestId) => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: arguments,
              ).toJson(),
            ),
          ]);
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'registry-test',
        registry: registry,
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'device.status'},
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (command, arguments, requestId) async {
          externalCalls.add(command);
          return PatchbayInvocation.accepted(
            requestId: requestId,
            payload: <String, Object?>{'external': command},
          ).toJson();
        },
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();
      final List<Object?> commands = catalog['commands']! as List<Object?>;
      expect(
        commands.map((entry) => (entry! as Map<Object?, Object?>)['name']),
        <String>['patchbay.registered', 'device.status'],
      );
      expect(
        (catalog['catalogDigest']! as Map<Object?, Object?>)['covers'],
        <String>['commands'],
      );

      final Map<String, Object?> registered = await host.dispatchInvoke(
        'patchbay.registered',
        <String, Object?>{'value': true},
        'registered-request',
      );
      final Map<String, Object?> external = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'external-request',
      );

      expect(registered['payload'], <String, Object?>{'value': true});
      expect(external['payload'], <String, Object?>{
        'external': 'device.status',
      });
      expect(externalCalls, <String>['device.status']);
    },
  );

  test(
    'service host validates accepted payload and exposes per-command mode',
    () async {
      final PatchbayCommandRegistry registry = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: PatchbayCommandDescriptor(
              name: 'patchbay.typed',
              summary: 'Typed command.',
              plane: PatchbayPlane.domain,
              mode: PatchbayCommandMode.immediate,
              sideEffect: PatchbaySideEffect.none,
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.appRecorded,
              },
              responseSchema: const PatchbayResponseSchema(
                accepted: PatchbayResponseValueSchema(
                  type: PatchbayResponseType.object,
                  properties: <String, PatchbayResponseValueSchema>{
                    'session': PatchbayResponseValueSchema(
                      type: PatchbayResponseType.string,
                    ),
                  },
                  required: <String>{'session'},
                ),
              ),
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) => PatchbayInvocation.accepted(
              requestId: requestId,
              payload: const <String, Object?>{'session': null},
            ).toJson(),
          ),
        ],
      );
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'schema-test',
        registry: registry,
        catalog: () async => const <String, Object?>{},
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'patchbay.typed',
        const <String, Object?>{},
        'schema-request',
      );

      expect(host.features, contains(PatchbayFeature.responseSchemas));
      expect(response['schemaMode'], 'validated');
      expect(response['admission'], 'rejected');
      final Map<Object?, Object?> rejection =
          response['rejection']! as Map<Object?, Object?>;
      expect(rejection['code'], 'providerProtocolViolation');
      final Map<Object?, Object?> details =
          rejection['details']! as Map<Object?, Object?>;
      expect(details['reason'], 'unexpectedNull');
      expect(details['field'], r'$.payload.session');
    },
  );

  test(
    'first direct no-arg invocation discovers an external response schema',
    () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'external-schema-test',
        registrar: (_, _) {},
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'device.status',
              'sideEffect': 'external',
              'retryPolicy': <String, Object?>{
                'maxAttempts': 2,
                'backoffMs': 0,
              },
              'responseSchema': <String, Object?>{
                'accepted': <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{
                    'online': <String, Object?>{'type': 'boolean'},
                  },
                  'required': <String>['online'],
                  'additionalProperties': false,
                },
              },
            },
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{'online': 'yes'},
        ).toJson(),
      );

      final Map<String, Object?> direct = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'same-request',
      );
      final ServiceExtensionResponse response = await host.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': 'device.status',
          'args': '{}',
          'requestId': 'same-request',
        },
      );
      final Map<String, Object?> vm = Map<String, Object?>.from(
        jsonDecode(response.result!) as Map<String, dynamic>,
      );

      expect(vm, direct);
      expect(direct['schemaMode'], 'validated');
      expect(
        (direct['rejection']! as Map<Object?, Object?>)['code'],
        'providerProtocolViolation',
      );
    },
  );

  test(
    'external schema registration fails closed before catalog publication',
    () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'invalid-schema-test',
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'device.invalid',
              'responseSchema': <String, Object?>{
                'accepted': <String, Object?>{
                  'type': 'object',
                  'properties': const <String, Object?>{},
                  'required': const <String>[],
                  // additionalProperties is deliberately absent.
                },
              },
            },
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();
      expect(catalog.containsKey('commands'), isFalse);
      final Map<Object?, Object?> rejection =
          catalog['rejection']! as Map<Object?, Object?>;
      final Map<Object?, Object?> details =
          rejection['details']! as Map<Object?, Object?>;
      final List<Object?> violations = details['violations']! as List<Object?>;
      expect(
        violations.single,
        containsPair('reason', 'invalidResponseSchema'),
      );
      final Map<String, Object?> direct = await host.dispatchInvoke(
        'device.invalid',
        const <String, Object?>{},
        'invalid-direct',
      );
      final Map<Object?, Object?> directRejection =
          direct['rejection']! as Map<Object?, Object?>;
      expect(directRejection['code'], 'providerProtocolViolation');
      expect(
        (directRejection['details']! as Map<Object?, Object?>)['reason'],
        'catalogUnavailable',
      );
    },
  );
}

PatchbayCommandDescriptor _descriptor(String name) => PatchbayCommandDescriptor(
  name: name,
  summary: 'Registry test command.',
  plane: PatchbayPlane.domain,
  mode: PatchbayCommandMode.immediate,
  sideEffect: PatchbaySideEffect.none,
  factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
  parameters: const <PatchbayParameterDescriptor>[
    PatchbayParameterDescriptor(
      name: 'value',
      type: PatchbayParameterType.json,
    ),
  ],
);
