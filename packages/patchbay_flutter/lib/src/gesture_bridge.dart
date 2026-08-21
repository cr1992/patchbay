// 拆分前 `gesture_bridge.dart` 的公共面。gesture/ 下的其余类型是拆分产物，
// 不因为被拆出来就成为公共 API。
export 'gesture/gesture_bridge.dart' show PatchbayGestureBridge;
export 'gesture/gesture_models.dart'
    show
        PatchbayGestureDecision,
        PatchbayGestureDelay,
        PatchbayGestureKind,
        PatchbayGesturePolicy,
        PatchbayGestureTarget,
        PatchbayPointerEventDispatcher;
