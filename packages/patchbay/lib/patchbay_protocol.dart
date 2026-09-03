/// Patchbay 的 protocol / wire implementer 入口（PB-060-02 / DG-060-02）。
///
/// 内容是生成的 `*Wire` 类型、catalog capability 与 digest、CLI syntax 词汇、
/// permission companion 协议、client 侧请求类型，以及 canonical protocol command
/// descriptor。写第三方 transport、复刻 CLI 行为或直接构造 wire 文档时用它。
///
/// 本 library 与默认 consumer 面、host 面都不相交：它既不 re-export
/// `package:patchbay/patchbay.dart`，也不 re-export
/// `package:patchbay/patchbay_host.dart`。需要多个角色就写多个显式 import。
///
/// 这里的类型跟着 wire 走：字段与 JSON 形态由协议决定，不是给业务代码当 DTO 用的
/// 便利类型。
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
        PatchbayCliSyntax;
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
export 'src/snapshot.dart'
    show
        PatchbaySnapshotCondition,
        PatchbaySnapshotDiffRequest,
        PatchbaySnapshotMiss,
        PatchbaySnapshotRequest,
        PatchbaySnapshotSelection,
        patchbayJsonEquals;
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
