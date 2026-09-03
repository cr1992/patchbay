// PB-050-38：注册表的**装配原语**——把声明与 handler 按位置配成一条注册。
//
// 这里的全部价值是那条位置约定本身：第 N 个 descriptor 配第 N 个 handler。它没有
// 名字校验，因为 descriptor 与 handler 各自都不知道对方是谁；错位不会抛，只会让
// 某条命令悄悄由别的桥应答——那是这类装配唯一会犯又最难看出来的错。所以数量对不上
// 时两头都要报：[bind] 在 descriptor 用完后还被要求配 handler 时报，[seal] 在
// handler 配完后还剩 descriptor 时报。
//
// 把它单独拎出来还有一个后果：数量失配可以脱离桥、脱离任何真实命令注入——给一个只
// 有一条 descriptor 的 builder 连 bind 两次即可。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';

import 'flutter_ui_rejection.dart';

/// 按位置把 descriptor 配给 handler，并在两端守住数量。
///
/// 一次性使用：[seal] 之后不要再 [bind]。
final class PatchbayUiRegistrationBuilder {
  PatchbayUiRegistrationBuilder(Iterable<PatchbayCommandDescriptor> descriptors)
    : _descriptors = descriptors.iterator;

  final Iterator<PatchbayCommandDescriptor> _descriptors;
  final List<PatchbayCommandRegistration<Object?>> _registrations =
      <PatchbayCommandRegistration<Object?>>[];

  /// 取下一条 descriptor，配上 [decode] / [handle]，追加进注册表。
  ///
  /// [strictKeys] 与 [includeReason] 只影响解码失败时的投影，不影响受理路径；
  /// [available] 为假时这条命令连目录都不出现（接入方没注入对应能力）。
  void bind<T>(
    PatchbayCommandDecoder<T> decode,
    PatchbayCommandHandler<T> handle, {
    bool strictKeys = false,
    bool includeReason = false,
    String? notice,
    bool available = true,
  }) {
    if (!_descriptors.moveNext()) {
      throw StateError('UI command descriptor/handler count mismatch');
    }
    _registrations.add(
      PatchbayCommandRegistration<T>(
        descriptor: _descriptors.current,
        decode: decode,
        handle: handle,
        available: available,
        onDecodeFailure: (failure, arguments, requestId, descriptor) =>
            patchbayInvalidUiArguments(
              requestId,
              descriptor.name,
              arguments,
              strictKeys: strictKeys,
              reason: includeReason
                  ? patchbayUiDecodeFailureReason(failure)
                  : null,
              notice: notice,
            ),
      ),
    );
  }

  /// 确认 descriptor 已经用尽，并交出注册表。
  PatchbayCommandRegistry seal() {
    if (_descriptors.moveNext()) {
      throw StateError('UI command descriptor/handler count mismatch');
    }
    return PatchbayCommandRegistry(_registrations);
  }
}
