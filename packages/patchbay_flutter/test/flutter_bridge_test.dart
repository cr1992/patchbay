import 'bridge/semantics_gesture_bridge_test.dart' as semantics_gesture;
import 'bridge/semantics_tree_bridge_test.dart' as semantics_tree;
import 'bridge/target_catalog_bridge_test.dart' as target_catalog;
import 'bridge/text_target_bridge_test.dart' as text_target;

void main() {
  target_catalog.main();
  semantics_tree.main();
  semantics_gesture.main();
  text_target.main();
}
