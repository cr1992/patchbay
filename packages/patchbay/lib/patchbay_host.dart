/// Patchbay 的 host implementer 入口（PB-060-02 / DG-060-02）。
///
/// 内容是默认 consumer 清单的**严格超集**：`package:patchbay/patchbay.dart` 的全部
/// 符号，再加 `PatchbayServiceHost`、audit sink/event、invocation 与 cancellation
/// lifecycle、admission/rejection 以及响应与执行证据的 validation。组合根只需要这
/// 一个 import，不必再叠加默认入口。
///
/// 这里**不** re-export protocol：既要实现 host 又要直接读写 raw wire 的高级使用者
/// 显式再 import `package:patchbay/patchbay_protocol.dart`。两个清单互不相交，同时
/// import 不会冲突。
///
/// 普通 widget / 业务 adapter 不应该 import 本 library —— 它能看见 host lifecycle，
/// 而那正是默认面刻意收窄掉的部分。
library;

export 'src/artifacts.dart'
    show
        PatchbayArtifactService,
        PatchbayCancellationSignal,
        PatchbayLogPage,
        PatchbayLogPageState,
        PatchbayLogQuery,
        PatchbayLogRecordTooLarge,
        PatchbayLogRedactionFailure,
        PatchbayLogSource,
        PatchbayLogSourceContractFailure,
        PatchbayRedactedLogRecord;
export 'src/audit.dart'
    show
        PatchbayAuditDeliveryClosed,
        PatchbayAuditDeliveryOverflow,
        PatchbayAuditDrainOutcome,
        PatchbayAuditDrainResult,
        PatchbayAuditEvent,
        PatchbayAuditSink,
        PatchbayAuditSinkErrorHandler,
        patchbayAuditAdmissionStages,
        patchbayAuditExecutionClassification,
        patchbayAuditGateDispositions,
        patchbayAuditLegacyUnknown,
        patchbayProjectAuditEvent;
export 'src/blob_store.dart'
    show PatchbayBlobFailure, PatchbayBlobFailureCode, PatchbayMemoryBlobStore;
export 'src/command_descriptor.dart'
    show
        PatchbayCommandDescriptor,
        PatchbayCommandMode,
        PatchbayParameterDescriptor,
        PatchbayParameterType,
        PatchbayRetryPolicy;
export 'src/command_registry.dart'
    show
        PatchbayCommandDecoder,
        PatchbayCommandFailureHandler,
        PatchbayCommandGate,
        PatchbayCommandHandler,
        PatchbayCommandRegistration,
        PatchbayCommandRegistry;
export 'src/execution_evidence.dart'
    show
        PatchbayExecutionClassification,
        PatchbayExecutionContract,
        PatchbayExecutionValidationResult,
        patchbayConfirmationBudgetMaxMs,
        patchbayUnchangedEvidenceMaxAgeMs,
        validatePatchbayExecutionContract,
        validatePatchbayExecutionEvidence;
export 'src/facts.dart' show PatchbayFactSource;
export 'src/gates.dart'
    show
        PatchbayBaseGate,
        PatchbayConsumerGate,
        PatchbayGateDecision,
        PatchbayGateEvaluator,
        PatchbayGateRejection;
export 'src/invocation.dart'
    show PatchbayAdmission, PatchbayInvocation, PatchbayRejection;
export 'src/invocation_cancellation.dart'
    show
        PatchbayCancellationConfirmation,
        PatchbayContextCommandHandler,
        PatchbayHostInvocationHandle,
        PatchbayInvocationCancellationOutcome,
        PatchbayInvocationCancellationReason,
        PatchbayInvocationCancellationResult,
        PatchbayInvocationCancellationSignal,
        PatchbayInvocationConfirmationState,
        PatchbayInvocationContext,
        PatchbayInvocationDeadline,
        PatchbayInvocationDrainOutcome,
        PatchbayInvocationDrainResult,
        PatchbayMonotonicClock,
        patchbayGenerateOwnerToken;
export 'src/jobs.dart'
    show
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
        PatchbayJobWaitResult;
export 'src/navigation.dart'
    show
        PatchbayDestinationDescriptor,
        PatchbayNavigationObservation,
        PatchbayNavigationOperation;
export 'src/response_schema.dart'
    show
        PatchbayResponseSchema,
        PatchbayResponseType,
        PatchbayResponseValidationIssue,
        PatchbayResponseValueSchema,
        patchbayResponseSchemaMaxDepth,
        patchbayResponseSchemaMaxFields,
        patchbayResponseValidationMaxIssues,
        validatePatchbayResponsePayload,
        validatePatchbayResponseSchema,
        validatePatchbayTerminalPayload;
export 'src/service_host.dart'
    show
        PatchbayCatalogProvider,
        PatchbayCatalogSample,
        PatchbayCatalogSource,
        PatchbayContextInvocationSource,
        PatchbayExtensionRegistrar,
        PatchbayInvocationSource,
        PatchbayServiceHost,
        PatchbaySnapshotSample,
        PatchbaySnapshotSource,
        PatchbayVersionedSnapshotSource;
export 'src/snapshot.dart'
    show
        PatchbaySnapshotRetentionLimits,
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
        patchbaySnapshotWaitCeiling;
export 'src/ui_descriptor.dart'
    show
        PatchbayPlane,
        PatchbaySensitivePolicy,
        PatchbaySideEffect,
        PatchbayUiOperation,
        PatchbayUiTargetDeclaration,
        PatchbayUiTargetDescriptor,
        PatchbayUiTargetKind;
export 'src/version.dart' show patchbayPackageVersion;
