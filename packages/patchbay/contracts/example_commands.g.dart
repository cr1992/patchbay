// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures
// Contract: example_commands.json
// Generator: packages/patchbay/tool/command_codegen.dart
import 'package:patchbay/patchbay.dart';

enum ExamplePatchbayCommandId {
  readingGet,
  runStart;

  String get wireName => switch (this) {
    ExamplePatchbayCommandId.readingGet => 'example.reading.get',
    ExamplePatchbayCommandId.runStart => 'example.run.start',
  };
  static ExamplePatchbayCommandId? parse(String value) => switch (value) {
    'example.reading.get' => ExamplePatchbayCommandId.readingGet,
    'example.run.start' => ExamplePatchbayCommandId.runStart,
    _ => null,
  };
}

enum ExamplePatchbayPermission { readState, controlDevice }

enum ExamplePatchbayCancellation { stopRun }

final class ExamplePatchbayCommandMetadata {
  const ExamplePatchbayCommandMetadata({
    required this.descriptor,
    this.permissions = const [],
    this.cancellation,
    this.suggestedWaitTimeoutMs,
    this.confirmationArgument,
  });
  final PatchbayCommandDescriptor descriptor;
  final List<ExamplePatchbayPermission> permissions;
  final ExamplePatchbayCancellation? cancellation;
  final int? suggestedWaitTimeoutMs;
  final String? confirmationArgument;
}

final class ExamplePatchbayDecodedCommand {
  const ExamplePatchbayDecodedCommand(this.command, this.values);
  final ExamplePatchbayCommandId command;
  final Map<String, Object?> values;
  String get mode => values['mode'] as String;
  int get passes => values['passes'] as int;
  bool get confirmed => values['confirmed'] as bool;
  String? get deviceSecret => values['deviceSecret'] as String?;
  T dispatch<T>({
    required T Function(ExamplePatchbayDecodedCommand) readingGet,
    required T Function(ExamplePatchbayDecodedCommand) runStart,
  }) => switch (command) {
    ExamplePatchbayCommandId.readingGet => readingGet(this),
    ExamplePatchbayCommandId.runStart => runStart(this),
  };
}

final class ExamplePatchbayDecodeResult {
  const ExamplePatchbayDecodeResult.accepted(this.command) : rejection = null;
  const ExamplePatchbayDecodeResult.rejected(this.rejection) : command = null;
  final ExamplePatchbayDecodedCommand? command;
  final PatchbayRejection? rejection;
}

final Map<ExamplePatchbayCommandId, ExamplePatchbayCommandMetadata>
examplePatchbayCommandMetadata = {
  ExamplePatchbayCommandId.readingGet: ExamplePatchbayCommandMetadata(
    descriptor: PatchbayCommandDescriptor(
      name: 'example.reading.get',
      summary: 'Read the last value the device reported.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: {PatchbayFactSource.appRecorded},
      gates: {},
      parameters: [],
    ),
    permissions: [ExamplePatchbayPermission.readState],
    cancellation: null,
    suggestedWaitTimeoutMs: null,
    confirmationArgument: null,
  ),
  ExamplePatchbayCommandId.runStart: ExamplePatchbayCommandMetadata(
    descriptor: PatchbayCommandDescriptor(
      name: 'example.run.start',
      summary: 'Ask the device to start a run and follow it as a job.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.job,
      sideEffect: PatchbaySideEffect.external,
      factSources: {
        PatchbayFactSource.appRecorded,
        PatchbayFactSource.deviceReported,
      },
      gates: {'example.deviceConnected'},
      parameters: [
        PatchbayParameterDescriptor(
          name: 'mode',
          type: PatchbayParameterType.enumeration,
          required: false,
          sensitive: false,
          defaultValue: 'quick',
          allowedValues: ['quick', 'full'],
        ),
        PatchbayParameterDescriptor(
          name: 'passes',
          type: PatchbayParameterType.integer,
          required: false,
          sensitive: false,
          defaultValue: 1,
          allowedValues: [],
        ),
        PatchbayParameterDescriptor(
          name: 'confirmed',
          type: PatchbayParameterType.boolean,
          required: true,
          sensitive: false,
          defaultValue: null,
          allowedValues: [],
        ),
        PatchbayParameterDescriptor(
          name: 'deviceSecret',
          type: PatchbayParameterType.string,
          required: false,
          sensitive: true,
          defaultValue: null,
          allowedValues: [],
        ),
      ],
    ),
    permissions: [ExamplePatchbayPermission.controlDevice],
    cancellation: ExamplePatchbayCancellation.stopRun,
    suggestedWaitTimeoutMs: 30000,
    confirmationArgument: 'confirmed',
  ),
};

List<PatchbayCommandDescriptor> get examplePatchbayCommandDescriptors =>
    List.unmodifiable(
      examplePatchbayCommandMetadata.values.map((value) => value.descriptor),
    );

ExamplePatchbayDecodeResult decodeExamplePatchbayCommand(
  String name,
  Map<String, Object?> raw,
) {
  final id = ExamplePatchbayCommandId.parse(name);
  if (id == null)
    return const ExamplePatchbayDecodeResult.rejected(
      PatchbayRejection(code: 'commandNotRegistered'),
    );
  final metadata = examplePatchbayCommandMetadata[id]!;
  final declared = {
    for (final parameter in metadata.descriptor.parameters)
      parameter.name: parameter,
  };
  final unknown = raw.keys.where((key) => !declared.containsKey(key)).toList()
    ..sort();
  if (unknown.isNotEmpty)
    return ExamplePatchbayDecodeResult.rejected(
      PatchbayRejection(
        code: 'invalidArguments',
        details: {'unknown': unknown},
      ),
    );
  final values = <String, Object?>{};
  for (final parameter in metadata.descriptor.parameters) {
    final value = raw.containsKey(parameter.name)
        ? raw[parameter.name]
        : parameter.defaultValue;
    if (parameter.required && value == null)
      return ExamplePatchbayDecodeResult.rejected(
        PatchbayRejection(
          code: 'invalidArguments',
          details: {'missing': parameter.name},
        ),
      );
    if (value == null) {
      values[parameter.name] = null;
      continue;
    }
    final typeOk = switch (parameter.type) {
      PatchbayParameterType.string ||
      PatchbayParameterType.enumeration => value is String,
      PatchbayParameterType.integer => value is int,
      PatchbayParameterType.number => value is num,
      PatchbayParameterType.boolean => value is bool,
      PatchbayParameterType.json => true,
    };
    if (!typeOk ||
        (parameter.allowedValues.isNotEmpty &&
            !parameter.allowedValues.contains(value)))
      return ExamplePatchbayDecodeResult.rejected(
        PatchbayRejection(
          code: 'invalidArguments',
          details: {'parameter': parameter.name},
        ),
      );
    values[parameter.name] = value;
  }
  final confirmation = metadata.confirmationArgument;
  if (confirmation != null && values[confirmation] != true)
    return const ExamplePatchbayDecodeResult.rejected(
      PatchbayRejection(code: 'explicitConfirmationRequired'),
    );
  return ExamplePatchbayDecodeResult.accepted(
    ExamplePatchbayDecodedCommand(id, Map.unmodifiable(values)),
  );
}
