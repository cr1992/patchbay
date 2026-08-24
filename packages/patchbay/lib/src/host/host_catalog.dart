import '../catalog_digest.dart';
import '../command_descriptor.dart';
import '../command_registry.dart';
import '../execution_evidence.dart';
import '../generated/core_wire.g.dart';
import '../response_schema.dart';
import 'host_models.dart';

final class HostCatalogHandler {
  HostCatalogHandler({
    required PatchbayCatalogSource catalogSource,
    required PatchbayCommandRegistry registry,
  }) : _catalog = catalogSource,
       _registry = registry;

  final PatchbayCatalogSource _catalog;
  final PatchbayCommandRegistry _registry;

  Map<String, PatchbayResponseSchema> responseSchemas =
      const <String, PatchbayResponseSchema>{};
  Map<String, PatchbayExecutionContract> executionContracts =
      const <String, PatchbayExecutionContract>{};
  int readGeneration = 0;

  Future<Map<String, Object?>> dispatchCatalog() async =>
      (await readCatalog()).response;

  Future<PatchbayCatalogRead> readCatalog() async {
    final int generation = ++readGeneration;
    final Map<String, Object?> declared;
    try {
      declared = await _catalog();
    } on Object catch (error) {
      if (generation == readGeneration) {
        responseSchemas = const <String, PatchbayResponseSchema>{};
        executionContracts = const <String, PatchbayExecutionContract>{};
      }
      return PatchbayCatalogRead.violated(<String, Object?>{
        'reason': 'catalogSourceFailed',
        'error': error.runtimeType.toString(),
      });
    }
    final Object? declaredCommands = declared['commands'];
    final Object? commands = switch (declaredCommands) {
      List<Object?> values => <Object?>[
        ..._registry.descriptors.map((descriptor) => descriptor.toJson()),
        ...values,
      ],
      null when !_registry.isEmpty => <Object?>[
        ..._registry.descriptors.map((descriptor) => descriptor.toJson()),
      ],
      _ => declaredCommands,
    };
    final Map<String, Object?> catalog = <String, Object?>{
      ...declared,
      if (commands != null) 'commands': commands,
      'schemaVersion': 1,
    };
    final Map<String, Object?>? violation = commandsViolation(
      catalog['commands'],
    );
    if (violation != null) {
      if (generation == readGeneration) {
        responseSchemas = const <String, PatchbayResponseSchema>{};
        executionContracts = const <String, PatchbayExecutionContract>{};
      }
      return PatchbayCatalogRead.violated(violation);
    }
    if (generation == readGeneration) {
      responseSchemas = responseSchemasFromCatalog(catalog);
      executionContracts = executionContractsFromCatalog(catalog);
    }
    return PatchbayCatalogRead.valid(<String, Object?>{
      ...catalog,
      'catalogDigest': PatchbayCatalogDigest.ofCommands(
        catalog['commands'],
      ).toJson(),
    });
  }

  static Map<String, Object?>? commandsViolation(Object? commands) {
    if (commands == null) return null;
    if (commands is! List<Object?>) {
      return <String, Object?>{'reason': 'commandsNotAnArray'};
    }
    final List<Map<String, Object?>> violations = <Map<String, Object?>>[];
    final Set<String> names = <String>{};
    for (var index = 0; index < commands.length; index += 1) {
      final Object? entry = commands[index];
      final Object? rawName = entry is Map<Object?, Object?>
          ? entry['name']
          : null;
      if (rawName is! String) {
        violations.add(<String, Object?>{
          'index': index,
          'reason': 'missingCommandName',
        });
      } else if (!patchbayCommandNamePattern.hasMatch(rawName)) {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'invalidCommandName',
        });
      } else if (!names.add(rawName)) {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'duplicateCommandName',
        });
      } else if (entry case final Map<Object?, Object?> command) {
        if (command.containsKey('responseSchema')) {
          try {
            final PatchbayResponseSchema schema =
                PatchbayResponseSchema.fromJson(command['responseSchema']);
            if (command['mode'] == 'job' &&
                !schema.terminal.keys.toSet().containsAll(const <String>{
                  'completed',
                  'failed',
                  'cancelled',
                })) {
              throw const FormatException('incomplete terminal schema');
            }
          } on Object {
            violations.add(<String, Object?>{
              'index': index,
              'name': rawName,
              'reason': 'invalidResponseSchema',
            });
          }
        }
        if (command.containsKey('retryPolicy')) {
          try {
            if (command['sideEffect'] != PatchbaySideEffectWire.external.name) {
              throw const FormatException(
                'retryPolicy requires external sideEffect',
              );
            }
            PatchbayRetryPolicy.fromJson(command['retryPolicy']);
          } on Object {
            violations.add(<String, Object?>{
              'index': index,
              'name': rawName,
              'reason': 'invalidRetryPolicy',
            });
          }
        }
        try {
          PatchbayExecutionContract.fromCatalogRow(command);
        } on Object {
          violations.add(<String, Object?>{
            'index': index,
            'name': rawName,
            'reason': 'invalidExecutionContract',
          });
        }
      }
    }
    if (violations.isEmpty) return null;
    return <String, Object?>{
      'reason': 'invalidCatalogCommands',
      'commandNamePattern': patchbayCommandNamePattern.pattern,
      'violations': violations,
    };
  }

  static Map<String, PatchbayResponseSchema> responseSchemasFromCatalog(
    Map<String, Object?> catalog,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return const <String, PatchbayResponseSchema>{};
    final Map<String, PatchbayResponseSchema> schemas =
        <String, PatchbayResponseSchema>{};
    for (final Object? row in rows) {
      if (row is! Map<Object?, Object?> ||
          row['name'] is! String ||
          !row.containsKey('responseSchema')) {
        continue;
      }
      schemas[row['name']! as String] = PatchbayResponseSchema.fromJson(
        row['responseSchema'],
      );
    }
    return Map<String, PatchbayResponseSchema>.unmodifiable(schemas);
  }

  static Map<String, PatchbayExecutionContract> executionContractsFromCatalog(
    Map<String, Object?> catalog,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) {
      return const <String, PatchbayExecutionContract>{};
    }
    return Map<String, PatchbayExecutionContract>.unmodifiable(<
      String,
      PatchbayExecutionContract
    >{
      for (final Object? row in rows)
        if (row is Map<Object?, Object?> && row['name'] is String)
          row['name']! as String: PatchbayExecutionContract.fromCatalogRow(row),
    });
  }
}
