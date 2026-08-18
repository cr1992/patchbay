import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

/// A host whose snapshot source is driven by the test.
///
/// [source] is called once per probe, so a wait test can make the App change
/// its mind between polls the way a real one does — which is the only way to
/// prove the loop re-reads instead of answering from its first look.
PatchbayServiceHost hostServing(
  Future<Map<String, Object?>> Function() source,
) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.test',
  registrar: (_, _) {},
  catalog: () async => const <String, Object?>{'commands': <Object?>[]},
  snapshot: source,
  invoke: (_, _, String requestId) async =>
      PatchbayInvocation.accepted(requestId: requestId).toJson(),
);

PatchbayServiceHost hostWith(Map<String, Object?> snapshot) =>
    hostServing(() async => snapshot);

Map<String, Object?> selectionOf(Map<String, Object?> response) =>
    response['selection']! as Map<String, Object?>;

Map<String, Object?> rejectionOf(Map<String, Object?> response) =>
    response['rejection']! as Map<String, Object?>;

Map<String, Object?> detailsOf(Map<String, Object?> response) =>
    rejectionOf(response)['details']! as Map<String, Object?>;

/// One plain selection of [path] against a host serving [snapshot].
Future<Map<String, Object?>> select_(
  Map<String, Object?> snapshot,
  String path,
) async => selectionOf(
  await hostWith(snapshot).dispatchSnapshot(<String, Object?>{'path': path}),
);

void main() {
  const Map<String, Object?> deviceSnapshot = <String, Object?>{
    'call': <String, Object?>{
      'session': <String, Object?>{
        'active': true,
        'peer': 'device-7',
        'endedAt': null,
      },
      'label': 'ready',
    },
    'battery': 41,
  };

  group('field selection', () {
    test(
      'a whole-snapshot read keeps consumer fields and adds revision metadata',
      () async {
        final Map<String, Object?> response = await hostWith(
          deviceSnapshot,
        ).dispatchSnapshot();
        expect(response, containsPair('call', deviceSnapshot['call']));
        expect(response, containsPair('battery', 41));
        expect(
          response,
          containsPair('schemaVersion', PatchbayServiceHost.schemaVersion),
        );
        expect(response, containsPair('snapshotRevision', 1));
        expect(response, containsPair('revisionSource', 'hostObserved'));
        expect(response, containsPair('factSource', 'appRecorded'));
        expect(response['observedAt'], isA<String>());
      },
    );

    test('selects one leaf field verbatim', () async {
      final Map<String, Object?> response = await hostWith(
        deviceSnapshot,
      ).dispatchSnapshot(<String, Object?>{'path': 'call.session.active'});

      expect(response['schemaVersion'], PatchbayServiceHost.schemaVersion);
      expect(selectionOf(response), <String, Object?>{
        'path': 'call.session.active',
        'found': true,
        'value': true,
      });
      // The point of the feature: the sibling subtree does not travel.
      expect(response.containsKey('call'), isFalse);
    });

    test('selects a subtree verbatim, without reshaping it', () async {
      final Map<String, Object?> response = await hostWith(
        deviceSnapshot,
      ).dispatchSnapshot(<String, Object?>{'path': 'call.session'});

      expect(selectionOf(response)['value'], <String, Object?>{
        'active': true,
        'peer': 'device-7',
        'endedAt': null,
      });
    });

    test('a protocol-owned envelope field is not addressable', () async {
      // The addressing root is the snapshot the App serves, not the response
      // envelope the host wraps around it. `schemaVersion` is the host's, and
      // answering it as though it were App state invents a field the consumer
      // never published — the operator cannot tell it apart from their own.
      final Map<String, Object?> response = await hostWith(
        deviceSnapshot,
      ).dispatchSnapshot(<String, Object?>{'path': 'schemaVersion'});

      expect(selectionOf(response), <String, Object?>{
        'path': 'schemaVersion',
        'found': false,
        'miss': 'missingKey',
      });
    });

    test('a consumer keeps its own key of that name', () async {
      // The flip side: the root is the consumer's map, so a consumer that
      // genuinely publishes `schemaVersion` gets *their* value. The host does
      // not blacklist words a consumer is allowed to own.
      final Map<String, Object?> response = await hostWith(
        const <String, Object?>{'schemaVersion': 999},
      ).dispatchSnapshot(<String, Object?>{'path': 'schemaVersion'});

      expect(selectionOf(response)['value'], 999);
    });

    test('a path that resolves to nothing says why', () async {
      Future<Object?> missOf(String path) async => selectionOf(
        await hostWith(
          deviceSnapshot,
        ).dispatchSnapshot(<String, Object?>{'path': path}),
      )['miss'];

      expect(await missOf('call.session.missing'), 'missingKey');
      expect(await missOf('call.session.endedAt'), 'nullValue');
      expect(await missOf('call.session.endedAt.deeper'), 'nullValue');
      // `label` is a string, so `label.x` has nothing to index into: that is a
      // path contradicting the snapshot, not a field that has not arrived.
      expect(await missOf('call.label.x'), 'notAnObject');
      expect(await missOf('battery.percent'), 'notAnObject');
    });

    test('a miss carries no value key at all', () async {
      final Map<String, Object?> response = await hostWith(
        deviceSnapshot,
      ).dispatchSnapshot(<String, Object?>{'path': 'call.missing'});

      expect(selectionOf(response), <String, Object?>{
        'path': 'call.missing',
        'found': false,
        'miss': 'missingKey',
      });
    });
  });

  group('a consumer that wraps its state in its own envelope', () {
    // The reference consumer in `example/` publishes a flat snapshot, and every
    // fixture in this repo does the same — which is exactly why an empty or
    // flat fixture cannot catch an addressing mistake. A real integration was
    // found publishing this shape instead: its own `admission` / `source`
    // bookkeeping beside a nested `snapshot` body. Anything asserting *where*
    // paths are rooted has to be written against a non-empty snapshot that
    // actually has a second level, or it passes for the wrong reason.
    const Map<String, Object?> enveloped = <String, Object?>{
      'admission': 'accepted',
      'source': 'appRecorded',
      'snapshot': <String, Object?>{
        'call': <String, Object?>{
          'session': <String, Object?>{'active': true},
        },
      },
    };

    test('its own keys are addressable, nesting and all', () async {
      Future<Map<String, Object?>> select(String path) async => selectionOf(
        await hostWith(
          enveloped,
        ).dispatchSnapshot(<String, Object?>{'path': path}),
      );

      // `admission` and `source` here are the *consumer's* keys, so they
      // resolve. They are not the host's envelope and must not be blacklisted:
      // the host does not get to decide which words a consumer may publish.
      expect((await select('admission'))['value'], 'accepted');
      expect((await select('snapshot.call.session.active'))['value'], true);
    });

    test('the host does not unwrap a consumer-chosen body key', () async {
      // `snapshot` is this consumer's own nesting, not a protocol field. If the
      // host silently rooted paths inside it, every flat consumer — the shipped
      // example included — would resolve against nothing.
      expect(
        (await select_(enveloped, 'call.session.active'))['miss'],
        'missingKey',
      );
      expect(
        (await select_(deviceSnapshot, 'call.session.active'))['value'],
        true,
      );
    });
  });

  group('a request that violates the contract', () {
    Future<Map<String, Object?>> refusing(Map<String, Object?> request) =>
        hostWith(deviceSnapshot).dispatchSnapshot(request);

    Future<void> expectRefused(Map<String, Object?> request) async {
      final Map<String, Object?> response = await refusing(request);
      expect(
        rejectionOf(response)['code'],
        'invalidSnapshotRequest',
        reason: jsonEncode(request),
      );
      expect(response['admission'], 'rejected');
      expect(response.containsKey('selection'), isFalse);
      expect(detailsOf(response)['reason'], isA<String>());
    }

    test('an unaddressable path is refused, not guessed at', () async {
      for (final String path in <String>[
        '',
        '.',
        'call.',
        '.call',
        'call..session',
        'call session',
        r'call$session',
      ]) {
        await expectRefused(<String, Object?>{'path': path});
      }
    });

    test('a wait without a budget is refused', () async {
      await expectRefused(<String, Object?>{
        'path': 'call.session.active',
        'until': 'exists',
      });
    });

    test('a budget outside the accepted range is refused', () async {
      for (final int timeoutMs in <int>[
        0,
        -1,
        patchbaySnapshotWaitCeiling.inMilliseconds + 1,
      ]) {
        await expectRefused(<String, Object?>{
          'path': 'call.session.active',
          'until': 'exists',
          'timeoutMs': timeoutMs,
        });
      }
    });

    test(
      'equals without a value, and a value without equals, are refused',
      () async {
        await expectRefused(<String, Object?>{
          'path': 'call.session.active',
          'until': 'equals',
          'timeoutMs': 100,
        });
        await expectRefused(<String, Object?>{
          'path': 'call.session.active',
          'until': 'exists',
          'value': true,
          'timeoutMs': 100,
        });
        await expectRefused(<String, Object?>{
          'path': 'call.session.active',
          'value': true,
        });
      },
    );

    test('a budget without a condition is refused', () async {
      await expectRefused(<String, Object?>{
        'path': 'call.session.active',
        'timeoutMs': 100,
      });
    });

    test('an undeclared key and an unknown condition are refused', () async {
      await expectRefused(<String, Object?>{
        'path': 'call.session.active',
        'depth': 2,
      });
      await expectRefused(<String, Object?>{
        'path': 'call.session.active',
        'until': 'matches',
        'timeoutMs': 100,
      });
      await expectRefused(const <String, Object?>{});
    });
  });

  group('server-side condition wait', () {
    /// A snapshot source that answers each probe from [answers] in order,
    /// repeating the last one once the list runs out.
    Future<Map<String, Object?>> Function() serving(
      List<Map<String, Object?>> answers,
      List<int> probes,
    ) {
      return () async {
        final int index = probes.length;
        probes.add(index);
        return answers[index < answers.length ? index : answers.length - 1];
      };
    }

    test('exists is observed on a later poll, not only on the first', () async {
      final List<int> probes = <int>[];
      final Map<String, Object?> response =
          await hostServing(
            serving(<Map<String, Object?>>[
              const <String, Object?>{'call': <String, Object?>{}},
              const <String, Object?>{'call': <String, Object?>{}},
              const <String, Object?>{
                'call': <String, Object?>{'session': 'device-7'},
              },
            ], probes),
          ).dispatchSnapshot(<String, Object?>{
            'path': 'call.session',
            'until': 'exists',
            'timeoutMs': 5000,
          });

      expect(selectionOf(response), <String, Object?>{
        'path': 'call.session',
        'found': true,
        'value': 'device-7',
      });
      final Map<String, Object?> wait =
          response['wait']! as Map<String, Object?>;
      expect(wait['outcome'], 'observed');
      expect(wait['condition'], 'exists');
      expect(wait['polls'], 3);
      expect(wait['timeoutMs'], 5000);
      expect(
        wait['pollIntervalMs'],
        patchbaySnapshotPollInterval.inMilliseconds,
      );
      expect(response['admission'], isNull);
    });

    test('an already-true condition answers without waiting a poll', () async {
      final Map<String, Object?> response = await hostWith(deviceSnapshot)
          .dispatchSnapshot(<String, Object?>{
            'path': 'call.session.active',
            'until': 'equals',
            'value': true,
            'timeoutMs': 5000,
          });

      final Map<String, Object?> wait =
          response['wait']! as Map<String, Object?>;
      expect(wait['polls'], 1);
      expect(
        wait['elapsedMs'],
        lessThan(patchbaySnapshotPollInterval.inMilliseconds),
      );
    });

    test('equals compares JSON structurally, not by identity', () async {
      Future<Object?> outcomeFor(Object? expected) async {
        final Map<String, Object?> response =
            await hostWith(const <String, Object?>{
              'ports': <String, Object?>{
                'open': <Object?>[1, 2],
                'meta': <String, Object?>{'a': 1},
              },
            }).dispatchSnapshot(<String, Object?>{
              'path': 'ports.open',
              'until': 'equals',
              'value': expected,
              'timeoutMs': 60,
            });
        return response['wait'] == null
            ? rejectionOf(response)['code']
            : (response['wait']! as Map<String, Object?>)['outcome'];
      }

      expect(await outcomeFor(<Object?>[1, 2]), 'observed');
      expect(await outcomeFor(<Object?>[2, 1]), 'snapshotWaitTimeout');
      expect(await outcomeFor(<Object?>[1]), 'snapshotWaitTimeout');
    });

    test('absent is observed for a missing key and for a null value', () async {
      for (final String path in <String>[
        'call.session.missing',
        'call.session.endedAt',
      ]) {
        final Map<String, Object?> response = await hostWith(deviceSnapshot)
            .dispatchSnapshot(<String, Object?>{
              'path': path,
              'until': 'absent',
              'timeoutMs': 5000,
            });
        expect(
          (response['wait']! as Map<String, Object?>)['outcome'],
          'observed',
          reason: path,
        );
      }
    });

    test(
      'absent is not satisfied by a path that contradicts the shape',
      () async {
        // `call.label` is a string. Reporting "absent" here would let a mistyped
        // path answer success; the timeout details name the real reason instead.
        final Map<String, Object?> response = await hostWith(deviceSnapshot)
            .dispatchSnapshot(<String, Object?>{
              'path': 'call.label.x',
              'until': 'absent',
              'timeoutMs': 60,
            });

        expect(rejectionOf(response)['code'], 'snapshotWaitTimeout');
        expect(
          (detailsOf(response)['observed']! as Map<String, Object?>)['miss'],
          'notAnObject',
        );
      },
    );

    test('a wait on an unaddressable root names what is there', () async {
      // The reported failure mode: a path whose very first segment does not
      // exist burns the whole budget and reports a timeout, which reads like
      // "the condition has not happened yet" when it is really "this path can
      // never resolve here". Naming the top-level keys turns a silent false
      // negative into a one-glance fix, and only the host knows them.
      final Map<String, Object?> response =
          await hostWith(const <String, Object?>{
            'admission': 'accepted',
            'source': 'appRecorded',
            'snapshot': <String, Object?>{'call': <String, Object?>{}},
          }).dispatchSnapshot(<String, Object?>{
            'path': 'call.session.active',
            'until': 'exists',
            'timeoutMs': 60,
          });

      expect(rejectionOf(response)['code'], 'snapshotWaitTimeout');
      expect(
        detailsOf(response)['availableKeys'],
        <String>['admission', 'snapshot', 'source'],
        reason: 'sorted, so the hint is stable enough to assert on',
      );
    });

    test('a wait that merely has not happened yet keeps quiet', () async {
      // The hint is for an unaddressable *root* only. A path that resolves part
      // way is a field that has not arrived, and listing top-level keys there
      // would be noise pointing at the wrong thing.
      final Map<String, Object?> response = await hostWith(deviceSnapshot)
          .dispatchSnapshot(<String, Object?>{
            'path': 'call.session.peerName',
            'until': 'exists',
            'timeoutMs': 60,
          });

      expect(rejectionOf(response)['code'], 'snapshotWaitTimeout');
      expect(detailsOf(response).containsKey('availableKeys'), isFalse);
    });

    test(
      'a source slower than the budget times out, it does not answer late',
      () async {
        // The condition holds on the very first probe — but reading it took six
        // times the declared budget. The budget is a hard cap on the whole
        // request, not merely on the gaps between probes: answering `observed`
        // here hands back a success the caller already stopped waiting for, and
        // on the CLI side it is the difference between exit 0 and exit 5.
        final Map<String, Object?> response =
            await hostServing(() async {
              await Future<void>.delayed(const Duration(milliseconds: 60));
              return deviceSnapshot;
            }).dispatchSnapshot(<String, Object?>{
              'path': 'call.session.active',
              'until': 'equals',
              'value': true,
              'timeoutMs': 10,
            });

        expect(response['admission'], 'rejected');
        expect(rejectionOf(response)['code'], 'snapshotWaitTimeout');
        expect(response.containsKey('wait'), isFalse);
        expect(response.containsKey('selection'), isFalse);
        final Map<String, Object?> details = detailsOf(response);
        expect(details['timeoutMs'], 10);
        expect(details['elapsedMs'], greaterThanOrEqualTo(60));
        expect(
          details['polls'],
          1,
          reason: 'an overrun must not buy another probe',
        );
        // The last resolution still travels: "the field was already what you
        // asked for, the read was just too slow" is what separates a slow
        // snapshot source from a condition that is never going to hold.
        expect(details['observed'], <String, Object?>{
          'path': 'call.session.active',
          'found': true,
          'value': true,
        });
      },
    );

    test(
      'a condition that never holds is rejected with what it did see',
      () async {
        final Map<String, Object?> response = await hostWith(deviceSnapshot)
            .dispatchSnapshot(<String, Object?>{
              'path': 'call.session.active',
              'until': 'equals',
              'value': false,
              'timeoutMs': 150,
            });

        expect(response['admission'], 'rejected');
        expect(rejectionOf(response)['code'], 'snapshotWaitTimeout');
        expect(response.containsKey('selection'), isFalse);
        final Map<String, Object?> details = detailsOf(response);
        expect(details['path'], 'call.session.active');
        expect(details['condition'], 'equals');
        expect(details['timeoutMs'], 150);
        expect(details['elapsedMs'], greaterThanOrEqualTo(150));
        expect(details['polls'], greaterThan(1));
        expect(details['observed'], <String, Object?>{
          'path': 'call.session.active',
          'found': true,
          'value': true,
        });
      },
    );

    test(
      'the wait is bounded by the declared budget, not by the interval',
      () async {
        final Stopwatch elapsed = Stopwatch()..start();
        await hostWith(deviceSnapshot).dispatchSnapshot(<String, Object?>{
          'path': 'call.session.absent',
          'until': 'exists',
          'timeoutMs': 40,
        });
        elapsed.stop();

        expect(
          elapsed.elapsed,
          lessThan(patchbaySnapshotPollInterval * 2),
          reason: 'a budget shorter than one interval must not round up to one',
        );
      },
    );
  });

  group('a snapshot source that fails', () {
    test('is answered, not thrown, on a whole-snapshot read', () async {
      final Map<String, Object?> response = await hostServing(
        () async => throw StateError('adapter not ready'),
      ).dispatchSnapshot();

      expect(response['admission'], 'rejected');
      expect(rejectionOf(response)['code'], 'providerProtocolViolation');
      expect(detailsOf(response)['reason'], 'snapshotSourceFailed');
      // The type, never the message: a consumer error string is App data.
      expect(detailsOf(response)['error'], 'StateError');
      expect(jsonEncode(response), isNot(contains('adapter not ready')));
    });

    test(
      'ends a wait with its own envelope instead of being retried',
      () async {
        var probes = 0;
        final Map<String, Object?> response =
            await hostServing(() async {
              probes += 1;
              if (probes == 1) return const <String, Object?>{'ready': false};
              throw StateError('adapter went away');
            }).dispatchSnapshot(<String, Object?>{
              'path': 'ready',
              'until': 'equals',
              'value': true,
              'timeoutMs': 5000,
            });

        expect(rejectionOf(response)['code'], 'providerProtocolViolation');
        expect(detailsOf(response)['reason'], 'snapshotSourceFailed');
        expect(probes, 2);
      },
    );
  });

  group('the VM Service handler', () {
    Future<Map<String, Object?>> call(Map<String, String> parameters) async {
      final ServiceExtensionResponse response = await hostWith(
        deviceSnapshot,
      ).handleSnapshot(PatchbayServiceHost.snapshotMethod, parameters);
      return response.result == null
          ? <String, Object?>{'errorCode': response.errorCode}
          : Map<String, Object?>.from(
              jsonDecode(response.result!) as Map<String, dynamic>,
            );
    }

    test('routes an encoded request through the same decoder', () async {
      final Map<String, Object?> response = await call(<String, String>{
        'isolateId': 'isolates/1',
        PatchbayServiceHost.snapshotRequestKey: jsonEncode(
          PatchbaySnapshotRequest(path: 'call.session.peer').toWire().toJson(),
        ),
      });

      expect(selectionOf(response)['value'], 'device-7');
    });

    test(
      'routes the separate diff request through the shared dispatcher',
      () async {
        var value = 1;
        final PatchbayServiceHost host = hostServing(
          () async => <String, Object?>{'value': value},
        );
        await host.handleSnapshot(
          PatchbayServiceHost.snapshotMethod,
          const <String, String>{'isolateId': 'isolates/1'},
        );
        value = 2;
        final ServiceExtensionResponse wire = await host.handleSnapshot(
          PatchbayServiceHost.snapshotMethod,
          <String, String>{
            'isolateId': 'isolates/1',
            PatchbayServiceHost.snapshotRequestKey: jsonEncode(
              PatchbaySnapshotDiffRequest(fromRevision: 1).toWire().toJson(),
            ),
          },
        );
        final Map<String, Object?> response = Map<String, Object?>.from(
          jsonDecode(wire.result!) as Map<String, dynamic>,
        );
        expect(response['snapshotRevision'], 2);
        expect(response['changed'], <Object?>[
          <String, Object?>{'path': '/value', 'before': 1, 'after': 2},
        ]);
      },
    );

    test('still serves the whole snapshot without a request', () async {
      expect(
        await call(const <String, String>{'isolateId': 'isolates/1'}),
        containsPair('battery', 41),
      );
    });

    test('refuses an unknown parameter and a non-object request', () async {
      expect(
        await call(const <String, String>{'depth': '2'}),
        containsPair('errorCode', ServiceExtensionResponse.invalidParams),
      );
      expect(
        await call(const <String, String>{
          PatchbayServiceHost.snapshotRequestKey: 'not json',
        }),
        containsPair('errorCode', ServiceExtensionResponse.invalidParams),
      );
      expect(
        await call(const <String, String>{
          PatchbayServiceHost.snapshotRequestKey: '["call"]',
        }),
        containsPair('errorCode', ServiceExtensionResponse.invalidParams),
      );
    });
  });

  group('the request type', () {
    test('round-trips through the wire without changing meaning', () {
      final PatchbaySnapshotRequest request = PatchbaySnapshotRequest(
        path: 'call.session.active',
        until: PatchbaySnapshotCondition.equals,
        value: true,
        timeout: const Duration(seconds: 3),
      );

      final PatchbaySnapshotRequest decoded = PatchbaySnapshotRequest.fromWire(
        PatchbaySnapshotRequestWire.fromJson(request.toWire().toJson()),
      );

      expect(decoded.path, request.path);
      expect(decoded.until, PatchbaySnapshotCondition.equals);
      expect(decoded.value, true);
      expect(decoded.timeout, const Duration(seconds: 3));
      expect(decoded.isWait, isTrue);
    });

    test('a plain selection omits the wait fields on the wire', () {
      expect(
        PatchbaySnapshotRequest(path: 'battery').toWire().toJson(),
        <String, Object?>{'path': 'battery'},
      );
    });

    test('every shape rule fails as a FormatException', () {
      expect(
        () => PatchbaySnapshotRequest(path: 'a..b'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PatchbaySnapshotRequest(
          path: 'a.b',
          until: PatchbaySnapshotCondition.exists,
          timeout: patchbaySnapshotWaitCeiling + const Duration(seconds: 1),
        ),
        throwsA(isA<FormatException>()),
        reason: 'a range failure must not escape as an ArgumentError',
      );
    });
  });
}
