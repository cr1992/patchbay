/// A protocol capability a host declares on the identity plane.
///
/// The point is to let a client *degrade against a declaration* instead of
/// guessing from a missing field. Without it, "this answer has no
/// `lifecycleState`" is indistinguishable from "this App's lifecycle is
/// unknown", and a client has to pick one of the two and be wrong half the
/// time — which is exactly the "let people believe something that is not
/// true" failure mode the admission envelope exists to prevent.
///
/// **Closed where it is declared, open where it is read.** A host may only
/// declare a name from this enum, so a capability cannot be invented by a
/// consumer and cannot mean two things in two Apps. A client, by contrast,
/// reads the wire list as plain strings: a newer host declaring a capability
/// this client has never heard of must degrade to "I do not use that", never
/// to a decode failure. That asymmetry is the whole mechanism — enforcing the
/// closed vocabulary on the reading side too would break the forward
/// compatibility the feature exists to provide.
///
/// A name only earns a place here when some client actually branches on it.
/// Declaring capabilities nobody reads turns the handshake into documentation
/// that drifts.
enum PatchbayFeature {
  /// The catalog answer carries `catalogDigest`.
  ///
  /// Declared by every `PatchbayServiceHost`: the digest is computed by the
  /// protocol, not by the consumer, so a host either has it or predates it.
  catalogDigest,

  /// The snapshot RPC accepts a field selector and server-side wait request.
  ///
  /// Declared by every [PatchbayServiceHost] that understands the optional
  /// snapshot request object. A client must see this declaration before it
  /// sends that object; absence means it may only use the whole-snapshot RPC.
  snapshotSelectors,

  /// Catalog command descriptors can drive host-side response validation.
  responseSchemas,

  /// The snapshot RPC accepts a separate revision-diff request shape.
  ///
  /// Revisions advance only when this host observes changed canonical content.
  /// A client must see this declaration before it sends the new request; old
  /// hosts strictly decode the selector request and cannot accept it.
  snapshotRevisionDiff,

  /// `*LifecycleNotResumed` rejections carry `details.lifecycleState`.
  ///
  /// Declared by the Flutter host, which owns the lifecycle gate. A pure Dart
  /// host has no engine lifecycle to report, and a host that predates the
  /// field cannot report one either; the declaration is what tells those two
  /// apart from an App that reports `unknown` because its consumer replaced
  /// the resumed decision without supplying a reader.
  lifecycleState,
}
