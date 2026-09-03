import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI syntax remains local metadata outside the strict wire descriptor',
    () {
      for (final PatchbayCommandDescriptor descriptor
          in patchbayProtocolCliCommandDescriptors) {
        expect(descriptor.cliSyntax, isNotEmpty, reason: descriptor.name);
        expect(descriptor.toJson(), isNot(contains('cliSyntax')));
        expect(descriptor.toJson().keys.toSet(), <String>{
          'name',
          'summary',
          'plane',
          'mode',
          'sideEffect',
          'factSources',
          'gates',
          'parameters',
          // 执行证据契约的线上字段，随 !62 进入 main：与 cliSyntax 不同，它
          // 本就属于协议面，所以出现在这里是对的。
          'weakConfirmationCompletes',
          // DG-060-05 additive sibling，只在声明了 interactionModel 的
          // 命令上出现——见 ui_interaction_model_descriptor_test.dart 对
          // 「恰好那 10 条」的机检。
          if (descriptor.interactionModel != null) 'interactionModel',
          // PB-050-40：机器投影声明同样是松读 catalog sibling，只在声明了
          // 投影的命令上出现；这里保持等值集，不退化成允许集。
          if (descriptor.outputProjection != null) 'outputProjection',
        }, reason: descriptor.name);
      }
    },
  );

  test('syntax metadata can express variants and fixed argument injection', () {
    const PatchbayCliSyntax enabled = PatchbayCliSyntax(
      id: 'fixtureOn',
      path: <String>['fixture', 'on'],
      summary: 'Enable fixture.',
      fixedArguments: <String, Object?>{'enabled': true},
    );
    const PatchbayCliSyntax disabled = PatchbayCliSyntax(
      id: 'fixtureOff',
      path: <String>['fixture', 'off'],
      summary: 'Disable fixture.',
      fixedArguments: <String, Object?>{'enabled': false},
    );

    expect(enabled.path, isNot(disabled.path));
    expect(enabled.fixedArguments['enabled'], isTrue);
    expect(disabled.fixedArguments['enabled'], isFalse);
  });

  test('runtime overrides cannot rebuild the stable command contract', () {
    final PatchbayCommandDescriptor canonical =
        patchbayUiInspectSelectCommandDescriptor;
    final PatchbayCommandDescriptor runtime = canonical.withRuntimeOverrides(
      gates: const <String>{'consumer.inspect'},
      parameterDefaults: const <String, Object?>{'ttlMs': 1234},
    );

    expect(runtime.name, canonical.name);
    expect(runtime.summary, canonical.summary);
    expect(runtime.plane, canonical.plane);
    expect(runtime.mode, canonical.mode);
    expect(runtime.sideEffect, canonical.sideEffect);
    expect(runtime.factSources, canonical.factSources);
    expect(runtime.cliSyntax, canonical.cliSyntax);
    expect(runtime.gates, const <String>{'consumer.inspect'});
    expect(
      runtime.parameters
          .singleWhere(
            (PatchbayParameterDescriptor parameter) =>
                parameter.name == 'ttlMs',
          )
          .defaultValue,
      1234,
    );
    expect(
      runtime.parameters.map((parameter) => parameter.name),
      canonical.parameters.map((parameter) => parameter.name),
    );
    expect(
      () => canonical.withRuntimeOverrides(
        parameterDefaults: const <String, Object?>{'undeclared': 1},
      ),
      throwsArgumentError,
    );
  });

  test('identifier action freezes the required generation CLI contract', () {
    final PatchbayCommandDescriptor descriptor =
        patchbayUiSemanticsActionByIdentifierCommandDescriptor;
    final PatchbayCliSyntax syntax = descriptor.cliSyntax.single;

    expect(descriptor.name, 'ui.semantics.actionByIdentifier');
    expect(descriptor.parameters.map((parameter) => parameter.name), <String>[
      'identifier',
      'generation',
      'action',
      'text',
      'inputWasStdin',
    ]);
    expect(
      descriptor.parameters
          .where((parameter) => parameter.required)
          .map((parameter) => parameter.name),
      <String>['identifier', 'generation', 'action'],
    );
    expect(syntax.path, <String>['ui', 'action']);
    expect(syntax.positionalParameters, <String>[
      'identifier',
      'generation',
      'action',
    ]);
    expect(syntax.nonNegativeParameters, <String>{'generation'});
    expect(syntax.stdinParameter, 'text');
    expect(syntax.stdinMarkerParameter, 'inputWasStdin');
  });
}
