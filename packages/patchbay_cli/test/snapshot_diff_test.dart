import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_transport/patchbay_transport.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

Future<({int exitCode, Map<String, Object?> response})> _run(
  FakePatchbayClient client,
) async {
  final StringBuffer out = StringBuffer();
  final int exitCode = await runPatchbayCli(
    <String>['--json', 'snapshot', 'diff', '--from', '7'],
    connect: (_) async => client,
    output: out,
    errorOutput: StringBuffer(),
  );
  return (
    exitCode: exitCode,
    response: jsonDecode(out.toString()) as Map<String, Object?>,
  );
}

FakePatchbayClient _client(Map<String, Object?> identity) => FakePatchbayClient(
  commands: const <Map<String, Object?>>[],
  handle: (_, _) async => fakeCommandNotRegistered(),
  identityData: identity,
  snapshotData: const <String, Object?>{'ready': true, 'schemaVersion': 1},
);

void main() {
  test('declared host receives the separate diff request', () async {
    final FakePatchbayClient client = _client(<String, Object?>{
      ...legacyFakeIdentity,
      'features': <String>[PatchbayFeature.snapshotRevisionDiff.name],
    });
    final result = await _run(client);
    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(client.snapshotDiffRequests, <int>[7]);
    expect(client.snapshotRequests, isEmpty);
    expect(result.response['revisionSource'], 'hostObserved');
  });

  test(
    'legacy host gets an explicit full snapshot without a diff request',
    () async {
      final FakePatchbayClient client = _client(legacyFakeIdentity);
      final result = await _run(client);
      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(client.snapshotDiffRequests, isEmpty);
      expect(client.snapshotRequests, <Object?>[null]);
      expect(result.response['snapshotMode'], 'legacyFull');
      expect(result.response['ready'], isTrue);
      expect(
        result.response['notice'],
        contains('without sending a diff request'),
      );
    },
  );

  test(
    'direct transport forwards the new request to the same dispatcher',
    () async {
      var value = 1;
      final PatchbayServiceHost service = PatchbayServiceHost(
        applicationId: 'dev.patchbay.direct-diff',
        appInstanceId: 'direct-diff-instance',
        registrar: (_, _) {},
        catalog: () async => const <String, Object?>{'commands': <Object?>[]},
        snapshot: () async => <String, Object?>{'value': value},
        invoke: (_, _, String requestId) async =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
      );
      final PatchbayDirectHost host = PatchbayDirectHost(
        handlers: PatchbayDirectHandlers(
          identity: () async => const PatchbayDirectIdentity(
            schemaVersion: 1,
            applicationId: 'dev.patchbay.direct-diff',
            appInstanceId: 'direct-diff-instance',
          ),
          catalog: service.dispatchCatalog,
          snapshot: service.dispatchSnapshot,
          invoke: service.dispatchInvoke,
        ),
      );
      final PatchbayDirectSession session = await host.start();
      addTearDown(() => host.stop());
      final PatchbayDirectConnection connection = PatchbayDirectConnection(
        endpoint: session.endpoint,
        bearerToken: session.bearerToken,
        schemaVersion: 1,
        applicationId: 'dev.patchbay.direct-diff',
        appInstanceId: 'direct-diff-instance',
      );
      addTearDown(connection.close);
      await connection.snapshot();
      value = 2;
      final Map<String, Object?> response = await connection.snapshotDiff(
        fromRevision: 1,
      );
      expect(response['snapshotRevision'], 2);
      expect(response['changed'], <Object?>[
        <String, Object?>{'path': '/value', 'before': 1, 'after': 2},
      ]);
    },
  );
}
