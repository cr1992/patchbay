import 'dart:convert';
import 'dart:io';

import 'permission_platform_adapter.dart';

const String patchbayIosXctestrunEnvironment = 'PATCHBAY_IOS_XCTESTRUN';
const String patchbayXcodebuildEnvironment = 'PATCHBAY_XCODEBUILD';

Future<int> runPatchbayIosXcuiTestRunner(
  List<String> arguments, {
  Map<String, String>? environment,
  PatchbayPlatformCommandRunner? runCommand,
  StringSink? output,
  StringSink? errorOutput,
}) async {
  final StringSink out = output ?? stdout;
  final StringSink err = errorOutput ?? stderr;
  final Map<String, String> values;
  try {
    values = _parseArguments(arguments);
  } on FormatException catch (failure) {
    err.writeln(failure.message);
    return 64;
  }
  final Map<String, String> processEnvironment =
      environment ?? Platform.environment;
  final String? configuredXctestrun =
      processEnvironment[patchbayIosXctestrunEnvironment];
  if (configuredXctestrun == null || configuredXctestrun.trim().isEmpty) {
    err.writeln('platformSigningUnavailable');
    return 69;
  }
  final File source = File(configuredXctestrun);
  if (!source.isAbsolute || !source.existsSync()) {
    err.writeln('platformSigningUnavailable');
    return 69;
  }
  final PatchbayPlatformCommandRunner command =
      runCommand ?? runPatchbayPlatformCommand;
  final Directory temporary = await Directory.systemTemp.createTemp(
    'patchbay-ios-xcuitest-',
  );
  try {
    final File jsonFile = File('${temporary.path}/request.json');
    final File requestFile = File('${temporary.path}/request.xctestrun');
    PatchbayPlatformCommandResult result = await command(
      '/usr/bin/plutil',
      <String>['-convert', 'json', '-o', jsonFile.path, source.path],
      const Duration(seconds: 10),
    );
    if (result.exitCode != 0 || !jsonFile.existsSync()) {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await jsonFile.readAsString());
    } on FormatException {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    if (decoded is! Map<String, dynamic>) {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    _absolutizeTestRoot(decoded, source.parent.path);
    if (!_injectEnvironment(decoded, <String, String>{
      'PATCHBAY_OPERATION': values['operation']!,
      'PATCHBAY_DEVICE_ID': values['device-id']!,
      'PATCHBAY_APPLICATION_ID': values['application-id']!,
      if (values['permission'] case final String permission)
        'PATCHBAY_PERMISSION': permission,
      if (values['decision'] case final String decision)
        'PATCHBAY_DECISION': decision,
    })) {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    await jsonFile.writeAsString(jsonEncode(decoded), flush: true);
    result = await command('/usr/bin/plutil', <String>[
      '-convert',
      'xml1',
      '-o',
      requestFile.path,
      jsonFile.path,
    ], const Duration(seconds: 10));
    if (result.exitCode != 0 || !requestFile.existsSync()) {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    final String xcodebuild =
        processEnvironment[patchbayXcodebuildEnvironment] ?? 'xcodebuild';
    result = await command(xcodebuild, <String>[
      'test-without-building',
      '-xctestrun',
      requestFile.path,
      '-destination',
      'id=${values['device-id']}',
      '-only-testing:'
          'PatchbayPermissionUITests/PatchbayPermissionUITests/'
          'testPermissionOperation',
      '-parallel-testing-enabled',
      'NO',
    ], const Duration(minutes: 3));
    final RegExp marker = RegExp(r'PATCHBAY_RESULT=([A-Za-z0-9+/=]+)');
    final RegExpMatch? match = marker.firstMatch(
      '${result.stdout}\n${result.stderr}',
    );
    if (result.exitCode != 0 || match == null) {
      err.writeln('systemUiUnexpected');
      return 70;
    }
    final String payload;
    try {
      payload = utf8.decode(base64Decode(match.group(1)!));
      final Object? resultJson = jsonDecode(payload);
      if (resultJson is! Map<String, dynamic>) {
        throw const FormatException();
      }
    } on FormatException {
      err.writeln('platformDriverProtocolError');
      return 70;
    }
    out.writeln(payload);
    return 0;
  } finally {
    if (temporary.existsSync()) {
      await temporary.delete(recursive: true);
    }
  }
}

void _absolutizeTestRoot(Object? node, String testRoot) {
  String resolve(String value) => value.replaceAll('__TESTROOT__', testRoot);

  if (node is Map<String, dynamic>) {
    for (final MapEntry<String, dynamic> entry in node.entries.toList()) {
      final Object? value = entry.value;
      if (value is String) {
        node[entry.key] = resolve(value);
      } else {
        _absolutizeTestRoot(value, testRoot);
      }
    }
  } else if (node is List<Object?>) {
    for (int index = 0; index < node.length; index += 1) {
      final Object? value = node[index];
      if (value is String) {
        node[index] = resolve(value);
      } else {
        _absolutizeTestRoot(value, testRoot);
      }
    }
  }
}

Map<String, String> _parseArguments(List<String> arguments) {
  if (arguments.length.isOdd) {
    throw const FormatException('permissionRunnerArgumentsInvalid');
  }
  final Map<String, String> values = <String, String>{};
  for (int index = 0; index < arguments.length; index += 2) {
    final String key = arguments[index];
    final String value = arguments[index + 1];
    if (!key.startsWith('--') || value.isEmpty) {
      throw const FormatException('permissionRunnerArgumentsInvalid');
    }
    final String name = key.substring(2);
    if (!const <String>{
      'operation',
      'device-id',
      'application-id',
      'permission',
      'decision',
    }.contains(name)) {
      throw const FormatException('permissionRunnerArgumentsInvalid');
    }
    if (values.containsKey(name)) {
      throw const FormatException('permissionRunnerArgumentsInvalid');
    }
    values[name] = value;
  }
  for (final String required in <String>[
    'operation',
    'device-id',
    'application-id',
  ]) {
    if (!values.containsKey(required)) {
      throw const FormatException('permissionRunnerArgumentsInvalid');
    }
  }
  final String operation = values['operation']!;
  if (!const <String>{
    'capabilities',
    'reset',
    'exercise',
  }.contains(operation)) {
    throw const FormatException('permissionRunnerArgumentsInvalid');
  }
  if (operation != 'capabilities' && !values.containsKey('permission')) {
    throw const FormatException('permissionRunnerArgumentsInvalid');
  }
  if (operation == 'exercise' && !values.containsKey('decision')) {
    throw const FormatException('permissionRunnerArgumentsInvalid');
  }
  return values;
}

bool _injectEnvironment(
  Map<String, dynamic> node,
  Map<String, String> environment,
) {
  bool injected = false;
  void visit(Object? value) {
    if (value is Map<String, dynamic>) {
      final Object? testBundlePath = value['TestBundlePath'];
      if (testBundlePath is String &&
          testBundlePath.contains('PatchbayPermissionUITests.xctest')) {
        final Map<String, Object?> existing =
            switch (value['EnvironmentVariables']) {
              final Map<Object?, Object?> map => Map<String, Object?>.from(map),
              _ => <String, Object?>{},
            };
        value['EnvironmentVariables'] = <String, Object?>{
          ...existing,
          ...environment,
        };
        injected = true;
      }
      for (final Object? child in value.values) {
        visit(child);
      }
    } else if (value is List<Object?>) {
      for (final Object? child in value) {
        visit(child);
      }
    }
  }

  visit(node);
  return injected;
}
