import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'artifact_download.dart';
import 'client.dart';
import 'command_help.dart';
import 'command_registry.dart';
import 'commands/catalog_invoker.dart';
import 'commands/command_dispatcher.dart';
import 'commands/command_parser.dart';
import 'commands/session_commands.dart';
import 'commands/trace_commands.dart';
import 'connection/connector.dart';
import 'doctor.dart';
import 'keep_awake_policy.dart';
import 'launcher.dart';
import 'legacy_payload_confirmation.dart';
import 'output/output_formatter.dart';
import 'permission_command.dart';
import 'permission_driver.dart';
import 'repl.dart';
import 'result.dart';
import 'rpc_timeout.dart';
import 'sensitive_input.dart';
import 'session.dart';
import 'trace.dart';
import 'trace/trace_context.dart';
import 'ui_manifest.dart';

export 'commands/command_parser.dart';

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
  if (!PatchbayTraceContext.isInitialized) {
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
    PatchbayConnector.validateGlobalShape(parsed);
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
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localSessionStore) {
      final LocalOutcome outcome =
          LocalSessionCommandHandler.runLocalSessionCommand(parsed);
      out.writeln(
        json
            ? const JsonEncoder.withIndent('  ').convert(outcome.response)
            : outcome.text,
      );
      return PatchbayExitCode.accepted;
    }
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localTraceStore) {
      final LocalOutcome outcome =
          LocalTraceCommandHandler.runLocalTraceCommand(parsed);
      out.writeln(
        json
            ? const JsonEncoder.withIndent('  ').convert(outcome.response)
            : outcome.text,
      );
      return PatchbayExitCode.accepted;
    }
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localDiagnostics) {
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
      final PatchbayDoctorReport report = await runPatchbayDoctor(
        options: parsed,
        connect: connect ?? PatchbayConnector.connect,
        rpcTimeout: PatchbayConnector.rpcTimeout(parsed),
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
      OutputFormatter.writeOutput(
        out,
        outcome.response,
        json: json,
        summary: outcome.summary,
      );
      return outcome.exitCode;
    }
    final bool repl = _isRepl(parsed);
    if (repl) {
      PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
      _validateReplShape(parsed);
    }
    final PatchbayUiManifest? manifest = CatalogInvoker.preReadUiManifest(
      parsed,
    );
    final Duration rpcTimeout = PatchbayConnector.rpcTimeout(parsed);
    connection = PatchbayTimeoutClient(
      await dialPatchbayUnderBudget(
        () => (connect ?? PatchbayConnector.connect)(parsed),
        rpcTimeout: rpcTimeout,
      ),
      rpcTimeout: rpcTimeout,
    );
    if (repl) {
      return await PatchbayReplSession(
        parser: parser,
        execute: (ArgResults line) async {
          final PatchbayTraceRecorder? trace =
              PatchbayTraceContext.currentRecorder;
          final PatchbayFriendlyCommandSpec? lineSpec =
              PatchbayFriendlyCommandRegistry.specFor(line.rest);
          final String? runId = trace == null || lineSpec == null
              ? null
              : trace.commandStarted(
                  lineSpec.path.join(' '),
                  transport: _traceTransport(parsed),
                );
          final Outcome outcome = await _renewKeepAwakeAfterSuccess(
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
    final Outcome outcome = await _renewKeepAwakeAfterSuccess(
      connection,
      parsed,
      await _executeOnce(connection, parsed, manifest: manifest),
      resolveKeepAwakePolicy(),
    );
    OutputFormatter.writeOutput(
      out,
      outcome.response,
      json: json,
      summary: outcome.summary,
    );
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
  final PatchbayFriendlyCommandSpec? spec = parsed == null
      ? null
      : PatchbayFriendlyCommandRegistry.specFor(parsed.rest);
  if (parsed == null ||
      spec == null ||
      spec.target == PatchbayCommandTarget.localTraceStore ||
      _helpTopic(parsed) != null) {
    if (parsed != null &&
        parsed.flag('include-legacy-payload') &&
        spec?.target == PatchbayCommandTarget.localTraceStore) {
      final StringSink usageOut = output ?? stdout;
      final StringSink usageError = errorOutput ?? stderr;
      const FormatException failure = FormatException(
        '--include-legacy-payload applies to a traced command, not to a local '
        'trace subcommand; pass it on each command whose legacy payload should '
        'be stored',
      );
      return _fail(
        usageOut,
        usageError,
        json: parsed.flag('json'),
        message: failure.message,
        envelope: _usageEnvelope(failure),
        exitCode: PatchbayExitCode.usage,
      );
    }
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
      zoneValues: const <Object?, Object?>{
        PatchbayTraceZoneKeys.initialized: true,
      },
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
        zoneValues: const <Object?, Object?>{
          PatchbayTraceZoneKeys.initialized: true,
        },
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
        PatchbayTraceZoneKeys.initialized: true,
        PatchbayTraceZoneKeys.recorder: recorder,
        PatchbayTraceZoneKeys.includeLegacyPayload: includeLegacy,
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

Future<Outcome> _executeOnce(
  PatchbayClient connection,
  ArgResults parsed, {
  PatchbayUiManifest? manifest,
}) async {
  try {
    final ExecutionResult execution = await CommandDispatcher.execute(
      connection,
      parsed,
      manifest: manifest,
    );
    Map<String, Object?> output = execution.response;
    if (execution.artifact case final ArtifactRequest artifact) {
      if (patchbayExitCodeFor(output) == PatchbayExitCode.accepted) {
        final PatchbayDownloadedArtifact downloaded =
            await PatchbayArtifactDownloader(
              chunkBytes: OutputFormatter.blobChunkBytes(execution.catalog!),
              invoke: (String command, Map<String, Object?> arguments) =>
                  CatalogInvoker.invokeAgainstCatalog(
                    connection,
                    execution.catalog!,
                    command,
                    arguments,
                  ),
            ).download(
              metadataJson: OutputFormatter.artifactMetadata(
                output,
                artifact.disposition,
              ),
              outputPath: artifact.outputPath,
              force: artifact.force,
            );
        PatchbayTraceContext.currentRecorder?.attachArtifact(
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
    return Outcome(
      output,
      execution.exitCode ?? patchbayExitCodeFor(output),
      summary: execution.summary,
    );
  } on PatchbayArtifactRejected catch (rejected) {
    return Outcome(rejected.response, patchbayExitCodeFor(rejected.response));
  }
}

Future<Outcome> _renewKeepAwakeAfterSuccess(
  PatchbayClient connection,
  ArgResults parsed,
  Outcome outcome,
  PatchbayKeepAwakePolicy policy,
) async {
  if (!policy.enabled || outcome.exitCode != PatchbayExitCode.accepted) {
    return outcome;
  }
  final String? serviceCommand = PatchbayFriendlyCommandRegistry.specFor(
    parsed.rest,
  )?.serviceCommand;
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
  return Outcome(
    <String, Object?>{...outcome.response, 'localKeepAwake': renewal.toJson()},
    renewal.success ? outcome.exitCode : PatchbayExitCode.typedFailure,
    summary: '$originalSummary $keepAwakeSummary',
  );
}

List<String>? _helpTopic(ArgResults parsed) {
  final List<String> words = parsed.rest;
  if (words case ['help', ...final List<String> topic]) return topic;
  if (parsed.flag('help')) return words;
  return null;
}

bool _isRepl(ArgResults parsed) =>
    parsed.rest.length == 1 && parsed.rest.single == 'repl';

void _validateReplShape(ArgResults parsed) {
  if (parsed.option('direct-endpoint') != null) {
    throw const FormatException(
      'repl cannot use --direct-endpoint: the bearer token and the command '
      'stream would have to share one stdin',
    );
  }
}

bool _confirmLegacyPayload(ArgResults parsed) =>
    confirmLegacyPayloadPersistenceFromStdio(
      includeRequested: parsed.flag('include-legacy-payload'),
      allowWithoutPrompt: parsed.flag('allow-non-tty-legacy-payload'),
      stdinTakenByCommand:
          parsed.flag('stdin') || parsed.flag('direct-token-stdin'),
    );

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

ArgResults? _tryParseForTrace(List<String> arguments) {
  try {
    return patchbayCliParser().parse(arguments);
  } on FormatException {
    return null;
  }
}

bool _jsonRequestedIn(List<String> arguments) {
  var json = false;
  for (final String word in arguments) {
    if (word == '--') break;
    if (word == '--json') json = true;
    if (word == '--no-json') json = false;
  }
  return json;
}

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

PatchbayErrorEnvelope _usageEnvelope(FormatException failure) =>
    PatchbayErrorEnvelope(
      'usageError',
      details: <String, Object?>{'message': failure.message},
    );
