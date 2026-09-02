import 'package:patchbay/patchbay.dart';

enum PatchbayArtifactDisposition {
  none,
  payloadBlob,
  responseBlob,
  renderedMember,
}

/// Where a CLI-only command declaration is implemented.
enum PatchbayCommandDeclarationSource { client, local }

/// Abstract interface for a friendly CLI command specification.
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

  /// The dot path to this command's one unbounded response member; `null`
  /// means it does not participate in local-artifact spilling.
  ///
  /// Only meaningful when [artifact] is
  /// [PatchbayArtifactDisposition.renderedMember]. The path is declared
  /// against the document this command would otherwise print, e.g.
  /// `payload.nodes` for `ui semantics tree` or `data` for the Flutter
  /// diagnostic tree passthroughs.
  String? get spilledMember;
}

/// Generated protocol command adapter implementing [PatchbayFriendlyCommandSpec].
final class GeneratedProtocolCommand implements PatchbayFriendlyCommandSpec {
  const GeneratedProtocolCommand({
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

  /// F8 (PB-050-20 follow-up): `ui semantics tree` accepts `--output`,
  /// `--force` and `--max-inline-bytes` exactly the way the plain
  /// `uiWidgetTree`/`uiRenderTree`/`uiFocusTree` declarations in
  /// `friendly_commands.dart` do — `friendly_command_registry.dart`'s
  /// `allowedOptions` already grants all three whenever [artifact] is
  /// `renderedMember` — but the wire-declared `syntax.usageSuffix` has no way
  /// to know about this CLI-only PB-050-20 decision, the same reason
  /// [artifact] below cannot live on the wire descriptor either. This
  /// literal is deliberately kept identical to those three siblings' own
  /// `usageSuffix` so a `--help ui semantics tree` line reads the same way
  /// theirs does.
  @override
  String get usageSuffix {
    if (serviceName == _renderedMemberServiceCommand) {
      return '[--output <path>] [--force] [--max-inline-bytes <n>]';
    }
    return syntax.usageSuffix;
  }

  /// PB-050-20: `ui semantics tree`'s only reachable CLI declaration is this
  /// generated wrapper. `PatchbayFriendlyCommand.uiSemanticsTree` is a
  /// `.compatibilityFrozen` stub, and `_patchbayFriendlyCommands` filters
  /// every stub out before path matching ever runs, so `renderedMember`
  /// cannot live on the friendly enum entry the way it does for
  /// `ui widget-tree` / `render-tree` / `focus-tree` (plain, non-stub
  /// declarations). The wire descriptor's own `cliSyntax.artifactDisposition`
  /// deliberately stays `none` — this is a CLI-only rendering decision, not a
  /// protocol change (see docs/proposals/0.5.0/tree-artifact-output.md,
  /// "判定位置：CLI 侧", reason 4).
  static const String _renderedMemberServiceCommand = 'ui.semantics.tree';
  static const String _renderedMemberSpilledMember = 'payload.nodes';

  @override
  PatchbayArtifactDisposition get artifact {
    if (serviceName == _renderedMemberServiceCommand) {
      return PatchbayArtifactDisposition.renderedMember;
    }
    return switch (syntax.artifactDisposition) {
      PatchbayCliArtifactDisposition.none => PatchbayArtifactDisposition.none,
      PatchbayCliArtifactDisposition.payloadBlob =>
        PatchbayArtifactDisposition.payloadBlob,
      PatchbayCliArtifactDisposition.responseBlob =>
        PatchbayArtifactDisposition.responseBlob,
    };
  }

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
  @override
  String? get spilledMember => serviceName == _renderedMemberServiceCommand
      ? _renderedMemberSpilledMember
      : null;
}

/// What the CLI actually calls once a declared path has been resolved.
enum PatchbayCommandTarget {
  declaredServiceCommand(PatchbayCommandDeclarationSource.client),
  callerServiceCommand(PatchbayCommandDeclarationSource.client),
  clientIdentity(PatchbayCommandDeclarationSource.client),
  clientCatalog(PatchbayCommandDeclarationSource.client),
  localCatalogDescription(PatchbayCommandDeclarationSource.local),
  clientSnapshot(PatchbayCommandDeclarationSource.client),
  clientWidgetTree(PatchbayCommandDeclarationSource.client),
  clientRenderTree(PatchbayCommandDeclarationSource.client),
  clientFocusTree(PatchbayCommandDeclarationSource.client),
  clientPerformanceProfile(PatchbayCommandDeclarationSource.client),
  clientNetworkProfile(PatchbayCommandDeclarationSource.client),
  localManifestVerification(PatchbayCommandDeclarationSource.local),
  localManifestEmission(PatchbayCommandDeclarationSource.local),
  clientReplSession(PatchbayCommandDeclarationSource.client),
  localSessionStore(PatchbayCommandDeclarationSource.local),
  localLauncher(PatchbayCommandDeclarationSource.local),
  localDiagnostics(PatchbayCommandDeclarationSource.local),
  localPermissionDriver(PatchbayCommandDeclarationSource.local),
  localTraceStore(PatchbayCommandDeclarationSource.local),
  routedServiceCommand(PatchbayCommandDeclarationSource.local);

  const PatchbayCommandTarget(this.declarationSource);

  final PatchbayCommandDeclarationSource declarationSource;
}

/// A command line that matched one friendly declaration.
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
    this.localRoute,
  });

  final PatchbayFriendlyCommandSpec spec;
  final Map<String, Object?> arguments;

  /// Resolved protocol name for the invoke targets; `null` for client targets.
  final String? serviceCommand;
  final String? outputPath;

  /// Local file the command reads before it talks to the App.
  final String? manifestPath;
  final bool force;
  final Set<String> plaintextArgumentKeys;
  final bool resolvesRevision;

  /// CLI-only routing facts for canonical commands. Host fields stay at the
  /// response root unchanged; the dispatcher adds this map beside them.
  final Map<String, Object?>? localRoute;
}
