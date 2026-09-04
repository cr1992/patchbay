// PB-050-38：一步之内的**重评、派发与记账**。
//
// 从 `reveal_engine.dart` 拆出来。这一阶段守着 reveal 授权模型里最紧的那条
// 时序约束：门放行与 `performAction` 之间不得出现任何 await / yield，否则被
// 授权的那块区域可能在两者之间换掉。因此
// [patchbayRevealDispatchScroll] 是**同步**的，[patchbayRevealBeforeDeadline]
// 也保持「一个 async 函数、一次 await」的形状——多包一层就多一个让步窗口，
// `reveal_engine_microtask_depth_test.dart` 会判红。
//
// 机制唯一：本文件是整个 reveal 里唯一调用 `performAction` 的地方，且只派发
// 传入的同轴 scroll action，**从不派发 `showOnScreen`**。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../semantics/semantics_models.dart';
import 'reveal_layer.dart';
import 'reveal_models.dart';

/// 一次带 deadline 的等待结果：要么完成并带回值，要么超时。
///
/// 「超时」与「完成但值为 null」是两个事实，不折叠成一个 nullable。
final class PatchbayRevealTimed<T> {
  const PatchbayRevealTimed.completed(T this.value) : completed = true;
  const PatchbayRevealTimed.timeout() : completed = false, value = null;

  final bool completed;
  final T? value;
}

/// 在 [deadline] 之前等 [future]，超时即如实回报而不是抛。
///
/// 剩余时长按调用时刻的墙钟算一次；已经过期就连 await 都不做——那一步不该再
/// 给任何人一个让步窗口。
Future<PatchbayRevealTimed<T>> patchbayRevealBeforeDeadline<T>(
  Future<T> future,
  DateTime deadline,
) async {
  final Duration remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) return PatchbayRevealTimed<T>.timeout();
  try {
    return PatchbayRevealTimed<T>.completed(await future.timeout(remaining));
  } on TimeoutException {
    return PatchbayRevealTimed<T>.timeout();
  }
}

/// 与 gesture 的 `_decisionEquals` 同构：四项逐项相等才继续。
bool patchbayRevealSameDecision(
  PatchbayRevealDecision left,
  PatchbayRevealDecision right,
) =>
    left.allowed == right.allowed &&
    setEquals(left.gateIds, right.gateIds) &&
    left.maxSteps == right.maxSteps &&
    left.maxDurationMs == right.maxDurationMs;

/// 同步派发一次 scroll action；成功返回 null，失败返回异常的 `runtimeType`。
///
/// **同步**是契约的一部分：调用点保证门与这次派发之间没有 await，本函数不得
/// 自己引入一个。失败只回报类型名——message 与 stack 可能带上接入方的业务串，
/// 不进 payload。
String? patchbayRevealDispatchScroll({
  required SemanticsOwner owner,
  required int nodeId,
  required PatchbaySemanticsAction action,
}) {
  try {
    owner.performAction(nodeId, action.flutterAction);
    return null;
  } catch (error) {
    return error.runtimeType.toString();
  }
}

/// 记一次派发：容器第一次被驱动时追加记录，之后只累加步数。
///
/// 元素只在第一次在该容器上派发时追加，因此 `steps >= 1`，因此
/// `containers.isEmpty <=> 顶层 steps == 0`。这条不变式是 payload 契约，
/// 不是实现细节。
void patchbayRevealRecordDispatch({
  required PatchbayRevealLayer layer,
  required List<PatchbayRevealContainerRecord> containers,
}) {
  final PatchbayRevealContainerRecord? existing = layer.record;
  if (existing != null) {
    existing.steps += 1;
    return;
  }
  final PatchbayRevealContainerRecord record = PatchbayRevealContainerRecord(
    nodeId: layer.nodeId,
    generation: layer.generation,
  )..steps = 1;
  layer.record = record;
  containers.add(record);
}
