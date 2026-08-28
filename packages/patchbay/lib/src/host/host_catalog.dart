import '../catalog_digest.dart';
import '../command_descriptor.dart';
import '../command_registry.dart';
import '../execution_evidence.dart';
import '../generated/core_wire.g.dart';
import '../response_schema.dart';
import 'host_models.dart';

final class PatchbayCatalogValidity {
  const PatchbayCatalogValidity._({
    required this.violation,
    required this.commandPolicies,
    required this.responseSchemas,
    required this.executionContracts,
    required this.retryPolicies,
  });

  const PatchbayCatalogValidity.valid({
    required Map<String, PatchbayCommandPolicy> commandPolicies,
    required Map<String, PatchbayResponseSchema> responseSchemas,
    required Map<String, PatchbayExecutionContract> executionContracts,
    required Map<String, PatchbayRetryPolicy> retryPolicies,
  }) : this._(
         violation: null,
         commandPolicies: commandPolicies,
         responseSchemas: responseSchemas,
         executionContracts: executionContracts,
         retryPolicies: retryPolicies,
       );

  factory PatchbayCatalogValidity.violated(Map<String, Object?> violation) =>
      PatchbayCatalogValidity._(
        violation: _freezeViolationMap(violation),
        commandPolicies: const <String, PatchbayCommandPolicy>{},
        responseSchemas: const <String, PatchbayResponseSchema>{},
        executionContracts: const <String, PatchbayExecutionContract>{},
        retryPolicies: const <String, PatchbayRetryPolicy>{},
      );

  final Map<String, Object?>? violation;
  final Map<String, PatchbayCommandPolicy> commandPolicies;
  final Map<String, PatchbayResponseSchema> responseSchemas;
  final Map<String, PatchbayExecutionContract> executionContracts;
  final Map<String, PatchbayRetryPolicy> retryPolicies;
}

final class HostCatalogHandler {
  HostCatalogHandler({
    PatchbayCatalogSource? catalogSource,
    PatchbayCatalogProvider? catalogProvider,
    required PatchbayCommandRegistry registry,
  }) : assert((catalogSource == null) != (catalogProvider == null)),
       _catalogSource = catalogSource,
       _catalogProvider = catalogProvider,
       _registry = registry;

  final PatchbayCatalogSource? _catalogSource;
  final PatchbayCatalogProvider? _catalogProvider;
  final PatchbayCommandRegistry _registry;

  Future<_CatalogLoad>? _legacyFlight;
  _VersionedCatalogFlight? _providerFlight;
  int? _highestRevision;
  int? _cacheRevision;
  String? _cacheCommandsDigest;
  PatchbayCatalogValidity? _cachedValidity;

  int _catalogBuildCount = 0;
  int _descriptorJsonCount = 0;
  int _commandsCanonicalizationCount = 0;
  int _catalogDigestCount = 0;

  /// Test-visible counters for the cache's construction-stage contract.
  ({
    int catalogBuilds,
    int descriptorJson,
    int commandsCanonicalization,
    int catalogDigest,
  })
  get debugBuildCounts => (
    catalogBuilds: _catalogBuildCount,
    descriptorJson: _descriptorJsonCount,
    commandsCanonicalization: _commandsCanonicalizationCount,
    catalogDigest: _catalogDigestCount,
  );

  Future<Map<String, Object?>> dispatchCatalog() async =>
      (await readCatalog()).response;

  /// Reads a complete catalog response. Versioned providers are still called
  /// on every explicit catalog request so dynamic non-command fields stay live.
  Future<PatchbayCatalogRead> readCatalog() async {
    if (_catalogProvider == null) return (await _readLegacy()).read;
    while (true) {
      final _RevisionObservation observation = _observeProviderRevision();
      if (observation.violation case final Map<String, Object?> violation) {
        return PatchbayCatalogRead.violated(violation);
      }
      final int revision = observation.revision!;
      final _VersionedCatalogFlight? flight = _providerFlight;
      if (flight != null) {
        if (flight.requestedRevision == revision) {
          return (await flight.future).read;
        }
        await flight.future;
        continue;
      }
      return (await _startProviderLoad(revision)).read;
    }
  }

  /// Obtains the whole-catalog validity and command policy used by invocation.
  Future<PatchbayCatalogValidity> readInvocationCatalog() async {
    if (_catalogProvider == null) return (await _readLegacy()).validity;
    while (true) {
      final _RevisionObservation observation = _observeProviderRevision();
      if (observation.violation case final Map<String, Object?> violation) {
        return PatchbayCatalogValidity.violated(violation);
      }
      final int revision = observation.revision!;
      if (_cacheRevision == revision && _cachedValidity != null) {
        return _cachedValidity!;
      }
      final _VersionedCatalogFlight? flight = _providerFlight;
      if (flight != null) {
        if (flight.requestedRevision == revision) {
          return (await flight.future).validity;
        }
        await flight.future;
        continue;
      }
      return (await _startProviderLoad(revision)).validity;
    }
  }

  Future<_CatalogLoad> _readLegacy() {
    final Future<_CatalogLoad>? existing = _legacyFlight;
    if (existing != null) return existing;
    late final Future<_CatalogLoad> flight;
    flight = () async {
      try {
        final Map<String, Object?> declared = await _catalogSource!();
        return _buildCatalog(declared);
      } on Object catch (error) {
        return _sourceFailure(error);
      } finally {
        if (identical(_legacyFlight, flight)) _legacyFlight = null;
      }
    }();
    _legacyFlight = flight;
    return flight;
  }

  _RevisionObservation _observeProviderRevision() {
    final int revision;
    try {
      revision = _catalogProvider!.commandsRevision;
    } on Object catch (error) {
      return _RevisionObservation.violated(_sourceFailureReason(error));
    }
    final Map<String, Object?>? violation = _revisionViolation(revision);
    return violation == null
        ? _RevisionObservation.valid(revision)
        : _RevisionObservation.violated(violation);
  }

  Future<_CatalogLoad> _startProviderLoad(int requestedRevision) {
    late final Future<_CatalogLoad> future;
    final _VersionedCatalogFlight flight = _VersionedCatalogFlight(
      requestedRevision,
      () async {
        try {
          final PatchbayCatalogSample sample = await _catalogProvider!
              .readCatalog();
          final Map<String, Object?>? revisionViolation =
              sample.commandsRevision == requestedRevision
              ? null
              : _revisionViolation(sample.commandsRevision);
          if (revisionViolation != null) {
            return _violationLoad(revisionViolation);
          }
          return _commitVersioned(
            _buildCatalog(
              sample.catalog,
              commandsRevision: sample.commandsRevision,
            ),
          );
        } on Object catch (error) {
          return _sourceFailure(error);
        } finally {
          if (identical(_providerFlight?.future, future)) {
            _providerFlight = null;
          }
        }
      }(),
    );
    future = flight.future;
    _providerFlight = flight;
    return future;
  }

  Map<String, Object?>? _revisionViolation(int revision) {
    if (revision < 0) {
      return <String, Object?>{
        'reason': 'catalogRevisionInvalid',
        'revision': revision,
      };
    }
    final int? highest = _highestRevision;
    if (highest != null && revision < highest) {
      return <String, Object?>{
        'reason': 'catalogRevisionRegressed',
        'revision': revision,
        'highestRevision': highest,
      };
    }
    if (highest == null || revision > highest) _highestRevision = revision;
    return null;
  }

  _CatalogLoad _commitVersioned(_CatalogLoad load) {
    final int revision = load.commandsRevision!;
    if (_cacheRevision == revision &&
        _cacheCommandsDigest != null &&
        load.commandsDigest != null &&
        _cacheCommandsDigest != load.commandsDigest) {
      final Map<String, Object?> violation = <String, Object?>{
        'reason': 'catalogRevisionContentChanged',
        'revision': revision,
      };
      final PatchbayCatalogValidity invalid = PatchbayCatalogValidity.violated(
        violation,
      );
      _cachedValidity = invalid;
      return _CatalogLoad(
        read: PatchbayCatalogRead.violated(violation),
        validity: invalid,
        commandsRevision: revision,
        commandsDigest: load.commandsDigest,
      );
    }
    if (_cacheRevision != revision) {
      _cacheRevision = revision;
      _cacheCommandsDigest = load.commandsDigest;
      _cachedValidity = load.validity;
    } else if (_cachedValidity == null) {
      _cacheCommandsDigest = load.commandsDigest;
      _cachedValidity = load.validity;
    }
    return load;
  }

  _CatalogLoad _buildCatalog(
    Map<String, Object?> declared, {
    int? commandsRevision,
  }) {
    _catalogBuildCount += 1;
    final Object? declaredCommands = declared['commands'];
    final Object? commands = switch (declaredCommands) {
      List<Object?> values => <Object?>[..._registryCommandRows(), ...values],
      null when !_registry.isEmpty => _registryCommandRows(),
      _ => declaredCommands,
    };
    final Map<String, Object?> catalog = <String, Object?>{
      ...declared,
      if (commands != null) 'commands': commands,
      'schemaVersion': 1,
    };
    final _CommandsValidation validation = _validateCommands(commands);
    if (validation.violation case final Map<String, Object?> violation) {
      final String? commandsDigest = _tryCommandsDigest(commands)?.value;
      return _CatalogLoad(
        read: PatchbayCatalogRead.violated(violation),
        validity: PatchbayCatalogValidity.violated(violation),
        commandsRevision: commandsRevision,
        commandsDigest: commandsDigest,
      );
    }
    final PatchbayCatalogDigest digest = _digestCommands(commands);
    return _CatalogLoad(
      read: PatchbayCatalogRead.valid(<String, Object?>{
        ...catalog,
        'catalogDigest': digest.toJson(),
      }),
      validity: PatchbayCatalogValidity.valid(
        commandPolicies: validation.commandPolicies,
        responseSchemas: validation.responseSchemas,
        executionContracts: validation.executionContracts,
        retryPolicies: validation.retryPolicies,
      ),
      commandsRevision: commandsRevision,
      commandsDigest: digest.value,
    );
  }

  List<Object?> _registryCommandRows() {
    final List<Object?> rows = <Object?>[];
    for (final PatchbayCommandDescriptor descriptor in _registry.descriptors) {
      _descriptorJsonCount += 1;
      rows.add(descriptor.toJson());
    }
    return rows;
  }

  PatchbayCatalogDigest _digestCommands(Object? commands) {
    _commandsCanonicalizationCount += 1;
    _catalogDigestCount += 1;
    return PatchbayCatalogDigest.ofCommands(commands);
  }

  PatchbayCatalogDigest? _tryCommandsDigest(Object? commands) {
    try {
      return _digestCommands(commands);
    } on Object {
      return null;
    }
  }

  static _CatalogLoad _sourceFailure(Object error) =>
      _violationLoad(_sourceFailureReason(error));

  static Map<String, Object?> _sourceFailureReason(Object error) =>
      <String, Object?>{
        'reason': 'catalogSourceFailed',
        'error': error.runtimeType.toString(),
      };

  static _CatalogLoad _violationLoad(Map<String, Object?> violation) =>
      _CatalogLoad(
        read: PatchbayCatalogRead.violated(violation),
        validity: PatchbayCatalogValidity.violated(violation),
      );

  static _CommandsValidation _validateCommands(Object? commands) {
    if (commands == null) return const _CommandsValidation.valid();
    if (commands is! List<Object?>) {
      return const _CommandsValidation.violated(<String, Object?>{
        'reason': 'commandsNotAnArray',
      });
    }
    final List<Map<String, Object?>> violations = <Map<String, Object?>>[];
    final Set<String> names = <String>{};
    final Map<String, PatchbayCommandPolicy> commandPolicies =
        <String, PatchbayCommandPolicy>{};
    final Map<String, PatchbayResponseSchema> responseSchemas =
        <String, PatchbayResponseSchema>{};
    final Map<String, PatchbayExecutionContract> executionContracts =
        <String, PatchbayExecutionContract>{};
    final Map<String, PatchbayRetryPolicy> retryPolicies =
        <String, PatchbayRetryPolicy>{};
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
        continue;
      }
      if (!patchbayCommandNamePattern.hasMatch(rawName)) {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'invalidCommandName',
        });
        continue;
      }
      if (!names.add(rawName)) {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'duplicateCommandName',
        });
        continue;
      }
      if (entry is! Map<Object?, Object?>) continue;
      commandPolicies[rawName] = PatchbayCommandPolicy.fromCatalogRow(entry);
      if (entry.containsKey('responseSchema')) {
        try {
          final PatchbayResponseSchema schema = PatchbayResponseSchema.fromJson(
            entry['responseSchema'],
          );
          if (entry['mode'] == 'job' &&
              !schema.terminal.keys.toSet().containsAll(const <String>{
                'completed',
                'failed',
                'cancelled',
              })) {
            throw const FormatException('incomplete terminal schema');
          }
          responseSchemas[rawName] = schema;
        } on Object {
          violations.add(<String, Object?>{
            'index': index,
            'name': rawName,
            'reason': 'invalidResponseSchema',
          });
        }
      }
      if (entry.containsKey('retryPolicy')) {
        try {
          if (entry['sideEffect'] != PatchbaySideEffectWire.external.name) {
            throw const FormatException(
              'retryPolicy requires external sideEffect',
            );
          }
          retryPolicies[rawName] = PatchbayRetryPolicy.fromJson(
            entry['retryPolicy'],
          );
        } on Object {
          violations.add(<String, Object?>{
            'index': index,
            'name': rawName,
            'reason': 'invalidRetryPolicy',
          });
        }
      }
      try {
        executionContracts[rawName] = PatchbayExecutionContract.fromCatalogRow(
          entry,
        );
      } on Object {
        violations.add(<String, Object?>{
          'index': index,
          'name': rawName,
          'reason': 'invalidExecutionContract',
        });
      }
    }
    if (violations.isNotEmpty) {
      return _CommandsValidation.violated(<String, Object?>{
        'reason': 'invalidCatalogCommands',
        'commandNamePattern': patchbayCommandNamePattern.pattern,
        'violations': violations,
      });
    }
    return _CommandsValidation.valid(
      commandPolicies: Map<String, PatchbayCommandPolicy>.unmodifiable(
        commandPolicies,
      ),
      responseSchemas: Map<String, PatchbayResponseSchema>.unmodifiable(
        responseSchemas,
      ),
      executionContracts: Map<String, PatchbayExecutionContract>.unmodifiable(
        executionContracts,
      ),
      retryPolicies: Map<String, PatchbayRetryPolicy>.unmodifiable(
        retryPolicies,
      ),
    );
  }
}

final class _RevisionObservation {
  const _RevisionObservation.valid(this.revision) : violation = null;

  const _RevisionObservation.violated(this.violation) : revision = null;

  final int? revision;
  final Map<String, Object?>? violation;
}

final class _VersionedCatalogFlight {
  const _VersionedCatalogFlight(this.requestedRevision, this.future);

  final int requestedRevision;
  final Future<_CatalogLoad> future;
}

final class _CatalogLoad {
  const _CatalogLoad({
    required this.read,
    required this.validity,
    this.commandsRevision,
    this.commandsDigest,
  });

  final PatchbayCatalogRead read;
  final PatchbayCatalogValidity validity;
  final int? commandsRevision;
  final String? commandsDigest;
}

final class _CommandsValidation {
  const _CommandsValidation.valid({
    this.commandPolicies = const <String, PatchbayCommandPolicy>{},
    this.responseSchemas = const <String, PatchbayResponseSchema>{},
    this.executionContracts = const <String, PatchbayExecutionContract>{},
    this.retryPolicies = const <String, PatchbayRetryPolicy>{},
  }) : violation = null;

  const _CommandsValidation.violated(this.violation)
    : commandPolicies = const <String, PatchbayCommandPolicy>{},
      responseSchemas = const <String, PatchbayResponseSchema>{},
      executionContracts = const <String, PatchbayExecutionContract>{},
      retryPolicies = const <String, PatchbayRetryPolicy>{};

  final Map<String, Object?>? violation;
  final Map<String, PatchbayCommandPolicy> commandPolicies;
  final Map<String, PatchbayResponseSchema> responseSchemas;
  final Map<String, PatchbayExecutionContract> executionContracts;
  final Map<String, PatchbayRetryPolicy> retryPolicies;
}

Map<String, Object?> _freezeViolationMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: _freezeViolationValue(entry.value),
    });

Object? _freezeViolationValue(Object? value) => switch (value) {
  Map<Object?, Object?> map =>
    Map<Object?, Object?>.unmodifiable(<Object?, Object?>{
      for (final MapEntry<Object?, Object?> entry in map.entries)
        entry.key: _freezeViolationValue(entry.value),
    }),
  List<Object?> values => List<Object?>.unmodifiable(
    values.map(_freezeViolationValue),
  ),
  _ => value,
};
