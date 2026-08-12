import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
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
      expect(snapshot['source'], PatchbayFactSource.appRecorded.name);

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
        PatchbayFactSource.appRecorded.name,
      );

      final ProcessResult missingCommand =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'exec',
            'fixture.missing',
          ], workingDirectory: Directory.current.path);
      expect(missingCommand.exitCode, PatchbayExitCode.protocol);

      final ProcessResult typedFailure =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'exec',
            'fixture.typedFailure',
          ], workingDirectory: Directory.current.path);
      expect(typedFailure.exitCode, PatchbayExitCode.typedFailure);

      final ProcessResult failedJob =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            '--wait',
            'exec',
            'fixture.failedJob',
          ], workingDirectory: Directory.current.path);
      expect(failedJob.exitCode, PatchbayExitCode.typedFailure);

      final ProcessResult semanticsTree =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'semantics',
            'tree',
          ], workingDirectory: Directory.current.path);
      expect(
        semanticsTree.exitCode,
        0,
        reason: semanticsTree.stderr.toString(),
      );
      expect(
        ((jsonDecode(semanticsTree.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['outcome'],
        'observed',
      );

      final ProcessResult semanticsTap =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'semantics',
            'action',
            '42',
            '7',
            'tap',
          ], workingDirectory: Directory.current.path);
      expect(semanticsTap.exitCode, 0, reason: semanticsTap.stderr.toString());
      final Map<String, Object?> tapPayload =
          (jsonDecode(semanticsTap.stdout.toString())
                  as Map<String, Object?>)['payload']!
              as Map<String, Object?>;
      expect(tapPayload['outcome'], 'dispatched');
      expect((tapPayload['arguments']! as Map<String, Object?>)['nodeId'], 42);

      final ProcessResult unavailableFlutterTree =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'widget-tree',
          ], workingDirectory: Directory.current.path);
      expect(
        unavailableFlutterTree.exitCode,
        PatchbayExitCode.protocol,
        reason: unavailableFlutterTree.stderr.toString(),
      );
      expect(
        unavailableFlutterTree.stderr.toString(),
        contains('flutterDiagnosticUnavailable'),
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
