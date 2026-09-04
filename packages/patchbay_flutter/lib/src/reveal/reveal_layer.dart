// PB-050-38：一层容器在步循环里的可变状态机。
//
// 从 `reveal_engine.dart` 拆出来：引擎负责「这一步该不该走、走完之后是不是终
// 态」，本文件只负责「在这一个容器上，下一次派发哪个 action、还算不算有进展」。
//
// 极性（谁增大 `pixels`）在这里学习与翻转，停滞阈值也在这里累加——两者都是纯
// 状态迁移，不读语义树、不产生终态，因此可以直接构造实例做失败注入。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import '../semantics/semantics_models.dart';
import 'reveal_container_facts.dart';
import 'reveal_models.dart';

/// 一层容器在循环中的可变状态。
///
/// 这是 reveal 里唯一一处「跨步累积」的东西：极性、当前 action、停滞计数与该层
/// 是否已耗尽。把它独立出来之后，换向、探测步与停滞阈值可以直接构造一个
/// [PatchbayRevealLayer] 来验证，不必先摆出一棵语义树再跑满一次调用。
final class PatchbayRevealLayer {
  PatchbayRevealLayer({
    required this.anchorIdentifier,
    required this.nodeId,
    required this.generation,
    required this.decision,
    required this._axis,
    required this.requested,
  });

  final String? anchorIdentifier;
  final int nodeId;
  final int generation;
  final PatchbayRevealDecision decision;
  final PatchbayRevealAxis? _axis;
  final PatchbayRevealDirection requested;

  PatchbayRevealContainerRecord? record;
  int stall = 0;

  /// 由同步判定点（早停 / stall 达阈值）记下的「该层耗尽」。
  bool exhausted = false;

  /// 已知的极性：内容序 forward 落到的那个 action。null 表示还没观察到。
  PatchbaySemanticsAction? _forward;

  /// 当前正在驱动的 action；null 表示还没选定。
  PatchbaySemanticsAction? _active;
  final Set<PatchbaySemanticsAction> _driven = <PatchbaySemanticsAction>{};
  bool _probeSpent = false;

  /// 本步要派发的 action，null 表示这一步无从派发。
  PatchbaySemanticsAction? actionFor(SemanticsData data) {
    final PatchbayRevealAxis? axis = _axis;
    if (axis == null) return null;
    final List<PatchbaySemanticsAction> exposed = axis.exposedIn(data);
    if (exposed.isEmpty) return null;

    // 事实一：只暴露一个同轴 action 时，`pixels` 处于某一端，极性由端点唯一
    // 确定——在 min 处暴露的是 forward，在 max 处暴露的是 backward。零成本。
    _inferFromEnd(data, exposed);

    final PatchbaySemanticsAction? active = _active;
    if (active != null) return exposed.contains(active) ? active : null;

    if (requested == PatchbayRevealDirection.both) {
      // `both` 不需要极性：两个 action 各自驱动到耗尽，顺序不影响结果；极性只
      // 用于给 containers[].direction 打标签，而每一步都会观察位移符号。
      for (final PatchbaySemanticsAction candidate in exposed) {
        if (_driven.contains(candidate)) continue;
        _active = candidate;
        return candidate;
      }
      return null;
    }

    final PatchbaySemanticsAction? mapped = _mappedFor(requested);
    if (mapped != null) {
      if (!exposed.contains(mapped)) return null;
      _active = mapped;
      return mapped;
    }
    // 两个同轴 action 都暴露且请求方向是显式的：需要一步探测步。它计入 steps
    // 与 containers[].steps，每容器每次调用至多一次，且发生在门与 policy 复核
    // 之后——它本身也是一次完整授权下的驱动。
    if (_probeSpent) return null;
    _probeSpent = true;
    _active = exposed.first;
    return _active;
  }

  void _inferFromEnd(
    SemanticsData data,
    List<PatchbaySemanticsAction> exposed,
  ) {
    _forward ??= patchbayRevealForwardFromEnd(data, _axis!, exposed);
  }

  PatchbaySemanticsAction? _mappedFor(PatchbayRevealDirection wanted) {
    final PatchbaySemanticsAction? forward = _forward;
    if (forward == null) return null;
    return wanted == PatchbayRevealDirection.forward
        ? forward
        : _axis!.other(forward);
  }

  /// 派发一步之后由位移符号确定极性。
  ///
  /// 探测步走反了就为该容器翻转映射并继续：`_active` 换成正确的那一个。
  void learnPolarity(PatchbaySemanticsAction action, double delta) {
    _driven.add(action);
    if (delta == 0) return;
    _forward ??= delta > 0 ? action : _axis!.other(action);
    if (requested == PatchbayRevealDirection.both) return;
    final PatchbaySemanticsAction? mapped = _mappedFor(requested);
    if (mapped != null && mapped != _active) {
      _active = mapped;
      stall = 0;
    }
  }

  /// 该 action 这一步实际把内容推向了哪个方向。
  PatchbayRevealDirection labelFor(PatchbaySemanticsAction action) {
    final PatchbaySemanticsAction? forward = _forward;
    if (forward == null) return requested;
    return action == forward
        ? PatchbayRevealDirection.forward
        : PatchbayRevealDirection.backward;
  }

  /// 记一次无进展；返回 true 表示该层在这次调用里已经耗尽。
  ///
  /// 顺序即语义：先累加，未到阈值不做任何判断；到阈值先试换向（`both` 才可能
  /// 成功），换不动才算耗尽。调用点据此决定是否升层。
  bool noteStallExhausted() {
    stall += 1;
    if (stall < PatchbayRevealBudget.stallSteps) return false;
    return !flipIfPossible();
  }

  /// `both` 且该容器还有没走过的同轴 action ⇒ 换向、stall 归零。
  bool flipIfPossible() {
    final PatchbayRevealAxis? axis = _axis;
    if (axis == null || requested != PatchbayRevealDirection.both) return false;
    final PatchbaySemanticsAction? active = _active;
    if (active == null) return false;
    final PatchbaySemanticsAction other = axis.other(active);
    if (_driven.contains(other)) return false;
    _active = other;
    stall = 0;
    return true;
  }
}
