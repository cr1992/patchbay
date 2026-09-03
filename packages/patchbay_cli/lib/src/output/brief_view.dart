/// PB-050-21 / PB-050-40: `--view brief` projects a decoded App response down
/// to the decision facts a machine consumer needs before it decides whether to
/// expand the rest, without ever changing a value or a key that survives the
/// projection.
///
/// PB-050-21 froze the *contract*: a closed deny-list, never a white-list, so
/// legacy fields, consumer payloads and future protocol additions the CLI has
/// never heard of pass through untouched. PB-050-40 moved the *table* out of
/// this file. The rules now arrive as a [PatchbayOutputProjection] — from the
/// host catalog when the host publishes one, from a CLI-local declaration for
/// the commands no catalog can describe, and from the frozen 0.5.0 fallback
/// otherwise — so a new command no longer means editing a rule table here, an
/// artifact disposition in the registry and a golden all at once.
///
/// What did not move: `$.notice` is still evaluated for every accepted
/// response regardless of declaration, because it is an envelope fact rather
/// than a command fact. Declaring it per command would be one rule copied into
/// every descriptor in the catalog.
///
/// This file is deliberately not re-exported from `patchbay_cli.dart`: it is
/// an internal implementation detail of the CLI's own output shaping, not a
/// public SDK surface.
library;

import 'package:patchbay/patchbay.dart';

import '../result.dart';

/// `--view` values accepted by the CLI.
const String patchbayViewFull = 'full';
const String patchbayViewBrief = 'brief';

/// Section 5.1: evaluated for every accepted response regardless of which
/// declaration (if any) applies. Not declared per command on purpose — see the
/// library comment.
final PatchbayOutputProjectionPath patchbayBriefNoticeRule =
    PatchbayOutputProjectionPath.parse(r'$.notice');

/// Whether [value] carries nothing a caller could have wanted expanded.
///
/// Section 5.4 names the case this exists for: outside a debug build the
/// three Flutter diagnostic trees answer with exit 0 and an **empty `data`**
/// rather than a refusal, and `localView.omitted` is the *only* way to tell
/// "the App had nothing to show" apart from "brief deleted it". Deleting an
/// empty member would collapse those two into the same document while saving
/// no bytes worth having, so the projection skips it and reports no deletion.
///
/// A JSON `null` counts, and so does an empty string, list or map — an empty
/// tree arrives as `null`, `''`, `[]` or `{}` depending on which SDK
/// extension answered, and none of those is worth hiding.
bool patchbayIsEmptyProjectedMember(Object? value) =>
    value == null ||
    (value is String && value.isEmpty) ||
    (value is Iterable && value.isEmpty) ||
    (value is Map && value.isEmpty);

/// Applies one rule to [root], returning the (possibly unchanged) response
/// and whether it actually removed something.
///
/// A rule that does not resolve — a missing container, a container of the
/// wrong shape, an absent leaf key, a leaf that is empty — is a no-op rather
/// than an error: invariant 4 in the proposal is that projection is a total
/// function that never guesses. A segment marked `[]` walks every map element
/// of the list at that step and applies the rest of the rule inside each one;
/// the rule reports one removal if any element lost the key.
(Map<String, Object?>, bool) patchbayApplyBriefRule(
  Map<String, Object?> root,
  PatchbayOutputProjectionPath rule,
) {
  final (Object? updated, bool removed) = _applySegments(
    root,
    rule.segments,
    0,
  );
  if (!removed) return (root, false);
  return (updated! as Map<String, Object?>, true);
}

(Object?, bool) _applySegments(
  Object? node,
  List<PatchbayOutputProjectionPathSegment> segments,
  int index,
) {
  if (node is! Map<String, Object?>) return (node, false);
  final PatchbayOutputProjectionPathSegment segment = segments[index];
  final bool isLeaf = index == segments.length - 1;
  if (!node.containsKey(segment.field)) return (node, false);
  final Object? value = node[segment.field];
  if (isLeaf) {
    if (patchbayIsEmptyProjectedMember(value)) return (node, false);
    return (<String, Object?>{...node}..remove(segment.field), true);
  }
  if (segment.traversesList) {
    if (value is! List<Object?>) return (node, false);
    var removed = false;
    final List<Object?> rewritten = <Object?>[];
    for (final Object? item in value) {
      final (Object? next, bool itemRemoved) = _applySegments(
        item,
        segments,
        index + 1,
      );
      removed = removed || itemRemoved;
      rewritten.add(next);
    }
    if (!removed) return (node, false);
    return (<String, Object?>{...node, segment.field: rewritten}, true);
  }
  final (Object? next, bool childRemoved) = _applySegments(
    value,
    segments,
    index + 1,
  );
  if (!childRemoved) return (node, false);
  return (<String, Object?>{...node, segment.field: next}, true);
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

/// Projects [response] to its brief view under [projection], or returns it
/// verbatim with an empty-`omitted` `localView` when [exitCode] is not
/// `PatchbayExitCode.accepted` — brief only ever thins a response the App
/// accepted; every "something went wrong" shape (rejection, typed failure,
/// a CLI error envelope, a keep-awake failure translation) keeps every
/// field, because those are exactly the shapes a caller reads to decide
/// what to do next.
///
/// A `null` [projection], or one that declares only an artifact, still runs
/// the envelope-wide `$.notice` rule and still reports a `localView` — with
/// `projection: null`, which is how a caller tells "this command declares no
/// brief" apart from "this command declared one that removed nothing".
///
/// Callers must gate this on `view == patchbayViewBrief` themselves: `full`
/// never calls it, so the default output stays byte-identical to a CLI that
/// does not know `--view` exists.
Map<String, Object?> projectPatchbayBriefView({
  required PatchbayOutputProjection? projection,
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

  final (Map<String, Object?> afterNotice, bool noticeRemoved) =
      patchbayApplyBriefRule(current, patchbayBriefNoticeRule);
  current = afterNotice;
  if (noticeRemoved) omitted.add(patchbayBriefNoticeRule.pattern);

  final PatchbayOutputBriefProjection? brief = projection?.brief;
  // PB-050-20 / PB-050-21 接缝（两份 Proposal 冻结的顺序：先落盘、后投影）：
  // once a response carries a top-level `localArtifact`, the declaration's own
  // "unbounded member" rule (semantics tree's `nodes`, the diagnostic
  // passthroughs' `data`) must not run — that member is no longer the raw
  // tree, it is already the small verified receipt PB-050-20 placed there.
  // Deleting it too would both destroy the one thing an artifact-consuming
  // caller needs and report an `omitted` entry for a deletion that never
  // happened, which brief-view.md's contract forbids outright.
  //
  // N3 (honesty correction, restated for PB-050-40): the check below is not
  // scoped to the declarations that can spill. `alreadySpilled` is computed
  // against the whole response, independent of the declaration, so *every*
  // brief rule is switched off the instant `localArtifact` is present — the
  // `catalog` and `logs.query` deny-lists included. That is structurally
  // correct only because `localArtifact` is written exclusively by the spill
  // path in `local_artifact.dart` and by the host-blob download in `cli.dart`,
  // and neither runs for a command whose declaration carries no artifact. A
  // future declaration whose response could legitimately carry an unrelated
  // top-level `localArtifact` would need this narrowed to that declaration's
  // own artifact member, not left widened by accident the way it is now.
  final bool alreadySpilled = current.containsKey('localArtifact');
  final List<PatchbayOutputProjectionPath> rules =
      brief == null || alreadySpilled
      ? const <PatchbayOutputProjectionPath>[]
      : brief.paths;
  for (final PatchbayOutputProjectionPath rule in rules) {
    final (Map<String, Object?> next, bool removed) = patchbayApplyBriefRule(
      current,
      rule,
    );
    current = next;
    if (removed) omitted.add(rule.pattern);
  }

  return <String, Object?>{
    ...current,
    'localView': _localView(projection: brief?.id, omitted: omitted),
  };
}

/// Appends the CLI's own routing report, after every projection has run.
///
/// PB-050-40 evaluation order, step 4: `localRoute` is a CLI-local fact, not a
/// host response member. Merging it into the response before projection — the
/// way PB-060-01 first did — let a descriptor declare `omit: ["$.localRoute"]`
/// and delete the CLI's report of which service command it actually called.
/// Appending it here makes that impossible by construction rather than by a
/// rule someone has to remember, and the declaration grammar refuses the
/// `local` root namespace on top of that.
Map<String, Object?> withPatchbayLocalRoute(
  Map<String, Object?> response,
  Map<String, Object?>? localRoute,
) {
  if (localRoute == null) return response;
  return <String, Object?>{...response, 'localRoute': localRoute};
}
