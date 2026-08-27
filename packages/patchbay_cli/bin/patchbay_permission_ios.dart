import 'dart:io';

import 'package:patchbay_cli/src/ios_permission_adapter.dart';
import 'package:patchbay_cli/src/permission_platform_adapter.dart';

Future<void> main() async {
  exitCode = await runPatchbayPermissionPlatformAdapter(
    PatchbayIosPermissionAdapter(
      xcrunExecutable: Platform.environment['PATCHBAY_XCRUN'] ?? 'xcrun',
      xcuiTestRunner: Platform.environment['PATCHBAY_IOS_PERMISSION_RUNNER'],
    ),
  );
}
