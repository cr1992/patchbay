import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'artifact_download.dart';
import 'client.dart';
import 'command_help.dart';
import 'command_registry.dart';
import 'direct_connection.dart';
import 'result.dart';
import 'sensitive_input.dart';
import 'session.dart';

Future<int> runPatchbayCli(List<String> arguments) async {
  final ArgParser parser = patchbayCliParser();
  final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return PatchbayExitCode.usage;
  }

  PatchbayClient? connection;
  try {
    if (_helpTopic(parsed) case final List<String> topic) {
      stdout.write(PatchbayCommandHelp.render(parser, topic));
      return PatchbayExitCode.accepted;
    }
    _validateGlobalShape(parsed);
    if (parsed.rest.isEmpty) {
      throw FormatException(PatchbayCommandHelp.usageLine());
    }
    connection = await _connect(parsed);
    final _Execution execution = await _execute(connection, parsed);
    Map<String, Object?> output = execution.response;
    if (execution.artifact case final _ArtifactRequest artifact) {
      if (patchbayExitCodeFor(output) == PatchbayExitCode.accepted) {
        final PatchbayDownloadedArtifact downloaded =
            await PatchbayArtifactDownloader(
              invoke: (String command, Map<String, Object?> arguments) =>
                  _invokeAgainstCatalog(
                    connection!,
                    execution.catalog!,
                    command,
                    arguments,
                  ),
            ).download(
              metadataJson: _artifactMetadata(output, artifact.disposition),
              outputPath: artifact.outputPath,
              force: artifact.force,
            );
        output = <String, Object?>{
          ...output,
          'localArtifact': downloaded.toJson(),
        };
      }
    }
    _writeOutput(output, json: parsed.flag('json'));
    return patchbayExitCodeFor(output);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return PatchbayExitCode.usage;
  } on PatchbayArtifactRejected catch (error) {
    _writeOutput(error.response, json: parsed.flag('json'));
    return patchbayExitCodeFor(error.response);
  } on PatchbayArtifactDownloadException catch (error) {
    stderr.writeln('patchbay protocol error: ${error.code}');
    return PatchbayExitCode.protocol;
  } on PatchbayProtocolException catch (error) {
    stderr.writeln('patchbay protocol error: ${error.code}');
    return PatchbayExitCode.protocol;
  } on PatchbayTransportException catch (error) {
    stderr.writeln('patchbay transport error: ${error.code}');
    return PatchbayExitCode.transport;
  } on PatchbaySessionException catch (error) {
    stderr.writeln('patchbay session error: ${error.code}');
    for (final String choice in error.choices) {
      stderr.writeln('  --session ${choice.split(' ').first}  $choice');
    }
    return error.code == 'sessionIdentityMismatch'
        ? PatchbayExitCode.protocol
        : PatchbayExitCode.transport;
  } on PatchbayJobWaitTimeout {
    stderr.writeln('patchbay job failed: waitTimeout');
    return PatchbayExitCode.typedFailure;
  } on PatchbaySensitiveInputException catch (error) {
    stderr.writeln('patchbay sensitive input error: ${error.code}');
    return PatchbayExitCode.usage;
  } on Object catch (error) {
    // VM Service URIs and direct bearer tokens are authentication material.
    // Socket exceptions can echo endpoints, so expose only the stable type.
    stderr.writeln('patchbay transport error: ${error.runtimeType}');
    return PatchbayExitCode.transport;
  } finally {
    await connection?.close();
  }
}

ArgParser patchbayCliParser() => ArgParser()
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show root, group, or command help without connecting to an App.',
  )
  ..addOption('ws-uri', help: 'VM Service http(s) or ws(s) URI.')
  ..addOption('session', help: 'Select one discovered Patchbay session ID.')
  ..addOption(
    'session-dir',
    help: 'Override the Patchbay launcher session directory.',
    hide: true,
  )
  ..addOption(
    'direct-endpoint',
    help: 'Experimental cleartext direct endpoint (never contains a token).',
  )
  ..addFlag(
    'direct-token-stdin',
    defaultsTo: false,
    help: 'Read the direct bearer token from no-echo stdin.',
  )
  ..addOption('direct-application-id', help: 'Expected direct App identity.')
  ..addOption('direct-app-instance-id', help: 'Expected direct App instance.')
  ..addOption(
    'direct-schema-version',
    defaultsTo: '1',
    help: 'Expected direct protocol schema version.',
  )
  ..addOption(
    'transport-timeout-ms',
    defaultsTo: '60000',
    help: 'Direct transport timeout in milliseconds.',
  )
  ..addOption('args', help: 'JSON object passed to a domain command.')
  ..addFlag(
    'stdin',
    defaultsTo: false,
    help: 'Read a sensitive JSON/text value from one no-echo stdin line.',
  )
  ..addFlag(
    'wait',
    defaultsTo: false,
    help: 'Wait for a returned jobId to reach a terminal event.',
  )
  ..addFlag('json', defaultsTo: false, help: 'Print stable JSON.')
  ..addOption('revision', help: 'Observed navigation revision.')
  ..addOption('timeout-ms', help: 'Operation timeout in milliseconds.')
  ..addOption('cursor', help: 'Opaque structured-log cursor.')
  ..addOption(
    'direction',
    allowed: const <String>['forward', 'backward'],
    help: 'Structured-log traversal direction.',
  )
  ..addOption('limit', help: 'Maximum number of log records.')
  ..addOption('levels', help: 'Comma-separated log levels.')
  ..addOption('categories', help: 'Comma-separated log categories.')
  ..addOption('since', help: 'ISO-8601 lower log time bound.')
  ..addOption('until', help: 'ISO-8601 upper log time bound.')
  ..addOption('ttl-ms', help: 'Artifact lifetime in milliseconds.')
  ..addOption('pixel-ratio', help: 'Positive Flutter capture pixel ratio.')
  ..addOption('output', help: 'Local artifact output path.')
  ..addFlag('force', defaultsTo: false, help: 'Replace an existing output.');

List<String>? _helpTopic(ArgResults parsed) {
  final List<String> words = parsed.rest;
  if (words case ['help', ...final List<String> topic]) return topic;
  if (parsed.flag('help')) return words;
  return null;
}

void _validateGlobalShape(ArgResults parsed) {
  final bool direct = parsed.option('direct-endpoint') != null;
  final bool hasVmSelection =
      parsed.option('ws-uri') != null || parsed.option('session') != null;
  if (parsed.option('ws-uri') != null && parsed.option('session') != null) {
    throw const FormatException(
      '--ws-uri and --session are mutually exclusive',
    );
  }
  if (direct && hasVmSelection) {
    throw const FormatException(
      '--direct-endpoint is mutually exclusive with VM session options',
    );
  }
  if (parsed.flag('direct-token-stdin') != direct ||
      (parsed.option('direct-application-id') != null) != direct ||
      (parsed.option('direct-app-instance-id') != null) != direct) {
    throw const FormatException(
      'direct mode requires --direct-endpoint, --direct-token-stdin, '
      '--direct-application-id and --direct-app-instance-id together',
    );
  }
  if (parsed.flag('stdin') && parsed.flag('direct-token-stdin')) {
    throw const FormatException(
      '--stdin and --direct-token-stdin cannot consume the same stdin',
    );
  }
}

Future<PatchbayClient> _connect(ArgResults parsed) async {
  final String? directEndpoint = parsed.option('direct-endpoint');
  if (directEndpoint != null) {
    final Uri endpoint = Uri.parse(directEndpoint);
    if (endpoint.scheme != 'http' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.fragment.isNotEmpty ||
        endpoint.path != PatchbayDirectConnection.protocolPath) {
      throw const FormatException(
        '--direct-endpoint must be a credential-free http URL',
      );
    }
    final int schemaVersion = _positiveOption(parsed, 'direct-schema-version');
    final int timeoutMs = _positiveOption(parsed, 'transport-timeout-ms');
    return PatchbayDirectConnection(
      endpoint: endpoint,
      bearerToken: readSensitiveStdinLine(),
      schemaVersion: schemaVersion,
      applicationId: parsed.option('direct-application-id')!,
      appInstanceId: parsed.option('direct-app-instance-id')!,
      timeout: Duration(milliseconds: timeoutMs),
    );
  }

  final String? uriText = parsed.option('ws-uri');
  if (uriText != null) return PatchbayConnection.connect(Uri.parse(uriText));
  final PatchbaySessionStore sessionStore = PatchbaySessionStore(
    parsed.option('session-dir'),
  );
  final PatchbayDiscoveredSession discovered = await PatchbaySessionResolver(
    store: sessionStore,
  ).resolve(sessionId: parsed.option('session'));
  try {
    return await PatchbayConnection.connect(
      Uri.parse(discovered.record.wsUri!),
      expectedIdentity: discovered.identity,
    );
  } on PatchbayProtocolException {
    sessionStore.remove(discovered.record.sessionId);
    // The transport connected but proved to be a different App/isolate.
    // Removing the stale discovery record is lifecycle cleanup; callers must
    // still receive the protocol/identity exit class (4), not transport (3).
    throw const PatchbayProtocolException('sessionIdentityMismatch');
  } on Object {
    sessionStore.remove(discovered.record.sessionId);
    throw const PatchbaySessionException('sessionStaleTransport');
  }
}

/// Dispatches one resolved declaration.
///
/// There is deliberately no second command table here: every path the CLI
/// accepts comes from [PatchbayFriendlyCommand], and the switch below has no
/// default arm, so a new declaration cannot be added without wiring dispatch
/// and help at the same time.
Future<_Execution> _execute(
  PatchbayClient connection,
  ArgResults parsed,
) async {
  final PatchbayFriendlyInvocation? friendly =
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
  if (friendly == null) {
    throw FormatException(PatchbayCommandHelp.usageLine());
  }
  switch (friendly.spec.target) {
    case PatchbayCommandTarget.clientIdentity:
      return _Execution(await connection.identity());
    case PatchbayCommandTarget.clientCatalog:
      return _Execution(await connection.catalog());
    case PatchbayCommandTarget.clientSnapshot:
      return _Execution(await connection.snapshot());
    case PatchbayCommandTarget.clientWidgetTree:
      return _Execution(await connection.widgetTree());
    case PatchbayCommandTarget.clientRenderTree:
      return _Execution(await connection.renderTree());
    case PatchbayCommandTarget.clientFocusTree:
      return _Execution(await connection.focusTree());
    case PatchbayCommandTarget.declaredServiceCommand:
    case PatchbayCommandTarget.callerServiceCommand:
      final _Invoked result = await _invokeCataloged(
        connection,
        friendly.serviceCommand!,
        friendly.arguments,
        wait: parsed.flag('wait'),
      );
      return _Execution(
        result.response,
        catalog: result.catalog,
        artifact: friendly.spec.artifact == PatchbayArtifactDisposition.none
            ? null
            : _ArtifactRequest(
                disposition: friendly.spec.artifact,
                outputPath: friendly.outputPath!,
                force: friendly.force,
              ),
      );
  }
}

Future<_Invoked> _invokeCataloged(
  PatchbayClient connection,
  String command,
  Map<String, Object?> arguments, {
  required bool wait,
}) async {
  final Map<String, Object?> catalog = await connection.catalog();
  final _CatalogCommand? descriptor = _CatalogCommand.find(catalog, command);
  final Map<String, Object?> admission = await _invokeAgainstCatalog(
    connection,
    catalog,
    command,
    arguments,
    deadline: _declaredWait(arguments),
  );
  final bool serverWaitAvailable =
      _CatalogCommand.find(catalog, 'patchbay.job.wait') != null;
  final Map<String, Object?> response = wait
      ? await _waitForJob(
          connection,
          catalog,
          admission,
          descriptor?.suggestedWaitTimeout,
          serverWaitAvailable: serverWaitAvailable,
        )
      : admission;
  return _Invoked(response, catalog);
}

/// A command that asks the App to wait server-side (`ui.wait`, `logs.tail`,
/// `patchbay.job.wait`) declares that budget in `timeoutMs`. The transport must
/// be told, or a short default transport deadline would abandon — and on the
/// direct transport previously tear down — a request the App is still serving.
Duration? _declaredWait(Map<String, Object?> arguments) {
  final Object? declared = arguments['timeoutMs'];
  return declared is int && declared > 0
      ? Duration(milliseconds: declared)
      : null;
}

Future<Map<String, Object?>> _invokeAgainstCatalog(
  PatchbayClient connection,
  Map<String, Object?> catalog,
  String command,
  Map<String, Object?> arguments, {
  Duration? deadline,
}) async {
  final bool cataloged = _CatalogCommand.find(catalog, command) != null;
  final Map<String, Object?> response = await connection.invoke(
    command: command,
    arguments: arguments,
    deadline: deadline,
  );
  if (!cataloged && !_isCommandNotRegistered(response)) {
    throw const PatchbayProtocolException('catalogInvocationDrift');
  }
  return response;
}

bool _isCommandNotRegistered(Map<String, Object?> response) {
  if (response['admission'] != 'rejected') return false;
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?> &&
      rejection['code'] == 'commandNotRegistered';
}

Future<Map<String, Object?>> _waitForJob(
  PatchbayClient connection,
  Map<String, Object?> catalog,
  Map<String, Object?> admission,
  Duration? descriptorTimeout, {
  required bool serverWaitAvailable,
}) async {
  final Object? jobIdValue = admission['jobId'];
  if (jobIdValue is! String) return admission;
  final Object? admissionPayload = admission['payload'];
  final Object? suggestedMs = admissionPayload is Map
      ? admissionPayload['suggestedWaitTimeoutMs']
      : null;
  final Duration timeout =
      descriptorTimeout ??
      (suggestedMs is int && suggestedMs > 0
          ? Duration(milliseconds: suggestedMs)
          : const Duration(seconds: 60));
  if (!serverWaitAvailable) {
    final Map<String, Object?> response = await waitForPatchbayJob(
      admission: admission,
      timeout: timeout,
      read: (String jobId) => _invokeAgainstCatalog(
        connection,
        catalog,
        'patchbay.job.get',
        <String, Object?>{'jobId': jobId},
      ),
    );
    return <String, Object?>{
      ...response,
      'waitMode': 'legacyPolling',
      'waitNotice':
          'host did not catalog patchbay.job.wait; CLI polled patchbay.job.get',
    };
  }

  final Stopwatch elapsed = Stopwatch()..start();
  var afterSequence = 0;
  while (elapsed.elapsed < timeout) {
    final Duration remaining = timeout - elapsed.elapsed;
    final int requestTimeoutMs = remaining.inMilliseconds.clamp(1, 30000);
    final Map<String, Object?> response = await _invokeAgainstCatalog(
      connection,
      catalog,
      'patchbay.job.wait',
      <String, Object?>{
        'jobId': jobIdValue,
        'afterSequence': afterSequence,
        'timeoutMs': requestTimeoutMs,
      },
      deadline: Duration(milliseconds: requestTimeoutMs),
    );
    if (response['admission'] == 'rejected') return response;
    final Object? payload = response['payload'];
    if (payload is! Map<Object?, Object?>) {
      throw const PatchbayProtocolException('jobWaitPayloadContractViolated');
    }
    final PatchbayJobWaitResultWire result;
    try {
      result = PatchbayJobWaitResultWire.fromJson(
        Map<String, Object?>.from(payload),
      );
    } on Object {
      throw const PatchbayProtocolException('jobWaitPayloadContractViolated');
    }
    for (final PatchbayJobEventWire event in result.snapshot.events) {
      if (event.sequence > afterSequence) afterSequence = event.sequence;
    }
    if (result.snapshot.terminal) {
      return <String, Object?>{
        ...response,
        'payload': <String, Object?>{
          ...result.snapshot.toJson(),
          'waitOutcome': result.outcome.toJson(),
        },
        'waitMode': 'serverLongPoll',
      };
    }
  }
  throw PatchbayJobWaitTimeout(jobIdValue);
}

Map<String, Object?> _artifactMetadata(
  Map<String, Object?> response,
  PatchbayArtifactDisposition disposition,
) {
  final Object? payload = response['payload'];
  if (payload is! Map<String, Object?>) {
    throw const PatchbayArtifactDownloadException(
      'artifactPayloadContractViolated',
    );
  }
  final Object? metadata = switch (disposition) {
    PatchbayArtifactDisposition.responseBlob => payload,
    PatchbayArtifactDisposition.payloadBlob => payload['blob'],
    PatchbayArtifactDisposition.none => null,
  };
  if (metadata is! Map<String, Object?>) {
    throw const PatchbayArtifactDownloadException(
      'artifactMetadataContractViolated',
    );
  }
  return metadata;
}

void _writeOutput(Map<String, Object?> output, {required bool json}) {
  stdout.writeln(
    json
        ? const JsonEncoder.withIndent('  ').convert(output)
        : _summary(output),
  );
}

String _summary(Map<String, Object?> value) {
  if (value['localArtifact'] case final Map<Object?, Object?> artifact) {
    return 'artifact=${artifact['path']} length=${artifact['length']} verified=true';
  }
  if (value case {
    'applicationId': final Object app,
    'appInstanceId': final Object instance,
  }) {
    return '$app instance=$instance';
  }
  if (value['uiTargets'] case final List<Object?> targets) {
    return 'commands=${(value['commands'] as List<Object?>?)?.length ?? 0} '
        'uiTargets=${targets.length}';
  }
  if (value['jobId'] case final String jobId) return 'jobId=$jobId';
  return jsonEncode(value);
}

int _positiveOption(ArgResults options, String name) {
  final int? value = int.tryParse(options.option(name)!);
  if (value == null || value <= 0) {
    throw FormatException('--$name must be a positive integer');
  }
  return value;
}

final class _CatalogCommand {
  const _CatalogCommand(this.suggestedWaitTimeout);

  final Duration? suggestedWaitTimeout;

  static _CatalogCommand? find(Map<String, Object?> catalog, String command) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return null;
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> || row['name'] != command) continue;
      final Object? milliseconds = row['suggestedWaitTimeoutMs'];
      return _CatalogCommand(
        milliseconds is int && milliseconds > 0
            ? Duration(milliseconds: milliseconds)
            : null,
      );
    }
    return null;
  }
}

final class _Invoked {
  const _Invoked(this.response, this.catalog);

  final Map<String, Object?> response;
  final Map<String, Object?> catalog;
}

final class _Execution {
  const _Execution(this.response, {this.catalog, this.artifact});

  final Map<String, Object?> response;
  final Map<String, Object?>? catalog;
  final _ArtifactRequest? artifact;
}

final class _ArtifactRequest {
  const _ArtifactRequest({
    required this.disposition,
    required this.outputPath,
    required this.force,
  });

  final PatchbayArtifactDisposition disposition;
  final String outputPath;
  final bool force;
}
