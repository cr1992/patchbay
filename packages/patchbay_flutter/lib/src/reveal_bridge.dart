// PB-050-17 的公共面。reveal/ 下的其余类型是拆分产物，不因为被拆出来就成为
// 公共 API（与 gesture/ 下的约定一致）。
export 'reveal/reveal_bridge.dart' show PatchbayRevealBridge;
export 'reveal/reveal_models.dart'
    show PatchbayRevealDecision, PatchbayRevealDirection, PatchbayRevealPolicy;
