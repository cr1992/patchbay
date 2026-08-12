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
