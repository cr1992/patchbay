import 'dart:convert';

import 'package:args/args.dart';

import 'command_help.dart';
import 'command_registry.dart';
import 'result.dart';

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
  }) : _parser = parser,
       _execute = execute,
       _out = out,
       _err = err,
       _json = json;

  final ArgParser _parser;
  final PatchbayReplCommand _execute;
  final StringSink _out;
  final StringSink _err;
  final bool _json;

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
      } on FormatException catch (error) {
        _writeFailure(number, <String>[], PatchbayExitCode.usage, error.message);
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
        _writeResult(number, parsed.rest, outcome);
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
  }

  void _writeResult(
    int number,
    List<String> command,
    PatchbayReplOutcome outcome,
  ) {
    if (_json) {
      _out.writeln(
        jsonEncode(<String, Object?>{
          'line': number,
          'command': command,
          'exitCode': outcome.exitCode,
          'response': outcome.response,
        }),
      );
      return;
    }
    _out.writeln(
      '[$number] exit=${outcome.exitCode} '
      '${patchbayResponseSummary(outcome.response)}',
    );
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
