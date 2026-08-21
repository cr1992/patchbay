import 'dart:async';
import 'dart:developer';

import 'audit.dart';
import 'command_registry.dart';
import 'features.dart';
import 'host/host_catalog.dart';
import 'host/host_invoker.dart';
import 'host/host_models.dart';
import 'host/host_snapshot.dart';
import 'host/host_vm_service.dart';

export 'host/host_models.dart'
    show
        PatchbayCatalogSource,
        PatchbaySnapshotSource,
        PatchbayInvocationSource,
        PatchbayExtensionRegistrar;

/// Generic VM Service extension host. It has no Flutter or consumer imports.
final class PatchbayServiceHost {
  PatchbayServiceHost({
    required this.applicationId,
    required PatchbayCatalogSource catalog,
    required PatchbaySnapshotSource snapshot,
    required PatchbayInvocationSource invoke,
    PatchbayCommandRegistry? registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    Set<PatchbayFeature> features = const <PatchbayFeature>{},
    this.auditSink,
    this.onAuditSinkError,
  }) : appInstanceId = appInstanceId ?? patchbayGenerateNonce(),
       _registry = registry ?? PatchbayCommandRegistry(const []),
       _declaredFeatures = features {
    _catalogHandler = HostCatalogHandler(
      catalogSource: catalog,
      registry: _registry,
    );
    _snapshotHandler = HostSnapshotHandler(snapshotSource: snapshot);
    _invokerHandler = HostInvokerHandler(
      invokeSource: invoke,
      registry: _registry,
      catalogHandler: _catalogHandler,
      auditSink: auditSink,
      onAuditSinkError: onAuditSinkError,
    );
    _vmServiceRegistrar = HostVmServiceRegistrar(
      applicationId: applicationId,
      appInstanceId: this.appInstanceId,
      features: this.features,
      catalogHandler: _catalogHandler,
      snapshotHandler: _snapshotHandler,
      invokerHandler: _invokerHandler,
      registrar: registrar,
    );
  }

  static const int schemaVersion = 1;
  static const String identityMethod = HostVmServiceRegistrar.identityMethod;
  static const String catalogMethod = HostVmServiceRegistrar.catalogMethod;
  static const String snapshotMethod = HostVmServiceRegistrar.snapshotMethod;
  static const String invokeMethod = HostVmServiceRegistrar.invokeMethod;
  static const String stdinProvenanceKey = 'inputWasStdin';
  static const String snapshotRequestKey =
      HostVmServiceRegistrar.snapshotRequestKey;

  static final RegExp _commandName = RegExp(
    r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$',
  );

  static RegExp get commandNamePattern => _commandName;

  final String applicationId;
  final String appInstanceId;
  final PatchbayCommandRegistry _registry;
  final Set<PatchbayFeature> _declaredFeatures;
  final PatchbayAuditSink? auditSink;
  final PatchbayAuditSinkErrorHandler? onAuditSinkError;

  late final HostCatalogHandler _catalogHandler;
  late final HostSnapshotHandler _snapshotHandler;
  late final HostInvokerHandler _invokerHandler;
  late final HostVmServiceRegistrar _vmServiceRegistrar;

  /// The newest 256 redacted command facts, in dispatch completion order.
  List<PatchbayAuditEvent> get auditEvents => _invokerHandler.auditEvents;

  /// Capabilities this host declares on the identity plane.
  Set<PatchbayFeature> get features => <PatchbayFeature>{
    ..._coreFeatures,
    if (_registry.hasResponseSchemas) PatchbayFeature.responseSchemas,
    ..._declaredFeatures,
  };

  static const Set<PatchbayFeature> _coreFeatures = <PatchbayFeature>{
    PatchbayFeature.catalogDigest,
    PatchbayFeature.snapshotSelectors,
    PatchbayFeature.snapshotRevisionDiff,
  };

  /// Transport-neutral dispatch seam used by alternate, explicitly enabled
  /// hosts.
  Future<Map<String, Object?>> dispatchCatalog() =>
      _catalogHandler.dispatchCatalog();

  /// Serves the snapshot RPC: the whole snapshot, one selected field, or a
  /// server-side wait for a condition on that field.
  Future<Map<String, Object?>> dispatchSnapshot([
    Map<String, Object?>? request,
  ]) => _snapshotHandler.dispatchSnapshot(request);

  /// Dispatches an invocation through the registry or external invocation handler.
  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) => _invokerHandler.dispatchInvoke(command, arguments, requestId);

  void register() => _vmServiceRegistrar.register();

  Future<ServiceExtensionResponse> handleSnapshot(
    String method,
    Map<String, String> parameters,
  ) => _vmServiceRegistrar.handleSnapshot(method, parameters);

  Future<ServiceExtensionResponse> handleIdentity(
    String method,
    Map<String, String> parameters,
  ) => _vmServiceRegistrar.handleIdentity(method, parameters);

  Map<String, Object?> identityResponse() =>
      _vmServiceRegistrar.identityResponse();

  Future<ServiceExtensionResponse> handleCatalog(
    String method,
    Map<String, String> parameters,
  ) => _vmServiceRegistrar.handleCatalog(method, parameters);

  Future<ServiceExtensionResponse> handleInvoke(
    String method,
    Map<String, String> parameters,
  ) => _vmServiceRegistrar.handleInvoke(method, parameters);
}
