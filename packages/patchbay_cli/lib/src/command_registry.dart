import 'dart:convert';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'sensitive_input.dart';

part 'generated/protocol_cli_commands.g.dart';

enum PatchbayArtifactDisposition { none, payloadBlob, responseBlob }

/// Where a CLI-only command declaration is implemented.
///
/// This is process-local metadata, not part of the Patchbay wire contract.
/// Protocol-generated declarations are identified by their descriptor before
/// this value is consulted.
enum PatchbayCommandDeclarationSource { client, local }

abstract interface class PatchbayFriendlyCommandSpec {
  String get name;
  String? get serviceCommand;
  List<String> get path;
  String get summary;
  String get usageSuffix;
  PatchbayArtifactDisposition get artifact;
  PatchbayCommandTarget get target;
  String? get waitCondition;
  bool get fencesNavigationRevision;
  PatchbayCommandDescriptor? get protocolDescriptor;
  PatchbayCliSyntax? get protocolSyntax;
}

final class _GeneratedProtocolCommand implements PatchbayFriendlyCommandSpec {
  const _GeneratedProtocolCommand({
    required this.descriptor,
    required this.serviceName,
    required this.syntaxIndex,
  });

  final PatchbayCommandDescriptor descriptor;
  final String serviceName;
  final int syntaxIndex;

  PatchbayCliSyntax get syntax => descriptor.cliSyntax[syntaxIndex];

  @override
  String get name => syntax.id;

  @override
  String get serviceCommand {
    if (serviceName != descriptor.name) {
      throw StateError('generated protocol service name drifted');
    }
    return serviceName;
  }

  @override
  List<String> get path => syntax.path;
  @override
  String get summary => syntax.summary;
  @override
  String get usageSuffix => syntax.usageSuffix;
  @override
  PatchbayArtifactDisposition get artifact =>
      switch (syntax.artifactDisposition) {
        PatchbayCliArtifactDisposition.none => PatchbayArtifactDisposition.none,
        PatchbayCliArtifactDisposition.payloadBlob =>
          PatchbayArtifactDisposition.payloadBlob,
        PatchbayCliArtifactDisposition.responseBlob =>
          PatchbayArtifactDisposition.responseBlob,
      };
  @override
  PatchbayCommandTarget get target =>
      PatchbayCommandTarget.declaredServiceCommand;
  @override
  String? get waitCondition => switch (syntax.fixedArguments['condition']) {
    final String condition => condition,
    _ => null,
  };
  @override
  bool get fencesNavigationRevision => syntax.fencesNavigationRevision;
  @override
  PatchbayCommandDescriptor get protocolDescriptor => descriptor;
  @override
  PatchbayCliSyntax get protocolSyntax => syntax;
}

/// What the CLI actually calls once a declared path has been resolved.
///
/// Every declaration picks exactly one target and `runPatchbayCli` switches
/// over this enum without a default arm, so a declaration can never reach the
/// dispatcher unhandled and a target can never be left unwired. That is what
/// removes the need for a second hand-written command table beside this one.
enum PatchbayCommandTarget {
  /// `ext.patchbay.invoke` with the declaration's own stable service command.
  declaredServiceCommand(PatchbayCommandDeclarationSource.client),

  /// `ext.patchbay.invoke` with the service command supplied by the caller.
  ///
  /// The generic escape hatch: the protocol name is data, not a declaration.
  callerServiceCommand(PatchbayCommandDeclarationSource.client),

  /// `PatchbayClient.identity` — the transport handshake, never a catalog row.
  clientIdentity(PatchbayCommandDeclarationSource.client),

  /// `PatchbayClient.catalog` — the capability listing itself.
  clientCatalog(PatchbayCommandDeclarationSource.client),

  /// A local projection of one live catalog row; invokes no App command.
  localCatalogDescription(PatchbayCommandDeclarationSource.local),

  /// `PatchbayClient.snapshot` — the transport-level state read.
  clientSnapshot(PatchbayCommandDeclarationSource.client),

  /// `PatchbayClient.widgetTree` — Flutter SDK diagnostic passthrough.
  clientWidgetTree(PatchbayCommandDeclarationSource.client),

  /// `PatchbayClient.renderTree` — Flutter SDK diagnostic passthrough.
  clientRenderTree(PatchbayCommandDeclarationSource.client),

  /// `PatchbayClient.focusTree` — Flutter SDK diagnostic passthrough.
  clientFocusTree(PatchbayCommandDeclarationSource.client),

  /// Public VM Service timeline and memory RPCs reduced to a stable summary.
  clientPerformanceProfile(PatchbayCommandDeclarationSource.client),

  /// A stable refusal until a collection-before-redaction network RPC exists.
  clientNetworkProfile(PatchbayCommandDeclarationSource.client),

  /// A verdict computed on this side of the wire from a catalog reading.
  ///
  /// The App is asked only for facts it already publishes — the UI target
  /// catalog, and the current destination when the manifest scopes anything.
  /// The comparison and the exit code are the CLI's, which is what lets this
  /// command exist without a single new wire command.
  localManifestVerification(PatchbayCommandDeclarationSource.local),

  /// A manifest draft computed on this side of the wire from live catalog
  /// facts and the currently settled destination.
  localManifestEmission(PatchbayCommandDeclarationSource.local),

  /// A reusable session: connect once, then run many of the targets above.
  ///
  /// It is declared here so help, option validation and the usage banner all
  /// derive from the same table as every other path, but it dispatches nothing
  /// itself — `runPatchbayCli` hands the connection to the repl loop.
  clientReplSession(PatchbayCommandDeclarationSource.client),

  /// The local launcher session directory, read and written without dialling.
  ///
  /// These commands answer questions *about* sessions — which records exist,
  /// which one later commands should use — so requiring a connection would
  /// invert the dependency: the operator reaches for them precisely when the
  /// CLI cannot pick a session on its own.
  localSessionStore(PatchbayCommandDeclarationSource.local),

  /// Starts and supervises one consumer child and its declared session.
  localLauncher(PatchbayCommandDeclarationSource.local),

  /// A diagnosis that owns its own connection attempt.
  ///
  /// Every other target is dispatched *after* a successful dial, which is
  /// exactly what a diagnosis cannot require: a dial that fails is the answer
  /// it was asked for. So `runPatchbayCli` hands this target the connection
  /// options rather than a connection, and it reports what happened to each.
  localDiagnostics(PatchbayCommandDeclarationSource.local),

  /// An explicitly installed external JSON Lines permission driver.
  localPermissionDriver(PatchbayCommandDeclarationSource.local),

  /// The local append-only trace store, read and written without dialling.
  localTraceStore(PatchbayCommandDeclarationSource.local);

  const PatchbayCommandTarget(this.declarationSource);

  /// Authoritative source for declarations that do not carry a protocol
  /// descriptor. Every target must choose explicitly, so adding a future
  /// local target cannot silently fall through to a client default.
  final PatchbayCommandDeclarationSource declarationSource;
}

/// Explicit declarations for local and client-only CLI commands.
///
/// Protocol-owned declarations are generated beside these from core
/// descriptors. [PatchbayFriendlyCommandRegistry.commands] is the single
/// combined syntax table consumed by parsing, dispatch and help.
enum PatchbayFriendlyCommand implements PatchbayFriendlyCommandSpec {
  launch(
    null,
    <String>['launch'],
    summary: 'Supervise a consumer command and its declared Patchbay session.',
    usageSuffix: '-- <consumer command>',
    target: PatchbayCommandTarget.localLauncher,
  ),
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
  describe(
    null,
    <String>['describe'],
    summary: 'Describe one live service command and its retry eligibility.',
    usageSuffix: '<service-command>',
    target: PatchbayCommandTarget.localCatalogDescription,
  ),
  snapshot(
    null,
    <String>['snapshot'],
    summary: 'Read the transport-level Patchbay snapshot.',
    usageSuffix: '[--path <dot.path>]',
    target: PatchbayCommandTarget.clientSnapshot,
  ),
  snapshotWait(
    null,
    <String>['snapshot', 'wait'],
    summary: 'Wait App-side for a condition on one snapshot field.',
    usageSuffix: '<dot.path> --until <condition> [<json-value>]',
    target: PatchbayCommandTarget.clientSnapshot,
  ),
  snapshotDiff(
    null,
    <String>['snapshot', 'diff'],
    summary: 'Compare the current snapshot with a retained revision.',
    usageSuffix: '--from <revision>',
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
  permissionDoctor(
    null,
    <String>['doctor', 'permission'],
    summary: 'Check the selected external permission driver and capabilities.',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionCapabilities(
    null,
    <String>['permission', 'capabilities'],
    summary: 'Read the external driver capability matrix.',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionStatus(
    null,
    <String>['permission', 'status'],
    summary: 'Read one platform permission state.',
    usageSuffix: '<permission>',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionNormalize(
    null,
    <String>['permission', 'normalize'],
    summary: 'Normalize one permission for an active debug/test session.',
    usageSuffix: '<permission> --state <state>',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionReset(
    null,
    <String>['permission', 'reset'],
    summary: 'Reset one permission for an active debug/test session.',
    usageSuffix: '<permission>',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionExercise(
    null,
    <String>['permission', 'exercise'],
    summary: 'Exercise one declared system permission decision.',
    usageSuffix: '<permission> --decision <decision>',
    target: PatchbayCommandTarget.localPermissionDriver,
  ),
  permissionFail(
    null,
    <String>['permission', 'fail'],
    summary: 'Fail when the current permission state differs.',
    usageSuffix: '<permission> --state <state>',
    target: PatchbayCommandTarget.localPermissionDriver,
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
  traceStart(
    null,
    <String>['trace', 'start'],
    summary: 'Create a local append-only debug trace.',
    usageSuffix: '--name <name> [--activate] [--pin]',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  traceMark(
    null,
    <String>['trace', 'mark'],
    summary: 'Append an operator note to an active or explicit trace.',
    usageSuffix: '<note>',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  traceStop(
    null,
    <String>['trace', 'stop'],
    summary: 'Finish an active or explicitly named trace.',
    usageSuffix: '[trace-id]',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  traceShow(
    null,
    <String>['trace', 'show'],
    summary: 'Read a trace timeline, including crash recovery facts.',
    usageSuffix: '<trace-id>',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  traceExport(
    null,
    <String>['trace', 'export'],
    summary: 'Export a re-redacted portable trace directory.',
    usageSuffix: '<trace-id> --output <directory>',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  traceDiff(
    null,
    <String>['trace', 'diff'],
    summary: 'Compare two traces by command identity and occurrence.',
    usageSuffix: '<before-trace-id> <after-trace-id>',
    target: PatchbayCommandTarget.localTraceStore,
  ),
  tracePrune(
    null,
    <String>['trace', 'prune'],
    summary: 'Remove ended, unpinned traces beyond the retention age.',
    usageSuffix: '[--dry-run]',
    target: PatchbayCommandTarget.localTraceStore,
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
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  navigationCatalog.compatibility(_navigationCatalogProtocolCommand),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  navigationCurrent.compatibility(_navigationCurrentProtocolCommand),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  navigationGo.compatibility(_navigationGoProtocolCommand),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  navigationPush.compatibility(_navigationPushProtocolCommand),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  navigationBack.compatibility(_navigationBackProtocolCommand),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitSemanticsMounted.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-mounted'],
    summary: 'Wait for a semantics identifier to mount.',
    usageSuffix: '<identifier>',
    waitCondition: 'semanticsMounted',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitSemanticsUnmounted.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-unmounted'],
    summary: 'Wait for a semantics identifier to unmount.',
    usageSuffix: '<identifier>',
    waitCondition: 'semanticsUnmounted',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitSemanticsValue.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'semantics-value'],
    summary: 'Wait for a semantics value.',
    usageSuffix: '<identifier> <value>',
    waitCondition: 'semanticsValue',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitDestination.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'destination'],
    summary: 'Wait for a navigation destination.',
    usageSuffix: '<destination-id>',
    waitCondition: 'navigationDestination',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitTreeRevision.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'tree-revision'],
    summary: 'Wait for the semantics tree revision.',
    usageSuffix: '<revision>',
    waitCondition: 'treeRevision',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiWaitFrameRevision.compatibilityFrozen(
    'ui.wait',
    <String>['ui', 'wait', 'frame-revision'],
    summary: 'Wait for the rendered frame revision.',
    usageSuffix: '<revision>',
    waitCondition: 'frameRevision',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiTextSet.compatibilityFrozen(
    'ui.text.set',
    <String>['ui', 'text', 'set'],
    summary: 'Replace the text of a registered input target.',
    usageSuffix: '<target-id> <generation> [text]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiTextEnter.compatibilityFrozen(
    'ui.text.enter',
    <String>['ui', 'text', 'enter'],
    summary: 'Type text into a registered input target and submit it.',
    usageSuffix: '<target-id> <generation> [text]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiSemanticsTree.compatibilityFrozen('ui.semantics.tree', <String>[
    'ui',
    'semantics',
    'tree',
  ], summary: 'Read the Patchbay semantics tree.'),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiSemanticsAction.compatibilityFrozen(
    'ui.semantics.action',
    <String>['ui', 'semantics', 'action'],
    summary: 'Dispatch a semantics action against an observed node.',
    usageSuffix: '<node-id> <generation> <action> [text]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiTap.compatibilityFrozen(
    'ui.semantics.tap',
    <String>['ui', 'tap'],
    summary: 'Resolve a semantics identifier and tap it in one request.',
    usageSuffix: '<identifier> [--generation <generation>]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiKeepAwakeOn.compatibilityFrozen(
    'ui.keepAwake.set',
    <String>['ui', 'keep-awake', 'on'],
    summary: 'Ask the App to hold the screen awake for one bounded lease.',
    usageSuffix: '[--lease-ms <ms>]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiKeepAwakeOff.compatibilityFrozen(
    'ui.keepAwake.set',
    <String>['ui', 'keep-awake', 'off'],
    summary: 'Release the keep-awake hold now, without waiting for the lease.',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiKeepAwakeStatus.compatibilityFrozen(
    'ui.keepAwake.status',
    <String>['ui', 'keep-awake', 'status'],
    summary:
        'Read whether the App is holding the screen awake, and for how '
        'much longer.',
  ),
  uiVerifyManifest(
    null,
    <String>['ui', 'verify-manifest'],
    summary: 'Reconcile a declared UI target manifest against the runtime.',
    usageSuffix:
        '<manifest-file> [--navigate] [--continue-on-error] [--restore]',
    target: PatchbayCommandTarget.localManifestVerification,
  ),
  uiTargets(
    null,
    <String>['ui', 'targets'],
    summary: 'Emit an editable manifest draft from mounted catalog targets.',
    usageSuffix: '--emit-manifest',
    target: PatchbayCommandTarget.localManifestEmission,
  ),
  // `on` and `off` are two spellings of one protocol command, exactly as
  // `ui wait <condition>` is six spellings of `ui.wait`: the boolean is the
  // argument, and the CLI path is what an operator types. `status` is a
  // separate declaration because it is a separate command — a read-only one
  // that changes nothing, which a shared descriptor could not honestly say.
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiInspectOn.compatibilityFrozen(
    'ui.inspect.select',
    <String>['ui', 'inspect', 'on'],
    summary: 'Turn widget select mode on for a lease, then it restores itself.',
    usageSuffix: '[--ttl-ms <ms>]',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiInspectOff.compatibilityFrozen(
    'ui.inspect.select',
    <String>['ui', 'inspect', 'off'],
    summary: 'Turn widget select mode off and release the lease.',
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  uiInspectStatus.compatibilityFrozen(
    'ui.inspect.status',
    <String>['ui', 'inspect', 'status'],
    summary: 'Read the widget select-mode switch and its lease.',
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
  performanceProfile(
    null,
    <String>['perf', 'profile'],
    summary: 'Collect one bounded VM Service performance summary.',
    usageSuffix: '[--duration-ms <ms>] [--sample-limit <events>]',
    target: PatchbayCommandTarget.clientPerformanceProfile,
  ),
  networkProfile(
    null,
    <String>['net', 'profile'],
    summary: 'Report whether privacy-safe network profiling is available.',
    target: PatchbayCommandTarget.clientNetworkProfile,
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
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  captureRoot.compatibilityFrozen(
    'ui.capture',
    <String>['capture', 'root'],
    summary: 'Capture the Flutter root repaint boundary.',
    usageSuffix: '--output <path>',
    artifact: PatchbayArtifactDisposition.payloadBlob,
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  captureTarget.compatibilityFrozen(
    'ui.capture',
    <String>['capture', 'target'],
    summary: 'Capture a registered Flutter UI target.',
    usageSuffix: '<target-id> <generation> --output <path>',
    artifact: PatchbayArtifactDisposition.payloadBlob,
  ),
  captureDiff(
    'ui.capture.diff',
    <String>['capture', 'diff'],
    summary: 'Compare two Flutter capture artifacts pixel by pixel.',
    usageSuffix: '<before-blob-id> <after-blob-id>',
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
    this._serviceCommand,
    this._path, {
    required String summary,
    String usageSuffix = '',
    this.artifact = PatchbayArtifactDisposition.none,
    this.target = PatchbayCommandTarget.declaredServiceCommand,
    this.waitCondition,
    bool fencesNavigationRevision = false,
  }) : _summary = summary,
       _usageSuffix = usageSuffix,
       _fencesNavigationRevision = fencesNavigationRevision,
       _compatibilityProtocol = null,
       _isCompatibilityStub = false,
       assert(
         (_serviceCommand != null) ==
             (target == PatchbayCommandTarget.declaredServiceCommand),
         'a declared service command belongs to exactly that target',
       ),
       assert(
         (waitCondition != null) == (_serviceCommand == 'ui.wait'),
         'every ui.wait declaration names the condition it sends, and only '
         'those declarations have one',
       );

  /// Source-compatible façade for navigation enum constants published before
  /// PB-040-06. These values are excluded from the active registry; their
  /// observable properties delegate to the generated descriptor spec.
  const PatchbayFriendlyCommand.compatibility(this._compatibilityProtocol)
    : _serviceCommand = null,
      _path = const <String>[],
      _summary = null,
      _usageSuffix = '',
      artifact = PatchbayArtifactDisposition.none,
      target = PatchbayCommandTarget.declaredServiceCommand,
      waitCondition = null,
      _fencesNavigationRevision = false,
      _isCompatibilityStub = true;

  const PatchbayFriendlyCommand.compatibilityFrozen(
    this._serviceCommand,
    this._path, {
    required String summary,
    String usageSuffix = '',
    this.artifact = PatchbayArtifactDisposition.none,
    this.waitCondition,
    bool fencesNavigationRevision = false,
  }) : _summary = summary,
       _usageSuffix = usageSuffix,
       _fencesNavigationRevision = fencesNavigationRevision,
       _compatibilityProtocol = null,
       _isCompatibilityStub = true,
       target = PatchbayCommandTarget.declaredServiceCommand;

  /// Stable protocol name, or `null` when the target does not declare one:
  /// `exec` takes it from the caller and the client targets are transport
  /// methods rather than catalog commands.
  final String? _serviceCommand;
  final List<String> _path;
  final String? _summary;
  final String _usageSuffix;
  final bool _fencesNavigationRevision;
  final _GeneratedProtocolCommand? _compatibilityProtocol;
  final bool _isCompatibilityStub;

  @override
  String get name {
    final String qualified = toString();
    return qualified.substring(qualified.indexOf('.') + 1);
  }

  @override
  String? get serviceCommand =>
      _compatibilityProtocol?.serviceCommand ?? _serviceCommand;
  @override
  List<String> get path => _compatibilityProtocol?.path ?? _path;
  @override
  String get summary => _compatibilityProtocol?.summary ?? _summary!;
  @override
  String get usageSuffix => _compatibilityProtocol?.usageSuffix ?? _usageSuffix;
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
  bool get fencesNavigationRevision =>
      _compatibilityProtocol?.fencesNavigationRevision ??
      _fencesNavigationRevision;

  @override
  PatchbayCommandDescriptor? get protocolDescriptor =>
      _compatibilityProtocol?.protocolDescriptor;
  @override
  PatchbayCliSyntax? get protocolSyntax =>
      _compatibilityProtocol?.protocolSyntax;

  bool get isCompatibilityStub => _isCompatibilityStub;
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

  final PatchbayFriendlyCommandSpec spec;
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
  /// Complete CLI syntax table: explicit local commands plus generated
  /// protocol-owned commands.
  static List<PatchbayFriendlyCommandSpec> get commands =>
      _patchbayFriendlyCommands;

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
    final PatchbayFriendlyCommandSpec? spec = _match(path);
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
    final Map<String, Object?> arguments;
    if (spec.protocolSyntax != null) {
      arguments = _protocolArguments(spec, tail, options, readSensitiveInput);
    } else {
      arguments = switch (spec) {
        PatchbayFriendlyCommand.identity ||
        PatchbayFriendlyCommand.catalog ||
        PatchbayFriendlyCommand.uiWidgetTree ||
        PatchbayFriendlyCommand.uiRenderTree ||
        PatchbayFriendlyCommand.uiFocusTree ||
        PatchbayFriendlyCommand.networkProfile ||
        PatchbayFriendlyCommand.repl ||
        PatchbayFriendlyCommand.doctor ||
        PatchbayFriendlyCommand.sessionsList ||
        PatchbayFriendlyCommand.sessionsPrune ||
        PatchbayFriendlyCommand.permissionCapabilities ||
        PatchbayFriendlyCommand.tracePrune => _noTail(tail, <String, Object?>{
          if (spec == PatchbayFriendlyCommand.tracePrune)
            'dryRun': options.flag('dry-run'),
        }),
        PatchbayFriendlyCommand.permissionDoctor => _noTail(
          tail,
          const <String, Object?>{},
        ),
        PatchbayFriendlyCommand.traceStart => _noTail(tail, <String, Object?>{
          'name': options.option('name'),
          'activate': options.flag('activate'),
          'pinned': options.flag('pin'),
        }),
        PatchbayFriendlyCommand.traceMark => _atLeastOneTail(
          tail,
          (List<String> words) => <String, Object?>{'note': words.join(' ')},
        ),
        PatchbayFriendlyCommand.traceStop => _zeroOrOneTail(
          tail,
          (String? traceId) => <String, Object?>{'traceId': traceId},
        ),
        PatchbayFriendlyCommand.traceShow ||
        PatchbayFriendlyCommand.traceExport => _oneTail(
          tail,
          (String traceId) => <String, Object?>{
            'traceId': traceId,
            if (spec == PatchbayFriendlyCommand.traceExport)
              'includeArtifacts': options.flag('include-artifacts'),
          },
        ),
        PatchbayFriendlyCommand.traceDiff => _twoTail(
          tail,
          (String before, String after) => <String, Object?>{
            'before': before,
            'after': after,
          },
        ),
        PatchbayFriendlyCommand.describe => _oneTail(
          tail,
          (String command) => <String, Object?>{'command': command},
        ),
        PatchbayFriendlyCommand.launch => <String, Object?>{
          'command': _launchCommand(tail),
        },
        PatchbayFriendlyCommand.performanceProfile =>
          _noTail(tail, <String, Object?>{
            'durationMs': _positiveInt(options, 'duration-ms', fallback: 10000),
            'sampleLimit': _positiveInt(
              options,
              'sample-limit',
              fallback: 10000,
            ),
          }),
        // An omitted `--path` produces no arguments at all, which is what makes
        // the whole-snapshot read stay exactly the request it always was.
        PatchbayFriendlyCommand.snapshot => _noTail(tail, <String, Object?>{
          if (options.option('path') case final String path) 'path': path,
        }),
        PatchbayFriendlyCommand.snapshotWait => _snapshotWaitArguments(
          tail,
          options,
        ),
        PatchbayFriendlyCommand.snapshotDiff => _noTail(tail, <String, Object?>{
          'fromRevision':
              _optionalPositiveInt(options, 'from') ??
              (throw const FormatException(
                'snapshot diff requires --from <revision>',
              )),
        }),
        PatchbayFriendlyCommand.sessionUse => _sessionUseArguments(
          tail,
          options,
        ),
        PatchbayFriendlyCommand.permissionStatus ||
        PatchbayFriendlyCommand.permissionReset => _oneTail(
          tail,
          (String permission) => <String, Object?>{'permission': permission},
        ),
        PatchbayFriendlyCommand.permissionNormalize ||
        PatchbayFriendlyCommand.permissionFail => _oneTail(
          tail,
          (String permission) => <String, Object?>{
            'permission': permission,
            'state': _requiredOption(options, 'state'),
          },
        ),
        PatchbayFriendlyCommand.permissionExercise => _oneTail(
          tail,
          (String permission) => <String, Object?>{
            'permission': permission,
            'decision': _requiredOption(options, 'decision'),
          },
        ),
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
        PatchbayFriendlyCommand.uiTargets => _noTail(
          tail,
          options.flag('emit-manifest')
              ? const <String, Object?>{}
              : throw const FormatException(
                  '--emit-manifest is required for ui targets',
                ),
        ),
        // `ttlMs` travels only with the enable: it is the lease on a switch that
        // is on, so sending it alongside `enabled: false` is a request the App
        // refuses rather than a value it would have to ignore.
        PatchbayFriendlyCommand.uiInspectOn => _noTail(tail, <String, Object?>{
          'enabled': true,
          'ttlMs': ?_optionalPositiveInt(options, 'ttl-ms'),
        }),
        PatchbayFriendlyCommand.uiInspectOff => _noTail(
          tail,
          const <String, Object?>{'enabled': false},
        ),
        PatchbayFriendlyCommand.uiInspectStatus => _noTail(
          tail,
          const <String, Object?>{},
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
        PatchbayFriendlyCommand.logsQuery ||
        PatchbayFriendlyCommand.logsTail ||
        PatchbayFriendlyCommand.logsExport ||
        PatchbayFriendlyCommand.captureRoot => _noTail(
          tail,
          _argumentsWithoutPositionals(spec, options),
        ),
        // `on` and `off` are two spellings of one protocol command, so the flag
        // is set here rather than typed by the operator: `keep-awake off` cannot
        // be turned into an accidental engagement by a stray argument.
        PatchbayFriendlyCommand.uiKeepAwakeOn => _noTail(tail, <
          String,
          Object?
        >{
          'enabled': true,
          // Omitted rather than defaulted CLI-side: the lease default is the
          // App's, published in the catalog descriptor, and a second copy here
          // would be the one that goes stale.
          'leaseMs': ?_optionalPositiveInt(options, 'lease-ms'),
        }),
        PatchbayFriendlyCommand.uiKeepAwakeOff => _noTail(
          tail,
          const <String, Object?>{'enabled': false},
        ),
        PatchbayFriendlyCommand.uiKeepAwakeStatus => _noTail(
          tail,
          const <String, Object?>{},
        ),
        // `revision` is left out when the caller omitted it: the dispatcher fills
        // it in from `navigation.current` before the request goes out, so the
        // fence still travels — it is just no longer a manual round trip.
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
        PatchbayFriendlyCommand.captureDiff => _twoTail(
          tail,
          (String beforeBlobId, String afterBlobId) => <String, Object?>{
            'beforeBlobId': beforeBlobId,
            'afterBlobId': afterBlobId,
          },
        ),
        PatchbayFriendlyCommand.blobGet ||
        PatchbayFriendlyCommand.blobMetadata => _oneTail(
          tail,
          (String blobId) => <String, Object?>{'blobId': blobId},
        ),
        _ => throw StateError(
          'generated protocol command missed generic parser',
        ),
      };
    }
    final bool writesArtifact =
        spec.artifact != PatchbayArtifactDisposition.none;
    final bool writesTraceExport = spec == PatchbayFriendlyCommand.traceExport;
    final String? outputPath = options.option('output');
    if ((writesArtifact || writesTraceExport) &&
        (outputPath == null || outputPath.isEmpty)) {
      throw const FormatException('--output is required for this command');
    }
    if (!writesArtifact && !writesTraceExport && outputPath != null) {
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
  static PatchbayFriendlyCommandSpec? specFor(List<String> words) =>
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
        for (final PatchbayFriendlyCommandSpec spec in commands)
          if (spec.waitCondition case final String condition)
            _PathAlias(<String>[
              ...spec.path.take(spec.path.length - 1),
              condition,
            ], spec.path),
        // `sessions` and `session` differ by one letter and both read as the
        // group an operator wants, so either spelling reaches the declared
        // path. As with every alias here, these expand into paths that already
        // exist and add no command.
        const _PathAlias(
          <String>['session', 'list'],
          <String>['sessions', 'list'],
        ),
        const _PathAlias(
          <String>['session', 'prune'],
          <String>['sessions', 'prune'],
        ),
        const _PathAlias(
          <String>['sessions', 'use'],
          <String>['session', 'use'],
        ),
        const _PathAlias(<String>['navigate'], <String>['navigation']),
        const _PathAlias(<String>['nav'], <String>['navigation']),
        const _PathAlias(<String>['wait'], <String>['ui', 'wait']),
        const _PathAlias(<String>['tap'], <String>['ui', 'tap']),
        const _PathAlias(<String>['keep-awake'], <String>['ui', 'keep-awake']),
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

  static PatchbayFriendlyCommandSpec? _match(List<String> words) {
    PatchbayFriendlyCommandSpec? result;
    for (final PatchbayFriendlyCommandSpec candidate in commands) {
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
    PatchbayFriendlyCommandSpec spec,
    ArgResults options,
  ) {
    final Set<String> allowed = allowedOptions(spec);
    const Set<String> friendlyOptions = <String>{
      'args',
      'stdin',
      'path',
      'revision',
      'generation',
      'start',
      'gesture-path',
      'velocity',
      'duration-ms',
      'timeout-ms',
      'cursor',
      'direction',
      'limit',
      'levels',
      'categories',
      'since',
      'until',
      'ttl-ms',
      'lease-ms',
      'pixel-ratio',
      'after-frames',
      'output',
      'force',
      'clear',
      'permission-driver',
      'device-id',
      'application-id',
      'state',
      'decision',
      'confirm-system-permission',
      'emit-manifest',
      'navigate',
      'continue-on-error',
      'restore',
      'screen-timeout-ms',
      'total-timeout-ms',
      'name',
      'activate',
      'pin',
      'dry-run',
      'include-artifacts',
      'sample-limit',
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
    if (spec == PatchbayFriendlyCommand.uiVerifyManifest &&
        !options.flag('navigate') &&
        (options.flag('continue-on-error') ||
            options.flag('restore') ||
            options.wasParsed('screen-timeout-ms') ||
            options.wasParsed('total-timeout-ms'))) {
      throw const FormatException(
        '--continue-on-error, --restore and walkthrough timeouts require '
        '--navigate',
      );
    }
  }

  static String _requiredOption(ArgResults options, String name) {
    final String? value = options.option(name);
    if (value == null || value.isEmpty) {
      throw FormatException('--$name is required for this command');
    }
    return value;
  }

  /// CLI options accepted by [spec]. Help and validation share this mapping.
  static Set<String> allowedOptions(PatchbayFriendlyCommandSpec spec) {
    if (spec.protocolSyntax case final PatchbayCliSyntax syntax) {
      return <String>{
        ...syntax.optionParameters.values,
        if (syntax.inputMode == PatchbayCliInputMode.mergedJsonObject) 'args',
        if (syntax.stdinParameter != null ||
            syntax.inputMode == PatchbayCliInputMode.mergedJsonObject)
          'stdin',
        if (syntax.artifactDisposition !=
            PatchbayCliArtifactDisposition.none) ...<String>{'output', 'force'},
      };
    }
    return switch (spec) {
      PatchbayFriendlyCommand.identity ||
      PatchbayFriendlyCommand.catalog ||
      PatchbayFriendlyCommand.describe ||
      PatchbayFriendlyCommand.jobGet ||
      PatchbayFriendlyCommand.jobCancel ||
      PatchbayFriendlyCommand.uiWidgetTree ||
      PatchbayFriendlyCommand.uiRenderTree ||
      PatchbayFriendlyCommand.uiFocusTree ||
      PatchbayFriendlyCommand.networkProfile ||
      PatchbayFriendlyCommand.captureDiff ||
      PatchbayFriendlyCommand.uiInspectOff ||
      PatchbayFriendlyCommand.uiInspectStatus ||
      PatchbayFriendlyCommand.blobMetadata ||
      // A repl carries connection options and `--json`, which are global rather
      // than per-command; every command option belongs on the lines it runs.
      PatchbayFriendlyCommand.repl ||
      // `--session-dir` selects which directory these read, and it is global.
      PatchbayFriendlyCommand.sessionsList ||
      PatchbayFriendlyCommand.sessionsPrune ||
      // Doctor runs a fixed set of checks: there is nothing per-command to
      // configure, and the RPC budget it runs under is the global
      // `--transport-timeout-ms` every other command already uses.
      PatchbayFriendlyCommand.doctor ||
      // A release takes no lease, and a read takes nothing at all.
      PatchbayFriendlyCommand.uiKeepAwakeOff ||
      PatchbayFriendlyCommand.uiKeepAwakeStatus => const <String>{},
      PatchbayFriendlyCommand.uiVerifyManifest => const <String>{
        'navigate',
        'continue-on-error',
        'restore',
        'screen-timeout-ms',
        'total-timeout-ms',
      },
      PatchbayFriendlyCommand.uiTargets => const <String>{'emit-manifest'},
      PatchbayFriendlyCommand.permissionCapabilities ||
      PatchbayFriendlyCommand.permissionStatus ||
      PatchbayFriendlyCommand.permissionDoctor ||
      PatchbayFriendlyCommand.permissionReset => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.permissionNormalize ||
      PatchbayFriendlyCommand.permissionFail => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
        'state',
      },
      PatchbayFriendlyCommand.permissionExercise => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
        'decision',
        'confirm-system-permission',
      },
      PatchbayFriendlyCommand.traceStart => const <String>{
        'name',
        'activate',
        'pin',
      },
      PatchbayFriendlyCommand.traceMark ||
      PatchbayFriendlyCommand.traceStop ||
      PatchbayFriendlyCommand.traceShow => const <String>{},
      PatchbayFriendlyCommand.traceExport => const <String>{
        'output',
        'include-artifacts',
      },
      PatchbayFriendlyCommand.traceDiff => const <String>{},
      PatchbayFriendlyCommand.tracePrune => const <String>{'dry-run'},
      PatchbayFriendlyCommand.launch => const <String>{'keep-awake'},
      PatchbayFriendlyCommand.performanceProfile => const <String>{
        'duration-ms',
        'sample-limit',
      },
      PatchbayFriendlyCommand.uiKeepAwakeOn => const <String>{'lease-ms'},
      PatchbayFriendlyCommand.snapshot => const <String>{'path'},
      PatchbayFriendlyCommand.snapshotWait => const <String>{
        'until',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.snapshotDiff => const <String>{'from'},
      PatchbayFriendlyCommand.sessionUse => const <String>{'clear'},
      PatchbayFriendlyCommand.exec || PatchbayFriendlyCommand.uiSemanticsTree =>
        const <String>{'args', 'stdin'},
      PatchbayFriendlyCommand.uiTextSet ||
      PatchbayFriendlyCommand.uiTextEnter ||
      PatchbayFriendlyCommand.uiSemanticsAction => const <String>{'stdin'},
      PatchbayFriendlyCommand.uiTap => const <String>{'generation'},
      PatchbayFriendlyCommand.uiInspectOn => const <String>{'ttl-ms'},
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
        'after-frames',
        'timeout-ms',
        'output',
        'force',
      },
      PatchbayFriendlyCommand.blobGet => const <String>{'output', 'force'},
      _ => throw StateError('generated protocol command bypassed metadata'),
    };
  }

  static Map<String, Object?> _argumentsWithoutPositionals(
    PatchbayFriendlyCommandSpec spec,
    ArgResults options,
  ) => switch (spec) {
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

  static Map<String, Object?> _protocolArguments(
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
      return _domainArguments(options, readSensitiveInput);
    }
    final int fixedCount = syntax.positionalParameters.length;
    if (tail.length < fixedCount ||
        syntax.trailingParameter == null && tail.length != fixedCount) {
      throw FormatException(
        '${spec.path.join(' ')} requires $fixedCount '
        'positional argument(s)',
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
      arguments[name] = _protocolValue(
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
        arguments[binding.key] = _protocolValue(
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

  static Object _protocolValue(
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

  /// `snapshot wait <dot.path> --until <condition> [<json-value>]`.
  ///
  /// The condition is a flag rather than a subcommand because it is not the
  /// thing being addressed — the path is — and only `equals` carries a value.
  /// The value is read as a **JSON literal**, so `true` is a boolean and a
  /// string has to be quoted: a snapshot field is typed JSON, and guessing that
  /// a bare word means a string would silently answer a different question than
  /// the one asked against a field that really does hold `"true"`.
  static Map<String, Object?> _snapshotWaitArguments(
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
      if (comparing) 'value': _jsonLiteral(tail[1]),
      'timeoutMs': _positiveInt(options, 'timeout-ms', fallback: 5000),
    };
  }

  static List<String> _launchCommand(List<String> tail) {
    if (tail.isEmpty) {
      throw const FormatException('launch requires -- <consumer command>');
    }
    return List<String>.unmodifiable(tail);
  }

  /// One JSON literal from the command line, refused rather than guessed at.
  ///
  /// The error names the fix because the failing case is always the same one:
  /// an unquoted word that JSON reads as nothing.
  static Object? _jsonLiteral(String encoded) {
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
      // JSON has no way to say "explicitly absent", and the whole protocol
      // reads a null as a value that is not there — which is what `absent`
      // already asks about, without pretending null is a value to match.
      throw const FormatException(
        'the compared value must not be null: use --until absent instead',
      );
    }
    return decoded;
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
        if (_optionalPositiveInt(options, 'after-frames') case final int frames)
          'afterFrames': frames,
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

  static Map<String, Object?> _zeroOrOneTail(
    List<String> tail,
    Map<String, Object?> Function(String?) build,
  ) {
    if (tail.length > 1) {
      throw const FormatException('command accepts at most one argument');
    }
    return build(tail.isEmpty ? null : tail.single);
  }

  static Map<String, Object?> _atLeastOneTail(
    List<String> tail,
    Map<String, Object?> Function(List<String>) build,
  ) {
    if (tail.isEmpty) {
      throw const FormatException('command requires an argument');
    }
    return build(tail);
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
