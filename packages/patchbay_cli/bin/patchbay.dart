import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runPatchbayCli(arguments);
}
