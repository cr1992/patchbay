import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

PatchbayServiceHost _host(Future<Map<String, Object?>> Function() source) =>
    PatchbayServiceHost(
      applicationId: 'dev.patchbay.diff',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{'commands': <Object?>[]},
      snapshot: source,
      invoke: (_, _, String requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

Map<String, Object?> _request(int revision) =>
    PatchbaySnapshotDiffRequest(fromRevision: revision).toWire().toJson();

void main() {
  test('same canonical content keeps one host-observed revision', () async {
    var reverse = false;
    final PatchbayServiceHost host = _host(() async {
      reverse = !reverse;
      return reverse
          ? <String, Object?>{'b': 2, 'a': 1}
          : <String, Object?>{'a': 1, 'b': 2};
    });

    final Map<String, Object?> first = await host.dispatchSnapshot();
    final Map<String, Object?> second = await host.dispatchSnapshot();

    expect(first['snapshotRevision'], 1);
    expect(second['snapshotRevision'], 1);
    expect(second['revisionSource'], 'hostObserved');
    expect(second['factSource'], 'appRecorded');
  });

  test('reports deterministic added changed and removed paths', () async {
    var current = <String, Object?>{
      'same': true,
      'nested': <String, Object?>{'old': 1, 'gone': 'x'},
    };
    final PatchbayServiceHost host = _host(() async => current);
    await host.dispatchSnapshot();
    current = <String, Object?>{
      'same': true,
      'nested': <String, Object?>{'old': 2, 'new': 'y'},
    };

    final Map<String, Object?> diff = await host.dispatchSnapshot(_request(1));

    expect(diff['snapshotRevision'], 2);
    expect(diff['fromRevision'], 1);
    expect(diff['added'], <Object?>[
      <String, Object?>{'path': '/nested/new', 'after': 'y'},
    ]);
    expect(diff['changed'], <Object?>[
      <String, Object?>{'path': '/nested/old', 'before': 1, 'after': 2},
    ]);
    expect(diff['removed'], <Object?>[
      <String, Object?>{'path': '/nested/gone', 'before': 'x'},
    ]);
  });

  test('unchanged diff is empty', () async {
    final PatchbayServiceHost host = _host(
      () async => <String, Object?>{'ready': true},
    );
    await host.dispatchSnapshot();
    final Map<String, Object?> diff = await host.dispatchSnapshot(_request(1));
    expect(diff['snapshotRevision'], 1);
    expect(diff['added'], isEmpty);
    expect(diff['changed'], isEmpty);
    expect(diff['removed'], isEmpty);
  });

  test(
    'a diff cannot invent its own baseline on a fresh app instance',
    () async {
      final PatchbayServiceHost host = _host(
        () async => <String, Object?>{'ready': true},
      );
      final Map<String, Object?> response = await host.dispatchSnapshot(
        _request(1),
      );
      expect(response['admission'], 'rejected');
      expect(
        (response['rejection']! as Map<String, Object?>)['code'],
        'snapshotRevisionUnavailable',
      );
    },
  );

  test('selector reads advance the same revision space', () async {
    var value = 1;
    final PatchbayServiceHost host = _host(
      () async => <String, Object?>{'value': value},
    );
    final Map<String, Object?> first = await host.dispatchSnapshot(
      <String, Object?>{'path': 'value'},
    );
    value = 2;
    final Map<String, Object?> second = await host.dispatchSnapshot(
      <String, Object?>{'path': 'value'},
    );
    expect(first['snapshotRevision'], 1);
    expect(second['snapshotRevision'], 2);
    final Map<String, Object?> diff = await host.dispatchSnapshot(_request(1));
    expect(diff['changed'], <Object?>[
      <String, Object?>{'path': '/value', 'before': 1, 'after': 2},
    ]);
  });

  test('a new app instance restarts revision numbering visibly', () async {
    final PatchbayServiceHost first = PatchbayServiceHost(
      applicationId: 'dev.patchbay.diff',
      appInstanceId: 'instance-a',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{'commands': <Object?>[]},
      snapshot: () async => <String, Object?>{'value': 1},
      invoke: (_, _, String requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );
    final PatchbayServiceHost second = PatchbayServiceHost(
      applicationId: 'dev.patchbay.diff',
      appInstanceId: 'instance-b',
      registrar: (_, _) {},
      catalog: () async => const <String, Object?>{'commands': <Object?>[]},
      snapshot: () async => <String, Object?>{'value': 2},
      invoke: (_, _, String requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );
    expect((await first.dispatchSnapshot())['snapshotRevision'], 1);
    expect((await second.dispatchSnapshot())['snapshotRevision'], 1);
    expect(first.identityResponse()['appInstanceId'], 'instance-a');
    expect(second.identityResponse()['appInstanceId'], 'instance-b');
  });

  test('evicted revision fails with a stable code', () async {
    var value = 0;
    final PatchbayServiceHost host = _host(
      () async => <String, Object?>{'value': value},
    );
    await host.dispatchSnapshot();
    for (value = 1; value <= patchbaySnapshotRevisionRetention; value += 1) {
      await host.dispatchSnapshot();
    }
    final Map<String, Object?> response = await host.dispatchSnapshot(
      _request(1),
    );
    expect(response['admission'], 'rejected');
    expect(
      (response['rejection']! as Map<String, Object?>)['code'],
      'snapshotRevisionUnavailable',
    );
  });

  test('change count budget fails closed without a partial diff', () async {
    var current = <String, Object?>{'seed': true};
    final PatchbayServiceHost host = _host(() async => current);
    await host.dispatchSnapshot();
    current = <String, Object?>{
      for (var index = 0; index <= patchbaySnapshotDiffMaxChanges; index += 1)
        'key-$index': index,
    };
    final Map<String, Object?> response = await host.dispatchSnapshot(
      _request(1),
    );
    expect(response['admission'], 'rejected');
    expect(
      (response['rejection']! as Map<String, Object?>)['code'],
      'snapshotDiffLimitExceeded',
    );
    expect(response.containsKey('added'), isFalse);
  });

  test('encoded byte budget fails closed without a partial diff', () async {
    var current = <String, Object?>{'value': 'small'};
    final PatchbayServiceHost host = _host(() async => current);
    await host.dispatchSnapshot();
    current = <String, Object?>{
      'value': 'x' * patchbaySnapshotDiffMaxEncodedBytes,
    };
    final Map<String, Object?> response = await host.dispatchSnapshot(
      _request(1),
    );
    expect(response['admission'], 'rejected');
    expect(
      (response['rejection']! as Map<String, Object?>)['code'],
      'snapshotDiffLimitExceeded',
    );
    expect(response.containsKey('changed'), isFalse);
  });
}
