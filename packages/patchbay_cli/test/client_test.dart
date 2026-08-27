import 'package:patchbay_cli/src/client.dart';
import 'package:test/test.dart';

void main() {
  test('rejects non-VM-Service URI schemes before opening a socket', () {
    expect(
      PatchbayConnection.connect(Uri.parse('file:///tmp/not-a-vm-service')),
      throwsA(isA<FormatException>()),
    );
  });
}
