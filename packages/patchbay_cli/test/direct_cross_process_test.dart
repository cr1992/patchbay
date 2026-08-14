import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'direct mode authenticates and preserves CLI result classification',
    () async {
      final Process host = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'test/fixture/direct_host.dart'],
        workingDirectory: Directory.current.path,
      );
      addTearDown(() async {
        host.kill();
        await host.exitCode;
      });
      final String line = await host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      final Map<String, Object?> session = Map<String, Object?>.from(
        jsonDecode(line) as Map<String, dynamic>,
      );
      final String endpoint = session['endpoint']! as String;
      final String token = session['token']! as String;

      final ProcessResult identity = await _runDirect(
        endpoint,
        token,
        const <String>['identity'],
      );
      expect(identity.exitCode, 0, reason: identity.stderr);
      expect(
        (jsonDecode(identity.stdout.toString())
            as Map<String, Object?>)['appInstanceId'],
        'direct-fixture-instance',
      );

      final ProcessResult navigation = await _runDirect(
        endpoint,
        token,
        const <String>['navigation', 'current'],
      );
      expect(navigation.exitCode, 0, reason: navigation.stderr);
      expect(
        ((jsonDecode(navigation.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['destinationId'],
        'home',
      );

      final ProcessResult rejected = await _runDirect(
        endpoint,
        token,
        const <String>['exec', 'fixture.reject'],
      );
      expect(rejected.exitCode, PatchbayExitCode.rejected);
      expect(
        ((jsonDecode(rejected.stdout.toString())
                as Map<String, Object?>)['rejection']!
            as Map<String, Object?>)['code'],
        'featureUnavailable',
      );

      final String wrongToken = List<String>.filled(64, 'f').join();
      final ProcessResult unauthorized = await _runDirect(
        endpoint,
        wrongToken,
        const <String>['identity'],
      );
      expect(unauthorized.exitCode, PatchbayExitCode.transport);
      expect(unauthorized.stderr.toString(), contains('unauthorized'));
      expect(unauthorized.stderr.toString(), isNot(contains(wrongToken)));
      expect(unauthorized.stderr.toString(), isNot(contains(endpoint)));

      final ProcessResult wrongIdentity = await _runDirect(
        endpoint,
        token,
        const <String>['identity'],
        appInstanceId: 'wrong-instance',
      );
      expect(wrongIdentity.exitCode, PatchbayExitCode.protocol);
      expect(wrongIdentity.stderr.toString(), contains('identityMismatch'));
      expect(wrongIdentity.stderr.toString(), isNot(contains(token)));

      final ProcessResult credentialInUrl = await _runDirect(
        '$endpoint?token=$token',
        token,
        const <String>['identity'],
      );
      expect(credentialInUrl.exitCode, PatchbayExitCode.usage);
      expect(credentialInUrl.stderr.toString(), isNot(contains(token)));

      final ProcessResult timeout = await _runDirect(
        endpoint,
        token,
        const <String>['exec', 'fixture.slow'],
        timeoutMs: 20,
      );
      expect(timeout.exitCode, PatchbayExitCode.transport);
      // The direct transport names its own budget `timeout`; the CLI reports
      // the peer, in the same words the VM Service path uses.
      expect(timeout.stderr.toString(), contains(patchbayAppUnresponsiveCode));
      expect(timeout.stderr.toString(), contains('frozen by the system'));
      expect(timeout.stderr.toString(), isNot(contains(token)));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

Future<ProcessResult> _runDirect(
  String endpoint,
  String token,
  List<String> command, {
  String appInstanceId = 'direct-fixture-instance',
  int timeoutMs = 10000,
}) async {
  final Process process =
      await Process.start(Platform.resolvedExecutable, <String>[
        'run',
        'bin/patchbay.dart',
        '--direct-endpoint',
        endpoint,
        '--direct-token-stdin',
        '--direct-application-id',
        'dev.patchbay.direct.fixture',
        '--direct-app-instance-id',
        appInstanceId,
        '--transport-timeout-ms',
        '$timeoutMs',
        '--json',
        ...command,
      ], workingDirectory: Directory.current.path);
  process.stdin.writeln(token);
  await process.stdin.close();
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  final int exitCode = await process.exitCode;
  return ProcessResult(process.pid, exitCode, await stdout, await stderr);
}
