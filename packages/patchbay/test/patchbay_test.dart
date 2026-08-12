import 'dart:async';
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
      snapshot: () async => <String, Object?>{'source': 'appRuntime'},
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
      snapshot: () async => const <String, Object?>{'source': 'appRuntime'},
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
    );

    final ServiceExtensionResponse response = await host.handleSnapshot(
      PatchbayServiceHost.snapshotMethod,
      const <String, String>{},
    );

    expect(jsonDecode(response.result!), containsPair('source', 'appRuntime'));
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
        descriptor.toJson()['parameters'],
        contains(containsPair('name', 'deviceId')),
      );
    },
  );

  test(
    'job registry records ordered terminal events and cancellation',
    () async {
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        now: () => DateTime.utc(2026, 8, 12),
      );
      final Completer<Map<String, Object?>> pending =
          Completer<Map<String, Object?>>();
      var cancelled = false;
      final String jobId = jobs.start(
        source: 'appFlow',
        body: () => pending.future,
        cancel: () => cancelled = true,
      );

      expect(jobs.snapshot(jobId)?.terminal, isFalse);
      expect(await jobs.cancel(jobId, reason: 'consentRevoked'), isTrue);
      expect(cancelled, isTrue);
      expect(jobs.snapshot(jobId)?.terminal, isTrue);
      expect(
        jobs.snapshot(jobId)?.events.map((PatchbayJobEvent e) => e.sequence),
        <int>[1, 2],
      );
      expect(jobs.snapshot(jobId)?.events.last.reason, 'consentRevoked');
      pending.complete(const <String, Object?>{'ignored': true});
    },
  );
}
