// 拆分前 `semantics_bridge.dart` 的公共面，见 gesture_bridge.dart 的说明。
export 'gesture_bridge.dart';
export 'semantics/semantics_bridge.dart' show PatchbaySemanticsBridge;
export 'semantics/semantics_models.dart'
    show
        PatchbaySemanticsAction,
        PatchbaySemanticsActionDecision,
        PatchbaySemanticsActionPolicy,
        PatchbaySemanticsIdentifierMatch,
        PatchbaySemanticsIdentifierObservation,
        PatchbaySemanticsTarget;
