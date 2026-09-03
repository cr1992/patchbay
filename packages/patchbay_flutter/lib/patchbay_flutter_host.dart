/// Patchbay 的 Flutter host 入口（PB-060-02 / DG-060-02）。
///
/// 组合根用它：core 的 host 清单（默认 consumer 面加 host lifecycle）加上
/// `patchbay_flutter` 的全部自有符号 —— `PatchbayFlutterServiceHost`、
/// `PatchbayFlutterBridge`、inspector / navigation / gesture / semantics /
/// reveal / capture / keep-awake bridge 与它们的 policy。
///
/// 它是 `package:patchbay_flutter/patchbay_flutter.dart` 的严格超集，所以
/// `main.dart` 这类装配文件只写这一个 import 即可；widget 文件继续只 import 默认
/// 面，让「这个文件能不能碰 host」在 import 行上一眼可读。
///
/// 需要直接读写 raw wire 时再显式加 `package:patchbay/patchbay_protocol.dart`；
/// 本 library 不 re-export protocol，也不存在
/// `patchbay_flutter_protocol.dart`。
library;

export 'package:patchbay/patchbay_host.dart'
    show
        PatchbayAdmission,
        PatchbayArtifactService,
        PatchbayAuditDeliveryClosed,
        PatchbayAuditDeliveryOverflow,
        PatchbayAuditDrainOutcome,
        PatchbayAuditDrainResult,
        PatchbayAuditEvent,
        PatchbayAuditSink,
        PatchbayAuditSinkErrorHandler,
        PatchbayBaseGate,
        PatchbayBlobFailure,
        PatchbayBlobFailureCode,
        PatchbayCancellationConfirmation,
        PatchbayCancellationSignal,
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
        PatchbayContextCommandHandler,
        PatchbayContextInvocationSource,
        PatchbayDestinationDescriptor,
        PatchbayExecutionClassification,
        PatchbayExecutionContract,
        PatchbayExecutionValidationResult,
        PatchbayExtensionRegistrar,
        PatchbayFactSource,
        PatchbayGateDecision,
        PatchbayGateEvaluator,
        PatchbayGateRejection,
        PatchbayHostInvocationHandle,
        PatchbayInvocation,
        PatchbayInvocationCancellationOutcome,
        PatchbayInvocationCancellationReason,
        PatchbayInvocationCancellationResult,
        PatchbayInvocationCancellationSignal,
        PatchbayInvocationConfirmationState,
        PatchbayInvocationContext,
        PatchbayInvocationDeadline,
        PatchbayInvocationDrainOutcome,
        PatchbayInvocationDrainResult,
        PatchbayInvocationSource,
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
        PatchbayMonotonicClock,
        PatchbayNavigationObservation,
        PatchbayNavigationOperation,
        PatchbayParameterDescriptor,
        PatchbayParameterType,
        PatchbayPlane,
        PatchbayRedactedLogRecord,
        PatchbayRejection,
        PatchbayResponseSchema,
        PatchbayResponseType,
        PatchbayResponseValidationIssue,
        PatchbayResponseValueSchema,
        PatchbayRetryPolicy,
        PatchbaySensitivePolicy,
        PatchbayServiceHost,
        PatchbaySideEffect,
        PatchbaySnapshotRetentionLimits,
        PatchbaySnapshotSample,
        PatchbaySnapshotSource,
        PatchbayUiOperation,
        PatchbayUiTargetDeclaration,
        PatchbayUiTargetDescriptor,
        PatchbayUiTargetKind,
        PatchbayVersionedSnapshotSource,
        patchbayAuditAdmissionStages,
        patchbayAuditExecutionClassification,
        patchbayAuditGateDispositions,
        patchbayAuditLegacyUnknown,
        patchbayConfirmationBudgetMaxMs,
        patchbayGenerateOwnerToken,
        patchbayPackageVersion,
        patchbayProjectAuditEvent,
        patchbayResponseSchemaMaxDepth,
        patchbayResponseSchemaMaxFields,
        patchbayResponseValidationMaxIssues,
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
        patchbayUnchangedEvidenceMaxAgeMs,
        validatePatchbayExecutionContract,
        validatePatchbayExecutionEvidence,
        validatePatchbayResponsePayload,
        validatePatchbayResponseSchema,
        validatePatchbayTerminalPayload;

export 'src/flutter_bridge.dart'
    show
        PatchbayCaptureBridge,
        PatchbayCaptureDecoder,
        PatchbayCaptureEncoder,
        PatchbayDecodedCapture,
        PatchbayEncodedCapture,
        PatchbayFlutterBridge,
        PatchbayKey,
        PatchbayRoot,
        PatchbayRootController,
        PatchbayUiRegistry;
export 'src/flutter_service_host.dart' show PatchbayFlutterServiceHost;
export 'src/frame_observer.dart' show PatchbayFrameObserver;
export 'src/inspect_bridge.dart'
    show
        PatchbayBindingInspectorSurface,
        PatchbayInspectBridge,
        PatchbayInspectPolicy,
        PatchbayInspectorSurface;
export 'src/keep_awake_bridge.dart'
    show PatchbayKeepAwakeBridge, PatchbayKeepAwakeDelegate;
export 'src/lifecycle.dart'
    show
        PatchbayLifecycleStateReader,
        patchbayBindingLifecycleState,
        patchbayLifecycleDetails,
        patchbayLifecycleReaderFor,
        patchbayUnknownLifecycleState;
export 'src/navigation_bridge.dart'
    show
        PatchbayNavigationAdapter,
        PatchbayNavigationBridge,
        PatchbayNavigationCatalogSource,
        PatchbayNavigationDestination,
        PatchbayNavigationObservationSource,
        PatchbayNavigationRequest;
export 'src/reveal_bridge.dart'
    show
        PatchbayRevealBridge,
        PatchbayRevealDecision,
        PatchbayRevealDirection,
        PatchbayRevealPolicy;
export 'src/semantics_bridge.dart'
    show
        PatchbayGestureBridge,
        PatchbayGestureDecision,
        PatchbayGestureDelay,
        PatchbayGestureKind,
        PatchbayGesturePolicy,
        PatchbayGestureTarget,
        PatchbayPointerEventDispatcher,
        PatchbaySemanticsAction,
        PatchbaySemanticsActionDecision,
        PatchbaySemanticsActionPolicy,
        PatchbaySemanticsBridge,
        PatchbaySemanticsIdentifierMatch,
        PatchbaySemanticsIdentifierObservation,
        PatchbaySemanticsTarget;
export 'src/ui_wait_bridge.dart' show PatchbayUiWaitBridge;
