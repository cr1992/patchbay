// PB-050-38：目录的 **UI 目标投影**——把桥观察到的目标表贴到 domain 目录上。
//
// 两条构造路径共用同一个投影：静态 `domainCatalog` 与 `PatchbayCatalogProvider`
// 都必须给出同一份 `uiTargets`，否则接入方换一种接线方式就换一份目录事实。
// [PatchbayFlutterCatalogProvider] 除了这层投影不做别的——`commandsRevision`
// 原样透传，读取次数也不多不少一次。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';

import 'flutter_bridge.dart';

/// domain 的键在前，`uiTargets` 追加在后。
Map<String, Object?> patchbayWithUiTargets(
  Map<String, Object?> domain,
  PatchbayFlutterBridge bridge,
) => <String, Object?>{
  ...domain,
  'uiTargets': bridge
      .catalog()
      .map((PatchbayUiTargetDescriptor target) => target.toJson())
      .toList(growable: false),
};

/// 包着接入方 provider 的一层投影：只加 `uiTargets`，其余原样。
final class PatchbayFlutterCatalogProvider implements PatchbayCatalogProvider {
  const PatchbayFlutterCatalogProvider(this.domain, this.bridge);

  final PatchbayCatalogProvider domain;
  final PatchbayFlutterBridge bridge;

  @override
  int get commandsRevision => domain.commandsRevision;

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    final PatchbayCatalogSample sample = await domain.readCatalog();
    return PatchbayCatalogSample(
      commandsRevision: sample.commandsRevision,
      catalog: patchbayWithUiTargets(sample.catalog, bridge),
    );
  }
}
