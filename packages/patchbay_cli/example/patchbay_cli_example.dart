import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main() async {
  exitCode = await runPatchbayCli(const <String>['--help']);
}
