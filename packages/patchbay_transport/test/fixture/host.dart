import 'dart:convert';
import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';

Future<void> main() async {
  const PatchbayDirectIdentity identity = PatchbayDirectIdentity(
    schemaVersion: 1,
    applicationId: 'dev.patchbay.transport.fixture',
    appInstanceId: 'fixture-instance',
  );
  final PatchbayDirectHost host = PatchbayDirectHost(
    handlers: PatchbayDirectHandlers(
      identity: () async => identity,
      catalog: () async => <String, Object?>{
        'commands': <Object?>['fixture.echo'],
      },
      snapshot: () async => <String, Object?>{
        'pid': pid,
        'source': 'child-process',
      },
      invoke:
          (
            String command,
            Map<String, Object?> arguments,
            String requestId,
          ) async => <String, Object?>{
            'command': command,
            'arguments': arguments,
            'requestId': requestId,
          },
    ),
  );
  final PatchbayDirectSession session = await host.start();
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'endpoint': session.endpoint.toString(),
      'bearerToken': session.bearerToken,
      'expiresAt': session.expiresAt.toIso8601String(),
      'identity': session.identity.toJson(),
    }),
  );
  await stdin.first;
  await host.stop();
}
