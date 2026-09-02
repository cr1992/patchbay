// 定版机检与落盘入口。
//
// 实现已模块化拆分至 `src/release_prep/`：
// - `constants.dart`：仓内坐标、路径常量
// - `models.dart`：判定模型、SemVer 版本模型
// - `pubspec_scanner.dart`：极小 pubspec 解析与版本改写
// - `package_topology.dart`：包间依赖拓扑与发布顺序
// - `markdown_links.dart`：Markdown 相对链接检查与绝对化改写
// - `changelog_manager.dart`：CHANGELOG 状态读取、碎片解析与包内派生
// - `lockfile_checker.dart`：example/pubspec.lock 检查与版本改写
// - `compat_matrix_manager.dart`：兼容矩阵与协议兼容语料生成
// - `release_checker.dart`：定版与发布门禁纯数据判定逻辑
// - `runner.dart`：CLI 入口、磁盘读写与主执行编排

export 'src/release_prep/changelog_manager.dart';
export 'src/release_prep/compat_matrix_manager.dart';
export 'src/release_prep/constants.dart';
export 'src/release_prep/lockfile_checker.dart';
export 'src/release_prep/markdown_links.dart';
export 'src/release_prep/models.dart';
export 'src/release_prep/package_topology.dart';
export 'src/release_prep/pubspec_scanner.dart';
export 'src/release_prep/release_checker.dart';
export 'src/release_prep/runner.dart';

import 'src/release_prep/runner.dart' as runner;

void main(List<String> arguments) => runner.main(arguments);
