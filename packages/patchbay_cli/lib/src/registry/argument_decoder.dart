import 'dart:convert';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';

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
    String Function() readSensitiveInput, {
    Map<String, String> boundOptionValues = const <String, String>{},
  }) {
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
      final String? raw =
          boundOptionValues[binding.key] ?? options.option(binding.value);
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

  /// Decodes `session register`, which writes a record instead of reading one.
  ///
  /// Every field it collects already exists on `PatchbaySessionRecord`
  /// (PB-050-27 adds no record field): the transport the caller already
  /// obtained, the identity a later handshake is reconciled against, the device
  /// and build mode a listing prints, and the local PID whose liveness decides
  /// when the record goes stale. `sessionId` is optional so a cleanup trap can
  /// be installed before the App is even started; omitted, the CLI names the
  /// record and reports the name it chose.
  static Map<String, Object?> sessionRegisterArguments(
    List<String> tail,
    ArgResults options,
  ) {
    if (tail.length > 1) {
      throw const FormatException(
        'session register accepts at most one <session-id>',
      );
    }
    // Read in the order the usage line prints them, so a half-written command
    // is told about its first missing option rather than its last.
    final String wsUri = transportUri(requiredOption(options, 'ws-uri'));
    final String applicationId = requiredOption(options, 'application-id');
    final String deviceId = requiredOption(options, 'device-id');
    final int? processId = int.tryParse(requiredOption(options, 'process-id'));
    if (processId == null || processId <= 0) {
      throw const FormatException('--process-id must be a positive integer');
    }
    final String buildMode = options.option('build-mode') ?? 'debug';
    if (buildMode.isEmpty) {
      throw const FormatException('--build-mode must not be empty');
    }
    final String? sessionId = tail.isEmpty ? null : tail.single;
    return <String, Object?>{
      'sessionId': ?sessionId,
      'wsUri': wsUri,
      'applicationId': applicationId,
      'deviceId': deviceId,
      'processId': processId,
      'buildMode': buildMode,
    };
  }

  /// Validates a transport URI the CLI records rather than dials.
  ///
  /// Checked here, at decode time, for the same reason the launcher refuses an
  /// empty `wsUri`: a record carrying an unusable endpoint is discovered
  /// normally and then fails on every later command, far away from the mistake.
  static String transportUri(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.host.isEmpty ||
        !const <String>{'http', 'https', 'ws', 'wss'}.contains(uri.scheme)) {
      throw const FormatException(
        '--ws-uri must be an absolute http(s) or ws(s) URI',
      );
    }
    return raw;
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

  /// Reads `--$name` as a non-negative integer, or `null` when the option
  /// was not passed.
  ///
  /// Every caller reaches this through an `options.option(name)` lookup, so
  /// [name] is always a `--`-flag spelling here — unlike [parseNonNegative],
  /// which a few call sites also use directly on a *positional* argument
  /// name (`nodeId`, `generation`) where a `--` prefix would be wrong. This
  /// method therefore builds its own message with the prefix rather than
  /// delegating to [parseNonNegative], so it stays aligned with the sibling
  /// `--$name must be positive` messages [positiveInt] and
  /// [optionalPositiveInt] already produce for the same option.
  static int? optionalInt(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw FormatException('--$name must be a non-negative integer');
    }
    return parsed;
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
