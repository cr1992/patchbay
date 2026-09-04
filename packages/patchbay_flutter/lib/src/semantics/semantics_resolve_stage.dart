// PB-050-38：准入管线的**解析阶段**——把 identifier 或 nodeId 变成一个已复核的
// 目标，或一个说得清原因的拒绝。
//
// 两条路径合成一个阶段是因为它们回答同一个问题、产出同一个
// [PatchbaySemanticsResolution]，并且必须给出**同一份**候选事实：调用方按 nodeId
// 选中的节点被拒时，应当拿到和 identifier 路径一样的证据，而不是一枚裸码。
//
// 阶段的全部依赖走构造参数注入的接缝——owner 由 `ensureOwner` 给、代际由 `observe`
// 给、已观察账本由 `entryFor` 查、树版本号由 `treeRevision` 读。桥不是它的前置
// 条件，所以这个阶段能在测试里脱离桥单独构造，并逐条注入失败（owner 缺失、歧义、
// 代际漂移、账本缺条目）。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:flutter/rendering.dart';

import 'semantics_evidence.dart';
import 'semantics_lookup.dart';
import 'semantics_models.dart';

final class PatchbaySemanticsTargetResolver {
  const PatchbaySemanticsTargetResolver({
    required this._ensureOwner,
    required this._observe,
    required this._entryFor,
    required this._treeRevision,
  });

  /// 未命中时回报的已挂载 identifier 上限。超出只截断清单，不改 `matchCount`
  /// 与 `mountedIdentifierCount`——截断的是证据的体积，不是事实本身。
  static const int maxReportedIdentifiers = 20;

  final Future<SemanticsOwner?> Function() _ensureOwner;
  final PatchbaySemanticsEntry Function(SemanticsNode node) _observe;
  final PatchbaySemanticsEntry? Function(int nodeId) _entryFor;
  final int Function() _treeRevision;

  /// 按稳定 identifier 解析。
  ///
  /// 歧义 fail-closed：不按树顺序挑一个，也不用 label / value 兜底。
  Future<PatchbaySemanticsResolution> byIdentifier({
    required String identifier,
    required int? expectedGeneration,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsUnavailable',
        details: <String, Object?>{'identifier': identifier},
      );
    }

    final List<SemanticsNode> matches = <SemanticsNode>[];
    final Set<String> mounted = <String>{};
    patchbayVisitSemantics(root, (SemanticsNode node) {
      final SemanticsData data = node.getSemanticsData();
      if (data.identifier.isNotEmpty) mounted.add(data.identifier);
      if (data.identifier == identifier) matches.add(node);
    });

    if (matches.isEmpty) {
      final List<String> reported = mounted.toList()..sort();
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsIdentifierNotFound',
        details: <String, Object?>{
          'identifier': identifier,
          'treeRevision': _treeRevision(),
          'matchCount': 0,
          'mountedIdentifierCount': reported.length,
          'mountedIdentifiers': reported
              .take(maxReportedIdentifiers)
              .toList(growable: false),
          'mountedIdentifiersTruncated':
              reported.length > maxReportedIdentifiers,
        },
      );
    }
    if (matches.length > 1) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsIdentifierAmbiguous',
        details: <String, Object?>{
          'identifier': identifier,
          'treeRevision': _treeRevision(),
          'matchCount': matches.length,
          'candidates': <Object?>[
            for (final SemanticsNode node in matches)
              patchbaySemanticsCandidateEvidence(
                node,
                node.getSemanticsData(),
                generation: _observe(node).generation,
              ),
          ],
        },
      );
    }

    final SemanticsNode node = matches.single;
    final PatchbaySemanticsEntry entry = _observe(node);
    if (expectedGeneration != null && entry.generation != expectedGeneration) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsGenerationStale',
        details: <String, Object?>{
          'identifier': identifier,
          'nodeId': node.id,
          'expectedGeneration': expectedGeneration,
          'currentGeneration': entry.generation,
        },
      );
    }
    return _admit(owner, node, entry, action);
  }

  /// 按 nodeId 解析，附带调用方声明的代际围栏。
  Future<PatchbaySemanticsResolution> byNodeId({
    required int nodeId,
    required int generation,
    required PatchbaySemanticsAction action,
  }) async {
    final SemanticsOwner? owner = await _ensureOwner();
    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (owner == null || root == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsUnavailable',
      );
    }
    final SemanticsNode? node = patchbaySemanticsNodeById(root, nodeId);
    if (node == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsNodeNotFound',
      );
    }
    final PatchbaySemanticsEntry? entry = _entryFor(nodeId);
    if (entry == null || entry.node.target == null) {
      return const PatchbaySemanticsResolution.rejected(
        'uiSemanticsNodeNotObserved',
      );
    }
    if (entry.generation != generation || !identical(entry.node.target, node)) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsGenerationStale',
        details: <String, Object?>{
          'nodeId': nodeId,
          'expectedGeneration': generation,
          'currentGeneration': entry.generation,
        },
      );
    }
    // From here the nodeId path answers with the same candidate details as
    // the identifier path: a caller who chose a node by id gets told why that
    // node cannot take the action, not just that it cannot.
    return _admit(owner, node, entry, action);
  }

  /// 两条路径共用的收尾复核：可达性与 action 可用性，然后投影出目标。
  PatchbaySemanticsResolution _admit(
    SemanticsOwner owner,
    SemanticsNode node,
    PatchbaySemanticsEntry entry,
    PatchbaySemanticsAction action,
  ) {
    final SemanticsData data = node.getSemanticsData();
    if (node.isInvisible || node.areUserActionsBlocked) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionBlocked',
        details: patchbaySemanticsCandidateEvidence(
          node,
          data,
          generation: _observe(node).generation,
        ),
      );
    }
    if (!data.hasAction(action.flutterAction)) {
      return PatchbaySemanticsResolution.rejected(
        'uiSemanticsActionUnavailable',
        details: <String, Object?>{
          ...patchbaySemanticsCandidateEvidence(
            node,
            data,
            generation: _observe(node).generation,
          ),
          'requestedAction': action.name,
        },
      );
    }
    return PatchbaySemanticsResolution.resolved(
      owner,
      patchbaySemanticsTargetOf(node, data, generation: entry.generation),
      node,
    );
  }
}
