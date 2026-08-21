// CLI 自己要读的 catalog 行描述符。
//
// 放在中立的 `support/` 层：`commands/` 与 `output/` 都要用它，
// 若继续住在 `commands/` 里就会形成 commands -> output -> commands 的领域环。
import 'package:patchbay/patchbay.dart';

/// One catalog row, read only for what the CLI itself has to decide.
final class CatalogCommandDescriptor {
  const CatalogCommandDescriptor(
    this.suggestedWaitTimeout,
    this._parameters,
    this.responseSchema,
    this.executionContract,
  );

  final Duration? suggestedWaitTimeout;
  final List<Map<Object?, Object?>> _parameters;
  final PatchbayResponseSchema? responseSchema;
  final PatchbayExecutionContract executionContract;

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
      );
    }
    return null;
  }
}
