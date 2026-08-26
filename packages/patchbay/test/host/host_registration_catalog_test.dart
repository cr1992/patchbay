import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test('service host registers fixed RPCs and serves identity', () async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      appInstanceId: 'instance-1',
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
      catalog: () async => <String, Object?>{'commands': const <Object?>[]},
      snapshot: () async => <String, Object?>{
        'source': PatchbayFactSource.appRecorded.name,
      },
      invoke: (command, arguments, requestId) async =>
          PatchbayInvocation.rejected(
            requestId: requestId,
            rejection: PatchbayRejection(
              code: 'notRegistered',
              details: <String, Object?>{
                'command': command,
                'argumentCount': arguments.length,
              },
            ),
          ).toJson(),
    )..register();
    host.register();

    expect(handlers.keys, <String>{
      PatchbayServiceHost.identityMethod,
      PatchbayServiceHost.catalogMethod,
      PatchbayServiceHost.snapshotMethod,
      PatchbayServiceHost.invokeMethod,
      PatchbayServiceHost.cancelInvocationMethod,
    });
    final ServiceExtensionResponse response =
        await handlers[PatchbayServiceHost.identityMethod]!(
          PatchbayServiceHost.identityMethod,
          const <String, String>{},
        );
    expect(
      jsonDecode(response.result!),
      containsPair('appInstanceId', 'instance-1'),
    );
  });

  test('service host serves a fixed snapshot RPC', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      appInstanceId: 'instance-2',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => <String, Object?>{
        'source': PatchbayFactSource.appRecorded.name,
      },
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    final ServiceExtensionResponse response = await host.handleSnapshot(
      PatchbayServiceHost.snapshotMethod,
      const <String, String>{},
    );

    expect(
      jsonDecode(response.result!),
      containsPair('source', PatchbayFactSource.appRecorded.name),
    );
  });

  test('service host owns schemaVersion in catalog and snapshot', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => <String, Object?>{
        'schemaVersion': 999,
        'commands': const <Object?>[],
      },
      snapshot: () async => <String, Object?>{'schemaVersion': 999},
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    expect(
      await host.dispatchCatalog(),
      containsPair('schemaVersion', PatchbayServiceHost.schemaVersion),
    );
    expect(
      await host.dispatchSnapshot(),
      containsPair('schemaVersion', PatchbayServiceHost.schemaVersion),
    );
  });

  group('a catalog that violates the protocol', () {
    late List<String> invoked;

    PatchbayServiceHost hostWith(PatchbayCatalogSource catalog) {
      invoked = <String>[];
      return PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        registrar: (_, _) {},
        catalog: catalog,
        snapshot: () async => const <String, Object?>{},
        invoke: (String command, _, String requestId) async {
          invoked.add(command);
          return PatchbayInvocation.accepted(requestId: requestId).toJson();
        },
      );
    }

    PatchbayCatalogSource declaring(List<Object?> commands) =>
        () async => <String, Object?>{'commands': commands};

    Map<String, Object?> rejectionOf(Map<String, Object?> response) =>
        response['rejection']! as Map<String, Object?>;

    Map<String, Object?> detailsOf(Map<String, Object?> response) =>
        rejectionOf(response)['details']! as Map<String, Object?>;

    test('names the kebab-cased command instead of throwing', () async {
      final Map<String, Object?> response = await hostWith(
        declaring(const <Object?>[
          <String, Object?>{'name': 'auth.tenant.switch'},
          <String, Object?>{'name': 'auth.switch-tenant'},
        ]),
      ).dispatchCatalog();

      expect(response['admission'], 'rejected');
      expect(rejectionOf(response)['code'], 'providerProtocolViolation');
      expect(detailsOf(response)['reason'], 'invalidCatalogCommands');
      expect(detailsOf(response)['violations'], <Object?>[
        <String, Object?>{
          'index': 1,
          'name': 'auth.switch-tenant',
          'reason': 'invalidCommandName',
        },
      ]);
      expect(
        detailsOf(response)['commandNamePattern'],
        r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$',
      );
    });

    test('serves no commands at all, not the surviving ones', () async {
      final Map<String, Object?> response = await hostWith(
        declaring(const <Object?>[
          <String, Object?>{'name': 'auth.tenant.switch'},
          <String, Object?>{'name': 'auth.switch-tenant'},
        ]),
      ).dispatchCatalog();

      expect(response.containsKey('commands'), isFalse);
      expect(response['schemaVersion'], PatchbayServiceHost.schemaVersion);
    });

    test('answers the catalog RPC instead of dropping the reply', () async {
      final ServiceExtensionResponse response =
          await hostWith(
            declaring(const <Object?>[
              <String, Object?>{'name': 'auth.switch-tenant'},
            ]),
          ).handleCatalog(
            PatchbayServiceHost.catalogMethod,
            const <String, String>{},
          );

      expect(response.isError(), isFalse);
      final Map<String, Object?> decoded =
          jsonDecode(response.result!) as Map<String, Object?>;
      expect(decoded['admission'], 'rejected');
      expect(
        (decoded['rejection']! as Map<String, Object?>)['code'],
        'providerProtocolViolation',
      );
    });

    test('reports duplicate names', () async {
      final Map<String, Object?> response = await hostWith(
        declaring(const <Object?>[
          <String, Object?>{'name': 'device.select'},
          <String, Object?>{'name': 'device.select'},
        ]),
      ).dispatchCatalog();

      expect(detailsOf(response)['violations'], <Object?>[
        <String, Object?>{
          'index': 1,
          'name': 'device.select',
          'reason': 'duplicateCommandName',
        },
      ]);
    });

    test('reports an entry with no usable name by position', () async {
      for (final Object? command in <Object?>[
        'device.select',
        const <String, Object?>{'summary': 'no name at all'},
        const <String, Object?>{'name': 42},
      ]) {
        final Map<String, Object?> response = await hostWith(
          declaring(<Object?>[command]),
        ).dispatchCatalog();

        expect(detailsOf(response)['violations'], <Object?>[
          <String, Object?>{'index': 0, 'reason': 'missingCommandName'},
        ], reason: 'entry $command');
      }
    });

    test('still rejects names that are strings but malformed', () async {
      for (final String name in <String>[' device.select ', 'Device.select']) {
        final Map<String, Object?> response = await hostWith(
          declaring(<Object?>[
            <String, Object?>{'name': name},
          ]),
        ).dispatchCatalog();

        expect(detailsOf(response)['violations'], <Object?>[
          <String, Object?>{
            'index': 0,
            'name': name,
            'reason': 'invalidCommandName',
          },
        ], reason: name);
      }
    });

    test('reports every offender in one answer', () async {
      final Map<String, Object?> response = await hostWith(
        declaring(const <Object?>[
          <String, Object?>{'name': 'auth.switch-tenant'},
          <String, Object?>{'name': 'device.select'},
          <String, Object?>{'name': 'device.select'},
          'device.select',
        ]),
      ).dispatchCatalog();

      expect(
        (detailsOf(response)['violations']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((Map<String, Object?> violation) => violation['reason']),
        <String>[
          'invalidCommandName',
          'duplicateCommandName',
          'missingCommandName',
        ],
      );
    });

    test('reports a commands field that is not an array', () async {
      final Map<String, Object?> response = await hostWith(
        () async => <String, Object?>{'commands': 'device.select'},
      ).dispatchCatalog();

      expect(detailsOf(response)['reason'], 'commandsNotAnArray');
    });

    test('reports a catalog source that throws, by type only', () async {
      final Map<String, Object?> response = await hostWith(
        () async => throw StateError('secret-bearing consumer message'),
      ).dispatchCatalog();

      expect(detailsOf(response)['reason'], 'catalogSourceFailed');
      expect(detailsOf(response)['error'], 'StateError');
      expect(jsonEncode(response), isNot(contains('secret-bearing')));
    });

    test('an omitted commands field is not a violation', () async {
      final Map<String, Object?> response = await hostWith(
        () async => const <String, Object?>{},
      ).dispatchCatalog();

      expect(response.containsKey('admission'), isFalse);
      expect(response['schemaVersion'], PatchbayServiceHost.schemaVersion);
    });

    test('makes invoke fail closed with the same diagnosis', () async {
      final Map<String, Object?> response =
          await hostWith(
            declaring(const <Object?>[
              <String, Object?>{'name': 'auth.switch-tenant'},
            ]),
          ).dispatchInvoke('device.bind', <String, Object?>{
            'password': 'hunter2',
          }, 'req-catalog');

      expect(response['admission'], 'rejected');
      expect(rejectionOf(response)['code'], 'providerProtocolViolation');
      expect(detailsOf(response)['reason'], 'catalogUnavailable');
      final Map<String, Object?> catalog =
          detailsOf(response)['catalog']! as Map<String, Object?>;
      expect(catalog['reason'], 'invalidCatalogCommands');
      expect(
        (catalog['violations']! as List<Object?>).single,
        containsPair('name', 'auth.switch-tenant'),
      );
      expect(invoked, isEmpty);
    });
  });

  test('service host replaces invalid provider invocation envelopes', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, _) async => PatchbayInvocation.accepted(
        requestId: 'provider-generated-id',
      ).toJson(),
    );

    final Map<String, Object?> result = await host.dispatchInvoke(
      'device.select',
      const <String, Object?>{},
      'caller-request-id',
    );

    expect(result['requestId'], 'caller-request-id');
    expect(result['admission'], 'rejected');
    expect(
      (result['rejection']! as Map<String, Object?>)['code'],
      'providerProtocolViolation',
    );
    expect(
      ((result['rejection']! as Map<String, Object?>)['details']!
          as Map<String, Object?>)['reason'],
      'requestIdMismatch',
    );
  });

  test(
    'service host rejects empty request IDs before provider dispatch',
    () async {
      var providerCalled = false;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{},
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async {
          providerCalled = true;
          return PatchbayInvocation.accepted(requestId: requestId).toJson();
        },
      );

      await expectLater(
        host.dispatchInvoke('device.select', const <String, Object?>{}, ''),
        throwsArgumentError,
      );
      expect(providerCalled, isFalse);
    },
  );

  test('service host rejects semantically contradictory envelopes', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async => <String, Object?>{
        ...PatchbayInvocation.accepted(requestId: requestId).toJson(),
        'rejection': const <String, Object?>{'code': 'contradiction'},
      },
    );

    final Map<String, Object?> result = await host.dispatchInvoke(
      'device.select',
      const <String, Object?>{},
      'caller-request-id',
    );
    expect(
      ((result['rejection']! as Map<String, Object?>)['details']!
          as Map<String, Object?>)['reason'],
      'acceptedWithRejection',
    );
  });
}
