/// Patchbay 的 protocol / wire implementer 入口（PB-060-02 / DG-060-02）。
///
/// 内容是生成的 `*Wire` 类型、catalog capability 与 digest、CLI syntax 词汇、permission
/// companion 协议、client 侧请求类型，以及 canonical protocol command descriptor。写第三方
/// transport、复刻 CLI 行为或直接构造 wire 文档时用它。
///
/// 它同样是自足闭包：canonical descriptor 常量的类型是 `PatchbayCommandDescriptor`，所以
/// descriptor / schema 这一组 consumer 类型也在本清单里。**本入口与默认 consumer 入口有意
/// 重叠**——重叠的是两个闭包都真正需要的类型，不是把默认面整库带过来。同时 import 两个入口
/// 不会冲突。
///
/// 本 library 不 re-export host 面：`PatchbayServiceHost`、audit 与 invocation lifecycle
/// 只在 `package:patchbay/patchbay_host.dart`。
///
/// 这里的类型跟着 wire 走：字段与 JSON 形态由协议决定，不是给业务代码当 DTO 用的便利类型。
library;

export 'src/audit.dart' show patchbayParameterShape;
export 'src/catalog_digest.dart'
    show
        PatchbayCatalogDigest,
        patchbayCanonicalJson,
        patchbayCatalogDigestScopeCommands,
        patchbayDigestAlgorithmSha256;
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
export 'src/execution_evidence.dart' show PatchbayExecutionContract;
export 'src/facts.dart' show PatchbayFactSource;
export 'src/features.dart' show PatchbayFeature;
export 'src/generated/core_wire.g.dart'
    show
        PatchbayAdmissionWire,
        PatchbayBlobChunkWire,
        PatchbayBlobMetadataRequestWire,
        PatchbayBlobMetadataWire,
        PatchbayBlobReadRequestWire,
        PatchbayBlobSourceWire,
        PatchbayCaptureDiffRequestWire,
        PatchbayCaptureDiffResultWire,
        PatchbayCaptureRequestWire,
        PatchbayCaptureResultWire,
        PatchbayCaptureTargetWire,
        PatchbayCaptureWarningWire,
        PatchbayCatalogDigestWire,
        PatchbayCommandDescriptorWire,
        PatchbayCommandModeWire,
        PatchbayDestinationDescriptorWire,
        PatchbayFactSourceWire,
        PatchbayIdentityWire,
        PatchbayInspectReleaseWire,
        PatchbayInspectSelectRequestWire,
        PatchbayInspectStateWire,
        PatchbayInspectUnavailableWire,
        PatchbayInvocationWire,
        PatchbayJobEventWire,
        PatchbayJobPhaseWire,
        PatchbayJobSnapshotWire,
        PatchbayJobWaitOutcomeWire,
        PatchbayJobWaitResultWire,
        PatchbayKeepAwakeReleaseWire,
        PatchbayKeepAwakeRequestWire,
        PatchbayKeepAwakeStateWire,
        PatchbayLogBatchOutcomeWire,
        PatchbayLogBatchWire,
        PatchbayLogDirectionWire,
        PatchbayLogExportRequestWire,
        PatchbayLogExportResultWire,
        PatchbayLogLevelWire,
        PatchbayLogQueryRequestWire,
        PatchbayLogRecordWire,
        PatchbayLogRedactionWire,
        PatchbayLogTailRequestWire,
        PatchbayLogTruncationWire,
        PatchbayNavigationCatalogWire,
        PatchbayNavigationCurrentWire,
        PatchbayNavigationOperationWire,
        PatchbayNavigationResultWire,
        PatchbayParameterDescriptorWire,
        PatchbayParameterTypeWire,
        PatchbayPlaneWire,
        PatchbayRejectionWire,
        PatchbayRevealContainerWire,
        PatchbayRevealDirectionWire,
        PatchbayRevealReachabilityWire,
        PatchbayRevealRequestWire,
        PatchbayRevealResultWire,
        PatchbaySemanticsNodeWire,
        PatchbaySemanticsRectWire,
        PatchbaySemanticsSnapshotWire,
        PatchbaySensitivePolicyWire,
        PatchbaySideEffectWire,
        PatchbaySnapshotConditionWire,
        PatchbaySnapshotDiffRequestWire,
        PatchbaySnapshotMissWire,
        PatchbaySnapshotRequestWire,
        PatchbaySnapshotSelectionWire,
        PatchbaySnapshotWaitWire,
        PatchbayUiTargetDescriptorWire,
        PatchbayUiTargetKindWire,
        PatchbayUiWaitConditionWire,
        PatchbayUiWaitRequestWire,
        PatchbayUiWaitResultWire;
export 'src/permissions.dart'
    show
        PatchbayPermissionAction,
        PatchbayPermissionCapabilities,
        PatchbayPermissionCapability,
        PatchbayPermissionDecision,
        PatchbayPermissionDriverRequest,
        PatchbayPermissionDriverResponse,
        PatchbayPermissionEvidence,
        PatchbayPermissionFactSource,
        PatchbayPermissionInterruption,
        PatchbayPermissionOperation,
        PatchbayPermissionState,
        PatchbayPermissionStatus,
        PatchbayPermissionWireException,
        patchbayPermissionProtocolMajor,
        patchbayPermissionProtocolMajorOf,
        patchbayPermissionProtocolVersion;
export 'src/protocol_commands.dart'
    show
        patchbayNavigationBackCommandDescriptor,
        patchbayNavigationCatalogCommandDescriptor,
        patchbayNavigationCurrentCommandDescriptor,
        patchbayNavigationGoCommandDescriptor,
        patchbayNavigationPushCommandDescriptor,
        patchbayProtocolCliCommandDescriptors;
export 'src/response_schema.dart'
    show
        PatchbayResponseSchema,
        PatchbayResponseType,
        PatchbayResponseValueSchema;
export 'src/snapshot.dart'
    show
        PatchbaySnapshotCondition,
        PatchbaySnapshotDiffRequest,
        PatchbaySnapshotMiss,
        PatchbaySnapshotRequest,
        PatchbaySnapshotSelection,
        patchbayJsonEquals;
export 'src/ui_descriptor.dart' show PatchbayPlane, PatchbaySideEffect;
export 'src/ui_protocol_commands.dart'
    show
        patchbayUiCaptureCommandDescriptor,
        patchbayUiGestureDragCommandDescriptor,
        patchbayUiGestureFlingCommandDescriptor,
        patchbayUiGesturePressHoldCommandDescriptor,
        patchbayUiGestureTapCommandDescriptor,
        patchbayUiInspectSelectCommandDescriptor,
        patchbayUiInspectStatusCommandDescriptor,
        patchbayUiKeepAwakeSetCommandDescriptor,
        patchbayUiKeepAwakeStatusCommandDescriptor,
        patchbayUiProtocolCliCommandDescriptors,
        patchbayUiRevealCommandDescriptor,
        patchbayUiSemanticsActionByIdentifierCommandDescriptor,
        patchbayUiSemanticsActionCommandDescriptor,
        patchbayUiSemanticsTapCommandDescriptor,
        patchbayUiSemanticsTreeCommandDescriptor,
        patchbayUiTextEnterCommandDescriptor,
        patchbayUiTextSetCommandDescriptor,
        patchbayUiWaitCommandDescriptor;
export 'src/ui_wait.dart' show PatchbayUiWaitCondition, PatchbayUiWaitRequest;
