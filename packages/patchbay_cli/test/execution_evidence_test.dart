import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

void main() {
  // 真机预检发现：手机时钟比工作站快 160ms 时，一份合法的 unchanged 证据被报成
  // providerProtocolViolation。App 侧的两个时间戳（priorObservedAtMs 与 observedAtMs）
  // 都来自设备时钟，拿工作站时钟当"现在"去比，会把时钟偏移归责成 App 违反协议。
  // job 事件路径早就用事件自带的 `at` 当基准，立即命令路径必须同口径。
  test(
    'device clock ahead of workstation is not a provider violation',
    () async {
      final int deviceNowMs =
          DateTime.now().millisecondsSinceEpoch +
          const Duration(seconds: 5).inMilliseconds;
      final _Run result = await _run(
        FakePatchbayClient(
          commands: <Map<String, Object?>>[
            <String, Object?>{
              ..._descriptor(),
              'unchangedEvidenceMaxAgeMs': 60000,
            },
          ],
          handle: (_, _) async => fakeAccepted(<String, Object?>{
            'execution': <String, Object?>{
              'classification': 'unchanged',
              'factSource': 'appRecorded',
              'observedAtMs': deviceNowMs,
              'reasonCode': null,
              'priorValueSource': 'deviceReported',
              'priorObservedAtMs': deviceNowMs - 200,
            },
          }),
        ),
      );

      expect(result.response['admission'], 'accepted');
      expect(result.exitCode, PatchbayExitCode.accepted);
    },
  );

  test(
    'CLI rejects uiObserved device confirmation without leaking payload',
    () async {
      final _Run result = await _run(
        FakePatchbayClient(
          commands: <Map<String, Object?>>[_descriptor()],
          handle: (_, _) async => fakeAccepted(<String, Object?>{
            ..._execution('deviceConfirmed', 'uiObserved'),
            'password': 'cli-secret',
          }),
        ),
      );

      expect(result.exitCode, PatchbayExitCode.rejected);
      expect(result.response['admission'], 'rejected');
      expect(result.response.toString(), isNot(contains('cli-secret')));
      expect(result.response.toString(), contains('providerProtocolViolation'));
    },
  );

  test(
    'CLI keeps execution authoritative and records dispatched conflict',
    () async {
      final _Run result = await _run(
        FakePatchbayClient(
          commands: <Map<String, Object?>>[_descriptor()],
          handle: (_, _) async => fakeAccepted(<String, Object?>{
            ..._execution('deviceConfirmed', 'deviceReported'),
            'dispatched': false,
          }),
        ),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(
        result.response['details'],
        containsPair('legacyDispatchedConflict', true),
      );
    },
  );

  test('completed sentUnconfirmed fails unless descriptor opts in', () async {
    final _Run strict = await _run(
      _jobClient(weakConfirmationCompletes: false),
      wait: true,
    );
    expect(strict.exitCode, PatchbayExitCode.rejected);
    expect(strict.response.toString(), contains('providerProtocolViolation'));

    final _Run weak = await _run(
      _jobClient(weakConfirmationCompletes: true),
      wait: true,
    );
    expect(weak.exitCode, PatchbayExitCode.accepted);
    expect(weak.response['schemaMode'], 'legacyUnvalidated');
  });

  test('0.3 command without execution policy keeps legacy payload', () async {
    final _Run result = await _run(
      FakePatchbayClient(
        commands: const <Map<String, Object?>>[
          <String, Object?>{'name': 'fixture.command'},
        ],
        handle: (_, _) async => fakeAccepted(<String, Object?>{
          'consumerField': 7,
          'dispatched': false,
        }),
      ),
    );

    expect(result.response['schemaMode'], 'legacyUnvalidated');
    expect(result.response['payload'], containsPair('consumerField', 7));
    expect(result.exitCode, PatchbayExitCode.typedFailure);
  });
}

FakePatchbayClient _jobClient({required bool weakConfirmationCompletes}) =>
    FakePatchbayClient(
      commands: <Map<String, Object?>>[
        <String, Object?>{
          ..._descriptor(),
          'mode': 'job',
          'weakConfirmationCompletes': weakConfirmationCompletes,
        },
        const <String, Object?>{'name': 'patchbay.job.wait'},
      ],
      handle: (String command, _) async {
        if (command == 'fixture.command') {
          return <String, Object?>{
            'admission': 'accepted',
            'payload': const <String, Object?>{},
            'jobId': 'job-1',
          };
        }
        return fakeAccepted(
          PatchbayJobWaitResult(
            outcome: PatchbayJobWaitOutcome.changed,
            snapshot: PatchbayJobSnapshot(
              jobId: 'job-1',
              events: <PatchbayJobEvent>[
                PatchbayJobEvent(
                  sequence: 1,
                  at: DateTime.utc(2026),
                  phase: PatchbayJobPhase.completed,
                  source: PatchbayFactSource.commandEcho,
                  payload: _execution('sentUnconfirmed', 'commandEcho'),
                ),
              ],
            ),
          ).toJson(),
        );
      },
    );

Map<String, Object?> _descriptor() => <String, Object?>{
  'name': 'fixture.command',
  'factSources': <String>[
    'appRecorded',
    'commandEcho',
    'deviceReported',
    'uiObserved',
  ],
  'confirmationBudgetMs': 3000,
  'weakConfirmationCompletes': false,
};
Map<String, Object?> _execution(String classification, String factSource) =>
    <String, Object?>{
      'execution': <String, Object?>{
        'classification': classification,
        'factSource': factSource,
        'observedAtMs': null,
        'reasonCode': null,
      },
    };

Future<_Run> _run(FakePatchbayClient client, {bool wait = false}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    <String>['--json', if (wait) '--wait', 'exec', 'fixture.command'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return _Run(exitCode, jsonDecode(out.toString()) as Map<String, Object?>);
}

final class _Run {
  const _Run(this.exitCode, this.response);

  final int exitCode;
  final Map<String, Object?> response;
}
