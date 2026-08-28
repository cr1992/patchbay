import 'dart:convert';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// How many JSON documents `--json` puts on stdout, and on which channel.
///
/// Both halves of that contract are load-bearing for a script and neither was
/// pinned: every other test decodes stdout with `jsonDecode` because it wants
/// the fields, so the document count was only ever asserted as a side effect,
/// and nothing at all said that a streaming command is read differently. An
/// operator who meets `Extra data` has to guess which of the two rules they
/// broke, and the guess that costs the most is "the CLI emits several
/// documents" — it sends them to write a multi-document parser for output that
/// never had more than one.
final class _Run {
  const _Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  /// stdout read the way a script's standard parser reads it.
  ///
  /// `jsonDecode` rejects anything after the first document, so this getter
  /// *is* the assertion: it cannot pass on output that carries a second
  /// document, a stray line, or prose.
  Map<String, Object?> get document => jsonDecode(out) as Map<String, Object?>;

  /// stdout read the way a script reads a stream: one document per line.
  List<Map<String, Object?>> get perLine => <Map<String, Object?>>[
    for (final String line in const LineSplitter().convert(out))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
}

FakePatchbayClient _client() => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    <String, Object?>{'name': 'logs.export'},
  ],
  handle: (String command, Map<String, Object?> arguments) async =>
      fakeCommandNotRegistered(),
);

Future<_Run> _run(List<String> arguments, {List<String>? replInput}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => _client(),
    replInput: replInput == null
        ? null
        : Stream<String>.fromIterable(replInput),
    output: out,
    errorOutput: err,
  );
  return _Run(exitCode, out.toString(), err.toString());
}

void main() {
  test('a one-shot command puts exactly one document on stdout', () async {
    final _Run result = await _run(<String>['--json', 'identity']);

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.document, isNotEmpty);
    // The human channel stays empty on success, so nothing can join stdout by
    // accident even for a caller that merges the two.
    expect(result.err, isEmpty);
  });

  test('a failing one-shot command still puts exactly one document', () async {
    final _Run result = await _run(<String>[
      '--json',
      'identity',
      'unexpected',
    ]);

    expect(result.exitCode, isNot(PatchbayExitCode.accepted));
    expect(result.document.keys, <String>['error']);
    // The sentence is on the other channel — which is the whole reason the
    // count above holds for a non-zero exit too.
    expect(result.err, isNotEmpty);
  });

  test('merging stderr into stdout is what breaks the parse', () async {
    final _Run result = await _run(<String>[
      '--json',
      'identity',
      'unexpected',
    ]);

    // `2>&1` in a pipeline produces exactly this string, and the failure it
    // raises names trailing data — which reads like a second document and is
    // not one. The test states the cause so the message cannot be misread as
    // the CLI emitting more than it promised.
    expect(() => jsonDecode(result.out + result.err), throwsFormatException);
    expect(result.err.trim(), isNot(startsWith('{')));
  });

  test('repl is a stream: one document per line, not one document', () async {
    final _Run result = await _run(
      <String>['--json', 'repl'],
      replInput: <String>['identity', 'snapshot', 'identity'],
    );

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.perLine, hasLength(3));
    expect(result.perLine.map((Map<String, Object?> row) => row['line']), <int>[
      1,
      2,
      3,
    ]);
    // Reading a streaming command as one document is the documented mistake,
    // so the docs' distinction is only true while this keeps throwing.
    expect(() => result.document, throwsFormatException);
  });
}
