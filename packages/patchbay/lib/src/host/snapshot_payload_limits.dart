// PB-050-38：snapshot payload 的**限额模型与预算判定**。
//
// 这一层只回答两个问题，且只回答这两个：某条预算的数值是多少，以及越界时应该
// 构造出哪一种类型化拒绝。它不遍历任何数据、不写任何字节——真正的计费发生在
// `snapshot_payload_path.dart`（出现次数）与 `snapshot_payload_bytes.dart`（字节），
// 两处都把判定结果交回这里成型。
//
// 双预算的分工来自两份已接受的 Proposal，拆开之后仍然逐字保持：
//
// - PB-050-01 的 [PatchbaySnapshotPayloadLimits.maxCanonicalBytes] 是安全天花板，
//   越过它是 provider 契约失败（[PatchbaySnapshotPayloadViolationKind.contract]）；
// - PB-050-02 的 [PatchbaySnapshotPayloadLimits.maxRunCanonicalBytes] 是 host 配置的
//   运行预算，永远不高于天花板，越过它是资源拒绝
//   （[PatchbaySnapshotPayloadViolationKind.runBudget]），调用方可以换更小的 snapshot 重试。
//
// 两类拒绝**回显的东西不同**：契约失败带结构 path 与限额三元组，资源拒绝只带两个
// 计数——path 或 canonical 片段会把 snapshot 内容漏进一个资源答复里。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。

const int patchbaySnapshotMaxContainerDepth = 128;
const int patchbaySnapshotMaxExpandedOccurrences = 2 * 1024 * 1024;
const int patchbaySnapshotMaxCanonicalBytes = 4 * 1024 * 1024;

final class PatchbaySnapshotPayloadLimits {
  const PatchbaySnapshotPayloadLimits({
    required this.maxContainerDepth,
    required this.maxExpandedOccurrences,
    required this.maxCanonicalBytes,
    int? maxRunCanonicalBytes,
  }) : assert(maxContainerDepth >= 0),
       assert(maxExpandedOccurrences > 0),
       assert(maxCanonicalBytes > 0),
       assert(maxRunCanonicalBytes == null || maxRunCanonicalBytes > 0),
       assert(
         maxRunCanonicalBytes == null ||
             maxRunCanonicalBytes <= maxCanonicalBytes,
       ),
       _maxRunCanonicalBytes = maxRunCanonicalBytes;

  static const PatchbaySnapshotPayloadLimits production =
      PatchbaySnapshotPayloadLimits(
        maxContainerDepth: patchbaySnapshotMaxContainerDepth,
        maxExpandedOccurrences: patchbaySnapshotMaxExpandedOccurrences,
        maxCanonicalBytes: patchbaySnapshotMaxCanonicalBytes,
      );

  final int maxContainerDepth;
  final int maxExpandedOccurrences;

  /// The safety ceiling from PB-050-01. Crossing it is a provider contract
  /// failure, not a budget the host operator chose.
  final int maxCanonicalBytes;

  final int? _maxRunCanonicalBytes;

  /// The configured per-snapshot budget from PB-050-02, never above
  /// [maxCanonicalBytes]. Crossing it while it is strictly smaller is a
  /// resource rejection the caller can retry against a smaller snapshot.
  int get maxRunCanonicalBytes => _maxRunCanonicalBytes ?? maxCanonicalBytes;

  PatchbaySnapshotPayloadLimits withRunCanonicalBytes(int bytes) =>
      PatchbaySnapshotPayloadLimits(
        maxContainerDepth: maxContainerDepth,
        maxExpandedOccurrences: maxExpandedOccurrences,
        maxCanonicalBytes: maxCanonicalBytes,
        maxRunCanonicalBytes: bytes < maxCanonicalBytes
            ? bytes
            : maxCanonicalBytes,
      );
}

/// Which budget a payload violation belongs to.
///
/// The two are not interchangeable: [contract] means the App handed the host
/// something it may never accept, while [runBudget] means the snapshot was
/// well formed but larger than the budget this host was configured with.
enum PatchbaySnapshotPayloadViolationKind { contract, runBudget }

/// 单个阶段抛出的内部故障。
///
/// 它只在包内旅行：`PatchbaySnapshotPayloadFreezer` 在边界上把它翻成对外的
/// `PatchbaySnapshotPayloadViolation`。每个阶段都只构造它、不构造对外类型，
/// 因此「哪一段判红」与「对外长什么样」可以分开测。
final class PatchbaySnapshotPayloadFault implements Exception {
  const PatchbaySnapshotPayloadFault._(this.details, this.kind);

  factory PatchbaySnapshotPayloadFault.invalid({
    required String failure,
    required String path,
    String? type,
  }) => PatchbaySnapshotPayloadFault._(<String, Object?>{
    'reason': 'snapshotPayloadInvalid',
    'failure': failure,
    'path': path,
    if (type != null) 'type': type,
  }, PatchbaySnapshotPayloadViolationKind.contract);

  factory PatchbaySnapshotPayloadFault.tooLarge({
    required String path,
    required String limitKind,
    required int limit,
    required int observed,
  }) => PatchbaySnapshotPayloadFault._(<String, Object?>{
    'reason': 'snapshotPayloadInvalid',
    'failure': 'payloadTooLarge',
    'path': path,
    'limitKind': limitKind,
    'limit': limit,
    'observed': observed,
  }, PatchbaySnapshotPayloadViolationKind.contract);

  /// The configured per-snapshot budget was crossed.
  ///
  /// Only the two counters travel: a path or a canonical excerpt would leak
  /// snapshot content into a resource answer.
  factory PatchbaySnapshotPayloadFault.runBudget({
    required int limit,
    required int observed,
  }) => PatchbaySnapshotPayloadFault._(<String, Object?>{
    'encodedBytesAtLeast': observed,
    'maxSnapshotBytes': limit,
  }, PatchbaySnapshotPayloadViolationKind.runBudget);

  final Map<String, Object?> details;
  final PatchbaySnapshotPayloadViolationKind kind;
}
