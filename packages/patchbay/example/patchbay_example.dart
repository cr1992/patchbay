import 'package:patchbay/patchbay.dart';

Future<void> main() async {
  final registry = PatchbayCommandRegistry(
    const <PatchbayCommandRegistration<Object?>>[],
  );

  final result = await registry.dispatch(
    'example.command',
    const <String, Object?>{},
    'example-request-1',
  );
  print(result);
}
