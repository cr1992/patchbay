import 'dart:io';

import 'package:patchbay_cli/src/android_permission_adapter.dart';
import 'package:patchbay_cli/src/permission_platform_adapter.dart';

Future<void> main() async {
  exitCode = await runPatchbayPermissionPlatformAdapter(
    PatchbayAndroidPermissionAdapter(
      adbExecutable: Platform.environment['PATCHBAY_ADB'] ?? 'adb',
      instrumentationRunner:
          Platform.environment['PATCHBAY_ANDROID_PERMISSION_RUNNER'],
    ),
  );
}
