import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addOption('ws-uri', help: 'VM Service http(s) or ws(s) URI.')
    ..addOption('session', help: 'Select one discovered Patchbay session ID.')
    ..addOption(
      'session-dir',
      help: 'Override the Patchbay launcher session directory.',
      hide: true,
    )
    ..addOption('args', help: 'JSON object passed to a domain command.')
    ..addFlag(
      'stdin',
      defaultsTo: false,
      help: 'Read a sensitive text value from one stdin line.',
    )
    ..addFlag(
      'wait',
      defaultsTo: false,
      help: 'Wait for a returned jobId to reach a terminal event.',
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
  final String? selectedSession = parsed.option('session');
  if (uriText != null && selectedSession != null) {
    stderr.writeln('--ws-uri and --session are mutually exclusive');
    exitCode = 64;
    return;
  }
  if (parsed.rest.isEmpty) {
    stderr.writeln(
      'usage: patchbay [--ws-uri <uri>|--session <id>] [--json] '
      '<identity|catalog|snapshot|exec|job|ui>',
    );
    exitCode = 64;
    return;
  }

  PatchbayConnection? connection;
  try {
    if (uriText != null) {
      connection = await PatchbayConnection.connect(Uri.parse(uriText));
    } else {
      final sessionStore = PatchbaySessionStore(parsed.option('session-dir'));
      final discovered = await PatchbaySessionResolver(
        store: sessionStore,
      ).resolve(sessionId: selectedSession);
      try {
        connection = await PatchbayConnection.connect(
          Uri.parse(discovered.record.wsUri!),
          expectedIdentity: discovered.identity,
        );
      } on PatchbayProtocolException {
        sessionStore.remove(discovered.record.sessionId);
        throw const PatchbaySessionException('sessionIdentityMismatch');
      } on Object {
        sessionStore.remove(discovered.record.sessionId);
        throw const PatchbaySessionException('sessionStaleTransport');
      }
    }
    final Map<String, Object?> result = switch (parsed.rest) {
      ['identity'] => await connection.identity(),
      ['catalog'] => await connection.catalog(),
      ['snapshot'] => await connection.snapshot(),
      ['exec', final String command] => await connection.invoke(
        command: command,
        arguments: _domainArguments(parsed),
      ),
      ['job', 'get', final String jobId] => await connection.invoke(
        command: 'patchbay.job.get',
        arguments: <String, Object?>{'jobId': jobId},
      ),
      ['job', 'cancel', final String jobId] => await connection.invoke(
        command: 'patchbay.job.cancel',
        arguments: <String, Object?>{'jobId': jobId},
      ),
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
                ? readSensitiveStdinLine()
                : words.join(' '),
            'inputWasStdin': parsed.flag('stdin'),
          },
        ),
      ['ui', 'semantics', 'tree'] => await connection.invoke(
        command: 'ui.semantics.tree',
        arguments: _domainArguments(parsed),
      ),
      ['ui', 'widget-tree'] => await connection.widgetTree(),
      ['ui', 'render-tree'] => await connection.renderTree(),
      ['ui', 'focus-tree'] => await connection.focusTree(),
      [
        'ui',
        'semantics',
        'action',
        final String nodeId,
        final String generation,
        final String action,
        ...final List<String> words,
      ] =>
        await connection.invoke(
          command: 'ui.semantics.action',
          arguments: <String, Object?>{
            'nodeId': int.parse(nodeId),
            'generation': int.parse(generation),
            'action': action,
            if (action == 'setText')
              'text': parsed.flag('stdin')
                  ? readSensitiveStdinLine()
                  : words.join(' '),
            'inputWasStdin': parsed.flag('stdin'),
          },
        ),
      _ => throw const FormatException('unknown command'),
    };
    final Map<String, Object?> output = parsed.flag('wait')
        ? await waitForPatchbayJob(
            admission: result,
            read: (String jobId) => connection!.invoke(
              command: 'patchbay.job.get',
              arguments: <String, Object?>{'jobId': jobId},
            ),
          )
        : result;
    stdout.writeln(
      parsed.flag('json')
          ? const JsonEncoder.withIndent('  ').convert(output)
          : _summary(output),
    );
    exitCode = patchbayExitCodeFor(output);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = PatchbayExitCode.usage;
  } on PatchbayProtocolException catch (error) {
    stderr.writeln('patchbay protocol error: ${error.code}');
    exitCode = PatchbayExitCode.protocol;
  } on PatchbaySessionException catch (error) {
    stderr.writeln('patchbay session error: ${error.code}');
    for (final choice in error.choices) {
      stderr.writeln('  --session ${choice.split(' ').first}  $choice');
    }
    exitCode = PatchbayExitCode.transport;
  } on PatchbayJobWaitTimeout {
    stderr.writeln('patchbay job failed: waitTimeout');
    exitCode = PatchbayExitCode.typedFailure;
  } on PatchbaySensitiveInputException catch (error) {
    stderr.writeln('patchbay sensitive input error: ${error.code}');
    exitCode = PatchbayExitCode.usage;
  } on Object catch (error) {
    // VM Service URIs carry authentication material. Exception strings from
    // socket clients may echo the URI, so ordinary CLI output exposes only the
    // stable error type.
    stderr.writeln('patchbay transport error: ${error.runtimeType}');
    exitCode = PatchbayExitCode.transport;
  } finally {
    await connection?.close();
  }
}

Map<String, Object?> _domainArguments(ArgResults parsed) {
  final String encoded = parsed.flag('stdin')
      ? readSensitiveStdinLine()
      : (parsed.option('args') ?? '{}');
  final Object? decoded = jsonDecode(encoded);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('--args/stdin must contain a JSON object');
  }
  return <String, Object?>{
    ...Map<String, Object?>.from(decoded),
    if (parsed.flag('stdin')) 'inputWasStdin': true,
  };
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
  if (value['jobId'] case final String jobId) return 'jobId=$jobId';
  return jsonEncode(value);
}
