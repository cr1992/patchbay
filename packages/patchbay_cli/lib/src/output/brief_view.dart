/// PB-050-21: `--view brief` projects a decoded App response down to the
/// decision facts a machine consumer needs before it decides whether to
/// expand the rest, without ever changing a value or a key that survives
/// the projection.
///
/// The projection table below is the frozen contract from
/// `docs/proposals/0.5.0/brief-view.md` — a closed deny-list, not a
/// white-list: only the paths listed here are ever removed, and everything
/// else in the response passes through untouched, including legacy fields,
/// consumer payloads and future protocol additions the table does not know
/// about yet.
///
/// This file is deliberately not re-exported from `patchbay_cli.dart`: it is
/// an internal implementation detail of the CLI's own output shaping, not a
/// public SDK surface.
library;

import '../command_registry.dart';
import '../result.dart';

/// `--view` values accepted by the CLI.
const String patchbayViewFull = 'full';
const String patchbayViewBrief = 'brief';

/// One deny-list projection rule: delete [leafKey] from the map reached by
/// walking [containerPath] off the response root (or from the root itself
/// when [containerPath] is empty), or — when [arrayContainer] is set — from
/// every map element of the list at that path.
///
/// [pattern] is the literal, table-shaped path string recorded in
/// `localView.omitted` when this rule actually removes something; it is
/// never derived from the instance being projected, so it can never leak a
/// consumer key name, a target id or session information.
final class _ProjectionRule {
  const _ProjectionRule({
    required this.pattern,
    required this.containerPath,
    required this.leafKey,
    this.arrayContainer = false,
  });

  final String pattern;
  final List<String> containerPath;
  final String leafKey;
  final bool arrayContainer;
}

/// Section 5.1: evaluated for every accepted response regardless of which
/// family (if any) matches below.
const _ProjectionRule _noticeRule = _ProjectionRule(
  pattern: r'$.notice',
  containerPath: <String>[],
  leafKey: 'notice',
);

/// Section 5.2: `catalog`. `name`/`plane`/`mode`/`sideEffect`/`summary`/
/// `factSources`/`gates` and `uiTargets`/`catalogDigest` are untouched — they
/// are the minimal facts "should I call this" needs.
///
/// `summary` is deliberately **not** in this table: the 2026-08-25 ruling on
/// brief-view.md's open question 3 kept it, because it is the only clue an
/// agent has about what a command does before it spends a `describe` round
/// trip. Deleting it would save bytes by removing the one field that makes
/// the rest of a brief catalog actionable.
const List<_ProjectionRule> _catalogRules = <_ProjectionRule>[
  _ProjectionRule(
    pattern: r'$.commands[].parameters',
    containerPath: <String>['commands'],
    leafKey: 'parameters',
    arrayContainer: true,
  ),
  _ProjectionRule(
    pattern: r'$.commands[].responseSchema',
    containerPath: <String>['commands'],
    leafKey: 'responseSchema',
    arrayContainer: true,
  ),
  _ProjectionRule(
    pattern: r'$.commands[].executionContract',
    containerPath: <String>['commands'],
    leafKey: 'executionContract',
    arrayContainer: true,
  ),
  _ProjectionRule(
    pattern: r'$.commands[].retryPolicy',
    containerPath: <String>['commands'],
    leafKey: 'retryPolicy',
    arrayContainer: true,
  ),
];

/// Section 5.3: `ui.semantics.tree`. `outcome`/`source`/`treeRevision`/
/// `rootNodeId`/`truncated`/`nodeCount` stay.
const List<_ProjectionRule> _semanticsTreeRules = <_ProjectionRule>[
  _ProjectionRule(
    pattern: r'$.payload.nodes',
    containerPath: <String>['payload'],
    leafKey: 'nodes',
  ),
];

/// Section 5.4: the three Flutter diagnostic-tree passthroughs
/// (`ui widget-tree` / `render-tree` / `focus-tree`). `source`/`plane`/
/// `schema`/`extension`/`format`/`warnings` stay — `warnings` is the one
/// place the SDK-drift caveat lives.
const List<_ProjectionRule> _diagnosticTreeRules = <_ProjectionRule>[
  _ProjectionRule(
    pattern: r'$.data',
    containerPath: <String>[],
    leafKey: 'data',
  ),
];

/// Section 5.5: `logs.query`. `outcome`/`source`/`nextCursor`/
/// `currentCursor`/`truncated`/`truncation`/`elapsedMs` stay.
const List<_ProjectionRule> _logsQueryRules = <_ProjectionRule>[
  _ProjectionRule(
    pattern: r'$.payload.records',
    containerPath: <String>['payload'],
    leafKey: 'records',
  ),
];

/// One family's rule set plus the `localView.projection` id it reports.
final class _Family {
  const _Family(this.id, this.rules);

  final String? id;
  final List<_ProjectionRule> rules;
}

const _Family _unmatchedFamily = _Family(null, <_ProjectionRule>[]);

/// Picks the rule family for [spec], keyed on the CLI's own declaration
/// (service command / target) rather than on the shape of the response —
/// `result.dart`'s `patchbayResponseSummary` already established why: a
/// consumer response is free to publish any key name, so matching on shape
/// would let it impersonate protocol structure.
_Family _familyFor(PatchbayFriendlyCommandSpec? spec) {
  if (spec == null) return _unmatchedFamily;
  if (spec == PatchbayFriendlyCommand.catalog) {
    return const _Family('catalog', _catalogRules);
  }
  if (spec.serviceCommand == 'ui.semantics.tree') {
    return const _Family('ui.semantics.tree', _semanticsTreeRules);
  }
  if (spec.target == PatchbayCommandTarget.clientWidgetTree ||
      spec.target == PatchbayCommandTarget.clientRenderTree ||
      spec.target == PatchbayCommandTarget.clientFocusTree) {
    return const _Family('diagnosticTree', _diagnosticTreeRules);
  }
  if (spec.serviceCommand == 'logs.query') {
    return const _Family('logs.query', _logsQueryRules);
  }
  return _unmatchedFamily;
}

/// Whether [value] carries nothing a caller could have wanted expanded.
///
/// Section 5.4 names the case this exists for: outside a debug build the
/// three Flutter diagnostic trees answer with exit 0 and an **empty `data`**
/// rather than a refusal, and `localView.omitted` is the *only* way to tell
/// "the App had nothing to show" apart from "brief deleted it". Deleting an
/// empty member would collapse those two into the same document while saving
/// no bytes worth having, so the table skips it and reports no deletion.
///
/// A JSON `null` counts, and so does an empty string, list or map — an empty
/// tree arrives as `null`, `''`, `[]` or `{}` depending on which SDK
/// extension answered, and none of those is worth hiding.
bool _isEmptyMember(Object? value) =>
    value == null ||
    (value is String && value.isEmpty) ||
    (value is Iterable && value.isEmpty) ||
    (value is Map && value.isEmpty);

/// Applies one rule to [root], returning the (possibly unchanged) response
/// and whether it actually removed something. A rule that does not resolve
/// — a missing container, a container of the wrong shape, an absent leaf
/// key, a leaf that is empty — is a no-op rather than an error: invariant 4
/// in the proposal is that projection is a total function that never
/// guesses.
(Map<String, Object?>, bool) _applyRule(
  Map<String, Object?> root,
  _ProjectionRule rule,
) {
  Object? cursor = root;
  for (final String segment in rule.containerPath) {
    if (cursor is Map && cursor.containsKey(segment)) {
      cursor = cursor[segment];
    } else {
      return (root, false);
    }
  }
  if (rule.arrayContainer) {
    if (cursor is! List) return (root, false);
    var removed = false;
    final List<Object?> updated = <Object?>[
      for (final Object? item in cursor)
        if (item is Map<String, Object?> &&
            item.containsKey(rule.leafKey) &&
            !_isEmptyMember(item[rule.leafKey]))
          _withoutKey(item, rule.leafKey, onRemoved: () => removed = true)
        else
          item,
    ];
    if (!removed) return (root, false);
    return (_withReplacedContainer(root, rule.containerPath, updated), true);
  }
  if (cursor is! Map<String, Object?> ||
      !cursor.containsKey(rule.leafKey) ||
      _isEmptyMember(cursor[rule.leafKey])) {
    return (root, false);
  }
  final Map<String, Object?> updated = <String, Object?>{...cursor}
    ..remove(rule.leafKey);
  return (_withReplacedContainer(root, rule.containerPath, updated), true);
}

Map<String, Object?> _withoutKey(
  Map<String, Object?> map,
  String key, {
  required void Function() onRemoved,
}) {
  onRemoved();
  return <String, Object?>{...map}..remove(key);
}

Map<String, Object?> _withReplacedContainer(
  Map<String, Object?> root,
  List<String> containerPath,
  Object? newValue,
) {
  if (containerPath.isEmpty) return newValue! as Map<String, Object?>;
  final String head = containerPath.first;
  if (containerPath.length == 1) {
    return <String, Object?>{...root, head: newValue};
  }
  final Map<String, Object?> child = root[head]! as Map<String, Object?>;
  final Map<String, Object?> updatedChild = _withReplacedContainer(
    child,
    containerPath.sublist(1),
    newValue,
  );
  return <String, Object?>{...root, head: updatedChild};
}

Map<String, Object?> _localView({
  required String? projection,
  required List<String> omitted,
}) => <String, Object?>{
  'view': 'brief',
  'projection': projection,
  'omitted': omitted,
  'expand': '--view full',
};

/// Projects [response] to its brief view for [spec], or returns it verbatim
/// with an empty-`omitted` `localView` when [exitCode] is not
/// `PatchbayExitCode.accepted` — brief only ever thins a response the App
/// accepted; every "something went wrong" shape (rejection, typed failure,
/// a CLI error envelope, a keep-awake failure translation) keeps every
/// field, because those are exactly the shapes a caller reads to decide
/// what to do next.
///
/// Callers must gate this on `view == patchbayViewBrief` themselves: `full`
/// never calls it, so the default output stays byte-identical to a CLI that
/// does not know `--view` exists.
Map<String, Object?> projectPatchbayBriefView({
  required PatchbayFriendlyCommandSpec? spec,
  required Map<String, Object?> response,
  required int exitCode,
}) {
  if (exitCode != PatchbayExitCode.accepted) {
    return <String, Object?>{
      ...response,
      'localView': _localView(projection: null, omitted: const <String>[]),
    };
  }

  final List<String> omitted = <String>[];
  var current = response;

  final (Map<String, Object?> afterNotice, bool noticeRemoved) = _applyRule(
    current,
    _noticeRule,
  );
  current = afterNotice;
  if (noticeRemoved) omitted.add(_noticeRule.pattern);

  final _Family family = _familyFor(spec);
  // PB-050-20 / PB-050-21 接缝（两份 Proposal 冻结的顺序：先落盘、后投影）：
  // once a response carries a top-level `localArtifact`, the family's own
  // "unbounded member" rule (semantics tree's `nodes`, the diagnostic
  // passthroughs' `data`) must not run — that member is no longer the raw
  // tree, it is already the small verified receipt PB-050-20 placed there.
  // Deleting it too would both destroy the one thing an artifact-consuming
  // caller needs and report an `omitted` entry for a deletion that never
  // happened, which brief-view.md's contract forbids outright.
  final bool alreadySpilled = current.containsKey('localArtifact');
  final Iterable<_ProjectionRule> effectiveRules = alreadySpilled
      ? const <_ProjectionRule>[]
      : family.rules;
  for (final _ProjectionRule rule in effectiveRules) {
    final (Map<String, Object?> next, bool removed) = _applyRule(current, rule);
    current = next;
    if (removed) omitted.add(rule.pattern);
  }

  return <String, Object?>{
    ...current,
    'localView': _localView(projection: family.id, omitted: omitted),
  };
}

/// Every literal path pattern the projection table can ever remove, keyed by
/// family id (`'general'` for the section-5.1 rule that runs regardless of
/// family). Exists only so tests can assert the table and the checked-in
/// `test/golden/view_brief/*.{full,brief}.json` pairs cover each other in
/// both directions — never called from production code.
Map<String, List<String>>
patchbayBriefViewRulePatternsForTesting() => <String, List<String>>{
  'general': <String>[_noticeRule.pattern],
  'catalog': <String>[for (final r in _catalogRules) r.pattern],
  'ui.semantics.tree': <String>[for (final r in _semanticsTreeRules) r.pattern],
  'diagnosticTree': <String>[for (final r in _diagnosticTreeRules) r.pattern],
  'logs.query': <String>[for (final r in _logsQueryRules) r.pattern],
};
