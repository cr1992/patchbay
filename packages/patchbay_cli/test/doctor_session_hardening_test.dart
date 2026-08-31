import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/trace/trace_redaction.dart';
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
      // PB-050-29：报告的是会话目录内的文件名，不是本机绝对路径。名字保留了
      // 操作者的可定位性（他知道自己的 --session-dir），而 doctor 输出是会被
      // 粘进 issue 的东西——同一原则已经让 workspace root 不进这份 finding。
      expect(finding.details['quarantinedFiles'], <String>[
        'a.json.quarantine-1-2',
      ]);
    });

    test('quarantined 文件名脱敏对各平台路径与退化输入都 fail-closed', () {
      final PatchbayDoctorFinding finding = patchbaySessionFinding(
        listings: const <PatchbaySessionListing>[],
        explicitSession: null,
        quarantinedFiles: const <String>[
          '/var/folders/xy/T/patchbay/b.json.quarantine-3-4',
          r'C:\Users\someone\AppData\Local\Temp\pb\c.json.quarantine-5-6',
          'd.json.quarantine-7-8',
        ],
      );

      expect(finding.details['quarantined'], 3);
      expect(finding.details['quarantinedFiles'], <String>[
        'b.json.quarantine-3-4',
        'c.json.quarantine-5-6',
        'd.json.quarantine-7-8',
      ]);
    });

    test('整份 details 里不残留任何看起来像绝对路径的字符串', () {
      // 出口级断言：不依赖调用方传了什么，也不依赖我们记住哪些键要脱敏。
      final PatchbayDoctorFinding finding = patchbaySessionFinding(
        listings: const <PatchbaySessionListing>[],
        explicitSession: null,
        quarantinedFiles: const <String>[
          '/tmp/s/a.json.quarantine-1-2',
          r'C:\tmp\s\b.json.quarantine-3-4',
        ],
      );

      final List<String> leaked = <String>[];
      void scan(Object? value) {
        if (value is String && looksAbsolutePath(value)) leaked.add(value);
        if (value is Map<Object?, Object?>) value.values.forEach(scan);
        if (value is List<Object?>) value.forEach(scan);
      }

      scan(finding.details);
      expect(leaked, isEmpty, reason: '泄露了绝对路径：$leaked');
    });

    test('退化输入报哨兵而不是泄露原值', () {
      // 实际的 `quarantinedFiles()` 只返回 File，因此这些取不到任何段的输入
      // 不会自然出现；断言的是「取不到文件名时宁可丢可定位性」。
      final PatchbayDoctorFinding finding = patchbaySessionFinding(
        listings: const <PatchbaySessionListing>[],
        explicitSession: null,
        quarantinedFiles: const <String>['', '/', r'C:\'],
      );

      expect(finding.details['quarantinedFiles'], <String>[
        '<redacted:absolute-path>',
        '<redacted:absolute-path>',
        '<redacted:absolute-path>',
      ]);
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
