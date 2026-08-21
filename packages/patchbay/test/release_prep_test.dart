import 'release_prep/release_prep_changelog_test.dart' as changelog;
import 'release_prep/release_prep_e2e_test.dart' as e2e;
import 'release_prep/release_prep_gates_test.dart' as gates;
import 'release_prep/release_prep_versioning_test.dart' as versioning;

void main() {
  versioning.main();
  changelog.main();
  gates.main();
  e2e.main();
}
