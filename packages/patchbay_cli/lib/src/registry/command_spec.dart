import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';

import 'output_projection_declarations.dart';

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

  /// The restricted path to this command's one unbounded response member;
  /// `null` means it does not participate in local-artifact spilling.
  ///
  /// Only meaningful when [artifact] is
  /// [PatchbayArtifactDisposition.renderedMember]. PB-050-40 made this a
  /// derived reading of the command's `outputProjection`, so it is now a
  /// restricted projection path against the document this command would
  /// otherwise print — `$.payload.nodes` for `ui semantics tree`, `$.data`
  /// for the Flutter diagnostic tree passthroughs — rather than a bare dot
  /// path maintained beside the disposition.
  String? get spilledMember;
}

/// Generated protocol command adapter implementing [PatchbayFriendlyCommandSpec].
final class GeneratedProtocolCommand
    implements PatchbayFriendlyCommandSpec, PatchbayLocallyProjectedCommand {
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

  /// F8 (PB-050-20 follow-up): a spelling that spills a rendered member
  /// accepts `--output`, `--force` and `--max-inline-bytes` exactly the way
  /// the `uiWidgetTree`/`uiRenderTree`/`uiFocusTree` declarations in
  /// `friendly_commands.dart` do — `friendly_command_registry.dart`'s
  /// `allowedOptions` grants all three whenever [artifact] is
  /// `renderedMember` — but the wire-declared `syntax.usageSuffix` cannot know
  /// which rendering the CLI will pick. PB-050-40 keys this off the resolved
  /// disposition rather than off the literal service name it used to compare
  /// against, so `ui semantics tree` reads its declaration like every other
  /// command instead of being a name special case.
  @override
  String get usageSuffix {
    if (artifact == PatchbayArtifactDisposition.renderedMember) {
      return '[--output <path>] [--force] [--max-inline-bytes <n>]';
    }
    return syntax.usageSuffix;
  }

  /// PB-050-40: a generated spelling carries no CLI-local declaration of its
  /// own. Its projection is the service descriptor's — read from the live host
  /// catalog at render time, and from the frozen 0.5.0 table here, which is
  /// all the option surface can consult while argv is still being parsed.
  @override
  PatchbayOutputProjection? get localOutputProjection => null;

  @override
  PatchbayArtifactDisposition get artifact =>
      patchbayDispositionOf(patchbayStaticOutputProjection(this));

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
  String? get spilledMember =>
      patchbayStaticOutputProjection(this)?.artifact?.member;
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
