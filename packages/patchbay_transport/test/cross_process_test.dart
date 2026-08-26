import 'dart:convert';
import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'client reaches a host in a separate process over a real socket',
    () async {
      final Process process = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'test/fixture/host.dart'],
        workingDirectory: Directory.current.path,
      );
      final Stream<String> lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final String firstLine = await lines.first.timeout(
        const Duration(seconds: 10),
      );
      final Map<String, Object?> start = Map<String, Object?>.from(
        jsonDecode(firstLine) as Map<String, dynamic>,
      );
      final Map<String, Object?> identityJson = Map<String, Object?>.from(
        start['identity']! as Map<String, dynamic>,
      );
      final PatchbayDirectSession session = PatchbayDirectSession.create(
        endpoint: Uri.parse(start['endpoint']! as String),
        bearerToken: start['bearerToken']! as String,
        expiresAt: DateTime.parse(start['expiresAt']! as String),
        identity: PatchbayDirectIdentity(
          schemaVersion: identityJson['schemaVersion']! as int,
          applicationId: identityJson['applicationId']! as String,
          appInstanceId: identityJson['appInstanceId']! as String,
        ),
        lanExposure: PatchbayLanExposure.disabled,
      );
      final PatchbayDirectClient client = PatchbayDirectClient(
        session: session,
      );
      try {
        expect(await client.identity(), <String, Object?>{
          ...identityJson,
          'features': const <String>[],
        });
        final Map<String, Object?> snapshot = await client.snapshot();
        expect(snapshot['source'], 'child-process');
        expect(snapshot['pid'], isA<int>());
        expect(
          await client.invoke(
            command: 'fixture.echo',
            arguments: <String, Object?>{'message': 'hello'},
            requestId: 'cross-process-1',
          ),
          <String, Object?>{
            'command': 'fixture.echo',
            'arguments': <String, Object?>{'message': 'hello'},
            'requestId': 'cross-process-1',
          },
        );
      } finally {
        client.close(force: true);
        process.stdin.writeln('stop');
        await process.stdin.flush();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
    },
  );
}
