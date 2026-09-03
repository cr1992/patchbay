/// PB-050-40: the one place the CLI decides which declaration a dispatch runs
/// under, and the one place a malformed provider declaration fails the catalog.
///
/// Everything downstream — the artifact spill, the brief deny-list, the
/// `localView.projection` id — reads the single [PatchbayOutputProjection] this
/// file returns. There is no second lookup and no shape sniffing: matching on
/// the *response* would let a consumer publish any key name and impersonate
/// protocol structure, which is the same reason `result.dart`'s
/// `patchbayResponseSummary` keys off the declaration instead.
library;

import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../command_registry.dart';

/// Typed failure code for a provider declaration the CLI refuses to interpret.
const String patchbayCatalogOutputProjectionInvalid =
    'catalogOutputProjectionInvalid';

/// Validates every `outputProjection` in [catalog], throwing
/// [PatchbayProtocolException] with [patchbayCatalogOutputProjectionInvalid]
/// as soon as one row is malformed.
///
/// All-or-nothing on purpose. A declaration the CLI cannot read is a provider
/// protocol violation, and dropping just that field would leave two clients
/// looking at the same host and projecting the same command differently — the
/// exact ambiguity `outputProjection` exists to remove. The catalog is refused
/// whole, before any command is invoked against it.
void validatePatchbayCatalogOutputProjections(Map<String, Object?> catalog) {
  try {
    patchbayDecodeCatalogOutputProjections(catalog);
  } on FormatException catch (failure) {
    throw PatchbayProtocolException(
      patchbayCatalogOutputProjectionInvalid,
      details: <String, Object?>{'reason': failure.message},
    );
  }
}

/// The declaration [spec] runs under, given the host [catalog] this dispatch
/// used (`null` for a command that never reads one).
///
/// Order, and why:
///
///   1. **the host's descriptor.** A host that publishes a declaration owns
///      its own command's projection; the CLI does not merge it with anything
///      or second-guess it.
///   2. **the CLI-local declaration.** Reached only when the host published
///      none, which is always the case for `catalog` and the three Flutter
///      diagnostic-tree passthroughs — they are not cataloged commands at all
///      — and for `blob get`, whose artifact is a property of the spelling
///      rather than of `blob.metadata`.
///   3. **the frozen 0.5.0 fallback.** Reached only against a host that
///      predates `outputProjection`, and covering only the commands 0.5.0
///      already projected. It is read-only: a 0.6.0 command declares on its
///      descriptor instead of being added here.
///
/// A command none of the three names projects nothing: the response passes
/// through, `localView.projection` is `null` and only the envelope-wide
/// `$.notice` rule runs. That is the legacy passthrough a consumer-owned
/// external command keeps — the CLI never guesses a family from the shape of
/// what came back.
PatchbayOutputProjection? resolvePatchbayOutputProjection({
  required PatchbayFriendlyCommandSpec? spec,
  required Map<String, Object?>? catalog,
}) {
  if (spec == null) return null;
  final PatchbayOutputProjection? declared = _hostDeclaration(
    catalog,
    spec.serviceCommand,
  );
  if (declared != null) return declared;
  return patchbayStaticOutputProjection(spec);
}

PatchbayOutputProjection? _hostDeclaration(
  Map<String, Object?>? catalog,
  String? serviceCommand,
) {
  if (catalog == null || serviceCommand == null) return null;
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return null;
  for (final Object? row in rows) {
    if (row is! Map<Object?, Object?> || row['name'] != serviceCommand) {
      continue;
    }
    try {
      return PatchbayOutputProjection.fromCatalogRow(row);
    } on FormatException catch (failure) {
      // Reachable only if a caller skipped
      // [validatePatchbayCatalogOutputProjections]; the same fail-closed
      // answer either way, never a silent drop back to the fallback.
      throw PatchbayProtocolException(
        patchbayCatalogOutputProjectionInvalid,
        details: <String, Object?>{
          'command': serviceCommand,
          'reason': failure.message,
        },
      );
    }
  }
  return null;
}
