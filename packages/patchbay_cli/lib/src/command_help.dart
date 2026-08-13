import 'package:args/args.dart';

import 'command_registry.dart';

/// Renders CLI help from the parser and friendly-command declarations.
abstract final class PatchbayCommandHelp {
  static String render(ArgParser parser, List<String> topic) {
    if (topic.isEmpty) return _root(parser);
    final List<PatchbayFriendlyCommand> matches = PatchbayFriendlyCommand.values
        .where(
          (PatchbayFriendlyCommand command) => _startsWith(command.path, topic),
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      throw FormatException('unknown help topic: ${topic.join(' ')}');
    }
    if (matches.length == 1 && matches.single.path.length == topic.length) {
      return _command(parser, matches.single);
    }
    return _group(parser, topic, matches);
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
    _writeOptions(output, parser, optionNames);
    output
      ..writeln()
      ..writeln('Availability is still decided by the running App catalog.');
    return output.toString();
  }

  static String _command(ArgParser parser, PatchbayFriendlyCommand command) {
    final StringBuffer output = StringBuffer()
      ..writeln('Usage: patchbay ${_usage(command)} [options]')
      ..writeln()
      ..writeln(command.summary)
      ..writeln(protocolLine(command));
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
