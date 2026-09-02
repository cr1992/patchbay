import 'dart:convert';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../command_help.dart';
import '../command_registry.dart';
import '../output/output_formatter.dart';
import '../performance_profile.dart';
import '../result.dart';
import '../runners/manifest_runner.dart';
import '../runners/snapshot_runner.dart';
import '../ui_manifest.dart';
import 'catalog_invoker.dart';

/// Dispatches one resolved declaration against a connection.
abstract final class CommandDispatcher {
  /// Dispatches one resolved declaration.
  static Future<ExecutionResult> execute(
    PatchbayClient connection,
    ArgResults parsed, {
    PatchbayUiManifest? manifest,
  }) async {
    final PatchbayFriendlyInvocation? friendly =
        PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
    if (friendly == null) {
      throw FormatException(PatchbayCommandHelp.usageLine());
    }
    switch (friendly.spec.target) {
      case PatchbayCommandTarget.clientIdentity:
        return ExecutionResult(await connection.identity());
      case PatchbayCommandTarget.clientCatalog:
        return ExecutionResult(await connection.catalog());
      case PatchbayCommandTarget.localCatalogDescription:
        return ExecutionResult(
          CatalogInvoker.describeCatalogCommand(
            await connection.catalog(),
            friendly.arguments['command']! as String,
          ),
        );
      case PatchbayCommandTarget.clientSnapshot:
        if (friendly.spec == PatchbayFriendlyCommand.snapshotDiff) {
          return ExecutionResult(
            await SnapshotRunner.snapshotDiff(
              connection,
              friendly.arguments['fromRevision']! as int,
            ),
          );
        }
        final PatchbaySnapshotRequest? selection = _selection(friendly);
        return ExecutionResult(
          selection == null
              ? await connection.snapshot()
              : await SnapshotRunner.selectedSnapshot(connection, selection),
        );
      case PatchbayCommandTarget.clientWidgetTree:
        return ExecutionResult(await connection.widgetTree());
      case PatchbayCommandTarget.clientRenderTree:
        return ExecutionResult(await connection.renderTree());
      case PatchbayCommandTarget.clientFocusTree:
        return ExecutionResult(await connection.focusTree());
      case PatchbayCommandTarget.clientPerformanceProfile:
        final PatchbayProfilingClient profiling = profilingClient(
          connection,
          capability: 'performanceProfile',
        );
        final PatchbayPerformanceProfileRequest request =
            PatchbayPerformanceProfileRequest(
              duration: Duration(
                milliseconds: friendly.arguments['durationMs']! as int,
              ),
              eventLimit: friendly.arguments['sampleLimit']! as int,
            );
        request.validate();
        return ExecutionResult(await profiling.performanceProfile(request));
      case PatchbayCommandTarget.clientNetworkProfile:
        return ExecutionResult(
          await profilingClient(
            connection,
            capability: 'networkProfile',
          ).networkProfile(),
        );
      case PatchbayCommandTarget.localManifestVerification:
        final PatchbayUiManifest verified =
            manifest ?? CatalogInvoker.readUiManifest(friendly.manifestPath!);
        final Map<String, Object?> catalog = await connection.catalog();
        if (parsed.flag('navigate')) {
          return walkUiManifest(connection, catalog, verified, parsed);
        }
        return verifyManifestCurrent(connection, catalog, verified);
      case PatchbayCommandTarget.localManifestEmission:
        final Map<String, Object?> catalog = await connection.catalog();
        final Map<String, Object?> current =
            await CatalogInvoker.invokeAgainstCatalog(
              connection,
              catalog,
              'navigation.current',
              const <String, Object?>{},
            );
        if (current['admission'] == 'rejected') {
          return ExecutionResult(
            CatalogInvoker.withSource(current, 'destinationSource'),
            catalog: catalog,
          );
        }
        final String? destination = CatalogInvoker.navigationDestination(
          current,
        );
        if (destination == null || destination.isEmpty) {
          throw const PatchbayProtocolException(
            'manifestDestinationUnavailable',
            details: <String, Object?>{
              'reason':
                  'navigation.current did not report a settled destination; '
                  'the CLI will not invent one for a manifest draft',
            },
          );
        }
        PatchbayUiManifestSemanticsRuntime? semantics;
        if (CatalogCommandDescriptor.find(catalog, 'ui.semantics.tree') !=
            null) {
          final Map<String, Object?> observed =
              await CatalogInvoker.invokeAgainstCatalog(
                connection,
                catalog,
                'ui.semantics.tree',
                const <String, Object?>{},
              );
          if (observed['admission'] == 'rejected') {
            return ExecutionResult(
              CatalogInvoker.withSource(observed, 'semanticsSource'),
              catalog: catalog,
            );
          }
          semantics = CatalogInvoker.manifestSemanticsRuntime(observed);
        }
        final Map<String, Object?> draft = emitPatchbayMountedUiManifest(
          runtime: decodePatchbayCatalogUiTargets(catalog),
          destination: destination,
          semantics: semantics,
        );
        return ExecutionResult(
          draft,
          catalog: catalog,
          exitCode: PatchbayExitCode.accepted,
          summary: const JsonEncoder.withIndent('  ').convert(draft),
        );
      case PatchbayCommandTarget.clientReplSession:
        throw StateError('repl is a session, not a dispatchable command');
      case PatchbayCommandTarget.localSessionStore:
        throw StateError('session-directory commands run without a connection');
      case PatchbayCommandTarget.localTraceStore:
        throw StateError('trace-store commands run without a connection');
      case PatchbayCommandTarget.localLauncher:
        throw StateError('launcher runs without a connection');
      case PatchbayCommandTarget.localDiagnostics:
        throw StateError('doctor owns its own connection');
      case PatchbayCommandTarget.localPermissionDriver:
        throw StateError('permission commands own their external driver');
      case PatchbayCommandTarget.declaredServiceCommand:
      case PatchbayCommandTarget.callerServiceCommand:
      case PatchbayCommandTarget.routedServiceCommand:
        final String command = friendly.serviceCommand!;
        final Map<String, Object?> catalog = await connection.catalog();
        CatalogInvoker.refuseSensitiveArgv(
          catalog,
          command,
          friendly.plaintextArgumentKeys,
        );
        Map<String, Object?> arguments = friendly.arguments;
        String? captureMode;
        if (friendly.spec.serviceCommand == 'ui.capture' &&
            arguments.containsKey('afterFrames')) {
          final Set<String>? features = patchbayDeclaredFeatures(
            await connection.identity(),
          );
          if (features?.contains(PatchbayFeature.captureAfterFrames.name) ==
              true) {
            captureMode = 'observedFrames';
          } else {
            arguments = <String, Object?>{...arguments}..remove('afterFrames');
            captureMode = 'legacyImmediate';
          }
        }
        if (friendly.resolvesRevision) {
          final Map<String, Object?> current =
              await CatalogInvoker.invokeAgainstCatalog(
                connection,
                catalog,
                'navigation.current',
                const <String, Object?>{},
              );
          if (current['admission'] == 'rejected') {
            return ExecutionResult(
              CatalogInvoker.withRevisionSource(current),
              catalog: catalog,
            );
          }
          arguments = <String, Object?>{
            ...arguments,
            'revision': CatalogInvoker.navigationRevision(current),
          };
        }
        Map<String, Object?> response = await CatalogInvoker.invokeCataloged(
          connection,
          catalog,
          command,
          arguments,
          wait: parsed.flag('wait'),
        );
        if (captureMode != null) {
          response = <String, Object?>{
            ...response,
            'captureMode': captureMode,
            if (captureMode == 'legacyImmediate')
              'captureNotice':
                  'host did not declare captureAfterFrames; captured in legacy '
                  'immediate mode',
          };
        }
        if (friendly.localRoute case final Map<String, Object?> localRoute) {
          response = <String, Object?>{...response, 'localRoute': localRoute};
        }
        return ExecutionResult(
          friendly.resolvesRevision
              ? CatalogInvoker.withRevisionSource(response)
              : response,
          catalog: catalog,
          // `renderedMember` commands never go through `ArtifactRequest` /
          // `PatchbayArtifactDownloader`: there is no host blob to fetch, the
          // member is already in `response`. `_executeOnce` renders and
          // spills it later, once the rendering mode (one-shot/repl,
          // json/human) is known.
          artifact:
              friendly.spec.artifact == PatchbayArtifactDisposition.none ||
                  friendly.spec.artifact ==
                      PatchbayArtifactDisposition.renderedMember
              ? null
              : ArtifactRequest(
                  disposition: friendly.spec.artifact,
                  outputPath: friendly.outputPath!,
                  force: friendly.force,
                ),
        );
    }
  }

  static Future<ExecutionResult> walkUiManifest(
    PatchbayClient connection,
    Map<String, Object?> initialCatalog,
    PatchbayUiManifest manifest,
    ArgResults parsed,
  ) async {
    final ManifestWalkthroughResult result =
        await ManifestWalkthroughRunner.walkUiManifest(
          connection: connection,
          initialCatalog: initialCatalog,
          manifest: manifest,
          parsed: parsed,
          hasCatalogCommand: (cat, cmd) =>
              CatalogCommandDescriptor.find(cat, cmd) != null,
          invokeAgainstCatalog: CatalogInvoker.invokeAgainstCatalog,
          getNavigationDestination: CatalogInvoker.navigationDestination,
          getNavigationRevision: CatalogInvoker.navigationRevision,
          getManifestSemanticsRuntime: CatalogInvoker.manifestSemanticsRuntime,
          withSource: CatalogInvoker.withSource,
        );
    return ExecutionResult(
      result.response,
      catalog: initialCatalog,
      exitCode: result.exitCode,
      summary: result.summary,
    );
  }

  static Future<ExecutionResult> verifyManifestCurrent(
    PatchbayClient connection,
    Map<String, Object?> catalog,
    PatchbayUiManifest manifest,
  ) async {
    final ManifestWalkthroughResult result =
        await ManifestWalkthroughRunner.verifyManifestCurrent(
          connection: connection,
          catalog: catalog,
          manifest: manifest,
          hasCatalogCommand: (cat, cmd) =>
              CatalogCommandDescriptor.find(cat, cmd) != null,
          invokeAgainstCatalog: CatalogInvoker.invokeAgainstCatalog,
          getNavigationDestination: CatalogInvoker.navigationDestination,
          getManifestSemanticsRuntime: CatalogInvoker.manifestSemanticsRuntime,
          withSource: CatalogInvoker.withSource,
        );
    return ExecutionResult(
      result.response,
      catalog: catalog,
      exitCode: result.exitCode,
      summary: result.summary,
    );
  }

  static PatchbayProfilingClient profilingClient(
    PatchbayClient client, {
    required String capability,
  }) {
    if (client is PatchbayProfilingClient) {
      return client as PatchbayProfilingClient;
    }
    throw PatchbayProtocolException(
      capability == 'networkProfile'
          ? 'networkProfilingUnavailable'
          : 'profilingVmServiceRequired',
      details: <String, Object?>{'capability': capability},
    );
  }

  static PatchbaySnapshotRequest? _selection(
    PatchbayFriendlyInvocation friendly,
  ) {
    if (friendly.arguments.isEmpty) return null;
    return PatchbaySnapshotRequest.fromWire(
      PatchbaySnapshotRequestWire.fromJson(friendly.arguments),
    );
  }
}
