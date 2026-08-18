import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test('closed state maps future platform spellings to unknown', () {
    expect(
      PatchbayPermissionState.fromWire('vendorFutureState'),
      PatchbayPermissionState.unknown,
    );
    expect(
      PatchbayPermissionState.fromWire('unsupported'),
      PatchbayPermissionState.unsupported,
    );
  });

  test('capability and status preserve platform facts on the wire', () {
    final PatchbayPermissionCapabilities capabilities =
        PatchbayPermissionCapabilities.fromJson(<String, Object?>{
          'platform': 'android',
          'driver': 'fixture.driver',
          'driverVersion': '7',
          'permissions': <String, Object?>{
            'camera': <String, Object?>{
              'actions': <String>['status', 'exercise'],
              'decisions': <String>['allow', 'deny'],
            },
          },
        });
    expect(
      capabilities.permissions['camera']!.actions,
      contains(PatchbayPermissionAction.exercise),
    );

    final PatchbayPermissionStatus status = PatchbayPermissionStatus.fromJson(
      <String, Object?>{
        'permission': 'camera',
        'platformPermission': 'android.permission.CAMERA',
        'state': 'futureVendorState',
        'platformState': 'futureVendorState',
        'factSource': 'deviceReported',
        'driver': 'fixture.driver',
        'driverVersion': '7',
        'supportedActions': <String>['status'],
        'requiresRestart': false,
        'requiresSettings': false,
        'systemUiExpected': false,
      },
    );
    expect(status.state, PatchbayPermissionState.unknown);
    expect(status.platformState, 'futureVendorState');
    expect(status.toJson()['state'], 'unknown');
  });

  test('response keeps admission, evidence and interruption typed', () {
    final PatchbayPermissionDriverResponse response =
        PatchbayPermissionDriverResponse.fromJson(<String, Object?>{
          'protocolVersion': '1.2',
          'requestId': 'r1',
          'admission': 'rejected',
          'rejection': <String, Object?>{
            'code': 'systemUiUnexpected',
            'details': const <String, Object?>{},
          },
          'evidence': <Object?>[
            <String, Object?>{
              'factSource': 'uiObserved',
              'kind': 'systemWindow',
              'details': <String, Object?>{'matched': false},
            },
          ],
          'interruption': <String, Object?>{
            'expected': false,
            'handled': false,
            'permission': 'camera',
            'code': 'systemUiUnexpected',
          },
        });
    expect(response.accepted, isFalse);
    expect(
      response.evidence.single.factSource,
      PatchbayPermissionFactSource.uiObserved,
    );
    expect(response.interruption?.handled, isFalse);
    expect(
      PatchbayPermissionDriverRequest.fromJson(
        const PatchbayPermissionDriverRequest(
          requestId: 'r2',
          operation: PatchbayPermissionOperation.status,
          permission: 'camera',
          timeoutMs: 1000,
        ).toJson(),
      ).operation,
      PatchbayPermissionOperation.status,
    );
  });

  test('protocol major parser refuses malformed versions', () {
    expect(patchbayPermissionProtocolMajorOf('1.9'), 1);
    expect(
      () => patchbayPermissionProtocolMajorOf('next'),
      throwsA(
        isA<PatchbayPermissionWireException>().having(
          (PatchbayPermissionWireException error) => error.code,
          'code',
          'platformDriverVersionMismatch',
        ),
      ),
    );
  });
}
