// `dart run patchbay:check_pana_budget` 的入口。
//
// 实现住在 `tool/`（与测试的相对引用保持不变）；`bin/` 只做转发，让 git/pub
// 依赖方无需 clone 源码即可运行该检查。
import '../tool/check_pana_budget.dart' as tool;

void main(List<String> arguments) => tool.main(arguments);
