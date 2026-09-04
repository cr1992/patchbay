// PB-050-38 / DG-060-04：admission pipeline 的**第一阶段**——catalog validity
// 与 descriptor 查找。
//
// 这一阶段回答两件事，且只回答这两件：整份目录此刻是否可用，以及被调命令的
// 声明 policy 是什么。它不评估任何门，也不看参数——DG-060-04 冻结的顺序里
// catalog validity 在 sensitive input 之前，而 sensitive input 又在任何门之前。
//
// 读目录是唯一一次 await，因此它也是本阶段唯一的现场变化窗口：读完之后立刻复核
// 一次取消冻结，再判断目录违规。顺序不能颠倒——一次已被取消的调用不该先收到目录
// 的诊断。
//
// 目录以 [PatchbayInvocationCatalogReader] 注入，测试因此可以脱离
// `HostCatalogHandler` 直接给出违规目录、给出漂移目录，或让读取抛出。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'host_catalog.dart';
import 'host_models.dart';
import 'invocation_rejections.dart';

/// 一次目录读取。host 传的是 `HostCatalogHandler.readInvocationCatalog`。
typedef PatchbayInvocationCatalogReader =
    Future<PatchbayCatalogValidity> Function();

/// catalog 阶段的结论。[response] 非空表示这一阶段已经决定了整次调用的应答。
final class PatchbayCatalogAdmission {
  const PatchbayCatalogAdmission.responded(Map<String, Object?> this.response)
    : validity = null,
      policy = const PatchbayCommandPolicy.undeclared();

  const PatchbayCatalogAdmission.admitted({
    required PatchbayCatalogValidity this.validity,
    required this.policy,
  }) : response = null;

  /// 冻结的取消应答或目录违规拒绝；`null` 表示放行。
  final Map<String, Object?>? response;

  /// 放行时这次调用据以决策的那一份目录读数。
  final PatchbayCatalogValidity? validity;

  /// 被调命令的声明 policy；未声明的命令按 fail-closed 的 `undeclared()` 处理。
  final PatchbayCommandPolicy policy;

  bool get admitted => response == null;
}

/// 读目录 → 复核取消 → 判目录违规 → 取出命令 policy。
///
/// [frozenCancellationResponse] 是 await 之后的现场复核接缝：返回非空即表示这次
/// 调用已被取消，冻结应答优先于目录诊断。
Future<PatchbayCatalogAdmission> patchbayAdmitInvocationCatalog({
  required PatchbayInvocationCatalogReader readCatalog,
  required String command,
  required String requestId,
  required Map<String, Object?>? Function() frozenCancellationResponse,
}) async {
  final PatchbayCatalogValidity catalog = await readCatalog();
  final Map<String, Object?>? cancelledAfterCatalog =
      frozenCancellationResponse();
  if (cancelledAfterCatalog != null) {
    return PatchbayCatalogAdmission.responded(cancelledAfterCatalog);
  }
  if (catalog.violation case final Map<String, Object?> reason) {
    return PatchbayCatalogAdmission.responded(
      patchbayInvalidInvocationEnvelope(
        requestId,
        'catalogUnavailable',
        <String, Object?>{'catalog': reason},
      ),
    );
  }
  return PatchbayCatalogAdmission.admitted(
    validity: catalog,
    policy:
        catalog.commandPolicies[command] ??
        const PatchbayCommandPolicy.undeclared(),
  );
}
