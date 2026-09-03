// PB-050-38：参数校验的**解码阶段**——wire map 进，类型化请求出，不合格就抛。
//
// 每个解码器只回答一个问题：这组参数能不能变成一次可执行的请求。它们不决定拒绝
// 长什么样——那是 `flutter_ui_rejection.dart` 的事——所以这里一律抛
// `FormatException`，句子用协议词汇写，永不回显调用方的值。
//
// 两类严格度在这里就分开了，不是到投影阶段才分：`patchbayRejectUnexpectedUiKeys`
// 出现在哪个解码器里，哪条命令就当场拒绝未声明的键；`exec` 式命令（参数整包来自
// `--args`）刻意不调用它。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_protocol.dart';

import 'semantics_bridge.dart';

Map<String, Object?> patchbayDecodeUiText(Map<String, Object?> arguments) {
  if (arguments['id'] is! String ||
      arguments['generation'] is! int ||
      arguments['text'] is! String) {
    throw const FormatException('id, generation and text are required');
  }
  return arguments;
}

Map<String, Object?> patchbayDecodeUiSemanticsTree(
  Map<String, Object?> arguments,
) {
  if (arguments['maxDepth'] != null && arguments['maxDepth'] is! int ||
      arguments['maxNodes'] != null && arguments['maxNodes'] is! int) {
    throw const FormatException('invalid semantics tree bounds');
  }
  return arguments;
}

Map<String, Object?> patchbayDecodeUiSemanticsAction(
  Map<String, Object?> arguments,
) {
  final Object? rawAction = arguments['action'];
  final PatchbaySemanticsAction? action = rawAction is String
      ? PatchbaySemanticsAction.fromWireName(rawAction)
      : null;
  if (arguments['nodeId'] is! int ||
      arguments['generation'] is! int ||
      action == null ||
      arguments['text'] != null && arguments['text'] is! String) {
    throw const FormatException('invalid semantics action arguments');
  }
  return <String, Object?>{...arguments, 'decodedAction': action};
}

Map<String, Object?> patchbayDecodeUiSemanticsTap(
  Map<String, Object?> arguments,
) {
  patchbayRejectUnexpectedUiKeys(arguments, const <String>{
    'identifier',
    'generation',
  });
  if (arguments['identifier'] is! String ||
      arguments['generation'] != null && arguments['generation'] is! int) {
    throw const FormatException('invalid semantics tap arguments');
  }
  return arguments;
}

Map<String, Object?> patchbayDecodeUiSemanticsIdentifierAction(
  Map<String, Object?> arguments,
) {
  patchbayRejectUnexpectedUiKeys(arguments, const <String>{
    'identifier',
    'generation',
    'action',
    'text',
    'inputWasStdin',
  });
  final Object? rawAction = arguments['action'];
  final PatchbayParameterDescriptor actionParameter =
      patchbayUiSemanticsActionByIdentifierCommandDescriptor.parameters
          .singleWhere(
            (PatchbayParameterDescriptor parameter) =>
                parameter.name == 'action',
          );
  final PatchbaySemanticsAction? action =
      rawAction is String && actionParameter.allowedValues.contains(rawAction)
      ? PatchbaySemanticsAction.fromWireName(rawAction)
      : null;
  if (arguments['identifier'] is! String ||
      arguments['generation'] is! int ||
      action == null ||
      arguments['text'] != null && arguments['text'] is! String ||
      arguments['inputWasStdin'] != null &&
          arguments['inputWasStdin'] is! bool) {
    throw const FormatException(
      'invalid semantics identifier action arguments',
    );
  }
  return <String, Object?>{...arguments, 'decodedAction': action};
}

Map<String, Object?> patchbayDecodeUiGesture(
  Map<String, Object?> arguments,
  PatchbayGestureKind kind,
) {
  // tap 没有 `durationMs`：间隔是 bridge 内部常数，wire 里出现该 key 即按
  // unknown key 拒绝。它的 `start` 也是家族里唯一可缺省的（默认目标中心，
  // 由 descriptor 声明、bridge 落地）。
  final bool isTap = kind == PatchbayGestureKind.tap;
  final Set<String> keys = <String>{
    'identifier',
    'generation',
    'start',
    if (!isTap) 'durationMs',
    if (kind == PatchbayGestureKind.drag) 'path',
    if (kind == PatchbayGestureKind.fling) 'velocity',
  };
  patchbayRejectUnexpectedUiKeys(arguments, keys);
  if (arguments['identifier'] is! String ||
      arguments['generation'] is! int ||
      (isTap
          ? arguments['start'] != null && arguments['start'] is! Map
          : arguments['start'] is! Map) ||
      arguments['durationMs'] != null && arguments['durationMs'] is! int ||
      kind == PatchbayGestureKind.drag && arguments['path'] is! List ||
      kind == PatchbayGestureKind.fling && arguments['velocity'] is! Map) {
    throw const FormatException('invalid anchored gesture arguments');
  }
  return <String, Object?>{
    ...arguments,
    if (arguments['start'] case final Map start)
      'start': start.cast<String, Object?>(),
    if (arguments['path'] case final List<Object?> path) 'path': path,
    if (arguments['velocity'] case final Map velocity)
      'velocity': velocity.cast<String, Object?>(),
  };
}

Map<String, Object?> patchbayDecodeNavigationDestination(
  Map<String, Object?> arguments,
) {
  patchbayRejectUnexpectedUiKeys(arguments, const <String>{
    'destinationId',
    'revision',
    'timeoutMs',
  });
  if (arguments['destinationId'] is! String ||
      arguments['revision'] is! int ||
      arguments['timeoutMs'] != null && arguments['timeoutMs'] is! int) {
    throw const FormatException('invalid navigation arguments');
  }
  return arguments;
}

Map<String, Object?> patchbayDecodeNavigationBack(
  Map<String, Object?> arguments,
) {
  patchbayRejectUnexpectedUiKeys(arguments, const <String>{
    'revision',
    'timeoutMs',
  });
  if (arguments['revision'] is! int ||
      arguments['timeoutMs'] != null && arguments['timeoutMs'] is! int) {
    throw const FormatException('invalid navigation arguments');
  }
  return arguments;
}

Map<String, Object?> patchbayDecodeNoUiArguments(
  Map<String, Object?> arguments,
) {
  patchbayRejectUnexpectedUiKeys(arguments, const <String>{});
  return arguments;
}

void patchbayRejectUnexpectedUiKeys(
  Map<String, Object?> arguments,
  Set<String> keys,
) {
  if (arguments.keys.any((String key) => !keys.contains(key))) {
    throw const FormatException('unexpected argument');
  }
}
