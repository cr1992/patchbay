import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  try {
    _run(arguments);
  } on FormatException catch (error) {
    stderr.writeln('Invalid Patchbay command contract: ${error.message}');
    exitCode = 64;
  }
}

void _run(List<String> arguments) {
  final _Options options = _Options.parse(arguments);
  final File contractFile = File(options.contract);
  final Object? decoded = jsonDecode(contractFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('command contract root must be an object');
  }
  final _Contract contract = _Contract.parse(decoded);
  final String generated = _formatDart(_render(contract, contractFile.path));
  final File output = File(options.output);
  if (options.check) {
    if (!output.existsSync() || output.readAsStringSync() != generated) {
      stderr.writeln(
        'Patchbay command generated output drifted: ${output.path}',
      );
      stderr.writeln('Run the same command with --write.');
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Patchbay command generated output is current: ${output.path}',
    );
    return;
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(generated);
  stdout.writeln('Generated ${output.path} from ${contractFile.path}');
}

final class _Options {
  const _Options(this.contract, this.output, this.check);
  final String contract;
  final String output;
  final bool check;

  static _Options parse(List<String> args) {
    String? contract;
    String? output;
    var check = false;
    var write = false;
    for (var i = 0; i < args.length; i += 1) {
      switch (args[i]) {
        case '--contract':
          contract = args.elementAtOrNull(++i);
        case '--output':
          output = args.elementAtOrNull(++i);
        case '--check':
          check = true;
        case '--write':
          write = true;
        default:
          throw FormatException('unknown command_codegen argument: ${args[i]}');
      }
    }
    if (contract == null || output == null || check == write) {
      throw const FormatException(
        'usage: command_codegen --contract <json> --output <dart> (--check|--write)',
      );
    }
    return _Options(contract, output, check);
  }
}

final class _Contract {
  const _Contract(
    this.apiPrefix,
    this.descriptorImport,
    this.permissions,
    this.cancellations,
    this.profiles,
    this.commands,
  );
  final String apiPrefix;
  final String descriptorImport;
  final List<String> permissions;
  final List<String> cancellations;
  final Map<String, _Profile> profiles;
  final List<_Command> commands;

  static _Contract parse(Map<String, dynamic> json) {
    _keys(json, const {
      'contractVersion',
      'apiPrefix',
      'descriptorImport',
      'permissions',
      'cancellations',
      'profiles',
      'commands',
    }, r'$');
    if (json['contractVersion'] != 2) {
      throw const FormatException('unsupported command contractVersion');
    }
    final String apiPrefix = _typePrefix(json['apiPrefix'], 'apiPrefix');
    final String descriptorImport =
        _choice(json['descriptorImport'], 'descriptorImport', const {
          'package:patchbay/patchbay.dart',
          'package:patchbay_flutter/patchbay_flutter.dart',
        });
    final List<String> permissions = _vocabulary(
      json['permissions'],
      'permissions',
    );
    final List<String> cancellations = _vocabulary(
      json['cancellations'],
      'cancellations',
    );
    final Map<String, dynamic> rawProfiles = _object(
      json['profiles'],
      'profiles',
    );
    final Map<String, _Profile> profiles = rawProfiles.map(
      (name, value) => MapEntry(
        _identifier(name, 'profile name'),
        _Profile.parse(_object(value, 'profiles.$name'), 'profiles.$name'),
      ),
    );
    final List<dynamic> rawCommands = _list(json['commands'], 'commands');
    final List<_Command> commands = rawCommands.indexed
        .map(
          (entry) => _Command.parse(
            _object(entry.$2, 'commands[${entry.$1}]'),
            profiles,
            permissions,
            cancellations,
            'commands[${entry.$1}]',
          ),
        )
        .toList(growable: false);
    if (commands.isEmpty) {
      throw const FormatException('commands must not be empty');
    }
    _unique(commands.map((value) => value.id), 'command id');
    _unique(commands.map((value) => value.name), 'command name');
    final Map<String, String> parameterTypes = {};
    for (final command in commands) {
      for (final parameter in command.parameters) {
        final previous = parameterTypes[parameter.name];
        if (previous != null && previous != parameter.type) {
          throw FormatException(
            'parameter ${parameter.name} has conflicting types $previous/${parameter.type}',
          );
        }
        parameterTypes[parameter.name] = parameter.type;
      }
    }
    return _Contract(
      apiPrefix,
      descriptorImport,
      permissions,
      cancellations,
      profiles,
      commands,
    );
  }
}

final class _Profile {
  const _Profile(this.mode, this.sideEffect, this.factSources, this.gates);
  final String mode;
  final String sideEffect;
  final List<String> factSources;
  final List<String> gates;

  static _Profile parse(Map<String, dynamic> json, String path) {
    _keys(json, const {'mode', 'sideEffect', 'factSources', 'gates'}, path);
    final mode = _choice(json['mode'], '$path.mode', const {
      'readOnly',
      'immediate',
      'job',
    });
    final sideEffect = _choice(json['sideEffect'], '$path.sideEffect', const {
      'none',
      'appState',
      'external',
    });
    final facts = _factSources(json['factSources'], '$path.factSources');
    return _Profile(
      mode,
      sideEffect,
      facts,
      _strings(json['gates'], '$path.gates'),
    );
  }
}

final class _Command {
  const _Command({
    required this.id,
    required this.name,
    required this.summary,
    required this.profile,
    required this.factSources,
    required this.parameters,
    required this.permissions,
    required this.cancellation,
    required this.suggestedWaitTimeoutMs,
    required this.confirmationArgument,
  });
  final String id;
  final String name;
  final String summary;
  final _Profile profile;
  final List<String> factSources;
  final List<_Parameter> parameters;
  final List<String> permissions;
  final String? cancellation;
  final int? suggestedWaitTimeoutMs;
  final String? confirmationArgument;

  static _Command parse(
    Map<String, dynamic> json,
    Map<String, _Profile> profiles,
    List<String> permissionVocabulary,
    List<String> cancellationVocabulary,
    String path,
  ) {
    _keys(json, const {
      'id',
      'name',
      'summary',
      'profile',
      'factSources',
      'parameters',
      'permissions',
      'cancellation',
      'suggestedWaitTimeoutMs',
      'confirmationArgument',
    }, path);
    final id = _identifier(json['id'], '$path.id');
    final name = _commandName(json['name'], '$path.name');
    final summary = _nonEmpty(json['summary'], '$path.summary');
    final profileName = _identifier(json['profile'], '$path.profile');
    final profile = profiles[profileName];
    if (profile == null) {
      throw FormatException('$path.profile is unknown: $profileName');
    }
    final parameters = json['parameters'] == null
        ? <_Parameter>[]
        : _list(json['parameters'], '$path.parameters').indexed
              .map(
                (entry) => _Parameter.parse(
                  _object(entry.$2, '$path.parameters[${entry.$1}]'),
                  '$path.parameters[${entry.$1}]',
                ),
              )
              .toList();
    _unique(parameters.map((value) => value.name), '$path parameter');
    final permissions = json['permissions'] == null
        ? <String>[]
        : _strings(json['permissions'], '$path.permissions');
    for (final permission in permissions) {
      _choice(permission, '$path.permissions', permissionVocabulary.toSet());
    }
    final cancellation = json['cancellation'] as String?;
    if (cancellation != null) {
      _choice(
        cancellation,
        '$path.cancellation',
        cancellationVocabulary.toSet(),
      );
    }
    final wait = json['suggestedWaitTimeoutMs'];
    if (wait != null && (wait is! int || wait <= 0)) {
      throw FormatException(
        '$path.suggestedWaitTimeoutMs must be a positive integer',
      );
    }
    final confirmation = json['confirmationArgument'] as String?;
    if (confirmation != null) {
      final matches = parameters.where((value) => value.name == confirmation);
      if (matches.length != 1 || matches.single.type != 'boolean') {
        throw FormatException(
          '$path.confirmationArgument must name a boolean parameter',
        );
      }
    }
    return _Command(
      id: id,
      name: name,
      summary: summary,
      profile: profile,
      factSources: json['factSources'] == null
          ? profile.factSources
          : _factSources(json['factSources'], '$path.factSources'),
      parameters: parameters,
      permissions: permissions,
      cancellation: cancellation,
      suggestedWaitTimeoutMs: wait as int?,
      confirmationArgument: confirmation,
    );
  }
}

final class _Parameter {
  const _Parameter(
    this.name,
    this.type,
    this.required,
    this.sensitive,
    this.defaultValue,
    this.allowedValues,
  );
  final String name;
  final String type;
  final bool required;
  final bool sensitive;
  final Object? defaultValue;
  final List<Object?> allowedValues;

  static _Parameter parse(Map<String, dynamic> json, String path) {
    _keys(json, const {
      'name',
      'type',
      'required',
      'sensitive',
      'default',
      'allowedValues',
    }, path);
    final name = _identifier(json['name'], '$path.name');
    final type = _choice(json['type'], '$path.type', const {
      'string',
      'integer',
      'number',
      'boolean',
      'enumeration',
      'json',
    });
    final required = json['required'] == true;
    final sensitive = json['sensitive'] == true;
    final defaultValue = json['default'];
    if (required && defaultValue != null) {
      throw FormatException('$path cannot be required and defaulted');
    }
    final allowed = json['allowedValues'] == null
        ? <Object?>[]
        : _list(json['allowedValues'], '$path.allowedValues').cast<Object?>();
    if (type == 'enumeration' && allowed.isEmpty) {
      throw FormatException('$path enumeration requires allowedValues');
    }
    if (defaultValue != null && !_valueMatches(type, defaultValue)) {
      throw FormatException('$path default has the wrong type');
    }
    if (defaultValue != null &&
        allowed.isNotEmpty &&
        !allowed.contains(defaultValue)) {
      throw FormatException('$path default is not allowed');
    }
    return _Parameter(name, type, required, sensitive, defaultValue, allowed);
  }
}

String _render(_Contract contract, String path) {
  final commands = contract.commands;
  final typePrefix = contract.apiPrefix;
  final valuePrefix = _lowerInitial(typePrefix);
  final enumPrefix = '${typePrefix}CommandId';
  final permissionType = '${typePrefix}Permission';
  final cancellationType = '${typePrefix}Cancellation';
  final metadataType = '${typePrefix}CommandMetadata';
  final decodedType = '${typePrefix}DecodedCommand';
  final decodeResultType = '${typePrefix}DecodeResult';
  final metadataName = '${valuePrefix}CommandMetadata';
  final Map<String, _Parameter> getters = {};
  final Set<String> nullable = {};
  for (final command in commands) {
    for (final parameter in command.parameters) {
      getters[parameter.name] = parameter;
      if (!parameter.required && parameter.defaultValue == null) {
        nullable.add(parameter.name);
      }
    }
  }
  final out = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('// ignore_for_file: curly_braces_in_flow_control_structures')
    ..writeln('// Contract: $path')
    ..writeln('// Generator: packages/patchbay/tool/command_codegen.dart')
    ..writeln("import '${contract.descriptorImport}';")
    ..writeln()
    ..writeln('enum $enumPrefix {');
  for (final command in commands) {
    out.writeln('  ${command.id},');
  }
  out
    ..writeln('  ;')
    ..writeln('  String get wireName => switch (this) {');
  for (final command in commands) {
    out.writeln("    $enumPrefix.${command.id} => '${_escape(command.name)}',");
  }
  out
    ..writeln('  };')
    ..writeln('  static $enumPrefix? parse(String value) => switch (value) {');
  for (final command in commands) {
    out.writeln("    '${_escape(command.name)}' => $enumPrefix.${command.id},");
  }
  out
    ..writeln('    _ => null,')
    ..writeln('  };')
    ..writeln('}')
    ..writeln()
    ..writeln('enum $permissionType { ${contract.permissions.join(', ')} }')
    ..writeln('enum $cancellationType { ${contract.cancellations.join(', ')} }')
    ..writeln()
    ..writeln('final class $metadataType {')
    ..writeln(
      '  const $metadataType({required this.descriptor, this.permissions = const [], this.cancellation, this.suggestedWaitTimeoutMs, this.confirmationArgument});',
    )
    ..writeln('  final PatchbayCommandDescriptor descriptor;')
    ..writeln('  final List<$permissionType> permissions;')
    ..writeln('  final $cancellationType? cancellation;')
    ..writeln('  final int? suggestedWaitTimeoutMs;')
    ..writeln('  final String? confirmationArgument;')
    ..writeln('}')
    ..writeln()
    ..writeln('final class $decodedType {')
    ..writeln('  const $decodedType(this.command, this.values);')
    ..writeln('  final $enumPrefix command;')
    ..writeln('  final Map<String, Object?> values;');
  for (final entry in getters.entries) {
    final type = _dartType(entry.value.type);
    final isNullable = nullable.contains(entry.key);
    out.writeln(
      '  $type${isNullable ? '?' : ''} get ${entry.key} => values[\'${entry.key}\'] as $type${isNullable ? '?' : ''};',
    );
  }
  out.writeln('  T dispatch<T>({');
  for (final command in commands) {
    out.writeln('    required T Function($decodedType) ${command.id},');
  }
  out.writeln('  }) => switch (command) {');
  for (final command in commands) {
    out.writeln('    $enumPrefix.${command.id} => ${command.id}(this),');
  }
  out
    ..writeln('  };')
    ..writeln('}')
    ..writeln()
    ..writeln('final class $decodeResultType {')
    ..writeln(
      '  const $decodeResultType.accepted(this.command) : rejection = null;',
    )
    ..writeln(
      '  const $decodeResultType.rejected(this.rejection) : command = null;',
    )
    ..writeln('  final $decodedType? command;')
    ..writeln('  final PatchbayRejection? rejection;')
    ..writeln('}')
    ..writeln()
    ..writeln('final Map<$enumPrefix, $metadataType> $metadataName = {');
  for (final command in commands) {
    out
      ..writeln('  $enumPrefix.${command.id}: $metadataType(')
      ..writeln('    descriptor: PatchbayCommandDescriptor(')
      ..writeln("      name: '${_escape(command.name)}',")
      ..writeln("      summary: '${_escape(command.summary)}',")
      ..writeln('      plane: PatchbayPlane.domain,')
      ..writeln('      mode: PatchbayCommandMode.${command.profile.mode},')
      ..writeln(
        '      sideEffect: PatchbaySideEffect.${command.profile.sideEffect},',
      )
      ..writeln(
        '      factSources: {${command.factSources.map((value) => 'PatchbayFactSource.$value').join(', ')}},',
      )
      ..writeln(
        '      gates: {${command.profile.gates.map((value) => "'${_escape(value)}'").join(', ')}},',
      )
      ..writeln('      parameters: [');
    for (final p in command.parameters) {
      out
        ..writeln('        PatchbayParameterDescriptor(')
        ..writeln("          name: '${p.name}',")
        ..writeln('          type: PatchbayParameterType.${p.type},')
        ..writeln('          required: ${p.required},')
        ..writeln('          sensitive: ${p.sensitive},')
        ..writeln('          defaultValue: ${_literal(p.defaultValue)},')
        ..writeln('          allowedValues: ${_literal(p.allowedValues)},')
        ..writeln('        ),');
    }
    out
      ..writeln('      ],')
      ..writeln('    ),')
      ..writeln(
        '    permissions: [${command.permissions.map((value) => '$permissionType.$value').join(', ')}],',
      )
      ..writeln(
        '    cancellation: ${command.cancellation == null ? 'null' : '$cancellationType.${command.cancellation}'},',
      )
      ..writeln(
        '    suggestedWaitTimeoutMs: ${command.suggestedWaitTimeoutMs},',
      )
      ..writeln(
        '    confirmationArgument: ${_literal(command.confirmationArgument)},',
      )
      ..writeln('  ),');
  }
  out
    ..writeln('};')
    ..writeln()
    ..writeln(
      'List<PatchbayCommandDescriptor> get ${valuePrefix}CommandDescriptors => List.unmodifiable($metadataName.values.map((value) => value.descriptor));',
    )
    ..writeln()
    ..writeln(
      '$decodeResultType decode${typePrefix}Command(String name, Map<String, Object?> raw) {',
    )
    ..writeln('  final id = $enumPrefix.parse(name);')
    ..writeln(
      "  if (id == null) return const $decodeResultType.rejected(PatchbayRejection(code: 'commandNotRegistered')); ",
    )
    ..writeln('  final metadata = $metadataName[id]!;')
    ..writeln(
      '  final declared = {for (final parameter in metadata.descriptor.parameters) parameter.name: parameter};',
    )
    ..writeln(
      "  final unknown = raw.keys.where((key) => !declared.containsKey(key) && key != 'inputWasStdin').toList()..sort();",
    )
    ..writeln(
      "  if (unknown.isNotEmpty) return $decodeResultType.rejected(PatchbayRejection(code: 'invalidArguments', details: {'unknown': unknown}));",
    )
    ..writeln('  final values = <String, Object?>{};')
    ..writeln('  for (final parameter in metadata.descriptor.parameters) {')
    ..writeln(
      '    final value = raw.containsKey(parameter.name) ? raw[parameter.name] : parameter.defaultValue;',
    )
    ..writeln(
      "    if (parameter.required && value == null) return $decodeResultType.rejected(PatchbayRejection(code: 'invalidArguments', details: {'missing': parameter.name}));",
    )
    ..writeln(
      '    if (value == null) { values[parameter.name] = null; continue; }',
    )
    ..writeln('    final typeOk = switch (parameter.type) {')
    ..writeln(
      '      PatchbayParameterType.string || PatchbayParameterType.enumeration => value is String,',
    )
    ..writeln('      PatchbayParameterType.integer => value is int,')
    ..writeln('      PatchbayParameterType.number => value is num,')
    ..writeln('      PatchbayParameterType.boolean => value is bool,')
    ..writeln('      PatchbayParameterType.json => true,')
    ..writeln('    };')
    ..writeln(
      "    if (!typeOk || (parameter.allowedValues.isNotEmpty && !parameter.allowedValues.contains(value))) return $decodeResultType.rejected(PatchbayRejection(code: 'invalidArguments', details: {'parameter': parameter.name}));",
    )
    ..writeln(
      "    if (parameter.sensitive && raw['inputWasStdin'] != true) return const $decodeResultType.rejected(PatchbayRejection(code: 'sensitiveInputRequiresStdin'));",
    )
    ..writeln('    values[parameter.name] = value;')
    ..writeln('  }')
    ..writeln('  final confirmation = metadata.confirmationArgument;')
    ..writeln(
      "  if (confirmation != null && values[confirmation] != true) return const $decodeResultType.rejected(PatchbayRejection(code: 'explicitConfirmationRequired'));",
    )
    ..writeln(
      '  return $decodeResultType.accepted($decodedType(id, Map.unmodifiable(values)));',
    )
    ..writeln('}');
  return out.toString();
}

String _formatDart(String source) {
  final directory = Directory.systemTemp.createTempSync('patchbay-command-');
  try {
    final candidate = File('${directory.path}/generated.dart')
      ..writeAsStringSync(source);
    final result = Process.runSync(Platform.resolvedExecutable, [
      'format',
      candidate.path,
    ]);
    if (result.exitCode != 0) {
      throw FormatException('generated Dart did not format: ${result.stderr}');
    }
    return candidate.readAsStringSync();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Map<String, dynamic> _object(Object? value, String path) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$path must be an object');
  }
  return value;
}

List<dynamic> _list(Object? value, String path) {
  if (value is! List) throw FormatException('$path must be a list');
  return value;
}

List<String> _strings(Object? value, String path) =>
    _list(value, path).map((item) => _nonEmpty(item, path)).toList();

List<String> _factSources(Object? value, String path) {
  final facts = _strings(value, path);
  for (final fact in facts) {
    _choice(fact, path, const {
      'appRecorded',
      'commandEcho',
      'deviceReported',
      'uiObserved',
      'unknown',
    });
  }
  return facts;
}

String _commandName(Object? value, String path) {
  final name = _nonEmpty(value, path);
  if (!RegExp(r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$').hasMatch(name)) {
    throw FormatException(
      '$path must be a stable dotted command name with lowercase-starting segments',
    );
  }
  return name;
}

String _identifier(Object? value, String path) {
  final text = _nonEmpty(value, path);
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(text)) {
    throw FormatException('$path must be a Dart identifier');
  }
  return text;
}

String _typePrefix(Object? value, String path) {
  final text = _identifier(value, path);
  if (!RegExp(r'^[A-Z]').hasMatch(text)) {
    throw FormatException('$path must start with an uppercase letter');
  }
  return text;
}

List<String> _vocabulary(Object? value, String path) {
  final words = _strings(value, path);
  if (words.isEmpty) throw FormatException('$path must not be empty');
  for (final word in words) {
    _identifier(word, path);
  }
  _unique(words, path);
  return words;
}

String _lowerInitial(String value) =>
    '${value[0].toLowerCase()}${value.substring(1)}';

String _nonEmpty(Object? value, String path) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$path must be a non-empty string');
  }
  return value;
}

String _choice(Object? value, String path, Set<String> choices) {
  final text = _nonEmpty(value, path);
  if (!choices.contains(text)) {
    throw FormatException('$path must be one of $choices');
  }
  return text;
}

void _keys(Map<String, dynamic> value, Set<String> allowed, String path) {
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException('$path has unknown fields: $unknown');
  }
}

void _unique(Iterable<String> values, String label) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) {
      throw FormatException('duplicate $label: $value');
    }
  }
}

bool _valueMatches(String type, Object value) => switch (type) {
  'string' || 'enumeration' => value is String,
  'integer' => value is int,
  'number' => value is num,
  'boolean' => value is bool,
  'json' => true,
  _ => false,
};
String _dartType(String type) => switch (type) {
  'string' || 'enumeration' => 'String',
  'integer' => 'int',
  'number' => 'num',
  'boolean' => 'bool',
  'json' => 'Object',
  _ => throw StateError(type),
};
String _literal(Object? value) {
  if (value == null) return 'null';
  if (value is String) return "'${_escape(value)}'";
  if (value is num || value is bool) return '$value';
  if (value is List) return '[${value.map(_literal).join(', ')}]';
  throw StateError('unsupported literal $value');
}

String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$');
