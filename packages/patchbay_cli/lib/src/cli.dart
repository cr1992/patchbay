import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'artifact_download.dart';
import 'client.dart';
import 'command_help.dart';
import 'command_registry.dart';
import 'direct_connection.dart';
import 'repl.dart';
import 'result.dart';
import 'rpc_timeout.dart';
import 'sensitive_input.dart';
import 'session.dart';

/// Runs one CLI invocation.
///
/// [connect], [replInput], [output] and [errorOutput] are test seams. They let
/// a test observe how many times a session actually dials the App and drive a
/// repl without a terminal; production callers pass none of them.
Future<int> runPatchbayCli(
  List<String> arguments, {
  Future<PatchbayClient> Function(ArgResults options)? connect,
  Stream<String>? replInput,
  StringSink? output,
  StringSink? errorOutput,
}) async {
  final StringSink out = output ?? stdout;
  final StringSink error = errorOutput ?? stderr;
  final ArgParser parser = patchbayCliParser();
  final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (failure) {
    // No ArgResults to ask yet, and a parse failure is exactly the kind of
    // error a `--json` caller still has to be able to read.
    return _fail(
      out,
      error,
      json: _jsonRequestedIn(arguments),
      message: failure.message,
      envelope: _usageEnvelope(failure),
      exitCode: PatchbayExitCode.usage,
    );
  }

  final bool json = parsed.flag('json');
  PatchbayClient? connection;
  try {
    if (_helpTopic(parsed) case final List<String> topic) {
      out.write(PatchbayCommandHelp.render(parser, topic));
      return PatchbayExitCode.accepted;
    }
    _validateGlobalShape(parsed);
    if (parsed.rest.isEmpty) {
      throw FormatException(PatchbayCommandHelp.usageLine());
    }
    final bool repl = _isRepl(parsed);
    if (repl) {
      // Resolve the declaration purely for its option policing: `repl` accepts
      // no command options, and running that check here keeps it derived from
      // the same table as every other path instead of a second hand-written
      // list. The invocation itself is unused — repl dispatches nothing.
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
      _validateReplShape(parsed);
    }
    // Every wait for the App is bounded from here on, dialling included: a
    // peer that stopped answering must not be able to hold the CLI open, and
    // the discovery handshake is a round trip like any other.
    final Duration rpcTimeout = _rpcTimeout(parsed);
    connection = PatchbayTimeoutClient(
      await awaitPatchbayRpc(
        (connect ?? _connect)(parsed),
        rpcTimeout: rpcTimeout,
      ),
      rpcTimeout: rpcTimeout,
    );
    if (repl) {
      return await PatchbayReplSession(
        parser: parser,
        // One connection, every line: this closure is the only thing the loop
        // can reach, so a later command has no way to open a second one.
        execute: (ArgResults line) async {
          final _Outcome outcome = await _executeOnce(connection!, line);
          return PatchbayReplOutcome(outcome.response, outcome.exitCode);
        },
        out: out,
        err: error,
        json: json,
      ).run(
        replInput ??
            stdin.transform(utf8.decoder).transform(const LineSplitter()),
      );
    }
    final _Outcome outcome = await _executeOnce(connection, parsed);
    _writeOutput(out, outcome.response, json: json);
    return outcome.exitCode;
  } on FormatException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: failure.message,
      envelope: _usageEnvelope(failure),
      exitCode: PatchbayExitCode.usage,
    );
  } on PatchbayArtifactDownloadException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay protocol error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(failure.code),
      exitCode: PatchbayExitCode.protocol,
    );
  } on PatchbayProtocolException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay protocol error: ${failure.code}',
      // Whatever the host already said about this failure travels with it: a
      // code alone would send the operator back to re-run the RPC that just
      // answered.
      envelope: PatchbayErrorEnvelope(failure.code, details: failure.details),
      exitCode: PatchbayExitCode.protocol,
    );
  } on PatchbayTransportException catch (failure) {
    final bool unresponsive = failure.code == patchbayAppUnresponsiveCode;
    return _fail(
      out,
      error,
      json: json,
      message: unresponsive
          ? 'patchbay transport error: ${failure.code}\n'
                '  $patchbayAppUnresponsiveHint'
          : 'patchbay transport error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(
        failure.code,
        details: unresponsive
            ? const <String, Object?>{'hint': patchbayAppUnresponsiveHint}
            : const <String, Object?>{},
      ),
      exitCode: PatchbayExitCode.transport,
    );
  } on PatchbaySessionException catch (failure) {
    final StringBuffer message = StringBuffer(
      'patchbay session error: ${failure.code}',
    );
    for (final String choice in failure.choices) {
      message.write('\n  --session ${choice.split(' ').first}  $choice');
    }
    return _fail(
      out,
      error,
      json: json,
      message: message.toString(),
      // The labels are already URI-free — that is what makes them printable —
      // so the JSON reader gets the same choices the operator sees.
      envelope: PatchbayErrorEnvelope(
        failure.code,
        details: <String, Object?>{
          if (failure.choices.isNotEmpty) 'sessions': failure.choices,
        },
      ),
      exitCode: failure.code == 'sessionIdentityMismatch'
          ? PatchbayExitCode.protocol
          : PatchbayExitCode.transport,
    );
  } on PatchbayJobWaitTimeout catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay job failed: waitTimeout',
      envelope: PatchbayErrorEnvelope(
        'waitTimeout',
        details: <String, Object?>{'jobId': failure.jobId},
      ),
      exitCode: PatchbayExitCode.typedFailure,
    );
  } on PatchbaySensitiveInputException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay sensitive input error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(failure.code),
      exitCode: PatchbayExitCode.usage,
    );
  } on Object catch (failure) {
    // VM Service URIs and direct bearer tokens are authentication material.
    // Socket exceptions can echo endpoints, so expose only the stable type.
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay transport error: ${failure.runtimeType}',
      envelope: PatchbayErrorEnvelope(
        'transportError',
        details: <String, Object?>{'type': '${failure.runtimeType}'},
      ),
      exitCode: PatchbayExitCode.transport,
    );
  } finally {
    await connection?.close();
  }
}

/// Reports one failure on both channels and returns its exit code.
///
/// stderr keeps the sentence it always printed. `--json` adds the machine
/// envelope on stdout, so stdout under `--json` is exactly one JSON document —
/// the response or the error — and never a mix of JSON and prose.
int _fail(
  StringSink out,
  StringSink error, {
  required bool json,
  required String message,
  required PatchbayErrorEnvelope envelope,
  required int exitCode,
}) {
  error.writeln(message);
  if (json) {
    out.writeln(const JsonEncoder.withIndent('  ').convert(envelope.toJson()));
  }
  return exitCode;
}

/// Usage errors have no code of their own; the sentence is the detail.
PatchbayErrorEnvelope _usageEnvelope(FormatException failure) =>
    PatchbayErrorEnvelope(
      'usageError',
      details: <String, Object?>{'message': failure.message},
    );

/// Whether `--json` appears in raw argv, for failures that precede parsing.
bool _jsonRequestedIn(List<String> arguments) {
  var json = false;
  for (final String word in arguments) {
    if (word == '--') break;
    if (word == '--json') json = true;
    if (word == '--no-json') json = false;
  }
  return json;
}

/// Whether this invocation opens a reusable session instead of one command.
bool _isRepl(ArgResults parsed) =>
    parsed.rest.length == 1 && parsed.rest.single == 'repl';

void _validateReplShape(ArgResults parsed) {
  // Direct mode reads its bearer token from stdin, which is the same stream
  // the repl needs for commands. Sharing one stdin between a secret and a
  // command stream is how a token ends up interpreted as a command, so refuse
  // the combination instead of racing the two readers.
  if (parsed.option('direct-endpoint') != null) {
    throw const FormatException(
      'repl cannot use --direct-endpoint: the bearer token and the command '
      'stream would have to share one stdin',
    );
  }
}

/// Runs one resolved command and classifies its response.
///
/// One-shot and repl share this so a command cannot mean two different things
/// depending on how it was launched.
Future<_Outcome> _executeOnce(
  PatchbayClient connection,
  ArgResults parsed,
) async {
  try {
    final _Execution execution = await _execute(connection, parsed);
    Map<String, Object?> output = execution.response;
    if (execution.artifact case final _ArtifactRequest artifact) {
      if (patchbayExitCodeFor(output) == PatchbayExitCode.accepted) {
        final PatchbayDownloadedArtifact downloaded =
            await PatchbayArtifactDownloader(
              chunkBytes: _blobChunkBytes(execution.catalog!),
              invoke: (String command, Map<String, Object?> arguments) =>
                  _invokeAgainstCatalog(
                    connection,
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
    return _Outcome(output, patchbayExitCodeFor(output));
  } on PatchbayArtifactRejected catch (rejected) {
    // The App answered; the artifact simply is not downloadable. That is a
    // normal typed response, not a CLI-level error.
    return _Outcome(
      rejected.response,
      patchbayExitCodeFor(rejected.response),
    );
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
    // One source for the number: an option default that drifted from the
    // documented one would make the exported constant a lie.
    defaultsTo: '${patchbayDefaultRpcTimeout.inMilliseconds}',
    help:
        'Per-RPC timeout in milliseconds, on every transport. A command that '
        'asks the App to wait (--timeout-ms) extends its own request by this '
        'much rather than being cut short by it.',
  )
  ..addOption('args', help: 'JSON object passed to a domain command.')
  ..addFlag(
    'stdin',
    defaultsTo: false,
    help: 'Read one no-echo stdin line; JSON merges over --args, stdin wins.',
  )
  ..addFlag(
    'wait',
    defaultsTo: false,
    help: 'Wait for a returned jobId to reach a terminal event.',
  )
  ..addFlag('json', defaultsTo: false, help: 'Print stable JSON.')
  ..addOption('revision', help: 'Observed navigation revision.')
  ..addOption(
    'generation',
    help: 'Expected semantics generation; refuses a target that already moved.',
  )
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

/// The per-RPC budget this invocation runs under.
///
/// `--transport-timeout-ms` already existed as the direct transport's socket
/// budget and was silently ignored everywhere else. It is the same quantity —
/// how long the CLI waits for one answer — so it governs every transport rather
/// than growing a second switch beside it. `--timeout-ms` keeps its own,
/// different meaning: the wait the *App* is asked to perform, which is sent on
/// the wire and which extends this budget instead of competing with it.
Duration _rpcTimeout(ArgResults parsed) =>
    Duration(milliseconds: _positiveOption(parsed, 'transport-timeout-ms'));

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
    return PatchbayDirectConnection(
      endpoint: endpoint,
      bearerToken: readSensitiveStdinLine(),
      schemaVersion: schemaVersion,
      applicationId: parsed.option('direct-application-id')!,
      appInstanceId: parsed.option('direct-app-instance-id')!,
      timeout: _rpcTimeout(parsed),
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
    case PatchbayCommandTarget.clientReplSession:
      // `runPatchbayCli` routes a repl to its own loop before dispatch, and
      // the loop refuses a nested `repl` line, so reaching here is a wiring
      // bug rather than caller input.
      throw StateError('repl is a session, not a dispatchable command');
    case PatchbayCommandTarget.declaredServiceCommand:
    case PatchbayCommandTarget.callerServiceCommand:
      final String command = friendly.serviceCommand!;
      final Map<String, Object?> catalog = await connection.catalog();
      _refuseSensitiveArgv(catalog, command, friendly.plaintextArgumentKeys);
      Map<String, Object?> arguments = friendly.arguments;
      if (friendly.resolvesRevision) {
        final Map<String, Object?> current = await _invokeAgainstCatalog(
          connection,
          catalog,
          'navigation.current',
          const <String, Object?>{},
        );
        // A refused read is reported as itself, marked with where it came
        // from: pretending the navigation command was refused would hide which
        // gate actually spoke.
        if (current['admission'] == 'rejected') {
          return _Execution(_withRevisionSource(current), catalog: catalog);
        }
        arguments = <String, Object?>{
          ...arguments,
          'revision': _navigationRevision(current),
        };
      }
      final Map<String, Object?> response = await _invokeCataloged(
        connection,
        catalog,
        command,
        arguments,
        wait: parsed.flag('wait'),
      );
      return _Execution(
        friendly.resolvesRevision ? _withRevisionSource(response) : response,
        catalog: catalog,
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

/// The `blob.read` chunk size this host will actually accept.
///
/// The descriptor declares the host's ceiling as the `limit` default and the
/// host refuses anything above it, so the CLI asks for no more than the App
/// offers. Taking the smaller of the two keeps a host that raises its ceiling
/// from silently enlarging every CLI request as well.
int _blobChunkBytes(Map<String, Object?> catalog) {
  final int? declared = _CatalogCommand.find(
    catalog,
    'blob.read',
  )?.positiveIntegerDefault('limit');
  if (declared == null) return PatchbayArtifactDownloader.defaultChunkBytes;
  return min(declared, PatchbayArtifactDownloader.defaultChunkBytes);
}

/// Marks a response whose revision fence the CLI read instead of the caller.
///
/// The marker is the only trace the convenience leaves in the output: a reader
/// can tell an operator-observed revision from one the CLI fetched a moment
/// before dispatching, which is exactly the difference that matters when a
/// navigation raced the command.
Map<String, Object?> _withRevisionSource(Map<String, Object?> response) =>
    <String, Object?>{...response, 'revisionSource': 'navigation.current'};

/// The revision an App reports as current, or a protocol error.
int _navigationRevision(Map<String, Object?> response) {
  final Object? payload = response['payload'];
  final Object? revision = payload is Map<Object?, Object?>
      ? payload['navigationRevision']
      : null;
  if (revision is! int || revision < 0) {
    throw const PatchbayProtocolException('navigationRevisionContractViolated');
  }
  return revision;
}

/// Refuses to send a catalog-declared sensitive parameter through argv.
///
/// `--stdin` merges over `--args`, so "this request used stdin" no longer
/// implies "every value came from stdin". Only the descriptor knows which key
/// is sensitive, and the CLI already holds the catalog here, so the check
/// belongs on this side of the wire: a secret must never reach argv, where the
/// shell history records it.
void _refuseSensitiveArgv(
  Map<String, Object?> catalog,
  String command,
  Set<String> plaintextKeys,
) {
  if (plaintextKeys.isEmpty) return;
  final _CatalogCommand? descriptor = _CatalogCommand.find(catalog, command);
  if (descriptor == null) return;
  for (final String name in plaintextKeys) {
    if (!descriptor.sensitiveParameters.contains(name)) continue;
    throw FormatException(
      '$command declares "$name" sensitive: it must come from --stdin, '
      'never from --args',
    );
  }
}

Future<Map<String, Object?>> _invokeCataloged(
  PatchbayClient connection,
  Map<String, Object?> catalog,
  String command,
  Map<String, Object?> arguments, {
  required bool wait,
}) async {
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
  return wait
      ? await _waitForJob(
          connection,
          catalog,
          admission,
          descriptor?.suggestedWaitTimeout,
          serverWaitAvailable: serverWaitAvailable,
        )
      : admission;
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
    throw PatchbayProtocolException(
      'catalogInvocationDrift',
      details: _driftDetails(command, catalog, response),
    );
  }
  return response;
}

/// What the host already said about the catalog this invoke disagreed with.
///
/// `catalogInvocationDrift` means "the command is absent from the catalog and
/// the App did not answer `commandNotRegistered` either". By far the most
/// common cause is a catalog the host itself refused to serve — an invalid or
/// duplicated command name — and the host answers with the precise reason in
/// `details.catalog`. Throwing a bare code discarded exactly that half, leaving
/// an operator to re-run `patchbay catalog` to learn what this response already
/// carried. Everything here is host data passed through unchanged.
Map<String, Object?> _driftDetails(
  String command,
  Map<String, Object?> catalog,
  Map<String, Object?> response,
) {
  final Map<Object?, Object?>? rejection = _rejectionOf(response);
  final Object? details = rejection?['details'];
  final Object? reason = details is Map<Object?, Object?>
      ? details['reason']
      : null;
  // The invoke answer describes this request, so it wins. The catalog read is
  // the fallback for a host that refused the catalog without repeating why in
  // the invoke response.
  final Object? violation = details is Map<Object?, Object?>
      ? details['catalog']
      : null;
  final Object? fromCatalog = _rejectionOf(catalog)?['details'];
  return <String, Object?>{
    'command': command,
    if (rejection?['code'] case final String code) 'rejection': code,
    if (reason case final String value) 'reason': value,
    if (violation ?? fromCatalog case final Object value) 'catalog': value,
  };
}

Map<Object?, Object?>? _rejectionOf(Map<String, Object?> response) {
  if (response['admission'] != 'rejected') return null;
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?> ? rejection : null;
}

bool _isCommandNotRegistered(Map<String, Object?> response) =>
    _rejectionOf(response)?['code'] == 'commandNotRegistered';

/// Waits for an admitted job and returns its terminal response.
///
/// The admission envelope carries `jobId` at the top level while a job snapshot
/// carries its own inside `payload`, so `--wait` used to answer with the id in
/// a different place than the request that started it. Both stay — the payload
/// one is the App's snapshot field — but the top level is restated here so one
/// path reads the same in both outputs: **top-level `jobId` is the stable place
/// to read the id of the job this command admitted.**
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
      // The admitted job id, restated at the top level. See `_waitForJob`.
      'jobId': jobIdValue,
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
        'jobId': jobIdValue,
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

void _writeOutput(
  StringSink out,
  Map<String, Object?> output, {
  required bool json,
}) {
  out.writeln(
    json
        ? const JsonEncoder.withIndent('  ').convert(output)
        : patchbayResponseSummary(output),
  );
}

int _positiveOption(ArgResults options, String name) {
  final int? value = int.tryParse(options.option(name)!);
  if (value == null || value <= 0) {
    throw FormatException('--$name must be a positive integer');
  }
  return value;
}

/// One catalog row, read only for what the CLI itself has to decide.
///
/// The row stays the App's data: nothing here upgrades it into a capability
/// claim. The parameter declarations matter because two CLI-side decisions —
/// which value may never touch argv, and how large a `blob.read` chunk the host
/// will accept — are the App's to make, not the CLI's to hardcode.
final class _CatalogCommand {
  const _CatalogCommand(this.suggestedWaitTimeout, this._parameters);

  final Duration? suggestedWaitTimeout;
  final List<Map<Object?, Object?>> _parameters;

  Set<String> get sensitiveParameters => <String>{
    for (final Map<Object?, Object?> parameter in _parameters)
      if (parameter['sensitive'] == true)
        if (parameter['name'] case final String name) name,
  };

  /// Positive integer default declared for [name], when the App declares one.
  int? positiveIntegerDefault(String name) {
    for (final Map<Object?, Object?> parameter in _parameters) {
      if (parameter['name'] != name) continue;
      final Object? value = parameter['defaultValue'];
      return value is int && value > 0 ? value : null;
    }
    return null;
  }

  static _CatalogCommand? find(Map<String, Object?> catalog, String command) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return null;
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> || row['name'] != command) continue;
      final Object? milliseconds = row['suggestedWaitTimeoutMs'];
      final Object? parameters = row['parameters'];
      return _CatalogCommand(
        milliseconds is int && milliseconds > 0
            ? Duration(milliseconds: milliseconds)
            : null,
        <Map<Object?, Object?>>[
          if (parameters is List<Object?>)
            for (final Object? parameter in parameters)
              if (parameter is Map<Object?, Object?>) parameter,
        ],
      );
    }
    return null;
  }
}

final class _Outcome {
  const _Outcome(this.response, this.exitCode);

  final Map<String, Object?> response;
  final int exitCode;
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
