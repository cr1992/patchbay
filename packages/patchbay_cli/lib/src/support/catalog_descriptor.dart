// CLI 自己要读的 catalog 行描述符。
//
// 放在中立的 `support/` 层：`commands/` 与 `output/` 都要用它，
// 若继续住在 `commands/` 里就会形成 commands -> output -> commands 的领域环。
import 'package:patchbay/patchbay.dart';

import '../client.dart';

/// Typed failure code for a provider declaration the CLI refuses to interpret.
const String patchbayCatalogOutputProjectionInvalid =
    'catalogOutputProjectionInvalid';

/// Validates every declaration a catalog document carries, before the CLI
/// invokes anything against it.
///
/// One named seam on purpose. PB-050-40 is the first declaration validated
/// here and, at the time of writing, the only one; PB-050-34's interaction
/// models are meant to land in the same function rather than beside it. The
/// bug that motivates the shape is that a per-feature validator gets wired
/// into the dispatch path and then quietly misses the direct readers —
/// `patchbay catalog` and `doctor` — so a violating host looks healthy through
/// exactly the two commands an operator reaches for first.
///
/// All-or-nothing: a declaration the CLI cannot read is a provider protocol
/// violation, and dropping just that field would leave two clients projecting
/// the same command differently — the ambiguity these declarations exist to
/// remove.
void validateCatalogDeclarations(Map<String, Object?> catalog) {
  try {
    patchbayDecodeCatalogOutputProjections(catalog);
  } on FormatException catch (failure) {
    throw PatchbayProtocolException(
      patchbayCatalogOutputProjectionInvalid,
      details: <String, Object?>{'reason': failure.message},
    );
  }
  validateCatalogInteractionModels(catalog);
}

/// Three-state read of a catalog row's `interactionModel` key.
///
/// [legacyUnknown] covers both real cases the reader cannot tell apart from
/// the row alone: a host that predates the field, and a command outside the
/// closed declaring set (DG-060-05). The reader never infers a value from
/// the command name — an unknown *declared* value is a provider violation
/// (see [validateCatalogInteractionModels]), not this state.
enum CatalogInteractionModelReading { directTarget, userLike, legacyUnknown }

CatalogInteractionModelReading catalogInteractionModelReading(
  Map<Object?, Object?> row,
) => switch (PatchbayInteractionModel.fromCatalogRow(row)) {
  PatchbayInteractionModel.directTarget =>
    CatalogInteractionModelReading.directTarget,
  PatchbayInteractionModel.userLike => CatalogInteractionModelReading.userLike,
  null => CatalogInteractionModelReading.legacyUnknown,
};

/// Fails the *whole* catalog, not just one row, when any row declares an
/// `interactionModel` outside the closed `directTarget`/`userLike` set
/// (DG-060-05: "未知值使整份 catalog 按 provider 违规失效", host and CLI
/// sides consistent). Unlike [CatalogCommandDescriptor.find]'s per-command
/// lookup, this walks every row so a provider that corrupts one row cannot
/// leave the rest of the catalog usable.
void validateCatalogInteractionModels(Map<String, Object?> catalog) {
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return;
  final List<Map<String, Object?>> violations = <Map<String, Object?>>[];
  for (var index = 0; index < rows.length; index += 1) {
    final Object? row = rows[index];
    if (row is! Map<Object?, Object?>) continue;
    try {
      PatchbayInteractionModel.fromCatalogRow(row);
    } on FormatException {
      violations.add(<String, Object?>{
        'index': index,
        if (row['name'] case final String name) 'name': name,
        'reason': 'invalidInteractionModel',
      });
    }
  }
  if (violations.isEmpty) return;
  throw PatchbayProtocolException(
    'providerProtocolViolation',
    details: <String, Object?>{
      'reason': 'invalidCatalogCommands',
      'violations': violations,
    },
  );
}

/// One catalog row, read only for what the CLI itself has to decide.
final class CatalogCommandDescriptor {
  const CatalogCommandDescriptor(
    this.suggestedWaitTimeout,
    this._parameters,
    this.responseSchema,
    this.executionContract,
    this.interactionModel,
  );

  final Duration? suggestedWaitTimeout;
  final List<Map<Object?, Object?>> _parameters;
  final PatchbayResponseSchema? responseSchema;
  final PatchbayExecutionContract executionContract;

  /// `legacyUnknown` for a row with no declared value; never guessed from
  /// the command name. Callers that reach a [CatalogCommandDescriptor] have
  /// already passed [validateCatalogInteractionModels], so a declared value
  /// here is always one of the two known members.
  final CatalogInteractionModelReading interactionModel;

  Set<String> get sensitiveParameters => <String>{
    for (final Map<Object?, Object?> parameter in _parameters)
      if (parameter['sensitive'] == true)
        if (parameter['name'] case final String name) name,
  };

  /// Positive integer default declared for [name], when the App declares one.
  int? positiveIntegerDefault(String name) {
    for (final Map<Object?, Object?> parameter in _parameters) {
      if (parameter['name'] != name) continue;
      final Object? value = parameter['defaultValue'];
      return value is int && value > 0 ? value : null;
    }
    return null;
  }

  static CatalogCommandDescriptor? find(
    Map<String, Object?> catalog,
    String command,
  ) {
    // Every call site funnels through here, including the ones that look up
    // a command other than the one carrying the bad value — so a single
    // corrupted row fails catalog-wide lookups, not just its own row
    // (DG-060-05, matching the host-side shape).
    validateCatalogInteractionModels(catalog);
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return null;
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> || row['name'] != command) continue;
      final Object? milliseconds = row['suggestedWaitTimeoutMs'];
      final Object? parameters = row['parameters'];
      return CatalogCommandDescriptor(
        milliseconds is int && milliseconds > 0
            ? Duration(milliseconds: milliseconds)
            : null,
        <Map<Object?, Object?>>[
          if (parameters is List<Object?>)
            for (final Object? parameter in parameters)
              if (parameter is Map<Object?, Object?>) parameter,
        ],
        row.containsKey('responseSchema')
            ? PatchbayResponseSchema.fromJson(row['responseSchema'])
            : null,
        PatchbayExecutionContract.fromCatalogRow(row),
        catalogInteractionModelReading(row),
      );
    }
    return null;
  }
}
