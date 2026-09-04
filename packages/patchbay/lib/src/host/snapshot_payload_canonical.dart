// PB-050-38：snapshot payload 的**canonical 字节序列化**。
//
// 这一段只对**已经冻结好的**树说话：它按 key 排序重新走一遍，产出用于相等比较与字节
// 计量的 canonical 字节。它不做任何合法性判断——上一段已经证明了这棵树是合法 JSON，
// 这里再判一次只会让「同一种错在两处各写一遍」慢慢分叉。
//
// 排序按 `String.sort()`，也就是 UTF-16 code unit 序；canonical 只决定相等比较与字节
// 数，**不决定响应体的 key 顺序**（响应体用的是冻结体保留的插入顺序）。这两个顺序是
// PB-050-01 刻意分开的两件事。
//
// 与冻结遍历同理，这里也是显式栈迭代而不是递归，并且同样把每一次写入交给有界 sink：
// 这一趟的 sink 保留字节（`retainBytes: true`），因为它的产物就是最终 canonical。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:typed_data';

import 'snapshot_payload_bytes.dart';
import 'snapshot_payload_limits.dart';
import 'snapshot_payload_path.dart';

final class PatchbaySnapshotCanonicalJsonWriter {
  /// 注入的 sink 必须与 [limits] **同预算**：接缝用来预置状态和观察调用，不是第二个
  /// 预算真值源。
  PatchbaySnapshotCanonicalJsonWriter(
    PatchbaySnapshotPayloadLimits limits, {
    PatchbaySnapshotBoundedByteSink? sink,
  }) : assert(
         sink == null || sink.limits.sameBudgetsAs(limits),
         'injected byte sink must share the writer budgets',
       ),
       _sink =
           sink ?? PatchbaySnapshotBoundedByteSink(limits, retainBytes: true);

  final PatchbaySnapshotBoundedByteSink _sink;

  Uint8List encode(Object? root) {
    final List<_CanonicalFrame> frames = <_CanonicalFrame>[];
    Object? pending = root;
    var pendingPath = PatchbaySnapshotPath.root;
    var hasPending = true;
    while (true) {
      if (hasPending) {
        final Object? value = pending;
        _sink.currentPath = pendingPath.value;
        if (value is Map<String, Object?>) {
          _sink.writeContainerOpen(isMap: true);
          frames.add(_CanonicalMapFrame(value, pendingPath));
        } else if (value is Map<Object?, Object?>) {
          // 管线内不可达：冻结遍历产出的每一层都是 `Map<String, Object?>`，非字符串
          // key 在那一段就已按 `nonStringKey` 判红。但本类是可以单独构造的，不显式
          // 拒绝的话，一份 `Map<Object?, Object?>` 会掉进标量分支被 JSON 编码器按
          // **插入顺序**写出去——一个悄悄不排序、也不报错的 canonical，比抛错危险得多。
          throw ArgumentError.value(
            value.runtimeType.toString(),
            'root',
            'canonical writer only accepts a frozen Map<String, Object?>',
          );
        } else if (value is List<Object?>) {
          _sink.writeContainerOpen(isMap: false);
          frames.add(_CanonicalListFrame(value, pendingPath));
        } else {
          _sink.writeJsonScalar(value);
        }
        hasPending = false;
      }

      while (!hasPending) {
        if (frames.isEmpty) return _sink.takeBytes();
        final _CanonicalFrame frame = frames.last;
        final _CanonicalNext? next = frame.next(_sink);
        if (next != null) {
          pending = next.value;
          pendingPath = next.path;
          hasPending = true;
          break;
        }
        frames.removeLast();
        _sink.currentPath = frame.path.value;
        _sink.writeContainerClose(isMap: frame.isMap);
      }
    }
  }
}

abstract base class _CanonicalFrame {
  PatchbaySnapshotPath get path;
  bool get isMap;
  _CanonicalNext? next(PatchbaySnapshotBoundedByteSink sink);
}

final class _CanonicalMapFrame extends _CanonicalFrame {
  _CanonicalMapFrame(this.source, this.path)
    : _keys = source.keys.toList(growable: false)..sort();

  final Map<String, Object?> source;
  @override
  final PatchbaySnapshotPath path;
  final List<String> _keys;
  var _index = 0;

  @override
  bool get isMap => true;

  @override
  _CanonicalNext? next(PatchbaySnapshotBoundedByteSink sink) {
    if (_index >= _keys.length) return null;
    if (_index > 0) sink.writeComma();
    final String key = _keys[_index++];
    sink.writeJsonScalar(key);
    sink.writeColon();
    return _CanonicalNext(source[key], path.objectKey(key));
  }
}

final class _CanonicalListFrame extends _CanonicalFrame {
  _CanonicalListFrame(this.source, this.path);

  final List<Object?> source;
  @override
  final PatchbaySnapshotPath path;
  var _index = 0;

  @override
  bool get isMap => false;

  @override
  _CanonicalNext? next(PatchbaySnapshotBoundedByteSink sink) {
    if (_index >= source.length) return null;
    if (_index > 0) sink.writeComma();
    final int index = _index++;
    return _CanonicalNext(source[index], path.listIndex(index));
  }
}

final class _CanonicalNext {
  const _CanonicalNext(this.value, this.path);

  final Object? value;
  final PatchbaySnapshotPath path;
}
