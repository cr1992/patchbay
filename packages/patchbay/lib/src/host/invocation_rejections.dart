// PB-050-38 / DG-060-04：admission pipeline 各阶段共用的**拒绝投影**。
//
// 拆开阶段之后，同一个拒绝形状会被两三个阶段构造（`providerProtocolViolation`
// 由 catalog、门后复核和 response validation 三处产出），所以它们必须只有一份
// 定义——否则「拒绝长什么样」会随阶段各写一遍而缓慢分叉，而这些形状是稳定 JSON，
// 连键序都被 CLI 与老 reader 按位置读过。
//
// 这里的函数全是同步纯函数：给定 requestId 与事实就得到一块完整的应答，调用方
// 原样 return 即可，不需要再决定拒绝长什么样。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'dart:convert';

import '../invocation.dart';
import '../response_schema.dart';

/// `providerProtocolViolation` 的统一投影。
///
/// [reason] 是封闭词表里的稳定原因，[details] 追加在它后面——键序即契约。
Map<String, Object?> patchbayInvalidInvocationEnvelope(
  String requestId,
  String reason, [
  Map<String, Object?> details = const <String, Object?>{},
]) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: 'providerProtocolViolation',
    details: <String, Object?>{'reason': reason, ...details},
  ),
).toJson();

/// 响应 schema / 执行证据校验失败的投影：首条 issue 抬到顶层，全量列在
/// `violations` 里。
Map<String, Object?> patchbayResponseSchemaViolation(
  String requestId,
  List<PatchbayResponseValidationIssue> issues,
) {
  final PatchbayResponseValidationIssue first = issues.first;
  return patchbayInvalidInvocationEnvelope(
    requestId,
    first.reason,
    <String, Object?>{
      'field': first.field,
      if (first.expected != null) 'expected': first.expected!,
      'violations': issues
          .map((PatchbayResponseValidationIssue issue) => issue.toJson())
          .toList(growable: false),
    },
  );
}

/// external 账本的重复请求拒绝：`requestIdConflict` / `duplicateRequestId` /
/// `requestLedgerFull` 共用这一个空 details 的形状。
Map<String, Object?> patchbayExternalDuplicateRejection(
  String requestId,
  String code,
) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(code: code),
).toJson();

/// A gate rejection in the shape the UI plane already uses.
///
/// `priorRequestObserved` is the one extra fact: because the gate runs
/// before ledger replay, a caller retrying an already-served requestId can
/// receive a rejection for work that *did* happen. Without this flag it
/// could read the rejection as "nothing happened", pick a fresh requestId
/// and cause a second effect. The flag says only that this requestId was
/// admitted before — never what it did, or with which arguments.
Map<String, Object?> patchbayDomainGateRejection({
  required String requestId,
  required String code,
  required String gateId,
  required bool priorRequestObserved,
  String? notice,
  String? reason,
}) => PatchbayInvocation.rejected(
  requestId: requestId,
  rejection: PatchbayRejection(
    code: code,
    notice: notice,
    details: <String, Object?>{
      'gateId': gateId,
      if (reason != null) 'reason': reason,
      if (priorRequestObserved) 'priorRequestObserved': true,
    },
  ),
).toJson();

/// 去掉 stdin 出处的元信息键。它是 host 与 consumer adapter 的边界事实，不该
/// 越过边界，也不该进审计。
Map<String, Object?> patchbayWithoutStdinProvenance(
  Map<String, Object?> arguments,
) => arguments.containsKey('inputWasStdin')
    ? (Map<String, Object?>.of(arguments)..remove('inputWasStdin'))
    : arguments;

/// 把 provider 交回来的应答冻结成一份只含 JSON 类型的独立副本。
///
/// consumer 可能继续持有并改写自己那个 `Map`；账本要重放的必须是「当时答了什么」。
Map<String, Object?> patchbayFreezeJsonMap(Map<String, Object?> value) =>
    Map<String, Object?>.from(
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
    );
