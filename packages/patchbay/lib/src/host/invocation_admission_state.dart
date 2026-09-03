// PB-050-38 / DG-060-04：admission pipeline 各阶段共用的**唯一可变账本**。
//
// 它刻意只有四个字段，且没有「是否走过 X」的布尔位：每个阶段进入时覆写
// [PatchbayInvocationAuditState.admissionStage]，因此最后留下的值就是这次调用
// 停在的阶段——不需要另一套「到哪一步了」的记账跟着阶段顺序一起维护。
//
// 这份状态是 host-only 的：它只喂给 `PatchbayAuditEvent`，任何字段都不进
// invocation envelope，也不进 rejection details。DG-060-04 的原话是把内部阶段
// 写进公共应答会让重构拓扑变成协议。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
library;

/// 一次调用在 admission pipeline 上的准入事实。
///
/// 各阶段以可选参数收下它并就地写入；测试可以脱离 host 单独构造，断言某个阶段
/// 究竟把 pipeline 推到了哪里。
final class PatchbayInvocationAuditState {
  String gateResult = 'notEvaluated';

  /// Where the pipeline currently stands. Overwritten as each stage is entered,
  /// so whatever value survives is the stage the invocation stopped at — no
  /// separate "did we get past X" bookkeeping to keep in sync.
  String admissionStage = 'catalog';
  String gateDisposition = 'notReached';
  bool recorded = false;
}
