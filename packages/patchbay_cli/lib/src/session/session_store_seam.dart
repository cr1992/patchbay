/// Failure seams for the session store's temp+rename writes.
///
/// Package-private on purpose: `lib/src/session.dart` does not export this
/// library, so nothing declared here reaches the published surface (DG-050-07
/// refuses new public symbols by default). It exists because "a crash between
/// the temp write and the rename" cannot be verified by planting the residue
/// such a crash would have left behind -- that fixture proves only that a
/// stray file is ignored, and stays green even if the write path stops being
/// atomic at all. Interrupting the *real* write path is the only way to see
/// what is on disk in that window.
library;

/// Runs inside [PatchbaySessionStore._atomicallyWrite] after the temp file is
/// written and flushed, and before it is renamed onto `target`.
///
/// Throwing reproduces a crash in exactly that window; returning normally lets
/// the write complete, which is what lets a test inspect the intermediate
/// state (old content still at `target`, new content parked in a temp file)
/// and then assert the rename still lands.
typedef PatchbayAtomicWriteInterrupt = void Function(String target);

PatchbayAtomicWriteInterrupt? _interrupt;

/// The installed interrupt, or `null` -- which is always the case in
/// production, where nothing calls [runWithAtomicWriteInterrupt].
PatchbayAtomicWriteInterrupt? get patchbayAtomicWriteInterrupt => _interrupt;

/// Installs [interrupt] for the duration of [body], then restores what was
/// there before -- including when [body] throws, which is the normal case.
T runWithAtomicWriteInterrupt<T>(
  PatchbayAtomicWriteInterrupt interrupt,
  T Function() body,
) {
  final PatchbayAtomicWriteInterrupt? previous = _interrupt;
  _interrupt = interrupt;
  try {
    return body();
  } finally {
    _interrupt = previous;
  }
}
