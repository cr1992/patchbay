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

  /// A verdict computed on this side of the wire from a catalog reading.
  ///
  /// The App is asked only for facts it already publishes — the UI target
  /// catalog, and the current destination when the manifest scopes anything.
  /// The comparison and the exit code are the CLI's, which is what lets this
  /// command exist without a single new wire command.
  localManifestVerification,

  /// A reusable session: connect once, then run many of the targets above.
  ///
  /// It is declared here so help, option validation and the usage banner all
  /// derive from the same table as every other path, but it dispatches nothing
  /// itself — `runPatchbayCli` hands the connection to the repl loop.
  clientReplSession,

  /// The local launcher session directory, read and written without dialling.
  ///
  /// These commands answer questions *about* sessions — which records exist,
  /// which one later commands should use — so requiring a connection would
  /// invert the dependency: the operator reaches for them precisely when the
  /// CLI cannot pick a session on its own.
  localSessionStore,

  /// A diagnosis that owns its own connection attempt.
  ///
  /// Every other target is dispatched *after* a successful dial, which is
  /// exactly what a diagnosis cannot require: a dial that fails is the answer
  /// it was asked for. So `runPatchbayCli` hands this target the connection
  /// options rather than a connection, and it reports what happened to each.
  localDiagnostics,
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
  doctor(
    null,
    <String>['doctor'],
    summary:
        'Check session, connection, catalog and App lifecycle in one pass.',
    target: PatchbayCommandTarget.localDiagnostics,
  ),
  sessionsList(
    null,
    <String>['sessions', 'list'],
    summary: 'List launcher session records; * marks the pinned one.',
    target: PatchbayCommandTarget.localSessionStore,
  ),
  sessionsPrune(
    null,
    <String>['sessions', 'prune'],
    summary: 'Remove session records whose App process is gone.',
    target: PatchbayCommandTarget.localSessionStore,
  ),
  sessionUse(
    null,
    <String>['session', 'use'],
    summary: 'Pin one session for commands that pass no --session.',
    usageSuffix: '<session-id> | --clear',
    target: PatchbayCommandTarget.localSessionStore,
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
    usageSuffix: '<destination-id> [--revision <revision>]',
    fencesNavigationRevision: true,
  ),
  navigationPush(
    'navigation.push',
    <String>['navigation', 'push'],
    summary: 'Push a cataloged destination.',
    usageSuffix: '<destination-id> [--revision <revision>]',
    fencesNavigationRevision: true,
  ),
  navigationBack(
    'navigation.back',
    <String>['navigation', 'back'],
    summary: 'Navigate back from an observed revision.',
    usageSuffix: '[--revision <revision>]',
    fencesNavigationRevision: true,
  ),
  uiWaitSemanticsMounted(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-mounted'],
    summary: 'Wait for a semantics identifier to mount.',
    usageSuffix: '<identifier>',
    waitCondition: 'semanticsMounted',
  ),
  uiWaitSemanticsUnmounted(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-unmounted'],
    summary: 'Wait for a semantics identifier to unmount.',
    usageSuffix: '<identifier>',
    waitCondition: 'semanticsUnmounted',
  ),
  uiWaitSemanticsValue(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-value'],
    summary: 'Wait for a semantics value.',
    usageSuffix: '<identifier> <value>',
    waitCondition: 'semanticsValue',
  ),
  uiWaitDestination(
    'ui.wait',
    <String>['ui', 'wait', 'destination'],
    summary: 'Wait for a navigation destination.',
    usageSuffix: '<destination-id>',
    waitCondition: 'navigationDestination',
  ),
  uiWaitTreeRevision(
    'ui.wait',
    <String>['ui', 'wait', 'tree-revision'],
    summary: 'Wait for the semantics tree revision.',
    usageSuffix: '<revision>',
    waitCondition: 'treeRevision',
  ),
  uiWaitFrameRevision(
    'ui.wait',
    <String>['ui', 'wait', 'frame-revision'],
    summary: 'Wait for the rendered frame revision.',
    usageSuffix: '<revision>',
    waitCondition: 'frameRevision',
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
  uiVerifyManifest(
    null,
    <String>['ui', 'verify-manifest'],
    summary: 'Reconcile a declared UI target manifest against the runtime.',
    usageSuffix: '<manifest-file>',
    target: PatchbayCommandTarget.localManifestVerification,
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
    this.waitCondition,
    this.fencesNavigationRevision = false,
  }) : assert(
         (serviceCommand != null) ==
             (target == PatchbayCommandTarget.declaredServiceCommand),
         'a declared service command belongs to exactly that target',
       ),
       assert(
         (waitCondition != null) == (serviceCommand == 'ui.wait'),
         'every ui.wait declaration names the condition it sends, and only '
             'those declarations have one',
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

  /// The `condition` value this declaration sends, for the `ui.wait` family.
  ///
  /// The CLI subcommand is hyphenated syntax and the condition is the wire
  /// value; they differ on purpose, but only the wire value appears in the
  /// response an operator is reading. Declaring it here is what lets help print
  /// the mapping and lets the parser accept either spelling, without a second
  /// hand-maintained list that could drift from the request actually sent.
  final String? waitCondition;

  /// Whether the request carries an observed navigation revision as a fence.
  ///
  /// When the caller omits `--revision` the CLI reads it from
  /// `navigation.current` and sends that value; the fence itself is unchanged,
  /// so a tree that moved in between is still refused by the App. The flag only
  /// says "this command needs the number", never "this command may skip it".
  final bool fencesNavigationRevision;
}

final class PatchbayFriendlyInvocation {
  const PatchbayFriendlyInvocation({
    required this.spec,
    required this.arguments,
    this.serviceCommand,
    this.outputPath,
    this.manifestPath,
    this.force = false,
    this.plaintextArgumentKeys = const <String>{},
    this.resolvesRevision = false,
  });

  final PatchbayFriendlyCommand spec;
  final Map<String, Object?> arguments;

  /// Resolved protocol name for the invoke targets; `null` for client targets.
  final String? serviceCommand;
  final String? outputPath;

  /// Local file the command reads before it talks to the App.
  ///
  /// It is kept out of [arguments] on purpose: a manifest is caller input read
  /// on this side of the wire, and nothing about it is ever sent to the App.
  final String? manifestPath;
  final bool force;

  /// Argument keys that came from `--args`, i.e. from an echoing argv.
  final Set<String> plaintextArgumentKeys;

  /// Whether the dispatcher still has to read the navigation revision fence.
  ///
  /// True only when the command needs one and the caller supplied none; an
  /// explicit `--revision` is already in [arguments] and is never second-
  /// guessed.
  final bool resolvesRevision;
}

/// One accepted spelling and the declared path it expands into.
final class _PathAlias {
  const _PathAlias(this.from, this.to);

  final List<String> from;
  final List<String> to;
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
    final List<String> path = canonicalPath(words);
    final PatchbayFriendlyCommand? spec = _match(path);
    if (spec == null) return null;
    _validateOptions(spec, options);
    final List<String> tail = path.sublist(spec.path.length);
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
      PatchbayFriendlyCommand.repl ||
      PatchbayFriendlyCommand.doctor ||
      PatchbayFriendlyCommand.sessionsList ||
      PatchbayFriendlyCommand.sessionsPrune => _noTail(
        tail,
        const <String, Object?>{},
      ),
      PatchbayFriendlyCommand.sessionUse => _sessionUseArguments(tail, options),
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
      // The manifest path is local input rather than an invoke argument, so it
      // travels in `manifestPath` and this command sends no arguments at all.
      PatchbayFriendlyCommand.uiVerifyManifest => _oneTail(
        tail,
        (String _) => const <String, Object?>{},
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
      // `revision` is left out when the caller omitted it: the dispatcher fills
      // it in from `navigation.current` before the request goes out, so the
      // fence still travels — it is just no longer a manual round trip.
      PatchbayFriendlyCommand.navigationGo ||
      PatchbayFriendlyCommand.navigationPush => _oneTail(
        tail,
        (String destination) => <String, Object?>{
          'destinationId': destination,
          'revision': ?_optionalInt(options, 'revision'),
          'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
        },
      ),
      PatchbayFriendlyCommand.navigationBack => _noTail(tail, <String, Object?>{
        'revision': ?_optionalInt(options, 'revision'),
        'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
      }),
      // Every arm below takes its `condition` from the declaration, so the
      // value help prints and the value the App receives cannot disagree.
      PatchbayFriendlyCommand.uiWaitSemanticsMounted ||
      PatchbayFriendlyCommand.uiWaitSemanticsUnmounted => _oneTail(
        tail,
        (String id) => _waitArguments(
          options,
          condition: spec.waitCondition!,
          semanticsIdentifier: id,
        ),
      ),
      PatchbayFriendlyCommand.uiWaitSemanticsValue => _twoTail(
        tail,
        (String id, String value) => _waitArguments(
          options,
          condition: spec.waitCondition!,
          semanticsIdentifier: id,
          value: value,
        ),
      ),
      PatchbayFriendlyCommand.uiWaitDestination => _oneTail(
        tail,
        (String destination) => _waitArguments(
          options,
          condition: spec.waitCondition!,
          destinationId: destination,
          revision: _optionalInt(options, 'revision'),
        ),
      ),
      PatchbayFriendlyCommand.uiWaitTreeRevision ||
      PatchbayFriendlyCommand.uiWaitFrameRevision => _oneTail(
        tail,
        (String revision) => _waitArguments(
          options,
          condition: spec.waitCondition!,
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
      // `_oneTail` above already refused any other arity for this declaration.
      manifestPath: spec == PatchbayFriendlyCommand.uiVerifyManifest
          ? tail.single
          : null,
      force: options.flag('force'),
      plaintextArgumentKeys: _plaintextArgumentKeys(options),
      resolvesRevision:
          spec.fencesNavigationRevision && options.option('revision') == null,
    );
  }

  /// The declaration [words] name, without touching arguments or stdin.
  ///
  /// `runPatchbayCli` has to know whether a command needs a connection *before*
  /// it dials, and the repl has to refuse the ones that do not. Both ask here
  /// rather than pattern-matching argv, so the answer stays derived from the
  /// same table as dispatch and help.
  static PatchbayFriendlyCommand? specFor(List<String> words) =>
      _match(canonicalPath(words));

  /// Rewrites [words] into the declared spelling of the same command.
  ///
  /// Aliases only ever expand into a path that already exists: they add a way
  /// to type a command, never a command, so no stable name changes and nothing
  /// new becomes dispatchable. Two rewrites are enough for the deepest chain
  /// (`wait semanticsMounted` → `ui wait semanticsMounted` → the declaration),
  /// and no expansion produces another alias, so this terminates.
  static List<String> canonicalPath(List<String> words) {
    List<String> current = words;
    for (var pass = 0; pass < 2; pass += 1) {
      final List<String>? expanded = _expandAlias(current);
      if (expanded == null) return current;
      current = expanded;
    }
    return current;
  }

  static List<String>? _expandAlias(List<String> words) {
    for (final _PathAlias alias in _aliases) {
      if (!_startsWith(words, alias.from)) continue;
      return <String>[...alias.to, ...words.sublist(alias.from.length)];
    }
    return null;
  }

  /// Alternate spellings accepted for a declared path.
  ///
  /// The `ui wait <condition>` entries are generated from the declarations
  /// themselves: whatever condition a payload shows is therefore typeable, and
  /// the mapping can never drift from the request the CLI actually sends. The
  /// rest are the group names operators reach for before reading help.
  static final List<_PathAlias> _aliases =
      <_PathAlias>[
        for (final PatchbayFriendlyCommand spec
            in PatchbayFriendlyCommand.values)
          if (spec.waitCondition case final String condition)
            _PathAlias(<String>[
              ...spec.path.take(spec.path.length - 1),
              condition,
            ], spec.path),
        // `sessions` and `session` differ by one letter and both read as the
        // group an operator wants, so either spelling reaches the declared
        // path. As with every alias here, these expand into paths that already
        // exist and add no command.
        const _PathAlias(<String>['session', 'list'], <String>[
          'sessions',
          'list',
        ]),
        const _PathAlias(<String>['session', 'prune'], <String>[
          'sessions',
          'prune',
        ]),
        const _PathAlias(<String>['sessions', 'use'], <String>[
          'session',
          'use',
        ]),
        const _PathAlias(<String>['navigate'], <String>['navigation']),
        const _PathAlias(<String>['nav'], <String>['navigation']),
        const _PathAlias(<String>['wait'], <String>['ui', 'wait']),
        const _PathAlias(<String>['tap'], <String>['ui', 'tap']),
        const _PathAlias(<String>['text'], <String>['ui', 'text']),
        const _PathAlias(<String>['semantics'], <String>['ui', 'semantics']),
      ]..sort(
        (_PathAlias a, _PathAlias b) => b.from.length.compareTo(a.from.length),
      );

  static bool _startsWith(List<String> words, List<String> prefix) {
    if (words.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index += 1) {
      if (words[index] != prefix[index]) return false;
    }
    return true;
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
      'clear',
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
    // Nothing about the comparison is tunable: the manifest is the whole
    // request, and the current destination comes from the App, not a flag.
    PatchbayFriendlyCommand.uiVerifyManifest ||
    // A repl carries connection options and `--json`, which are global rather
    // than per-command; every command option belongs on the lines it runs.
    PatchbayFriendlyCommand.repl ||
    // `--session-dir` selects which directory these read, and it is global.
    PatchbayFriendlyCommand.sessionsList ||
    PatchbayFriendlyCommand.sessionsPrune ||
    // Doctor runs a fixed set of checks: there is nothing per-command to
    // configure, and the RPC budget it runs under is the global
    // `--transport-timeout-ms` every other command already uses.
    PatchbayFriendlyCommand.doctor => const <String>{},
    PatchbayFriendlyCommand.sessionUse => const <String>{'clear'},
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
  ///
  /// The two merge and stdin wins on a shared key. A command usually has one
  /// value that must not be echoed and several that are ordinary shape; making
  /// stdin *replace* `--args` forced the whole object through the no-echo line,
  /// where a typo in the readable half is invisible. Passing everything through
  /// stdin still works — that is the degenerate case where `--args` is absent.
  static Map<String, Object?> _domainArguments(
    ArgResults options,
    String Function() readSensitiveInput,
  ) {
    final Map<String, Object?> fromArgs = _jsonObject(
      options.option('args') ?? '{}',
      '--args',
    );
    if (!options.flag('stdin')) return fromArgs;
    return <String, Object?>{
      ...fromArgs,
      ..._jsonObject(readSensitiveInput(), 'stdin'),
      // Fail closed on the marker itself: a stdin payload claiming
      // `inputWasStdin: false` must not be able to unset it.
      'inputWasStdin': true,
    };
  }

  /// Argument keys this invocation took from argv rather than from stdin.
  ///
  /// The dispatcher compares them against the catalog descriptor and refuses to
  /// send a parameter the App declares sensitive through argv, so merging
  /// `--args` with `--stdin` cannot become a detour around the no-echo line.
  static Set<String> _plaintextArgumentKeys(ArgResults options) {
    final String? encoded = options.option('args');
    if (encoded == null) return const <String>{};
    return _jsonObject(encoded, '--args').keys.toSet();
  }

  static Map<String, Object?> _jsonObject(String encoded, String source) {
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$source must contain a JSON object');
    }
    return Map<String, Object?>.from(decoded);
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

  /// `session use <session-id>` or `session use --clear`, never both.
  ///
  /// Pinning and unpinning are opposite intents, so a line that states both is
  /// refused rather than resolved by precedence: an operator who typed an id
  /// and a stale `--clear` must not silently end up unpinned.
  static Map<String, Object?> _sessionUseArguments(
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
