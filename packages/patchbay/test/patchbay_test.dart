import 'host/host_invocation_admission_test.dart' as invocation_admission;
import 'host/host_jobs_snapshot_test.dart' as jobs_snapshot;
import 'host/host_registration_catalog_test.dart' as registration_catalog;

void main() {
  registration_catalog.main();
  invocation_admission.main();
  jobs_snapshot.main();
}
