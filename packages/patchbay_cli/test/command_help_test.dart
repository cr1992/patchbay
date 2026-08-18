import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

/// Matches the root help's "Friendly command groups" listing row for [group].
Matcher _listsGroup(String group) =>
    matches(RegExp('^  $group +\\d+ commands?\$', multiLine: true));

void main() {
  test('launcher help exposes the local keep-awake override pair', () {
    final String help = PatchbayCommandHelp.render(
      patchbayCliParser(),
      <String>['launch'],
    );

    expect(help, contains('--[no-]keep-awake'));
  });

  test('navigation group help matches the declaration-derived snapshot', () {
    expect(
      PatchbayCommandHelp.render(patchbayCliParser(), <String>['navigation']),
      '''Usage: patchbay navigation <command> [options]

Commands:
  navigation back [--revision <revision>]                   Navigate back from an observed revision.
  navigation catalog                                        List destinations exposed by the running App.
  navigation current                                        Read the current destination and revision.
  navigation go <destination-id> [--revision <revision>]    Replace navigation state with a destination.
  navigation push <destination-id> [--revision <revision>]  Push a cataloged destination.

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
      for (final PatchbayFriendlyCommandSpec command
          in PatchbayFriendlyCommandRegistry.commands) {
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
      PatchbayFriendlyCommandRegistry.commands
          .map((PatchbayFriendlyCommandSpec command) => command.target)
          .toSet(),
      PatchbayCommandTarget.values.toSet(),
    );
  });

  test(
    'root and every required group are derived from friendly declarations',
    () {
      final ArgParser parser = patchbayCliParser();
      final String root = PatchbayCommandHelp.render(parser, const <String>[]);
      final Set<String> groups = PatchbayFriendlyCommandRegistry.commands
          .map((PatchbayFriendlyCommandSpec command) => command.path.first)
          .toSet();
      // This set was previously frozen at the five groups that happened to be
      // declared, which turned the help gap into a contract: `identity`,
      // `catalog`, `snapshot`, `exec` and `job` were dispatchable commands
      // with no help at all. The freeze is now the full dispatchable surface.
      expect(groups, <String>{
        'launch',
        'identity',
        'catalog',
        'describe',
        'snapshot',
        'exec',
        'repl',
        'doctor',
        'permission',
        'job',
        'session',
        'sessions',
        'trace',
        'navigation',
        'ui',
        'logs',
        'capture',
        'blob',
        'perf',
        'net',
      });
      for (final String group in groups) {
        // Matched against the group listing, not anywhere in the page: prose
        // like "`patchbay exec <service-command>`" would otherwise satisfy a
        // bare `contains` while the group was missing from the listing.
        expect(root, _listsGroup(group), reason: group);
        final String groupHelp = PatchbayCommandHelp.render(parser, <String>[
          group,
        ]);
        for (final PatchbayFriendlyCommandSpec command
            in PatchbayFriendlyCommandRegistry.commands.where(
              (PatchbayFriendlyCommandSpec command) =>
                  command.path.first == group,
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
      'session',
      'sessions',
      'navigation',
      'ui',
      'logs',
      'capture',
      'blob',
      'perf',
      'net',
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

  test('a catalog command name is a help topic', () {
    final ArgParser parser = patchbayCliParser();
    // What an operator holds is the protocol name printed in a catalog row or
    // echoed in a response; it used to be an unknown topic.
    expect(
      PatchbayCommandHelp.render(parser, <String>['navigation.go']),
      contains('Usage: patchbay navigation go'),
    );
    expect(
      PatchbayCommandHelp.render(parser, <String>['ui.semantics.tap']),
      contains('Usage: patchbay ui tap'),
    );
    expect(
      PatchbayCommandHelp.render(parser, <String>['patchbay.job.get']),
      contains('Usage: patchbay job get'),
    );

    // Names that several friendly commands share resolve to the menu of them.
    final String wait = PatchbayCommandHelp.render(parser, <String>['ui.wait']);
    expect(wait, contains('Service command: ui.wait'));
    for (final PatchbayFriendlyCommandSpec command
        in PatchbayFriendlyCommandRegistry.commands.where(
          (PatchbayFriendlyCommandSpec command) =>
              command.serviceCommand == 'ui.wait',
        )) {
      expect(wait, contains(command.path.join(' ')), reason: command.name);
    }
    expect(
      PatchbayCommandHelp.render(parser, <String>['blob.metadata']),
      contains('Service command: blob.metadata'),
    );
  });

  test('every declared service command answers as a help topic', () {
    final ArgParser parser = patchbayCliParser();
    for (final PatchbayFriendlyCommandSpec command
        in PatchbayFriendlyCommandRegistry.commands) {
      if (command.serviceCommand case final String name) {
        expect(
          () => PatchbayCommandHelp.render(parser, <String>[name]),
          returnsNormally,
          reason: name,
        );
      }
    }
  });

  test('friendly group aliases answer instead of "unknown topic"', () {
    final ArgParser parser = patchbayCliParser();
    expect(
      PatchbayCommandHelp.render(parser, <String>['navigate']),
      PatchbayCommandHelp.render(parser, <String>['navigation']),
    );
    expect(
      PatchbayCommandHelp.render(parser, <String>['wait']),
      PatchbayCommandHelp.render(parser, <String>['ui', 'wait']),
    );
    expect(
      PatchbayCommandHelp.render(parser, <String>['tap']),
      PatchbayCommandHelp.render(parser, <String>['ui', 'tap']),
    );
    expect(
      PatchbayCommandHelp.render(parser, <String>['navigate', 'go']),
      PatchbayCommandHelp.render(parser, <String>['navigation', 'go']),
    );
  });

  test('help prints the condition each ui wait command sends', () {
    final ArgParser parser = patchbayCliParser();
    final String group = PatchbayCommandHelp.render(parser, <String>[
      'ui',
      'wait',
    ]);
    for (final PatchbayFriendlyCommandSpec command
        in PatchbayFriendlyCommandRegistry.commands) {
      if (command.waitCondition case final String condition) {
        expect(group, contains(condition), reason: command.name);
        expect(
          PatchbayCommandHelp.render(parser, command.path),
          contains('Sends condition: $condition'),
          reason: command.name,
        );
      }
    }
    // The mapping block belongs only where a condition exists.
    expect(
      PatchbayCommandHelp.render(parser, <String>['navigation']),
      isNot(contains('condition')),
    );
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

  test('an unknown protocol name is still an unknown topic', () {
    // The catalog-name lookup must not become a wildcard: a name no
    // declaration sends has no help to show.
    expect(
      () => PatchbayCommandHelp.render(patchbayCliParser(), <String>[
        'navigation.teleport',
      ]),
      throwsA(isA<FormatException>()),
    );
  });
}
