// PB-050-38：host 的**装配阶段**——把桥、注册表与接入方注入的几个源头合成一台
// `PatchbayServiceHost`。
//
// 这一段只做三件可以单独断言的事，之后就把控制权交给 core：
//
// 1. 合并注册表：UI 命令表加上 artifacts 自带的 blob 命令表；
// 2. 补齐缺省源：没给 snapshot 就给空 map，`domainInvoke` 与
//    `domainInvokeWithContext` 都没给才装那条 `commandNotRegistered` 兜底——
//    只给了 `invokeWithContext` 的 App 不该被兜底抢走请求；
// 3. 声明 features：`lifecycleState` 总在，`captureAfterFrames` 跟着 capture 是否
//    接线。
//
// 门交给桥自己那个 evaluator，不再造第二个：一个 gateId 在 UI 面与 domain 面必须
// 指同一件事（见 `bridge.gates`）。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';

import 'flutter_bridge.dart';
import 'flutter_ui_catalog.dart';
import 'flutter_ui_command_bindings.dart';

/// 组装这台 host。[domainCatalog] 与 [domainCatalogProvider] 至多给一个。
PatchbayServiceHost patchbayBuildFlutterServiceHost({
  required String applicationId,
  required PatchbayFlutterBridge bridge,
  PatchbayCatalogSource? domainCatalog,
  PatchbayCatalogProvider? domainCatalogProvider,
  PatchbaySnapshotSource? snapshot,
  PatchbayInvocationSource? domainInvoke,
  PatchbayContextInvocationSource? domainInvokeWithContext,
  String? appInstanceId,
  PatchbayExtensionRegistrar? registrar,
  PatchbayAuditSink? auditSink,
  PatchbayAuditSinkErrorHandler? onAuditSinkError,
  required int auditQueueCapacity,
  required int maxConcurrentInvocations,
  required Duration cancellationConfirmationTimeout,
  PatchbayMonotonicClock? monotonicClock,
}) {
  assert((domainCatalog == null) || domainCatalogProvider == null);
  final PatchbayCommandRegistry registry =
      PatchbayCommandRegistry.combine(<PatchbayCommandRegistry>[
        patchbayFlutterUiCommandRegistry(bridge),
        if (bridge.artifacts case final PatchbayArtifactService artifacts)
          artifacts.registry,
      ]);
  final PatchbaySnapshotSource effectiveSnapshot =
      snapshot ?? () async => const <String, Object?>{};
  final PatchbayInvocationSource? effectiveInvoke =
      domainInvoke == null && domainInvokeWithContext == null
      ? (command, arguments, requestId) async => PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: PatchbayRejection(
            code: 'commandNotRegistered',
            details: <String, Object?>{'command': command},
          ),
        ).toJson()
      : domainInvoke;
  final Set<PatchbayFeature> features = <PatchbayFeature>{
    PatchbayFeature.lifecycleState,
    if (bridge.capture != null) PatchbayFeature.captureAfterFrames,
  };
  if (domainCatalogProvider case final PatchbayCatalogProvider provider) {
    return PatchbayServiceHost.withCatalogProvider(
      applicationId: applicationId,
      appInstanceId: appInstanceId,
      registrar: registrar,
      auditSink: auditSink,
      onAuditSinkError: onAuditSinkError,
      auditQueueCapacity: auditQueueCapacity,
      maxConcurrentInvocations: maxConcurrentInvocations,
      cancellationConfirmationTimeout: cancellationConfirmationTimeout,
      monotonicClock: monotonicClock,
      registry: registry,
      catalogProvider: PatchbayFlutterCatalogProvider(provider, bridge),
      snapshot: effectiveSnapshot,
      invoke: effectiveInvoke,
      invokeWithContext: domainInvokeWithContext,
      // The bridge's evaluator, not a second one: see `bridge.gates`.
      domainGates: bridge.gates,
      features: features,
    );
  }
  return PatchbayServiceHost(
    applicationId: applicationId,
    appInstanceId: appInstanceId,
    registrar: registrar,
    auditSink: auditSink,
    onAuditSinkError: onAuditSinkError,
    auditQueueCapacity: auditQueueCapacity,
    maxConcurrentInvocations: maxConcurrentInvocations,
    cancellationConfirmationTimeout: cancellationConfirmationTimeout,
    monotonicClock: monotonicClock,
    registry: registry,
    catalog: () async => patchbayWithUiTargets(
      await domainCatalog?.call() ?? const <String, Object?>{},
      bridge,
    ),
    snapshot: effectiveSnapshot,
    invoke: effectiveInvoke,
    invokeWithContext: domainInvokeWithContext,
    // The bridge's evaluator, not a second one: see `bridge.gates`.
    domainGates: bridge.gates,
    features: features,
  );
}
