import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI syntax remains local metadata outside the strict wire descriptor',
    () {
      for (final PatchbayCommandDescriptor descriptor
          in patchbayProtocolCliCommandDescriptors) {
        expect(descriptor.cliSyntax, isNotEmpty, reason: descriptor.name);
        expect(descriptor.toJson(), isNot(contains('cliSyntax')));
        expect(descriptor.toJson().keys, <String>{
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
        });
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
}
