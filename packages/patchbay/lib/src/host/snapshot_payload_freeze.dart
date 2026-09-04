// PB-050-38：snapshot payload 的**冻结遍历**。
//
// 这一段回答的是「consumer 交来的这张图能不能变成一棵合法、独立、不可变的 JSON 树」，
// 顺带在同一次经过里把字节与出现次数计完。它必须是显式栈的迭代遍历——PB-050-01 明确
// 要求验证不依赖 Dart 调用栈深度，否则深结构会以 `StackOverflowError` 越过普通 RPC
// 失败边界。因此这里有 [_PendingValue] / [_CompletedValue] / [_FreezeFrame] 三件套，
// 而不是一个递归函数。
//
// 三条硬闸在这一次经过里各就各位：深度在进入容器时判、出现次数由计数器判、字节由
// sink 判。字节按**插入顺序**计费（不是 canonical 顺序），因为这一趟走的就是 consumer
// 给的顺序；canonical 顺序是下一段的事。两趟都计费不是重复劳动：这一趟保证「构造副本
// 之前就停」，canonical 那一趟保证「最终输出也在预算内」。
//
// 冻结体保留原 map/list 的迭代顺序（响应体的 key 顺序由它决定），并在每一层套上
// unmodifiable 视图——consumer 在 source 返回之后继续改自己的对象，不能再影响本次
// 响应、selector、revision 与 diff。
//
// 遍历接缝（sink 与出现次数计数器）都可注入，因此失败注入不必构造真的超大 payload。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:collection';

import 'snapshot_payload_bytes.dart';
import 'snapshot_payload_limits.dart';
import 'snapshot_payload_path.dart';

final class PatchbaySnapshotFreezingTraversal {
  PatchbaySnapshotFreezingTraversal(
    this.limits, {
    PatchbaySnapshotBoundedByteSink? sink,
    PatchbaySnapshotOccurrenceCounter? occurrences,
  }) : _bytes = sink ?? PatchbaySnapshotBoundedByteSink(limits),
       _occurrences = occurrences ?? PatchbaySnapshotOccurrenceCounter(limits);

  final PatchbaySnapshotPayloadLimits limits;
  final PatchbaySnapshotBoundedByteSink _bytes;
  final PatchbaySnapshotOccurrenceCounter _occurrences;
  final Set<Object> _ancestry = HashSet<Object>.identity();
  final List<_FreezeFrame> _frames = <_FreezeFrame>[];

  Object? freeze(Object? source) {
    _PendingValue? pending = _PendingValue(
      source,
      PatchbaySnapshotPath.root,
      0,
    );
    _CompletedValue? completed;
    while (true) {
      if (pending != null) {
        final Object? value = pending.value;
        if (value is Map<Object?, Object?>) {
          _startContainer(value, pending.path, pending.depth, isMap: true);
          pending = null;
        } else if (value is List<Object?>) {
          _startContainer(value, pending.path, pending.depth, isMap: false);
          pending = null;
        } else {
          _writeScalar(value, pending.path);
          completed = _CompletedValue(value);
          pending = null;
        }
      }

      if (completed != null) {
        if (_frames.isEmpty) return completed.value;
        _frames.last.accept(completed.value);
        completed = null;
      }

      while (pending == null && completed == null) {
        if (_frames.isEmpty) {
          throw StateError('snapshot traversal ended without a root value');
        }
        final _FreezeFrame frame = _frames.last;
        final _PendingValue? next = frame.next(this);
        if (next != null) {
          pending = next;
          break;
        }
        _frames.removeLast();
        _bytes.currentPath = frame.path.value;
        _bytes.writeContainerClose(isMap: frame.isMap);
        _ancestry.remove(frame.source);
        completed = _CompletedValue(frame.complete());
      }
    }
  }

  void _startContainer(
    Object source,
    PatchbaySnapshotPath path,
    int depth, {
    required bool isMap,
  }) {
    if (depth > limits.maxContainerDepth) {
      throw PatchbaySnapshotPayloadFault.invalid(
        failure: 'nestingTooDeep',
        path: path.value,
      );
    }
    if (!_ancestry.add(source)) {
      throw PatchbaySnapshotPayloadFault.invalid(
        failure: 'cycleDetected',
        path: path.value,
      );
    }
    _bytes.currentPath = path.value;
    _bytes.writeContainerOpen(isMap: isMap);
    _occurrences.count(path);
    _frames.add(
      isMap
          ? _MapFreezeFrame(source as Map<Object?, Object?>, path, depth)
          : _ListFreezeFrame(source as List<Object?>, path, depth),
    );
  }

  void _writeScalar(Object? value, PatchbaySnapshotPath path) {
    if (value is double && !value.isFinite) {
      throw PatchbaySnapshotPayloadFault.invalid(
        failure: 'nonFiniteNumber',
        path: path.value,
      );
    }
    if (value != null && value is! bool && value is! num && value is! String) {
      throw PatchbaySnapshotPayloadFault.invalid(
        failure: 'unsupportedType',
        path: path.value,
        type: value.runtimeType.toString(),
      );
    }
    _bytes.currentPath = path.value;
    _bytes.writeJsonScalar(value);
    _occurrences.count(path);
  }

  void _writeMapKey(
    PatchbaySnapshotPath parentPath,
    String key, {
    required bool first,
  }) {
    final PatchbaySnapshotPath path = parentPath.objectKey(key);
    _bytes.currentPath = path.value;
    if (!first) _bytes.writeComma();
    _bytes.writeJsonScalar(key);
    _bytes.writeColon();
    _occurrences.count(path);
  }

  void _writeListSeparator(PatchbaySnapshotPath path, {required bool first}) {
    _bytes.currentPath = path.value;
    if (!first) _bytes.writeComma();
  }

  Never nonStringKey(PatchbaySnapshotPath parentPath, Object? key) {
    throw PatchbaySnapshotPayloadFault.invalid(
      failure: 'nonStringKey',
      path: parentPath.value,
      type: key.runtimeType.toString(),
    );
  }
}

abstract base class _FreezeFrame {
  _FreezeFrame(this.source, this.path, this.depth);

  final Object source;
  final PatchbaySnapshotPath path;
  final int depth;
  bool get isMap;
  _PendingValue? next(PatchbaySnapshotFreezingTraversal traversal);
  void accept(Object? value);
  Object complete();
}

final class _MapFreezeFrame extends _FreezeFrame {
  _MapFreezeFrame(
    Map<Object?, Object?> source,
    PatchbaySnapshotPath path,
    int depth,
  ) : _entries = source.entries.iterator,
      super(source, path, depth);

  final Iterator<MapEntry<Object?, Object?>> _entries;
  final Map<String, Object?> _output = <String, Object?>{};
  String? _key;
  var _first = true;

  @override
  bool get isMap => true;

  @override
  _PendingValue? next(PatchbaySnapshotFreezingTraversal traversal) {
    if (!_entries.moveNext()) return null;
    final MapEntry<Object?, Object?> entry = _entries.current;
    final Object? rawKey = entry.key;
    if (rawKey is! String) traversal.nonStringKey(path, rawKey);
    _key = rawKey;
    traversal._writeMapKey(path, rawKey, first: _first);
    _first = false;
    return _PendingValue(entry.value, path.objectKey(rawKey), depth + 1);
  }

  @override
  void accept(Object? value) {
    _output[_key!] = value;
    _key = null;
  }

  @override
  Object complete() => Map<String, Object?>.unmodifiable(_output);
}

final class _ListFreezeFrame extends _FreezeFrame {
  _ListFreezeFrame(List<Object?> source, PatchbaySnapshotPath path, int depth)
    : _items = source.iterator,
      super(source, path, depth);

  final Iterator<Object?> _items;
  final List<Object?> _output = <Object?>[];
  var _index = 0;

  @override
  bool get isMap => false;

  @override
  _PendingValue? next(PatchbaySnapshotFreezingTraversal traversal) {
    if (!_items.moveNext()) return null;
    final PatchbaySnapshotPath childPath = path.listIndex(_index++);
    traversal._writeListSeparator(childPath, first: _index == 1);
    return _PendingValue(_items.current, childPath, depth + 1);
  }

  @override
  void accept(Object? value) => _output.add(value);

  @override
  Object complete() => List<Object?>.unmodifiable(_output);
}

final class _PendingValue {
  const _PendingValue(this.value, this.path, this.depth);

  final Object? value;
  final PatchbaySnapshotPath path;
  final int depth;
}

final class _CompletedValue {
  const _CompletedValue(this.value);

  final Object? value;
}
