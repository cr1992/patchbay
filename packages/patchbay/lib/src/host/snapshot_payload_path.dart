// PB-050-38：snapshot payload 的**路径与出现次数记账**。
//
// 两件事放在一起，是因为它们是同一件事的两半：遍历每经过一个 JSON 节点，既要知道
// 它的结构路径（用于拒绝时的 `path`），也要给它记一次出现。PB-050-01 明确规定这份
// 计费按**出现次数**而不是 Dart object identity 结算——共享无环子树第二次出现要重新
// 展开、重新计数，所以计数器不能挂在被冻结的对象上，只能挂在遍历上。
//
// [PatchbaySnapshotPath] 只承载对象 key 与数组下标，从不承载值。无法安全表示的 key
// （不匹配 `[A-Za-z_][A-Za-z0-9_]*` 或超过 128 个字符）会让路径**就地封口**：此后
// 所有后代都复用父路径，不再追加任何片段。这是隐私边界，不是省事——把任意 key 拼进
// 路径等于把 snapshot 内容漏进拒绝 details。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'snapshot_payload_limits.dart';

final class PatchbaySnapshotPath {
  const PatchbaySnapshotPath._(this.value, this._appendable);

  static const PatchbaySnapshotPath root = PatchbaySnapshotPath._(r'$', true);

  final String value;
  final bool _appendable;

  PatchbaySnapshotPath objectKey(String key) {
    if (!_appendable) return this;
    if (key.length <= 128 && _simplePathKey.hasMatch(key)) {
      return PatchbaySnapshotPath._('$value.$key', true);
    }
    return PatchbaySnapshotPath._(value, false);
  }

  PatchbaySnapshotPath listIndex(int index) =>
      _appendable ? PatchbaySnapshotPath._('$value[$index]', true) : this;
}

final RegExp _simplePathKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// 展开 occurrence 的计数器：PB-050-01 的第二条硬闸。
///
/// 深度只防递归链，字节只管最终 payload 尺寸；这一条负责给遍历步数本身加 backstop，
/// 让共享 DAG 的指数展开在构造出完整副本之前就停下。三者互不替代。
final class PatchbaySnapshotOccurrenceCounter {
  PatchbaySnapshotOccurrenceCounter(this.limits);

  final PatchbaySnapshotPayloadLimits limits;
  var _observed = 0;

  /// 已经计入的出现次数。
  int get observed => _observed;

  /// 给 [path] 上的一次出现记账；越界即抛出，计数**不**推进。
  void count(PatchbaySnapshotPath path) {
    final int observed = _observed + 1;
    if (observed > limits.maxExpandedOccurrences) {
      throw PatchbaySnapshotPayloadFault.tooLarge(
        path: path.value,
        limitKind: 'expandedNodes',
        limit: limits.maxExpandedOccurrences,
        observed: observed,
      );
    }
    _observed = observed;
  }
}
