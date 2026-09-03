/// DG-060-05: an unknown `interactionModel` value fails the *whole* catalog
/// as a provider violation, the same fail-closed shape already frozen for
/// `retryPolicy`/`responseSchema`/`factSources` (see `host_catalog.dart`'s
/// `_validateCommands`), not just the one offending row.
library;

import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'VM Service and direct catalog reads are byte-identical for every '
    'interactionModel-bearing command (DG-060-05 VM/direct consistency)',
    () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'interaction-model-vm-direct-test',
        registrar: (_, _) {},
        catalog: () async => <String, Object?>{
          'commands': patchbayUiProtocolCliCommandDescriptors
              .map(
                (PatchbayCommandDescriptor descriptor) => descriptor.toJson(),
              )
              .toList(growable: false),
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> direct = await host.dispatchCatalog();
      final ServiceExtensionResponse vmResponse = await host.handleCatalog(
        PatchbayServiceHost.catalogMethod,
        const <String, String>{},
      );
      final Map<String, Object?> vm = Map<String, Object?>.from(
        jsonDecode(vmResponse.result!) as Map<String, dynamic>,
      );

      expect(vm, direct);
      final List<Object?> commands = direct['commands']! as List<Object?>;
      final Set<String> withInteractionModel = <String>{
        for (final Object? row in commands)
          if (row is Map<Object?, Object?> &&
              row.containsKey('interactionModel'))
            row['name']! as String,
      };
      expect(withInteractionModel, hasLength(10));
    },
  );

  test(
    'catalog rejects an unknown interactionModel value on any row',
    () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'interaction-model-catalog-test',
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'ui.semantics.tree'},
            <String, Object?>{
              'name': 'ui.text.set',
              'interactionModel': 'bogus',
            },
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();

      // 整份失效，不是只丢那一行：既有 responseSchema/retryPolicy 违规同款形状。
      expect(catalog.containsKey('commands'), isFalse);
      expect(catalog.toString(), contains('invalidInteractionModel'));
      final Map<Object?, Object?> rejection =
          catalog['rejection']! as Map<Object?, Object?>;
      expect(rejection['code'], 'providerProtocolViolation');
      final Map<Object?, Object?> details =
          rejection['details']! as Map<Object?, Object?>;
      expect(details['reason'], 'invalidCatalogCommands');

      // 一个正常命令（ui.semantics.tree）也拿不到，证明是整份、不是那一行。
      final Map<String, Object?> direct = await host.dispatchInvoke(
        'ui.semantics.tree',
        const <String, Object?>{},
        'request-1',
      );
      expect(
        (direct['rejection']! as Map<Object?, Object?>)['code'],
        'providerProtocolViolation',
      );
    },
  );

  test(
    'a non-string interactionModel value also fails the whole catalog',
    () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'interaction-model-catalog-type-test',
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'ui.text.set', 'interactionModel': 3},
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();

      expect(catalog.containsKey('commands'), isFalse);
      expect(catalog.toString(), contains('invalidInteractionModel'));
    },
  );

  test('a declared directTarget/userLike value publishes normally, additive '
      'and side by side with every other command', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'interaction-model-catalog-valid-test',
      catalog: () async => <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{
            'name': 'ui.text.set',
            'interactionModel': 'directTarget',
          },
          <String, Object?>{
            'name': 'ui.gesture.tap',
            'interactionModel': 'userLike',
          },
          <String, Object?>{'name': 'ui.semantics.tree'},
        ],
      },
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

    final Map<String, Object?> catalog = await host.dispatchCatalog();

    final List<Object?> commands = catalog['commands']! as List<Object?>;
    expect(commands, hasLength(3));
    final Map<Object?, Object?> textSet =
        commands.firstWhere(
              (Object? row) =>
                  row is Map<Object?, Object?> && row['name'] == 'ui.text.set',
            )!
            as Map<Object?, Object?>;
    expect(textSet['interactionModel'], 'directTarget');
    final Map<Object?, Object?> tree =
        commands.firstWhere(
              (Object? row) =>
                  row is Map<Object?, Object?> &&
                  row['name'] == 'ui.semantics.tree',
            )!
            as Map<Object?, Object?>;
    expect(tree.containsKey('interactionModel'), isFalse);
  });
}
