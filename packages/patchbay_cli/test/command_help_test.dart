import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test('navigation group help matches the declaration-derived snapshot', () {
    expect(
      PatchbayCommandHelp.render(patchbayCliParser(), <String>['navigation']),
      '''Usage: patchbay navigation <command> [options]

Commands:
  navigation back --revision <revision>                   Navigate back from an observed revision.
  navigation catalog                                      List destinations exposed by the running App.
  navigation current                                      Read the current destination and revision.
  navigation go <destination-id> --revision <revision>    Replace navigation state with a destination.
  navigation push <destination-id> --revision <revision>  Push a cataloged destination.

Options:
  --revision         Observed navigation revision.
  --timeout-ms       Operation timeout in milliseconds.

Availability is still decided by the running App catalog.
''',
    );
  });

  test(
    'every friendly declaration is represented by help and parser options',
    () {
      final ArgParser parser = patchbayCliParser();
      final Set<String> paths = <String>{};
      for (final PatchbayFriendlyCommand command
          in PatchbayFriendlyCommand.values) {
        expect(command.summary, isNotEmpty, reason: command.name);
        expect(paths.add(command.path.join(' ')), isTrue, reason: command.name);
        for (final String option
            in PatchbayFriendlyCommandRegistry.allowedOptions(command)) {
          expect(parser.options, contains(option), reason: command.name);
        }
        final String help = PatchbayCommandHelp.render(parser, command.path);
        expect(help, contains('Usage: patchbay ${command.path.join(' ')}'));
        expect(help, contains(command.summary));
        expect(help, contains('Service command: ${command.serviceCommand}'));
      }
    },
  );

  test(
    'root and every required group are derived from friendly declarations',
    () {
      final ArgParser parser = patchbayCliParser();
      final String root = PatchbayCommandHelp.render(parser, const <String>[]);
      final Set<String> groups = PatchbayFriendlyCommand.values
          .map((PatchbayFriendlyCommand command) => command.path.first)
          .toSet();
      expect(groups, <String>{'navigation', 'ui', 'logs', 'capture', 'blob'});
      for (final String group in groups) {
        expect(root, contains(group));
        final String groupHelp = PatchbayCommandHelp.render(parser, <String>[
          group,
        ]);
        for (final PatchbayFriendlyCommand command
            in PatchbayFriendlyCommand.values.where(
              (PatchbayFriendlyCommand command) => command.path.first == group,
            )) {
          expect(groupHelp, contains(command.path.join(' ')));
        }
      }
    },
  );

  test(
    'help forms exit zero without session discovery or token stdin',
    () async {
      for (final List<String> arguments in <List<String>>[
        <String>['--help'],
        <String>['-h'],
        <String>['help'],
        <String>['help', 'logs'],
        <String>['capture', '--help'],
        <String>[
          '--direct-endpoint',
          'http://127.0.0.1:1/patchbay/direct/v1',
          '--direct-token-stdin',
          '--direct-application-id',
          'dev.help.fixture',
          '--direct-app-instance-id',
          'help-instance',
          'blob',
          '--help',
        ],
      ]) {
        final ProcessResult result = await Process.run(
          Platform.resolvedExecutable,
          <String>['run', 'bin/patchbay.dart', ...arguments],
          workingDirectory: Directory.current.path,
        );
        expect(result.exitCode, 0, reason: '$arguments\n${result.stderr}');
        expect(result.stderr, isEmpty, reason: '$arguments');
        expect(
          result.stdout,
          contains('Usage: patchbay'),
          reason: '$arguments',
        );
      }
    },
  );

  test('unknown help topic is a usage error without connecting', () async {
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'bin/patchbay.dart', 'help', 'not-a-group'],
      workingDirectory: Directory.current.path,
    );
    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.stderr, contains('unknown help topic'));
    expect(result.stderr, isNot(contains('session')));
  });
}
