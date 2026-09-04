// PB-050-38：snapshot payload 的**门面与编排**。
//
// 冻结一次 snapshot 是四段处理，每一段现在各有一个文件、各自可单独构造与失败注入：
//
// 1. `snapshot_payload_limits.dart`：限额模型与两类拒绝的成型；
// 2. `snapshot_payload_path.dart`：结构路径与展开 occurrence 记账；
// 3. `snapshot_payload_bytes.dart`：有界字节 sink，双预算在这里判红；
// 4. `snapshot_payload_freeze.dart` 与 `snapshot_payload_canonical.dart`：两趟遍历，
//    前者产出保留插入顺序的不可变冻结体，后者产出按 key 排序的 canonical 字节。
//
// 本文件只留三件事：对外类型、上面四段的调用顺序，以及**边界翻译**——内部
// `PatchbaySnapshotPayloadFault` 到对外 [PatchbaySnapshotPayloadViolation] 的唯一转换点。
// 这个翻译只有一份，任何阶段都不得自己构造对外违规，否则「同一种错在不同阶段长得不一样」
// 会从此不可证伪。
//
// 兜底 catch 同样只有一份：冻结与 canonical 编码内部的任何其他异常统一收敛成根路径上的
// `unsupportedType`，只回显 runtimeType。PB-050-01 要求 host 不能被一份 provider payload
// 以未捕获异常结束请求，也不能把 provider 数据或异常 message 漏回去。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:convert';
import 'dart:typed_data';

import 'snapshot_payload_canonical.dart';
import 'snapshot_payload_freeze.dart';
import 'snapshot_payload_limits.dart';

export 'snapshot_payload_limits.dart';

enum PatchbaySnapshotPayloadStage { beforeFreeze, beforeCanonical }

final class PatchbayFrozenSnapshotPayload {
  const PatchbayFrozenSnapshotPayload({
    required this.body,
    required this.canonical,
    required this.canonicalBytes,
  });

  final Map<String, Object?> body;
  final String canonical;

  /// UTF-8 length of [canonical], counted by the bounded sink that produced
  /// it rather than re-encoded afterwards.
  final int canonicalBytes;
}

final class PatchbaySnapshotPayloadViolation implements Exception {
  PatchbaySnapshotPayloadViolation._(
    this._token,
    Map<String, Object?> details, {
    this.kind = PatchbaySnapshotPayloadViolationKind.contract,
  }) : details = Map<String, Object?>.unmodifiable(details);

  final Object _token;
  final Map<String, Object?> details;
  final PatchbaySnapshotPayloadViolationKind kind;

  bool belongsTo(Object token) => identical(_token, token);
}

final class PatchbaySnapshotPayloadFreezer {
  const PatchbaySnapshotPayloadFreezer({
    this.limits = PatchbaySnapshotPayloadLimits.production,
    this.testStageHook,
  });

  final PatchbaySnapshotPayloadLimits limits;
  final void Function(PatchbaySnapshotPayloadStage stage)? testStageHook;

  PatchbayFrozenSnapshotPayload freeze(
    Object? source, {
    Object? violationToken,
  }) {
    final Object token = violationToken ?? Object();
    try {
      testStageHook?.call(PatchbaySnapshotPayloadStage.beforeFreeze);
      final Object? frozen = PatchbaySnapshotFreezingTraversal(
        limits,
      ).freeze(source);
      if (frozen is! Map<String, Object?>) {
        throw PatchbaySnapshotPayloadFault.invalid(
          failure: 'unsupportedType',
          path: r'$',
          type: frozen.runtimeType.toString(),
        );
      }
      testStageHook?.call(PatchbaySnapshotPayloadStage.beforeCanonical);
      final Uint8List canonical = PatchbaySnapshotCanonicalJsonWriter(
        limits,
      ).encode(frozen);
      return PatchbayFrozenSnapshotPayload(
        body: frozen,
        canonical: utf8.decode(canonical),
        canonicalBytes: canonical.length,
      );
    } on PatchbaySnapshotPayloadFault catch (error) {
      throw PatchbaySnapshotPayloadViolation._(
        token,
        error.details,
        kind: error.kind,
      );
    } on Object catch (error) {
      throw PatchbaySnapshotPayloadViolation._(token, <String, Object?>{
        'reason': 'snapshotPayloadInvalid',
        'failure': 'unsupportedType',
        'path': r'$',
        'type': error.runtimeType.toString(),
      });
    }
  }
}
