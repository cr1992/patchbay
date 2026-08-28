import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'legacy job polling is explicit in machine output',
    () async {
      final Process host =
          await Process.start(Platform.resolvedExecutable, <String>[
            '--enable-vm-service=0',
            '--disable-service-auth-codes',
            'test/fixture/legacy_job_host.dart',
          ], workingDirectory: Directory.current.path);
      addTearDown(() async {
        host.kill();
        await host.exitCode;
      });
      final Completer<Uri> uri = Completer<Uri>();
      void observe(String line) {
        final RegExpMatch? match = RegExp(
          r'(https?://[^\s]+)',
        ).firstMatch(line);
        if (match != null && !uri.isCompleted) {
          uri.complete(Uri.parse(match.group(1)!));
        }
      }

      host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      host.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      final Uri serviceUri = await uri.future.timeout(
        const Duration(seconds: 10),
      );
      final ProcessResult result =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            serviceUri.toString(),
            '--json',
            '--wait',
            'exec',
            'fixture.job',
          ], workingDirectory: Directory.current.path);
      expect(result.exitCode, 0, reason: result.stderr);
      final Map<String, Object?> output = Map<String, Object?>.from(
        jsonDecode(result.stdout.toString()) as Map<String, dynamic>,
      );
      expect(output['waitMode'], 'legacyPolling');
      expect(output['waitNotice'], contains('patchbay.job.get'));
      // Same contract on the compatibility path: the admitted job id is at the
      // top level of a `--wait` result, whichever way the CLI waited.
      expect(output['jobId'], 'legacy-job');
    },
    // Real host boot + one real `dart run bin/patchbay.dart` compile, same
    // real-subprocess-under-contention class as `cross_process_test.dart`'s
    // 120s ceiling. Not exercising a timeout mechanism -- just headroom for
    // two real cold starts to land. 20s measured ~20.0s wall-clock failures
    // (dart:test's own ceiling firing, not this test's logic) under a local
    // `--cpus=1 --memory=4g` container repro run concurrently with the other
    // heavy cross-process test files, even though an isolated run typically
    // finishes in ~6s; widened with real margin rather than trimmed further.
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
