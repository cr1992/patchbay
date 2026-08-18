import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  try {
    _run(arguments);
  } on FormatException catch (error) {
    stderr.writeln('Invalid Patchbay wire contract: ${error.message}');
    exitCode = 64;
  }
}

void _run(List<String> arguments) {
  final _Options options = _Options.parse(arguments);
  final File contractFile = File(options.contract);
  final Object? decoded = jsonDecode(contractFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('wire contract root must be a JSON object');
  }
  final _Contract contract = _Contract.parse(decoded);
  final String generated = _formatDart(_render(contract, contractFile.path));
  final File output = File(options.output);
  final Directory? packageRoot = contract.library == 'patchbay_core_wire'
      ? contractFile.absolute.parent.parent
      : null;
  final File? surfaceGolden = packageRoot == null
      ? null
      : File('${packageRoot.path}/test/golden/wire_surface.json');
  final String? surface = packageRoot == null
      ? null
      : _renderSurfaceGolden(contract, packageRoot);

  if (options.check) {
    final List<String> drifted = <String>[
      if (!output.existsSync() || output.readAsStringSync() != generated)
        output.path,
      if (surfaceGolden != null &&
          (!surfaceGolden.existsSync() ||
              surfaceGolden.readAsStringSync() != surface))
        surfaceGolden.path,
    ];
    if (drifted.isNotEmpty) {
      for (final String path in drifted) {
        stderr.writeln('Patchbay wire generated output drifted: $path');
      }
      stderr.writeln('Run the same command with --write.');
      exitCode = 1;
      return;
    }
    stdout.writeln(
      surfaceGolden == null
          ? 'Patchbay wire generated output is current: ${output.path}'
          : 'Patchbay wire generated outputs are current: '
                '${output.path}, ${surfaceGolden.path}',
    );
    return;
  }

  output.parent.createSync(recursive: true);
  output.writeAsStringSync(generated);
  if (surfaceGolden != null) {
    surfaceGolden.parent.createSync(recursive: true);
    surfaceGolden.writeAsStringSync(surface!);
  }
  stdout.writeln(
    surfaceGolden == null
        ? 'Generated ${output.path} from ${contractFile.path}'
        : 'Generated ${output.path} and ${surfaceGolden.path} '
              'from ${contractFile.path}',
  );
}

String _renderSurfaceGolden(_Contract contract, Directory packageRoot) {
  final File serviceHost = File(
    '${packageRoot.path}/lib/src/service_host.dart',
  );
  final Iterable<RegExpMatch> schemaMatches = RegExp(
    r'static const int schemaVersion\s*=\s*(\d+)\s*;',
  ).allMatches(serviceHost.readAsStringSync());
  if (schemaMatches.length != 1) {
    throw const FormatException(
      'PatchbayServiceHost.schemaVersion must have one integer declaration',
    );
  }
  final int schemaVersion = int.parse(schemaMatches.single.group(1)!);
  final Set<String> declared = contract.types
      .map((_TypeDefinition type) => type.name)
      .toSet();
  final RegExp strictDecode = RegExp(r'\b(Patchbay[A-Za-z0-9]*Wire)\.fromJson');
  final Set<String> decoded = <String>{};
  for (final String package in <String>['patchbay_cli', 'patchbay_transport']) {
    final Directory lib = Directory('${packageRoot.parent.path}/$package/lib');
    for (final File file
        in lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.dart'))) {
      for (final RegExpMatch match in strictDecode.allMatches(
        file.readAsStringSync(),
      )) {
        final String name = match.group(1)!;
        if (declared.contains(name)) decoded.add(name);
      }
    }
  }
  if (decoded.isEmpty) {
    throw const FormatException(
      'no strict wire decoders found in shipped client sources',
    );
  }

  final Map<String, Object?> types = <String, Object?>{};
  for (final _TypeDefinition type in contract.types) {
    types[type.name] = switch (type.kind) {
      _TypeKind.enumeration => <String, Object?>{
        'kind': 'enum',
        'values': type.values,
      },
      _TypeKind.object => <String, Object?>{
        'kind': 'object',
        'fields': <String>[
          for (final _Field field in type.fields) field.wireName,
        ],
      },
    };
  }
  final String rendered = const JsonEncoder.withIndent('  ')
      .convert(<String, Object?>{
        'schemaVersion': schemaVersion,
        'strictlyDecodedByShippedClients': decoded.toList()..sort(),
        'types': types,
      });
  return '$rendered\n';
}

String _formatDart(String source) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-wire-',
  );
  try {
    final File candidate = File('${directory.path}/generated.dart')
      ..writeAsStringSync(source);
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['format', candidate.path],
    );
    if (result.exitCode != 0) {
      throw FormatException('generated Dart did not format: ${result.stderr}');
    }
    return candidate.readAsStringSync();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

final class _Options {
  const _Options({
    required this.contract,
    required this.output,
    required this.check,
  });

  final String contract;
  final String output;
  final bool check;

  static _Options parse(List<String> arguments) {
    String? contract;
    String? output;
    var check = false;
    var write = false;
    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--contract':
          contract = arguments.elementAtOrNull(++index);
          break;
        case '--output':
          output = arguments.elementAtOrNull(++index);
          break;
        case '--check':
          check = true;
          break;
        case '--write':
          write = true;
          break;
        default:
          throw FormatException(
            'unknown wire_codegen argument: ${arguments[index]}',
          );
      }
    }
    if (contract == null || output == null || check == write) {
      throw const FormatException(
        'usage: wire_codegen --contract <json> --output <dart> (--check|--write)',
      );
    }
    return _Options(contract: contract, output: output, check: check);
  }
}

final class _Contract {
  const _Contract({required this.library, required this.types});

  final String library;
  final List<_TypeDefinition> types;

  static _Contract parse(Map<String, dynamic> json) {
    _contractKeys(json, const <String>{
      'contractVersion',
      'library',
      'types',
    }, r'$');
    if (json['contractVersion'] != 1) {
      throw const FormatException('unsupported Patchbay wire contractVersion');
    }
    final String library = _identifier(json['library'], 'library');
    final Object? rawTypes = json['types'];
    if (rawTypes is! List || rawTypes.isEmpty) {
      throw const FormatException('types must be a non-empty list');
    }
    final List<_TypeDefinition> types = rawTypes
        .map((Object? value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('every type must be an object');
          }
          return _TypeDefinition.parse(value);
        })
        .toList(growable: false);
    final Set<String> names = <String>{};
    for (final _TypeDefinition type in types) {
      if (!names.add(type.name)) {
        throw FormatException('duplicate wire type ${type.name}');
      }
    }
    const Set<String> scalars = <String>{
      'String',
      'bool',
      'int',
      'num',
      'Json',
      'JsonObject',
    };
    for (final _TypeDefinition type in types) {
      for (final _Field field in type.fields) {
        if (!scalars.contains(field.type) && !names.contains(field.type)) {
          throw FormatException(
            '${type.name}.${field.name} references unknown type ${field.type}',
          );
        }
      }
    }
    return _Contract(library: library, types: types);
  }
}

enum _TypeKind { enumeration, object }

final class _TypeDefinition {
  const _TypeDefinition.enumeration({required this.name, required this.values})
    : kind = _TypeKind.enumeration,
      fields = const <_Field>[];

  const _TypeDefinition.object({required this.name, required this.fields})
    : kind = _TypeKind.object,
      values = const <String>[];

  final _TypeKind kind;
  final String name;
  final List<String> values;
  final List<_Field> fields;

  static _TypeDefinition parse(Map<String, dynamic> json) {
    final String name = _identifier(json['name'], 'type.name');
    switch (json['kind']) {
      case 'enum':
        _contractKeys(json, const <String>{'kind', 'name', 'values'}, name);
        final Object? rawValues = json['values'];
        if (rawValues is! List || rawValues.isEmpty) {
          throw FormatException('$name.values must be a non-empty list');
        }
        final List<String> values = rawValues
            .map((Object? value) => _identifier(value, '$name.values'))
            .toList(growable: false);
        if (values.toSet().length != values.length) {
          throw FormatException('$name has duplicate enum values');
        }
        return _TypeDefinition.enumeration(name: name, values: values);
      case 'object':
        _contractKeys(json, const <String>{'kind', 'name', 'fields'}, name);
        final Object? rawFields = json['fields'];
        if (rawFields is! List || rawFields.isEmpty) {
          throw FormatException('$name.fields must be a non-empty list');
        }
        final List<_Field> fields = rawFields
            .map((Object? value) {
              if (value is! Map<String, dynamic>) {
                throw FormatException('$name fields must be objects');
              }
              return _Field.parse(value, owner: name);
            })
            .toList(growable: false);
        if (fields.map((field) => field.name).toSet().length != fields.length) {
          throw FormatException('$name has duplicate fields');
        }
        if (fields.map((field) => field.wireName).toSet().length !=
            fields.length) {
          throw FormatException('$name has duplicate wire field names');
        }
        return _TypeDefinition.object(name: name, fields: fields);
      default:
        throw FormatException('$name.kind must be enum or object');
    }
  }
}

final class _Field {
  const _Field({
    required this.name,
    required this.wireName,
    required this.type,
    required this.nullable,
    required this.list,
    required this.omitIfEmpty,
    required this.emitNull,
  });

  final String name;
  final String wireName;
  final String type;
  final bool nullable;
  final bool list;
  final bool omitIfEmpty;
  final bool emitNull;

  static _Field parse(Map<String, dynamic> json, {required String owner}) {
    _contractKeys(json, const <String>{
      'name',
      'wireName',
      'type',
      'nullable',
      'list',
      'omitIfEmpty',
      'emitNull',
    }, '$owner.field');
    final String name = _identifier(json['name'], '$owner.field.name');
    final Object? rawWireName = json['wireName'];
    final String wireName = rawWireName == null
        ? name
        : _wireFieldName(rawWireName, '$owner.$name.wireName');
    final String type = _identifier(json['type'], '$owner.field.type');
    final bool nullable = json['nullable'] == true;
    final bool list = json['list'] == true;
    final bool omitIfEmpty = json['omitIfEmpty'] == true;
    final bool emitNull = json['emitNull'] == true;
    if (omitIfEmpty && !list && type != 'JsonObject') {
      throw FormatException(
        '$owner.$name omitIfEmpty requires a list or JsonObject',
      );
    }
    if (omitIfEmpty && nullable) {
      throw FormatException('$owner.$name cannot be nullable and omitIfEmpty');
    }
    if (emitNull && !nullable) {
      throw FormatException('$owner.$name emitNull requires nullable');
    }
    return _Field(
      name: name,
      wireName: wireName,
      type: type,
      nullable: nullable,
      list: list,
      omitIfEmpty: omitIfEmpty,
      emitNull: emitNull,
    );
  }
}

String _identifier(Object? value, String path) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value)) {
    throw FormatException('$path must be a Dart identifier');
  }
  return value;
}

String _wireFieldName(Object? value, String path) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$path must be a non-empty string');
  }
  return value;
}

void _contractKeys(
  Map<String, dynamic> json,
  Set<String> allowed,
  String path,
) {
  final List<String> unknown =
      json.keys.where((key) => !allowed.contains(key)).toList(growable: false)
        ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException('$path has unknown contract fields: $unknown');
  }
}

String _render(_Contract contract, String contractPath) {
  final Map<String, _TypeDefinition> types = <String, _TypeDefinition>{
    for (final _TypeDefinition type in contract.types) type.name: type,
  };
  final StringBuffer out = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln(
      '// ignore_for_file: curly_braces_in_flow_control_structures, prefer_null_aware_operators, unused_element, use_null_aware_elements',
    )
    ..writeln('// Contract: $contractPath')
    ..writeln('// Generator: packages/patchbay/tool/wire_codegen.dart')
    ..writeln('// Library: ${contract.library}')
    ..writeln();
  for (final _TypeDefinition type in contract.types) {
    switch (type.kind) {
      case _TypeKind.enumeration:
        _renderEnum(out, type);
      case _TypeKind.object:
        _renderObject(out, type, types);
    }
    out.writeln();
  }
  out
    ..writeln('Map<String, Object?> _wireMap(Object? value, String path) {')
    ..writeln(
      '  if (value is! Map) throw FormatException(\'\$path must be an object\');',
    )
    ..writeln('  try {')
    ..writeln('    return Map<String, Object?>.from(value);')
    ..writeln('  } on Object {')
    ..writeln('    throw FormatException(\'\$path must have string keys\');')
    ..writeln('  }')
    ..writeln('}')
    ..writeln()
    ..writeln('List<Object?> _wireList(Object? value, String path) {')
    ..writeln(
      '  if (value is! List) throw FormatException(\'\$path must be a list\');',
    )
    ..writeln('  return List<Object?>.from(value);')
    ..writeln('}')
    ..writeln()
    ..writeln('String _wireString(Object? value, String path) {')
    ..writeln(
      '  if (value is! String) throw FormatException(\'\$path must be a string\');',
    )
    ..writeln('  return value;')
    ..writeln('}')
    ..writeln()
    ..writeln('bool _wireBool(Object? value, String path) {')
    ..writeln(
      '  if (value is! bool) throw FormatException(\'\$path must be a bool\');',
    )
    ..writeln('  return value;')
    ..writeln('}')
    ..writeln()
    ..writeln('int _wireInt(Object? value, String path) {')
    ..writeln(
      '  if (value is! int) throw FormatException(\'\$path must be an int\');',
    )
    ..writeln('  return value;')
    ..writeln('}')
    ..writeln()
    ..writeln('num _wireNum(Object? value, String path) {')
    ..writeln(
      '  if (value is! num) throw FormatException(\'\$path must be a number\');',
    )
    ..writeln(
      '  if (!value.isFinite) throw FormatException(\'\$path must be finite\');',
    )
    ..writeln('  return value;')
    ..writeln('}')
    ..writeln()
    ..writeln('Object? _wireJson(Object? value, String path) {')
    ..writeln(
      '  if (value == null || value is String || value is bool) return value;',
    )
    ..writeln('  if (value is num) return _wireNum(value, path);')
    ..writeln('  if (value is List) {')
    ..writeln('    return <Object?>[')
    ..writeln('      for (var index = 0; index < value.length; index += 1)')
    ..writeln("        _wireJson(value[index], '\$path[\$index]'),")
    ..writeln('    ];')
    ..writeln('  }')
    ..writeln('  if (value is Map) return _wireJsonObject(value, path);')
    ..writeln("  throw FormatException('\$path must be a JSON value');")
    ..writeln('}')
    ..writeln()
    ..writeln(
      'Map<String, Object?> _wireJsonObject(Object? value, String path) {',
    )
    ..writeln('  final map = _wireMap(value, path);')
    ..writeln('  return <String, Object?>{')
    ..writeln('    for (final entry in map.entries)')
    ..writeln(
      "      entry.key: _wireJson(entry.value, '\$path.\${entry.key}'),",
    )
    ..writeln('  };')
    ..writeln('}')
    ..writeln()
    ..writeln(
      'void _wireKeys(Map<String, Object?> json, Set<String> allowed, String path) {',
    )
    ..writeln(
      '  final unknown = json.keys.where((key) => !allowed.contains(key)).toList()..sort();',
    )
    ..writeln('  if (unknown.isNotEmpty) {')
    ..writeln(
      "    throw FormatException('\$path has unknown fields: \${unknown.join(',')}');",
    )
    ..writeln('  }')
    ..writeln('}');
  return out.toString();
}

void _renderEnum(StringBuffer out, _TypeDefinition type) {
  out
    ..writeln('enum ${type.name} {')
    ..writeln('  ${type.values.join(',\n  ')};')
    ..writeln()
    ..writeln(
      '  static ${type.name} fromJson(Object? value, {String path = r\'\$\'}) {',
    )
    ..writeln('    final wire = _wireString(value, path);')
    ..writeln('    for (final candidate in values) {')
    ..writeln('      if (candidate.name == wire) return candidate;')
    ..writeln('    }')
    ..writeln(
      "    throw FormatException('\$path has unknown ${type.name}: \$wire');",
    )
    ..writeln('  }')
    ..writeln()
    ..writeln('  String toJson() => name;')
    ..writeln('}');
}

void _renderObject(
  StringBuffer out,
  _TypeDefinition type,
  Map<String, _TypeDefinition> types,
) {
  out
    ..writeln('final class ${type.name} {')
    ..writeln('  const ${type.name}({');
  for (final _Field field in type.fields) {
    out.writeln('    required this.${field.name},');
  }
  out
    ..writeln('  });')
    ..writeln();
  for (final _Field field in type.fields) {
    out.writeln('  final ${_dartType(field)} ${field.name};');
  }
  out
    ..writeln()
    ..writeln(
      '  factory ${type.name}.fromJson(Map<String, Object?> json, {String path = r\'\$\'}) {',
    )
    ..writeln('    _wireKeys(json, const <String>{')
    ..writeln(
      type.fields.map((field) => "      '${field.wireName}',").join('\n'),
    )
    ..writeln('    }, path);')
    ..writeln('    return ${type.name}(');
  for (final _Field field in type.fields) {
    final String fieldPath = "'\$path.${field.wireName}'";
    final String value = "json['${field.wireName}']";
    final String expression = _fromJsonExpression(
      field,
      value,
      fieldPath,
      types,
    );
    out.writeln(
      '      ${field.name}: ${field.omitIfEmpty ? "$value == null ? ${_emptyValue(field)} : $expression" : expression},',
    );
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  Map<String, Object?> toJson() => <String, Object?>{');
  for (final _Field field in type.fields) {
    final String fieldPath = "r'\$.${field.wireName}'";
    if (field.emitNull) {
      out.writeln(
        "    '${field.wireName}': ${field.name} == null ? null : ${_toJsonExpression(field, '${field.name}!', fieldPath)},",
      );
    } else if (field.nullable) {
      out.writeln(
        "    if (${field.name} != null) '${field.wireName}': ${_toJsonExpression(field, '${field.name}!', fieldPath)},",
      );
    } else if (field.omitIfEmpty) {
      out.writeln(
        "    if (${field.name}.isNotEmpty) '${field.wireName}': ${_toJsonExpression(field, field.name, fieldPath)},",
      );
    } else {
      out.writeln(
        "    '${field.wireName}': ${_toJsonExpression(field, field.name, fieldPath)},",
      );
    }
  }
  out
    ..writeln('  };')
    ..writeln('}');
}

String _dartType(_Field field) {
  final String element = switch (field.type) {
    'Json' => 'Object?',
    'JsonObject' => 'Map<String, Object?>',
    _ => field.type,
  };
  final String base = field.list ? 'List<$element>' : element;
  return field.nullable && !base.endsWith('?') ? '$base?' : base;
}

String _emptyValue(_Field field) => field.list
    ? 'const <${_dartType(field).substring(5, _dartType(field).length - 1)}>[]'
    : 'const <String, Object?>{}';

String _fromJsonExpression(
  _Field field,
  String value,
  String path,
  Map<String, _TypeDefinition> types,
) {
  String parseOne(String item, String itemPath) {
    switch (field.type) {
      case 'String':
        return '_wireString($item, $itemPath)';
      case 'bool':
        return '_wireBool($item, $itemPath)';
      case 'int':
        return '_wireInt($item, $itemPath)';
      case 'num':
        return '_wireNum($item, $itemPath)';
      case 'Json':
        return '_wireJson($item, $itemPath)';
      case 'JsonObject':
        return '_wireJsonObject($item, $itemPath)';
      default:
        final _TypeDefinition target = types[field.type]!;
        return target.kind == _TypeKind.enumeration
            ? '${field.type}.fromJson($item, path: $itemPath)'
            : '${field.type}.fromJson(_wireMap($item, $itemPath), path: $itemPath)';
    }
  }

  String expression;
  if (field.list) {
    final String itemPath = '${path.substring(0, path.length - 1)}[]\'';
    expression =
        '_wireList($value, $path)'
        '.map((item) => ${parseOne('item', itemPath)})'
        '.toList(growable: false)';
  } else {
    expression = parseOne(value, path);
  }
  return field.nullable ? '$value == null ? null : $expression' : expression;
}

String _toJsonExpression(_Field field, String value, String path) {
  String encodeOne(String item, String itemPath) {
    return switch (field.type) {
      'String' || 'bool' || 'int' || 'num' => item,
      'Json' => '_wireJson($item, $itemPath)',
      'JsonObject' => '_wireJsonObject($item, $itemPath)',
      _ => '$item.toJson()',
    };
  }

  if (field.list) {
    final String itemPath = '${path.substring(0, path.length - 1)}[]\'';
    return '$value.map((item) => ${encodeOne('item', itemPath)}).toList(growable: false)';
  }
  return encodeOne(value, path);
}

extension<T> on List<T> {
  T? elementAtOrNull(int index) =>
      index >= 0 && index < length ? this[index] : null;
}
