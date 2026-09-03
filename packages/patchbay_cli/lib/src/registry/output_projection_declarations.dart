/// PB-050-40: the CLI's two catalog-independent projection sources.
///
/// A `--view brief` deletion or a local artifact used to be spelled four
/// different ways — a rule table in `output/brief_view.dart`, a
/// `PatchbayArtifactDisposition` on each friendly declaration, a `spilledMember`
/// dot path beside it and a `_familyFor` path special case. This file replaces
/// the last three with one declaration type, [PatchbayOutputProjection], and
/// keeps exactly two ways for the CLI to reach one without a host catalog:
///
///   1. [PatchbayLocallyProjectedCommand.localOutputProjection] — a CLI-local
///      declaration, for commands that have no host descriptor at all
///      (`catalog`, the three Flutter diagnostic-tree passthroughs) or whose
///      artifact belongs to the CLI spelling rather than the service command
///      (`blob get`, whose sibling `blob metadata` calls the same
///      `blob.metadata` and must not download anything).
///   2. [patchbayFrozenOutputProjection] — the read-only 0.5.0 compatibility
///      table, used only when a host publishes no declaration of its own.
///
/// Rule for the frozen table: **it does not grow.** It exists so a 0.6.0 CLI
/// keeps producing 0.5.0's bytes against a 0.5.0 host, and a 0.6.0 command
/// that needs a projection declares it on its descriptor instead. The test
/// suite pins its key set for exactly that reason.
library;

import 'package:patchbay/patchbay.dart';

import 'command_spec.dart';

/// Implemented by a CLI-local command declaration that owns its own
/// projection.
///
/// Deliberately a separate interface rather than a member of
/// [PatchbayFriendlyCommandSpec]: most specs — generated protocol commands and
/// the canonical `ui perform` façades — have no CLI-local declaration at all,
/// they read the service descriptor's. Making every implementer answer a
/// question only two of them have an answer to would be the "declare it in
/// four places" problem this change removes.
abstract interface class PatchbayLocallyProjectedCommand {
  /// This spelling's own declaration, or `null` when the host descriptor and
  /// the frozen fallback decide.
  PatchbayOutputProjection? get localOutputProjection;
}

/// The 0.5.0 brief/artifact contract for the protocol commands that had one,
/// keyed by service command.
///
/// Frozen: entries may be deleted when a host version stops being supported,
/// never added. Every value here is byte-identical to what
/// `docs/proposals/0.5.0/brief-view.md` and `tree-artifact-output.md` froze,
/// and each one is also declared on the matching descriptor in
/// `package:patchbay`, so a 0.6.0 host and this fallback cannot disagree — a
/// test asserts the two sides stay equal.
const Map<String, PatchbayOutputProjection> patchbayFrozen050OutputProjections =
    <String, PatchbayOutputProjection>{
      'ui.semantics.tree': PatchbayOutputProjection(
        brief: PatchbayOutputBriefProjection(
          id: 'ui.semantics.tree',
          omit: <String>[r'$.payload.nodes'],
        ),
        artifact: PatchbayOutputArtifactProjection.renderedMember(
          member: r'$.payload.nodes',
          encoding: PatchbayOutputArtifactEncoding.json,
        ),
      ),
      'logs.query': PatchbayOutputProjection(
        brief: PatchbayOutputBriefProjection(
          id: 'logs.query',
          omit: <String>[r'$.payload.records'],
        ),
      ),
      'logs.export': PatchbayOutputProjection(
        artifact: PatchbayOutputArtifactProjection.payloadBlob(),
      ),
      'ui.capture': PatchbayOutputProjection(
        artifact: PatchbayOutputArtifactProjection.payloadBlob(),
      ),
    };

/// The frozen 0.5.0 declaration for [spec], or `null`.
///
/// A closed table lookup and nothing else. An earlier revision also derived a
/// fallback from `spec.protocolSyntax?.artifactDisposition`, which read like a
/// convenience and behaved like a loophole: any future command that set an
/// `artifactDisposition` on its CLI syntax and forgot `outputProjection` would
/// have picked up a projection silently — the same "add one more line to the
/// CLI's table" habit the proposal closes when it calls this fallback a
/// read-only compatibility area that must not grow for 0.6.0 commands. A
/// 0.6.0 command declares on its descriptor, or it has no projection.
PatchbayOutputProjection? patchbayFrozenOutputProjection(
  PatchbayFriendlyCommandSpec spec,
) => patchbayFrozen050OutputProjections[spec.serviceCommand];

/// The projection the CLI can name **before** it has talked to a host.
///
/// Option parsing has to answer "does this spelling accept `--output`?" while
/// the process is still reading argv, long before a catalog exists, so the
/// option surface is a build-time fact by construction. A host declaration can
/// change what a projection *does*; it cannot retroactively grant an option to
/// a spelling the CLI shipped without one.
PatchbayOutputProjection? patchbayStaticOutputProjection(
  PatchbayFriendlyCommandSpec spec,
) {
  if (spec is PatchbayLocallyProjectedCommand) {
    final PatchbayOutputProjection? local =
        (spec as PatchbayLocallyProjectedCommand).localOutputProjection;
    if (local != null) return local;
  }
  return patchbayFrozenOutputProjection(spec);
}

/// The [PatchbayArtifactDisposition] a projection implies, for the CLI option
/// surface and the host-blob download path.
PatchbayArtifactDisposition patchbayDispositionOf(
  PatchbayOutputProjection? projection,
) => switch (projection?.artifact?.kind) {
  PatchbayOutputArtifactKind.renderedMember =>
    PatchbayArtifactDisposition.renderedMember,
  PatchbayOutputArtifactKind.payloadBlob =>
    PatchbayArtifactDisposition.payloadBlob,
  PatchbayOutputArtifactKind.responseBlob =>
    PatchbayArtifactDisposition.responseBlob,
  null => PatchbayArtifactDisposition.none,
};
