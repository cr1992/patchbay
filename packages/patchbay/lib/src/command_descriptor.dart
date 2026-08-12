import 'facts.dart';
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

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type.name,
    'required': required,
    'sensitive': sensitive,
    if (defaultValue != null) 'default': defaultValue,
    if (allowedValues.isNotEmpty) 'allowedValues': allowedValues,
    if (summary != null) 'summary': summary,
  };
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

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'summary': summary,
    'plane': plane.name,
    'mode': mode.name,
    'sideEffect': sideEffect.name,
    'factSources':
        factSources.map((PatchbayFactSource value) => value.name).toList()
          ..sort(),
    'gates': gates.toList()..sort(),
    'parameters': parameters
        .map((PatchbayParameterDescriptor value) => value.toJson())
        .toList(growable: false),
  };
}
