// PB-050-38：`PatchbaySemanticsAction` 的两处**封闭分类**。
//
// 它们是准入管线两个不同阶段的输入判据（遮挡准入与 identifier 路径的参数校验），
// 拆到这里是为了让分类本身可以脱离桥单独读、单独测：判据写在哪个阶段里都容易被
// 后来的编辑顺手放宽，摆在一起则必须对着判据解释。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'semantics_models.dart';

extension PatchbaySemanticsActionTaxonomy on PatchbaySemanticsAction {
  /// PB-050-16 / DG-050-09：点性 action 的封闭分类。
  ///
  /// 判据：真实用户对应物是一次落在目标边界内单点上的指针接触——有指针对应物、
  /// 对应物是单点而不是路径或方向、覆盖该点即改变真实用户的可达性，三条同时
  /// 成立才算点性。`tap` 与 `longPress` 是单点 down/(hold)/up；`focus` 与
  /// `setText` 没有位置对应物；`scroll*` 的对应物是拖动，部分覆盖也应可滚动；
  /// `showOnScreen` 按定义要在目标尚不可达时工作；其余是纯辅助功能语义。
  /// `longPress` 还不在 0.5.0 的公开 allowlist 内，提前分类只为它将来进
  /// allowlist 时按构造继承本闸。
  ///
  /// 穷尽 switch、**无 `default` 分支**：`PatchbaySemanticsAction` 新增值时
  /// 编译期就必须显式分类，而不是靠后来的记忆。
  bool get isPointLike => switch (this) {
    PatchbaySemanticsAction.tap => true,
    PatchbaySemanticsAction.longPress => true,
    PatchbaySemanticsAction.focus => false,
    PatchbaySemanticsAction.dismiss => false,
    PatchbaySemanticsAction.showOnScreen => false,
    PatchbaySemanticsAction.scrollUp => false,
    PatchbaySemanticsAction.scrollDown => false,
    PatchbaySemanticsAction.scrollLeft => false,
    PatchbaySemanticsAction.scrollRight => false,
    PatchbaySemanticsAction.increase => false,
    PatchbaySemanticsAction.decrease => false,
    PatchbaySemanticsAction.expand => false,
    PatchbaySemanticsAction.collapse => false,
    PatchbaySemanticsAction.setText => false,
  };

  /// identifier 路径当前公开声明的 action 集合。同样是穷尽 switch、无 `default`。
  bool get isPublicIdentifierAction => switch (this) {
    PatchbaySemanticsAction.tap ||
    PatchbaySemanticsAction.focus ||
    PatchbaySemanticsAction.scrollUp ||
    PatchbaySemanticsAction.scrollDown ||
    PatchbaySemanticsAction.scrollLeft ||
    PatchbaySemanticsAction.scrollRight ||
    PatchbaySemanticsAction.setText => true,
    PatchbaySemanticsAction.longPress ||
    PatchbaySemanticsAction.dismiss ||
    PatchbaySemanticsAction.showOnScreen ||
    PatchbaySemanticsAction.increase ||
    PatchbaySemanticsAction.decrease ||
    PatchbaySemanticsAction.expand ||
    PatchbaySemanticsAction.collapse => false,
  };
}
