// PB-050-38：snapshot payload 的**有界字节 sink**。
//
// 它是双预算里唯一真正会判红的那一段：每次写入前先算 projected 长度，越界当场中止，
// 绝不先拼出完整 String 再量长度（PB-050-01 与 PB-050-02 都明确禁止后者，因为那样
// 保护不了峰值内存）。
//
// 越界时选哪一种拒绝由**较小的那条预算**决定，而不是由 encoder 恰好怎么分块决定：
// 只有当运行预算就是天花板本身时，PB-050-01 的契约失败才说话；否则一律是 PB-050-02
// 的资源拒绝。这条规则写在这里而不是散在调用点，正是为了让它只有一份定义。
//
// [PatchbaySnapshotBoundedByteSink.currentPath] 是调用方在每次写入前更新的现场标记；
// 契约失败回显的 `path` 就是它，因此「写这一段字节时算站在哪个节点上」由调用方负责，
// sink 只负责如实引用。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:convert';
import 'dart:typed_data';

import 'snapshot_payload_limits.dart';

final class PatchbaySnapshotBoundedByteSink extends ByteConversionSinkBase {
  PatchbaySnapshotBoundedByteSink(this._limits, {bool retainBytes = false})
    : _builder = retainBytes ? BytesBuilder(copy: false) : null;

  final PatchbaySnapshotPayloadLimits _limits;
  final BytesBuilder? _builder;
  var _length = 0;
  String currentPath = r'$';

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void close() => addSlice(const <int>[], 0, 0, true);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    final int count = end - start;
    final int projected = _length + count;
    final int runBytes = _limits.maxRunCanonicalBytes;
    if (projected > runBytes) {
      // The smaller budget always decides, so the answer does not depend on
      // how the encoder happened to chunk this write. The PB-050-01 ceiling
      // only speaks when it *is* the effective budget.
      if (runBytes >= _limits.maxCanonicalBytes) {
        throw PatchbaySnapshotPayloadFault.tooLarge(
          path: currentPath,
          limitKind: 'canonicalBytes',
          limit: _limits.maxCanonicalBytes,
          observed: _limits.maxCanonicalBytes + 1,
        );
      }
      throw PatchbaySnapshotPayloadFault.runBudget(
        limit: runBytes,
        observed: projected,
      );
    }
    _length += count;
    _builder?.add(chunk.sublist(start, end));
  }

  /// 已经写入并计费的字节数。
  int get length => _length;

  /// 容器的开括号。JSON 结构字符只有这一处定义，两个遍历共用同一份。
  void writeContainerOpen({required bool isMap}) =>
      add(isMap ? _openMap : _openList);

  /// 容器的闭括号。
  void writeContainerClose({required bool isMap}) =>
      add(isMap ? _closeMap : _closeList);

  void writeComma() => add(_comma);

  void writeColon() => add(_colon);

  /// 把一个 JSON 标量（含 map key 字符串）按 UTF-8 写进本 sink。
  ///
  /// 走 chunked conversion 而不是 `jsonEncode`，是为了让编码结果**边产生边计费**：
  /// 超长字符串在写到一半时就会撞上预算，不会先在内存里成型。
  void writeJsonScalar(Object? value) {
    final ByteConversionSink output = _NonClosingByteSink(this);
    final ChunkedConversionSink<Object?> input = JsonUtf8Encoder()
        .startChunkedConversion(output);
    input.add(value);
    input.close();
  }

  Uint8List takeBytes() => _builder?.takeBytes() ?? Uint8List(0);
}

/// 转发写入但**吞掉 close**：一次标量编码结束不等于整份 payload 结束。
final class _NonClosingByteSink extends ByteConversionSinkBase {
  _NonClosingByteSink(this.target);

  final PatchbaySnapshotBoundedByteSink target;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void close() {}

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    target.addSlice(chunk, start, end, false);
  }
}

const List<int> _openMap = <int>[0x7b];
const List<int> _closeMap = <int>[0x7d];
const List<int> _openList = <int>[0x5b];
const List<int> _closeList = <int>[0x5d];
const List<int> _comma = <int>[0x2c];
const List<int> _colon = <int>[0x3a];
