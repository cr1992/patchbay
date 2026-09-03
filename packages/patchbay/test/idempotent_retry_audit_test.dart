import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'descriptor serializes retry policy but registry ownership rejects it',
    () {
      const PatchbayCommandDescriptor descriptor = PatchbayCommandDescriptor(
        name: 'device.write',
        summary: 'Write device state',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.external,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        retryPolicy: PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 50),
      );

      expect(descriptor.toJson()['retryPolicy'], const <String, Object?>{
        'maxAttempts': 2,
        'backoffMs': 50,
      });
      expect(
        () => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: descriptor,
            decode: (Map<String, Object?> arguments) => arguments,
            handle: (Map<String, Object?> _, String requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ]),
        throwsArgumentError,
      );
    },
  );

  group('external requestId ledger', () {
    test('shares in-flight work and replays the settled result', () async {
      final Completer<Map<String, Object?>> provider =
          Completer<Map<String, Object?>>();
      var calls = 0;
      final PatchbayServiceHost host = _host(
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 0),
        invoke: (_, _, requestId) {
          calls += 1;
          return provider.future;
        },
      );

      final Future<Map<String, Object?>> first = host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'enabled': true},
        'same-request',
      );
      await Future<void>.delayed(Duration.zero);
      final Future<Map<String, Object?>> concurrent = host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'enabled': true},
        'same-request',
      );
      provider.complete(
        PatchbayInvocation.accepted(
          requestId: 'same-request',
          payload: const <String, Object?>{'result': 'written'},
        ).toJson(),
      );

      final Map<String, Object?> firstResult = await first;
      final Map<String, Object?> concurrentResult = await concurrent;
      final Map<String, Object?> replay = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{'enabled': true},
        'same-request',
      );

      expect(calls, 1);
      expect(concurrentResult, firstResult);
      expect(replay, firstResult);
      expect(host.auditEvents, hasLength(1));
    });

    test(
      'same key with different arguments fails without leaking values',
      () async {
        var calls = 0;
        final PatchbayServiceHost host = _host(
          retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 0),
          invoke: (_, _, requestId) async {
            calls += 1;
            return PatchbayInvocation.accepted(requestId: requestId).toJson();
          },
        );

        await host.dispatchInvoke('device.write', const <String, Object?>{
          'secret': 'first-value',
        }, 'conflict-request');
        final Map<String, Object?> conflict = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{'secret': 'second-value'},
          'conflict-request',
        );

        expect(calls, 1);
        expect(_rejectionCode(conflict), 'requestIdConflict');
        expect(conflict.toString(), isNot(contains('first-value')));
        expect(conflict.toString(), isNot(contains('second-value')));
        expect(host.auditEvents, hasLength(2));
        expect(host.auditEvents.last.executionClassification, isNull);
      },
    );

    test('non-idempotent duplicate never executes twice', () async {
      var calls = 0;
      final PatchbayServiceHost host = _host(
        invoke: (_, _, requestId) async {
          calls += 1;
          return PatchbayInvocation.accepted(requestId: requestId).toJson();
        },
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'non-idempotent-request',
      );
      final Map<String, Object?> duplicate = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'non-idempotent-request',
      );

      expect(calls, 1);
      expect(_rejectionCode(duplicate), 'duplicateRequestId');
      expect(host.auditEvents, hasLength(2));
      expect(host.auditEvents.last.executionClassification, isNull);
    });

    test('VM and direct seams share the same de-duplication result', () async {
      PatchbayServiceHost host() => _host(
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 0),
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{'result': 'once'},
        ).toJson(),
      );

      final PatchbayServiceHost directHost = host();
      final PatchbayServiceHost vmHost = host();
      final Map<String, Object?> direct = await directHost.dispatchInvoke(
        'device.write',
        const <String, Object?>{'enabled': true},
        'parity-request',
      );
      final ServiceExtensionResponse vmResponse = await vmHost.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        const <String, String>{
          'command': 'device.write',
          'args': '{"enabled":true}',
          'requestId': 'parity-request',
        },
      );
      final Map<String, Object?> vm = Map<String, Object?>.from(
        jsonDecode(vmResponse.result!) as Map<String, dynamic>,
      );

      expect(vm, direct);
      expect(
        await directHost.dispatchInvoke('device.write', const <String, Object?>{
          'enabled': true,
        }, 'parity-request'),
        direct,
      );
      final ServiceExtensionResponse vmReplay = await vmHost.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        const <String, String>{
          'command': 'device.write',
          'args': '{"enabled":true}',
          'requestId': 'parity-request',
        },
      );
      expect(
        Map<String, Object?>.from(
          jsonDecode(vmReplay.result!) as Map<String, dynamic>,
        ),
        vm,
      );
      expect(directHost.auditEvents, hasLength(1));
      expect(vmHost.auditEvents, hasLength(1));
    });
  });

  group('retry policy validation', () {
    for (final Map<String, Object?> policy in <Map<String, Object?>>[
      const <String, Object?>{'maxAttempts': 1, 'backoffMs': 0},
      const <String, Object?>{'maxAttempts': 4, 'backoffMs': 0},
      const <String, Object?>{'maxAttempts': 2, 'backoffMs': -1},
      const <String, Object?>{'maxAttempts': 2, 'backoffMs': 5001},
      const <String, Object?>{'maxAttempts': 2, 'backoffMs': 0, 'future': true},
    ]) {
      test('invalid bounds/shape fail the catalog closed: $policy', () async {
        var invoked = false;
        final PatchbayServiceHost host = _host(
          rawRetryPolicy: policy,
          invoke: (_, _, requestId) async {
            invoked = true;
            return PatchbayInvocation.accepted(requestId: requestId).toJson();
          },
        );

        final Map<String, Object?> catalog = await host.dispatchCatalog();
        expect(_rejectionCode(catalog), 'providerProtocolViolation');
        expect(catalog.toString(), contains('invalidRetryPolicy'));
        final Map<String, Object?> invocation = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'invalid-policy-request',
        );
        expect(_rejectionCode(invocation), 'providerProtocolViolation');
        expect(invoked, isFalse);
      });
    }

    test('retry policy on a non-external command fails closed', () async {
      final PatchbayServiceHost host = _host(
        sideEffect: 'appState',
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 0),
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();
      expect(_rejectionCode(catalog), 'providerProtocolViolation');
      expect(catalog.toString(), contains('invalidRetryPolicy'));
    });
  });

  group('redacted audit ledger', () {
    test(
      'records shape/classification before isolating sink failure',
      () async {
        final Completer<void> sinkError = Completer<void>();
        final PatchbayServiceHost host = _host(
          auditSink: (_) => throw StateError('sink unavailable'),
          onAuditSinkError: (_, _, __) => sinkError.complete(),
          invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
            requestId: requestId,
            payload: const <String, Object?>{
              'execution': <String, Object?>{
                'classification': 'deviceConfirmed',
                'factSource': 'deviceReported',
                'observedAtMs': 1000,
                'reasonCode': null,
              },
            },
          ).toJson(),
        );

        final Map<String, Object?> response = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{
            'token': 'top-secret',
            'nested': <String, Object?>{
              'pin': 1234,
              'flags': <Object?>[true, false, true],
            },
          },
          'audit-request',
        );
        await sinkError.future;

        expect(response['admission'], 'accepted');
        final PatchbayAuditEvent event = host.auditEvents.single;
        expect(event.command, 'device.write');
        expect(event.requestId, 'audit-request');
        expect(event.gateResult, 'notEvaluated');
        expect(event.executionClassification, 'deviceConfirmed');
        expect(event.toJson().toString(), isNot(contains('top-secret')));
        expect(event.toJson().toString(), isNot(contains('1234')));
        expect(event.parameterShape.toString(), contains('token'));
        expect(event.parameterShape.toString(), contains('2-5'));
        expect(
          () => event.parameterShape['leak'] = 'value',
          throwsUnsupportedError,
        );
      },
    );

    test('records the registry gate result rather than inferring it', () async {
      final PatchbayCommandRegistry registry = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: const PatchbayCommandDescriptor(
              name: 'patchbay.gated',
              summary: 'Gated fixture.',
              plane: PatchbayPlane.domain,
              mode: PatchbayCommandMode.immediate,
              sideEffect: PatchbaySideEffect.none,
              factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
            ),
            decode: (arguments) => arguments,
            gate: (_, __) => null,
            handle: (_, requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ],
      );
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'registered-audit-test',
        registrar: (_, _) {},
        registry: registry,
        catalog: () async => const <String, Object?>{},
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );

      await host.dispatchInvoke(
        'patchbay.gated',
        const <String, Object?>{},
        'registered-audit',
      );

      expect(host.auditEvents.single.gateResult, 'passed');
    });

    test('retains only the newest 256 facts', () async {
      final PatchbayServiceHost host = _host();
      for (var index = 0; index < 257; index += 1) {
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'audit-$index',
        );
      }

      expect(host.auditEvents, hasLength(256));
      expect(host.auditEvents.first.requestId, 'audit-1');
      expect(host.auditEvents.last.requestId, 'audit-256');
    });

    test('array item shapes are deterministic and unsupported is stable', () {
      final Map<String, Object?> left = patchbayParameterShape(
        <String, Object?>{
          'values': <Object?>[true, 'secret'],
          'other': Object(),
        },
      );
      final Map<String, Object?> right = patchbayParameterShape(
        <String, Object?>{
          'other': Object(),
          'values': <Object?>['different', false],
        },
      );

      expect(left, right);
      expect(left.toString(), contains('unsupported'));
      expect(left.toString(), isNot(contains('Object')));
      expect(left.toString(), isNot(contains('secret')));
      expect(left.toString(), isNot(contains('different')));
    });
  });
}

PatchbayServiceHost _host({
  PatchbayRetryPolicy? retryPolicy,
  Map<String, Object?>? rawRetryPolicy,
  String sideEffect = 'external',
  PatchbayInvocationSource? invoke,
  PatchbayAuditSink? auditSink,
  PatchbayAuditSinkErrorHandler? onAuditSinkError,
}) => PatchbayServiceHost(
  applicationId: 'retry-audit-test',
  registrar: (_, _) {},
  catalog: () async => <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{
        'name': 'device.write',
        'mode': 'immediate',
        'sideEffect': sideEffect,
        'factSources': <String>['deviceReported'],
        'confirmationBudgetMs': 3000,
        if (retryPolicy != null) 'retryPolicy': retryPolicy.toJson(),
        if (rawRetryPolicy != null) 'retryPolicy': rawRetryPolicy,
      },
    ],
  },
  snapshot: () async => const <String, Object?>{},
  invoke:
      invoke ??
      (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
  auditSink: auditSink,
  onAuditSinkError: onAuditSinkError,
);

String? _rejectionCode(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}
