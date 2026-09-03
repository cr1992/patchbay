// PB-050-38 / DG-060-04：external command 的 **requestId 账本**。
//
// 账本回答一个问题：这条 `(command, requestId)` 之前有没有被受理过，如果有，
// 这次该重放、该拒，还是该新开一条。它被咨询两次，而两次的位置是有意义的：
//
//   - **preflight**，在编排最前面。命中已有记录时直接给出重放或重复拒绝，
//     调用方拿到的是「上次答了什么」而不是又跑一遍副作用；
//   - **dispatch**，在门之后。这一次才会预留槽位并真正调 provider——门是当下的
//     授权判断，放在槽位之前，慢门就不会把无关命令挤成 `requestLedgerFull`。
//
// provider 调用以接缝注入，冻结应答（`jsonDecode(jsonEncode(...))`）留在账本内：
// 要重放的必须是「当时答了什么」，而 consumer 完全可能继续改写自己那个 `Map`。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:async';

import '../catalog_digest.dart';
import '../command_descriptor.dart';
import '../invocation_cancellation.dart';
import 'host_models.dart';
import 'invocation_rejections.dart';

/// provider 调用接缝：host 按构造时的两个源二选一后交给账本。
typedef PatchbayExternalInvoke =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
      PatchbayInvocationContext context,
    );

/// preflight 的三种结论。
final class PatchbayExternalPreflight {
  const PatchbayExternalPreflight.none() : replay = null, rejection = null;

  const PatchbayExternalPreflight.replay(
    Future<Map<String, Object?>> this.replay,
  ) : rejection = null;

  const PatchbayExternalPreflight.rejected(Map<String, Object?> this.rejection)
    : replay = null;

  /// 已受理过且可幂等重放时，上一次那条应答。
  final Future<Map<String, Object?>>? replay;

  /// `requestIdConflict` / `duplicateRequestId` 的成形拒绝。
  final Map<String, Object?>? rejection;

  bool get isEmpty => replay == null && rejection == null;
}

/// external 命令的 requestId 账本。
final class PatchbayExternalInvocationLedger {
  PatchbayExternalInvocationLedger({required PatchbayExternalInvoke invoke})
    : _invoke = invoke;

  static const int slotCapacity = 256;

  final PatchbayExternalInvoke _invoke;
  final Map<(String, String), PatchbayExternalInvocationRecord> _records =
      <(String, String), PatchbayExternalInvocationRecord>{};

  /// 账本里是否已经有这条 requestId。门拒绝据此补 `priorRequestObserved`。
  bool contains(String command, String requestId) =>
      _records.containsKey((command, requestId));

  /// 编排最前的账本咨询。
  ///
  /// [registryOwned] 为真时账本不参与——registry 命令根本不走这本账。参数摘要同时
  /// 按原始形态与剥掉 stdin 出处的形态比对，因为记录是用转发后的参数建的。
  PatchbayExternalPreflight preflight({
    required String command,
    required Map<String, Object?> arguments,
    required String requestId,
    required bool registryOwned,
    required String? ownerToken,
  }) {
    if (registryOwned) return const PatchbayExternalPreflight.none();
    final PatchbayExternalInvocationRecord? existing =
        _records[(command, requestId)];
    if (existing == null) return const PatchbayExternalPreflight.none();
    final String rawDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      arguments,
    ]).value;
    final String forwardedDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      patchbayWithoutStdinProvenance(arguments),
    ]).value;
    final bool sameArguments =
        existing.argumentDigest == rawDigest ||
        existing.argumentDigest == forwardedDigest;
    final bool sameOwner =
        ownerToken == null || existing.ownerToken == ownerToken;
    if (sameArguments && existing.idempotent && sameOwner) {
      return PatchbayExternalPreflight.replay(existing.servedResponse.future);
    }
    return PatchbayExternalPreflight.rejected(
      patchbayExternalDuplicateRejection(
        requestId,
        !sameArguments || !sameOwner
            ? 'requestIdConflict'
            : 'duplicateRequestId',
      ),
    );
  }

  /// 门之后的实际派发：查重 → 预留槽位 → 建记录 → 调 provider。
  Future<Map<String, Object?>> dispatch({
    required String command,
    required Map<String, Object?> arguments,
    required String requestId,
    required PatchbayRetryPolicy? retryPolicy,
    required void Function(String disposition) onDisposition,
    required PatchbayInvocationContext context,
    required String? ownerToken,
  }) async {
    final (String, String) key = (command, requestId);
    final String argumentDigest = PatchbayCatalogDigest.ofCommands(<Object?>[
      arguments,
    ]).value;
    final PatchbayExternalInvocationRecord? existing = _records[key];
    if (existing != null) {
      if (existing.argumentDigest != argumentDigest) {
        onDisposition('rejection');
        return patchbayExternalDuplicateRejection(
          requestId,
          'requestIdConflict',
        );
      }
      if (!existing.idempotent) {
        onDisposition('rejection');
        return patchbayExternalDuplicateRejection(
          requestId,
          'duplicateRequestId',
        );
      }
      onDisposition('replay');
      return existing.response;
    }
    if (!reserveSlot()) {
      onDisposition('rejection');
      return patchbayExternalDuplicateRejection(requestId, 'requestLedgerFull');
    }
    onDisposition('owner');
    final PatchbayExternalInvocationRecord record =
        PatchbayExternalInvocationRecord(
          argumentDigest: argumentDigest,
          idempotent: retryPolicy != null,
          ownerToken: ownerToken,
        );
    _records[key] = record;
    record.response = () async {
      try {
        return patchbayFreezeJsonMap(
          await _invoke(command, arguments, requestId, context),
        );
      } finally {
        record.settled = true;
      }
    }();
    return record.response;
  }

  /// 槽位预留：满了就回收一条已结算的记录，一条都回收不动才判满。
  bool reserveSlot() {
    if (_records.length < slotCapacity) return true;
    for (final MapEntry<(String, String), PatchbayExternalInvocationRecord>
        entry
        in _records.entries) {
      if (!entry.value.settled) continue;
      _records.remove(entry.key);
      return true;
    }
    return false;
  }

  /// 把这次实际送出的应答记进记录，供后续幂等重放取回。
  void settleOwner(
    String command,
    String requestId,
    Map<String, Object?> response,
  ) => _records[(command, requestId)]?.servedResponse.complete(response);

  /// 派发抛出时同样要落到记录上，否则等待重放的一方会永远悬着。
  void failOwner(
    String command,
    String requestId,
    Object error,
    StackTrace stackTrace,
  ) => _records[(command, requestId)]?.servedResponse.completeError(
    error,
    stackTrace,
  );
}
