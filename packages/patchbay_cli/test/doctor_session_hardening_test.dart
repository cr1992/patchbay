import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/session.dart';
import 'package:test/test.dart';

PatchbaySessionRecord _record({String? processStartTime}) =>
    PatchbaySessionRecord(
      sessionId: 'session-1',
      applicationId: 'com.example.app',
      appInstanceId: 'instance-1',
      isolateId: 'isolates/1',
      processId: 4242,
      wsUri: 'ws://127.0.0.1:1/ws',
      buildMode: 'debug',
      createdAt: DateTime.utc(2026, 8, 25),
      workspacePath: '/tmp/example',
      deviceId: 'device-1',
      processStartTime: processStartTime,
    );

void main() {
  group('PB-050-18/19 doctor wiring', () {
    test('statusFinding surfaces identityUnverified for legacy records', () {
      final PatchbaySessionListing listing = PatchbaySessionListing(
        record: _record(),
        status: PatchbaySessionStatus.live,
        selected: false,
        identityUnverified: true,
      );
      final PatchbayDoctorFinding finding = statusFinding(
        listing,
        'the pinned record',
        const <String, Object?>{},
      );
      expect(finding.details['identityUnverified'], isTrue);
    });

    test('statusFinding omits the flag for verified records', () {
      final PatchbaySessionListing listing = PatchbaySessionListing(
        record: _record(processStartTime: 'sig'),
        status: PatchbaySessionStatus.live,
        selected: false,
        identityUnverified: false,
      );
      final PatchbayDoctorFinding finding = statusFinding(
        listing,
        'the pinned record',
        const <String, Object?>{},
      );
      expect(finding.details.containsKey('identityUnverified'), isFalse);
    });

    test('patchbaySessionFinding reports quarantined files when present', () {
      final PatchbayDoctorFinding finding = patchbaySessionFinding(
        listings: const <PatchbaySessionListing>[],
        explicitSession: null,
        quarantinedFiles: const <String>['/tmp/s/a.json.quarantine-1-2'],
      );
      expect(finding.details['quarantined'], 1);
      expect(
        finding.details['quarantinedFiles'],
        contains('/tmp/s/a.json.quarantine-1-2'),
      );
    });

    test('patchbaySessionFinding action names all three recovery paths for '
        'an empty directory', () {
      final PatchbayDoctorFinding finding = patchbaySessionFinding(
        listings: const <PatchbaySessionListing>[],
        explicitSession: null,
      );
      expect(finding.details['code'], 'sessionDirectoryEmpty');
      expect(finding.action, contains('the launcher'));
      expect(finding.action, contains('--ws-uri'));
      expect(finding.action, contains('patchbay session register'));
    });
  });
}
