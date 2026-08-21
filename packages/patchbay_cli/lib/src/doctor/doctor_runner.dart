import 'package:args/args.dart';

import '../client.dart';
import '../rpc_timeout.dart';
import 'doctor_checks.dart';
import 'doctor_models.dart';

const String _noConnection = 'there is no connection to reach the App with';

/// Runs every check against one App and returns what it found.
Future<PatchbayDoctorReport> runPatchbayDoctor({
  required ArgResults options,
  required Future<PatchbayClient> Function(ArgResults options) connect,
  required Duration rpcTimeout,
}) async {
  final PatchbayDoctorFinding session = patchbaySessionDirectoryFinding(
    options,
  );
  final List<PatchbayDoctorFinding> findings = <PatchbayDoctorFinding>[session];
  final List<PatchbayDoctorWarning> warnings = <PatchbayDoctorWarning>[];

  // A session check that failed has already established there is nothing to
  // dial.
  if (session.verdict == PatchbayCheckVerdict.failed) {
    return PatchbayDoctorReport(
      findings: <PatchbayDoctorFinding>[
        session,
        skippedFinding(
          PatchbayDoctorCheck.connection,
          'no session resolves, so there is nothing to dial',
        ),
        skippedFinding(PatchbayDoctorCheck.catalog, _noConnection),
        skippedFinding(PatchbayDoctorCheck.lifecycle, _noConnection),
      ],
      warnings: warnings,
    );
  }

  PatchbayClient? connection;
  Map<String, Object?> identity = const <String, Object?>{};
  try {
    connection = PatchbayTimeoutClient(
      await dialPatchbayUnderBudget(
        () => connect(options),
        rpcTimeout: rpcTimeout,
      ),
      rpcTimeout: rpcTimeout,
    );
    identity = await connection.identity();
    findings.add(patchbayIdentityFinding(identity));
  } on Object catch (failure) {
    findings.add(
      patchbayFailureFinding(PatchbayDoctorCheck.connection, failure),
    );
    findings.addAll(<PatchbayDoctorFinding>[
      skippedFinding(PatchbayDoctorCheck.catalog, _noConnection),
      skippedFinding(PatchbayDoctorCheck.lifecycle, _noConnection),
    ]);
    warnings.add(
      const PatchbayDoctorWarning(
        kind: patchbaySnapshotUnavailableWarningKind,
        message:
            'the App is unreachable, so doctor cannot tell whether a business '
            'session is live on the device: $patchbayDestructiveRecoveryWarning',
      ),
    );
    return PatchbayDoctorReport(findings: findings, warnings: warnings);
  }

  try {
    final Map<String, Object?> catalog = await connection.catalog();
    findings.add(patchbayCatalogFinding(catalog));
    warnings.addAll(
      patchbayCapabilityWarnings(identity: identity, catalog: catalog),
    );
    warnings.addAll(await readSnapshotWarnings(connection));
    findings.add(
      await probePatchbayLifecycle(connection, catalog, identity: identity),
    );
  } on Object catch (failure) {
    findings.add(patchbayFailureFinding(PatchbayDoctorCheck.catalog, failure));
    findings.add(
      skippedFinding(
        PatchbayDoctorCheck.lifecycle,
        'the catalog read did not answer',
      ),
    );
  } finally {
    await closePatchbayQuietly(connection);
  }
  return PatchbayDoctorReport(findings: findings, warnings: warnings);
}
