import 'dart:async';

import 'package:patchbay/patchbay.dart';

void main() {
  final PatchbayServiceHost host = PatchbayServiceHost(
    applicationId: 'dev.patchbay.fixture',
    appInstanceId: 'fixture-instance',
    catalog: () async => <String, Object?>{
      'commands': const <Object?>[],
      'uiTargets': const <Object?>[],
    },
    snapshot: () async => <String, Object?>{
      'source': PatchbayFactSource.appRecorded.name,
    },
    invoke:
        (String command, Map<String, Object?> args, String requestId) async =>
            switch (command) {
              'fixture.typedFailure' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{'outcome': 'failed'},
              ).toJson(),
              'fixture.failedJob' => PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: 'fixture-job',
              ).toJson(),
              'ui.semantics.tree' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'observed',
                  'source': 'uiObserved',
                  'nodes': <Object?>[],
                },
              ).toJson(),
              'ui.semantics.action' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'dispatched',
                  'source': 'uiObserved',
                  'arguments': args,
                },
              ).toJson(),
              'patchbay.job.get' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'terminal': true,
                  'events': <Object?>[
                    <String, Object?>{'phase': 'running'},
                    <String, Object?>{'phase': 'failed'},
                  ],
                },
              ).toJson(),
              _ => PatchbayInvocation.rejected(
                requestId: requestId,
                rejection: const PatchbayRejection(
                  code: 'commandNotRegistered',
                ),
              ).toJson(),
            },
  );
  host.register();
  Timer.periodic(const Duration(hours: 1), (_) {});
}
