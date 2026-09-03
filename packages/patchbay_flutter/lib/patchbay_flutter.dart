/// Patchbay 的默认 Flutter 入口（PB-060-02 / DG-060-02）。
///
/// widget 文件只需要这一个 import：core 的默认 consumer 清单，加上四个 widget 侧
/// 自有符号 `PatchbayKey`、`PatchbayRoot`、`PatchbayRootController` 与
/// `PatchbayUiRegistry`。
///
/// service host、bridge、policy、inspector、lifecycle、navigation、gesture、
/// semantics、reveal 与 capture 都是组合根的事，走
/// `package:patchbay_flutter/patchbay_flutter_host.dart`；它是本清单与 core host
/// 清单的严格超集，因此组合根只需要那一个 import。
///
/// 本 library 不再整库 re-export `package:patchbay/patchbay.dart`：raw wire 与
/// host lifecycle 不从最常用的入口泄漏出去。
library;

export 'package:patchbay/patchbay.dart'
    show
        PatchbayArtifactService,
        PatchbayBaseGate,
        PatchbayBlobFailure,
        PatchbayBlobFailureCode,
        PatchbayCatalogProvider,
        PatchbayCatalogSample,
        PatchbayCatalogSource,
        PatchbayCommandDecoder,
        PatchbayCommandDescriptor,
        PatchbayCommandFailureHandler,
        PatchbayCommandGate,
        PatchbayCommandHandler,
        PatchbayCommandMode,
        PatchbayCommandRegistration,
        PatchbayCommandRegistry,
        PatchbayConsumerGate,
        PatchbayDestinationDescriptor,
        PatchbayExecutionClassification,
        PatchbayExecutionContract,
        PatchbayFactSource,
        PatchbayGateDecision,
        PatchbayGateEvaluator,
        PatchbayGateRejection,
        PatchbayJobBody,
        PatchbayJobCancelOutcome,
        PatchbayJobCancellation,
        PatchbayJobCancellationSignal,
        PatchbayJobCapacityExceeded,
        PatchbayJobEvent,
        PatchbayJobFailure,
        PatchbayJobPhase,
        PatchbayJobRegistry,
        PatchbayJobSnapshot,
        PatchbayJobWaitOutcome,
        PatchbayJobWaitResult,
        PatchbayLogPage,
        PatchbayLogPageState,
        PatchbayLogQuery,
        PatchbayLogRecordTooLarge,
        PatchbayLogRedactionFailure,
        PatchbayLogSource,
        PatchbayLogSourceContractFailure,
        PatchbayMemoryBlobStore,
        PatchbayNavigationObservation,
        PatchbayNavigationOperation,
        PatchbayParameterDescriptor,
        PatchbayParameterType,
        PatchbayPlane,
        PatchbayRedactedLogRecord,
        PatchbayResponseSchema,
        PatchbayResponseType,
        PatchbayResponseValueSchema,
        PatchbayRetryPolicy,
        PatchbaySensitivePolicy,
        PatchbaySideEffect,
        PatchbaySnapshotRetentionLimits,
        PatchbaySnapshotSample,
        PatchbaySnapshotSource,
        PatchbayUiOperation,
        PatchbayUiTargetDeclaration,
        PatchbayUiTargetDescriptor,
        PatchbayUiTargetKind,
        PatchbayVersionedSnapshotSource,
        patchbayConfirmationBudgetMaxMs,
        patchbayPackageVersion,
        patchbaySnapshotDefaultMaxRetainedBytes,
        patchbaySnapshotDefaultMaxSnapshotBytes,
        patchbaySnapshotDiffMaxChanges,
        patchbaySnapshotDiffMaxEncodedBytes,
        patchbaySnapshotMinSnapshotBytes,
        patchbaySnapshotPollInterval,
        patchbaySnapshotRetainedByteCeiling,
        patchbaySnapshotRevisionRetention,
        patchbaySnapshotRevisionRetentionCeiling,
        patchbaySnapshotSnapshotByteCeiling,
        patchbaySnapshotWaitCeiling,
        patchbayUnchangedEvidenceMaxAgeMs;

export 'src/flutter_bridge.dart'
    show PatchbayKey, PatchbayRoot, PatchbayRootController, PatchbayUiRegistry;
