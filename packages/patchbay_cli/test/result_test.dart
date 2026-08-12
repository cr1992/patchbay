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
}
