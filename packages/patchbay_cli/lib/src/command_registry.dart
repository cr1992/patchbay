import 'dart:convert';

import 'package:args/args.dart';

import 'sensitive_input.dart';

enum PatchbayArtifactDisposition { none, payloadBlob, responseBlob }

/// What the CLI actually calls once a declared path has been resolved.
///
/// Every declaration picks exactly one target and `runPatchbayCli` switches
/// over this enum without a default arm, so a declaration can never reach the
/// dispatcher unhandled and a target can never be left unwired. That is what
/// removes the need for a second hand-written command table beside this one.
enum PatchbayCommandTarget {
  /// `ext.patchbay.invoke` with the declaration's own stable service command.
  declaredServiceCommand,

  /// `ext.patchbay.invoke` with the service command supplied by the caller.
  ///
  /// The generic escape hatch: the protocol name is data, not a declaration.
  callerServiceCommand,

  /// `PatchbayClient.identity` — the transport handshake, never a catalog row.
  clientIdentity,

  /// `PatchbayClient.catalog` — the capability listing itself.
  clientCatalog,

  /// `PatchbayClient.snapshot` — the transport-level state read.
  clientSnapshot,

  /// `PatchbayClient.widgetTree` — Flutter SDK diagnostic passthrough.
  clientWidgetTree,

  /// `PatchbayClient.renderTree` — Flutter SDK diagnostic passthrough.
  clientRenderTree,

  /// `PatchbayClient.focusTree` — Flutter SDK diagnostic passthrough.
  clientFocusTree,

  /// A reusable session: connect once, then run many of the targets above.
  ///
  /// It is declared here so help, option validation and the usage banner all
  /// derive from the same table as every other path, but it dispatches nothing
  /// itself — `runPatchbayCli` hands the connection to the repl loop.
  clientReplSession,
}

/// Mechanical mapping between CLI-friendly paths and stable protocol names.
///
/// This is the only command table in the CLI: parsing, dispatch and help are
/// all derived from it. Runtime availability still comes from the service
/// catalog and the invoke response remains authoritative. This table is
/// syntax, not a capability inventory.
enum PatchbayFriendlyCommand {
  identity(
    null,
    <String>['identity'],
    summary: 'Read the runtime identity handshake.',
    target: PatchbayCommandTarget.clientIdentity,
  ),
  catalog(
    null,
    <String>['catalog'],
    summary: 'List the commands and UI targets the App registers.',
    target: PatchbayCommandTarget.clientCatalog,
  ),
  snapshot(
    null,
    <String>['snapshot'],
    summary: 'Read the transport-level Patchbay snapshot.',
    target: PatchbayCommandTarget.clientSnapshot,
  ),
  exec(
    null,
    <String>['exec'],
    summary: 'Invoke any cataloged service command by its protocol name.',
    usageSuffix: '<service-command>',
    target: PatchbayCommandTarget.callerServiceCommand,
  ),
  repl(
    null,
    <String>['repl'],
    summary: 'Connect once, then run commands from stdin over that connection.',
    target: PatchbayCommandTarget.clientReplSession,
  ),
  jobGet(
    'patchbay.job.get',
    <String>['job', 'get'],
    summary: 'Read the current snapshot of an admitted job.',
    usageSuffix: '<job-id>',
  ),
  jobCancel(
    'patchbay.job.cancel',
    <String>['job', 'cancel'],
    summary: 'Request cancellation of an admitted job.',
    usageSuffix: '<job-id>',
  ),
  navigationCatalog('navigation.catalog', <String>[
    'navigation',
    'catalog',
  ], summary: 'List destinations exposed by the running App.'),
  navigationCurrent('navigation.current', <String>[
    'navigation',
    'current',
  ], summary: 'Read the current destination and revision.'),
  navigationGo(
    'navigation.go',
    <String>['navigation', 'go'],
    summary: 'Replace navigation state with a destination.',
    usageSuffix: '<destination-id> --revision <revision>',
  ),
  navigationPush(
    'navigation.push',
    <String>['navigation', 'push'],
    summary: 'Push a cataloged destination.',
    usageSuffix: '<destination-id> --revision <revision>',
  ),
  navigationBack(
    'navigation.back',
    <String>['navigation', 'back'],
    summary: 'Navigate back from an observed revision.',
    usageSuffix: '--revision <revision>',
  ),
  uiWaitSemanticsMounted(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-mounted'],
    summary: 'Wait for a semantics identifier to mount.',
    usageSuffix: '<identifier>',
  ),
  uiWaitSemanticsUnmounted(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-unmounted'],
    summary: 'Wait for a semantics identifier to unmount.',
    usageSuffix: '<identifier>',
  ),
  uiWaitSemanticsValue(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-value'],
    summary: 'Wait for a semantics value.',
    usageSuffix: '<identifier> <value>',
  ),
  uiWaitDestination(
    'ui.wait',
    <String>['ui', 'wait', 'destination'],
    summary: 'Wait for a navigation destination.',
    usageSuffix: '<destination-id>',
  ),
  uiWaitTreeRevision(
    'ui.wait',
    <String>['ui', 'wait', 'tree-revision'],
    summary: 'Wait for the semantics tree revision.',
    usageSuffix: '<revision>',
  ),
  uiWaitFrameRevision(
    'ui.wait',
    <String>['ui', 'wait', 'frame-revision'],
    summary: 'Wait for the rendered frame revision.',
    usageSuffix: '<revision>',
  ),
  uiTextSet(
    'ui.text.set',
    <String>['ui', 'text', 'set'],
    summary: 'Replace the text of a registered input target.',
    usageSuffix: '<target-id> <generation> [text]',
  ),
  uiTextEnter(
    'ui.text.enter',
    <String>['ui', 'text', 'enter'],
    summary: 'Type text into a registered input target and submit it.',
    usageSuffix: '<target-id> <generation> [text]',
  ),
  uiSemanticsTree('ui.semantics.tree', <String>[
    'ui',
    'semantics',
    'tree',
  ], summary: 'Read the Patchbay semantics tree.'),
  uiSemanticsAction(
    'ui.semantics.action',
    <String>['ui', 'semantics', 'action'],
    summary: 'Dispatch a semantics action against an observed node.',
    usageSuffix: '<node-id> <generation> <action> [text]',
  ),
  uiTap(
    'ui.semantics.tap',
    <String>['ui', 'tap'],
    summary: 'Resolve a semantics identifier and tap it in one request.',
    usageSuffix: '<identifier> [--generation <generation>]',
  ),
  uiWidgetTree(
    null,
    <String>['ui', 'widget-tree'],
    summary: 'Read the Flutter widget tree diagnostic (SDK passthrough).',
    target: PatchbayCommandTarget.clientWidgetTree,
  ),
  uiRenderTree(
    null,
    <String>['ui', 'render-tree'],
    summary: 'Read the Flutter render tree diagnostic (SDK passthrough).',
    target: PatchbayCommandTarget.clientRenderTree,
  ),
  uiFocusTree(
    null,
    <String>['ui', 'focus-tree'],
    summary: 'Read the Flutter focus tree diagnostic (SDK passthrough).',
    target: PatchbayCommandTarget.clientFocusTree,
  ),
  logsQuery('logs.query', <String>[
    'logs',
    'query',
  ], summary: 'Query structured App logs.'),
  logsTail('logs.tail', <String>[
    'logs',
    'tail',
  ], summary: 'Long-poll for structured App logs.'),
  logsExport(
    'logs.export',
    <String>['logs', 'export'],
    summary: 'Export structured logs to a verified artifact.',
    usageSuffix: '--output <path>',
    artifact: PatchbayArtifactDisposition.payloadBlob,
  ),
  captureRoot(
    'ui.capture',
    <String>['capture', 'root'],
    summary: 'Capture the Flutter root repaint boundary.',
    usageSuffix: '--output <path>',
    artifact: PatchbayArtifactDisposition.payloadBlob,
  ),
  captureTarget(
    'ui.capture',
    <String>['capture', 'target'],
    summary: 'Capture a registered Flutter UI target.',
    usageSuffix: '<target-id> <generation> --output <path>',
    artifact: PatchbayArtifactDisposition.payloadBlob,
  ),
  blobGet(
    'blob.metadata',
    <String>['blob', 'get'],
    summary: 'Download and verify a blob artifact.',
    usageSuffix: '<blob-id> --output <path>',
    artifact: PatchbayArtifactDisposition.responseBlob,
  ),
  blobMetadata(
    'blob.metadata',
    <String>['blob', 'metadata'],
    summary: 'Read blob metadata without downloading it.',
    usageSuffix: '<blob-id>',
  );

  const PatchbayFriendlyCommand(
    this.serviceCommand,
    this.path, {
    required this.summary,
    this.usageSuffix = '',
    this.artifact = PatchbayArtifactDisposition.none,
    this.target = PatchbayCommandTarget.declaredServiceCommand,
  }) : assert(
         (serviceCommand != null) ==
             (target == PatchbayCommandTarget.declaredServiceCommand),
         'a declared service command belongs to exactly that target',
       );

  /// Stable protocol name, or `null` when the target does not declare one:
  /// `exec` takes it from the caller and the client targets are transport
  /// methods rather than catalog commands.
  final String? serviceCommand;
  final List<String> path;
  final String summary;
  final String usageSuffix;
  final PatchbayArtifactDisposition artifact;
  final PatchbayCommandTarget target;
}

final class PatchbayFriendlyInvocation {
  const PatchbayFriendlyInvocation({
    required this.spec,
    required this.arguments,
    this.serviceCommand,
    this.outputPath,
    this.force = false,
  });

  final PatchbayFriendlyCommand spec;
  final Map<String, Object?> arguments;

  /// Resolved protocol name for the invoke targets; `null` for client targets.
  final String? serviceCommand;
  final String? outputPath;
  final bool force;
}

abstract final class PatchbayFriendlyCommandRegistry {
  /// Resolves [words] against the declaration table.
  ///
  /// [readSensitiveInput] is injected so tests can exercise the `--stdin`
  /// shapes without a TTY; production callers keep the no-echo reader.
  static PatchbayFriendlyInvocation? resolve(
    List<String> words,
    ArgResults options, {
    String Function() readSensitiveInput = readSensitiveStdinLine,
  }) {
    final PatchbayFriendlyCommand? spec = _match(words);
    if (spec == null) return null;
    _validateOptions(spec, options);
    final List<String> tail = words.sublist(spec.path.length);
    final String? serviceCommand;
    if (spec.target == PatchbayCommandTarget.callerServiceCommand) {
      if (tail.length != 1) {
        throw const FormatException(
          'exec requires one <service-command> argument',
        );
      }
      serviceCommand = tail.single;
    } else {
      serviceCommand = spec.serviceCommand;
    }
    final Map<String, Object?> arguments = switch (spec) {
      PatchbayFriendlyCommand.identity ||
      PatchbayFriendlyCommand.catalog ||
      PatchbayFriendlyCommand.snapshot ||
      PatchbayFriendlyCommand.uiWidgetTree ||
      PatchbayFriendlyCommand.uiRenderTree ||
      PatchbayFriendlyCommand.uiFocusTree ||
      PatchbayFriendlyCommand.repl => _noTail(tail, const <String, Object?>{}),
      // The service command already consumed the single positional above.
      PatchbayFriendlyCommand.exec => _domainArguments(
        options,
        readSensitiveInput,
      ),
      PatchbayFriendlyCommand.jobGet || PatchbayFriendlyCommand.jobCancel =>
        _oneTail(tail, (String jobId) => <String, Object?>{'jobId': jobId}),
      PatchbayFriendlyCommand.uiTextSet ||
      PatchbayFriendlyCommand.uiTextEnter => _textArguments(
        tail,
        options,
        readSensitiveInput,
      ),
      PatchbayFriendlyCommand.uiSemanticsTree => _noTail(
        tail,
        _domainArguments(options, readSensitiveInput),
      ),
      PatchbayFriendlyCommand.uiSemanticsAction => _semanticsActionArguments(
        tail,
        options,
        readSensitiveInput,
      ),
      // `--generation` stays optional: the App resolves and fences the target
      // itself, so requiring a generation here would reintroduce the tree read
      // this command exists to remove. Supplying it adds a caller-side fence.
      PatchbayFriendlyCommand.uiTap => _oneTail(
        tail,
        (String identifier) => <String, Object?>{
          'identifier': identifier,
          'generation': ?_optionalInt(options, 'generation'),
        },
      ),
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
      serviceCommand: serviceCommand,
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
    final Set<String> allowed = allowedOptions(spec);
    const Set<String> friendlyOptions = <String>{
      'args',
      'stdin',
      'revision',
      'generation',
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

  /// CLI options accepted by [spec]. Help and validation share this mapping.
  static Set<String> allowedOptions(
    PatchbayFriendlyCommand spec,
  ) => switch (spec) {
    PatchbayFriendlyCommand.identity ||
    PatchbayFriendlyCommand.catalog ||
    PatchbayFriendlyCommand.snapshot ||
    PatchbayFriendlyCommand.jobGet ||
    PatchbayFriendlyCommand.jobCancel ||
    PatchbayFriendlyCommand.uiWidgetTree ||
    PatchbayFriendlyCommand.uiRenderTree ||
    PatchbayFriendlyCommand.uiFocusTree ||
    PatchbayFriendlyCommand.navigationCatalog ||
    PatchbayFriendlyCommand.navigationCurrent ||
    PatchbayFriendlyCommand.blobMetadata ||
    // A repl carries connection options and `--json`, which are global rather
    // than per-command; every command option belongs on the lines it runs.
    PatchbayFriendlyCommand.repl => const <String>{},
    PatchbayFriendlyCommand.exec ||
    PatchbayFriendlyCommand.uiSemanticsTree => const <String>{'args', 'stdin'},
    PatchbayFriendlyCommand.uiTextSet ||
    PatchbayFriendlyCommand.uiTextEnter ||
    PatchbayFriendlyCommand.uiSemanticsAction => const <String>{'stdin'},
    PatchbayFriendlyCommand.uiTap => const <String>{'generation'},
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
    PatchbayFriendlyCommand.uiWaitFrameRevision => const <String>{'timeout-ms'},
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

  /// `--args`/`--stdin` JSON object shared by `exec` and `ui semantics tree`.
  static Map<String, Object?> _domainArguments(
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    final bool fromStdin = options.flag('stdin');
    final String encoded = fromStdin
        ? readSensitiveInput()
        : (options.option('args') ?? '{}');
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('--args/stdin must contain a JSON object');
    }
    return <String, Object?>{
      ...Map<String, Object?>.from(decoded),
      if (fromStdin) 'inputWasStdin': true,
    };
  }

  /// `ui text set|enter <target-id> <generation> [text]`.
  ///
  /// The trailing text is variadic, so this shape cannot use the fixed-arity
  /// helpers; `--stdin` replaces the trailing words with one no-echo line.
  static Map<String, Object?> _textArguments(
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
      'generation': _parseNonNegative(tail[1], 'generation'),
      'text': fromStdin ? readSensitiveInput() : tail.sublist(2).join(' '),
      'inputWasStdin': fromStdin,
    };
  }

  /// `ui semantics action <node-id> <generation> <action> [text]`.
  ///
  /// Only `setText` carries text, so the sensitive read stays inside that arm.
  static Map<String, Object?> _semanticsActionArguments(
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
      'nodeId': _parseNonNegative(tail[0], 'nodeId'),
      'generation': _parseNonNegative(tail[1], 'generation'),
      'action': action,
      if (action == 'setText')
        'text': fromStdin ? readSensitiveInput() : tail.sublist(3).join(' '),
      'inputWasStdin': fromStdin,
    };
  }

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
