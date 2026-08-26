import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/src/host/host_snapshot.dart';
import 'package:patchbay/src/host/snapshot_payload.dart';
import 'package:test/test.dart';

Map<String, Object?> _rejection(Map<String, Object?> response) =>
    response['rejection']! as Map<String, Object?>;

Map<String, Object?> _details(Map<String, Object?> response) =>
    _rejection(response)['details']! as Map<String, Object?>;

/// A payload whose canonical UTF-8 encoding is exactly [bytes] long.
///
/// `{"value":"<filler>"}` is twelve bytes of frame plus the filler, so a test
/// can sit one byte either side of a budget instead of guessing at it. [seed]
/// is appended inside the filler, so successive payloads differ in content
/// while staying byte-identical in size.
Map<String, Object?> _payloadOfBytes(int bytes, [Object? seed]) {
  final String tag = seed?.toString() ?? '';
  return <String, Object?>{'value': 'x' * (bytes - 12 - tag.length) + tag};
}

/// A body that fails loudly the moment anything reads it.
///
/// The consumer-revision fast path is only honest if the host never touches
/// the map handed to it for an unchanged revision; a map that throws on `keys`
/// turns "we did not look" from a claim into an assertion.
final class _UnreadableBody extends MapBase<String, Object?> {
  @override
  Iterable<String> get keys =>
      throw StateError('the host read a body it promised not to read');

  @override
  Object? operator [](Object? key) =>
      throw StateError('the host read a body it promised not to read');

  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read-only test map');

  @override
  void clear() => throw UnsupportedError('read-only test map');

  @override
  Object? remove(Object? key) => throw UnsupportedError('read-only test map');
}

PatchbaySnapshotRetentionLimits _limits({
  int revisions = patchbaySnapshotRevisionRetention,
  int snapshotBytes = patchbaySnapshotMinSnapshotBytes,
  int? retainedBytes,
}) => PatchbaySnapshotRetentionLimits(
  maxRetainedRevisions: revisions,
  maxSnapshotBytes: snapshotBytes,
  maxRetainedBytes: retainedBytes ?? snapshotBytes,
);

void main() {
  group('budget constants', () {
    test('production defaults match the DG-050-01 decision', () {
      const PatchbaySnapshotRetentionLimits limits =
          PatchbaySnapshotRetentionLimits.production;
      expect(limits.maxRetainedRevisions, 32);
      expect(limits.maxSnapshotBytes, 1024 * 1024);
      expect(limits.maxRetainedBytes, 8 * 1024 * 1024);
      expect(limits.maxRetainedRevisions, patchbaySnapshotRevisionRetention);
    });

    test('the occurrence backstop cannot fire before the byte budget', () {
      // DG-050-01 conclusion 2: PB-050-01's occurrence backstop exists behind
      // the byte ceiling, so any legal 1..4 MiB payload is classified by the
      // byte budget. The densest canonical payload spends at least two bytes
      // per occurrence, so half the byte ceiling is the strongest claim the
      // relation has to survive.
      expect(
        patchbaySnapshotMaxExpandedOccurrences,
        greaterThanOrEqualTo(patchbaySnapshotMaxCanonicalBytes ~/ 2),
      );
    });

    test('no configurable single-snapshot budget may pass the ceiling', () {
      expect(patchbaySnapshotSnapshotByteCeiling, 4 * 1024 * 1024);
      expect(
        patchbaySnapshotSnapshotByteCeiling,
        patchbaySnapshotMaxCanonicalBytes,
      );
      expect(
        () => _limits(snapshotBytes: patchbaySnapshotSnapshotByteCeiling + 1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => _limits(snapshotBytes: patchbaySnapshotMinSnapshotBytes - 1),
        throwsA(isA<AssertionError>()),
      );
      expect(() => _limits(revisions: 0), throwsA(isA<AssertionError>()));
      expect(() => _limits(revisions: 129), throwsA(isA<AssertionError>()));
      expect(
        () => _limits(snapshotBytes: 128 * 1024, retainedBytes: 128 * 1024 - 1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => _limits(retainedBytes: patchbaySnapshotRetainedByteCeiling + 1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        _limits(snapshotBytes: patchbaySnapshotSnapshotByteCeiling).effective,
        patchbaySnapshotSnapshotByteCeiling,
      );
    });
  });

  group('single snapshot byte budget', () {
    test('accepts the payload that lands exactly on the budget', () async {
      const int budget = patchbaySnapshotMinSnapshotBytes;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => _payloadOfBytes(budget),
        retention: _limits(snapshotBytes: budget),
      );

      final Map<String, Object?> response = await handler.dispatchSnapshot();

      expect(response['snapshotRevision'], 1);
      expect(response['snapshotBytes'], budget);
      expect(handler.retainedCanonicalBytes, budget);
    });

    test('rejects one byte past the budget without touching latest', () async {
      const int budget = patchbaySnapshotMinSnapshotBytes;
      Map<String, Object?> current = _payloadOfBytes(budget);
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => current,
        retention: _limits(snapshotBytes: budget),
      );
      await handler.dispatchSnapshot();
      final int retainedBefore = handler.retainedCanonicalBytes;

      current = _payloadOfBytes(budget + 1);
      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      expect(refused['admission'], 'rejected');
      expect(_rejection(refused)['code'], 'snapshotPayloadTooLarge');
      expect(_details(refused).keys.toSet(), <String>{
        'encodedBytesAtLeast',
        'maxSnapshotBytes',
      });
      expect(_details(refused)['maxSnapshotBytes'], budget);
      expect(handler.retainedCanonicalBytes, retainedBefore);

      // Latest is untouched: the retained revision still answers and still
      // carries the payload that was admitted.
      current = _payloadOfBytes(budget);
      final Map<String, Object?> again = await handler.dispatchSnapshot();
      expect(again['snapshotRevision'], 1);
    });

    test('aborts the sink instead of building the whole canonical', () async {
      const int budget = patchbaySnapshotMinSnapshotBytes;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => _payloadOfBytes(1024 * 1024),
        retention: _limits(snapshotBytes: budget),
      );

      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      final Object? counted = _details(refused)['encodedBytesAtLeast'];
      expect(counted, isA<int>());
      expect(counted! as int, greaterThan(budget));
      // The write counter stopped just past the budget rather than running to
      // the megabyte the source actually offered.
      expect(counted as int, lessThan(budget + 4096));
    });

    test('a payload past the hard ceiling stays a provider failure', () async {
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async =>
            _payloadOfBytes(patchbaySnapshotSnapshotByteCeiling + 4096),
        retention: _limits(
          snapshotBytes: patchbaySnapshotSnapshotByteCeiling,
          retainedBytes: patchbaySnapshotSnapshotByteCeiling,
        ),
      );

      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      expect(_rejection(refused)['code'], 'providerProtocolViolation');
      expect(
        _details(refused),
        containsPair('reason', 'snapshotPayloadInvalid'),
      );
      expect(_details(refused), containsPair('failure', 'payloadTooLarge'));
      expect(_details(refused), containsPair('limitKind', 'canonicalBytes'));
    });

    test('an over-budget sample leaves no negative byte count', () async {
      const int budget = patchbaySnapshotMinSnapshotBytes;
      Map<String, Object?> current = _payloadOfBytes(budget + 1);
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => current,
        retention: _limits(snapshotBytes: budget),
      );

      await handler.dispatchSnapshot();
      expect(handler.retainedCanonicalBytes, 0);
      expect(handler.hasSamplingInFlight, isFalse);

      current = _payloadOfBytes(budget);
      await handler.dispatchSnapshot();
      expect(handler.retainedCanonicalBytes, budget);
    });
  });

  group('total retained byte budget', () {
    test('evicts the oldest revisions until the total fits', () async {
      const int single = patchbaySnapshotMinSnapshotBytes;
      var counter = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => _payloadOfBytes(single, counter),
        retention: _limits(snapshotBytes: single, retainedBytes: single * 2),
      );

      for (counter = 1; counter <= 4; counter += 1) {
        await handler.dispatchSnapshot();
      }

      expect(handler.retainedRevisionCount, 2);
      expect(handler.retainedCanonicalBytes, single * 2);

      final Map<String, Object?> refused = await handler.dispatchSnapshot(
        <String, Object?>{'fromRevision': 1},
      );
      expect(_rejection(refused)['code'], 'snapshotRevisionUnavailable');
      expect(_details(refused), containsPair('retainedByteLimit', single * 2));
      expect(
        _details(refused),
        containsPair(
          'retainedRevisionLimit',
          patchbaySnapshotRevisionRetention,
        ),
      );
      expect(_details(refused), containsPair('oldestAvailableRevision', 4));
    });

    test('count and byte eviction can fire on the same commit', () async {
      const int single = patchbaySnapshotMinSnapshotBytes;
      var counter = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => _payloadOfBytes(single ~/ 4, counter),
        retention: _limits(
          revisions: 1,
          snapshotBytes: single,
          retainedBytes: single,
        ),
      );

      for (counter = 1; counter <= 3; counter += 1) {
        await handler.dispatchSnapshot();
      }

      expect(handler.retainedRevisionCount, 1);
      expect(handler.retainedCanonicalBytes, single ~/ 4);
    });

    test('the newest revision is never evicted by its own commit', () async {
      const int single = patchbaySnapshotMinSnapshotBytes;
      var counter = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => _payloadOfBytes(single, counter),
        retention: _limits(snapshotBytes: single, retainedBytes: single),
      );

      for (counter = 1; counter <= 3; counter += 1) {
        final Map<String, Object?> response = await handler.dispatchSnapshot();
        expect(response['snapshotRevision'], counter);
      }
      expect(handler.retainedRevisionCount, 1);
      expect(handler.retainedCanonicalBytes, single);
    });

    test('refreshing an unchanged revision does not double count', () async {
      const int single = patchbaySnapshotMinSnapshotBytes;
      Map<String, Object?> current = <String, Object?>{'a': 1, 'b': 2};
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => current,
        retention: _limits(snapshotBytes: single, retainedBytes: single * 4),
      );

      await handler.dispatchSnapshot();
      final int first = handler.retainedCanonicalBytes;
      // Same canonical content, different insertion order: the host refreshes
      // the retained frozen view in place rather than committing a revision.
      current = <String, Object?>{'b': 2, 'a': 1};
      await handler.dispatchSnapshot();
      await handler.dispatchSnapshot();

      expect(handler.retainedRevisionCount, 1);
      expect(handler.retainedCanonicalBytes, first);
    });
  });

  group('metadata', () {
    test('valid reads keep field order and add byte facts', () async {
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => <String, Object?>{'ready': true},
      );

      final Map<String, Object?> response = await handler.dispatchSnapshot();

      expect(response.keys.toList(), <String>[
        'ready',
        'schemaVersion',
        'snapshotRevision',
        'revisionSource',
        'factSource',
        'observedAt',
        'retainedRevisionLimit',
        'retainedByteLimit',
        'snapshotBytes',
      ]);
      expect(response['retainedByteLimit'], 8 * 1024 * 1024);
      expect(response['snapshotBytes'], utf8.encode('{"ready":true}').length);
    });

    test('VM Service and direct dispatch report the same metadata', () async {
      Map<String, Object?> metadataOf(Map<String, Object?> response) =>
          Map<String, Object?>.of(response)..remove('observedAt');

      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.budget',
        appInstanceId: 'instance-a',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
        snapshot: () async => <String, Object?>{'ready': true},
      );

      final Map<String, Object?> direct = await host.dispatchSnapshot();
      final ServiceExtensionResponse vm = await host.handleSnapshot(
        PatchbayServiceHost.snapshotMethod,
        const <String, String>{'isolateId': 'main'},
      );
      final Map<String, Object?> decoded =
          jsonDecode(vm.result!) as Map<String, Object?>;

      expect(metadataOf(decoded), metadataOf(direct));
      expect(decoded['retainedByteLimit'], direct['retainedByteLimit']);
      expect(decoded['snapshotBytes'], direct['snapshotBytes']);
    });
  });

  group('single flight sampling', () {
    test('concurrent callers share one provider sampling', () async {
      for (final int callers in <int>[1, 10, 100]) {
        final Completer<Map<String, Object?>> gate =
            Completer<Map<String, Object?>>();
        var calls = 0;
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: () {
            calls += 1;
            return gate.future;
          },
        );

        final List<Future<Map<String, Object?>>> reads =
            <Future<Map<String, Object?>>>[
              for (var index = 0; index < callers; index += 1)
                handler.dispatchSnapshot(),
            ];
        gate.complete(<String, Object?>{'value': 1});
        final List<Map<String, Object?>> responses = await Future.wait(reads);

        expect(calls, 1, reason: '$callers callers must share one sampling');
        expect(
          responses.map((Map<String, Object?> r) => r['snapshotRevision']),
          everyElement(1),
        );
        expect(handler.hasSamplingInFlight, isFalse);
      }
    });

    test('a shared sampling still answers each selection on its own', () async {
      final Completer<Map<String, Object?>> gate =
          Completer<Map<String, Object?>>();
      var calls = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () {
          calls += 1;
          return gate.future;
        },
      );

      final Future<Map<String, Object?>> left = handler.dispatchSnapshot(
        <String, Object?>{'path': 'left'},
      );
      final Future<Map<String, Object?>> right = handler.dispatchSnapshot(
        <String, Object?>{'path': 'right'},
      );
      gate.complete(<String, Object?>{'left': 1, 'right': 2});

      expect((await left)['selection'], <String, Object?>{
        'path': 'left',
        'found': true,
        'value': 1,
      });
      expect((await right)['selection'], <String, Object?>{
        'path': 'right',
        'found': true,
        'value': 2,
      });
      expect(calls, 1);
    });

    test('a slow waiter cannot extend another waiter budget', () async {
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async => <String, Object?>{'other': true},
      );
      final List<String> order = <String>[];

      Future<Map<String, Object?>> wait(String label, int timeoutMs) => handler
          .dispatchSnapshot(<String, Object?>{
            'path': 'missing',
            'until': 'exists',
            'timeoutMs': timeoutMs,
          })
          .then((Map<String, Object?> response) {
            order.add(label);
            return response;
          });

      final Future<Map<String, Object?>> quick = wait('quick', 60);
      final Future<Map<String, Object?>> slow = wait('slow', 600);
      final Map<String, Object?> quickResponse = await quick;
      final Map<String, Object?> slowResponse = await slow;

      expect(order, <String>['quick', 'slow']);
      expect(_rejection(quickResponse)['code'], 'snapshotWaitTimeout');
      expect(_details(quickResponse), containsPair('timeoutMs', 60));
      expect(_rejection(slowResponse)['code'], 'snapshotWaitTimeout');
      expect(_details(slowResponse), containsPair('timeoutMs', 600));
      expect(
        _details(slowResponse)['elapsedMs']! as int,
        greaterThan(_details(quickResponse)['elapsedMs']! as int),
      );
    });

    test('the flight clears as soon as it settles', () async {
      var calls = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async {
          calls += 1;
          return <String, Object?>{'value': calls};
        },
      );

      await handler.dispatchSnapshot();
      expect(handler.hasSamplingInFlight, isFalse);
      await handler.dispatchSnapshot();

      expect(calls, 2);
    });

    test('a failed sampling is shared then retried by the next call', () async {
      var calls = 0;
      var failing = true;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () async {
          calls += 1;
          await Future<void>.delayed(Duration.zero);
          if (failing) throw StateError('sampling failed');
          return <String, Object?>{'value': 1};
        },
      );

      final Future<Map<String, Object?>> first = handler.dispatchSnapshot();
      final Future<Map<String, Object?>> second = handler.dispatchSnapshot();
      final Map<String, Object?> firstResponse = await first;
      final Map<String, Object?> secondResponse = await second;

      expect(calls, 1);
      expect(_rejection(firstResponse)['code'], 'providerProtocolViolation');
      expect(
        _details(firstResponse),
        containsPair('reason', 'snapshotSourceFailed'),
      );
      expect(secondResponse, firstResponse);
      expect(handler.hasSamplingInFlight, isFalse);
      expect(handler.retainedCanonicalBytes, 0);

      failing = false;
      final Map<String, Object?> recovered = await handler.dispatchSnapshot();
      expect(calls, 2);
      expect(recovered['snapshotRevision'], 1);
    });

    test('an abandoned flight owner does not strand the batch', () async {
      final Completer<Map<String, Object?>> gate =
          Completer<Map<String, Object?>>();
      var calls = 0;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: () {
          calls += 1;
          if (calls == 1) return gate.future;
          return Future<Map<String, Object?>>.value(<String, Object?>{
            'value': calls,
          });
        },
      );

      // The owner starts the flight and then stops waiting for it.
      final Future<Map<String, Object?>> abandoned = handler.dispatchSnapshot();
      await expectLater(
        abandoned.timeout(const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expect(handler.hasSamplingInFlight, isTrue);

      final Future<Map<String, Object?>> joined = handler.dispatchSnapshot();
      expect(calls, 1);
      gate.complete(<String, Object?>{'value': 1});

      final Map<String, Object?> joinedResponse = await joined;
      expect(joinedResponse['snapshotRevision'], 1);
      expect(handler.hasSamplingInFlight, isFalse);
      // The abandoned owner still settles with the same shared answer, so a
      // timed-out waiter cannot strand the flight it opened.
      expect(await abandoned, joinedResponse);
      final Map<String, Object?> next = await handler.dispatchSnapshot();
      expect(calls, 2);
      expect(next['snapshotRevision'], 2);
    });
  });

  group('a sampling that never settles', () {
    /// A source whose first sampling never answers, and whose later samplings
    /// do. The `hang` future is deliberately never completed: a provider that
    /// wedges once is the failure the Proposal names as `source hang`, and it
    /// is the only shape that separates "shares the sampling in flight" from
    /// "is owned by it".
    ({Future<Map<String, Object?>> Function() source, List<int> calls})
    wedged() {
      final Completer<Map<String, Object?>> hang =
          Completer<Map<String, Object?>>();
      final List<int> calls = <int>[];
      return (
        calls: calls,
        source: () {
          calls.add(calls.length + 1);
          if (calls.length == 1) return hang.future;
          return Future<Map<String, Object?>>.value(<String, Object?>{
            'call': <String, Object?>{'session': 'device-${calls.length}'},
          });
        },
      );
    }

    Map<String, Object?> _waitRequest(int timeoutMs) => <String, Object?>{
      'path': 'call.session',
      'until': 'exists',
      'timeoutMs': timeoutMs,
    };

    test(
      'a joined waiter keeps its own budget when the sampling hangs',
      () async {
        final ({
          Future<Map<String, Object?>> Function() source,
          List<int> calls,
        })
        provider = wedged();
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: provider.source,
        );

        // The owner opens the sampling and is swallowed by it. Everything after
        // this point is a *joined* caller, and a joined caller's budget is its
        // own.
        unawaited(handler.dispatchSnapshot());
        expect(handler.hasSamplingInFlight, isTrue);
        expect(provider.calls.length, 1);

        final Stopwatch elapsed = Stopwatch()..start();
        final Map<String, Object?> response = await handler
            .dispatchSnapshot(_waitRequest(200))
            .timeout(const Duration(seconds: 5));
        elapsed.stop();

        expect(_rejection(response)['code'], 'snapshotWaitTimeout');
        expect(_details(response), containsPair('timeoutMs', 200));
        expect(
          _details(response)['polls'],
          0,
          reason: 'a sampling that never answered cannot be counted as a poll',
        );
        expect(
          elapsed.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason: 'the dead flight must not swallow the caller budget',
        );
        expect(provider.calls.length, 1);
      },
    );

    test('a joined VM Service waiter keeps its own budget too', () async {
      final ({Future<Map<String, Object?>> Function() source, List<int> calls})
      provider = wedged();
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.budget',
        appInstanceId: 'instance-hang',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
        snapshot: provider.source,
      );

      unawaited(host.dispatchSnapshot());
      expect(provider.calls.length, 1);

      final Stopwatch elapsed = Stopwatch()..start();
      final ServiceExtensionResponse vm = await host
          .handleSnapshot(PatchbayServiceHost.snapshotMethod, <String, String>{
            'isolateId': 'main',
            PatchbayServiceHost.snapshotRequestKey: jsonEncode(
              _waitRequest(200),
            ),
          })
          .timeout(const Duration(seconds: 5));
      elapsed.stop();

      final Map<String, Object?> decoded =
          jsonDecode(vm.result!) as Map<String, Object?>;
      expect(_rejection(decoded)['code'], 'snapshotWaitTimeout');
      expect(_details(decoded), containsPair('timeoutMs', 200));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('the dead flight is dropped so the next read can retry', () async {
      final ({Future<Map<String, Object?>> Function() source, List<int> calls})
      provider = wedged();
      final HostSnapshotHandler handler = HostSnapshotHandler(
        snapshotSource: provider.source,
      );

      unawaited(handler.dispatchSnapshot());
      await handler
          .dispatchSnapshot(_waitRequest(60))
          .timeout(const Duration(seconds: 5));

      // The Proposal's failure-injection node: a hung source leaves no
      // unfinished flight behind, and the next call retries.
      expect(handler.hasSamplingInFlight, isFalse);
      expect(handler.retainedCanonicalBytes, 0);

      final Map<String, Object?> plain = await handler
          .dispatchSnapshot()
          .timeout(const Duration(seconds: 5));
      expect(provider.calls.length, 2);
      expect(plain['snapshotRevision'], 1);

      final Map<String, Object?> selection = await handler
          .dispatchSnapshot(<String, Object?>{'path': 'call.session'})
          .timeout(const Duration(seconds: 5));
      expect(provider.calls.length, 3);
      expect(selection['selection'], <String, Object?>{
        'path': 'call.session',
        'found': true,
        'value': 'device-3',
      });
    });

    test('the dead flight is dropped for the VM Service side too', () async {
      final ({Future<Map<String, Object?>> Function() source, List<int> calls})
      provider = wedged();
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.budget',
        appInstanceId: 'instance-hang',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
        snapshot: provider.source,
      );

      unawaited(host.dispatchSnapshot());
      await host
          .handleSnapshot(PatchbayServiceHost.snapshotMethod, <String, String>{
            'isolateId': 'main',
            PatchbayServiceHost.snapshotRequestKey: jsonEncode(
              _waitRequest(60),
            ),
          })
          .timeout(const Duration(seconds: 5));

      final ServiceExtensionResponse vm = await host
          .handleSnapshot(
            PatchbayServiceHost.snapshotMethod,
            const <String, String>{'isolateId': 'main'},
          )
          .timeout(const Duration(seconds: 5));
      final Map<String, Object?> decoded =
          jsonDecode(vm.result!) as Map<String, Object?>;

      expect(provider.calls.length, 2);
      expect(decoded['snapshotRevision'], 1);
    });

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
        _waitRequest(5000),
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

  group('consumer reported revisions', () {
    test('an unchanged revision never touches the offered body', () async {
      var revision = 7;
      Map<String, Object?> body = <String, Object?>{'value': 1};
      final HostSnapshotHandler handler = HostSnapshotHandler(
        versionedSnapshotSource: () async =>
            PatchbaySnapshotSample(contentRevision: revision, body: body),
      );

      final Map<String, Object?> first = await handler.dispatchSnapshot();
      body = _UnreadableBody();
      final Map<String, Object?> second = await handler.dispatchSnapshot();

      expect(first['snapshotRevision'], 1);
      expect(first['revisionSource'], 'consumerReported');
      expect(second['snapshotRevision'], 1);
      expect(second['revisionSource'], 'consumerReported');
      expect(second['value'], 1);
      expect(second['snapshotBytes'], first['snapshotBytes']);
      expect(handler.retainedRevisionCount, 1);
      expect(revision, 7);
    });

    test('an advanced revision commits even when canonical is equal', () async {
      var revision = 1;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        versionedSnapshotSource: () async => PatchbaySnapshotSample(
          contentRevision: revision,
          body: <String, Object?>{'value': 1},
        ),
      );

      final Map<String, Object?> first = await handler.dispatchSnapshot();
      revision = 2;
      final Map<String, Object?> second = await handler.dispatchSnapshot();
      final Map<String, Object?> diff = await handler.dispatchSnapshot(
        <String, Object?>{'fromRevision': 1},
      );

      expect(first['snapshotRevision'], 1);
      expect(second['snapshotRevision'], 2);
      expect(diff['added'], isEmpty);
      expect(diff['changed'], isEmpty);
      expect(diff['removed'], isEmpty);
    });

    test('a regressed revision is a provider protocol violation', () async {
      var revision = 5;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        versionedSnapshotSource: () async => PatchbaySnapshotSample(
          contentRevision: revision,
          body: <String, Object?>{'value': 1},
        ),
      );

      await handler.dispatchSnapshot();
      final int retained = handler.retainedCanonicalBytes;
      revision = 4;
      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      expect(_rejection(refused)['code'], 'providerProtocolViolation');
      expect(_details(refused), containsPair('reason', 'revisionRegressed'));
      expect(_details(refused), containsPair('contentRevision', 4));
      expect(_details(refused), containsPair('previousContentRevision', 5));
      expect(handler.retainedCanonicalBytes, retained);
      expect(handler.hasSamplingInFlight, isFalse);
    });

    test('a negative revision is refused before anything is frozen', () async {
      final HostSnapshotHandler handler = HostSnapshotHandler(
        versionedSnapshotSource: () async => PatchbaySnapshotSample(
          contentRevision: -1,
          body: _UnreadableBody(),
        ),
      );

      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      expect(_rejection(refused)['code'], 'providerProtocolViolation');
      expect(_details(refused), containsPair('reason', 'revisionRegressed'));
      expect(handler.retainedCanonicalBytes, 0);
    });

    test('a rebuilt app instance restarts the revision agreement', () async {
      Future<PatchbaySnapshotSample> source() async => PatchbaySnapshotSample(
        contentRevision: 9,
        body: <String, Object?>{'value': 1},
      );
      final HostSnapshotHandler first = HostSnapshotHandler(
        versionedSnapshotSource: source,
      );
      final HostSnapshotHandler second = HostSnapshotHandler(
        versionedSnapshotSource: source,
      );

      expect((await first.dispatchSnapshot())['snapshotRevision'], 1);
      expect((await second.dispatchSnapshot())['snapshotRevision'], 1);
    });

    test('a versioned sample still crosses the payload budgets', () async {
      const int budget = patchbaySnapshotMinSnapshotBytes;
      var revision = 1;
      final HostSnapshotHandler handler = HostSnapshotHandler(
        versionedSnapshotSource: () async => PatchbaySnapshotSample(
          contentRevision: revision,
          body: _payloadOfBytes(revision == 1 ? budget : budget + 1),
        ),
        retention: _limits(snapshotBytes: budget),
      );

      await handler.dispatchSnapshot();
      revision = 2;
      final Map<String, Object?> refused = await handler.dispatchSnapshot();

      expect(_rejection(refused)['code'], 'snapshotPayloadTooLarge');
      expect(handler.retainedCanonicalBytes, budget);

      // The rejected revision was never accepted, so the same value may be
      // offered again without reading as a regression.
      final Map<String, Object?> retry = await handler.dispatchSnapshot();
      expect(_rejection(retry)['code'], 'snapshotPayloadTooLarge');
    });
  });

  group('legacy source compatibility', () {
    test('an unmodified legacy source keeps host observed revisions', () async {
      var value = 1;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.budget',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
        snapshot: () async => <String, Object?>{'value': value},
      );

      final Map<String, Object?> first = await host.dispatchSnapshot();
      final Map<String, Object?> repeated = await host.dispatchSnapshot();
      value = 2;
      final Map<String, Object?> changed = await host.dispatchSnapshot();

      expect(first['revisionSource'], 'hostObserved');
      expect(repeated['snapshotRevision'], 1);
      expect(changed['snapshotRevision'], 2);
    });

    test('a versioned source can be declared on the service host', () async {
      var revision = 1;
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.budget',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
        versionedSnapshot: () async => PatchbaySnapshotSample(
          contentRevision: revision,
          body: <String, Object?>{'value': revision},
        ),
      );

      final Map<String, Object?> first = await host.dispatchSnapshot();
      revision = 2;
      final Map<String, Object?> second = await host.dispatchSnapshot();

      expect(first['revisionSource'], 'consumerReported');
      expect(second['snapshotRevision'], 2);
      // DG-050-01 conclusion 3: the revision source is a per-response fact, so
      // no capability is declared for it.
      expect(
        PatchbayFeature.values.map((PatchbayFeature f) => f.name),
        isNot(contains('consumerReportedRevisions')),
      );
    });

    test('a host must declare exactly one snapshot source', () {
      expect(
        () => PatchbayServiceHost(
          applicationId: 'dev.patchbay.budget',
          registrar: (_, _) {},
          catalog: () async => const <String, Object?>{'commands': <Object?>[]},
          invoke: (_, _, String requestId) async =>
              PatchbayInvocation.accepted(requestId: requestId).toJson(),
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PatchbayServiceHost(
          applicationId: 'dev.patchbay.budget',
          registrar: (_, _) {},
          catalog: () async => const <String, Object?>{'commands': <Object?>[]},
          invoke: (_, _, String requestId) async =>
              PatchbayInvocation.accepted(requestId: requestId).toJson(),
          snapshot: () async => const <String, Object?>{},
          versionedSnapshot: () async => const PatchbaySnapshotSample(
            contentRevision: 0,
            body: <String, Object?>{},
          ),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
