import 'dart:async';
import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  group('cooperative invocation cancellation', () {
    test(
      'deadline freezes rejection while confirmation releases capacity',
      () async {
        final Completer<Map<String, Object?>> handler =
            Completer<Map<String, Object?>>();
        final Completer<void> stopped = Completer<void>();
        final PatchbayServiceHost host = _host(
          maxConcurrentInvocations: 1,
          invokeWithContext: (command, arguments, requestId, context) {
            context.registerCancellationConfirmation((reason) async {
              expect(
                reason,
                PatchbayInvocationCancellationReason.callerDeadlineExceeded,
              );
              await stopped.future;
            });
            return handler.future;
          },
        );

        final Future<Map<String, Object?>> first = host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'req-1',
          ownerToken: 'AAAAAAAAAAAAAAAAAAAAAA',
          deadline: const Duration(milliseconds: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(
          (await first)['rejection'],
          containsPair('code', 'invocationDeadlineExceeded'),
        );
        expect(
          (await host.dispatchInvoke(
            'device.run',
            const <String, Object?>{},
            'req-2',
          ))['rejection'],
          containsPair('code', 'invocationCapacityExceeded'),
        );

        stopped.complete();
        await Future<void>.delayed(Duration.zero);
        final Future<Map<String, Object?>> third = host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'req-3',
        );
        handler.complete(_accepted('req-1'));
        expect((await third)['requestId'], 'req-3');
      },
    );

    test('explicit cancel is idempotent and callback runs once', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      var callbacks = 0;
      final PatchbayServiceHost host = _host(
        invokeWithContext: (command, arguments, requestId, context) {
          context.registerCancellationConfirmation((reason) async {
            callbacks += 1;
          });
          return handler.future;
        },
      );
      final Future<Map<String, Object?>> response = host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'req-cancel',
        ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
      );
      await Future<void>.delayed(Duration.zero);

      final PatchbayInvocationCancellationResult first = await host
          .cancelInvocation(
            command: 'device.run',
            requestId: 'req-cancel',
            ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
          );
      final PatchbayInvocationCancellationResult second = await host
          .cancelInvocation(
            command: 'device.run',
            requestId: 'req-cancel',
            ownerToken: 'BBBBBBBBBBBBBBBBBBBBBB',
          );

      expect(first.outcome, PatchbayInvocationCancellationOutcome.confirmed);
      expect(second.outcome, PatchbayInvocationCancellationOutcome.confirmed);
      expect(callbacks, 1);
      expect(
        (await response)['rejection'],
        containsPair('code', 'invocationCancelled'),
      );
      handler.complete(_accepted('req-cancel'));
    });

    test('registry and external handlers share one execution budget', () async {
      final Completer<Map<String, Object?>> registered =
          Completer<Map<String, Object?>>();
      final PatchbayCommandRegistry registry =
          PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
            PatchbayCommandRegistration<Object?>(
              descriptor: _descriptor('core.wait'),
              decode: (arguments) => null,
              handle: (request, requestId) => registered.future,
            ),
          ]);
      final PatchbayServiceHost host = _host(
        registry: registry,
        maxConcurrentInvocations: 1,
      );

      final Future<Map<String, Object?>> first = host.dispatchInvoke(
        'core.wait',
        const <String, Object?>{},
        'registry-1',
      );
      await Future<void>.delayed(Duration.zero);
      final Map<String, Object?> refused = await host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'external-1',
      );

      expect(
        refused['rejection'],
        containsPair('code', 'invocationCapacityExceeded'),
      );
      registered.complete(_accepted('registry-1'));
      await first;
    });

    test(
      'confirmed owner still rejects duplicate requestId until settle',
      () async {
        final Completer<Map<String, Object?>> handler =
            Completer<Map<String, Object?>>();
        final PatchbayServiceHost host = _host(
          invokeWithContext: (command, arguments, requestId, context) {
            context.registerCancellationConfirmation((reason) async {});
            return handler.future;
          },
        );
        final Future<Map<String, Object?>> first = host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'same-id',
          ownerToken: 'CCCCCCCCCCCCCCCCCCCCCC',
        );
        await Future<void>.delayed(Duration.zero);
        await host.cancelInvocation(
          command: 'device.run',
          requestId: 'same-id',
          ownerToken: 'CCCCCCCCCCCCCCCCCCCCCC',
        );

        expect(
          (await host.dispatchInvoke(
            'device.run',
            const <String, Object?>{},
            'same-id',
            ownerToken: 'DDDDDDDDDDDDDDDDDDDDDD',
          ))['rejection'],
          containsPair('code', 'requestIdConflict'),
        );
        handler.complete(_accepted('same-id'));
        await first;
      },
    );

    test('legacy deadline reports unsupported and retains capacity', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        catalog: () async => <String, Object?>{
          'commands': <Object?>[_descriptor('device.run').toJson()],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, _) => handler.future,
        maxConcurrentInvocations: 1,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'legacy-1',
        deadline: const Duration(milliseconds: 1),
      );
      expect(
        response['rejection'],
        containsPair('details', <String, Object?>{
          'reason': 'callerDeadlineExceeded',
          'cancellation': 'unsupported',
        }),
      );
      expect(
        (await host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'legacy-2',
        ))['rejection'],
        containsPair('code', 'invocationCapacityExceeded'),
      );
      handler.complete(_accepted('legacy-1'));
    });

    test('deadline during catalog wait never starts the handler', () async {
      final Completer<Map<String, Object?>> catalog =
          Completer<Map<String, Object?>>();
      var handlerCalls = 0;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.test',
        catalog: () => catalog.future,
        snapshot: () async => const <String, Object?>{},
        invokeWithContext: (_, _, requestId, _) async {
          handlerCalls += 1;
          return _accepted(requestId);
        },
      );

      final Future<Map<String, Object?>> response = host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'catalog-wait',
        deadline: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        (await response)['rejection'],
        containsPair('code', 'invocationDeadlineExceeded'),
      );
      catalog.complete(<String, Object?>{
        'commands': <Object?>[_descriptor('device.run').toJson()],
      });
      await Future<void>.delayed(Duration.zero);
      expect(handlerCalls, 0);
    });

    test('confirmation failures are stable and do not leak errors', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      final PatchbayServiceHost host = _host(
        invokeWithContext: (_, _, _, context) {
          context.registerCancellationConfirmation((_) async {
            throw StateError('secret consumer failure');
          });
          return handler.future;
        },
      );
      unawaited(
        host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'callback-failed',
          ownerToken: 'EEEEEEEEEEEEEEEEEEEEEE',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final PatchbayInvocationCancellationResult result = await host
          .cancelInvocation(
            command: 'device.run',
            requestId: 'callback-failed',
            ownerToken: 'EEEEEEEEEEEEEEEEEEEEEE',
          );
      expect(result.outcome, PatchbayInvocationCancellationOutcome.unconfirmed);
      expect(
        result.confirmation,
        PatchbayInvocationConfirmationState.callbackFailed,
      );
      expect(result.toJson().toString(), isNot(contains('secret')));
      handler.complete(_accepted('callback-failed'));
    });

    test('drain classifies confirmed but unsettled owners', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      final PatchbayServiceHost host = _host(
        invokeWithContext: (_, _, _, context) {
          context.registerCancellationConfirmation((_) async {});
          return handler.future;
        },
      );
      final Future<Map<String, Object?>> response = host.dispatchInvoke(
        'device.run',
        const <String, Object?>{},
        'drain-1',
        ownerToken: 'FFFFFFFFFFFFFFFFFFFFFF',
      );
      await Future<void>.delayed(Duration.zero);

      final PatchbayInvocationDrainResult drain = await host.drainInvocations();
      expect(drain.outcome, PatchbayInvocationDrainOutcome.drained);
      expect(drain.settledCount, 0);
      expect(drain.confirmedCount, 1);
      expect(drain.abandonedCount, 0);
      expect(
        (await response)['rejection'],
        containsPair('code', 'hostDisposed'),
      );
      expect(
        (await host.dispatchInvoke(
          'device.run',
          const <String, Object?>{},
          'after-drain',
        ))['rejection'],
        containsPair('code', 'hostDisposed'),
      );
      handler.complete(_accepted('drain-1'));
    });

    test('VM invoke and cancel keep strict additive shapes', () async {
      final Completer<Map<String, Object?>> handler =
          Completer<Map<String, Object?>>();
      final PatchbayServiceHost host = _host(
        invokeWithContext: (_, _, _, context) {
          context.registerCancellationConfirmation((_) async {});
          return handler.future;
        },
      );
      final Future<dynamic> invoke = host.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        const <String, String>{
          'command': 'device.run',
          'args': '{}',
          'requestId': 'vm-1',
          'deadlineMs': '300000',
          'ownerToken': 'GGGGGGGGGGGGGGGGGGGGGG',
        },
      );
      await Future<void>.delayed(Duration.zero);
      final dynamic cancel = await host.handleCancelInvocation(
        PatchbayServiceHost.cancelInvocationMethod,
        const <String, String>{
          'command': 'device.run',
          'requestId': 'vm-1',
          'ownerToken': 'GGGGGGGGGGGGGGGGGGGGGG',
        },
      );
      expect(
        jsonDecode(cancel.result! as String),
        containsPair('outcome', 'confirmed'),
      );
      final dynamic response = await invoke;
      expect(
        jsonDecode(response.result! as String)['rejection'],
        containsPair('code', 'invocationCancelled'),
      );
      final dynamic invalid = await host.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        const <String, String>{
          'command': 'device.run',
          'args': '{}',
          'requestId': 'vm-invalid',
          'future': 'field',
        },
      );
      expect(invalid.errorCode, isNotNull);
      handler.complete(_accepted('vm-1'));
    });
  });
}

PatchbayServiceHost _host({
  PatchbayCommandRegistry? registry,
  int maxConcurrentInvocations = 8,
  PatchbayContextInvocationSource? invokeWithContext,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.test',
  catalog: () async => <String, Object?>{
    'commands': <Object?>[_descriptor('device.run').toJson()],
  },
  snapshot: () async => const <String, Object?>{},
  invoke: invokeWithContext == null
      ? (command, arguments, requestId) async => _accepted(requestId)
      : null,
  invokeWithContext: invokeWithContext,
  registry: registry,
  maxConcurrentInvocations: maxConcurrentInvocations,
  cancellationConfirmationTimeout: const Duration(milliseconds: 20),
);

PatchbayCommandDescriptor _descriptor(String name) => PatchbayCommandDescriptor(
  name: name,
  summary: 'test',
  plane: PatchbayPlane.domain,
  mode: PatchbayCommandMode.immediate,
  sideEffect: PatchbaySideEffect.external,
  factSources: const <PatchbayFactSource>{},
);

Map<String, Object?> _accepted(String requestId) =>
    PatchbayInvocation.accepted(requestId: requestId).toJson();
