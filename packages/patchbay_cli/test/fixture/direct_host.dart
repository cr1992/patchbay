import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';

Future<void> main() async {
  const PatchbayDirectIdentity identity = PatchbayDirectIdentity(
    schemaVersion: 1,
    applicationId: 'dev.patchbay.direct.fixture',
    appInstanceId: 'direct-fixture-instance',
  );
  final PatchbayDirectHost host = PatchbayDirectHost(
    handlers: PatchbayDirectHandlers(
      identity: () async => identity,
      catalog: () async => <String, Object?>{
        'schemaVersion': 1,
        'commands': <Object?>[
          <String, Object?>{'name': 'navigation.current'},
          <String, Object?>{'name': 'fixture.reject'},
          <String, Object?>{'name': 'fixture.slow'},
        ],
        'uiTargets': const <Object?>[],
      },
      snapshot: () async => <String, Object?>{
        'schemaVersion': 1,
        'source': 'appRecorded',
      },
      invoke: (command, arguments, requestId) async {
        if (command == 'fixture.slow') {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (command == 'navigation.current') {
          return <String, Object?>{
            'schemaVersion': 1,
            'admission': 'accepted',
            'requestId': requestId,
            'payload': <String, Object?>{
              'outcome': 'observed',
              'source': 'appRecorded',
              'navigationRevision': 1,
              'destinationId': 'home',
            },
          };
        }
        return <String, Object?>{
          'schemaVersion': 1,
          'admission': 'rejected',
          'requestId': requestId,
          'rejection': <String, Object?>{
            'code': command == 'fixture.reject'
                ? 'featureUnavailable'
                : 'commandNotRegistered',
          },
        };
      },
    ),
  );
  final PatchbayDirectSession session = await host.start();
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'endpoint': session.endpoint.toString(),
      'token': session.bearerToken,
    }),
  );
  await stdout.flush();
  ProcessSignal.sigterm.watch().listen((_) async {
    await host.stop();
    exit(0);
  });
  Timer.periodic(const Duration(hours: 1), (_) {});
}
