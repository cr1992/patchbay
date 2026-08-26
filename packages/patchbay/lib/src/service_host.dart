import 'dart:async';
import 'dart:developer';

import 'audit.dart';
import 'command_registry.dart';
import 'features.dart';
import 'gates.dart';
import 'host/host_catalog.dart';
import 'host/host_invoker.dart';
import 'host/host_models.dart';
import 'host/host_snapshot.dart';
import 'host/host_vm_service.dart';
import 'invocation_cancellation.dart';

export 'host/host_models.dart'
    show
        PatchbayCatalogProvider,
        PatchbayCatalogSample,
        PatchbayCatalogSource,
        PatchbaySnapshotSource,
        PatchbayInvocationSource,
        PatchbayContextInvocationSource,
        PatchbayExtensionRegistrar;

/// Generic VM Service extension host. It has no Flutter or consumer imports.
///
/// `domainGates` is the evaluator consumer-owned write commands cross before
/// they reach `invoke`. A command is admitted through it when the registry does
/// not serve it and its catalog row does not declare `sideEffect: none`; the
/// row's `gates` are handed to the evaluator unchanged, so an empty set still
/// runs the non-optional base gate. Leaving it null keeps gate-free commands
/// exactly as they were, but a row that declares gates no evaluator can run is
/// then refused rather than silently admitted.
final class PatchbayServiceHost {
  factory PatchbayServiceHost({
    required String applicationId,
    required PatchbayCatalogSource catalog,
    required PatchbaySnapshotSource snapshot,
    PatchbayInvocationSource? invoke,
    PatchbayContextInvocationSource? invokeWithContext,
    PatchbayCommandRegistry? registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    Set<PatchbayFeature> features = const <PatchbayFeature>{},
    PatchbayGateEvaluator? domainGates,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
    int auditQueueCapacity = 256,
    int maxConcurrentInvocations = 8,
    Duration cancellationConfirmationTimeout = const Duration(seconds: 2),
    PatchbayMonotonicClock? monotonicClock,
  }) => PatchbayServiceHost._(
    applicationId: applicationId,
    catalogSource: catalog,
    snapshot: snapshot,
    invoke: invoke,
    invokeWithContext: invokeWithContext,
    registry: registry,
    appInstanceId: appInstanceId,
    registrar: registrar,
    features: features,
    domainGates: domainGates,
    auditSink: auditSink,
    onAuditSinkError: onAuditSinkError,
    auditQueueCapacity: auditQueueCapacity,
    maxConcurrentInvocations: maxConcurrentInvocations,
    cancellationConfirmationTimeout: cancellationConfirmationTimeout,
    monotonicClock: monotonicClock,
  );

  factory PatchbayServiceHost.withCatalogProvider({
    required String applicationId,
    required PatchbayCatalogProvider catalogProvider,
    required PatchbaySnapshotSource snapshot,
    PatchbayInvocationSource? invoke,
    PatchbayContextInvocationSource? invokeWithContext,
    PatchbayCommandRegistry? registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    Set<PatchbayFeature> features = const <PatchbayFeature>{},
    PatchbayGateEvaluator? domainGates,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
    int auditQueueCapacity = 256,
    int maxConcurrentInvocations = 8,
    Duration cancellationConfirmationTimeout = const Duration(seconds: 2),
    PatchbayMonotonicClock? monotonicClock,
  }) => PatchbayServiceHost._(
    applicationId: applicationId,
    catalogProvider: catalogProvider,
    snapshot: snapshot,
    invoke: invoke,
    invokeWithContext: invokeWithContext,
    registry: registry,
    appInstanceId: appInstanceId,
    registrar: registrar,
    features: features,
    domainGates: domainGates,
    auditSink: auditSink,
    onAuditSinkError: onAuditSinkError,
    auditQueueCapacity: auditQueueCapacity,
    maxConcurrentInvocations: maxConcurrentInvocations,
    cancellationConfirmationTimeout: cancellationConfirmationTimeout,
    monotonicClock: monotonicClock,
  );

  PatchbayServiceHost._({
    required this.applicationId,
    PatchbayCatalogSource? catalogSource,
    PatchbayCatalogProvider? catalogProvider,
    required PatchbaySnapshotSource snapshot,
    PatchbayInvocationSource? invoke,
    PatchbayContextInvocationSource? invokeWithContext,
    PatchbayCommandRegistry? registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    Set<PatchbayFeature> features = const <PatchbayFeature>{},
    PatchbayGateEvaluator? domainGates,
    this.auditSink,
    this.onAuditSinkError,
    required this.auditQueueCapacity,
    required int maxConcurrentInvocations,
    required Duration cancellationConfirmationTimeout,
    PatchbayMonotonicClock? monotonicClock,
  }) : assert((catalogSource == null) != (catalogProvider == null)),
       appInstanceId = appInstanceId ?? patchbayGenerateNonce(),
       _registry = registry ?? PatchbayCommandRegistry(const []),
       _declaredFeatures = features {
    _catalogHandler = HostCatalogHandler(
      catalogSource: catalogSource,
      catalogProvider: catalogProvider,
      registry: _registry,
    );
    _snapshotHandler = HostSnapshotHandler(snapshotSource: snapshot);
    _invokerHandler = HostInvokerHandler(
      invokeSource: invoke,
      invokeWithContext: invokeWithContext,
      registry: _registry,
      catalogHandler: _catalogHandler,
      domainGates: domainGates,
      auditSink: auditSink,
      onAuditSinkError: onAuditSinkError,
      auditQueueCapacity: auditQueueCapacity,
      maxConcurrentInvocations: maxConcurrentInvocations,
      cancellationConfirmationTimeout: cancellationConfirmationTimeout,
      monotonicClock: monotonicClock,
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
  static const String cancelInvocationMethod =
      HostVmServiceRegistrar.cancelInvocationMethod;
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
  final int auditQueueCapacity;

  Future<void>? _disposeFuture;

  late final HostCatalogHandler _catalogHandler;
  late final HostSnapshotHandler _snapshotHandler;
  late final HostInvokerHandler _invokerHandler;
  late final HostVmServiceRegistrar _vmServiceRegistrar;

  /// The newest 256 redacted command facts, in dispatch completion order.
  List<PatchbayAuditEvent> get auditEvents => _invokerHandler.auditEvents;

  /// Stops accepting audit deliveries and waits for the accepted prefix.
  ///
  /// The first call freezes [timeout]. Later calls return the same terminal
  /// future and ignore their timeout argument.
  Future<PatchbayAuditDrainResult> drainAudit({
    Duration timeout = const Duration(seconds: 2),
  }) => _invokerHandler.drainAudit(timeout: timeout);

  /// Drains host-owned resources. Repeated calls return the same future.
  Future<void> dispose({
    Duration invocationTimeout = const Duration(seconds: 2),
    Duration auditTimeout = const Duration(seconds: 2),
  }) {
    final Future<void>? existing = _disposeFuture;
    if (existing != null) return existing;
    return _disposeFuture = drainInvocations(
      timeout: invocationTimeout,
    ).then((_) => drainAudit(timeout: auditTimeout)).then<void>((_) {});
  }

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
    PatchbayFeature.invocationCancellation,
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
    String requestId, {
    String? ownerToken,
    Duration? deadline,
  }) => _invokerHandler.dispatchInvoke(
    command,
    arguments,
    requestId,
    ownerToken: ownerToken,
    deadline: deadline,
  );

  PatchbayHostInvocationHandle dispatchInvokeHandle(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    String? ownerToken,
    Duration? deadline,
  }) => _invokerHandler.dispatchInvokeHandle(
    command,
    arguments,
    requestId,
    ownerToken: ownerToken,
    deadline: deadline,
  );

  Future<PatchbayInvocationCancellationResult> cancelInvocation({
    required String command,
    required String requestId,
    required String ownerToken,
    PatchbayInvocationCancellationReason reason =
        PatchbayInvocationCancellationReason.explicitRequest,
  }) => _invokerHandler.cancelInvocation(
    command: command,
    requestId: requestId,
    ownerToken: ownerToken,
    reason: reason,
  );

  Future<PatchbayInvocationDrainResult> drainInvocations({
    Duration timeout = const Duration(seconds: 2),
  }) => _invokerHandler.drainInvocations(timeout: timeout);

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

  Future<ServiceExtensionResponse> handleCancelInvocation(
    String method,
    Map<String, String> parameters,
  ) => _vmServiceRegistrar.handleCancelInvocation(method, parameters);
}
