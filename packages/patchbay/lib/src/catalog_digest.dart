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
    this.coversFullyRead = true,
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
  ///
  /// **Tolerance stops at the edge of [covers].** An unknown sibling *field* is
  /// safe to ignore — it does not change what the fields this version does
  /// understand mean. An unreadable *entry inside `covers`* is the opposite:
  /// dropping it silently narrows the host's claim, and a narrowed claim that
  /// happens to land on this version's coverage reads as "I understood all of
  /// it" when the truth is "I could not read part of it". So an entry that is
  /// not a string poisons the whole coverage via [coversFullyRead], and the
  /// digest degrades to not-recomputable — the same fail-closed answer an
  /// unknown [algorithm] gets, for the same reason.
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
      coversFullyRead: covers.every((Object? scope) => scope is String),
      value: digest,
    );
  }

  /// Names the hash function. Not an enum on the wire: a reader that meets an
  /// algorithm it cannot compute has to say so and move on, not throw.
  final String algorithm;

  /// The catalog regions this digest was computed over.
  ///
  /// Holds only the entries this reader could name; when the wire carried one
  /// it could not, [coversFullyRead] is false and this list is a *subset* of
  /// what the host actually claimed. Never treat it as the full coverage
  /// without checking that flag — and note [toJson] re-serialises this
  /// narrowed list, so a digest that came off the wire malformed is not a
  /// faithful thing to forward.
  final List<String> covers;

  /// Lowercase hex, no algorithm prefix — [algorithm] already carries that.
  final String value;

  /// Whether every entry of the wire `covers` array was readable as a scope
  /// name. False means [covers] under-reports what the host claimed.
  ///
  /// Hosts building a digest locally always produce string scopes, so this
  /// defaults to true; only [fromJson] can turn it off.
  final bool coversFullyRead;

  /// Whether a reader of *this* protocol version can recompute the digest and
  /// therefore judge whether it matches the catalog it arrived with.
  ///
  /// Requires [coversFullyRead]: a coverage this reader only partly understood
  /// cannot be compared against anything, because the part it could not read is
  /// exactly the part that would make the comparison wrong.
  bool get isRecomputable =>
      coversFullyRead &&
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
