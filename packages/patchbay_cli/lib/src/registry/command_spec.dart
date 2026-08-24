import 'package:patchbay/patchbay.dart';

enum PatchbayArtifactDisposition { none, payloadBlob, responseBlob }

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
  localTraceStore(PatchbayCommandDeclarationSource.local);

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
}
