import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'generated/core_wire.g.dart';

/// The only digest algorithm this protocol version computes.
const String patchbayDigestAlgorithmSha256 = 'sha256';

/// The catalog region [PatchbayCatalogDigest.ofCommands] covers.
const String patchbayCatalogDigestScopeCommands = 'commands';

/// A stable content digest of the command surface an App declares.
///
/// It answers one question a consumer cannot otherwise answer cheaply: *did
/// the App's declared capabilities change?* Diffing two catalogs by hand is
/// noise — registration order and formatting move on their own — so the digest
/// is computed over a canonical form that ignores both.
///
/// **What it covers, and why not more.** Only `commands`. The catalog also
/// carries `uiTargets`, but those are the targets currently *registered*,
/// which is mount state: navigating to another screen changes the set without
/// anything about the App's declared surface changing. A digest that flips on
/// navigation is a digest consumers learn to ignore. `schemaVersion` is
/// excluded for the opposite reason — it is protocol-owned and constant, so
/// including it would make the digest move on a protocol bump that changed
/// nothing the consumer declared.
///
/// [covers] travels on the wire precisely so the name `catalogDigest` is not a
/// promise the value does not keep: a reader is told which region was hashed
/// rather than having to assume, and a later version can widen the coverage
/// without any reader silently comparing two different things.
final class PatchbayCatalogDigest {
  const PatchbayCatalogDigest({
    required this.algorithm,
    required this.covers,
    required this.value,
  });

  /// Digests the `commands` array of a catalog.
  ///
  /// [commands] is whatever the catalog carries under that key; anything that
  /// is not a list digests as an empty surface, because an App that declares
  /// no commands and an App whose `commands` key is absent have the same
  /// declared surface. A malformed list never reaches here: the host validates
  /// the array before serving it, and a violated catalog gets no digest at
  /// all.
  ///
  /// Entries are canonicalised individually and then sorted as strings, so the
  /// digest is independent of the order the composition root happened to
  /// register in — reordering a registration list is not a capability change.
  factory PatchbayCatalogDigest.ofCommands(Object? commands) {
    final List<Object?> rows = commands is List<Object?>
        ? commands
        : const <Object?>[];
    final List<String> canonical = <String>[
      for (final Object? row in rows) patchbayCanonicalJson(row),
    ]..sort();
    return PatchbayCatalogDigest(
      algorithm: patchbayDigestAlgorithmSha256,
      covers: const <String>[patchbayCatalogDigestScopeCommands],
      value: crypto.sha256
          .convert(utf8.encode('[${canonical.join(',')}]'))
          .toString(),
    );
  }

  /// Reads a digest a host served, or null when there is none to read.
  ///
  /// Deliberately hand-written rather than delegating to the generated
  /// `PatchbayCatalogDigestWire.fromJson`: that decoder rejects unknown
  /// fields, which is right for a request a host has to police and wrong for a
  /// forward-compatibility mechanism. A newer host that attaches something
  /// extra here must leave this reader with a digest it can still evaluate,
  /// not with a decode failure.
  static PatchbayCatalogDigest? fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final Object? algorithm = value['algorithm'];
    final Object? covers = value['covers'];
    final Object? digest = value['value'];
    if (algorithm is! String || digest is! String || covers is! List<Object?>) {
      return null;
    }
    return PatchbayCatalogDigest(
      algorithm: algorithm,
      covers: <String>[
        for (final Object? scope in covers)
          if (scope is String) scope,
      ],
      value: digest,
    );
  }

  /// Names the hash function. Not an enum on the wire: a reader that meets an
  /// algorithm it cannot compute has to say so and move on, not throw.
  final String algorithm;

  /// The catalog regions this digest was computed over.
  final List<String> covers;

  /// Lowercase hex, no algorithm prefix — [algorithm] already carries that.
  final String value;

  /// Whether a reader of *this* protocol version can recompute the digest and
  /// therefore judge whether it matches the catalog it arrived with.
  bool get isRecomputable =>
      algorithm == patchbayDigestAlgorithmSha256 &&
      covers.length == 1 &&
      covers.single == patchbayCatalogDigestScopeCommands;

  Map<String, Object?> toJson() => PatchbayCatalogDigestWire(
    algorithm: algorithm,
    covers: covers,
    value: value,
  ).toJson();
}

/// Encodes [value] as JSON with every object's keys in sorted order.
///
/// Two catalogs that declare the same thing must produce the same bytes, and
/// map iteration order is an implementation detail of whatever built the
/// descriptor — so it is sorted away here rather than depended on.
///
/// Non-string keys are coerced with `toString` instead of throwing: the digest
/// runs while a response is being assembled, and a catalog that cannot be JSON
/// encoded already fails at the transport with a message about that. A digest
/// must never be the thing that takes a host down.
String patchbayCanonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) {
  if (value is Map<Object?, Object?>) {
    final List<MapEntry<String, Object?>> entries =
        <MapEntry<String, Object?>>[
          for (final MapEntry<Object?, Object?> entry in value.entries)
            MapEntry<String, Object?>('${entry.key}', _canonical(entry.value)),
        ]..sort(
          (MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
              a.key.compareTo(b.key),
        );
    return Map<String, Object?>.fromEntries(entries);
  }
  if (value is List<Object?>) {
    return <Object?>[for (final Object? item in value) _canonical(item)];
  }
  return value;
}
