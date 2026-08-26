import 'dart:convert';

import 'package:args/args.dart';

import 'command_help.dart';
import 'command_registry.dart';
import 'doctor.dart';
import 'output/brief_view.dart';
import 'output/local_artifact.dart';
import 'registry/argument_decoder.dart';
import 'result.dart';
import 'ui_manifest.dart';

/// One command's result, classified exactly as the same command would be
/// classified when run standalone.
final class PatchbayReplOutcome {
  const PatchbayReplOutcome(this.response, this.exitCode);

  final Map<String, Object?> response;
  final int exitCode;
}

/// Runs one already-parsed command line against the session's connection.
typedef PatchbayReplCommand =
    Future<PatchbayReplOutcome> Function(ArgResults parsed);

/// Options that select or configure the transport.
///
/// The whole point of this mode is that the connection is established once, so
/// a per-line transport option could only be honoured by reconnecting — the
/// cost the session exists to remove. Accepting and ignoring them would be
/// worse: the operator would believe a later line ran somewhere it did not.
const Set<String> patchbayReplSessionOptions = <String>{
  'ws-uri',
  'session',
  'session-dir',
  'direct-endpoint',
  'direct-token-stdin',
  'direct-application-id',
  'direct-app-instance-id',
  'direct-schema-version',
  'transport-timeout-ms',
  'json',
};

/// Splits one repl input line into argv words.
///
/// Quoting follows the usual shell rules because operators paste JSON into
/// `--args`: double quotes honour backslash escapes, single quotes are
/// literal. An unterminated quote is a usage error for that line rather than a
/// silent truncation that would send a different command than the one typed.
List<String> tokenizePatchbayReplLine(String line) {
  final List<String> words = <String>[];
  final StringBuffer current = StringBuffer();
  var started = false;
  String? quote;
  for (var index = 0; index < line.length; index += 1) {
    final String character = line[index];
    if (quote == null && (character == ' ' || character == '\t')) {
      if (started) {
        words.add(current.toString());
        current.clear();
        started = false;
      }
      continue;
    }
    if (quote == null && (character == '"' || character == "'")) {
      quote = character;
      started = true;
      continue;
    }
    if (quote == character) {
      quote = null;
      continue;
    }
    if (character == r'\' && quote != "'" && index + 1 < line.length) {
      index += 1;
      current.write(line[index]);
      started = true;
      continue;
    }
    current.write(character);
    started = true;
  }
  if (quote != null) {
    throw const FormatException('unterminated quote in repl command line');
  }
  if (started) words.add(current.toString());
  return words;
}

/// Executes many typed commands over one already-established connection.
///
/// The process exit code cannot carry per-command results — exit code `0`
/// already means "the App admitted this and returned a non-failure result",
/// and a session runs many commands. So every line reports its own exit code,
/// and the session's own code only describes the session: `0` when the loop
/// ended cleanly, otherwise the class of the error that ended it.
///
/// A rejected or typed-failure line is normal traffic and does not end the
/// session. A transport, protocol or session error does: it says the reused
/// connection or its peer is no longer the one the operator selected, and the
/// only honest response is to stop rather than quietly reconnect.
final class PatchbayReplSession {
  PatchbayReplSession({
    required ArgParser parser,
    required PatchbayReplCommand execute,
    required StringSink out,
    required StringSink err,
    required bool json,
    required PatchbayLocalArtifactWriter outputWriter,
    String sessionView = patchbayViewFull,
    Map<String, String>? environment,
    void Function()? onLineRendered,
  }) : _parser = parser,
       _execute = execute,
       _out = out,
       _err = err,
       _json = json,
       _outputWriter = outputWriter,
       _sessionView = sessionView,
       _environment = environment,
       _onLineRendered = onLineRendered;

  final ArgParser _parser;
  final PatchbayReplCommand _execute;
  final StringSink _out;
  final StringSink _err;
  final bool _json;
  final PatchbayLocalArtifactWriter _outputWriter;

  /// Called once a line has been fully rendered, including any PB-050-20
  /// spill the rendering triggered.
  ///
  /// A repl line's trace run cannot be closed by [_execute] itself: spilling
  /// happens at render time, which is after [_execute] has returned, so a
  /// `command.finished` written inside the closure would land *before* the
  /// `artifact.attached` event belonging to that same line — and the
  /// attachment would then read as the first thing the next line did. The
  /// caller therefore hands the run's closing step here, where "this line is
  /// done" is actually true.
  final void Function()? _onLineRendered;

  /// The view `patchbay --json --view brief ... repl` opened the session
  /// with; a line's own `--view` overrides it for that line only (PB-050-21
  /// section 6 — this is the only per-line override `--view` gets, and it
  /// deliberately does not reconnect).
  final String _sessionView;
  final Map<String, String>? _environment;

  /// Whether this session has already explained a non-resumed App.
  ///
  /// A screen-off device refuses every UI line, so repeating the remedies each
  /// time would bury the results the operator is reading. Once is a warning;
  /// ten times is noise that hides the ninth line's answer.
  bool _lifecycleExplained = false;

  Future<int> run(Stream<String> lines) async {
    var number = 0;
    await for (final String raw in lines) {
      number += 1;
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line == 'exit' || line == 'quit') break;

      final List<String> words;
      final ArgResults parsed;
      try {
        words = tokenizePatchbayReplLine(line);
        parsed = _parser.parse(words);
        _rejectSessionScopedOptions(parsed);
        if (_resolvedView(parsed) == patchbayViewBrief && !_json) {
          throw const FormatException('--view brief requires --json');
        }
      } on FormatException catch (error) {
        _writeFailure(
          number,
          <String>[],
          PatchbayExitCode.usage,
          error.message,
        );
        continue;
      }

      if (_helpTopic(parsed) case final List<String> topic) {
        try {
          _out.write(PatchbayCommandHelp.render(_parser, topic));
        } on FormatException catch (error) {
          _writeFailure(
            number,
            parsed.rest,
            PatchbayExitCode.usage,
            error.message,
          );
        }
        continue;
      }
      if (parsed.rest.isEmpty) {
        _writeFailure(
          number,
          parsed.rest,
          PatchbayExitCode.usage,
          PatchbayCommandHelp.usageLine(),
        );
        continue;
      }

      try {
        final PatchbayReplOutcome outcome = await _execute(parsed);
        try {
          await _writeResult(number, parsed, outcome);
        } finally {
          // Even a line whose rendering threw (an `--output` that already
          // exists, say) ran to completion as far as the trace is concerned:
          // the run must be closed, or the next line's events would be read
          // as belonging to this one.
          _onLineRendered?.call();
        }
      } on FormatException catch (error) {
        _writeFailure(
          number,
          parsed.rest,
          PatchbayExitCode.usage,
          error.message,
        );
      } on PatchbayJobWaitTimeout {
        _writeFailure(
          number,
          parsed.rest,
          PatchbayExitCode.typedFailure,
          'waitTimeout',
        );
      } on PatchbayUiManifestException catch (error) {
        // A file this line could not read says nothing about the connection
        // the session is reusing, so it ends the line the way a usage error
        // does rather than tearing down every command after it.
        _writeFailure(
          number,
          parsed.rest,
          PatchbayExitCode.usage,
          error.sentence,
        );
      }
    }
    return PatchbayExitCode.accepted;
  }

  void _rejectSessionScopedOptions(ArgResults parsed) {
    for (final String name in patchbayReplSessionOptions) {
      if (parsed.wasParsed(name)) {
        throw FormatException(
          '--$name belongs to the repl session, not to one command; '
          'pass it to `patchbay ... repl` instead',
        );
      }
    }
    if (parsed.wasParsed('stdin')) {
      // The command stream already owns stdin, so there is no no-echo channel
      // left to read a secret from. Downgrading to an echoing read would put
      // the value into scrollback; use a one-shot `patchbay --stdin ...`.
      throw const FormatException(
        '--stdin is unavailable inside a repl session: the command stream '
        'already owns stdin; run that command as a one-shot instead',
      );
    }
    if (parsed.rest.isNotEmpty && parsed.rest.first == 'repl') {
      throw const FormatException('a repl session cannot nest another repl');
    }
    // Session selection decides which App the *next* process connects to. This
    // one already holds its connection, so honouring `session use` here would
    // change nothing about the lines that follow it while reading as if it had.
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localSessionStore) {
      throw const FormatException(
        'session-directory commands are unavailable inside a repl session: '
        'the connection is already chosen; run them as a one-shot instead',
      );
    }
    // Doctor is about how a connection gets established, and it answers with a
    // verdict rather than an admission envelope — so a repl line could neither
    // exercise the dial it is about nor carry its result through the per-line
    // exit code every other line uses. The session prints its own lifecycle
    // preflight when it opens; the rest is a one-shot.
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localDiagnostics) {
      throw const FormatException(
        'doctor is unavailable inside a repl session: it diagnoses how a '
        'connection is established, and this session already holds one; run '
        'it as a one-shot instead',
      );
    }
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target ==
        PatchbayCommandTarget.localPermissionDriver) {
      throw const FormatException(
        'permission commands are unavailable inside a repl session: they '
        'use an external driver and write operations require a launcher '
        'session trust record; run them as a one-shot instead',
      );
    }
  }

  Future<void> _writeResult(
    int number,
    ArgResults parsed,
    PatchbayReplOutcome outcome,
  ) async {
    _explainLifecycleOnce(outcome.response);
    final List<String> command = parsed.rest;
    final PatchbayFriendlyCommandSpec? spec =
        PatchbayFriendlyCommandRegistry.specFor(command);
    final Map<String, Object?> response = await _finishReplRendering(
      spec: spec,
      parsed: parsed,
      outcome: outcome,
      number: number,
      command: command,
    );
    if (_json) {
      _out.writeln(
        jsonEncode(<String, Object?>{
          'line': number,
          'command': command,
          'exitCode': outcome.exitCode,
          'response': response,
        }),
      );
      return;
    }
    _out.writeln(
      '[$number] exit=${outcome.exitCode} '
      '${patchbayResponseSummary(response)}',
    );
  }

  /// The PB-050-20 / PB-050-21 render-time seam for one repl line: spill
  /// first, project second, matching the one-shot path in `cli.dart`.
  ///
  /// The `renderDocument` closures below reproduce exactly what `_json`/
  /// human rendering below would print unspilled, so the PB-050-20
  /// threshold measures the real per-line document — compact JSON or a
  /// human summary line — not the one-shot shape.
  Future<Map<String, Object?>> _finishReplRendering({
    required PatchbayFriendlyCommandSpec? spec,
    required ArgResults parsed,
    required PatchbayReplOutcome outcome,
    required int number,
    required List<String> command,
  }) async {
    final int maxInlineBytes =
        ArgumentDecoder.optionalInt(parsed, 'max-inline-bytes') ??
        patchbayDefaultMaxInlineBytes;
    final PatchbayRenderedMemberSpillResult spilled =
        await maybeSpillRenderedMember(
          writer: _outputWriter,
          spec: spec,
          response: outcome.response,
          exitCode: outcome.exitCode,
          explicitOutputPath: parsed.option('output'),
          force: parsed.flag('force'),
          maxInlineBytes: maxInlineBytes,
          renderDocument: (Map<String, Object?> candidate) => _json
              ? jsonEncode(<String, Object?>{
                  'line': number,
                  'command': command,
                  'exitCode': outcome.exitCode,
                  'response': candidate,
                })
              : '[$number] exit=${outcome.exitCode} '
                    '${patchbayResponseSummary(candidate)}',
          environment: _environment,
        );
    attachSpilledArtifactToTrace(spilled.artifact);
    if (_resolvedView(parsed) != patchbayViewBrief) return spilled.response;
    return projectPatchbayBriefView(
      spec: spec,
      response: spilled.response,
      exitCode: outcome.exitCode,
    );
  }

  String _resolvedView(ArgResults parsed) =>
      parsed.wasParsed('view') ? parsed.option('view')! : _sessionView;

  /// Prints the lifecycle remedies the first time a line proves they apply.
  ///
  /// A session is opened once and then typed into, often as a whole heredoc of
  /// lines, and against a screen-off device every one of them is refused with
  /// nothing but a code. The remedies are platform-specific and none of them
  /// is guessable from `uiWaitLifecycleNotResumed`, so the session says them
  /// out loud — on stderr, because `--json` promises stdout carries only
  /// command results.
  ///
  /// It is read out of a refusal the App produced anyway rather than out of a
  /// probe of the session's own: a repl must run the lines that were typed and
  /// nothing else.
  void _explainLifecycleOnce(Map<String, Object?> response) {
    if (_lifecycleExplained) return;
    if (patchbayLifecycleBannerFor(response) case final String banner) {
      _lifecycleExplained = true;
      _err.writeln(banner);
    }
  }

  void _writeFailure(
    int number,
    List<String> command,
    int exitCode,
    String message,
  ) {
    if (_json) {
      _out.writeln(
        jsonEncode(<String, Object?>{
          'line': number,
          'command': command,
          'exitCode': exitCode,
          'error': message,
        }),
      );
      return;
    }
    _out.writeln('[$number] exit=$exitCode');
    _err.writeln(message);
  }

  static List<String>? _helpTopic(ArgResults parsed) {
    final List<String> words = parsed.rest;
    if (words case ['help', ...final List<String> topic]) return topic;
    if (parsed.flag('help')) return words;
    return null;
  }
}
