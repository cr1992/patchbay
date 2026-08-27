/// 对端被冻结时，CLI **进程本身**必须在预算量级内结束。
///
/// 只断言错误码不够：预算判完、`appUnresponsive` 也打印了，进程却可以继续挂着——
/// 被放弃的 VM Service WebSocket 握手仍注册在事件循环上，`main` 返回后 VM 会一直
/// 等它。真机上量到 178 秒（30 秒预算早就判完并打印了），直到系统把 App 杀掉、
/// TCP 断开才退出。所以这里跨进程起真的 fixture、SIGSTOP 冻结它，断言的是
/// **CLI 进程的 exitCode**，而不是某个 in-process future 的结果。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/rpc_timeout.dart';
import 'package:test/test.dart';

/// 冻结对端时给 CLI 的预算。取小值让用例快，回归时的失败模式是「永不退出」，
/// 不是「慢一点」，所以下面的上界可以给得很宽而不牺牲判据。
const Duration _budget = Duration(seconds: 2);

/// CLI 进程必须自己退出的上界。
///
/// 宽到足以容纳 `dart run` 的编译与 CI 抖动，又远小于回归时的「无界」。
const Duration _mustExitWithin = Duration(seconds: 60);

Future<Uri> _vmServiceUri(Process host, List<StreamSubscription<String>> subs) {
  final Completer<Uri> found = Completer<Uri>();
  void observe(String line) {
    final RegExpMatch? match = RegExp(r'(https?://[^\s]+)').firstMatch(line);
    if (match != null && !found.isCompleted) {
      found.complete(Uri.parse(match.group(1)!));
    }
  }

  for (final Stream<List<int>> stream in <Stream<List<int>>>[
    host.stdout,
    host.stderr,
  ]) {
    subs.add(
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe),
    );
  }
  return found.future.timeout(const Duration(seconds: 30));
}

void main() {
  test(
    'a frozen peer cannot hold the CLI process open',
    () async {
      final Process host =
          await Process.start(Platform.resolvedExecutable, <String>[
            '--enable-vm-service=0',
            '--disable-service-auth-codes',
            'test/fixture/host.dart',
          ], workingDirectory: Directory.current.path);
      final List<StreamSubscription<String>> subs =
          <StreamSubscription<String>>[];
      addTearDown(() async {
        for (final StreamSubscription<String> sub in subs) {
          await sub.cancel();
        }
        // Resume first: a stopped process cannot act on SIGTERM, and a child
        // left in that state would outlive the run.
        Process.killPid(host.pid, ProcessSignal.sigcont);
        host.kill(ProcessSignal.sigkill);
        await host.exitCode;
      });
      final Uri uri = await _vmServiceUri(host, subs);

      expect(
        Process.killPid(host.pid, ProcessSignal.sigstop),
        isTrue,
        reason: '没能冻结 fixture，下面测的就不是冻结对端了',
      );

      final Stopwatch elapsed = Stopwatch()..start();
      final Process cli =
          await Process.start(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            '$uri',
            '--transport-timeout-ms',
            '${_budget.inMilliseconds}',
            '--json',
            'identity',
          ], workingDirectory: Directory.current.path);
      final Future<String> stdout = cli.stdout.transform(utf8.decoder).join();
      final Future<String> stderr = cli.stderr.transform(utf8.decoder).join();

      final int exitCode;
      try {
        exitCode = await cli.exitCode.timeout(_mustExitWithin);
      } on TimeoutException {
        cli.kill(ProcessSignal.sigkill);
        await cli.exitCode;
        fail(
          'CLI 进程在 ${_mustExitWithin.inSeconds}s 内没有自己退出（预算 '
          '${_budget.inMilliseconds}ms）——判决已经做出，但被放弃的连接仍把事件循环'
          '按在那里，这正是真机上 178s 的成因',
        );
      }
      elapsed.stop();

      expect(exitCode, PatchbayExitCode.transport);
      final Map<String, Object?> error =
          (jsonDecode(await stdout) as Map<String, Object?>)['error']!
              as Map<String, Object?>;
      expect(error['code'], patchbayAppUnresponsiveCode);
      expect(await stderr, contains(patchbayAppUnresponsiveCode));
      // 冻结的对端不会给出任何应答，所以在预算到点之前不可能结束：这条把用例钉在
      // 「等满了预算」上，防止某天连接因别的原因秒失败而让上面的断言恒真。
      expect(elapsed.elapsed, greaterThanOrEqualTo(_budget));
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'a dead peer fails on the connection, not on the budget',
    () async {
      // Frozen and dead look the same to a caller but not to the kernel: nothing
      // is listening any more, so the dial is refused immediately. The budget
      // must not swallow that — waiting 30 seconds to report a closed port would
      // turn the most legible failure the OS offers into the least legible one.
      final Process host =
          await Process.start(Platform.resolvedExecutable, <String>[
            '--enable-vm-service=0',
            '--disable-service-auth-codes',
            'test/fixture/host.dart',
          ], workingDirectory: Directory.current.path);
      final List<StreamSubscription<String>> subs =
          <StreamSubscription<String>>[];
      addTearDown(() async {
        for (final StreamSubscription<String> sub in subs) {
          await sub.cancel();
        }
      });
      final Uri uri = await _vmServiceUri(host, subs);

      host.kill(ProcessSignal.sigkill);
      await host.exitCode;

      final Stopwatch elapsed = Stopwatch()..start();
      final ProcessResult result = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--ws-uri',
          '$uri',
          // A budget far larger than any plausible dial, so an assertion below
          // the budget can only pass by failing on the connection itself.
          '--transport-timeout-ms',
          '30000',
          '--json',
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      elapsed.stop();

      expect(result.exitCode, PatchbayExitCode.transport);
      final Map<String, Object?> error =
          (jsonDecode(result.stdout as String)
                  as Map<String, Object?>)['error']!
              as Map<String, Object?>;
      expect(error['code'], isNot(patchbayAppUnresponsiveCode));
      expect(error['code'], 'transportError');
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 20)));
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
