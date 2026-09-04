// PB-050-38：参数校验的**拒绝投影阶段**——把一次解码失败变成 `invalidUiArguments`。
//
// 与 `flutter_ui_argument_decoders.dart` 是同一段的两半：解码器只负责判定「这组
// 参数不可受理」并抛出，本文件负责回答「不可受理在哪里」。分开是因为两者的输入输出
// 完全不同——解码器吃 wire map 吐类型化请求，投影吃一个失败对象加声明表吐信封——
// 而且投影这一半可以脱离任何桥、任何命令单独构造与断言。
//
// 判据只有一个来源：host 自己发布的那份 descriptor 列表。让「哪个键缺了」从目录
// 里推导出来，而不是手抄第二份命令形状，是这条拒绝不会与声明漂移的唯一理由。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';

import 'flutter_ui_command_descriptors.dart';
import 'inspect_bridge.dart';

/// `invalidUiArguments`，naming what is actually wrong with the request.
///
/// A bare `invalidUiArguments` says only that *something* about the arguments
/// is unacceptable, which leaves the caller to bisect their own request key by
/// key. `details` names it instead: `missing` for a declared parameter the
/// request left out, `unexpected` for a key the command does not declare,
/// `invalid` for a declared key whose value has the wrong type or an
/// undeclared enum value, and `reason` for a shape rule no single key can
/// express (`ui.wait` conditions require different companions).
///
/// Only parameter *names* travel. They are protocol vocabulary published in
/// the catalog; the values are caller data and may be sensitive, so they stay
/// out of the envelope exactly as they do everywhere else.
///
/// [strictKeys] says whether this call site actually refuses undeclared keys.
/// The sites that do not — `exec`-style commands that forward `--args`
/// wholesale — must not have unrelated keys listed as if they were the reason.
Map<String, Object?> patchbayInvalidUiArguments(
  String requestId,
  String command,
  Map<String, Object?> arguments, {
  bool strictKeys = false,
  String? reason,
  String? notice,
}) {
  final PatchbayUiArgumentShape? shape = patchbayUiArgumentShapes[command];
  final List<String> missing = shape?.missing(arguments) ?? const <String>[];
  final List<String> unexpected = strictKeys
      ? shape?.unexpected(arguments) ?? const <String>[]
      : const <String>[];
  final List<String> invalid = shape?.invalid(arguments) ?? const <String>[];
  return PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: 'invalidUiArguments',
      notice: notice,
      details: <String, Object?>{
        'command': command,
        if (missing.isNotEmpty) 'missing': missing,
        if (unexpected.isNotEmpty) 'unexpected': unexpected,
        if (invalid.isNotEmpty) 'invalid': invalid,
        'reason': ?reason,
      },
    ),
  ).toJson();
}

/// A rejection reason that names the rule without echoing a value.
///
/// The wire decoders and `PatchbayUiWaitRequest` already phrase their own
/// failures in protocol vocabulary — field paths, expected types, which
/// companion a condition needs — so their `FormatException` message is exactly
/// the sentence the caller needs. Anything else is reported as its type only:
/// an `ArgumentError.toString()` embeds the offending value, and no caller
/// value belongs in a response envelope.
String patchbayUiDecodeFailureReason(Object failure) => switch (failure) {
  FormatException(:final String message) => message,
  ArgumentError(:final Object? name) when name is String =>
    '$name is out of the accepted range',
  _ => failure.runtimeType.toString(),
};

/// Declared argument shape per UI command, read from the descriptors this
/// host publishes.
///
/// Deriving the rejection details from the same list the catalog serves is
/// what stops "which key is missing" from becoming a second, hand-maintained
/// copy of every command shape — one that would drift away from the
/// declaration the caller actually reads.
///
/// 运行期覆写（gates、参数默认）与这张表无关，所以它按空覆写建一次就够：覆写只改
/// 门与缺省值，不改参数的名字、必填与类型，而这三项才是拒绝要指名的东西。
///
/// 拆分前它是类私有的 `static final`，包内谁也改不着；搬成 top-level 之后可见性扩到
/// 整个 `lib/src/`，所以这里显式封成不可变——拒绝判据是全进程共享的一份，任何一处
/// 写进去都会静默改掉其他所有命令的拒绝形状。`final` 的懒初始化语义不受影响：首次
/// 读取时才建表。
final Map<String, PatchbayUiArgumentShape> patchbayUiArgumentShapes =
    Map<String, PatchbayUiArgumentShape>.unmodifiable(
      <String, PatchbayUiArgumentShape>{
        for (final PatchbayCommandDescriptor descriptor
            in patchbayFlutterUiCommandDescriptors(
              captureGates: const <String>{},
              keepAwakeGates: const <String>{},
              inspectPolicy: const PatchbayInspectPolicy(),
            ))
          descriptor.name: PatchbayUiArgumentShape(descriptor.parameters),
      },
    );

/// One command's declared parameters, reduced to what a rejection has to name.
///
/// It answers three questions and nothing more: which declared parameters this
/// request left out, which keys it carries that were never declared, and which
/// declared keys hold a value of the wrong shape. Every answer is a list of
/// names, sorted so two identical failures produce two identical envelopes.
final class PatchbayUiArgumentShape {
  PatchbayUiArgumentShape(List<PatchbayParameterDescriptor> parameters)
    : _parameters = <String, PatchbayParameterDescriptor>{
        for (final PatchbayParameterDescriptor parameter in parameters)
          parameter.name: parameter,
      };

  final Map<String, PatchbayParameterDescriptor> _parameters;

  /// Declared-required parameters this request omits.
  ///
  /// A key present with a `null` value counts as omitted: JSON has no way to
  /// say "explicitly absent", and every decoder here treats null as missing.
  List<String> missing(Map<String, Object?> arguments) => <String>[
    for (final PatchbayParameterDescriptor parameter in _parameters.values)
      if (parameter.required && arguments[parameter.name] == null)
        parameter.name,
  ]..sort();

  /// Keys this command does not declare at all.
  List<String> unexpected(Map<String, Object?> arguments) => <String>[
    for (final String key in arguments.keys)
      if (!_parameters.containsKey(key)) key,
  ]..sort();

  /// Declared keys whose value does not match the declaration.
  List<String> invalid(Map<String, Object?> arguments) => <String>[
    for (final MapEntry<String, PatchbayParameterDescriptor> entry
        in _parameters.entries)
      if (arguments[entry.key] case final Object value
          when !_matches(entry.value, value))
        entry.key,
  ]..sort();

  static bool _matches(PatchbayParameterDescriptor parameter, Object value) =>
      switch (parameter.type) {
        PatchbayParameterType.string => value is String,
        PatchbayParameterType.integer => value is int,
        PatchbayParameterType.number => value is num,
        PatchbayParameterType.boolean => value is bool,
        // An enumeration is a string drawn from a published set, so an
        // unlisted word is as wrong as a number would be.
        PatchbayParameterType.enumeration =>
          value is String && parameter.allowedValues.contains(value),
        // `json` declares no shape, so nothing about a value can contradict it.
        PatchbayParameterType.json => true,
      };
}
