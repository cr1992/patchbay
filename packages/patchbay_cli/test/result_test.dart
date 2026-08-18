import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test('classifies protocol, admission, and typed failures separately', () {
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'rejected',
        'rejection': <String, Object?>{'code': 'commandNotRegistered'},
      }),
      PatchbayExitCode.protocol,
    );
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'rejected',
        'rejection': <String, Object?>{'code': 'domainNotReady'},
      }),
      PatchbayExitCode.rejected,
    );
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{'outcome': 'failed'},
      }),
      PatchbayExitCode.typedFailure,
    );
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'terminal': true,
          'events': <Object?>[
            <String, Object?>{'phase': 'running'},
            <String, Object?>{'phase': 'failed'},
          ],
        },
      }),
      PatchbayExitCode.typedFailure,
    );
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'terminal': true,
          'events': <Object?>[
            <String, Object?>{'phase': 'completed'},
          ],
        },
      }),
      PatchbayExitCode.accepted,
    );
  });

  test('a terminal job summary keeps both the id and the outcome', () {
    // The top-level id is the admitted job; the summary must not drop the
    // phase, which is the half the operator was waiting for.
    expect(
      patchbayResponseSummary(<String, Object?>{
        'admission': 'accepted',
        'jobId': 'job-7',
        'payload': <String, Object?>{
          'jobId': 'snapshot-7',
          'terminal': true,
          'events': <Object?>[
            <String, Object?>{'phase': 'running'},
            <String, Object?>{'phase': 'failed'},
          ],
        },
      }),
      'jobId=job-7 terminal=true phase=failed',
    );
    // An admission that has not reached a terminal state still summarises as
    // the bare id it always did.
    expect(
      patchbayResponseSummary(<String, Object?>{
        'admission': 'accepted',
        'jobId': 'job-7',
      }),
      'jobId=job-7',
    );
  });

  test('typed execution supersedes legacy dispatched for immediate exits', () {
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'dispatched': false,
          'execution': <String, Object?>{'classification': 'deviceConfirmed'},
        },
      }),
      PatchbayExitCode.accepted,
    );
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'dispatched': true,
          'execution': <String, Object?>{'classification': 'notSent'},
        },
      }),
      PatchbayExitCode.typedFailure,
    );
  });

  test('legacy dispatched false still fails a completed terminal job', () {
    expect(
      patchbayExitCodeFor(<String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'terminal': true,
          'dispatched': false,
          'events': <Object?>[
            <String, Object?>{'phase': 'completed'},
          ],
        },
      }),
      PatchbayExitCode.typedFailure,
    );
  });

  test('wait timeout is a typed job failure, not a transport exception', () {
    expect(
      waitForPatchbayJob(
        admission: const <String, Object?>{'jobId': 'job-1'},
        read: (_) async => const <String, Object?>{
          'payload': <String, Object?>{'terminal': false},
        },
        timeout: Duration.zero,
        pollInterval: Duration.zero,
      ),
      throwsA(isA<PatchbayJobWaitTimeout>()),
    );
  });

  test('wait honors a consumer-neutral admission timeout hint', () async {
    var reads = 0;
    final Map<String, Object?> result = await waitForPatchbayJob(
      admission: const <String, Object?>{
        'jobId': 'job-1',
        'payload': <String, Object?>{'suggestedWaitTimeoutMs': 100},
      },
      pollInterval: Duration.zero,
      read: (_) async {
        reads += 1;
        return <String, Object?>{
          'payload': <String, Object?>{
            'terminal': reads > 1,
            'events': <Object?>[
              <String, Object?>{'phase': reads > 1 ? 'completed' : 'running'},
            ],
          },
        };
      },
    );

    expect((result['payload']! as Map<Object?, Object?>)['terminal'], isTrue);
  });
}
