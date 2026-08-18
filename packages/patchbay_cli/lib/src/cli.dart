import 'dart:async';
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
import 'doctor.dart';
import 'keep_awake_policy.dart';
import 'launcher.dart';
import 'performance_profile.dart';
import 'permission_command.dart';
import 'permission_driver.dart';
import 'repl.dart';
import 'request_id.dart';
import 'result.dart';
import 'rpc_timeout.dart';
import 'sensitive_input.dart';
import 'session.dart';
import 'trace.dart';
import 'ui_manifest.dart';

const Symbol _traceZoneInitializedKey = #patchbayTraceZoneInitialized;
const Symbol _traceRecorderKey = #patchbayTraceRecorder;
const Symbol _traceIncludeLegacyPayloadKey = #patchbayTraceIncludeLegacyPayload;

PatchbayTraceRecorder? get _traceRecorder =>
    Zone.current[_traceRecorderKey] as PatchbayTraceRecorder?;

bool get _traceIncludesLegacyPayload =>
    Zone.current[_traceIncludeLegacyPayloadKey] == true;

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
  PatchbayPermissionCommandRunner? permissionCommands,
  Map<String, String>? environment,
}) async {
  if (Zone.current[_traceZoneInitializedKey] != true) {
    return _runPatchbayCliWithTrace(
      arguments,
      connect: connect,
      replInput: replInput,
      output: output,
      errorOutput: errorOutput,
      permissionCommands: permissionCommands,
      environment: environment,
    );
  }
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
  PatchbayKeepAwakePolicy? keepAwakePolicy;
  PatchbayKeepAwakePolicy resolveKeepAwakePolicy() =>
      keepAwakePolicy ??= PatchbayKeepAwakePolicy.resolve(
        commandLine: parsed.wasParsed('keep-awake')
            ? parsed.flag('keep-awake')
            : null,
        environment: environment ?? Platform.environment,
      );
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
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localLauncher) {
      final PatchbayFriendlyInvocation invocation =
          PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
      final String launchId =
          'launch-${pid}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final Completer<void> cancellation = Completer<void>();
      final List<StreamSubscription<ProcessSignal>> signalSubscriptions =
          <StreamSubscription<ProcessSignal>>[];
      void watch(ProcessSignal signal) {
        try {
          signalSubscriptions.add(
            signal.watch().listen((_) {
              if (!cancellation.isCompleted) cancellation.complete();
            }),
          );
        } on Object {
          // Some signals are unavailable on Windows. Lease expiry remains the
          // crash-safe release path there.
        }
      }

      watch(ProcessSignal.sigint);
      watch(ProcessSignal.sigterm);
      try {
        final PatchbayLaunchResult result =
            await PatchbayLauncherSupervisor(
              store: PatchbaySessionStore(parsed.option('session-dir')),
            ).run(
              command: List<String>.from(
                invocation.arguments['command']! as List<Object?>,
              ),
              launchId: launchId,
              ownerPid: pid,
              onFrame: (PatchbayLaunchFrame frame) =>
                  out.writeln(jsonEncode(frame.toJson())),
              onHumanLine: error.writeln,
              keepAwakePolicy: resolveKeepAwakePolicy(),
              cancellation: cancellation.future,
            );
        return result.exitCode;
      } finally {
        for (final StreamSubscription<ProcessSignal> subscription
            in signalSubscriptions) {
          await subscription.cancel();
        }
      }
    }
    // Session bookkeeping answers before any transport exists: these commands
    // are what an operator reaches for when the CLI cannot pick a session, so
    // dialling first would make them unavailable exactly when they are needed.
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localSessionStore) {
      final _LocalOutcome outcome = _runLocalSessionCommand(parsed);
      out.writeln(
        json
            ? const JsonEncoder.withIndent('  ').convert(outcome.response)
            : outcome.text,
      );
      return PatchbayExitCode.accepted;
    }
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localTraceStore) {
      final _LocalOutcome outcome = _runLocalTraceCommand(parsed);
      out.writeln(
        json
            ? const JsonEncoder.withIndent('  ').convert(outcome.response)
            : outcome.text,
      );
      return PatchbayExitCode.accepted;
    }
    // Doctor owns its own dial for the same reason: a failed connection is its
    // subject matter, not its failure mode, so it must not be routed through
    // the dispatcher's dial-then-execute path — that path is the one whose
    // errors doctor exists to explain.
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localDiagnostics) {
      // Resolved only for its shape policing: doctor takes no arguments and no
      // command options, and that rule stays derived from the same table as
      // every other command instead of being re-stated here.
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
      final PatchbayDoctorReport report = await runPatchbayDoctor(
        options: parsed,
        connect: connect ?? _connect,
        rpcTimeout: _rpcTimeout(parsed),
      );
      out.writeln(
        json
            ? const JsonEncoder.withIndent('  ').convert(report.toJson())
            : report.render().trimRight(),
      );
      return report.exitCode;
    }
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localPermissionDriver) {
      final PatchbayFriendlyInvocation invocation =
          PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
      final PatchbayPermissionCommandOutcome outcome =
          await (permissionCommands ?? PatchbayPermissionCommandRunner()).run(
            parsed,
            invocation,
          );
      _writeOutput(out, outcome.response, json: json, summary: outcome.summary);
      return outcome.exitCode;
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
    // The manifest is read and parsed before the dial, because it is caller
    // input and a file the CLI refuses to read is the author's news whether or
    // not an App happens to be reachable. Dialling first answered a syntax
    // error with `sessionDirectoryEmpty`, which sends the author to look for a
    // device when the actual problem is a comma in the file they just wrote.
    final PatchbayUiManifest? manifest = _preReadUiManifest(parsed);
    // Every wait for the App is bounded from here on, dialling included: a
    // peer that stopped answering must not be able to hold the CLI open, and
    // the discovery handshake is a round trip like any other.
    final Duration rpcTimeout = _rpcTimeout(parsed);
    connection = PatchbayTimeoutClient(
      await dialPatchbayUnderBudget(
        () => (connect ?? _connect)(parsed),
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
          final PatchbayTraceRecorder? trace = _traceRecorder;
          final PatchbayFriendlyCommand? lineSpec =
              PatchbayFriendlyCommandRegistry.specFor(line.rest);
          final String? runId = trace == null || lineSpec == null
              ? null
              : trace.commandStarted(
                  lineSpec.path.join(' '),
                  transport: _traceTransport(parsed),
                );
          final _Outcome outcome = await _renewKeepAwakeAfterSuccess(
            connection!,
            line,
            await _executeOnce(connection, line),
            resolveKeepAwakePolicy(),
          );
          if (runId != null) trace!.commandFinished(runId, outcome.exitCode);
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
    final _Outcome outcome = await _renewKeepAwakeAfterSuccess(
      connection,
      parsed,
      await _executeOnce(connection, parsed, manifest: manifest),
      resolveKeepAwakePolicy(),
    );
    _writeOutput(out, outcome.response, json: json, summary: outcome.summary);
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
    if (failure.hint case final String hint) message.write('\n  $hint');
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
          if (failure.hint case final String hint) 'hint': hint,
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
  } on PatchbayUiManifestException catch (failure) {
    // Caller input the CLI refused to read, so it is a usage error like any
    // other bad argument — but a file has more than one way to be wrong, and
    // the envelope has to say which one rather than leave the author bisecting.
    return _fail(
      out,
      error,
      json: json,
      message: failure.sentence,
      envelope: PatchbayErrorEnvelope(failure.code, details: failure.details),
      exitCode: PatchbayExitCode.usage,
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
  } on PatchbayPermissionDriverException catch (failure) {
    if (failure.diagnostic case final String diagnostic) {
      error.writeln(diagnostic);
    }
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay permission driver error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(failure.code, details: failure.details),
      exitCode: failure.code == 'permissionTimeoutInvalid'
          ? PatchbayExitCode.usage
          : PatchbayExitCode.typedFailure,
    );
  } on PatchbayTraceException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay trace error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(failure.code, details: failure.details),
      exitCode: PatchbayExitCode.protocol,
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
    await closePatchbayQuietly(connection);
  }
}

Future<int> _runPatchbayCliWithTrace(
  List<String> arguments, {
  Future<PatchbayClient> Function(ArgResults options)? connect,
  Stream<String>? replInput,
  StringSink? output,
  StringSink? errorOutput,
  PatchbayPermissionCommandRunner? permissionCommands,
  Map<String, String>? environment,
}) async {
  final ArgResults? parsed = _tryParseForTrace(arguments);
  final PatchbayFriendlyCommand? spec = parsed == null
      ? null
      : PatchbayFriendlyCommandRegistry.specFor(parsed.rest);
  if (parsed == null ||
      spec == null ||
      spec.target == PatchbayCommandTarget.localTraceStore ||
      _helpTopic(parsed) != null) {
    return runZoned(
      () => runPatchbayCli(
        arguments,
        connect: connect,
        replInput: replInput,
        output: output,
        errorOutput: errorOutput,
        permissionCommands: permissionCommands,
        environment: environment,
      ),
      zoneValues: const <Object?, Object?>{_traceZoneInitializedKey: true},
    );
  }

  final StringSink out = output ?? stdout;
  final StringSink error = errorOutput ?? stderr;
  final bool json = parsed.flag('json');
  try {
    final PatchbayTraceStore store = PatchbayTraceStore(
      parsed.option('trace-dir'),
    );
    final String? traceId = store.resolve(parsed.option('trace'));
    if (traceId == null) {
      return runZoned(
        () => runPatchbayCli(
          arguments,
          connect: connect,
          replInput: replInput,
          output: output,
          errorOutput: errorOutput,
          permissionCommands: permissionCommands,
          environment: environment,
        ),
        zoneValues: const <Object?, Object?>{_traceZoneInitializedKey: true},
      );
    }
    final bool includeLegacy = _confirmLegacyPayload(parsed);
    final PatchbayTraceRecorder recorder = store.recorder(traceId);
    final String runId = recorder.commandStarted(
      spec.path.join(' '),
      transport: _traceTransport(parsed),
    );
    if (_traceSessionRef(parsed) case final Map<String, Object?> sessionRef) {
      recorder.sessionObserved(sessionRef);
    }
    final int exitCode = await runZoned(
      () => runPatchbayCli(
        arguments,
        connect: connect,
        replInput: replInput,
        output: output,
        errorOutput: errorOutput,
        permissionCommands: permissionCommands,
        environment: environment,
      ),
      zoneValues: <Object?, Object?>{
        _traceZoneInitializedKey: true,
        _traceRecorderKey: recorder,
        _traceIncludeLegacyPayloadKey: includeLegacy,
      },
    );
    recorder.commandFinished(runId, exitCode);
    return exitCode;
  } on FormatException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: failure.message,
      envelope: _usageEnvelope(failure),
      exitCode: PatchbayExitCode.usage,
    );
  } on PatchbayTraceException catch (failure) {
    return _fail(
      out,
      error,
      json: json,
      message: 'patchbay trace error: ${failure.code}',
      envelope: PatchbayErrorEnvelope(failure.code, details: failure.details),
      exitCode: PatchbayExitCode.protocol,
    );
  }
}

ArgResults? _tryParseForTrace(List<String> arguments) {
  try {
    return patchbayCliParser().parse(arguments);
  } on FormatException {
    return null;
  }
}

bool _confirmLegacyPayload(ArgResults parsed) {
  if (!parsed.flag('include-legacy-payload')) return false;
  if (parsed.flag('stdin') || parsed.flag('direct-token-stdin')) {
    throw const FormatException(
      '--include-legacy-payload cannot share stdin with command or direct '
      'credential input',
    );
  }
  if (!stdin.hasTerminal) {
    if (!parsed.flag('allow-non-tty-legacy-payload')) {
      throw const FormatException(
        '--include-legacy-payload requires a TTY confirmation; automation '
        'must also pass --allow-non-tty-legacy-payload',
      );
    }
    return true;
  }
  stderr.write(
    'Legacy host payloads have no persistence metadata. Type INCLUDE to '
    'store their re-redacted values: ',
  );
  final String? confirmation = stdin.readLineSync();
  if (confirmation == null) {
    throw const FormatException(
      '--include-legacy-payload requires a TTY confirmation; automation '
      'must also pass --allow-non-tty-legacy-payload',
    );
  }
  if (confirmation != 'INCLUDE') {
    throw const FormatException('legacy payload confirmation refused');
  }
  return true;
}

String _traceTransport(ArgResults parsed) {
  if (parsed.option('direct-endpoint') != null) return 'direct';
  return 'vmService';
}

Map<String, Object?>? _traceSessionRef(ArgResults parsed) {
  if (parsed.option('direct-endpoint') != null) {
    return <String, Object?>{
      'mode': 'direct',
      'applicationId': parsed.option('direct-application-id'),
      'appInstanceId': parsed.option('direct-app-instance-id'),
    };
  }
  if (parsed.option('session') case final String sessionId) {
    return <String, Object?>{'mode': 'launcher', 'sessionId': sessionId};
  }
  if (parsed.option('ws-uri') != null) {
    return const <String, Object?>{'mode': 'explicitVmService'};
  }
  final PatchbaySessionStore sessions = PatchbaySessionStore(
    parsed.option('session-dir'),
  );
  final List<PatchbaySessionRecord> records = sessions.readAll();
  final String? selected = sessions.readSelection();
  PatchbaySessionRecord? record;
  for (final PatchbaySessionRecord candidate in records) {
    if (candidate.sessionId == selected) record = candidate;
  }
  record ??= records.length == 1 ? records.single : null;
  if (record == null) return null;
  return <String, Object?>{
    'mode': 'launcher',
    'sessionId': record.sessionId,
    'applicationId': record.applicationId,
    'appInstanceId': record.appInstanceId,
    'deviceId': record.deviceId,
    'buildMode': record.buildMode,
  };
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
  ArgResults parsed, {
  PatchbayUiManifest? manifest,
}) async {
  try {
    final _Execution execution = await _execute(
      connection,
      parsed,
      manifest: manifest,
    );
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
        _traceRecorder?.attachArtifact(
          localPath: downloaded.path,
          blobId: downloaded.blobId,
          sha256Value: downloaded.sha256,
          length: downloaded.length,
          contentType: downloaded.contentType,
        );
        output = <String, Object?>{
          ...output,
          'localArtifact': downloaded.toJson(),
        };
      }
    }
    // A locally computed verdict classifies itself; everything that came off
    // the wire is classified by what the App answered.
    return _Outcome(
      output,
      execution.exitCode ?? patchbayExitCodeFor(output),
      summary: execution.summary,
    );
  } on PatchbayArtifactRejected catch (rejected) {
    // The App answered; the artifact simply is not downloadable. That is a
    // normal typed response, not a CLI-level error.
    return _Outcome(rejected.response, patchbayExitCodeFor(rejected.response));
  }
}

Future<_Outcome> _renewKeepAwakeAfterSuccess(
  PatchbayClient connection,
  ArgResults parsed,
  _Outcome outcome,
  PatchbayKeepAwakePolicy policy,
) async {
  if (!policy.enabled || outcome.exitCode != PatchbayExitCode.accepted) {
    return outcome;
  }
  final String? serviceCommand = PatchbayFriendlyCommandRegistry.specFor(
    parsed.rest,
  )?.serviceCommand;
  // Generated active specs are the authority after command-surface sync; the
  // deprecated enum façade is not guaranteed to preserve object identity.
  if (serviceCommand == 'ui.keepAwake.set' ||
      serviceCommand == 'ui.keepAwake.status') {
    return outcome;
  }
  final PatchbayKeepAwakeAttempt renewal = await requestPatchbayKeepAwake(
    connection,
    enabled: true,
    lease: policy.lease,
  );
  final String originalSummary =
      outcome.summary ?? patchbayResponseSummary(outcome.response);
  final String keepAwakeSummary = renewal.reasonCode == null
      ? 'keepAwake=${renewal.state}'
      : 'keepAwake=${renewal.state} reason=${renewal.reasonCode}';
  return _Outcome(
    <String, Object?>{...outcome.response, 'localKeepAwake': renewal.toJson()},
    renewal.success ? outcome.exitCode : PatchbayExitCode.typedFailure,
    summary: '$originalSummary $keepAwakeSummary',
  );
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
    'trace',
    help: 'Append this command to an explicit local debug trace ID.',
  )
  ..addOption(
    'trace-dir',
    help: 'Override the local Patchbay trace directory.',
    hide: true,
  )
  ..addFlag(
    'include-legacy-payload',
    defaultsTo: false,
    help:
        'Persist re-redacted values from legacy hosts after explicit '
        'confirmation.',
  )
  ..addFlag(
    'allow-non-tty-legacy-payload',
    defaultsTo: false,
    help: 'Explicitly allow legacy payload persistence without a TTY.',
    hide: true,
  )
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
  ..addOption(
    'path',
    help:
        'Dot path into the snapshot (a.b.c); answers that field or subtree '
        'instead of the whole snapshot.',
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
  ..addFlag(
    'keep-awake',
    defaultsTo: false,
    help:
        'Renew the App keep-awake lease after successful commands; launch '
        'also holds it for the supervised session. Disabled by default.',
  )
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
  // One option, two commands, never both at once: `_validateOptions` refuses
  // it for every command that does not list it, so the two readings can never
  // meet. The help says both because a shared option that documents only one
  // of them is the kind of lie an operator finds out about at the prompt.
  ..addOption(
    'until',
    help:
        'logs query|export: ISO-8601 upper time bound. snapshot wait: the '
        'condition to wait for (exists|absent|equals).',
  )
  ..addOption(
    'ttl-ms',
    help: 'Artifact lifetime, or inspect select-mode lease, in milliseconds.',
  )
  ..addOption(
    'lease-ms',
    help:
        'Keep-awake lease in milliseconds; the App releases the screen on its '
        'own when it runs out. Omit to use the App-declared default.',
  )
  ..addOption('pixel-ratio', help: 'Positive Flutter capture pixel ratio.')
  ..addOption(
    'duration-ms',
    help: 'Performance profile window in milliseconds (1..60000).',
  )
  ..addOption(
    'sample-limit',
    help: 'Maximum VM timeline events summarized (1..10000).',
  )
  ..addOption('output', help: 'Local artifact output path.')
  ..addOption('name', help: 'Human-readable local trace name.')
  ..addFlag(
    'activate',
    defaultsTo: false,
    help: 'Select the new trace for this workspace.',
  )
  ..addFlag(
    'pin',
    defaultsTo: false,
    help: 'Exclude the new trace from retention pruning.',
  )
  ..addFlag(
    'dry-run',
    defaultsTo: false,
    help: 'Report retention candidates without deleting them.',
  )
  ..addFlag(
    'include-artifacts',
    defaultsTo: true,
    help: 'Include content-addressed artifacts in a trace export.',
  )
  ..addFlag('force', defaultsTo: false, help: 'Replace an existing output.')
  ..addFlag(
    'clear',
    defaultsTo: false,
    help: 'Unpin the selected session instead of selecting one.',
  )
  ..addOption(
    'permission-driver',
    help: 'Explicit external permission driver executable path.',
  )
  ..addOption('device-id', help: 'Explicit platform device selection.')
  ..addOption('application-id', help: 'Explicit platform application ID.')
  ..addOption(
    'state',
    allowed: <String>[
      for (final PatchbayPermissionState state
          in PatchbayPermissionState.values)
        state.name,
    ],
    help: 'Desired or required closed permission state.',
  )
  ..addOption(
    'decision',
    allowed: <String>[
      for (final PatchbayPermissionDecision decision
          in PatchbayPermissionDecision.values)
        decision.name,
    ],
    help: 'System permission decision for exercise.',
  )
  ..addFlag(
    'confirm-system-permission',
    defaultsTo: false,
    negatable: false,
    help: 'Explicitly confirm an exercise allow system permission action.',
  )
  ..addFlag(
    'emit-manifest',
    defaultsTo: false,
    negatable: false,
    help: 'Emit a v2 draft covering only targets mounted right now.',
  )
  ..addFlag(
    'navigate',
    defaultsTo: false,
    negatable: false,
    help: 'Opt in to navigation side effects and verify every destination.',
  )
  ..addFlag(
    'continue-on-error',
    defaultsTo: false,
    negatable: false,
    help: 'Continue the destination walkthrough after a screen fails.',
  )
  ..addFlag(
    'restore',
    defaultsTo: false,
    negatable: false,
    help: 'Try to restore the initial destination after a walkthrough.',
  )
  ..addOption(
    'screen-timeout-ms',
    help: 'Per-destination walkthrough budget (default 5000, max 120000).',
  )
  ..addOption(
    'total-timeout-ms',
    help: 'Whole walkthrough budget (default 120000, max 600000).',
  );

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
  if (parsed.flag('allow-non-tty-legacy-payload') &&
      !parsed.flag('include-legacy-payload')) {
    throw const FormatException(
      '--allow-non-tty-legacy-payload requires --include-legacy-payload',
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

/// Runs one session-directory command: no transport, no catalog, no App.
///
/// The switch has no default arm for the declarations it handles, so a fourth
/// local command cannot be declared without being wired here.
_LocalOutcome _runLocalSessionCommand(ArgResults parsed) {
  _validateLocalSessionShape(parsed);
  final PatchbayFriendlyInvocation friendly =
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
  final PatchbaySessionResolver sessions = PatchbaySessionResolver(
    store: PatchbaySessionStore(parsed.option('session-dir')),
  );
  return switch (friendly.spec) {
    PatchbayFriendlyCommand.sessionsList => _listSessions(sessions),
    PatchbayFriendlyCommand.sessionsPrune => _pruneSessions(sessions),
    PatchbayFriendlyCommand.sessionUse => _useSession(sessions, friendly),
    _ => throw StateError(
      'unexpected local session command ${friendly.spec.name}',
    ),
  };
}

/// Refuses the options that would suggest these commands talk to an App.
///
/// `--session-dir` is the one connection-shaped option that does apply: it
/// says *which* directory to read. The rest name a peer, and accepting them
/// silently would imply the listing came from that peer.
void _validateLocalSessionShape(ArgResults parsed) {
  for (final String name in const <String>[
    'ws-uri',
    'session',
    'direct-endpoint',
    'direct-token-stdin',
  ]) {
    if (!parsed.wasParsed(name)) continue;
    throw FormatException(
      '--$name does not apply to a session-directory command: it reads the '
      'local launcher records, not a running App',
    );
  }
}

_LocalOutcome _listSessions(PatchbaySessionResolver sessions) {
  final List<PatchbaySessionListing> listings = sessions.inventory();
  return _LocalOutcome(<String, Object?>{
    'sessions': <Map<String, Object?>>[
      for (final PatchbaySessionListing listing in listings) listing.toJson(),
    ],
    'selected': _selectedId(listings),
  }, _sessionLines(listings));
}

_LocalOutcome _pruneSessions(PatchbaySessionResolver sessions) {
  final PatchbaySessionPruneResult result = sessions.prune();
  final String removed = result.removed.isEmpty
      ? 'pruned nothing'
      : 'pruned ${result.removed.length}: ${result.removed.join(', ')}';
  return _LocalOutcome(
    <String, Object?>{
      'pruned': result.removed,
      'selectionCleared': result.selectionCleared,
      'sessions': <Map<String, Object?>>[
        for (final PatchbaySessionListing listing in result.remaining)
          listing.toJson(),
      ],
      'selected': _selectedId(result.remaining),
    },
    <String>[
      result.selectionCleared
          ? '$removed (the pinned session was among them and is now unpinned)'
          : removed,
      _sessionLines(result.remaining),
    ].join('\n'),
  );
}

_LocalOutcome _useSession(
  PatchbaySessionResolver sessions,
  PatchbayFriendlyInvocation friendly,
) {
  if (friendly.arguments['clear'] == true) {
    final String? previous = sessions.selection;
    sessions.clearSelection();
    return _LocalOutcome(
      <String, Object?>{'selected': null, 'previous': previous},
      previous == null
          ? 'no session was pinned'
          : 'unpinned $previous; commands without --session now require a '
                'single discoverable session',
    );
  }
  final PatchbaySessionListing pinned = sessions.select(
    friendly.arguments['sessionId']! as String,
  );
  return _LocalOutcome(<String, Object?>{
    'selected': pinned.record.sessionId,
    'session': pinned.toJson(),
  }, 'pinned ${pinned.label}');
}

_LocalOutcome _runLocalTraceCommand(ArgResults parsed) {
  _validateLocalTraceShape(parsed);
  final PatchbayFriendlyInvocation friendly =
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
  final PatchbayTraceStore traces = PatchbayTraceStore(
    parsed.option('trace-dir'),
  );
  final String? explicit = parsed.option('trace');
  switch (friendly.spec) {
    case PatchbayFriendlyCommand.traceStart:
      if (explicit != null) {
        throw const FormatException('trace start does not accept --trace');
      }
      final Object? name = friendly.arguments['name'];
      if (name is! String || name.trim().isEmpty) {
        throw const FormatException('trace start requires --name <name>');
      }
      final PatchbayTraceManifest manifest = traces.start(
        name: name,
        cliVersion: patchbayPackageVersion,
        activate: friendly.arguments['activate'] == true,
        pinned: friendly.arguments['pinned'] == true,
      );
      return _LocalOutcome(<String, Object?>{
        'trace': manifest.toJson(),
        'active': friendly.arguments['activate'] == true,
      }, 'traceId: ${manifest.traceId}');
    case PatchbayFriendlyCommand.traceMark:
      final PatchbayTraceManifest manifest = traces.mark(
        explicit,
        friendly.arguments['note']! as String,
      );
      return _LocalOutcome(<String, Object?>{
        'trace': manifest.toJson(),
        'marked': true,
      }, 'marked ${manifest.traceId}');
    case PatchbayFriendlyCommand.traceStop:
      final String? positional = friendly.arguments['traceId'] as String?;
      if (positional != null && explicit != null && positional != explicit) {
        throw const FormatException(
          'trace stop positional id and --trace must match',
        );
      }
      final PatchbayTraceManifest manifest = traces.stop(
        positional ?? explicit,
      );
      return _LocalOutcome(<String, Object?>{
        'trace': manifest.toJson(),
        'stopped': true,
      }, 'stopped ${manifest.traceId}');
    case PatchbayFriendlyCommand.traceShow:
      final PatchbayTraceReadResult result = traces.show(
        friendly.arguments['traceId']! as String,
      );
      return _LocalOutcome(result.toJson(), _traceTimeline(result));
    case PatchbayFriendlyCommand.traceExport:
      final Map<String, Object?> result = traces.exportDirectory(
        friendly.arguments['traceId']! as String,
        friendly.outputPath!,
        includeArtifacts: friendly.arguments['includeArtifacts'] == true,
      );
      return _LocalOutcome(
        result,
        'exported ${result['traceId']} to ${result['output']}',
      );
    case PatchbayFriendlyCommand.traceDiff:
      final Map<String, Object?> result = traces.diff(
        friendly.arguments['before']! as String,
        friendly.arguments['after']! as String,
      );
      final int changes =
          (result['added']! as List<Object?>).length +
          (result['removed']! as List<Object?>).length +
          (result['changed']! as List<Object?>).length;
      return _LocalOutcome(result, 'trace diff: $changes change(s)');
    case PatchbayFriendlyCommand.tracePrune:
      final PatchbayTracePruneResult result = traces.prune(
        dryRun: friendly.arguments['dryRun'] == true,
      );
      return _LocalOutcome(
        result.toJson(),
        result.dryRun
            ? 'would prune ${result.candidates.length} trace(s)'
            : 'pruned ${result.candidates.length} trace(s)',
      );
    default:
      throw StateError('unexpected local trace command ${friendly.spec.name}');
  }
}

void _validateLocalTraceShape(ArgResults parsed) {
  for (final String name in const <String>[
    'ws-uri',
    'session',
    'direct-endpoint',
    'direct-token-stdin',
  ]) {
    if (!parsed.wasParsed(name)) continue;
    throw FormatException(
      '--$name does not apply to a local trace-store command',
    );
  }
}

String _traceTimeline(PatchbayTraceReadResult result) {
  final List<String> lines = <String>[
    '${result.manifest.traceId} ${result.manifest.name} '
        '${result.manifest.ended ? 'finished' : 'active'} '
        'integrity=${result.integrity}',
    for (final PatchbayTraceEvent event in result.events)
      '${event.sequence.toString().padLeft(4)} '
          '+${event.elapsedMs}ms ${event.type}'
          '${event.requestId == null ? '' : ' request=${event.requestId}'}'
          '${event.jobId == null ? '' : ' job=${event.jobId}'}',
    if (result.truncatedTail) 'warning: truncatedTail',
    for (final String digest in result.missingArtifacts)
      'warning: missing artifact $digest',
  ];
  return lines.join('\n');
}

String? _selectedId(List<PatchbaySessionListing> listings) {
  for (final PatchbaySessionListing listing in listings) {
    if (listing.selected) return listing.record.sessionId;
  }
  return null;
}

/// The listing block both `sessions list` and `sessions prune` print.
String _sessionLines(List<PatchbaySessionListing> listings) {
  if (listings.isEmpty) return 'no session records';
  final List<String> lines = <String>[
    for (final PatchbaySessionListing listing in listings)
      '${listing.selected ? '*' : ' '} ${listing.label}',
  ];
  if (listings.length > 1 &&
      !listings.any((PatchbaySessionListing listing) => listing.selected)) {
    lines.add(patchbaySessionAmbiguousHint);
  }
  return lines.join('\n');
}

/// Dispatches one resolved declaration.
///
/// There is deliberately no second command table here: every path the CLI
/// accepts comes from [PatchbayFriendlyCommand], and the switch below has no
/// default arm, so a new declaration cannot be added without wiring dispatch
/// and help at the same time.
Future<_Execution> _execute(
  PatchbayClient connection,
  ArgResults parsed, {
  PatchbayUiManifest? manifest,
}) async {
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
    case PatchbayCommandTarget.localCatalogDescription:
      return _Execution(
        _describeCatalogCommand(
          await connection.catalog(),
          friendly.arguments['command']! as String,
        ),
      );
    case PatchbayCommandTarget.clientSnapshot:
      final PatchbaySnapshotRequest? selection = _selection(friendly);
      return _Execution(
        selection == null
            ? await connection.snapshot()
            : await _selectedSnapshot(connection, selection),
      );
    case PatchbayCommandTarget.clientWidgetTree:
      return _Execution(await connection.widgetTree());
    case PatchbayCommandTarget.clientRenderTree:
      return _Execution(await connection.renderTree());
    case PatchbayCommandTarget.clientFocusTree:
      return _Execution(await connection.focusTree());
    case PatchbayCommandTarget.clientPerformanceProfile:
      final PatchbayProfilingClient profiling = _profilingClient(
        connection,
        capability: 'performanceProfile',
      );
      final PatchbayPerformanceProfileRequest request =
          PatchbayPerformanceProfileRequest(
            duration: Duration(
              milliseconds: friendly.arguments['durationMs']! as int,
            ),
            eventLimit: friendly.arguments['sampleLimit']! as int,
          );
      request.validate();
      return _Execution(await profiling.performanceProfile(request));
    case PatchbayCommandTarget.clientNetworkProfile:
      return _Execution(
        await _profilingClient(
          connection,
          capability: 'networkProfile',
        ).networkProfile(),
      );
    case PatchbayCommandTarget.localManifestVerification:
      // A one-shot invocation parsed this before it dialled; a repl line
      // arrives with the connection already open and nothing parsed yet, so
      // this is the only remaining reader rather than a duplicated one.
      final PatchbayUiManifest verified =
          manifest ?? _readUiManifest(friendly.manifestPath!);
      final Map<String, Object?> catalog = await connection.catalog();
      if (parsed.flag('navigate')) {
        return _walkUiManifest(connection, catalog, verified, parsed);
      }
      String? destination;
      if (verified.usesDestinations) {
        final Map<String, Object?> current = await _invokeAgainstCatalog(
          connection,
          catalog,
          'navigation.current',
          const <String, Object?>{},
        );
        // Without the current destination the scoped half of the manifest
        // cannot be reconciled at all, so the refusal is reported as itself
        // rather than resolved into a verdict about a screen nobody named.
        if (current['admission'] == 'rejected') {
          return _Execution(
            _withSource(current, 'destinationSource'),
            catalog: catalog,
          );
        }
        destination = _navigationDestination(current);
      }
      PatchbayUiManifestSemanticsRuntime? semantics;
      if (verified.requiresSemanticsAt(destination)) {
        if (_CatalogCommand.find(catalog, 'ui.semantics.tree') == null) {
          throw const PatchbayProtocolException(
            'manifestSemanticsUnavailable',
            details: <String, Object?>{
              'reason':
                  'the App does not declare ui.semantics.tree, so the CLI '
                  'cannot verify semanticsIdentifier entries',
            },
          );
        }
        final Map<String, Object?> observed = await _invokeAgainstCatalog(
          connection,
          catalog,
          'ui.semantics.tree',
          const <String, Object?>{},
        );
        if (observed['admission'] == 'rejected') {
          return _Execution(
            _withSource(observed, 'semanticsSource'),
            catalog: catalog,
          );
        }
        semantics = _manifestSemanticsRuntime(observed);
      }
      final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
        manifest: verified,
        runtime: decodePatchbayCatalogUiTargets(catalog),
        currentDestination: destination,
        semantics: semantics,
      );
      return _Execution(
        report.toJson(),
        catalog: catalog,
        exitCode: report.hasDeviation
            ? PatchbayExitCode.verificationDeviation
            : PatchbayExitCode.accepted,
        summary: report.humanReport,
      );
    case PatchbayCommandTarget.localManifestEmission:
      final Map<String, Object?> catalog = await connection.catalog();
      final Map<String, Object?> current = await _invokeAgainstCatalog(
        connection,
        catalog,
        'navigation.current',
        const <String, Object?>{},
      );
      if (current['admission'] == 'rejected') {
        return _Execution(
          _withSource(current, 'destinationSource'),
          catalog: catalog,
        );
      }
      final String? destination = _navigationDestination(current);
      if (destination == null || destination.isEmpty) {
        throw const PatchbayProtocolException(
          'manifestDestinationUnavailable',
          details: <String, Object?>{
            'reason':
                'navigation.current did not report a settled destination; '
                'the CLI will not invent one for a manifest draft',
          },
        );
      }
      PatchbayUiManifestSemanticsRuntime? semantics;
      if (_CatalogCommand.find(catalog, 'ui.semantics.tree') != null) {
        final Map<String, Object?> observed = await _invokeAgainstCatalog(
          connection,
          catalog,
          'ui.semantics.tree',
          const <String, Object?>{},
        );
        if (observed['admission'] == 'rejected') {
          return _Execution(
            _withSource(observed, 'semanticsSource'),
            catalog: catalog,
          );
        }
        semantics = _manifestSemanticsRuntime(observed);
      }
      final Map<String, Object?> draft = emitPatchbayMountedUiManifest(
        runtime: decodePatchbayCatalogUiTargets(catalog),
        destination: destination,
        semantics: semantics,
      );
      return _Execution(
        draft,
        catalog: catalog,
        exitCode: PatchbayExitCode.accepted,
        // A manifest is an artifact intended to be redirected and edited, not
        // a response to collapse into a one-line human summary.
        summary: const JsonEncoder.withIndent('  ').convert(draft),
      );
    case PatchbayCommandTarget.clientReplSession:
      // `runPatchbayCli` routes a repl to its own loop before dispatch, and
      // the loop refuses a nested `repl` line, so reaching here is a wiring
      // bug rather than caller input.
      throw StateError('repl is a session, not a dispatchable command');
    case PatchbayCommandTarget.localSessionStore:
      // Answered before the dial, and refused inside a repl, so this arm is
      // unreachable for the same reason the one above is.
      throw StateError('session-directory commands run without a connection');
    case PatchbayCommandTarget.localTraceStore:
      throw StateError('trace-store commands run without a connection');
    case PatchbayCommandTarget.localLauncher:
      throw StateError('launcher runs without a connection');
    case PatchbayCommandTarget.localDiagnostics:
      // Answered before the dial as well: doctor dials for itself so that a
      // failed dial becomes a finding instead of ending the command.
      throw StateError('doctor owns its own connection');
    case PatchbayCommandTarget.localPermissionDriver:
      // Permission commands are handled before the App dial. A repl cannot
      // spawn an external process because its connection/session identity is
      // not the full launcher trust record required for writes.
      throw StateError('permission commands own their external driver');
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

const String _manifestWalkthroughSchema = 'uiManifestWalkthroughReport';
const Duration _defaultManifestScreenBudget = Duration(seconds: 5);
const Duration _maximumManifestScreenBudget = Duration(minutes: 2);
const Duration _defaultManifestTotalBudget = Duration(minutes: 2);
const Duration _maximumManifestTotalBudget = Duration(minutes: 10);

/// Runs the explicitly side-effecting, destination-ordered manifest audit.
///
/// Navigation admission remains consumer-owned: this code only asks for ids
/// that appeared in both the manifest and `navigation.catalog`. A successful
/// `navigation.go` is followed by the closed `navigationDestination` wait;
/// arbitrary readiness expressions never enter the request.
Future<_Execution> _walkUiManifest(
  PatchbayClient connection,
  Map<String, Object?> initialCatalog,
  PatchbayUiManifest manifest,
  ArgResults parsed,
) async {
  final Duration screenBudget = _manifestWalkthroughBudget(
    parsed,
    'screen-timeout-ms',
    fallback: _defaultManifestScreenBudget,
    maximum: _maximumManifestScreenBudget,
  );
  final Duration totalBudget = _manifestWalkthroughBudget(
    parsed,
    'total-timeout-ms',
    fallback: _defaultManifestTotalBudget,
    maximum: _maximumManifestTotalBudget,
  );
  final bool continueOnError = parsed.flag('continue-on-error');
  final bool restoreRequested = parsed.flag('restore');
  const Set<String> requiredCommands = <String>{
    'navigation.catalog',
    'navigation.current',
    'navigation.go',
    'ui.wait',
  };
  final Set<String> missingCommands = <String>{
    for (final String command in requiredCommands)
      if (_CatalogCommand.find(initialCatalog, command) == null) command,
  };

  // An older host is not probed for a request it never declared. If it can
  // still name the current destination, preserve the existing one-screen
  // verifier; otherwise only an unscoped v1 manifest can be truthfully
  // reconciled without inventing which destination is mounted.
  if (missingCommands.isNotEmpty || manifest.destinations.isEmpty) {
    if (_CatalogCommand.find(initialCatalog, 'navigation.current') != null ||
        !manifest.usesDestinations) {
      final _Execution current = await _verifyManifestCurrent(
        connection,
        initialCatalog,
        manifest,
      );
      return _Execution(
        <String, Object?>{
          ...current.response,
          'navigationMode': 'unavailable',
          'navigationUnavailableReason': manifest.destinations.isEmpty
              ? 'manifestDestinationsUnavailable'
              : 'navigationCapabilityUnavailable',
          if (missingCommands.isNotEmpty)
            'missingCommands': missingCommands.toList()..sort(),
        },
        catalog: initialCatalog,
        exitCode: current.exitCode,
        summary:
            'navigation unavailable; ${current.summary ?? 'current-screen verification only'}',
      );
    }
    return _Execution(
      <String, Object?>{
        'schema': _manifestWalkthroughSchema,
        'navigationMode': 'unavailable',
        'reasonCode': 'navigationCapabilityUnavailable',
        'missingCommands': missingCommands.toList()..sort(),
        'visited': const <String>[],
        'passed': const <String>[],
        'failed': const <String>[],
        'skipped': manifest.destinations,
        'destinations': <Map<String, Object?>>[
          for (final String destination in manifest.destinations)
            <String, Object?>{
              'destinationId': destination,
              'status': 'skipped',
              'reasonCode': 'navigationCapabilityUnavailable',
            },
        ],
        'restore': <String, Object?>{
          'requested': restoreRequested,
          'attempted': false,
        },
        'finalDestination': null,
      },
      catalog: initialCatalog,
      exitCode: PatchbayExitCode.typedFailure,
      summary: 'navigation unavailable; no destination-scoped verdict emitted',
    );
  }

  final Stopwatch total = Stopwatch()..start();
  final List<String> visited = <String>[];
  final List<String> passed = <String>[];
  final List<String> failed = <String>[];
  final List<String> skipped = <String>[];
  final List<Map<String, Object?>> destinations = <Map<String, Object?>>[];
  final List<Map<String, Object?>> notices = <Map<String, Object?>>[];
  int primaryExitCode = PatchbayExitCode.accepted;

  final Map<String, Object?> navigationCatalogResponse =
      await _invokeWalkthroughWait(
        connection,
        initialCatalog,
        'navigation.catalog',
        const <String, Object?>{},
        deadline: totalBudget - total.elapsed,
        total: total,
        totalBudget: totalBudget,
        timeoutCode: 'manifestWalkthroughTotalTimeout',
      );
  if (patchbayExitCodeFor(navigationCatalogResponse) !=
      PatchbayExitCode.accepted) {
    return _walkthroughPreludeRejected(
      manifest,
      initialCatalog,
      restoreRequested,
      navigationCatalogResponse,
      'navigationCatalogRejected',
    );
  }
  final PatchbayNavigationCatalogWire navigationCatalog =
      _decodeNavigationCatalog(navigationCatalogResponse);
  final Map<String, PatchbayDestinationDescriptorWire> descriptors =
      <String, PatchbayDestinationDescriptorWire>{
        for (final PatchbayDestinationDescriptorWire descriptor
            in navigationCatalog.destinations)
          descriptor.id: descriptor,
      };

  final Map<String, Object?> initialCurrent = await _invokeWalkthroughWait(
    connection,
    initialCatalog,
    'navigation.current',
    const <String, Object?>{},
    deadline: totalBudget - total.elapsed,
    total: total,
    totalBudget: totalBudget,
    timeoutCode: 'manifestWalkthroughTotalTimeout',
  );
  if (patchbayExitCodeFor(initialCurrent) != PatchbayExitCode.accepted) {
    return _walkthroughPreludeRejected(
      manifest,
      initialCatalog,
      restoreRequested,
      initialCurrent,
      'navigationCurrentRejected',
    );
  }
  final String? initialDestination = _navigationDestination(initialCurrent);

  var stopped = false;
  for (var index = 0; index < manifest.destinations.length; index += 1) {
    final String destination = manifest.destinations[index];
    if (stopped) {
      skipped.add(destination);
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': 'skipped',
        'reasonCode': 'stoppedAfterFailure',
      });
      continue;
    }
    if (total.elapsed >= totalBudget) {
      failed.add(destination);
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': 'failed',
        'reasonCode': 'manifestWalkthroughTotalTimeout',
      });
      primaryExitCode = _firstFailure(
        primaryExitCode,
        PatchbayExitCode.typedFailure,
      );
      stopped = true;
      continue;
    }

    final PatchbayDestinationDescriptorWire? descriptor =
        descriptors[destination];
    final String? descriptorFailure = descriptor == null
        ? 'manifestDestinationNotDeclared'
        : descriptor.ambiguous
        ? 'navigationDestinationAmbiguous'
        : !descriptor.operations.contains(PatchbayNavigationOperationWire.go)
        ? 'navigationGoUnsupported'
        : null;
    if (descriptorFailure != null) {
      failed.add(destination);
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': 'failed',
        'reasonCode': descriptorFailure,
        if (descriptor != null) 'descriptorGates': descriptor.gates,
      });
      primaryExitCode = _firstFailure(
        primaryExitCode,
        PatchbayExitCode.rejected,
      );
      stopped = !continueOnError;
      continue;
    }

    final Stopwatch screen = Stopwatch()..start();
    final Duration currentTimeout = _remainingWalkthroughBudget(
      screenBudget,
      screen.elapsed,
      totalBudget,
      total.elapsed,
    );
    final Map<String, Object?> current = await _invokeWalkthroughWait(
      connection,
      initialCatalog,
      'navigation.current',
      const <String, Object?>{},
      deadline: currentTimeout,
      total: total,
      totalBudget: totalBudget,
    );
    Map<String, Object?>? failure;
    if (patchbayExitCodeFor(current) != PatchbayExitCode.accepted) {
      failure = current;
    } else {
      final Duration navigationTimeout = _remainingWalkthroughBudget(
        screenBudget,
        screen.elapsed,
        totalBudget,
        total.elapsed,
      );
      if (navigationTimeout <= Duration.zero) {
        failure = _localWalkthroughFailure('manifestWalkthroughScreenTimeout');
      } else {
        final Map<String, Object?> navigation = await _invokeWalkthroughWait(
          connection,
          initialCatalog,
          'navigation.go',
          <String, Object?>{
            'destinationId': destination,
            'revision': _navigationRevision(current),
            'timeoutMs': navigationTimeout.inMilliseconds,
          },
          deadline: navigationTimeout,
          total: total,
          totalBudget: totalBudget,
        );
        if (patchbayExitCodeFor(navigation) != PatchbayExitCode.accepted) {
          failure = navigation;
        } else {
          final Duration stableTimeout = _remainingWalkthroughBudget(
            screenBudget,
            screen.elapsed,
            totalBudget,
            total.elapsed,
          );
          if (stableTimeout <= Duration.zero) {
            failure = _localWalkthroughFailure(
              'manifestWalkthroughScreenTimeout',
            );
          } else {
            final Map<String, Object?> stable = await _invokeWalkthroughWait(
              connection,
              initialCatalog,
              'ui.wait',
              <String, Object?>{
                'condition': 'navigationDestination',
                'timeoutMs': stableTimeout.inMilliseconds,
                'destinationId': destination,
              },
              deadline: stableTimeout,
              total: total,
              totalBudget: totalBudget,
            );
            if (patchbayExitCodeFor(stable) != PatchbayExitCode.accepted) {
              failure = stable;
            }
          }
        }
      }
    }

    if (failure == null && total.elapsed >= totalBudget) {
      failure = _localWalkthroughFailure('manifestWalkthroughTotalTimeout');
    } else if (failure == null && screen.elapsed >= screenBudget) {
      failure = _localWalkthroughFailure('manifestWalkthroughScreenTimeout');
    }

    if (failure != null) {
      final String reason = _walkthroughFailureCode(failure);
      failed.add(destination);
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': 'failed',
        'reasonCode': reason,
        'descriptorGates': descriptor!.gates,
      });
      primaryExitCode = _firstFailure(
        primaryExitCode,
        patchbayExitCodeFor(failure),
      );
      stopped = reason == 'manifestWalkthroughTotalTimeout' || !continueOnError;
      continue;
    }

    visited.add(destination);
    PatchbayUiManifestSemanticsRuntime? semantics;
    Map<String, Object?>? verificationFailure;
    Map<String, Object?>? screenCatalog;
    final Duration catalogTimeout = _remainingWalkthroughBudget(
      screenBudget,
      screen.elapsed,
      totalBudget,
      total.elapsed,
    );
    if (catalogTimeout.inMilliseconds < 1) {
      verificationFailure = _localWalkthroughFailure(
        total.elapsed >= totalBudget
            ? 'manifestWalkthroughTotalTimeout'
            : 'manifestWalkthroughScreenTimeout',
      );
    } else {
      try {
        screenCatalog = await connection.catalog().timeout(catalogTimeout);
      } on TimeoutException {
        verificationFailure = _localWalkthroughFailure(
          total.elapsed >= totalBudget
              ? 'manifestWalkthroughTotalTimeout'
              : 'manifestWalkthroughScreenTimeout',
        );
      }
    }
    if (verificationFailure == null &&
        manifest.requiresSemanticsAt(destination)) {
      if (_CatalogCommand.find(screenCatalog!, 'ui.semantics.tree') == null) {
        verificationFailure = _localWalkthroughFailure(
          'manifestSemanticsUnavailable',
        );
      } else {
        final Duration semanticsTimeout = _remainingWalkthroughBudget(
          screenBudget,
          screen.elapsed,
          totalBudget,
          total.elapsed,
        );
        final Map<String, Object?> observed = await _invokeWalkthroughWait(
          connection,
          screenCatalog,
          'ui.semantics.tree',
          const <String, Object?>{},
          deadline: semanticsTimeout,
          total: total,
          totalBudget: totalBudget,
        );
        if (patchbayExitCodeFor(observed) != PatchbayExitCode.accepted) {
          verificationFailure = observed;
        } else {
          semantics = _manifestSemanticsRuntime(observed);
        }
      }
    }
    if (verificationFailure != null) {
      final String reason = _walkthroughFailureCode(verificationFailure);
      failed.add(destination);
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': 'failed',
        'reasonCode': reason,
        'descriptorGates': descriptor!.gates,
      });
      primaryExitCode = _firstFailure(
        primaryExitCode,
        patchbayExitCodeFor(verificationFailure),
      );
      stopped = reason == 'manifestWalkthroughTotalTimeout' || !continueOnError;
      continue;
    }
    final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
      manifest: manifest,
      runtime: decodePatchbayCatalogUiTargets(screenCatalog!),
      currentDestination: destination,
      semantics: semantics,
    );
    if (report.hasDeviation) {
      failed.add(destination);
      primaryExitCode = _firstFailure(
        primaryExitCode,
        PatchbayExitCode.verificationDeviation,
      );
      stopped = !continueOnError;
    } else {
      passed.add(destination);
    }
    destinations.add(<String, Object?>{
      'destinationId': destination,
      'status': report.hasDeviation ? 'failed' : 'passed',
      'reasonCode': report.hasDeviation ? 'manifestDeviation' : 'verified',
      'descriptorGates': descriptor!.gates,
      'report': report.toJson(),
    });
  }

  final Map<String, Object?> restore = <String, Object?>{
    'requested': restoreRequested,
    'attempted': false,
  };
  String? finalDestination;
  Map<String, Object?>? finalCurrent;
  try {
    finalCurrent = await _invokeWalkthroughWait(
      connection,
      initialCatalog,
      'navigation.current',
      const <String, Object?>{},
      deadline: totalBudget - total.elapsed,
      total: total,
      totalBudget: totalBudget,
    );
    if (patchbayExitCodeFor(finalCurrent) == PatchbayExitCode.accepted) {
      finalDestination = _navigationDestination(finalCurrent);
    }
  } on Object {
    // The primary walkthrough result remains authoritative; the notice below
    // names that final position could not be observed without exposing a URI.
  }
  if (restoreRequested &&
      initialDestination != null &&
      finalDestination != initialDestination) {
    final Duration remaining = _remainingWalkthroughBudget(
      screenBudget,
      Duration.zero,
      totalBudget,
      total.elapsed,
    );
    if (remaining.inMilliseconds < 1 ||
        finalCurrent == null ||
        patchbayExitCodeFor(finalCurrent) != PatchbayExitCode.accepted) {
      restore['reasonCode'] = 'manifestRestoreBudgetUnavailable';
      notices.add(const <String, Object?>{
        'code': 'manifestRestoreFailed',
        'reasonCode': 'manifestRestoreBudgetUnavailable',
      });
    } else {
      restore['attempted'] = true;
      final Map<String, Object?> response = await _invokeWalkthroughWait(
        connection,
        initialCatalog,
        'navigation.go',
        <String, Object?>{
          'destinationId': initialDestination,
          'revision': _navigationRevision(finalCurrent),
          'timeoutMs': remaining.inMilliseconds,
        },
        deadline: remaining,
        total: total,
        totalBudget: totalBudget,
      );
      if (patchbayExitCodeFor(response) != PatchbayExitCode.accepted) {
        final String reason = _walkthroughFailureCode(response);
        restore['reasonCode'] = reason;
        notices.add(<String, Object?>{
          'code': 'manifestRestoreFailed',
          'reasonCode': reason,
        });
      } else {
        restore['outcome'] = 'restored';
        finalDestination = initialDestination;
      }
      final Map<String, Object?> observed = await _invokeWalkthroughWait(
        connection,
        initialCatalog,
        'navigation.current',
        const <String, Object?>{},
        deadline: totalBudget - total.elapsed,
        total: total,
        totalBudget: totalBudget,
      );
      if (patchbayExitCodeFor(observed) == PatchbayExitCode.accepted) {
        finalDestination = _navigationDestination(observed);
      }
    }
  }

  final Map<String, Object?> response = <String, Object?>{
    'schema': _manifestWalkthroughSchema,
    'navigationMode': 'walkthrough',
    'visited': visited,
    'passed': passed,
    'failed': failed,
    'skipped': skipped,
    'destinations': destinations,
    'initialDestination': initialDestination,
    'finalDestination': finalDestination,
    'restore': restore,
    if (notices.isNotEmpty) 'notices': notices,
  };
  return _Execution(
    response,
    catalog: initialCatalog,
    exitCode: primaryExitCode,
    summary:
        'visited=${visited.length} passed=${passed.length} '
        'failed=${failed.length} skipped=${skipped.length} '
        'finalDestination=${finalDestination ?? 'none'}',
  );
}

Future<_Execution> _verifyManifestCurrent(
  PatchbayClient connection,
  Map<String, Object?> catalog,
  PatchbayUiManifest manifest,
) async {
  String? destination;
  if (manifest.usesDestinations) {
    final Map<String, Object?> current = await _invokeAgainstCatalog(
      connection,
      catalog,
      'navigation.current',
      const <String, Object?>{},
    );
    if (current['admission'] == 'rejected') {
      return _Execution(
        _withSource(current, 'destinationSource'),
        catalog: catalog,
      );
    }
    destination = _navigationDestination(current);
  }
  PatchbayUiManifestSemanticsRuntime? semantics;
  if (manifest.requiresSemanticsAt(destination)) {
    if (_CatalogCommand.find(catalog, 'ui.semantics.tree') == null) {
      throw const PatchbayProtocolException('manifestSemanticsUnavailable');
    }
    final Map<String, Object?> observed = await _invokeAgainstCatalog(
      connection,
      catalog,
      'ui.semantics.tree',
      const <String, Object?>{},
    );
    if (observed['admission'] == 'rejected') {
      return _Execution(
        _withSource(observed, 'semanticsSource'),
        catalog: catalog,
      );
    }
    semantics = _manifestSemanticsRuntime(observed);
  }
  final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
    manifest: manifest,
    runtime: decodePatchbayCatalogUiTargets(catalog),
    currentDestination: destination,
    semantics: semantics,
  );
  return _Execution(
    report.toJson(),
    catalog: catalog,
    exitCode: report.hasDeviation
        ? PatchbayExitCode.verificationDeviation
        : PatchbayExitCode.accepted,
    summary: report.humanReport,
  );
}

Duration _manifestWalkthroughBudget(
  ArgResults parsed,
  String name, {
  required Duration fallback,
  required Duration maximum,
}) {
  final String? raw = parsed.option(name);
  if (raw == null) return fallback;
  final int? milliseconds = int.tryParse(raw);
  if (milliseconds == null ||
      milliseconds <= 0 ||
      milliseconds > maximum.inMilliseconds) {
    throw FormatException(
      '--$name must be an integer from 1 to ${maximum.inMilliseconds}',
    );
  }
  return Duration(milliseconds: milliseconds);
}

Duration _remainingWalkthroughBudget(
  Duration screenBudget,
  Duration screenElapsed,
  Duration totalBudget,
  Duration totalElapsed,
) {
  final Duration screenRemaining = screenBudget - screenElapsed;
  final Duration totalRemaining = totalBudget - totalElapsed;
  return screenRemaining < totalRemaining ? screenRemaining : totalRemaining;
}

int _firstFailure(int current, int next) =>
    current == PatchbayExitCode.accepted ? next : current;

Map<String, Object?> _localWalkthroughFailure(String code) => <String, Object?>{
  'outcome': 'failed',
  'failure': <String, Object?>{'code': code},
};

Future<Map<String, Object?>> _invokeWalkthroughWait(
  PatchbayClient connection,
  Map<String, Object?> catalog,
  String command,
  Map<String, Object?> arguments, {
  required Duration deadline,
  required Stopwatch total,
  required Duration totalBudget,
  String? timeoutCode,
}) async {
  if (deadline.inMilliseconds < 1) {
    return _localWalkthroughFailure(
      timeoutCode ??
          (total.elapsed >= totalBudget
              ? 'manifestWalkthroughTotalTimeout'
              : 'manifestWalkthroughScreenTimeout'),
    );
  }
  try {
    return await _invokeAgainstCatalog(
      connection,
      catalog,
      command,
      arguments,
      deadline: deadline,
    ).timeout(deadline);
  } on TimeoutException {
    return _localWalkthroughFailure(
      timeoutCode ??
          (total.elapsed >= totalBudget
              ? 'manifestWalkthroughTotalTimeout'
              : 'manifestWalkthroughScreenTimeout'),
    );
  }
}

String _walkthroughFailureCode(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  if (rejection is Map<Object?, Object?> && rejection['code'] is String) {
    return rejection['code']! as String;
  }
  final Object? failure = response['failure'];
  if (failure is Map<Object?, Object?> && failure['code'] is String) {
    return failure['code']! as String;
  }
  return 'manifestWalkthroughFailed';
}

PatchbayNavigationCatalogWire _decodeNavigationCatalog(
  Map<String, Object?> response,
) {
  final Object? payload = response['payload'];
  if (payload is! Map<String, Object?>) {
    throw const PatchbayProtocolException('navigationCatalogContractViolated');
  }
  try {
    return PatchbayNavigationCatalogWire.fromJson(payload);
  } on FormatException catch (failure) {
    throw PatchbayProtocolException(
      'navigationCatalogContractViolated',
      details: <String, Object?>{'reason': failure.message},
    );
  }
}

_Execution _walkthroughPreludeRejected(
  PatchbayUiManifest manifest,
  Map<String, Object?> catalog,
  bool restoreRequested,
  Map<String, Object?> rejection,
  String fallbackCode,
) {
  final String code =
      _walkthroughFailureCode(rejection) == 'manifestWalkthroughFailed'
      ? fallbackCode
      : _walkthroughFailureCode(rejection);
  return _Execution(
    <String, Object?>{
      'schema': _manifestWalkthroughSchema,
      'navigationMode': 'walkthrough',
      'reasonCode': code,
      'visited': const <String>[],
      'passed': const <String>[],
      'failed': const <String>[],
      'skipped': manifest.destinations,
      'destinations': <Map<String, Object?>>[
        for (final String destination in manifest.destinations)
          <String, Object?>{
            'destinationId': destination,
            'status': 'skipped',
            'reasonCode': code,
          },
      ],
      'restore': <String, Object?>{
        'requested': restoreRequested,
        'attempted': false,
      },
      'finalDestination': null,
    },
    catalog: catalog,
    exitCode: patchbayExitCodeFor(rejection),
    summary: 'walkthrough refused: $code',
  );
}

PatchbayProfilingClient _profilingClient(
  PatchbayClient client, {
  required String capability,
}) {
  if (client is PatchbayProfilingClient) {
    return client as PatchbayProfilingClient;
  }
  throw PatchbayProtocolException(
    capability == 'networkProfile'
        ? 'networkProfilingUnavailable'
        : 'profilingVmServiceRequired',
    details: <String, Object?>{'capability': capability},
  );
}

/// Stable code for "this App is too old to understand a snapshot selector".
const String patchbaySnapshotSelectorUnsupportedCode =
    'snapshotSelectionUnsupportedByHost';

/// Sends one selector-bearing snapshot only when the host declared support.
///
/// Identity capabilities are an open string set on the client: unknown names
/// remain valid, while the one name this command understands is required. A
/// missing declaration therefore degrades before the selector reaches the
/// wire. Once declared, every failure from the snapshot RPC stays exactly what
/// it was; a real transport or protocol failure must never be rewritten as a
/// version skew.
Future<Map<String, Object?>> _selectedSnapshot(
  PatchbayClient connection,
  PatchbaySnapshotRequest request,
) async {
  final Set<String>? features = patchbayDeclaredFeatures(
    await connection.identity(),
  );
  if (!(features?.contains(PatchbayFeature.snapshotSelectors.name) ?? false)) {
    return _snapshotSelectorUnsupported();
  }
  return connection.snapshot(request: request);
}

/// The refusal above, in the same typed shape the App's own rejections use.
///
/// A rejection rather than an error envelope because that is what happened —
/// the request was refused, by a peer that cannot serve it — and it lets a
/// script that already branches on `admission` classify a version skew without
/// learning a second shape. The notice carries the fallback that does work, so
/// the answer itself says what to run next.
Map<String, Object?> _snapshotSelectorUnsupported() {
  const String notice =
      'This App does not support snapshot field selection or waits. Run '
      '`patchbay snapshot` for the whole snapshot, or update the App to a '
      'Patchbay version that serves selectors.';
  return <String, Object?>{
    'schemaVersion': PatchbayServiceHost.schemaVersion,
    'admission': 'rejected',
    'notice': notice,
    'rejection': PatchbayRejection(
      code: patchbaySnapshotSelectorUnsupportedCode,
      notice: notice,
    ).toJson(),
  };
}

/// The snapshot selection this invocation asks for, or null for the whole
/// snapshot.
///
/// The declaration already produced the wire object; decoding it through the
/// same request type the App validates is what keeps the CLI from having a
/// second, looser opinion about what a selector may say. A malformed one is a
/// usage error here rather than a round trip that comes back rejected.
PatchbaySnapshotRequest? _selection(PatchbayFriendlyInvocation friendly) {
  if (friendly.arguments.isEmpty) return null;
  return PatchbaySnapshotRequest.fromWire(
    PatchbaySnapshotRequestWire.fromJson(friendly.arguments),
  );
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
    _withSource(response, 'revisionSource');

Map<String, Object?> _withSource(Map<String, Object?> response, String field) =>
    <String, Object?>{...response, field: 'navigation.current'};

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

/// The destination an App reports as current, which may legitimately be none.
///
/// `destinationId` is declared nullable on the wire — an App between screens
/// has no settled destination — so `null` is an answer, not a violation. Only a
/// value of the wrong type is one.
String? _navigationDestination(Map<String, Object?> response) {
  final Object? payload = response['payload'];
  if (payload is! Map<Object?, Object?>) {
    throw const PatchbayProtocolException(
      'navigationDestinationContractViolated',
    );
  }
  final Object? destination = payload['destinationId'];
  if (destination != null && destination is! String) {
    throw const PatchbayProtocolException(
      'navigationDestinationContractViolated',
    );
  }
  return destination as String?;
}

PatchbayUiManifestSemanticsRuntime _manifestSemanticsRuntime(
  Map<String, Object?> response,
) {
  final Object? payload = response['payload'];
  if (payload is! Map<String, Object?>) {
    throw const PatchbayProtocolException(
      'manifestSemanticsContractViolated',
      details: <String, Object?>{
        'reason': 'ui.semantics.tree did not return an object payload',
      },
    );
  }
  return decodePatchbayManifestSemantics(payload);
}

/// Parses the manifest of a one-shot `ui verify-manifest`, or returns `null`.
///
/// Ordering, not convenience: this runs before the dial so that a manifest the
/// CLI refuses to read is reported as itself. Reading it after the dial made an
/// offline machine answer every bad manifest with a session error, which is a
/// true statement about the wrong thing — the file is wrong no matter which
/// device is plugged in, and only one of those two failures the author can fix
/// from where they are sitting.
///
/// Every other command returns `null` here and is unaffected, including a repl:
/// its lines are dispatched against a connection that already exists, so there
/// is no dial left for a parse to precede.
PatchbayUiManifest? _preReadUiManifest(ArgResults parsed) {
  if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target !=
      PatchbayCommandTarget.localManifestVerification) {
    return null;
  }
  // Resolution is what turns argv into the path; it also polices the command's
  // shape, and doing that before the dial is the same improvement for the same
  // reason.
  final PatchbayFriendlyInvocation? friendly =
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
  if (friendly?.manifestPath case final String path) {
    return _readUiManifest(path);
  }
  return null;
}

/// Reads the manifest file the caller named.
///
/// The path is argv, so it may be echoed back; the operating system's reason
/// travels with it because "which file, and why not" is the whole content of
/// this failure. No part of the file itself does.
PatchbayUiManifest _readUiManifest(String path) {
  final PatchbayUiManifestFormat format = switch (path) {
    final String value when value.endsWith('.json') =>
      PatchbayUiManifestFormat.json,
    final String value when value.endsWith('.yaml') || value.endsWith('.yml') =>
      PatchbayUiManifestFormat.yaml,
    _ => throw PatchbayUiManifestException(
      'manifestFormatUnsupported',
      details: const <String, Object?>{
        'reason': 'manifest extension must be .json, .yaml, or .yml',
      },
    ),
  };
  final List<int> bytes;
  try {
    final RandomAccessFile file = File(path).openSync();
    try {
      // Never allocate from the file's claimed length and never read more than
      // one byte beyond the accepted budget, including if the file changes
      // between open and read.
      bytes = file.readSync(patchbayUiManifestMaximumBytes + 1);
    } finally {
      file.closeSync();
    }
  } on FileSystemException catch (failure) {
    throw PatchbayUiManifestException(
      'manifestUnreadable',
      details: <String, Object?>{
        'path': path,
        'reason': ?failure.osError?.message,
      },
    );
  } on Object catch (failure) {
    throw PatchbayUiManifestException(
      'manifestUnreadable',
      details: <String, Object?>{
        'path': path,
        'reason': '${failure.runtimeType}',
      },
    );
  }
  if (bytes.length > patchbayUiManifestMaximumBytes) {
    throw const PatchbayUiManifestException(
      'manifestResourceLimit',
      details: <String, Object?>{
        'reason': 'manifest byte limit exceeded',
        'limit': patchbayUiManifestMaximumBytes,
      },
    );
  }
  final String source;
  try {
    source = utf8.decode(bytes);
  } on FormatException {
    throw const PatchbayUiManifestException(
      'manifestInvalid',
      details: <String, Object?>{
        'reason': 'manifest must be valid UTF-8',
        'line': 1,
        'column': 1,
      },
    );
  }
  return PatchbayUiManifest.parseSource(source, format: format);
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
  if (!wait) return admission;
  final Map<String, Object?> terminal = await _waitForJob(
    connection,
    catalog,
    admission,
    descriptor?.suggestedWaitTimeout,
    serverWaitAvailable: serverWaitAvailable,
  );
  return _validateTerminalPayload(terminal, descriptor);
}

Map<String, Object?> _validateTerminalPayload(
  Map<String, Object?> response,
  _CatalogCommand? descriptor,
) {
  if (descriptor == null || response['admission'] != 'accepted') {
    return response;
  }
  final List<PatchbayResponseValidationIssue> issues =
      <PatchbayResponseValidationIssue>[];
  if (descriptor.responseSchema case final PatchbayResponseSchema schema) {
    issues.addAll(validatePatchbayTerminalPayload(schema, response['payload']));
  }
  final PatchbayExecutionValidationResult execution =
      _validateTerminalExecution(response, descriptor.executionContract);
  issues.addAll(execution.issues);
  if (issues.isNotEmpty) return _cliResponseSchemaViolation(response, issues);
  return _withCliExecutionDetails(<String, Object?>{
    ...response,
    'schemaMode': descriptor.responseSchema == null
        ? 'legacyUnvalidated'
        : 'validated',
  }, execution);
}

PatchbayExecutionValidationResult _validateTerminalExecution(
  Map<String, Object?> response,
  PatchbayExecutionContract contract,
) {
  final Object? payload = response['payload'];
  final Object? events = payload is Map<Object?, Object?>
      ? payload['events']
      : null;
  if (events is! List<Object?> || events.isEmpty) {
    return const PatchbayExecutionValidationResult();
  }
  final Object? event = events.last;
  if (event is! Map<Object?, Object?> || event['phase'] is! String) {
    return const PatchbayExecutionValidationResult();
  }
  final Object? rawAt = event['at'];
  final DateTime? at = rawAt is String ? DateTime.tryParse(rawAt) : null;
  final int eventIndex = events.length - 1;
  return validatePatchbayExecutionEvidence(
    contract,
    event['payload'],
    path:
        r'$.payload.events'
        '[$eventIndex].payload',
    terminalPhase: event['phase']! as String,
    nowMs: at?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
  );
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
  final PatchbayRetryPolicy? retryPolicy = _retryPolicyFor(catalog, command);
  final PatchbayTraceRecorder? trace = _traceRecorder;
  String? issuedRequestId;
  final Map<String, Object?> response;
  if (retryPolicy == null) {
    issuedRequestId = trace == null ? null : patchbayCliRequestId('trace');
    response = await connection.invoke(
      command: command,
      arguments: arguments,
      requestId: issuedRequestId,
      deadline: deadline,
    );
  } else {
    final String requestId = patchbayCliRequestId('retry');
    issuedRequestId = requestId;
    Map<String, Object?>? answer;
    for (var attempt = 1; attempt <= retryPolicy.maxAttempts; attempt += 1) {
      try {
        answer = await connection.invoke(
          command: command,
          arguments: arguments,
          requestId: requestId,
          deadline: deadline,
        );
        break;
      } on PatchbayTransportException catch (failure) {
        if (!_isRetryableTransportFailure(failure)) rethrow;
        if (attempt == retryPolicy.maxAttempts) rethrow;
        if (retryPolicy.backoffMs > 0) {
          await Future<void>.delayed(
            Duration(milliseconds: retryPolicy.backoffMs),
          );
        }
      }
    }
    response = answer!;
  }
  if (!cataloged && !_isCommandNotRegistered(response)) {
    throw PatchbayProtocolException(
      'catalogInvocationDrift',
      details: _driftDetails(command, catalog, response),
    );
  }
  final _CatalogCommand? descriptor = _CatalogCommand.find(catalog, command);
  final PatchbayResponseSchema? responseSchema = descriptor?.responseSchema;
  PatchbayExecutionValidationResult execution =
      const PatchbayExecutionValidationResult();
  final List<PatchbayResponseValidationIssue> issues =
      <PatchbayResponseValidationIssue>[];
  if (response['admission'] == 'accepted') {
    if (responseSchema != null) {
      issues.addAll(
        validatePatchbayResponsePayload(
          responseSchema.accepted,
          response['payload'],
        ),
      );
    }
    if (issues.isEmpty && descriptor != null) {
      execution = validatePatchbayExecutionEvidence(
        descriptor.executionContract,
        response['payload'],
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      issues.addAll(execution.issues);
    }
  }
  final Map<String, Object?> result = issues.isNotEmpty
      ? _cliResponseSchemaViolation(response, issues)
      : _withCliExecutionDetails(<String, Object?>{
          ...response,
          'schemaMode': responseSchema == null
              ? 'legacyUnvalidated'
              : 'validated',
        }, execution);
  if (trace != null) {
    final Object? rawRow = _catalogRow(catalog, command);
    final String descriptorDigest = rawRow == null
        ? 'uncataloged'
        : PatchbayCatalogDigest.ofCommands(<Object?>[rawRow]).value;
    final Object? responseRequestId = result['requestId'];
    final String requestId = responseRequestId is String
        ? responseRequestId
        : issuedRequestId ?? '';
    trace.admission(
      command: command,
      requestId: requestId,
      arguments: arguments,
      sensitiveParameters: descriptor?.sensitiveParameters ?? const <String>{},
      descriptorDigest: descriptorDigest,
      response: result,
      includeLegacyPayload: _traceIncludesLegacyPayload,
    );
  }
  return result;
}

Map<String, Object?> _withCliExecutionDetails(
  Map<String, Object?> response,
  PatchbayExecutionValidationResult validation,
) {
  if (!validation.legacyDispatchedConflict) return response;
  final Object? existing = response['details'];
  return <String, Object?>{
    ...response,
    'details': <String, Object?>{
      if (existing is Map<Object?, Object?>)
        for (final MapEntry<Object?, Object?> entry in existing.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      'legacyDispatchedConflict': true,
    },
  };
}

bool _isRetryableTransportFailure(PatchbayTransportException failure) =>
    const <String>{
      patchbayAppUnresponsiveCode,
      'transportError',
      'transportUnavailable',
      'socketClosed',
    }.contains(failure.code);

PatchbayRetryPolicy? _retryPolicyFor(
  Map<String, Object?> catalog,
  String command,
) {
  final Map<Object?, Object?>? row = _catalogRow(catalog, command);
  if (row == null || !row.containsKey('retryPolicy')) return null;
  if (row['sideEffect'] != 'external') {
    throw const PatchbayProtocolException('catalogRetryPolicyInvalid');
  }
  try {
    return PatchbayRetryPolicy.fromJson(row['retryPolicy']);
  } on FormatException {
    throw const PatchbayProtocolException('catalogRetryPolicyInvalid');
  }
}

Map<String, Object?> _describeCatalogCommand(
  Map<String, Object?> catalog,
  String command,
) {
  final Map<Object?, Object?>? row = _catalogRow(catalog, command);
  if (row == null) {
    throw PatchbayProtocolException(
      'commandNotRegistered',
      details: <String, Object?>{'command': command},
    );
  }
  final String retryEligibility;
  if (row['sideEffect'] != 'external') {
    retryEligibility = 'notExternal';
  } else if (!row.containsKey('retryPolicy')) {
    retryEligibility = 'notDeclared';
  } else {
    _retryPolicyFor(catalog, command);
    retryEligibility = 'eligible';
  }
  return <String, Object?>{
    'command': <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in row.entries)
        '${entry.key}': entry.value,
    },
    'schemaMode': row.containsKey('responseSchema')
        ? 'validated'
        : 'legacyUnvalidated',
    'retryEligibility': retryEligibility,
  };
}

Map<Object?, Object?>? _catalogRow(
  Map<String, Object?> catalog,
  String command,
) {
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return null;
  for (final Object? row in rows) {
    if (row is Map<Object?, Object?> && row['name'] == command) return row;
  }
  return null;
}

Map<String, Object?> _cliResponseSchemaViolation(
  Map<String, Object?> response,
  List<PatchbayResponseValidationIssue> issues,
) {
  final List<PatchbayResponseValidationIssue> capped = issues
      .take(patchbayResponseValidationMaxIssues)
      .toList(growable: false);
  final PatchbayResponseValidationIssue first = capped.first;
  return <String, Object?>{
    'schemaVersion': response['schemaVersion'] ?? 1,
    'requestId': response['requestId'] ?? '',
    'admission': 'rejected',
    'payload': const <String, Object?>{},
    'notice': null,
    'jobId': response['jobId'],
    'rejection': <String, Object?>{
      'code': 'providerProtocolViolation',
      'details': <String, Object?>{
        'reason': first.reason,
        'field': first.field,
        if (first.expected != null) 'expected': first.expected!,
        'violations': capped
            .map((PatchbayResponseValidationIssue issue) => issue.toJson())
            .toList(growable: false),
      },
    },
    'schemaMode': 'validated',
  };
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
  String? summary,
}) {
  out.writeln(
    json
        ? const JsonEncoder.withIndent('  ').convert(output)
        : summary ?? patchbayResponseSummary(output),
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
  const _CatalogCommand(
    this.suggestedWaitTimeout,
    this._parameters,
    this.responseSchema,
    this.executionContract,
  );

  final Duration? suggestedWaitTimeout;
  final List<Map<Object?, Object?>> _parameters;
  final PatchbayResponseSchema? responseSchema;
  final PatchbayExecutionContract executionContract;

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
        row.containsKey('responseSchema')
            ? PatchbayResponseSchema.fromJson(row['responseSchema'])
            : null,
        PatchbayExecutionContract.fromCatalogRow(row),
      );
    }
    return null;
  }
}

final class _Outcome {
  const _Outcome(this.response, this.exitCode, {this.summary});

  final Map<String, Object?> response;
  final int exitCode;

  /// Human rendering for the one-shot path, when one line cannot carry the
  /// result. `null` keeps the shared per-response summary.
  final String? summary;
}

/// A session-directory answer, in both the shapes the CLI prints.
///
/// It carries its own human rendering instead of going through
/// `patchbayResponseSummary`: that function summarises one App response into a
/// single line, and a session listing is a table whose whole value is the rows.
final class _LocalOutcome {
  const _LocalOutcome(this.response, this.text);

  final Map<String, Object?> response;
  final String text;
}

final class _Execution {
  const _Execution(
    this.response, {
    this.catalog,
    this.artifact,
    this.exitCode,
    this.summary,
  });

  final Map<String, Object?> response;
  final Map<String, Object?>? catalog;
  final _ArtifactRequest? artifact;

  /// Set only when the CLI itself decided the outcome, so the classification of
  /// an App response stays in one place.
  final int? exitCode;
  final String? summary;
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
