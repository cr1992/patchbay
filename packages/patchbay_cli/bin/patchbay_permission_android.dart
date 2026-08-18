import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main() async {
  exitCode = await runPatchbayPermissionPlatformAdapter(
    PatchbayAndroidPermissionAdapter(
      adbExecutable: Platform.environment['PATCHBAY_ADB'] ?? 'adb',
      instrumentationRunner:
          Platform.environment['PATCHBAY_ANDROID_PERMISSION_RUNNER'],
    ),
  );
}
