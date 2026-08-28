export 'session/session_models.dart';
export 'session/session_resolver.dart';
export 'session/session_store.dart';
export 'session/trace_session_ref.dart';
// Deliberately not a whole-library export. Exporting the file wholesale
// published three symbols nothing consumes: `patchbayWorkspaceIdentityDomain`,
// which is an implementation detail of the digest preimage, and the
// `gitProbe`/`realpath` typedefs, which every caller satisfies with a function
// literal and never names. DG-050-07 refuses new public symbols by default, so
// this names what is actually consumed rather than everything declared.
export 'session/workspace_identity.dart'
    show
        PatchbayWorkspaceAffinity,
        PatchbayWorkspaceGitAnswer,
        PatchbayWorkspaceIdentity,
        PatchbayWorkspaceIdentityAt,
        PatchbayWorkspaceIdentityProbe,
        PatchbayWorkspaceKind,
        patchbayScopedSelectionMaximumBytes,
        patchbayScopedSelectionMaximumCount,
        patchbayWorkspaceGitProbeBudget,
        patchbayWorkspaceIdentityVersion,
        patchbayWorkspacePathMaximumLength;
