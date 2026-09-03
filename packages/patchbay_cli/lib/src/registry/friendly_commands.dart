import 'package:patchbay/patchbay_protocol.dart';

import 'command_spec.dart';
import 'output_projection_declarations.dart';

/// PB-050-40: the diagnostic-tree passthroughs' shared declaration.
///
/// `ui widget-tree` / `render-tree` / `focus-tree` are CLI-local: they are
/// Flutter SDK service extensions the CLI calls directly, so no host catalog
/// row can ever carry their declaration. They still use the same
/// [PatchbayOutputProjection] type and the same interpreter as a protocol
/// command — the proposal's rule that a non-protocol command is not a second
/// projection model, only a declaration with nowhere on the wire to live.
///
/// `data` is both the member that spills and the member brief deletes. The
/// interpreter runs the artifact first, so a spilled response keeps the
/// receipt and reports no deletion for it.
///
/// The encoding is [PatchbayOutputArtifactEncoding.jsonOrDecodedText] because
/// `docs/proposals/0.5.0/tree-artifact-output.md` fixed it that way: the same
/// command answers with inspector JSON on one Flutter build and with a
/// `debugDumpApp` text dump on another, and that proposal rules that storing
/// the text dump as a quoted JSON string is a fake artifact. That value is
/// CLI-local only and is never published in a catalog row — see its own
/// comment in `package:patchbay`.
const PatchbayOutputProjection _diagnosticTreeProjection =
    PatchbayOutputProjection(
      brief: PatchbayOutputBriefProjection(
        id: 'diagnosticTree',
        omit: <String>[r'$.data'],
      ),
      artifact: PatchbayOutputArtifactProjection.renderedMember(
        member: r'$.data',
        encoding: PatchbayOutputArtifactEncoding.jsonOrDecodedText,
      ),
    );

const GeneratedProtocolCommand _navigationCatalogProtocolCommand =
    GeneratedProtocolCommand(
      descriptor: patchbayNavigationCatalogCommandDescriptor,
      serviceName: 'navigation.catalog',
      syntaxIndex: 0,
    );

const GeneratedProtocolCommand _navigationCurrentProtocolCommand =
    GeneratedProtocolCommand(
      descriptor: patchbayNavigationCurrentCommandDescriptor,
      serviceName: 'navigation.current',
      syntaxIndex: 0,
    );

const GeneratedProtocolCommand _navigationGoProtocolCommand =
    GeneratedProtocolCommand(
      descriptor: patchbayNavigationGoCommandDescriptor,
      serviceName: 'navigation.go',
      syntaxIndex: 0,
    );

const GeneratedProtocolCommand _navigationPushProtocolCommand =
    GeneratedProtocolCommand(
      descriptor: patchbayNavigationPushCommandDescriptor,
      serviceName: 'navigation.push',
      syntaxIndex: 0,
    );

const GeneratedProtocolCommand _navigationBackProtocolCommand =
    GeneratedProtocolCommand(
      descriptor: patchbayNavigationBackCommandDescriptor,
      serviceName: 'navigation.back',
      syntaxIndex: 0,
    );

/// Explicit declarations for local and client-only CLI commands.
enum PatchbayFriendlyCommand
    implements PatchbayFriendlyCommandSpec, PatchbayLocallyProjectedCommand {
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
    // PB-050-40: `catalog` answers from the client handshake, not from a
    // cataloged command, so its declaration is CLI-local by necessity.
    // `summary` is deliberately absent from the deny-list (the 2026-08-25
    // ruling on brief-view.md's open question 3): it is the only clue an
    // agent has about what a command does before it spends a `describe`.
    localOutputProjection: PatchbayOutputProjection(
      brief: PatchbayOutputBriefProjection(
        id: 'catalog',
        omit: <String>[
          r'$.commands[].parameters',
          r'$.commands[].responseSchema',
          r'$.commands[].executionContract',
          r'$.commands[].retryPolicy',
        ],
      ),
    ),
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
  sessionRegister(
    null,
    <String>['session', 'register'],
    summary:
        'Record an App this checkout started itself, so later commands '
        'discover it without --ws-uri.',
    usageSuffix:
        '--ws-uri <uri> --application-id <id> --device-id <id> '
        '--process-id <pid> [<session-id>]',
    target: PatchbayCommandTarget.localSessionStore,
  ),
  sessionUnregister(
    null,
    <String>['session', 'unregister'],
    summary: 'Remove one session record by id, without dialling the App.',
    usageSuffix: '<session-id>',
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
  // Never matched: `_patchbayFriendlyCommands` filters every
  // `.compatibilityFrozen` stub out, so path resolution for `ui semantics
  // tree` always lands on the generated `_uiSemanticsTreeProtocolCommand`
  // instead. Its projection therefore comes from the `ui.semantics.tree`
  // descriptor — the host's declaration at render time, the frozen 0.5.0
  // entry when the host publishes none — and not from a declaration here.
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
    usageSuffix: '[--output <path>] [--force] [--max-inline-bytes <n>]',
    target: PatchbayCommandTarget.clientWidgetTree,
    localOutputProjection: _diagnosticTreeProjection,
  ),
  uiRenderTree(
    null,
    <String>['ui', 'render-tree'],
    summary: 'Read the Flutter render tree diagnostic (SDK passthrough).',
    usageSuffix: '[--output <path>] [--force] [--max-inline-bytes <n>]',
    target: PatchbayCommandTarget.clientRenderTree,
    localOutputProjection: _diagnosticTreeProjection,
  ),
  uiFocusTree(
    null,
    <String>['ui', 'focus-tree'],
    summary: 'Read the Flutter focus tree diagnostic (SDK passthrough).',
    usageSuffix: '[--output <path>] [--force] [--max-inline-bytes <n>]',
    target: PatchbayCommandTarget.clientFocusTree,
    localOutputProjection: _diagnosticTreeProjection,
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
    // PB-050-40: `logs.export` also declares this on its descriptor. The
    // spelling repeats it because the CLI has to know which options to accept
    // before it has a catalog to read.
    localOutputProjection: PatchbayOutputProjection(
      artifact: PatchbayOutputArtifactProjection.payloadBlob(),
    ),
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  captureRoot.compatibilityFrozen(
    'ui.capture',
    <String>['capture', 'root'],
    summary: 'Capture the Flutter root repaint boundary.',
    usageSuffix: '--output <path>',
    localOutputProjection: PatchbayOutputProjection(
      artifact: PatchbayOutputArtifactProjection.payloadBlob(),
    ),
  ),
  @Deprecated('Use PatchbayFriendlyCommandRegistry.commands by path.')
  captureTarget.compatibilityFrozen(
    'ui.capture',
    <String>['capture', 'target'],
    summary: 'Capture a registered Flutter UI target.',
    usageSuffix: '<target-id> <generation> --output <path>',
    localOutputProjection: PatchbayOutputProjection(
      artifact: PatchbayOutputArtifactProjection.payloadBlob(),
    ),
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
    // PB-050-40: this artifact belongs to the *spelling*, not to
    // `blob.metadata`: `blob metadata` calls the same service command and must
    // keep answering with metadata only. That is why the declaration is
    // CLI-local and why `blob.metadata`'s descriptor deliberately carries none.
    localOutputProjection: PatchbayOutputProjection(
      artifact: PatchbayOutputArtifactProjection.responseBlob(),
    ),
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
    this.localOutputProjection,
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

  const PatchbayFriendlyCommand.compatibility(this._compatibilityProtocol)
    : _serviceCommand = null,
      _path = const <String>[],
      _summary = null,
      _usageSuffix = '',
      localOutputProjection = null,
      target = PatchbayCommandTarget.declaredServiceCommand,
      waitCondition = null,
      _fencesNavigationRevision = false,
      _isCompatibilityStub = true;

  const PatchbayFriendlyCommand.compatibilityFrozen(
    this._serviceCommand,
    this._path, {
    required String summary,
    String usageSuffix = '',
    this.localOutputProjection,
    this.waitCondition,
    bool fencesNavigationRevision = false,
  }) : _summary = summary,
       _usageSuffix = usageSuffix,
       _fencesNavigationRevision = fencesNavigationRevision,
       _compatibilityProtocol = null,
       _isCompatibilityStub = true,
       target = PatchbayCommandTarget.declaredServiceCommand;

  final String? _serviceCommand;
  final List<String> _path;
  final String? _summary;
  final String _usageSuffix;
  final bool _fencesNavigationRevision;
  final GeneratedProtocolCommand? _compatibilityProtocol;
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

  /// PB-050-40: this spelling's own projection declaration, when it owns one.
  ///
  /// Non-null for exactly the commands no host catalog can describe (`catalog`,
  /// the three Flutter diagnostic trees) and the one spelling whose artifact is
  /// not a property of its service command (`blob get`). Everything else reads
  /// the service descriptor.
  @override
  final PatchbayOutputProjection? localOutputProjection;

  /// Derived from [localOutputProjection] and the frozen 0.5.0 fallback: the
  /// disposition is no longer a second hand-maintained fact beside the
  /// declaration, it is a reading of it.
  @override
  PatchbayArtifactDisposition get artifact =>
      patchbayDispositionOf(patchbayStaticOutputProjection(this));

  @override
  final PatchbayCommandTarget target;
  @override
  final String? waitCondition;

  @override
  String? get spilledMember =>
      patchbayStaticOutputProjection(this)?.artifact?.member;

  @override
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
