import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/src/host/host_snapshot.dart';
import 'package:test/test.dart';

Map<String, Object?> _rejection(Map<String, Object?> response) =>
    response['rejection']! as Map<String, Object?>;

Map<String, Object?> _details(Map<String, Object?> response) =>
    _rejection(response)['details']! as Map<String, Object?>;

void main() {
  group('a sampling that never settles', () {
    /// A source that wedges on *every* call until [hang] is completed.
    ///
    /// A source that only wedges once heals itself: the second call answers, so
    /// "the sampling was reopened" and "the sampling was shared" produce the
    /// same visible result and the leak hides. Wedging every call is the shape
    /// the Proposal names as `source hang`, and the only one where the provider
    /// call count is evidence.
    ({
      Future<Map<String, Object?>> Function() source,
      List<int> calls,
      Completer<Map<String, Object?>> hang,
    })
    wedged() {
      final Completer<Map<String, Object?>> hang =
          Completer<Map<String, Object?>>();
      final List<int> calls = <int>[];
      return (
        calls: calls,
        hang: hang,
        source: () {
          calls.add(calls.length + 1);
          if (!hang.isCompleted) return hang.future;
          return Future<Map<String, Object?>>.value(<String, Object?>{
            'call': <String, Object?>{'session': 'device-${calls.length}'},
          });
        },
      );
    }

    Map<String, Object?> waitRequest(int timeoutMs) => <String, Object?>{
      'path': 'call.session',
      'until': 'exists',
      'timeoutMs': timeoutMs,
    };

    PatchbayServiceHost serviceHostServing(
      Future<Map<String, Object?>> Function() source,
    ) => PatchbayServiceHost(
      applicationId: 'dev.patchbay.budget',
      appInstanceId: 'instance-hang',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{'commands': <Object?>[]},
      invoke: (_, _, String requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
      snapshot: source,
    );

    Future<Map<String, Object?>> serviceWait(
      PatchbayServiceHost host,
      int timeoutMs,
    ) async {
      final ServiceExtensionResponse vm = await host
          .handleSnapshot(PatchbayServiceHost.snapshotMethod, <String, String>{
            'isolateId': 'main',
            PatchbayServiceHost.snapshotRequestKey: jsonEncode(
              waitRequest(timeoutMs),
            ),
          })
          .timeout(const Duration(seconds: 5));
      return jsonDecode(vm.result!) as Map<String, Object?>;
    }

    /// The typed answer a wedged sampling owes a caller that declared a budget.
    void expectSpentItsOwnBudget(
      Map<String, Object?> response, {
      required int timeoutMs,
    }) {
      expect(_rejection(response)['code'], 'snapshotWaitTimeout');
      expect(_details(response), containsPair('timeoutMs', timeoutMs));
      expect(
        _details(response)['polls'],
        0,
        reason: 'a sampling that never answered cannot be counted as a poll',
      );
      expect(
        _details(response).containsKey('observed'),
        isFalse,
        reason: 'nothing was observed, so nothing is reported as observed',
      );
    }

    test(
      'a wait that joins the wedged sampling keeps its own budget',
      () async {
        final ({
          Future<Map<String, Object?>> Function() source,
          List<int> calls,
          Completer<Map<String, Object?>> hang,
        })
        provider = wedged();
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: provider.source,
        );

        // Somebody else already opened the sampling and was swallowed by it.
        unawaited(handler.dispatchSnapshot());
        expect(handler.hasSamplingInFlight, isTrue);
        expect(provider.calls.length, 1);

        final Stopwatch elapsed = Stopwatch()..start();
        final Map<String, Object?> response = await handler
            .dispatchSnapshot(waitRequest(200))
            .timeout(const Duration(seconds: 5));
        elapsed.stop();

        expectSpentItsOwnBudget(response, timeoutMs: 200);
        expect(
          elapsed.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason: 'the wedged sampling must not swallow the caller budget',
        );
        expect(provider.calls.length, 1);
        expect(
          handler.hasSamplingInFlight,
          isTrue,
          reason: 'giving up on a budget says nothing about the provider call',
        );
      },
    );

    test('a wait that opens the wedged sampling keeps its own budget', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: provider.source,
      );

      // Nothing is in flight, so this caller opens the sampling itself. Opening
      // it is not a reason to wait longer than the budget it declared: the two
      // timings must answer alike or a caller's deadline depends on who else
      // happened to be reading.
      expect(handler.hasSamplingInFlight, isFalse);

      final Stopwatch elapsed = Stopwatch()..start();
      final Map<String, Object?> response = await handler
          .dispatchSnapshot(waitRequest(200))
          .timeout(const Duration(seconds: 5));
      elapsed.stop();

      expectSpentItsOwnBudget(response, timeoutMs: 200);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
      expect(provider.calls.length, 1);
      expect(handler.hasSamplingInFlight, isTrue);
    });

    test('a VM Service wait that joins keeps its own budget', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final PatchbayServiceHost host = serviceHostServing(provider.source);

      unawaited(host.dispatchSnapshot());
      expect(provider.calls.length, 1);

      final Stopwatch elapsed = Stopwatch()..start();
      final Map<String, Object?> response = await serviceWait(host, 200);
      elapsed.stop();

      expectSpentItsOwnBudget(response, timeoutMs: 200);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
      expect(provider.calls.length, 1);
    });

    test('a VM Service wait that opens keeps its own budget', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final PatchbayServiceHost host = serviceHostServing(provider.source);

      final Stopwatch elapsed = Stopwatch()..start();
      final Map<String, Object?> response = await serviceWait(host, 200);
      elapsed.stop();

      expectSpentItsOwnBudget(response, timeoutMs: 200);
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
      expect(provider.calls.length, 1);
    });

    test(
      'a wedged provider is called once, however many waits pile on',
      () async {
        final ({
          Future<Map<String, Object?>> Function() source,
          List<int> calls,
          Completer<Map<String, Object?>> hang,
        })
        provider = wedged();
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: provider.source,
        );

        // Polling a wedged App is what a script does. Every round must cost the
        // App exactly nothing: one provider call, made once, shared by all of
        // them. Reopening the sampling per round is the leak this asserts away.
        for (var round = 1; round <= 10; round += 1) {
          final Map<String, Object?> response = await handler
              .dispatchSnapshot(waitRequest(60))
              .timeout(const Duration(seconds: 5));
          expectSpentItsOwnBudget(response, timeoutMs: 60);
          expect(
            provider.calls.length,
            1,
            reason: 'round $round reopened the sampling',
          );
          expect(
            handler.hasSamplingInFlight,
            isTrue,
            reason:
                'round $round dropped a provider call that is still running',
          );
        }
        expect(handler.retainedCanonicalBytes, 0);
        expect(handler.retainedRevisionCount, 0);
      },
    );

    test('the VM Service side piles onto the same wedged sampling', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final PatchbayServiceHost host = serviceHostServing(provider.source);

      for (var round = 1; round <= 5; round += 1) {
        final Map<String, Object?> response = await serviceWait(host, 60);
        expectSpentItsOwnBudget(response, timeoutMs: 60);
        expect(
          provider.calls.length,
          1,
          reason: 'round $round reopened the sampling',
        );
      }
    });

    test(
      'the sampling everyone gave up on still commits exactly once',
      () async {
        final ({
          Future<Map<String, Object?>> Function() source,
          List<int> calls,
          Completer<Map<String, Object?>> hang,
        })
        provider = wedged();
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: provider.source,
        );

        // A whole-snapshot read declares no budget, so it is still attached when
        // the App finally answers — which is what makes the late settle
        // observable here rather than merely asserted about.
        final Future<Map<String, Object?>> patient = handler.dispatchSnapshot();
        for (var round = 1; round <= 3; round += 1) {
          expectSpentItsOwnBudget(
            await handler
                .dispatchSnapshot(waitRequest(60))
                .timeout(const Duration(seconds: 5)),
            timeoutMs: 60,
          );
        }
        expect(provider.calls.length, 1);

        provider.hang.complete(<String, Object?>{
          'call': <String, Object?>{'session': 'device-1'},
        });
        final Map<String, Object?> settled = await patient.timeout(
          const Duration(seconds: 5),
        );

        // One provider call, one commit, and the content is the App's own — the
        // waiters that walked away neither duplicated it nor reordered it.
        expect(settled['snapshotRevision'], 1);
        expect(settled['call'], <String, Object?>{'session': 'device-1'});
        expect(handler.retainedRevisionCount, 1);
        expect(provider.calls.length, 1);
        expect(handler.hasSamplingInFlight, isFalse);

        // And the App is ordinary again: the next read samples afresh.
        final Map<String, Object?> next = await handler
            .dispatchSnapshot(<String, Object?>{'path': 'call.session'})
            .timeout(const Duration(seconds: 5));
        expect(provider.calls.length, 2);
        expect(next['snapshotRevision'], 2);
        expect(next['selection'], <String, Object?>{
          'path': 'call.session',
          'found': true,
          'value': 'device-2',
        });

        final Map<String, Object?> observed = await handler
            .dispatchSnapshot(waitRequest(5000))
            .timeout(const Duration(seconds: 5));
        expect(
          (observed['wait']! as Map<String, Object?>)['outcome'],
          'observed',
        );
      },
    );

    test('a joiner still inside its budget shares the sampling', () async {
      final Completer<Map<String, Object?>> gate =
          Completer<Map<String, Object?>>();
      var calls = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () {
          calls += 1;
          return gate.future;
        },
      );

      unawaited(handler.dispatchSnapshot());
      final Future<Map<String, Object?>> joined = handler.dispatchSnapshot(
        waitRequest(5000),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Nothing has expired, so the batch is still one sampling: the repair
      // must not turn "slow" into "sample again".
      expect(calls, 1);
      expect(handler.hasSamplingInFlight, isTrue);

      gate.complete(<String, Object?>{
        'call': <String, Object?>{'session': 'device-1'},
      });
      final Map<String, Object?> response = await joined.timeout(
        const Duration(seconds: 5),
      );
      expect(
        (response['wait']! as Map<String, Object?>)['outcome'],
        'observed',
      );
      expect(calls, 1);
    });
  });
}
