import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addOption('ws-uri', help: 'VM Service http(s) or ws(s) URI.')
    ..addFlag(
      'stdin',
      defaultsTo: false,
      help: 'Read a sensitive text value from one stdin line.',
    )
    ..addFlag('json', defaultsTo: false, help: 'Print stable JSON.');
  final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }
  final String? uriText = parsed.option('ws-uri');
  if (uriText == null || parsed.rest.isEmpty) {
    stderr.writeln(
      'usage: patchbay --ws-uri <uri> [--json] <identity|catalog|ui>',
    );
    exitCode = 64;
    return;
  }

  PatchbayConnection? connection;
  try {
    connection = await PatchbayConnection.connect(Uri.parse(uriText));
    final Map<String, Object?> result = switch (parsed.rest) {
      ['identity'] => await connection.identity(),
      ['catalog'] => await connection.catalog(),
      [
        'ui',
        'text',
        final String operation,
        final String id,
        final String generation,
        ...final List<String> words,
      ]
          when operation == 'set' || operation == 'enter' =>
        await connection.invoke(
          command: 'ui.text.$operation',
          arguments: <String, Object?>{
            'id': id,
            'generation': int.parse(generation),
            'text': parsed.flag('stdin')
                ? (stdin.readLineSync() ?? '')
                : words.join(' '),
            'inputWasStdin': parsed.flag('stdin'),
          },
        ),
      _ => throw const FormatException('unknown command'),
    };
    stdout.writeln(
      parsed.flag('json')
          ? const JsonEncoder.withIndent('  ').convert(result)
          : _summary(result),
    );
    if (result['admission'] == 'rejected') exitCode = 5;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on Object catch (error) {
    // VM Service URIs carry authentication material. Exception strings from
    // socket clients may echo the URI, so ordinary CLI output exposes only the
    // stable error type.
    stderr.writeln('patchbay transport error: ${error.runtimeType}');
    exitCode = 3;
  } finally {
    await connection?.close();
  }
}

String _summary(Map<String, Object?> value) {
  if (value case {
    'applicationId': final Object app,
    'appInstanceId': final Object instance,
  }) {
    return '$app instance=$instance';
  }
  if (value['uiTargets'] case final List<Object?> targets) {
    return 'commands=${(value['commands'] as List<Object?>?)?.length ?? 0} uiTargets=${targets.length}';
  }
  return jsonEncode(value);
}
