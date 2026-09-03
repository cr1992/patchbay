/// Patchbay 的默认 consumer 入口（PB-060-02 / DG-060-02）。
///
/// 这里是把一个 App 接进 Patchbay 所需要的**自足**清单：命令注册与 descriptor、参数与
/// 响应 schema、gate、catalog/snapshot provider、job ledger、artifact/blob/log service，
/// 以及 navigation 与 UI 的声明类型。业务 adapter 绝大多数只需要这一个 import。
///
/// 「自足」是硬约束，由 `tool/check_api_closure.dart` 用 analyzer 的 element model 机检：
/// 本 library 导出的每个符号，其公共签名（超类/接口、构造函数形参、公共字段与 getter 的
/// 类型、方法形参与返回类型、typedef 的 aliased type、类型参数上界）里出现的 Patchbay
/// 类型必须也由本 library 导出。因此这里会出现少量 `*Wire` 与 CLI syntax 类型 ——
/// 例如 `PatchbayLogQuery` 的构造函数收 `PatchbayLogLevelWire`、`PatchbayRedactedLogRecord`
/// 公开 `PatchbayLogRecordWire wire` —— 它们不是「raw wire 泄漏」，是接入方实现
/// `PatchbayLogSource` 时**必须能命名**的类型。闭包优先于「`Wire` 后缀归 protocol」这类
/// 命名分组。
///
/// 清单是**封闭**的：每一行 `show` 都逐名列出，新增公共符号必须在所属 MR 里显式选择
/// consumer、host 还是 protocol，并同步 `tool/api_surface.json`。没有「差集自动落到默认面」
/// 这回事，也没有「不登记就看不见」——`lib/src/**` 里未被任何公共入口导出的公共名必须登记
/// 进 golden 的 `internal` 清单。
///
/// 另外两个角色有各自的入口：
///
/// - 实现 host（`PatchbayServiceHost`、audit、invocation/cancellation 的生命周期、
///   validation）用 `package:patchbay/patchbay_host.dart`，它是本清单的严格超集；
/// - 直接处理 raw wire、catalog capability/digest、permission companion 或 canonical
///   protocol descriptor 用 `package:patchbay/patchbay_protocol.dart`。
///
/// protocol 入口与本入口有意重叠（各自闭包的交集），同时 import 两者不会冲突：同一个声明
/// 从两个 library 到达仍是同一个类型。同一个文件跨角色时显式写两个 import；本包不提供
/// `legacy.dart`，也不提供任何整库 re-export 的兼容口袋。
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
export 'src/blob_store.dart'
    show PatchbayBlobFailure, PatchbayBlobFailureCode, PatchbayMemoryBlobStore;
export 'src/command_descriptor.dart'
    show
        PatchbayCliArtifactDisposition,
        PatchbayCliEqualsCondition,
        PatchbayCliInputMode,
        PatchbayCliSyntax,
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
        patchbayConfirmationBudgetMaxMs,
        patchbayUnchangedEvidenceMaxAgeMs;
export 'src/facts.dart' show PatchbayFactSource;
export 'src/gates.dart'
    show
        PatchbayBaseGate,
        PatchbayConsumerGate,
        PatchbayGateDecision,
        PatchbayGateEvaluator,
        PatchbayGateRejection;
export 'src/generated/core_wire.g.dart'
    show
        PatchbayBlobChunkWire,
        PatchbayBlobMetadataWire,
        PatchbayBlobSourceWire,
        PatchbayDestinationDescriptorWire,
        PatchbayFactSourceWire,
        PatchbayLogDirectionWire,
        PatchbayLogLevelWire,
        PatchbayLogRecordWire,
        PatchbayLogRedactionWire,
        PatchbayNavigationOperationWire;
export 'src/invocation_cancellation.dart'
    show
        PatchbayCancellationConfirmation,
        PatchbayContextCommandHandler,
        PatchbayInvocationCancellationReason,
        PatchbayInvocationCancellationSignal,
        PatchbayInvocationContext,
        PatchbayInvocationDeadline;
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
        PatchbayResponseValueSchema;
export 'src/service_host.dart'
    show
        PatchbayCatalogProvider,
        PatchbayCatalogSample,
        PatchbayCatalogSource,
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
