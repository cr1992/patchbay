import 'dart:io';

import 'package:patchbay/patchbay.dart';

const String _outputPath = 'lib/src/generated/protocol_cli_commands.g.dart';

void main(List<String> arguments) {
  final bool check = arguments.length == 1 && arguments.single == '--check';
  final bool write = arguments.length == 1 && arguments.single == '--write';
  if (!check && !write) {
    stderr.writeln('usage: protocol_cli_codegen (--check|--write)');
    exitCode = 64;
    return;
  }
  final String generated = _formatDart(_render());
  final File output = File(_outputPath);
  if (check) {
    if (!output.existsSync() || output.readAsStringSync() != generated) {
      stderr.writeln(
        'Generated protocol CLI registration drifted: $_outputPath',
      );
      stderr.writeln('Run: dart run tool/protocol_cli_codegen.dart --write');
      exitCode = 1;
      return;
    }
    stdout.writeln('Generated protocol CLI registration is current.');
    return;
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(generated);
  stdout.writeln('Generated $_outputPath');
}

String _render() {
  final StringBuffer out = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('// Source: package:patchbay protocol command descriptors.')
    ..writeln()
    ..writeln("part of '../command_registry.dart';")
    ..writeln();
  final List<String> ids = <String>[];
  final Set<String> commandNames = <String>{};
  for (final PatchbayCommandDescriptor descriptor
      in patchbayProtocolCliCommandDescriptors) {
    if (!commandNames.add(descriptor.name)) {
      throw StateError(
        'duplicate protocol command descriptor: ${descriptor.name}',
      );
    }
    final Set<String> parameters = descriptor.parameters
        .map((PatchbayParameterDescriptor parameter) => parameter.name)
        .toSet();
    for (var index = 0; index < descriptor.cliSyntax.length; index += 1) {
      final PatchbayCliSyntax syntax = descriptor.cliSyntax[index];
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(syntax.id) ||
          syntax.path.isEmpty ||
          syntax.path.any((String word) => word.isEmpty) ||
          syntax.summary.isEmpty) {
        throw StateError('${descriptor.name} has invalid CLI syntax metadata');
      }
      final Set<String> referenced = <String>{
        ...syntax.positionalParameters,
        ...syntax.optionParameters.keys,
        ...syntax.fixedArguments.keys,
        ...syntax.positiveParameters,
      };
      final Set<String> unknown = referenced.difference(parameters);
      if (unknown.isNotEmpty) {
        throw StateError('${descriptor.name} CLI syntax references $unknown');
      }
      final Set<String> duplicateBindings = <String>{
        ...syntax.positionalParameters.where(
          syntax.optionParameters.containsKey,
        ),
        ...syntax.positionalParameters.where(syntax.fixedArguments.containsKey),
        ...syntax.optionParameters.keys.where(
          syntax.fixedArguments.containsKey,
        ),
      };
      if (duplicateBindings.isNotEmpty) {
        throw StateError(
          '${descriptor.name} CLI syntax binds $duplicateBindings twice',
        );
      }
      ids.add(syntax.id);
      out
        ..writeln(
          'const _GeneratedProtocolCommand _${syntax.id}ProtocolCommand =',
        )
        ..writeln('    _GeneratedProtocolCommand(')
        ..writeln(
          '      descriptor: ${_descriptorIdentifier(descriptor.name)},',
        )
        ..writeln("      serviceName: '${descriptor.name}',")
        ..writeln('      syntaxIndex: $index,')
        ..writeln('    );')
        ..writeln();
    }
  }
  if (ids.toSet().length != ids.length) {
    throw StateError('protocol CLI syntax ids must be unique');
  }
  out
    ..writeln('final List<PatchbayFriendlyCommandSpec>')
    ..writeln('    _patchbayFriendlyCommands = <PatchbayFriendlyCommandSpec>[')
    ..writeln('      for (final PatchbayFriendlyCommand command')
    ..writeln('          in PatchbayFriendlyCommand.values)')
    ..writeln('        if (!command.isCompatibilityStub) command,');
  for (final String id in ids) {
    out.writeln('      _${id}ProtocolCommand,');
  }
  out
    ..writeln('    ];')
    ..writeln();
  return out.toString();
}

String _descriptorIdentifier(String command) {
  final List<String> words = command.split('.');
  final String suffix = words
      .map((String word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join();
  return 'patchbay${suffix}CommandDescriptor';
}

String _formatDart(String source) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-protocol-cli-',
  );
  try {
    final File candidate = File('${directory.path}/generated.dart')
      ..writeAsStringSync(source);
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['format', candidate.path],
    );
    if (result.exitCode != 0) {
      throw StateError('generated Dart did not format: ${result.stderr}');
    }
    return candidate.readAsStringSync();
  } finally {
    directory.deleteSync(recursive: true);
  }
}
