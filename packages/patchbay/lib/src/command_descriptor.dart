import 'facts.dart';
import 'generated/core_wire.g.dart';
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

  Map<String, Object?> toJson() {
    final List<PatchbayFactSourceWire> sortedFactSources =
        factSources.map(_factSourceWire).toList(growable: false)
          ..sort((a, b) => a.name.compareTo(b.name));
    final List<String> sortedGates = gates.toList(growable: false)..sort();
    return PatchbayCommandDescriptorWire(
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
