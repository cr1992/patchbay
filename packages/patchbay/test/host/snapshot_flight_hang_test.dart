import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay_host.dart';
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

    test('the wait that opens the wedged sampling is left pending', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: provider.source,
      );

      // The opener owns the provider call, and PB-040 keeps it waiting for that
      // call to finish: the budget rules on whether the answer still counts, it
      // does not cut the read short. A source that never answers therefore
      // leaves this one caller suspended and the transport deadline is what
      // ends it — the same fallback plain reads have always relied on. That
      // residual is deliberate here; what must not happen is it spreading to
      // everybody else.
      expect(handler.hasSamplingInFlight, isFalse);
      var openerSettled = false;
      final Future<Map<String, Object?>> opener = handler
          .dispatchSnapshot(waitRequest(60))
          .whenComplete(() => openerSettled = true);
      expect(handler.hasSamplingInFlight, isTrue);
      expect(provider.calls.length, 1);

      // Arriving second is the whole difference: this one joined, so it is
      // answered on its own budget while the opener is still suspended.
      final Map<String, Object?> joiner = await handler
          .dispatchSnapshot(waitRequest(60))
          .timeout(const Duration(seconds: 5));
      expectSpentItsOwnBudget(joiner, timeoutMs: 60);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        openerSettled,
        isFalse,
        reason: 'the opener waits on its own provider call, budget or not',
      );
      expect(provider.calls.length, 1);
      expect(handler.hasSamplingInFlight, isTrue);
      unawaited(opener);
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

    test('the VM Service wait that opens is left pending too', () async {
      final ({
        Future<Map<String, Object?>> Function() source,
        List<int> calls,
        Completer<Map<String, Object?>> hang,
      })
      provider = wedged();
      final PatchbayServiceHost host = serviceHostServing(provider.source);

      // Same split across the VM Service handler: whoever opened the wedged
      // sampling stays suspended, everybody behind them is answered.
      var openerSettled = false;
      final Future<ServiceExtensionResponse> opener = host
          .handleSnapshot(PatchbayServiceHost.snapshotMethod, <String, String>{
            'isolateId': 'main',
            PatchbayServiceHost.snapshotRequestKey: jsonEncode(waitRequest(60)),
          })
          .whenComplete(() => openerSettled = true);
      expect(provider.calls.length, 1);

      expectSpentItsOwnBudget(await serviceWait(host, 60), timeoutMs: 60);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(openerSettled, isFalse);
      expect(provider.calls.length, 1);
      unawaited(opener);
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

        // Somebody owns the wedged provider call and, under PB-040, waits on
        // it. Polling a wedged App is what a script does next, and every round
        // must cost the App exactly nothing: one provider call, made once,
        // shared by all of them. Reopening the sampling per round — which is
        // what releasing a timed-out waiter's flight causes — is the leak this
        // asserts away.
        unawaited(handler.dispatchSnapshot());
        expect(provider.calls.length, 1);
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

      unawaited(host.dispatchSnapshot());
      expect(provider.calls.length, 1);
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

        // The opener declares a budget and still waits for its own provider
        // call. A whole-snapshot read declares none and joins it, which is what
        // makes the committed view observable here rather than merely asserted
        // about.
        final Future<Map<String, Object?>> opener = handler.dispatchSnapshot(
          waitRequest(60),
        );
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
        final Map<String, Object?> late = await opener.timeout(
          const Duration(seconds: 5),
        );
        final Map<String, Object?> settled = await patient.timeout(
          const Duration(seconds: 5),
        );

        // The opener is judged the way PB-040 has always judged a source slower
        // than the budget: the read completed, so a poll counts and what it
        // resolved travels, but the answer arrived long past the declared
        // budget and is refused rather than handed back as a success.
        expect(_rejection(late)['code'], 'snapshotWaitTimeout');
        expect(_details(late)['polls'], 1);
        expect(
          _details(late)['elapsedMs']! as int,
          greaterThan(120),
          reason: 'a wedged source overruns its budget by more than a rounding',
        );
        expect(_details(late)['observed'], <String, Object?>{
          'path': 'call.session',
          'found': true,
          'value': 'device-1',
        });

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
