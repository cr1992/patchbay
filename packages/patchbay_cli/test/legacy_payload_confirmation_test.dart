import 'package:patchbay_cli/src/legacy_payload_confirmation.dart';
import 'package:test/test.dart';

void main() {
  group('legacy payload confirmation', () {
    bool call({
      bool includeRequested = true,
      bool allowWithoutPrompt = false,
      bool stdinTakenByCommand = false,
      bool hasTerminal = true,
      String? line,
      List<String>? prompts,
    }) => confirmLegacyPayloadPersistence(
      includeRequested: includeRequested,
      allowWithoutPrompt: allowWithoutPrompt,
      stdinTakenByCommand: stdinTakenByCommand,
      hasTerminal: hasTerminal,
      readLine: () => line,
      writePrompt: (String prompt) => prompts?.add(prompt),
    );

    test('default records shapes only, without asking anything', () {
      final List<String> prompts = <String>[];
      expect(call(includeRequested: false, prompts: prompts), isFalse);
      expect(prompts, isEmpty);
    });

    // The regression this whole seam exists for: `stdin.hasTerminal` reports
    // true for `</dev/null` on macOS, which is the stdin shape this repo's own
    // automation prescribes. When the escape hatch was only consulted in the
    // `!hasTerminal` branch, automation could never reach it — it got an
    // interactive prompt it cannot answer, then a usage error.
    test(
      'explicit switch is honoured even when stdin looks like a terminal',
      () {
        final List<String> prompts = <String>[];
        expect(
          call(allowWithoutPrompt: true, hasTerminal: true, prompts: prompts),
          isTrue,
        );
        expect(prompts, isEmpty, reason: '显式开关不该再去问一次');
      },
    );

    test('explicit switch is honoured when stdin is a pipe', () {
      expect(call(allowWithoutPrompt: true, hasTerminal: false), isTrue);
    });

    test('non-interactive stdin without the switch fails closed', () {
      expect(
        () => call(hasTerminal: false),
        throwsA(
          isA<FormatException>().having(
            (FormatException failure) => failure.message,
            'message',
            contains('must also pass --allow-non-tty-legacy-payload'),
          ),
        ),
      );
    });

    // Two refusals used to share one message, so a trace that hit end of input
    // was indistinguishable from one that never had a terminal.
    test('prompt reaching end of input reports its own reason', () {
      expect(
        () => call(hasTerminal: true, line: null),
        throwsA(
          isA<FormatException>().having(
            (FormatException failure) => failure.message,
            'message',
            allOf(
              contains('reached end of input'),
              isNot(contains('requires a TTY confirmation')),
            ),
          ),
        ),
      );
    });

    test('only the exact confirmation word opts in', () {
      expect(call(line: 'INCLUDE'), isTrue);
      expect(
        () => call(line: 'include'),
        throwsA(
          isA<FormatException>().having(
            (FormatException failure) => failure.message,
            'message',
            contains('confirmation refused'),
          ),
        ),
      );
    });

    test('a command already consuming stdin cannot also confirm on it', () {
      expect(
        () => call(stdinTakenByCommand: true),
        throwsA(
          isA<FormatException>().having(
            (FormatException failure) => failure.message,
            'message',
            contains('cannot share stdin'),
          ),
        ),
      );
    });
  });
}
