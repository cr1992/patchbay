import 'dart:async';

import 'package:patchbay/patchbay_host.dart';

void main() {
  final PatchbayServiceHost host = PatchbayServiceHost(
    applicationId: 'dev.patchbay.legacy.fixture',
    appInstanceId: 'legacy-fixture-instance',
    catalog: () async => <String, Object?>{
      'commands': const <Object?>[
        <String, Object?>{'name': 'fixture.job'},
        <String, Object?>{'name': 'patchbay.job.get'},
      ],
      'uiTargets': const <Object?>[],
    },
    snapshot: () async => const <String, Object?>{},
    invoke: (command, arguments, requestId) async => switch (command) {
      'fixture.job' => PatchbayInvocation.accepted(
        requestId: requestId,
        jobId: 'legacy-job',
      ).toJson(),
      'patchbay.job.get' => PatchbayInvocation.accepted(
        requestId: requestId,
        payload: const <String, Object?>{
          'terminal': true,
          'events': <Object?>[
            <String, Object?>{'sequence': 1, 'phase': 'succeeded'},
          ],
        },
      ).toJson(),
      _ => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'commandNotRegistered'),
      ).toJson(),
    },
  );
  host.register();
  Timer.periodic(const Duration(hours: 1), (_) {});
}
