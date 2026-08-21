import 'dart:convert';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'command_spec.dart';
import 'friendly_commands.dart';

abstract final class ArgumentDecoder {
  static Map<String, Object?> argumentsWithoutPositionals(
    PatchbayFriendlyCommandSpec spec,
    ArgResults options,
  ) => switch (spec) {
    PatchbayFriendlyCommand.logsQuery => logArguments(options),
    PatchbayFriendlyCommand.logsTail => <String, Object?>{
      if (options.option('cursor') case final String cursor) 'cursor': cursor,
      if (optionalPositiveInt(options, 'limit') case final int limit)
        'limit': limit,
      'timeoutMs': positiveInt(options, 'timeout-ms', fallback: 5000),
      if (csv(options, 'levels') case final List<String> levels)
        'levels': levels,
      if (csv(options, 'categories') case final List<String> categories)
        'categories': categories,
    },
    PatchbayFriendlyCommand.logsExport => <String, Object?>{
      ...logArguments(options),
      if (optionalPositiveInt(options, 'ttl-ms') case final int ttl)
        'ttlMs': ttl,
    },
    PatchbayFriendlyCommand.captureRoot => captureArguments(options),
    _ => throw StateError('unexpected no-positional command ${spec.name}'),
  };

  static Map<String, Object?> protocolArguments(
    PatchbayFriendlyCommandSpec spec,
    List<String> tail,
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    final PatchbayCommandDescriptor descriptor = spec.protocolDescriptor!;
    final PatchbayCliSyntax syntax = spec.protocolSyntax!;
    if (syntax.inputMode == PatchbayCliInputMode.mergedJsonObject) {
      if (tail.isNotEmpty) {
        throw FormatException(
          '${spec.path.join(' ')} takes no positional arguments',
        );
      }
      return domainArguments(options, readSensitiveInput);
    }
    final int fixedCount = syntax.positionalParameters.length;
    if (tail.length < fixedCount ||
        syntax.trailingParameter == null && tail.length != fixedCount) {
      throw FormatException(
        '${spec.path.join(' ')} requires $fixedCount positional argument(s)',
      );
    }
    final Map<String, PatchbayParameterDescriptor> parameters =
        <String, PatchbayParameterDescriptor>{
          for (final PatchbayParameterDescriptor parameter
              in descriptor.parameters)
            parameter.name: parameter,
        };
    final Map<String, Object?> arguments = <String, Object?>{
      ...syntax.fixedArguments,
    };
    for (var index = 0; index < fixedCount; index += 1) {
      final String name = syntax.positionalParameters[index];
      arguments[name] = protocolValue(
        parameters[name]!,
        tail[index],
        name,
        positive: syntax.positiveParameters.contains(name),
        nonNegative: syntax.nonNegativeParameters.contains(name),
      );
    }
    if (syntax.trailingParameter case final String trailingName) {
      final bool include = switch (syntax.trailingWhen) {
        final PatchbayCliEqualsCondition condition =>
          arguments[condition.parameter] == condition.value,
        null => true,
      };
      final List<String> trailing = tail.sublist(fixedCount);
      if (!include && trailing.isNotEmpty) {
        throw FormatException(
          '${spec.path.join(' ')} has unexpected trailing arguments',
        );
      }
      final bool fromStdin = options.flag('stdin');
      if (include) {
        arguments[trailingName] = fromStdin
            ? readSensitiveInput()
            : trailing.join(' ');
      }
      if (syntax.stdinMarkerParameter case final String marker) {
        arguments[marker] = fromStdin;
      }
    }
    for (final MapEntry<String, String> binding
        in syntax.optionParameters.entries) {
      final PatchbayParameterDescriptor parameter = parameters[binding.key]!;
      final String? raw = options.option(binding.value);
      if (raw != null) {
        arguments[binding.key] = protocolValue(
          parameter,
          raw,
          '--${binding.value}',
          positive: syntax.positiveParameters.contains(binding.key),
          nonNegative: syntax.nonNegativeParameters.contains(binding.key),
        );
      } else if (parameter.defaultValue != null &&
          !syntax.omitOptionDefaults.contains(binding.key)) {
        arguments[binding.key] = parameter.defaultValue;
      }
    }
    for (final PatchbayParameterDescriptor parameter in descriptor.parameters) {
      if (!parameter.required || arguments.containsKey(parameter.name)) {
        continue;
      }
      if (syntax.fencesNavigationRevision && parameter.name == 'revision') {
        continue;
      }
      throw StateError(
        '${descriptor.name} CLI syntax omits required ${parameter.name}',
      );
    }
    return arguments;
  }

  static Object protocolValue(
    PatchbayParameterDescriptor parameter,
    String raw,
    String label, {
    required bool positive,
    bool nonNegative = false,
  }) {
    switch (parameter.type) {
      case PatchbayParameterType.string || PatchbayParameterType.enumeration:
        return raw;
      case PatchbayParameterType.integer:
        final int? value = int.tryParse(raw);
        if (value == null ||
            positive && value <= 0 ||
            nonNegative && value < 0) {
          throw FormatException(
            '$label must be ${positive
                ? 'positive'
                : nonNegative
                ? 'a non-negative integer'
                : 'an integer'}',
          );
        }
        return value;
      case PatchbayParameterType.number:
        final num? value = num.tryParse(raw);
        if (value == null ||
            positive && value <= 0 ||
            nonNegative && value < 0) {
          throw FormatException(
            '$label must be ${positive ? 'a positive ' : 'a '}number',
          );
        }
        return value;
      case PatchbayParameterType.boolean:
        return switch (raw) {
          'true' => true,
          'false' => false,
          _ => throw FormatException('$label must be true or false'),
        };
      case PatchbayParameterType.json:
        return jsonDecode(raw);
    }
  }

  static Map<String, Object?> domainArguments(
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    final Map<String, Object?> fromArgs = jsonObject(
      options.option('args') ?? '{}',
      '--args',
    );
    if (!options.flag('stdin')) return fromArgs;
    return <String, Object?>{
      ...fromArgs,
      ...jsonObject(readSensitiveInput(), 'stdin'),
      'inputWasStdin': true,
    };
  }

  static Set<String> plaintextArgumentKeys(ArgResults options) {
    final String? encoded = options.option('args');
    if (encoded == null) return const <String>{};
    return jsonObject(encoded, '--args').keys.toSet();
  }

  static Map<String, Object?> jsonObject(String encoded, String source) {
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$source must contain a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }

  static Map<String, Object?> textArguments(
    List<String> tail,
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    if (tail.length < 2) {
      throw const FormatException(
        'command requires <target-id> <generation> [text]',
      );
    }
    final bool fromStdin = options.flag('stdin');
    return <String, Object?>{
      'id': tail[0],
      'generation': parseNonNegative(tail[1], 'generation'),
      'text': fromStdin ? readSensitiveInput() : tail.sublist(2).join(' '),
      'inputWasStdin': fromStdin,
    };
  }

  static Map<String, Object?> semanticsActionArguments(
    List<String> tail,
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    if (tail.length < 3) {
      throw const FormatException(
        'command requires <node-id> <generation> <action> [text]',
      );
    }
    final String action = tail[2];
    final bool fromStdin = options.flag('stdin');
    return <String, Object?>{
      'nodeId': parseNonNegative(tail[0], 'nodeId'),
      'generation': parseNonNegative(tail[1], 'generation'),
      'action': action,
      if (action == 'setText')
        'text': fromStdin ? readSensitiveInput() : tail.sublist(3).join(' '),
      'inputWasStdin': fromStdin,
    };
  }

  static Map<String, Object?> snapshotWaitArguments(
    List<String> tail,
    ArgResults options,
  ) {
    final String? until = options.option('until');
    if (until == null) {
      throw const FormatException(
        'snapshot wait requires --until <exists|absent|equals>',
      );
    }
    final bool comparing = until == 'equals';
    if (tail.length != (comparing ? 2 : 1)) {
      throw FormatException(
        comparing
            ? 'snapshot wait --until equals requires <dot.path> <json-value>'
            : 'snapshot wait --until $until requires only <dot.path>',
      );
    }
    return <String, Object?>{
      'path': tail.first,
      'until': until,
      if (comparing) 'value': jsonLiteral(tail[1]),
      'timeoutMs': positiveInt(options, 'timeout-ms', fallback: 5000),
    };
  }

  static List<String> launchCommand(List<String> tail) {
    if (tail.isEmpty) {
      throw const FormatException('launch requires -- <consumer command>');
    }
    return List<String>.unmodifiable(tail);
  }

  static Object? jsonLiteral(String encoded) {
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw FormatException(
        'the compared value must be a JSON literal (true, 42, "text", '
        '[…], {…}); for the string $encoded write \'"$encoded"\'',
      );
    }
    if (decoded == null) {
      throw const FormatException(
        'the compared value must not be null: use --until absent instead',
      );
    }
    return decoded;
  }

  static Map<String, Object?> sessionUseArguments(
    List<String> tail,
    ArgResults options,
  ) {
    if (options.flag('clear')) {
      if (tail.isNotEmpty) {
        throw const FormatException(
          'session use --clear takes no <session-id>',
        );
      }
      return const <String, Object?>{'clear': true};
    }
    if (tail.length != 1) {
      throw const FormatException(
        'session use requires <session-id>, or --clear to unpin',
      );
    }
    return <String, Object?>{'sessionId': tail.single, 'clear': false};
  }

  static Map<String, Object?> logArguments(
    ArgResults options,
  ) => <String, Object?>{
    if (options.option('cursor') case final String cursor) 'cursor': cursor,
    if (options.option('direction') case final String direction)
      'direction': direction,
    if (optionalPositiveInt(options, 'limit') case final int limit)
      'limit': limit,
    if (csv(options, 'levels') case final List<String> levels) 'levels': levels,
    if (csv(options, 'categories') case final List<String> categories)
      'categories': categories,
    if (options.option('since') case final String since) 'since': since,
    if (options.option('until') case final String until) 'until': until,
  };

  static Map<String, Object?> captureArguments(ArgResults options) =>
      <String, Object?>{
        if (optionalNumber(options, 'pixel-ratio') case final num ratio)
          'pixelRatio': ratio,
        'timeoutMs': positiveInt(options, 'timeout-ms', fallback: 5000),
        if (optionalPositiveInt(options, 'after-frames') case final int frames)
          'afterFrames': frames,
      };

  static Map<String, Object?> waitArguments(
    ArgResults options, {
    required String condition,
    String? semanticsIdentifier,
    String? value,
    String? destinationId,
    int? revision,
  }) => <String, Object?>{
    'condition': condition,
    'timeoutMs': positiveInt(options, 'timeout-ms', fallback: 5000),
    'semanticsIdentifier': ?semanticsIdentifier,
    'value': ?value,
    'destinationId': ?destinationId,
    'revision': ?revision,
  };

  static Map<String, Object?> noTail(
    List<String> tail,
    Map<String, Object?> arguments,
  ) {
    if (tail.isNotEmpty) throw const FormatException('unexpected argument');
    return arguments;
  }

  static Map<String, Object?> oneTail(
    List<String> tail,
    Map<String, Object?> Function(String) build,
  ) {
    if (tail.length != 1) {
      throw const FormatException('command requires one positional argument');
    }
    return build(tail.single);
  }

  static Map<String, Object?> twoTail(
    List<String> tail,
    Map<String, Object?> Function(String, String) build,
  ) {
    if (tail.length != 2) {
      throw const FormatException('command requires two positional arguments');
    }
    return build(tail[0], tail[1]);
  }

  static Map<String, Object?> zeroOrOneTail(
    List<String> tail,
    Map<String, Object?> Function(String?) build,
  ) {
    if (tail.length > 1) {
      throw const FormatException('command accepts at most one argument');
    }
    return build(tail.isEmpty ? null : tail.single);
  }

  static Map<String, Object?> atLeastOneTail(
    List<String> tail,
    Map<String, Object?> Function(List<String>) build,
  ) {
    if (tail.isEmpty) {
      throw const FormatException('command requires an argument');
    }
    return build(tail);
  }

  static int? optionalInt(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    return parseNonNegative(value, name);
  }

  static int positiveInt(
    ArgResults options,
    String name, {
    required int fallback,
  }) {
    final int value = optionalInt(options, name) ?? fallback;
    if (value <= 0) throw FormatException('--$name must be positive');
    return value;
  }

  static int? optionalPositiveInt(ArgResults options, String name) {
    final int? value = optionalInt(options, name);
    if (value != null && value <= 0) {
      throw FormatException('--$name must be positive');
    }
    return value;
  }

  static int parseNonNegative(String value, String name) {
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw FormatException('$name must be a non-negative integer');
    }
    return parsed;
  }

  static num? optionalNumber(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    final num? parsed = num.tryParse(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('--$name must be a positive number');
    }
    return parsed;
  }

  static List<String>? csv(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    final List<String> result = value
        .split(',')
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
    if (result.isEmpty) throw FormatException('--$name must not be empty');
    return result;
  }

  static String requiredOption(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null || value.isEmpty) {
      throw FormatException('--$name is required for this command');
    }
    return value;
  }
}
