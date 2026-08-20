import 'dart:io';

import 'package:patchbay_cli/src/ios_xcuitest_runner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runPatchbayIosXcuiTestRunner(arguments);
}
