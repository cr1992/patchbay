import 'facts.dart';
import 'response_schema.dart';

enum PatchbayExecutionClassification {
  notSent,
  sentUnconfirmed,
  unchanged,
  deviceConfirmed,
}

const int patchbayUnchangedEvidenceMaxAgeMs = 300000;
const int patchbayConfirmationBudgetMaxMs = 120000;

/// Descriptor-owned policy used to interpret a payload's `execution` object.
final class PatchbayExecutionContract {
  const PatchbayExecutionContract({
    required this.factSources,
    this.unchangedEvidenceMaxAgeMs,
    this.confirmationBudgetMs,
    this.weakConfirmationCompletes = false,
  });

  final Set<PatchbayFactSource> factSources;
  final int? unchangedEvidenceMaxAgeMs;
  final int? confirmationBudgetMs;
  final bool weakConfirmationCompletes;

  factory PatchbayExecutionContract.fromCatalogRow(Map<Object?, Object?> row) {
    final Object? rawSources = row['factSources'];
    final Set<PatchbayFactSource> sources = <PatchbayFactSource>{};
    if (rawSources != null && rawSources is! List<Object?>) {
      throw const FormatException('factSources must be an array');
    }
    if (rawSources is List<Object?>) {
      for (final Object? raw in rawSources) {
        if (raw is! String) {
          throw const FormatException('factSources must contain strings');
        }
        final PatchbayFactSource? source = _factSource(raw);
        if (source == null) {
          throw const FormatException('unknown factSource');
        }
        sources.add(source);
      }
    }
    final Object? rawUnchanged = row['unchangedEvidenceMaxAgeMs'];
    final Object? rawConfirmation = row['confirmationBudgetMs'];
    final Object? rawWeak = row['weakConfirmationCompletes'];
    if (row.containsKey('unchangedEvidenceMaxAgeMs') && rawUnchanged is! int) {
      throw const FormatException('unchangedEvidenceMaxAgeMs must be integer');
    }
    if (row.containsKey('confirmationBudgetMs') && rawConfirmation is! int) {
      throw const FormatException('confirmationBudgetMs must be integer');
    }
    if (row.containsKey('weakConfirmationCompletes') && rawWeak is! bool) {
      throw const FormatException('weakConfirmationCompletes must be boolean');
    }
    if (rawWeak == true && row['mode'] != 'job') {
      throw const FormatException(
        'weakConfirmationCompletes is only valid for job commands',
      );
    }
    final PatchbayExecutionContract contract = PatchbayExecutionContract(
      factSources: Set<PatchbayFactSource>.unmodifiable(sources),
      unchangedEvidenceMaxAgeMs: rawUnchanged as int?,
      confirmationBudgetMs: rawConfirmation as int?,
      weakConfirmationCompletes: rawWeak as bool? ?? false,
    );
    validatePatchbayExecutionContract(contract);
    return contract;
  }
}

final class PatchbayExecutionValidationResult {
  const PatchbayExecutionValidationResult({
    this.issues = const <PatchbayResponseValidationIssue>[],
    this.legacyDispatchedConflict = false,
  });

  final List<PatchbayResponseValidationIssue> issues;
  final bool legacyDispatchedConflict;
}

void validatePatchbayExecutionContract(PatchbayExecutionContract contract) {
  final int? unchanged = contract.unchangedEvidenceMaxAgeMs;
  if (unchanged != null &&
      (unchanged < 1 || unchanged > patchbayUnchangedEvidenceMaxAgeMs)) {
    throw ArgumentError.value(
      unchanged,
      'unchangedEvidenceMaxAgeMs',
      'must be in 1..$patchbayUnchangedEvidenceMaxAgeMs',
    );
  }
  final int? confirmation = contract.confirmationBudgetMs;
  if (confirmation != null &&
      (confirmation < 1 || confirmation > patchbayConfirmationBudgetMaxMs)) {
    throw ArgumentError.value(
      confirmation,
      'confirmationBudgetMs',
      'must be in 1..$patchbayConfirmationBudgetMaxMs',
    );
  }
  if (contract.weakConfirmationCompletes && confirmation == null) {
    throw ArgumentError(
      'weakConfirmationCompletes requires confirmationBudgetMs',
    );
  }
}

PatchbayExecutionValidationResult validatePatchbayExecutionEvidence(
  PatchbayExecutionContract contract,
  Object? payload, {
  String path = r'$.payload',
  String? terminalPhase,
  required int nowMs,
}) {
  if (payload is! Map<Object?, Object?> || !payload.containsKey('execution')) {
    return const PatchbayExecutionValidationResult();
  }
  final List<PatchbayResponseValidationIssue> issues =
      <PatchbayResponseValidationIssue>[];
  final Object? rawExecution = payload['execution'];
  if (rawExecution is! Map<Object?, Object?>) {
    return PatchbayExecutionValidationResult(
      issues: <PatchbayResponseValidationIssue>[
        PatchbayResponseValidationIssue(
          field: '$path.execution',
          reason: 'wrongType',
          expected: 'object',
        ),
      ],
    );
  }
  const Set<String> baseFields = <String>{
    'classification',
    'factSource',
    'observedAtMs',
    'reasonCode',
  };
  const Set<String> priorFields = <String>{
    'priorValueSource',
    'priorObservedAtMs',
  };
  for (final Object? key in rawExecution.keys) {
    if (key is! String ||
        (!baseFields.contains(key) && !priorFields.contains(key))) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: key is String ? '$path.execution.$key' : '$path.execution',
          reason: 'unknownField',
        ),
      );
    }
  }
  for (final String field in baseFields) {
    if (!rawExecution.containsKey(field)) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: '$path.execution.$field',
          reason: 'missingField',
        ),
      );
    }
  }
  final Object? rawClassification = rawExecution['classification'];
  final PatchbayExecutionClassification? classification =
      rawClassification is String
      ? PatchbayExecutionClassification.values
            .cast<PatchbayExecutionClassification?>()
            .firstWhere(
              (PatchbayExecutionClassification? value) =>
                  value?.name == rawClassification,
              orElse: () => null,
            )
      : null;
  if (rawClassification != null && rawClassification is! String) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.classification',
        reason: 'wrongType',
        expected: 'string',
      ),
    );
  } else if (rawClassification is String && classification == null) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.classification',
        reason: 'unknownVariant',
        expected: PatchbayExecutionClassification.values
            .map((PatchbayExecutionClassification value) => value.name)
            .join('|'),
      ),
    );
  }
  final Object? rawSource = rawExecution['factSource'];
  final PatchbayFactSource? source = rawSource is String
      ? _factSource(rawSource)
      : null;
  if (rawSource != null && rawSource is! String) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.factSource',
        reason: 'wrongType',
        expected: 'string',
      ),
    );
  } else if (rawSource is String &&
      (source == null || !contract.factSources.contains(source))) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.factSource',
        reason: 'unknownVariant',
        expected:
            (contract.factSources
                    .map((PatchbayFactSource value) => value.name)
                    .toList(growable: false)
                  ..sort())
                .join('|'),
      ),
    );
  }
  _nullableScalar(
    rawExecution,
    'observedAtMs',
    int,
    '$path.execution.observedAtMs',
    issues,
  );
  final Object? observedAtMs = rawExecution['observedAtMs'];
  if (observedAtMs is int && observedAtMs < 0) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.observedAtMs',
        reason: 'unknownVariant',
        expected: 'nonNegativeInteger|null',
      ),
    );
  }
  if (source == PatchbayFactSource.unknown && observedAtMs != null) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.observedAtMs',
        reason: 'unknownVariant',
        expected: 'nullWhenFactSourceUnknown',
      ),
    );
  }
  _nullableScalar(
    rawExecution,
    'reasonCode',
    String,
    '$path.execution.reasonCode',
    issues,
  );

  if (classification == PatchbayExecutionClassification.unchanged) {
    _validateUnchanged(contract, rawExecution, path, nowMs, issues);
  } else {
    for (final String field in priorFields) {
      if (rawExecution.containsKey(field)) {
        issues.add(
          PatchbayResponseValidationIssue(
            field: '$path.execution.$field',
            reason: 'unknownField',
          ),
        );
      }
    }
  }
  if (classification == PatchbayExecutionClassification.sentUnconfirmed ||
      classification == PatchbayExecutionClassification.deviceConfirmed) {
    if (contract.confirmationBudgetMs == null) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: r'$.descriptor.confirmationBudgetMs',
          reason: 'missingField',
        ),
      );
    }
  }
  if (classification == PatchbayExecutionClassification.deviceConfirmed &&
      source != PatchbayFactSource.deviceReported) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.factSource',
        reason: 'unknownVariant',
        expected: PatchbayFactSource.deviceReported.name,
      ),
    );
  }
  if (classification != null && terminalPhase != null) {
    final bool phaseAllowed = switch (classification) {
      PatchbayExecutionClassification.notSent => terminalPhase == 'failed',
      PatchbayExecutionClassification.sentUnconfirmed =>
        terminalPhase == 'failed' ||
            (contract.weakConfirmationCompletes &&
                terminalPhase == 'completed'),
      PatchbayExecutionClassification.unchanged ||
      PatchbayExecutionClassification.deviceConfirmed =>
        terminalPhase == 'completed',
    };
    if (!phaseAllowed) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: '$path.execution.classification',
          reason: 'unknownVariant',
          expected: 'phaseCompatible:$terminalPhase',
        ),
      );
    }
  }

  final Object? dispatched = payload['dispatched'];
  final bool conflict =
      dispatched is bool &&
      classification != null &&
      dispatched != (classification != PatchbayExecutionClassification.notSent);
  return PatchbayExecutionValidationResult(
    issues: List<PatchbayResponseValidationIssue>.unmodifiable(
      issues.take(patchbayResponseValidationMaxIssues),
    ),
    legacyDispatchedConflict: conflict,
  );
}

void _validateUnchanged(
  PatchbayExecutionContract contract,
  Map<Object?, Object?> execution,
  String path,
  int nowMs,
  List<PatchbayResponseValidationIssue> issues,
) {
  final int? maxAge = contract.unchangedEvidenceMaxAgeMs;
  if (maxAge == null) {
    issues.add(
      const PatchbayResponseValidationIssue(
        field: r'$.descriptor.unchangedEvidenceMaxAgeMs',
        reason: 'missingField',
      ),
    );
  }
  for (final String field in <String>[
    'priorValueSource',
    'priorObservedAtMs',
  ]) {
    if (!execution.containsKey(field)) {
      issues.add(
        PatchbayResponseValidationIssue(
          field: '$path.execution.$field',
          reason: 'missingField',
        ),
      );
    }
  }
  final Object? rawPriorSource = execution['priorValueSource'];
  if (rawPriorSource != null && rawPriorSource is! String) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.priorValueSource',
        reason: 'wrongType',
        expected: 'string',
      ),
    );
  } else if (rawPriorSource is String &&
      rawPriorSource != PatchbayFactSource.deviceReported.name &&
      rawPriorSource != PatchbayFactSource.appRecorded.name) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.priorValueSource',
        reason: 'unknownVariant',
        expected: 'deviceReported|appRecorded',
      ),
    );
  }
  final Object? rawPriorAt = execution['priorObservedAtMs'];
  if (rawPriorAt != null && rawPriorAt is! int) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.priorObservedAtMs',
        reason: 'wrongType',
        expected: 'integer',
      ),
    );
  } else if (rawPriorAt is int &&
      maxAge != null &&
      (rawPriorAt > nowMs || nowMs - rawPriorAt > maxAge)) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: '$path.execution.priorObservedAtMs',
        reason: 'unknownVariant',
        expected: 'ageMs<=${contract.unchangedEvidenceMaxAgeMs}',
      ),
    );
  }
}

void _nullableScalar(
  Map<Object?, Object?> object,
  String field,
  Type type,
  String path,
  List<PatchbayResponseValidationIssue> issues,
) {
  if (!object.containsKey(field)) return;
  final Object? value = object[field];
  if (value == null) return;
  final bool matches = type == int ? value is int : value is String;
  if (!matches) {
    issues.add(
      PatchbayResponseValidationIssue(
        field: path,
        reason: 'wrongType',
        expected: type == int ? 'integer|null' : 'string|null',
      ),
    );
  }
}

PatchbayFactSource? _factSource(String value) =>
    PatchbayFactSource.values.cast<PatchbayFactSource?>().firstWhere(
      (PatchbayFactSource? candidate) => candidate?.name == value,
      orElse: () => null,
    );
