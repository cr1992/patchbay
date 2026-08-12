import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'connects to a real VM Service extension host',
    () async {
      final Process host =
          await Process.start(Platform.resolvedExecutable, <String>[
            '--enable-vm-service=0',
            '--disable-service-auth-codes',
            'test/fixture/host.dart',
          ], workingDirectory: Directory.current.path);
      addTearDown(() async {
        host.kill();
        await host.exitCode;
      });

      final Completer<Uri> serviceUri = Completer<Uri>();
      void observe(String line) {
        final RegExpMatch? match = RegExp(
          r'(https?://[^\s]+)',
        ).firstMatch(line);
        if (match != null && !serviceUri.isCompleted) {
          serviceUri.complete(Uri.parse(match.group(1)!));
        }
      }

      final StreamSubscription<String> stdout = host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      final StreamSubscription<String> stderr = host.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      addTearDown(stdout.cancel);
      addTearDown(stderr.cancel);

      final Uri uri = await serviceUri.future.timeout(
        const Duration(seconds: 15),
      );
      final PatchbayConnection connection = await PatchbayConnection.connect(
        uri,
      );
      addTearDown(connection.close);

      final Map<String, Object?> identity = await connection.identity();
      expect(identity['applicationId'], 'dev.patchbay.fixture');
      expect(identity['appInstanceId'], 'fixture-instance');

      final Map<String, Object?> snapshot = await connection.snapshot();
      expect(snapshot['source'], 'fixture');

      final ProcessResult cli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--ws-uri',
          uri.toString(),
          '--json',
          'snapshot',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(cli.exitCode, 0, reason: cli.stderr.toString());
      expect(
        (jsonDecode(cli.stdout.toString()) as Map<String, Object?>)['source'],
        'fixture',
      );

      final Map<String, Object?> invocation = await connection.invoke(
        command: 'device.list',
        arguments: const <String, Object?>{},
      );
      expect(invocation['admission'], 'rejected');
      expect(
        (invocation['rejection']! as Map<String, Object?>)['code'],
        'commandNotRegistered',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
