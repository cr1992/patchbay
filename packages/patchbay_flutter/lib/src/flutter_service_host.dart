import 'package:patchbay/patchbay_host.dart';

import 'flutter_bridge.dart';
import 'flutter_host_assembly.dart';

/// Registers the Flutter UI catalog and operators on the generic host.
///
/// PB-050-38：这个类只剩两件事——接入方看得见的公共门面，以及把构造参数转交给
/// `flutter_host_assembly.dart` 的装配。命令声明、参数解码、拒绝投影、注册表装配、
/// 命令族到桥的派发与 catalog 投影各自成文件，可以脱离 host 单独构造与失败注入：
///
/// - `flutter_ui_command_descriptors.dart`：发布哪几条命令、每条长什么样；
/// - `flutter_ui_argument_decoders.dart`：wire map 进、类型化请求出，不合格就抛；
/// - `flutter_ui_rejection.dart`：把解码失败投影成 `invalidUiArguments`；
/// - `flutter_ui_registration.dart`：descriptor 与 handler 按位置配对，两端守数量；
/// - `flutter_ui_command_bindings.dart`：每条命令交给哪座桥的哪个方法；
/// - `flutter_ui_catalog.dart`：把桥的 UI 目标表贴到 domain 目录上；
/// - `flutter_host_assembly.dart`：注册表合并、缺省源补齐与 features 声明。
final class PatchbayFlutterServiceHost {
  PatchbayFlutterServiceHost({
    required String applicationId,
    required PatchbayFlutterBridge bridge,
    PatchbayCatalogSource? domainCatalog,
    PatchbaySnapshotSource? snapshot,
    PatchbayInvocationSource? domainInvoke,
    PatchbayContextInvocationSource? domainInvokeWithContext,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
    int auditQueueCapacity = 256,
    int maxConcurrentInvocations = 8,
    Duration cancellationConfirmationTimeout = const Duration(seconds: 2),
    PatchbayMonotonicClock? monotonicClock,
  }) : _host = patchbayBuildFlutterServiceHost(
         applicationId: applicationId,
         bridge: bridge,
         domainCatalog: domainCatalog,
         snapshot: snapshot,
         domainInvoke: domainInvoke,
         domainInvokeWithContext: domainInvokeWithContext,
         appInstanceId: appInstanceId,
         registrar: registrar,
         auditSink: auditSink,
         onAuditSinkError: onAuditSinkError,
         auditQueueCapacity: auditQueueCapacity,
         maxConcurrentInvocations: maxConcurrentInvocations,
         cancellationConfirmationTimeout: cancellationConfirmationTimeout,
         monotonicClock: monotonicClock,
       );

  PatchbayFlutterServiceHost.withDomainCatalogProvider({
    required String applicationId,
    required PatchbayFlutterBridge bridge,
    required PatchbayCatalogProvider domainCatalogProvider,
    PatchbaySnapshotSource? snapshot,
    PatchbayInvocationSource? domainInvoke,
    PatchbayContextInvocationSource? domainInvokeWithContext,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
    int auditQueueCapacity = 256,
    int maxConcurrentInvocations = 8,
    Duration cancellationConfirmationTimeout = const Duration(seconds: 2),
    PatchbayMonotonicClock? monotonicClock,
  }) : _host = patchbayBuildFlutterServiceHost(
         applicationId: applicationId,
         bridge: bridge,
         domainCatalogProvider: domainCatalogProvider,
         snapshot: snapshot,
         domainInvoke: domainInvoke,
         domainInvokeWithContext: domainInvokeWithContext,
         appInstanceId: appInstanceId,
         registrar: registrar,
         auditSink: auditSink,
         onAuditSinkError: onAuditSinkError,
         auditQueueCapacity: auditQueueCapacity,
         maxConcurrentInvocations: maxConcurrentInvocations,
         cancellationConfirmationTimeout: cancellationConfirmationTimeout,
         monotonicClock: monotonicClock,
       );

  final PatchbayServiceHost _host;

  String get applicationId => _host.applicationId;

  String get appInstanceId => _host.appInstanceId;

  int get schemaVersion => PatchbayServiceHost.schemaVersion;

  List<PatchbayAuditEvent> get auditEvents => _host.auditEvents;

  Set<PatchbayFeature> get features => _host.features;

  Future<PatchbayAuditDrainResult> drainAudit({
    Duration timeout = const Duration(seconds: 2),
  }) => _host.drainAudit(timeout: timeout);

  Future<void> dispose({
    Duration invocationTimeout = const Duration(seconds: 2),
    Duration auditTimeout = const Duration(seconds: 2),
  }) => _host.dispose(
    invocationTimeout: invocationTimeout,
    auditTimeout: auditTimeout,
  );

  Future<Map<String, Object?>> dispatchCatalog() => _host.dispatchCatalog();

  Future<Map<String, Object?>> dispatchSnapshot([
    Map<String, Object?>? request,
  ]) => _host.dispatchSnapshot(request);

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    String? ownerToken,
    Duration? deadline,
  }) => _host.dispatchInvoke(
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
  }) => _host.dispatchInvokeHandle(
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
  }) => _host.cancelInvocation(
    command: command,
    requestId: requestId,
    ownerToken: ownerToken,
    reason: reason,
  );

  Future<PatchbayInvocationDrainResult> drainInvocations({
    Duration timeout = const Duration(seconds: 2),
  }) => _host.drainInvocations(timeout: timeout);

  void register() => _host.register();
}
