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
    invoke:
        (String command, Map<String, Object?> args, String requestId) async =>
            PatchbayInvocation.rejected(
              requestId: requestId,
              rejection: const PatchbayRejection(code: 'commandNotRegistered'),
            ).toJson(),
  );
  host.register();
  Timer.periodic(const Duration(hours: 1), (_) {});
}
