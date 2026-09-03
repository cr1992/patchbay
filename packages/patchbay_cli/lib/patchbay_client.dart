/// Opt-in Dart client surface for `patchbay_cli` (PB-050-13, DG-050-07).
///
/// Import this library only to hold a Patchbay connection open from Dart code.
/// Driving the App as a tool — commands, exit codes, stable JSON — belongs to
/// the `patchbay` executable and its `--json` contract, not here.
///
/// The surface is a closed list of eight symbols. Nothing else in this package
/// is public: launcher, session, trace, doctor, REPL, manifest and permission
/// implementations are executable internals, and every test clock, random
/// source, starter and factory seam stays inside `src/`. Growing this list is a
/// design decision, not an implementation one — it requires an accepted
/// proposal and a golden update, never a convenience export.
library;

// PB-060-02：`PatchbaySnapshotRequest` 是 protocol 面的类型，因此从
// `patchbay_protocol.dart` 精确 re-export。这条 re-export 本身没有变——client
// 的调用者仍然只 import 本 library 就能命名一次快照请求，不必再加一条依赖。
export 'package:patchbay/patchbay_protocol.dart' show PatchbaySnapshotRequest;

export 'src/client.dart'
    show
        PatchbayClient,
        PatchbayProtocolException,
        PatchbayRuntimeIdentity,
        PatchbaySnapshotDiffClient,
        PatchbayTransportException;
export 'src/client_factories.dart'
    show connectPatchbayDirect, connectPatchbayVmService;
