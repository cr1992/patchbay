// PB-050-38：准入管线的最后两个阶段——**遮挡准入**与**派发**。
//
// 它们必须留在同一个文件里，因为两者之间的「不得插入 await」是这条管线唯一一处
// 靠位置维持的安全性质：
//
// - [patchbaySemanticsOcclusionFence] 是**同步**函数（PB-050-16 / DG-050-09）。
//   位置是冻结的——门后二次 policy 与敏感输入复核之后、`performAction` 之前，全程
//   只有这一处（门前的判定不权威：声明 gate 的 await 恰恰是覆盖层出现的窗口）。
//   结论只对这一次派发有效，不缓存、不跨调用复用，也不因为遮挡而重解析、等待或
//   重试——写操作不重放。
// - [patchbaySemanticsPerformAction] 虽然签名是 `async`，但 Dart 的 async 函数体在
//   第一个 `await` 之前**同步执行**，所以 `performAction` 与上面那次复核在同一个
//   微任务内，用的是同一次 resolve 得到的 owner/节点。**不要在 `performAction`
//   之前加任何 `await`**，那会重新打开这条管线专门关掉的漂移窗口。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:patchbay/patchbay_host.dart';

import '../occlusion/occlusion_probe.dart';
import 'semantics_action_taxonomy.dart';
import 'semantics_evidence.dart';
import 'semantics_models.dart';

/// 点性 action 的固定采样遮挡准入。放行返回 `null`。
///
/// 非点性 action 直接放行：`scroll*` 的真实对应物是拖动、`focus` / `setText` 没有
/// 位置对应物、`showOnScreen` 按定义要在目标尚不可达时工作，用点覆盖去拒绝它们
/// 会把正确的调用判死。分类见 [PatchbaySemanticsActionTaxonomy]。
PatchbayInvocation? patchbaySemanticsOcclusionFence({
  required String requestId,
  required PatchbaySemanticsAction action,
  required SemanticsOwner owner,
  required SemanticsNode node,
  required int nodeId,
  required int generation,
  String? identifier,
}) {
  if (!action.isPointLike) return null;
  final String? obscuredReason = patchbaySampledOcclusionReason(
    owner: owner,
    node: node,
  );
  if (obscuredReason == null) return null;
  return PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: 'uiSemanticsTargetObscured',
      details: patchbaySemanticsObscuredEvidence(
        reason: obscuredReason,
        nodeId: nodeId,
        generation: generation,
        identifier: identifier,
      ),
    ),
  );
}

/// 实际派发。
///
/// 派发本身抛出**不是拒绝**：请求已经受理过了，异常只改变执行结论，所以答复仍是
/// accepted，载荷 `outcome` 为 `failed` 并只带异常类型。
///
/// [treeRevision] 在 `performAction` 前后各读一次，[refreshOwner] 在等到帧末之后
/// 调用一次——两个读数之间夹的正是这次派发驱动的那一帧。
Future<PatchbayInvocation> patchbaySemanticsPerformAction({
  required String requestId,
  required SemanticsOwner owner,
  required PatchbaySemanticsAction action,
  required int nodeId,
  required int generation,
  required bool sensitive,
  required int Function() treeRevision,
  required void Function() refreshOwner,
  String? identifier,
  String? text,
}) async {
  final int beforeRevision = treeRevision();
  try {
    owner.performAction(
      nodeId,
      action.flutterAction,
      action == PatchbaySemanticsAction.setText ? text : null,
    );
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    refreshOwner();
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: patchbaySemanticsDispatchedPayload(
        action: action,
        nodeId: nodeId,
        generation: generation,
        beforeTreeRevision: beforeRevision,
        afterTreeRevision: treeRevision(),
        sensitive: sensitive,
        identifier: identifier,
        text: text,
      ),
    );
  } catch (error) {
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: patchbaySemanticsFailedPayload(
        action: action,
        nodeId: nodeId,
        generation: generation,
        error: error,
        identifier: identifier,
      ),
    );
  }
}
