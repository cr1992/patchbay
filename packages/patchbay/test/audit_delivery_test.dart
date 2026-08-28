import 'dart:async';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  group('audit delivery', () {
    test('starts one sink at a time in ledger order', () async {
      final List<Completer<void>> started = List<Completer<void>>.generate(
        3,
        (_) => Completer<void>(),
      );
      final List<Completer<void>> release = List<Completer<void>>.generate(
        3,
        (_) => Completer<void>(),
      );
      final List<String> requestIds = <String>[];
      var active = 0;
      var maxActive = 0;
      var calls = 0;
      final PatchbayServiceHost host = _host(
        auditSink: (PatchbayAuditEvent event) async {
          final int index = calls++;
          requestIds.add(event.requestId);
          active += 1;
          if (active > maxActive) maxActive = active;
          started[index].complete();
          await release[index].future;
          active -= 1;
        },
      );

      for (var index = 0; index < 3; index += 1) {
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'ordered-$index',
        );
      }

      await started[0].future;
      expect(calls, 1);
      release[0].complete();
      await started[1].future;
      expect(calls, 2);
      release[1].complete();
      await started[2].future;
      release[2].complete();

      final PatchbayAuditDrainResult result = await host.drainAudit();
      expect(requestIds, <String>['ordered-0', 'ordered-1', 'ordered-2']);
      expect(maxActive, 1);
      expect(result.outcome, PatchbayAuditDrainOutcome.drained);
      expect(result.settledCount, 3);
      expect(result.overflowDroppedCount, 0);
      expect(result.abandonedCount, 0);
    });

    test(
      'bounds active plus waiting and reports one complete overflow burst',
      () async {
        final Map<String, Completer<void>> releases =
            <String, Completer<void>>{};
        final List<String> started = <String>[];
        final Completer<PatchbayAuditDeliveryOverflow> overflow =
            Completer<PatchbayAuditDeliveryOverflow>();
        final PatchbayServiceHost host = _host(
          auditQueueCapacity: 2,
          auditSink: (PatchbayAuditEvent event) async {
            started.add(event.requestId);
            final Completer<void> release = Completer<void>();
            releases[event.requestId] = release;
            await release.future;
          },
          onAuditSinkError: (Object error, _, __) {
            if (error is PatchbayAuditDeliveryOverflow &&
                !overflow.isCompleted) {
              overflow.complete(error);
            }
          },
        );

        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'accepted-active',
        );
        await _waitUntil(() => started.length == 1);
        for (final String requestId in <String>[
          'accepted-waiting',
          'dropped-first',
          'dropped-last',
        ]) {
          await host.dispatchInvoke(
            'device.write',
            const <String, Object?>{},
            requestId,
          );
        }
        expect(started, <String>['accepted-active']);
        expect(overflow.isCompleted, isFalse);

        releases['accepted-active']!.complete();
        await _waitUntil(() => started.length == 2);
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'accepted-after-recovery',
        );

        final PatchbayAuditDeliveryOverflow error = await overflow.future;
        expect(error.droppedCount, 2);
        expect(error.firstSequence, 3);
        expect(error.lastSequence, 4);
        expect(error.capacity, 2);

        releases['accepted-waiting']!.complete();
        await _waitUntil(() => started.length == 3);
        releases['accepted-after-recovery']!.complete();
        final PatchbayAuditDrainResult result = await host.drainAudit();

        expect(started, <String>[
          'accepted-active',
          'accepted-waiting',
          'accepted-after-recovery',
        ]);
        expect(result.settledCount, 3);
        expect(result.overflowDroppedCount, 2);
        expect(result.abandonedCount, 0);
      },
    );

    test(
      'timeout abandons active and waiting without starting the suffix',
      () async {
        final Completer<void> activeStarted = Completer<void>();
        final Completer<void> activeRelease = Completer<void>();
        final List<String> started = <String>[];
        final List<PatchbayAuditDeliveryClosed> closed =
            <PatchbayAuditDeliveryClosed>[];
        final PatchbayServiceHost host = _host(
          auditSink: (PatchbayAuditEvent event) async {
            started.add(event.requestId);
            activeStarted.complete();
            await activeRelease.future;
          },
          onAuditSinkError: (Object error, _, __) {
            if (error is PatchbayAuditDeliveryClosed) closed.add(error);
          },
        );

        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'active',
        );
        await activeStarted.future;
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'waiting',
        );

        final PatchbayAuditDrainResult result = await host.drainAudit(
          timeout: Duration.zero,
        );
        expect(result.outcome, PatchbayAuditDrainOutcome.timedOut);
        expect(result.settledCount, 0);
        expect(result.overflowDroppedCount, 0);
        expect(result.abandonedCount, 2);

        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'after-close',
        );
        await _waitUntil(() => closed.isNotEmpty);
        expect(closed.single.sequence, 3);

        activeRelease.complete();
        await Future<void>.delayed(Duration.zero);
        expect(started, <String>['active']);
        expect(host.auditEvents, hasLength(3));
      },
    );

    test(
      'sink and observer failures stay isolated and delivery continues',
      () async {
        final List<String> started = <String>[];
        final List<Object> errors = <Object>[];
        final PatchbayServiceHost host = _host(
          auditSink: (PatchbayAuditEvent event) {
            started.add(event.requestId);
            if (event.requestId == 'throws') {
              throw StateError('sink unavailable');
            }
          },
          onAuditSinkError: (Object error, _, __) {
            errors.add(error);
            throw StateError('observer unavailable');
          },
        );

        final Map<String, Object?> first = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'throws',
        );
        final Map<String, Object?> second = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'continues',
        );
        final PatchbayAuditDrainResult result = await host.drainAudit();
        await _waitUntil(() => errors.isNotEmpty);

        expect(first['admission'], 'accepted');
        expect(second['admission'], 'accepted');
        expect(started, <String>['throws', 'continues']);
        expect(errors.single, isA<StateError>());
        expect(result.settledCount, 2);
      },
    );

    test(
      'drain closes a permanent overflow burst and absorbs late failure',
      () async {
        final Completer<void> release = Completer<void>();
        final List<Object> errors = <Object>[];
        final List<PatchbayAuditEvent> errorEvents = <PatchbayAuditEvent>[];
        final PatchbayServiceHost host = _host(
          auditQueueCapacity: 1,
          auditSink: (_) => release.future,
          onAuditSinkError: (Object error, _, PatchbayAuditEvent event) {
            errors.add(error);
            errorEvents.add(event);
          },
        );

        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'active',
        );
        await Future<void>.delayed(Duration.zero);
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'dropped-first',
        );
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'dropped-last',
        );

        final PatchbayAuditDrainResult result = await host.drainAudit(
          timeout: Duration.zero,
        );
        await _waitUntil(() => errors.isNotEmpty);
        final PatchbayAuditDeliveryOverflow overflow =
            errors.single as PatchbayAuditDeliveryOverflow;
        expect(overflow.droppedCount, 2);
        expect(overflow.firstSequence, 2);
        expect(overflow.lastSequence, 3);
        expect(overflow.capacity, 1);
        expect(errorEvents.single.requestId, 'dropped-first');
        expect(result.outcome, PatchbayAuditDrainOutcome.timedOut);
        expect(result.settledCount, 0);
        expect(result.overflowDroppedCount, 2);
        expect(result.abandonedCount, 1);

        release.completeError(StateError('late sink failure'));
        await _waitUntil(() => errors.length == 2);
        expect(errors.last, isA<StateError>());
        expect(errorEvents.last.requestId, 'active');
        expect(result.toJson(), <String, Object?>{
          'outcome': 'timedOut',
          'settledCount': 0,
          'overflowDroppedCount': 2,
          'abandonedCount': 1,
        });
      },
    );

    test(
      'drain and dispose are idempotent and freeze the first timeout',
      () async {
        final Completer<void> release = Completer<void>();
        final PatchbayServiceHost host = _host(
          auditSink: (_) => release.future,
        );
        await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'terminal',
        );

        final Future<PatchbayAuditDrainResult> first = host.drainAudit(
          timeout: const Duration(seconds: 1),
        );
        final Future<PatchbayAuditDrainResult> second = host.drainAudit(
          timeout: Duration.zero,
        );
        expect(identical(first, second), isTrue);
        release.complete();
        expect((await first).outcome, PatchbayAuditDrainOutcome.drained);

        final Future<void> disposeFirst = host.dispose();
        final Future<void> disposeSecond = host.dispose(
          auditTimeout: Duration.zero,
        );
        expect(identical(disposeFirst, disposeSecond), isTrue);
        await disposeFirst;
      },
    );

    test('no sink drains as an empty delivery stream', () async {
      final PatchbayServiceHost host = _host();
      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'ledger-only',
      );

      final PatchbayAuditDrainResult result = await host.drainAudit();
      expect(result.outcome, PatchbayAuditDrainOutcome.drained);
      expect(result.settledCount, 0);
      expect(result.overflowDroppedCount, 0);
      expect(result.abandonedCount, 0);
      expect(host.auditEvents.single.requestId, 'ledger-only');
    });

    test('validates queue capacity and drain timeout bounds', () {
      expect(() => _host(auditQueueCapacity: 0), throwsArgumentError);
      expect(() => _host(auditQueueCapacity: 4097), throwsArgumentError);
      expect(
        () => _host(auditQueueCapacity: 4096, auditSink: (_) {}),
        returnsNormally,
      );

      final PatchbayServiceHost host = _host(auditSink: (_) {});
      expect(
        () => host.drainAudit(timeout: const Duration(microseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => host.drainAudit(timeout: const Duration(seconds: 31)),
        throwsArgumentError,
      );
    });
  });
}

PatchbayServiceHost _host({
  PatchbayAuditSink? auditSink,
  PatchbayAuditSinkErrorHandler? onAuditSinkError,
  int auditQueueCapacity = 256,
}) => PatchbayServiceHost(
  applicationId: 'audit-delivery-test',
  registrar: (_, _) {},
  catalog: () async => const <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{
        'name': 'device.write',
        'mode': 'immediate',
        'sideEffect': 'external',
        'factSources': <String>['deviceReported'],
        'confirmationBudgetMs': 3000,
      },
    ],
  },
  snapshot: () async => const <String, Object?>{},
  invoke: (_, _, String requestId) async =>
      PatchbayInvocation.accepted(requestId: requestId).toJson(),
  auditSink: auditSink,
  onAuditSinkError: onAuditSinkError,
  auditQueueCapacity: auditQueueCapacity,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not reached');
}
