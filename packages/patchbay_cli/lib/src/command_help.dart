import 'package:args/args.dart';

import 'command_registry.dart';

/// Renders CLI help from the parser and friendly-command declarations.
abstract final class PatchbayCommandHelp {
  static String render(ArgParser parser, List<String> topic) {
    if (topic.isEmpty) return _root(parser);
    final List<String> path = PatchbayFriendlyCommandRegistry.canonicalPath(
      topic,
    );
    final List<PatchbayFriendlyCommand> matches = PatchbayFriendlyCommand.values
        .where(
          (PatchbayFriendlyCommand command) => _startsWith(command.path, path),
        )
        .toList(growable: false);
    if (matches.isNotEmpty) {
      if (matches.length == 1 && matches.single.path.length == path.length) {
        return _command(parser, matches.single);
      }
      return _group(parser, path, matches);
    }
    // What an operator has in hand is usually a catalog row or a response
    // field — a protocol name, not the CLI's own path. Sending that to
    // "unknown help topic" made the catalog and the help two separate maps.
    if (topic.length == 1) {
      final List<PatchbayFriendlyCommand> byService =
          PatchbayFriendlyCommand.values
              .where(
                (PatchbayFriendlyCommand command) =>
                    command.serviceCommand == topic.single,
              )
              .toList(growable: false);
      if (byService.length == 1) return _command(parser, byService.single);
      if (byService.length > 1) {
        return _serviceCommand(parser, topic.single, byService);
      }
    }
    throw FormatException('unknown help topic: ${topic.join(' ')}');
  }

  /// One-line usage banner, derived from the same declarations as the help.
  static String usageLine() {
    final List<String> groups =
        PatchbayFriendlyCommand.values
            .map((PatchbayFriendlyCommand command) => command.path.first)
            .toSet()
            .toList()
          ..sort();
    return 'usage: patchbay [connection] [--json] <${groups.join('|')}>; '
        'run `patchbay --help` for the full command list';
  }

  static String _root(ArgParser parser) {
    final Map<String, int> groups = <String, int>{};
    for (final PatchbayFriendlyCommand command
        in PatchbayFriendlyCommand.values) {
      groups.update(
        command.path.first,
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final List<String> names = groups.keys.toList()..sort();
    final StringBuffer output = StringBuffer()
      ..writeln('Patchbay consumer-neutral runtime debugging CLI')
      ..writeln()
      ..writeln('Usage: patchbay [options] <command> [arguments]')
      ..writeln()
      ..writeln('Use `patchbay catalog` to discover runtime capabilities and')
      ..writeln(
        '`patchbay exec <service-command>` as the generic escape hatch.',
      )
      ..writeln()
      ..writeln('Friendly command groups:');
    for (final String name in names) {
      final int count = groups[name]!;
      output.writeln(
        '  ${name.padRight(12)} $count ${count == 1 ? 'command' : 'commands'}',
      );
    }
    output
      ..writeln()
      ..writeln('Run `patchbay help <group>` or `patchbay <group> --help`.')
      ..writeln(
        'A catalog name works as a topic too: `patchbay help navigation.go`.',
      )
      ..writeln()
      ..writeln('Options:')
      ..writeln(parser.usage);
    return output.toString();
  }

  static String _group(
    ArgParser parser,
    List<String> topic,
    List<PatchbayFriendlyCommand> commands,
  ) {
    final List<PatchbayFriendlyCommand> sorted = List.of(commands)
      ..sort(
        (PatchbayFriendlyCommand a, PatchbayFriendlyCommand b) =>
            a.path.join(' ').compareTo(b.path.join(' ')),
      );
    final List<String> usages = sorted
        .map((PatchbayFriendlyCommand command) => _usage(command))
        .toList(growable: false);
    final int width = usages.fold<int>(
      0,
      (int value, String usage) => usage.length > value ? usage.length : value,
    );
    final Set<String> optionNames = <String>{
      for (final PatchbayFriendlyCommand command in sorted)
        ...PatchbayFriendlyCommandRegistry.allowedOptions(command),
    };
    final StringBuffer output = StringBuffer()
      ..writeln('Usage: patchbay ${topic.join(' ')} <command> [options]')
      ..writeln()
      ..writeln('Commands:');
    for (var index = 0; index < sorted.length; index += 1) {
      output.writeln(
        '  ${usages[index].padRight(width)}  ${sorted[index].summary}',
      );
    }
    _writeConditions(output, sorted);
    _writeOptions(output, parser, optionNames);
    output
      ..writeln()
      ..writeln('Availability is still decided by the running App catalog.');
    return output.toString();
  }

  /// Help for one protocol name that several CLI commands send.
  ///
  /// `ui.wait` and `blob.metadata` are each reachable through more than one
  /// friendly path, so the catalog name maps to a small menu rather than to a
  /// single command.
  static String _serviceCommand(
    ArgParser parser,
    String serviceCommand,
    List<PatchbayFriendlyCommand> commands,
  ) {
    final List<PatchbayFriendlyCommand> sorted = List.of(commands)
      ..sort(
        (PatchbayFriendlyCommand a, PatchbayFriendlyCommand b) =>
            a.path.join(' ').compareTo(b.path.join(' ')),
      );
    final List<String> usages = sorted
        .map((PatchbayFriendlyCommand command) => _usage(command))
        .toList(growable: false);
    final int width = usages.fold<int>(
      0,
      (int value, String usage) => usage.length > value ? usage.length : value,
    );
    final StringBuffer output = StringBuffer()
      ..writeln('Usage: patchbay <command> [options]')
      ..writeln()
      ..writeln('Service command: $serviceCommand')
      ..writeln()
      ..writeln('CLI commands that send it:');
    for (var index = 0; index < sorted.length; index += 1) {
      output.writeln(
        '  ${usages[index].padRight(width)}  ${sorted[index].summary}',
      );
    }
    _writeConditions(output, sorted);
    _writeOptions(output, parser, <String>{
      for (final PatchbayFriendlyCommand command in sorted)
        ...PatchbayFriendlyCommandRegistry.allowedOptions(command),
    });
    output
      ..writeln()
      ..writeln(availabilityLine(sorted.first));
    return output.toString();
  }

  /// Prints how a `ui wait` subcommand maps onto the `condition` it sends.
  ///
  /// The names differ deliberately — hyphenated CLI syntax versus the wire
  /// value — but a response only ever shows the wire value, so without this
  /// table the operator has to guess which command produced it. Both spellings
  /// are accepted on the command line; neither name changes.
  static void _writeConditions(
    StringBuffer output,
    List<PatchbayFriendlyCommand> commands,
  ) {
    final List<PatchbayFriendlyCommand> conditions = commands
        .where((PatchbayFriendlyCommand command) => command.waitCondition != null)
        .toList(growable: false);
    if (conditions.isEmpty) return;
    final int width = conditions.fold<int>(
      0,
      (int value, PatchbayFriendlyCommand command) =>
          command.path.join(' ').length > value
          ? command.path.join(' ').length
          : value,
    );
    output
      ..writeln()
      ..writeln('Payload `condition` values (accepted as the command name too):');
    for (final PatchbayFriendlyCommand command in conditions) {
      output.writeln(
        '  ${command.path.join(' ').padRight(width)}  ${command.waitCondition}',
      );
    }
  }

  static String _command(ArgParser parser, PatchbayFriendlyCommand command) {
    final StringBuffer output = StringBuffer()
      ..writeln('Usage: patchbay ${_usage(command)} [options]')
      ..writeln()
      ..writeln(command.summary)
      ..writeln(protocolLine(command));
    if (command.waitCondition case final String condition) {
      output.writeln(
        'Sends condition: $condition — the value the response carries, and '
        'accepted in place of "${command.path.last}".',
      );
    }
    _writeOptions(
      output,
      parser,
      PatchbayFriendlyCommandRegistry.allowedOptions(command),
    );
    output
      ..writeln()
      ..writeln(availabilityLine(command));
    return output.toString();
  }

  /// Where the command's availability is actually decided.
  static String availabilityLine(PatchbayFriendlyCommand command) =>
      switch (command.target) {
        PatchbayCommandTarget.declaredServiceCommand ||
        PatchbayCommandTarget.callerServiceCommand =>
          'Availability is still decided by the running App catalog.',
        PatchbayCommandTarget.clientIdentity ||
        PatchbayCommandTarget.clientCatalog ||
        PatchbayCommandTarget.clientSnapshot =>
          'Available on any connected Patchbay transport.',
        PatchbayCommandTarget.clientWidgetTree ||
        PatchbayCommandTarget.clientRenderTree ||
        PatchbayCommandTarget.clientFocusTree =>
          'Only on the VM Service transport, and only while the Flutter SDK '
              'registers the extension.',
        PatchbayCommandTarget.clientReplSession =>
          'Available on any connected Patchbay transport except direct HTTP, '
              'whose token would have to share stdin with the commands.',
      };

  /// What the CLI will actually call, phrased per dispatch target.
  ///
  /// Client targets deliberately print no extension name: those names live in
  /// the transport and would go stale if help kept its own copy.
  static String protocolLine(PatchbayFriendlyCommand command) =>
      switch (command.target) {
        PatchbayCommandTarget.declaredServiceCommand =>
          'Service command: ${command.serviceCommand}',
        PatchbayCommandTarget.callerServiceCommand =>
          'Service command: the <service-command> argument',
        PatchbayCommandTarget.clientIdentity ||
        PatchbayCommandTarget.clientCatalog ||
        PatchbayCommandTarget.clientSnapshot =>
          'Served by the transport handshake, not by an App catalog command.',
        PatchbayCommandTarget.clientWidgetTree ||
        PatchbayCommandTarget.clientRenderTree ||
        PatchbayCommandTarget.clientFocusTree =>
          'Flutter SDK diagnostic passthrough, not an App catalog command.',
        PatchbayCommandTarget.clientReplSession =>
          'Reads command lines from stdin and runs each over one connection; '
              'every line reports its own exit code.',
      };

  static String _usage(PatchbayFriendlyCommand command) => <String>[
    ...command.path,
    if (command.usageSuffix.isNotEmpty) command.usageSuffix,
  ].join(' ');

  static void _writeOptions(
    StringBuffer output,
    ArgParser parser,
    Set<String> optionNames,
  ) {
    if (optionNames.isEmpty) return;
    final List<String> sorted = optionNames.toList()..sort();
    output
      ..writeln()
      ..writeln('Options:');
    for (final String name in sorted) {
      final Option? option = parser.options[name];
      if (option == null) {
        throw StateError('friendly option --$name is missing from the parser');
      }
      output.writeln(
        '  --${name.padRight(16)} ${option.help ?? ''}'.trimRight(),
      );
    }
  }

  static bool _startsWith(List<String> path, List<String> prefix) {
    if (path.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index += 1) {
      if (path[index] != prefix[index]) return false;
    }
    return true;
  }
}
