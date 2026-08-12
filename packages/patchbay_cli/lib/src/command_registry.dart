import 'package:args/args.dart';

enum PatchbayArtifactDisposition { none, payloadBlob, responseBlob }

/// Mechanical mapping between CLI-friendly paths and stable protocol names.
///
/// Runtime availability still comes from the service catalog and the invoke
/// response remains authoritative. This table is syntax, not a capability
/// inventory.
enum PatchbayFriendlyCommand {
  navigationCatalog('navigation.catalog', <String>['navigation', 'catalog']),
  navigationCurrent('navigation.current', <String>['navigation', 'current']),
  navigationGo('navigation.go', <String>['navigation', 'go']),
  navigationPush('navigation.push', <String>['navigation', 'push']),
  navigationBack('navigation.back', <String>['navigation', 'back']),
  uiWaitSemanticsMounted('ui.wait', <String>[
    'ui',
    'wait',
    'semantics-mounted',
  ]),
  uiWaitSemanticsUnmounted('ui.wait', <String>[
    'ui',
    'wait',
    'semantics-unmounted',
  ]),
  uiWaitSemanticsValue('ui.wait', <String>['ui', 'wait', 'semantics-value']),
  uiWaitDestination('ui.wait', <String>['ui', 'wait', 'destination']),
  uiWaitTreeRevision('ui.wait', <String>['ui', 'wait', 'tree-revision']),
  uiWaitFrameRevision('ui.wait', <String>['ui', 'wait', 'frame-revision']),
  logsQuery('logs.query', <String>['logs', 'query']),
  logsTail('logs.tail', <String>['logs', 'tail']),
  logsExport('logs.export', <String>[
    'logs',
    'export',
  ], artifact: PatchbayArtifactDisposition.payloadBlob),
  captureRoot('ui.capture', <String>[
    'capture',
    'root',
  ], artifact: PatchbayArtifactDisposition.payloadBlob),
  captureTarget('ui.capture', <String>[
    'capture',
    'target',
  ], artifact: PatchbayArtifactDisposition.payloadBlob),
  blobGet('blob.metadata', <String>[
    'blob',
    'get',
  ], artifact: PatchbayArtifactDisposition.responseBlob),
  blobMetadata('blob.metadata', <String>['blob', 'metadata']);

  const PatchbayFriendlyCommand(
    this.serviceCommand,
    this.path, {
    this.artifact = PatchbayArtifactDisposition.none,
  });

  final String serviceCommand;
  final List<String> path;
  final PatchbayArtifactDisposition artifact;
}

final class PatchbayFriendlyInvocation {
  const PatchbayFriendlyInvocation({
    required this.spec,
    required this.arguments,
    this.outputPath,
    this.force = false,
  });

  final PatchbayFriendlyCommand spec;
  final Map<String, Object?> arguments;
  final String? outputPath;
  final bool force;
}

abstract final class PatchbayFriendlyCommandRegistry {
  static PatchbayFriendlyInvocation? resolve(
    List<String> words,
    ArgResults options,
  ) {
    final PatchbayFriendlyCommand? spec = _match(words);
    if (spec == null) return null;
    _validateOptions(spec, options);
    final List<String> tail = words.sublist(spec.path.length);
    final Map<String, Object?> arguments = switch (spec) {
      PatchbayFriendlyCommand.navigationCatalog ||
      PatchbayFriendlyCommand.navigationCurrent ||
      PatchbayFriendlyCommand.logsQuery ||
      PatchbayFriendlyCommand.logsTail ||
      PatchbayFriendlyCommand.logsExport ||
      PatchbayFriendlyCommand.captureRoot => _noTail(
        tail,
        _argumentsWithoutPositionals(spec, options),
      ),
      PatchbayFriendlyCommand.navigationGo ||
      PatchbayFriendlyCommand.navigationPush => _oneTail(
        tail,
        (String destination) => <String, Object?>{
          'destinationId': destination,
          'revision': _requiredInt(options, 'revision'),
          'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
        },
      ),
      PatchbayFriendlyCommand.navigationBack => _noTail(tail, <String, Object?>{
        'revision': _requiredInt(options, 'revision'),
        'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
      }),
      PatchbayFriendlyCommand.uiWaitSemanticsMounted => _oneTail(
        tail,
        (String id) => _waitArguments(
          options,
          condition: 'semanticsMounted',
          semanticsIdentifier: id,
        ),
      ),
      PatchbayFriendlyCommand.uiWaitSemanticsUnmounted => _oneTail(
        tail,
        (String id) => _waitArguments(
          options,
          condition: 'semanticsUnmounted',
          semanticsIdentifier: id,
        ),
      ),
      PatchbayFriendlyCommand.uiWaitSemanticsValue => _twoTail(
        tail,
        (String id, String value) => _waitArguments(
          options,
          condition: 'semanticsValue',
          semanticsIdentifier: id,
          value: value,
        ),
      ),
      PatchbayFriendlyCommand.uiWaitDestination => _oneTail(
        tail,
        (String destination) => _waitArguments(
          options,
          condition: 'navigationDestination',
          destinationId: destination,
          revision: _optionalInt(options, 'revision'),
        ),
      ),
      PatchbayFriendlyCommand.uiWaitTreeRevision => _oneTail(
        tail,
        (String revision) => _waitArguments(
          options,
          condition: 'treeRevision',
          revision: _parseNonNegative(revision, 'revision'),
        ),
      ),
      PatchbayFriendlyCommand.uiWaitFrameRevision => _oneTail(
        tail,
        (String revision) => _waitArguments(
          options,
          condition: 'frameRevision',
          revision: _parseNonNegative(revision, 'revision'),
        ),
      ),
      PatchbayFriendlyCommand.captureTarget => _twoTail(
        tail,
        (String id, String generation) => <String, Object?>{
          'targetId': id,
          'generation': _parseNonNegative(generation, 'generation'),
          ..._captureArguments(options),
        },
      ),
      PatchbayFriendlyCommand.blobGet || PatchbayFriendlyCommand.blobMetadata =>
        _oneTail(tail, (String blobId) => <String, Object?>{'blobId': blobId}),
    };
    final bool writesArtifact =
        spec.artifact != PatchbayArtifactDisposition.none;
    final String? outputPath = options.option('output');
    if (writesArtifact && (outputPath == null || outputPath.isEmpty)) {
      throw const FormatException('--output is required for this command');
    }
    if (!writesArtifact && outputPath != null) {
      throw const FormatException('--output is not valid for this command');
    }
    return PatchbayFriendlyInvocation(
      spec: spec,
      arguments: arguments,
      outputPath: outputPath,
      force: options.flag('force'),
    );
  }

  static PatchbayFriendlyCommand? _match(List<String> words) {
    PatchbayFriendlyCommand? result;
    for (final PatchbayFriendlyCommand candidate
        in PatchbayFriendlyCommand.values) {
      if (words.length < candidate.path.length) continue;
      bool matches = true;
      for (var index = 0; index < candidate.path.length; index += 1) {
        if (words[index] != candidate.path[index]) {
          matches = false;
          break;
        }
      }
      if (matches &&
          (result == null || candidate.path.length > result.path.length)) {
        result = candidate;
      }
    }
    return result;
  }

  static void _validateOptions(
    PatchbayFriendlyCommand spec,
    ArgResults options,
  ) {
    final Set<String> allowed = switch (spec) {
      PatchbayFriendlyCommand.navigationCatalog ||
      PatchbayFriendlyCommand.navigationCurrent ||
      PatchbayFriendlyCommand.blobMetadata => const <String>{},
      PatchbayFriendlyCommand.navigationGo ||
      PatchbayFriendlyCommand.navigationPush ||
      PatchbayFriendlyCommand.navigationBack => const <String>{
        'revision',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.uiWaitSemanticsMounted ||
      PatchbayFriendlyCommand.uiWaitSemanticsUnmounted ||
      PatchbayFriendlyCommand.uiWaitSemanticsValue ||
      PatchbayFriendlyCommand.uiWaitTreeRevision ||
      PatchbayFriendlyCommand.uiWaitFrameRevision => const <String>{
        'timeout-ms',
      },
      PatchbayFriendlyCommand.uiWaitDestination => const <String>{
        'revision',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.logsQuery => const <String>{
        'cursor',
        'direction',
        'limit',
        'levels',
        'categories',
        'since',
        'until',
      },
      PatchbayFriendlyCommand.logsTail => const <String>{
        'cursor',
        'limit',
        'levels',
        'categories',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.logsExport => const <String>{
        'cursor',
        'direction',
        'limit',
        'levels',
        'categories',
        'since',
        'until',
        'ttl-ms',
        'output',
        'force',
      },
      PatchbayFriendlyCommand.captureRoot ||
      PatchbayFriendlyCommand.captureTarget => const <String>{
        'pixel-ratio',
        'timeout-ms',
        'output',
        'force',
      },
      PatchbayFriendlyCommand.blobGet => const <String>{'output', 'force'},
    };
    const Set<String> friendlyOptions = <String>{
      'args',
      'stdin',
      'revision',
      'timeout-ms',
      'cursor',
      'direction',
      'limit',
      'levels',
      'categories',
      'since',
      'until',
      'ttl-ms',
      'pixel-ratio',
      'output',
      'force',
    };
    for (final String name in friendlyOptions) {
      if (options.wasParsed(name) && !allowed.contains(name)) {
        throw FormatException(
          '--$name is not valid for ${spec.path.join(' ')}',
        );
      }
    }
    if (options.flag('force') && options.option('output') == null) {
      throw const FormatException('--force requires --output');
    }
  }

  static Map<String, Object?> _argumentsWithoutPositionals(
    PatchbayFriendlyCommand spec,
    ArgResults options,
  ) => switch (spec) {
    PatchbayFriendlyCommand.navigationCatalog ||
    PatchbayFriendlyCommand.navigationCurrent => const <String, Object?>{},
    PatchbayFriendlyCommand.logsQuery => _logArguments(options),
    PatchbayFriendlyCommand.logsTail => <String, Object?>{
      if (options.option('cursor') case final String cursor) 'cursor': cursor,
      if (_optionalPositiveInt(options, 'limit') case final int limit)
        'limit': limit,
      'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
      if (_csv(options, 'levels') case final List<String> levels)
        'levels': levels,
      if (_csv(options, 'categories') case final List<String> categories)
        'categories': categories,
    },
    PatchbayFriendlyCommand.logsExport => <String, Object?>{
      ..._logArguments(options),
      if (_optionalPositiveInt(options, 'ttl-ms') case final int ttl)
        'ttlMs': ttl,
    },
    PatchbayFriendlyCommand.captureRoot => _captureArguments(options),
    _ => throw StateError('unexpected no-positional command ${spec.name}'),
  };

  static Map<String, Object?> _logArguments(ArgResults options) =>
      <String, Object?>{
        if (options.option('cursor') case final String cursor) 'cursor': cursor,
        if (options.option('direction') case final String direction)
          'direction': direction,
        if (_optionalPositiveInt(options, 'limit') case final int limit)
          'limit': limit,
        if (_csv(options, 'levels') case final List<String> levels)
          'levels': levels,
        if (_csv(options, 'categories') case final List<String> categories)
          'categories': categories,
        if (options.option('since') case final String since) 'since': since,
        if (options.option('until') case final String until) 'until': until,
      };

  static Map<String, Object?> _captureArguments(ArgResults options) =>
      <String, Object?>{
        if (_optionalNumber(options, 'pixel-ratio') case final num ratio)
          'pixelRatio': ratio,
        'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
      };

  static Map<String, Object?> _waitArguments(
    ArgResults options, {
    required String condition,
    String? semanticsIdentifier,
    String? value,
    String? destinationId,
    int? revision,
  }) => <String, Object?>{
    'condition': condition,
    'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
    'semanticsIdentifier': ?semanticsIdentifier,
    'value': ?value,
    'destinationId': ?destinationId,
    'revision': ?revision,
  };

  static Map<String, Object?> _noTail(
    List<String> tail,
    Map<String, Object?> arguments,
  ) {
    if (tail.isNotEmpty) throw const FormatException('unexpected argument');
    return arguments;
  }

  static Map<String, Object?> _oneTail(
    List<String> tail,
    Map<String, Object?> Function(String) build,
  ) {
    if (tail.length != 1) {
      throw const FormatException('command requires one positional argument');
    }
    return build(tail.single);
  }

  static Map<String, Object?> _twoTail(
    List<String> tail,
    Map<String, Object?> Function(String, String) build,
  ) {
    if (tail.length != 2) {
      throw const FormatException('command requires two positional arguments');
    }
    return build(tail[0], tail[1]);
  }

  static int _requiredInt(ArgResults options, String name) {
    final int? result = _optionalInt(options, name);
    if (result == null) throw FormatException('--$name is required');
    return result;
  }

  static int? _optionalInt(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    return _parseNonNegative(value, name);
  }

  static int _positiveInt(
    ArgResults options,
    String name, {
    required int fallback,
  }) {
    final int value = _optionalInt(options, name) ?? fallback;
    if (value <= 0) throw FormatException('--$name must be positive');
    return value;
  }

  static int? _optionalPositiveInt(ArgResults options, String name) {
    final int? value = _optionalInt(options, name);
    if (value != null && value <= 0) {
      throw FormatException('--$name must be positive');
    }
    return value;
  }

  static int _parseNonNegative(String value, String name) {
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw FormatException('$name must be a non-negative integer');
    }
    return parsed;
  }

  static num? _optionalNumber(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null) return null;
    final num? parsed = num.tryParse(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('--$name must be a positive number');
    }
    return parsed;
  }

  static List<String>? _csv(ArgResults options, String name) {
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
}
