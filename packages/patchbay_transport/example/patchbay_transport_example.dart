import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';

Future<void> main() async {
  const identity = PatchbayDirectIdentity(
    schemaVersion: 1,
    applicationId: 'com.example.app',
    appInstanceId: 'example-instance',
  );
  final host = PatchbayDirectHost(
    handlers: PatchbayDirectHandlers(
      identity: () async => identity,
      catalog: () async => const <String, Object?>{'commands': <Object?>[]},
      snapshot: ([request]) async => const <String, Object?>{},
      invoke: (command, arguments, requestId) async => <String, Object?>{
        'requestId': requestId,
        'accepted': true,
      },
    ),
  );

  final session = await host.start();
  final client = PatchbayDirectClient(session: session);
  try {
    stdout.writeln(await client.identity());
  } finally {
    client.close(force: true);
    await host.stop();
  }
}
