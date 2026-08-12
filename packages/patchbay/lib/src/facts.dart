/// Closed vocabulary for the strength and origin of a Patchbay fact.
///
/// A weaker source must never be upgraded by the transport or CLI. Consumers
/// may refine a payload at a deeper object path, but every emitted `source`
/// value must come from this vocabulary.
enum PatchbayFactSource {
  /// App-local state, bookkeeping, or a request receipt.
  appRecorded,

  /// A command echo. This is not external state.
  commandEcho,

  /// An external device report or a verifiable read-back.
  deviceReported,

  /// A direct Flutter target, metrics, or render-tree observation.
  uiObserved,

  /// The available evidence cannot establish a stronger source.
  unknown,
}
