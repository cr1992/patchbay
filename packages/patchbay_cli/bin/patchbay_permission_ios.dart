import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main() async {
  exitCode = await runPatchbayPermissionPlatformAdapter(
    PatchbayIosPermissionAdapter(
      xcrunExecutable: Platform.environment['PATCHBAY_XCRUN'] ?? 'xcrun',
      xcuiTestRunner: Platform.environment['PATCHBAY_IOS_PERMISSION_RUNNER'],
    ),
  );
}
