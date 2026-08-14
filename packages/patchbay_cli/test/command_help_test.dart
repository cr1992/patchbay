import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

/// Matches the root help's "Friendly command groups" listing row for [group].
Matcher _listsGroup(String group) =>
    matches(RegExp('^  $group +\\d+ commands?\$', multiLine: true));

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
        expect(help, contains(PatchbayCommandHelp.protocolLine(command)));
        expect(help, contains(PatchbayCommandHelp.availabilityLine(command)));
        if (command.target == PatchbayCommandTarget.declaredServiceCommand) {
          expect(help, contains('Service command: ${command.serviceCommand}'));
        }
      }
    },
  );

  test('every dispatch target is claimed by at least one declaration', () {
    // `runPatchbayCli` switches over `PatchbayCommandTarget` with no default
    // arm. Together with this test, a target can be neither unwired nor
    // unreachable, which is what keeps dispatch and help on one declaration.
    expect(
      PatchbayFriendlyCommand.values
          .map((PatchbayFriendlyCommand command) => command.target)
          .toSet(),
      PatchbayCommandTarget.values.toSet(),
    );
  });

  test(
    'root and every required group are derived from friendly declarations',
    () {
      final ArgParser parser = patchbayCliParser();
      final String root = PatchbayCommandHelp.render(parser, const <String>[]);
      final Set<String> groups = PatchbayFriendlyCommand.values
          .map((PatchbayFriendlyCommand command) => command.path.first)
          .toSet();
      // This set was previously frozen at the five groups that happened to be
      // declared, which turned the help gap into a contract: `identity`,
      // `catalog`, `snapshot`, `exec` and `job` were dispatchable commands
      // with no help at all. The freeze is now the full dispatchable surface.
      expect(groups, <String>{
        'identity',
        'catalog',
        'snapshot',
        'exec',
        'repl',
        'job',
        'navigation',
        'ui',
        'logs',
        'capture',
        'blob',
      });
      for (final String group in groups) {
        // Matched against the group listing, not anywhere in the page: prose
        // like "`patchbay exec <service-command>`" would otherwise satisfy a
        // bare `contains` while the group was missing from the listing.
        expect(root, _listsGroup(group), reason: group);
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
        <String>['help', 'job'],
        <String>['help', 'identity'],
        <String>['help', 'exec'],
        <String>['help', 'ui', 'text', 'set'],
        <String>['capture', '--help'],
        <String>['ui', 'widget-tree', '--help'],
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

  test('help covers every command the CLI can dispatch, end to end', () async {
    // Process-level because the regression was reachable only through argv:
    // `patchbay help job` and `patchbay ui widget-tree --help` both exited 64
    // while the same commands executed fine.
    Future<ProcessResult> run(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'bin/patchbay.dart', ...arguments],
      workingDirectory: Directory.current.path,
    );

    final ProcessResult root = await run(<String>['--help']);
    expect(root.exitCode, 0, reason: root.stderr.toString());
    for (final String group in <String>[
      'identity',
      'catalog',
      'snapshot',
      'exec',
      'job',
      'navigation',
      'ui',
      'logs',
      'capture',
      'blob',
    ]) {
      expect(root.stdout, _listsGroup(group), reason: group);
    }

    final ProcessResult job = await run(<String>['help', 'job']);
    expect(job.exitCode, 0, reason: job.stderr.toString());
    expect(job.stdout, contains('job get <job-id>'));
    expect(job.stdout, contains('job cancel <job-id>'));

    final ProcessResult ui = await run(<String>['help', 'ui']);
    expect(ui.exitCode, 0, reason: ui.stderr.toString());
    for (final String command in <String>[
      'ui widget-tree',
      'ui render-tree',
      'ui focus-tree',
      'ui semantics tree',
      'ui semantics action',
      'ui text set',
      'ui text enter',
      'ui wait semantics-mounted',
    ]) {
      expect(ui.stdout, contains(command), reason: command);
    }
  });

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
