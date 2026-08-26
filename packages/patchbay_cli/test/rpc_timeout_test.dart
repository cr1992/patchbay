import 'dart:async';
import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// A client whose per-command latency the test picks.
///
/// [invokeDelay] returning `null` means "never answers", expressed as a
/// `Completer` rather than a very long delay on purpose: an abandoned timer
/// would keep the test isolate alive past the assertion it was written for,
/// which is how a timeout test starts passing for the wrong reason. `identity`
/// never answers, which is what makes it usable as the unresponsive handshake.
class _SlowClient implements PatchbayClient {
  _SlowClient({
    required this.commands,
    this.invokeDelay = _neverAnswers,
    this.answer,
    this.catalogAnswers = true,
  });

  final List<Map<String, Object?>> commands;
  final Duration? Function(String command) invokeDelay;
  final Map<String, Object?> Function(String command)? answer;

  /// Whether the catalog read — the first RPC of every `exec` — comes back.
  final bool catalogAnswers;

  final List<String> invoked = <String>[];

  static Duration? _neverAnswers(String command) => null;

  static Future<T> _never<T>() => Completer<T>().future;

  @override
  Future<Map<String, Object?>> identity() => _never();

  @override
  Future<Map<String, Object?>> catalog() async {
    if (!catalogAnswers) return _never();
    return <String, Object?>{
      'commands': commands,
      'uiTargets': const <Object?>[],
    };
  }

  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async => <String, Object?>{'source': 'appRecorded'};

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async {
    invoked.add(command);
    final Duration? delay = invokeDelay(command);
    if (delay == null) return _never();
    await Future<void>.delayed(delay);
    return <String, Object?>{
      'schemaVersion': 1,
      'requestId': requestId ?? 'slow-request',
      ...?answer?.call(command),
    };
  }

  @override
  Future<Map<String, Object?>> widgetTree() => _never();

  @override
  Future<Map<String, Object?>> renderTree() => _never();

  @override
  Future<Map<String, Object?>> focusTree() => _never();

  @override
  Future<void> close() async {}
}

final class _CancelableSlowClient extends _SlowClient
    implements PatchbayCancelableInvocationClient {
  _CancelableSlowClient() : super(commands: const <Map<String, Object?>>[]);

  int cancellations = 0;

  @override
  PatchbayClientInvocationHandle beginInvocation({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) => PatchbayClientInvocationHandle(
    response: Completer<Map<String, Object?>>().future,
    requestCancellation: () async {
      cancellations += 1;
      return const <String, Object?>{'outcome': 'confirmed'};
    },
  );
}

final class _LegacyCancelableSlowClient extends _SlowClient
    implements PatchbayCancelableInvocationClient {
  _LegacyCancelableSlowClient()
    : super(commands: const <Map<String, Object?>>[]);

  int cancellations = 0;

  @override
  PatchbayClientInvocationHandle beginInvocation({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) => PatchbayClientInvocationHandle(
    response: Completer<Map<String, Object?>>().future,
    cancellationSupported: () => false,
    requestCancellation: () async {
      cancellations += 1;
      return const <String, Object?>{'outcome': 'unsupported'};
    },
  );
}

final class _Run {
  const _Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  Map<String, Object?> get error =>
      (jsonDecode(out) as Map<String, Object?>)['error']!
          as Map<String, Object?>;

  Map<String, Object?> get details => error['details']! as Map<String, Object?>;
}

Future<_Run> _run(List<String> arguments, PatchbayClient client) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return _Run(exitCode, out.toString(), err.toString());
}

/// The budget the multi-RPC timing case runs under.
const Duration _budget = Duration(milliseconds: 300);

void main() {
  test('the documented default is the option default', () {
    // The constant is what the docs and the exported API promise; the option
    // default is what an invocation without the flag actually gets.
    expect(
      patchbayCliParser().defaultFor('transport-timeout-ms'),
      '${patchbayDefaultRpcTimeout.inMilliseconds}',
    );
    expect(patchbayDefaultRpcTimeout, const Duration(seconds: 30));
  });

  group('patchbayRpcBudget', () {
    test('a plain round trip gets the flat budget', () {
      expect(
        patchbayRpcBudget(const Duration(seconds: 30), null),
        const Duration(seconds: 30),
      );
    });

    test('a declared wait shorter than the budget changes nothing', () {
      expect(
        patchbayRpcBudget(
          const Duration(seconds: 30),
          const Duration(seconds: 5),
        ),
        const Duration(seconds: 30),
      );
    });

    test('a declared wait longer than the budget extends it, never caps it', () {
      // The App was asked to wait two minutes, so the answer cannot arrive any
      // sooner; capping at the flat budget would abandon a request that is
      // being served correctly.
      expect(
        patchbayRpcBudget(
          const Duration(seconds: 30),
          const Duration(minutes: 2),
        ),
        const Duration(seconds: 150),
      );
    });
  });

  group('an App that stops answering', () {
    test(
      'requests explicit cancellation from a feature-aware client',
      () async {
        final _CancelableSlowClient inner = _CancelableSlowClient();
        final PatchbayTimeoutClient client = PatchbayTimeoutClient(
          inner,
          rpcTimeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          client.invoke(
            command: 'app.slow',
            arguments: const <String, Object?>{},
            requestId: 'slow-owner',
          ),
          throwsA(
            isA<PatchbayTransportException>().having(
              (PatchbayTransportException error) => error.code,
              'code',
              patchbayAppUnresponsiveCode,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(inner.cancellations, 1);
      },
    );

    test('does not send cancel to a legacy host and labels the mode', () async {
      final _LegacyCancelableSlowClient inner = _LegacyCancelableSlowClient();
      final PatchbayTimeoutClient client = PatchbayTimeoutClient(
        inner,
        rpcTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        client.invoke(
          command: 'app.slow',
          arguments: const <String, Object?>{},
          requestId: 'legacy-owner',
        ),
        throwsA(
          isA<PatchbayTransportException>()
              .having(
                (PatchbayTransportException error) => error.code,
                'code',
                patchbayAppUnresponsiveCode,
              )
              .having(
                (PatchbayTransportException error) =>
                    error.details['cancellationMode'],
                'cancellationMode',
                'legacyWaitOnly',
              ),
        ),
      );
      expect(inner.cancellations, 0);
    });

    test('fails with a diagnosable code instead of hanging', () async {
      final _SlowClient client = _SlowClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'app.slow'},
        ],
      );

      final _Run result = await _run(<String>[
        '--json',
        '--transport-timeout-ms',
        '80',
        'exec',
        'app.slow',
      ], client);

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(result.error['code'], patchbayAppUnresponsiveCode);
      expect(result.details['hint'], patchbayAppUnresponsiveHint);
      expect(result.details['cancellationMode'], 'legacyWaitOnly');
      // The operator reads stderr; the sentence has to reach them there too.
      expect(result.err, contains(patchbayAppUnresponsiveCode));
      expect(result.err, contains('frozen by the system'));
      expect(client.invoked, contains('app.slow'));
    });

    test('costs one budget for the whole command, not one per RPC', () async {
      // `exec` is a two-RPC command: read the catalog, then invoke. If the
      // budget were spent per RPC and the command carried on, an unresponsive
      // peer would cost one budget per leg. It cannot: the first unanswered
      // RPC ends the command, so the later legs are never attempted — which is
      // the structural reason the total stays at one budget rather than N.
      final _SlowClient client = _SlowClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'app.slow'},
        ],
        catalogAnswers: false,
      );

      final Stopwatch elapsed = Stopwatch()..start();
      final _Run result = await _run(<String>[
        '--json',
        '--transport-timeout-ms',
        '300',
        'exec',
        'app.slow',
      ], client);
      elapsed.stop();

      expect(result.error['code'], patchbayAppUnresponsiveCode);
      expect(client.invoked, isEmpty);
      expect(elapsed.elapsed, greaterThanOrEqualTo(_budget));
      // Two budgets would be 600ms. The bound is loose enough for a busy
      // machine and still far below anything that stacked.
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 550)));
    });

    test('bounds the handshake as well, not only domain commands', () async {
      final _SlowClient client = _SlowClient(
        commands: const <Map<String, Object?>>[],
      );

      final _Run result = await _run(<String>[
        '--json',
        '--transport-timeout-ms',
        '80',
        'identity',
      ], client);

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(result.error['code'], patchbayAppUnresponsiveCode);
    });
  });

  group('a command that asks the App to wait', () {
    test('is not cut short by the flat RPC budget', () async {
      // `ui wait` declares a 300ms wait while the flat budget is 80ms. The App
      // answers at 200ms — later than the budget, earlier than the declared
      // wait — so only a budget that covers the declared wait lets it through.
      final _SlowClient client = _SlowClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.wait'},
        ],
        invokeDelay: (_) => const Duration(milliseconds: 200),
        answer: (_) => <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{'outcome': 'observed'},
        },
      );

      final _Run result = await _run(<String>[
        '--json',
        '--transport-timeout-ms',
        '80',
        '--timeout-ms',
        '300',
        'ui',
        'wait',
        'semantics-mounted',
        'app.ready',
      ], client);

      expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
      expect(
        jsonDecode(result.out) as Map<String, Object?>,
        containsPair('admission', 'accepted'),
      );
    });

    test('--wait long-polls the job without being cut short either', () async {
      // Admission is an ordinary immediate round trip and stays on the flat
      // budget; only `patchbay.job.wait`, which declares its own `timeoutMs`,
      // is allowed to outlast it.
      final _SlowClient client = _SlowClient(
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'app.job', 'suggestedWaitTimeoutMs': 400},
          <String, Object?>{'name': 'patchbay.job.wait'},
        ],
        invokeDelay: (String command) => command == 'patchbay.job.wait'
            ? const Duration(milliseconds: 200)
            : Duration.zero,
        answer: (String command) => switch (command) {
          'patchbay.job.wait' => <String, Object?>{
            'admission': 'accepted',
            'payload': <String, Object?>{
              'outcome': 'changed',
              'snapshot': <String, Object?>{
                'jobId': 'job-1',
                'terminal': true,
                'events': <Object?>[],
              },
            },
          },
          _ => <String, Object?>{
            'admission': 'accepted',
            'jobId': 'job-1',
            'payload': <String, Object?>{},
          },
        },
      );

      final _Run result = await _run(<String>[
        '--json',
        '--transport-timeout-ms',
        '80',
        '--wait',
        'exec',
        'app.job',
      ], client);

      expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
      expect(client.invoked, contains('patchbay.job.wait'));
    });
  });

  test('an answer inside the budget is untouched', () async {
    final FakePatchbayClient client = FakePatchbayClient(
      commands: <Map<String, Object?>>[
        <String, Object?>{'name': 'app.fast'},
      ],
      handle: (String command, Map<String, Object?> arguments) async =>
          fakeAccepted(const <String, Object?>{'ok': true}),
    );

    final _Run result = await _run(<String>[
      '--json',
      'exec',
      'app.fast',
    ], client);

    expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
  });
}
