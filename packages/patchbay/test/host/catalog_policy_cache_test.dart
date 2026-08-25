import 'dart:async';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/src/host/host_catalog.dart';
import 'package:test/test.dart';

void main() {
  group('versioned catalog policy cache', () {
    test('skips every catalog construction stage on a cache hit', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[],
      );
      final HostCatalogHandler handler = HostCatalogHandler(
        catalogProvider: provider,
        registry:
            PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
              PatchbayCommandRegistration<Map<String, Object?>>(
                descriptor: _descriptor('device.registered'),
                decode: (arguments) => arguments,
                handle: (_, requestId) =>
                    PatchbayInvocation.accepted(requestId: requestId).toJson(),
              ),
            ]),
      );

      await handler.readInvocationCatalog();
      await handler.readInvocationCatalog();

      expect(provider.reads, 1);
      expect(handler.debugBuildCounts.catalogBuilds, 1);
      expect(handler.debugBuildCounts.descriptorJson, 1);
      expect(handler.debugBuildCounts.commandsCanonicalization, 1);
      expect(handler.debugBuildCounts.catalogDigest, 1);
    });

    test('reuses one validated revision across invocations', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);

      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-1',
        ))['admission'],
        'accepted',
      );
      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-2',
        ))['admission'],
        'accepted',
      );

      expect(provider.reads, 1);
    });

    test('reloads after the commands revision advances', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-1',
      );
      provider
        ..revision = 1
        ..commands = const <Object?>[
          <String, Object?>{'name': 'device.status'},
          <String, Object?>{'name': 'device.refresh'},
        ];
      await host.dispatchInvoke(
        'device.refresh',
        const <String, Object?>{},
        'req-2',
      );

      expect(provider.reads, 2);
    });

    test('rejects a regressed revision without replacing the cache', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        revision: 2,
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);
      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-1',
      );

      provider.revision = 1;
      final Map<String, Object?> rejected = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-2',
      );
      expect(_catalogReason(rejected), 'catalogRevisionRegressed');
      expect(provider.reads, 1);

      provider.revision = 2;
      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-3',
        ))['admission'],
        'accepted',
      );
      expect(provider.reads, 1);
    });

    test('rejects a negative revision before reading the provider', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        revision: -1,
        commands: const <Object?>[],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);

      expect(
        _catalogReason(
          await host.dispatchInvoke(
            'device.status',
            const <String, Object?>{},
            'req-negative',
          ),
        ),
        'catalogRevisionInvalid',
      );
      expect(provider.reads, 0);
    });

    test('caches an invalid catalog only until revision advances', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.invalid-name'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);

      for (final String requestId in <String>[
        'req-invalid-1',
        'req-invalid-2',
      ]) {
        expect(
          _catalogReason(
            await host.dispatchInvoke(
              'device.status',
              const <String, Object?>{},
              requestId,
            ),
          ),
          'invalidCatalogCommands',
        );
      }
      expect(provider.reads, 1);

      provider
        ..revision = 1
        ..commands = const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ];
      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-repaired',
        ))['admission'],
        'accepted',
      );
      expect(provider.reads, 2);
    });

    test('same-revision command drift invalidates the old entry', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);
      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-1',
      );

      provider.commands = const <Object?>[
        <String, Object?>{'name': 'device.changed'},
      ];
      expect(
        _directCatalogReason(await host.dispatchCatalog()),
        'catalogRevisionContentChanged',
      );
      expect(
        _catalogReason(
          await host.dispatchInvoke(
            'device.status',
            const <String, Object?>{},
            'req-2',
          ),
        ),
        'catalogRevisionContentChanged',
      );
      expect(provider.reads, 2);
    });

    test('a getter failure does not overwrite a committed entry', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);
      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-1',
      );

      provider.getterError = StateError('private consumer detail');
      final Map<String, Object?> rejected = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-2',
      );
      expect(_catalogReason(rejected), 'catalogSourceFailed');
      expect(rejected.toString(), isNot(contains('private consumer detail')));

      provider.getterError = null;
      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-3',
        ))['admission'],
        'accepted',
      );
      expect(provider.reads, 1);
    });

    test('a read failure is retried without poisoning the revision', () async {
      final _MutableCatalogProvider provider = _MutableCatalogProvider(
        commands: const <Object?>[
          <String, Object?>{'name': 'device.status'},
        ],
      )..readError = StateError('private consumer detail');
      final PatchbayServiceHost host = _hostWithProvider(provider);

      final Map<String, Object?> rejected = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-failed',
      );
      expect(_catalogReason(rejected), 'catalogSourceFailed');
      expect(rejected.toString(), isNot(contains('private consumer detail')));

      provider.readError = null;
      expect(
        (await host.dispatchInvoke(
          'device.status',
          const <String, Object?>{},
          'req-retried',
        ))['admission'],
        'accepted',
      );
      expect(provider.reads, 2);
    });

    test('a newer caller waits for the old in-flight read', () async {
      final Completer<PatchbayCatalogSample> first =
          Completer<PatchbayCatalogSample>();
      final Completer<PatchbayCatalogSample> second =
          Completer<PatchbayCatalogSample>();
      final _QueuedCatalogProvider provider = _QueuedCatalogProvider(
        <Completer<PatchbayCatalogSample>>[first, second],
      );
      final PatchbayServiceHost host = _hostWithProvider(provider);

      final Future<Map<String, Object?>> oldInvocation = host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-old',
      );
      await Future<void>.delayed(Duration.zero);
      provider.revision = 1;
      final Future<Map<String, Object?>> newInvocation = host.dispatchInvoke(
        'device.refresh',
        const <String, Object?>{},
        'req-new',
      );
      await Future<void>.delayed(Duration.zero);
      expect(provider.reads, 1);

      first.complete(
        const PatchbayCatalogSample(
          commandsRevision: 0,
          catalog: <String, Object?>{
            'commands': <Object?>[
              <String, Object?>{'name': 'device.status'},
            ],
          },
        ),
      );
      expect((await oldInvocation)['admission'], 'accepted');
      await Future<void>.delayed(Duration.zero);
      expect(provider.reads, 2);
      second.complete(
        const PatchbayCatalogSample(
          commandsRevision: 1,
          catalog: <String, Object?>{
            'commands': <Object?>[
              <String, Object?>{'name': 'device.refresh'},
            ],
          },
        ),
      );
      expect((await newInvocation)['admission'], 'accepted');
    });
  });

  test(
    'legacy source validates every invocation including empty arguments',
    () async {
      var reads = 0;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        registrar: (_, _) {},
        catalog: () async {
          reads += 1;
          return const <String, Object?>{
            'commands': <Object?>[
              <String, Object?>{'name': 'device.status'},
            ],
          };
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-1',
      );
      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-2',
      );
      expect(reads, 2);
    },
  );

  test(
    'legacy source keeps the per-invocation construction baseline',
    () async {
      var reads = 0;
      final HostCatalogHandler handler = HostCatalogHandler(
        catalogSource: () async {
          reads += 1;
          return const <String, Object?>{'commands': <Object?>[]};
        },
        registry:
            PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
              PatchbayCommandRegistration<Map<String, Object?>>(
                descriptor: _descriptor('device.registered'),
                decode: (arguments) => arguments,
                handle: (_, requestId) =>
                    PatchbayInvocation.accepted(requestId: requestId).toJson(),
              ),
            ]),
      );

      await handler.readInvocationCatalog();
      await handler.readInvocationCatalog();

      expect(reads, 2);
      expect(handler.debugBuildCounts.catalogBuilds, 2);
      expect(handler.debugBuildCounts.descriptorJson, 2);
      expect(handler.debugBuildCounts.commandsCanonicalization, 2);
      expect(handler.debugBuildCounts.catalogDigest, 2);
    },
  );

  test('legacy callers share only an unsettled read', () async {
    final Completer<Map<String, Object?>> pending =
        Completer<Map<String, Object?>>();
    var reads = 0;
    final HostCatalogHandler handler = HostCatalogHandler(
      catalogSource: () {
        reads += 1;
        return pending.future;
      },
      registry: PatchbayCommandRegistry(
        const <PatchbayCommandRegistration<Object?>>[],
      ),
    );

    final Future<PatchbayCatalogValidity> first = handler
        .readInvocationCatalog();
    final Future<PatchbayCatalogValidity> second = handler
        .readInvocationCatalog();
    expect(reads, 1);
    pending.complete(const <String, Object?>{'commands': <Object?>[]});
    await Future.wait(<Future<PatchbayCatalogValidity>>[first, second]);

    await handler.readInvocationCatalog();
    expect(reads, 2);
  });

  test('registered empty-argument commands cannot bypass validity', () async {
    var handled = false;
    final PatchbayCommandRegistry registry =
        PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _descriptor('device.registered'),
            decode: (arguments) => arguments,
            handle: (_, requestId) {
              handled = true;
              return PatchbayInvocation.accepted(requestId: requestId).toJson();
            },
          ),
        ]);
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      registry: registry,
      catalog: () async => throw StateError('catalog unavailable'),
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'device.registered',
      const <String, Object?>{},
      'req-registered',
    );
    expect(_catalogReason(response), 'catalogSourceFailed');
    expect(handled, isFalse);
  });
}

PatchbayServiceHost _hostWithProvider(PatchbayCatalogProvider provider) =>
    PatchbayServiceHost.withCatalogProvider(
      applicationId: 'dev.patchbay.test',
      registrar: (_, _) {},
      catalogProvider: provider,
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

String? _catalogReason(Map<String, Object?> response) {
  final Map<String, Object?> rejection =
      response['rejection']! as Map<String, Object?>;
  final Map<String, Object?> details =
      rejection['details']! as Map<String, Object?>;
  final Map<String, Object?> catalog =
      details['catalog']! as Map<String, Object?>;
  return catalog['reason'] as String?;
}

String? _directCatalogReason(Map<String, Object?> response) {
  final Map<String, Object?> rejection =
      response['rejection']! as Map<String, Object?>;
  final Map<String, Object?> details =
      rejection['details']! as Map<String, Object?>;
  return details['reason'] as String?;
}

final class _MutableCatalogProvider implements PatchbayCatalogProvider {
  _MutableCatalogProvider({this.revision = 0, required this.commands});

  int revision;
  List<Object?> commands;
  Object? getterError;
  Object? readError;
  int reads = 0;

  @override
  int get commandsRevision {
    if (getterError case final Object error) throw error;
    return revision;
  }

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    reads += 1;
    if (readError case final Object error) throw error;
    return PatchbayCatalogSample(
      commandsRevision: revision,
      catalog: <String, Object?>{'commands': commands},
    );
  }
}

PatchbayCommandDescriptor _descriptor(String name) => PatchbayCommandDescriptor(
  name: name,
  summary: 'Catalog cache test command.',
  plane: PatchbayPlane.domain,
  mode: PatchbayCommandMode.immediate,
  sideEffect: PatchbaySideEffect.none,
  factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
  parameters: const <PatchbayParameterDescriptor>[],
);

final class _QueuedCatalogProvider implements PatchbayCatalogProvider {
  _QueuedCatalogProvider(this.samples);

  final List<Completer<PatchbayCatalogSample>> samples;
  int revision = 0;
  int reads = 0;

  @override
  int get commandsRevision => revision;

  @override
  Future<PatchbayCatalogSample> readCatalog() {
    final Completer<PatchbayCatalogSample> sample = samples[reads];
    reads += 1;
    return sample.future;
  }
}
