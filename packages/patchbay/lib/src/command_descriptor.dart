import 'facts.dart';
import 'execution_evidence.dart';
import 'generated/core_wire.g.dart';
import 'output_projection.dart';
import 'response_schema.dart';
import 'ui_descriptor.dart';

enum PatchbayCommandMode { readOnly, immediate, job }

enum PatchbayParameterType {
  string,
  integer,
  number,
  boolean,
  enumeration,
  json,
}

/// Bounded retry contract for one consumer-owned external command.
///
/// The presence of this object is the command's explicit idempotency opt-in.
/// [maxAttempts] includes the first attempt; clients must reuse one requestId
/// across every attempt so the host can return the same execution fact.
final class PatchbayRetryPolicy {
  const PatchbayRetryPolicy({
    required this.maxAttempts,
    required this.backoffMs,
  });

  factory PatchbayRetryPolicy.fromJson(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any(
          (Object? key) => key != 'maxAttempts' && key != 'backoffMs',
        )) {
      throw const FormatException('invalid retryPolicy shape');
    }
    final Object? maxAttempts = value['maxAttempts'];
    final Object? backoffMs = value['backoffMs'];
    if (maxAttempts is! int ||
        maxAttempts < 2 ||
        maxAttempts > 3 ||
        backoffMs is! int ||
        backoffMs < 0 ||
        backoffMs > 5000) {
      throw const FormatException('invalid retryPolicy bounds');
    }
    return PatchbayRetryPolicy(maxAttempts: maxAttempts, backoffMs: backoffMs);
  }

  final int maxAttempts;
  final int backoffMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'maxAttempts': maxAttempts,
    'backoffMs': backoffMs,
  };
}

/// Machine-readable argument declaration used by both validation and CLI help.
final class PatchbayParameterDescriptor {
  const PatchbayParameterDescriptor({
    required this.name,
    required this.type,
    this.required = false,
    this.sensitive = false,
    this.defaultValue,
    this.allowedValues = const <Object?>[],
    this.summary,
  });

  final String name;
  final PatchbayParameterType type;
  final bool required;
  final bool sensitive;
  final Object? defaultValue;
  final List<Object?> allowedValues;
  final String? summary;

  /// Returns the same stable parameter declaration with a host-observed
  /// default.
  ///
  /// Runtime adapters use this for defaults that belong to consumer policy
  /// (for example a lease duration). Shape, sensitivity, allowed values, and
  /// documentation remain owned by the canonical protocol descriptor.
  PatchbayParameterDescriptor withRuntimeDefault(Object? value) =>
      PatchbayParameterDescriptor(
        name: name,
        type: type,
        required: required,
        sensitive: sensitive,
        defaultValue: value,
        allowedValues: allowedValues,
        summary: summary,
      );

  PatchbayParameterDescriptorWire _toWire() => PatchbayParameterDescriptorWire(
    name: name,
    type: _parameterTypeWire(type),
    required: required,
    sensitive: sensitive,
    defaultValue: defaultValue,
    allowedValues: allowedValues,
    summary: summary,
  );

  Map<String, Object?> toJson() => _toWire().toJson();
}

/// One CLI spelling derived from a protocol-owned command descriptor.
///
/// This metadata is deliberately local to the Dart packages: it is build-time
/// syntax for the separately deployed CLI, not a runtime capability, and is
/// therefore never included in [PatchbayCommandDescriptor.toJson]. One service
/// command may expose several spellings when the path injects a fixed argument
/// such as an `on`/`off` or `ui.wait` condition variant.
final class PatchbayCliSyntax {
  const PatchbayCliSyntax({
    required this.id,
    required this.path,
    required this.summary,
    this.usageSuffix = '',
    this.positionalParameters = const <String>[],
    this.optionParameters = const <String, String>{},
    this.positiveParameters = const <String>{},
    this.fixedArguments = const <String, Object?>{},
    this.fencesNavigationRevision = false,
    this.inputMode = PatchbayCliInputMode.descriptorParameters,
    this.nonNegativeParameters = const <String>{},
    this.omitOptionDefaults = const <String>{},
    this.trailingParameter,
    this.stdinParameter,
    this.stdinMarkerParameter,
    this.trailingWhen,
    this.artifactDisposition = PatchbayCliArtifactDisposition.none,
  });

  /// Stable Dart identifier used by generated CLI registration code.
  final String id;
  final List<String> path;
  final String summary;
  final String usageSuffix;

  /// Descriptor parameter names, in argv positional order.
  final List<String> positionalParameters;

  /// Descriptor parameter name to long option name.
  final Map<String, String> optionParameters;

  /// Numeric parameters whose CLI spelling accepts positive values only.
  final Set<String> positiveParameters;

  /// Arguments implied by the chosen path rather than typed by the operator.
  final Map<String, Object?> fixedArguments;

  /// Whether an omitted `revision` is resolved through navigation.current.
  final bool fencesNavigationRevision;
  final PatchbayCliInputMode inputMode;
  final Set<String> nonNegativeParameters;
  final Set<String> omitOptionDefaults;
  final String? trailingParameter;
  final String? stdinParameter;
  final String? stdinMarkerParameter;
  final PatchbayCliEqualsCondition? trailingWhen;
  final PatchbayCliArtifactDisposition artifactDisposition;
}

enum PatchbayCliInputMode { descriptorParameters, mergedJsonObject }

enum PatchbayCliArtifactDisposition { none, payloadBlob, responseBlob }

final class PatchbayCliEqualsCondition {
  const PatchbayCliEqualsCondition({
    required this.parameter,
    required this.value,
  });

  final String parameter;
  final Object? value;
}

/// Consumer-neutral catalog entry. Business namespaces remain consumer-owned.
final class PatchbayCommandDescriptor {
  const PatchbayCommandDescriptor({
    required this.name,
    required this.summary,
    required this.plane,
    required this.mode,
    required this.sideEffect,
    required this.factSources,
    this.parameters = const <PatchbayParameterDescriptor>[],
    this.gates = const <String>{},
    this.responseSchema,
    this.unchangedEvidenceMaxAgeMs,
    this.confirmationBudgetMs,
    this.weakConfirmationCompletes = false,
    this.retryPolicy,
    this.outputProjection,
    this.cliSyntax = const <PatchbayCliSyntax>[],
  });

  final String name;
  final String summary;
  final PatchbayPlane plane;
  final PatchbayCommandMode mode;
  final PatchbaySideEffect sideEffect;

  /// Sources that may occur in this command's result payload.
  ///
  /// The actual payload remains authoritative and may refine the source at a
  /// deeper object path. This declaration lets clients reject undocumented
  /// provenance instead of guessing from a command name.
  final Set<PatchbayFactSource> factSources;
  final List<PatchbayParameterDescriptor> parameters;
  final Set<String> gates;
  final PatchbayResponseSchema? responseSchema;
  final int? unchangedEvidenceMaxAgeMs;
  final int? confirmationBudgetMs;
  final bool weakConfirmationCompletes;

  PatchbayExecutionContract get executionContract => PatchbayExecutionContract(
    factSources: factSources,
    unchangedEvidenceMaxAgeMs: unchangedEvidenceMaxAgeMs,
    confirmationBudgetMs: confirmationBudgetMs,
    weakConfirmationCompletes: weakConfirmationCompletes,
  );

  /// Idempotent retry opt-in for a consumer-owned external command.
  ///
  /// A registry-owned command cannot declare this: the host's external
  /// fallback is the boundary that owns requestId de-duplication.
  final PatchbayRetryPolicy? retryPolicy;

  /// PB-050-40: how a machine consumer's `--view brief` and local artifact are
  /// derived from this command's accepted response.
  ///
  /// Optional, and deliberately a **loose sibling** of the strict descriptor
  /// wire rather than a field of [PatchbayCommandDescriptorWire]: catalog rows
  /// already travel as loosely-read JSON (`responseSchema`, `retryPolicy` and
  /// `weakConfirmationCompletes` are appended the same way), so an old reader
  /// ignores this key instead of failing on it, `schemaVersion` stays `1`, and
  /// no request or envelope a shipped client decodes strictly grows a field.
  /// The catalog digest covers it for free, because that digest is taken over
  /// whole command objects.
  ///
  /// Absent means "descriptor-less legacy", which is not the same as an empty
  /// projection: the CLI falls back to its frozen 0.5.0 table for a command it
  /// already knew, and leaves everything else untouched.
  final PatchbayOutputProjection? outputProjection;

  /// Build-time CLI syntax. It is intentionally absent from the wire form.
  final List<PatchbayCliSyntax> cliSyntax;

  /// Applies the only catalog fields a runtime adapter may specialize.
  ///
  /// The command identity and stable contract deliberately cannot be supplied
  /// here. This keeps runtime packages from rebuilding names, summaries,
  /// planes, modes, side effects, fact sources, or parameter schemas beside
  /// the protocol-owned canonical descriptor.
  PatchbayCommandDescriptor withRuntimeOverrides({
    Set<String>? gates,
    Map<String, Object?> parameterDefaults = const <String, Object?>{},
  }) {
    final Set<String> parameterNames = parameters
        .map((PatchbayParameterDescriptor parameter) => parameter.name)
        .toSet();
    final List<String> unknownDefaults =
        parameterDefaults.keys
            .where((String name) => !parameterNames.contains(name))
            .toList(growable: false)
          ..sort();
    if (unknownDefaults.isNotEmpty) {
      throw ArgumentError.value(
        unknownDefaults,
        'parameterDefaults',
        'contains parameters not declared by $name',
      );
    }
    return PatchbayCommandDescriptor(
      name: name,
      summary: summary,
      plane: plane,
      mode: mode,
      sideEffect: sideEffect,
      factSources: factSources,
      parameters: <PatchbayParameterDescriptor>[
        for (final PatchbayParameterDescriptor parameter in parameters)
          if (parameterDefaults.containsKey(parameter.name))
            parameter.withRuntimeDefault(parameterDefaults[parameter.name])
          else
            parameter,
      ],
      gates: gates ?? this.gates,
      outputProjection: outputProjection,
      cliSyntax: cliSyntax,
    );
  }

  Map<String, Object?> toJson() {
    final List<PatchbayFactSourceWire> sortedFactSources =
        factSources.map(_factSourceWire).toList(growable: false)
          ..sort((a, b) => a.name.compareTo(b.name));
    final List<String> sortedGates = gates.toList(growable: false)..sort();
    final Map<String, Object?> json = PatchbayCommandDescriptorWire(
      name: name,
      summary: summary,
      plane: _planeWire(plane),
      mode: _commandModeWire(mode),
      sideEffect: _sideEffectWire(sideEffect),
      factSources: sortedFactSources,
      gates: sortedGates,
      parameters: parameters
          .map((value) => value._toWire())
          .toList(growable: false),
    ).toJson();
    if (responseSchema case final PatchbayResponseSchema schema) {
      json['responseSchema'] = schema.toJson();
    }
    if (unchangedEvidenceMaxAgeMs case final int value) {
      json['unchangedEvidenceMaxAgeMs'] = value;
    }
    if (confirmationBudgetMs case final int value) {
      json['confirmationBudgetMs'] = value;
    }
    json['weakConfirmationCompletes'] = weakConfirmationCompletes;
    if (retryPolicy case final PatchbayRetryPolicy policy) {
      json['retryPolicy'] = policy.toJson();
    }
    if (outputProjection case final PatchbayOutputProjection projection) {
      json['outputProjection'] = projection.toJson();
    }
    return json;
  }
}

PatchbayCommandModeWire _commandModeWire(PatchbayCommandMode value) =>
    switch (value) {
      PatchbayCommandMode.readOnly => PatchbayCommandModeWire.readOnly,
      PatchbayCommandMode.immediate => PatchbayCommandModeWire.immediate,
      PatchbayCommandMode.job => PatchbayCommandModeWire.job,
    };

PatchbayParameterTypeWire _parameterTypeWire(PatchbayParameterType value) =>
    switch (value) {
      PatchbayParameterType.string => PatchbayParameterTypeWire.string,
      PatchbayParameterType.integer => PatchbayParameterTypeWire.integer,
      PatchbayParameterType.number => PatchbayParameterTypeWire.number,
      PatchbayParameterType.boolean => PatchbayParameterTypeWire.boolean,
      PatchbayParameterType.enumeration =>
        PatchbayParameterTypeWire.enumeration,
      PatchbayParameterType.json => PatchbayParameterTypeWire.json,
    };

PatchbayPlaneWire _planeWire(PatchbayPlane value) => switch (value) {
  PatchbayPlane.domain => PatchbayPlaneWire.domain,
  PatchbayPlane.flutterUi => PatchbayPlaneWire.flutterUi,
};

PatchbaySideEffectWire _sideEffectWire(PatchbaySideEffect value) =>
    switch (value) {
      PatchbaySideEffect.none => PatchbaySideEffectWire.none,
      PatchbaySideEffect.appState => PatchbaySideEffectWire.appState,
      PatchbaySideEffect.external => PatchbaySideEffectWire.external,
    };

PatchbayFactSourceWire _factSourceWire(PatchbayFactSource value) =>
    switch (value) {
      PatchbayFactSource.appRecorded => PatchbayFactSourceWire.appRecorded,
      PatchbayFactSource.commandEcho => PatchbayFactSourceWire.commandEcho,
      PatchbayFactSource.deviceReported =>
        PatchbayFactSourceWire.deviceReported,
      PatchbayFactSource.uiObserved => PatchbayFactSourceWire.uiObserved,
      PatchbayFactSource.unknown => PatchbayFactSourceWire.unknown,
    };
