// PB-050-38：命令族到桥的**派发胶水**——每条 UI 命令交给哪座桥的哪个方法。
//
// 一个族一个函数，每个函数只认两样东西：一个 [PatchbayUiRegistrationBuilder] 和
// 那座桥。这样每族都能脱离 host 单独装配，也能单独注入失败（给一座会抛的桥、
// 或者给一个 descriptor 数量不对的 builder）。
//
// **调用顺序是契约**：builder 按位置发 descriptor，所以
// [patchbayFlutterUiCommandRegistry] 里这几个 bind 函数的次序必须与
// `flutter_ui_command_descriptors.dart` 那张表逐条对齐，函数内部的 bind 次序同理。
//
// handler 里那几个 `?? 常数` 是 wire 缺省的落地点，与 descriptor 声明的 `default`
// 是同一个数：目录说 40，handler 就必须写 40，否则调用方读到的声明与实际行为不符。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

import 'flutter_bridge.dart';
import 'flutter_ui_argument_decoders.dart';
import 'flutter_ui_command_descriptors.dart';
import 'flutter_ui_registration.dart';
import 'inspect_bridge.dart';
import 'reveal_bridge.dart';
import 'semantics_bridge.dart';

/// 本 host 的整张 UI 命令注册表，按 descriptor 表的次序装配。
PatchbayCommandRegistry patchbayFlutterUiCommandRegistry(
  PatchbayFlutterBridge bridge,
) {
  final PatchbayUiRegistrationBuilder builder = PatchbayUiRegistrationBuilder(
    patchbayFlutterUiCommandDescriptors(
      captureGates: bridge.capture?.gateIds ?? const <String>{},
      keepAwakeGates: bridge.keepAwake.gateIds,
      inspectPolicy: bridge.inspect?.policy ?? const PatchbayInspectPolicy(),
    ),
  );
  patchbayBindUiTextCommands(builder, bridge);
  patchbayBindUiSemanticsCommands(builder, bridge);
  patchbayBindUiGestureCommands(builder, bridge);
  patchbayBindUiRevealAndWaitCommands(builder, bridge);
  patchbayBindUiKeepAwakeCommands(builder, bridge);
  patchbayBindUiCaptureCommands(builder, bridge);
  patchbayBindUiInspectCommands(builder, bridge);
  patchbayBindNavigationCommands(builder, bridge);
  return builder.seal();
}

/// `ui.text.set` / `ui.text.enter`。
///
/// 这两条不收严格键：`inputWasStdin` 之外的多余键交给桥自己的目标解析去说，
/// 拒绝里带 notice 而不带 unexpected。
void patchbayBindUiTextCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiText,
    (request, requestId) async => (await bridge.setText(
      id: request['id']! as String,
      generation: request['generation']! as int,
      text: request['text']! as String,
      inputWasStdin: request['inputWasStdin'] == true,
      requestId: requestId,
    )).toJson(),
    notice: 'id, generation and text are required.',
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiText,
    (request, requestId) async => (await bridge.enterText(
      id: request['id']! as String,
      generation: request['generation']! as int,
      text: request['text']! as String,
      inputWasStdin: request['inputWasStdin'] == true,
      requestId: requestId,
    )).toJson(),
    notice: 'id, generation and text are required.',
  );
}

/// `ui.semantics.tree` 与三条 action。
///
/// tree 总是可用（它是观察），三条 action 一起跟 `actionsEnabled`：没写下动作
/// policy 的 App 连目录里都看不到它们。
void patchbayBindUiSemanticsCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiSemanticsTree,
    (request, requestId) async => (await bridge.semantics.snapshot(
      maxDepth: request['maxDepth'] as int? ?? 64,
      maxNodes: request['maxNodes'] as int? ?? 1000,
      requestId: requestId,
    )).toJson(),
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiSemanticsAction,
    (request, requestId) async => (await bridge.semantics.invoke(
      nodeId: request['nodeId']! as int,
      generation: request['generation']! as int,
      action: request['decodedAction']! as PatchbaySemanticsAction,
      text: request['text'] as String?,
      inputWasStdin: request['inputWasStdin'] == true,
      requestId: requestId,
    )).toJson(),
    available: bridge.semantics.actionsEnabled,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiSemanticsIdentifierAction,
    (request, requestId) async => (await bridge.semantics.invokeIdentifier(
      identifier: request['identifier']! as String,
      generation: request['generation']! as int,
      action: request['decodedAction']! as PatchbaySemanticsAction,
      text: request['text'] as String?,
      inputWasStdin: request['inputWasStdin'] == true,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    available: bridge.semantics.actionsEnabled,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeUiSemanticsTap,
    (request, requestId) async => (await bridge.semantics.tapIdentifier(
      identifier: request['identifier']! as String,
      expectedGeneration: request['generation'] as int?,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    available: bridge.semantics.actionsEnabled,
  );
}

/// 指针通道上的四条手势。
///
/// 四条共用一个解码器，只靠 [PatchbayGestureKind] 分叉；`durationMs` 的缺省逐条
/// 不同（500 / 300 / 100），tap 没有这个参数——它的间隔是桥内部常数。
void patchbayBindUiGestureCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<Map<String, Object?>>(
    (arguments) =>
        patchbayDecodeUiGesture(arguments, PatchbayGestureKind.pressHold),
    (request, requestId) async => (await bridge.gesture.pressHold(
      identifier: request['identifier']! as String,
      generation: request['generation']! as int,
      start: request['start']! as Map<String, Object?>,
      durationMs: request['durationMs'] as int? ?? 500,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.gesture.enabled,
  );
  builder.bind<Map<String, Object?>>(
    (arguments) => patchbayDecodeUiGesture(arguments, PatchbayGestureKind.drag),
    (request, requestId) async => (await bridge.gesture.drag(
      identifier: request['identifier']! as String,
      generation: request['generation']! as int,
      start: request['start']! as Map<String, Object?>,
      path: request['path']! as List<Object?>,
      durationMs: request['durationMs'] as int? ?? 300,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.gesture.enabled,
  );
  builder.bind<Map<String, Object?>>(
    (arguments) =>
        patchbayDecodeUiGesture(arguments, PatchbayGestureKind.fling),
    (request, requestId) async => (await bridge.gesture.fling(
      identifier: request['identifier']! as String,
      generation: request['generation']! as int,
      start: request['start']! as Map<String, Object?>,
      velocity: request['velocity']! as Map<String, Object?>,
      durationMs: request['durationMs'] as int? ?? 100,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.gesture.enabled,
  );
  builder.bind<Map<String, Object?>>(
    (arguments) => patchbayDecodeUiGesture(arguments, PatchbayGestureKind.tap),
    (request, requestId) async => (await bridge.gesture.tap(
      identifier: request['identifier']! as String,
      generation: request['generation']! as int,
      start: request['start'] as Map<String, Object?>?,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.gesture.enabled,
  );
}

/// `ui.reveal` 与 `ui.wait`。
///
/// 两条都是「等到某个条件成立」的有界操作，缺省值（reveal 的 40 步 / 5s，wait 的
/// 超时）都在这里落地。reveal 跟 `enabled`——没注入 revealPolicy 就不发布。
void patchbayBindUiRevealAndWaitCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<PatchbayRevealRequestWire>(
    PatchbayRevealRequestWire.fromJson,
    (request, requestId) async => (await bridge.reveal.reveal(
      identifier: request.identifier,
      container: request.container,
      direction: request.direction == null
          ? PatchbayRevealDirection.both
          : PatchbayRevealDirection.fromWire(request.direction!),
      maxSteps: request.maxSteps ?? 40,
      timeoutMs: request.timeoutMs ?? 5000,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.reveal.enabled,
  );
  builder.bind<PatchbayUiWaitRequest>(
    (arguments) => PatchbayUiWaitRequest.fromWire(
      PatchbayUiWaitRequestWire.fromJson(arguments),
    ),
    (request, requestId) async =>
        (await bridge.wait.wait(request, requestId: requestId)).toJson(),
    strictKeys: true,
    includeReason: true,
  );
}

/// `ui.keepAwake.set` / `.status`。
///
/// 两条总是注册，哪怕接入方没接 delegate：keep-awake 正是操作员在 UI 面不再应答时
/// 才会伸手去够的能力，所以它答 `wired: false` 作诊断，而不是从目录里消失。
void patchbayBindUiKeepAwakeCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<PatchbayKeepAwakeRequestWire>(
    PatchbayKeepAwakeRequestWire.fromJson,
    (request, requestId) async =>
        (await bridge.keepAwake.set(request, requestId: requestId)).toJson(),
    strictKeys: true,
    includeReason: true,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNoUiArguments,
    (_, requestId) async =>
        (await bridge.keepAwake.status(requestId: requestId)).toJson(),
    strictKeys: true,
  );
}

/// `ui.capture` 与 `ui.capture.diff`，两条都跟着 artifacts 是否接线。
void patchbayBindUiCaptureCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<PatchbayCaptureRequestWire>(
    PatchbayCaptureRequestWire.fromJson,
    (request, requestId) async =>
        (await bridge.capture!.capture(request, requestId: requestId)).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.capture != null,
  );
  builder.bind<PatchbayCaptureDiffRequestWire>(
    PatchbayCaptureDiffRequestWire.fromJson,
    (request, requestId) async =>
        (await bridge.capture!.diff(request, requestId: requestId)).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.capture != null,
  );
}

/// `ui.inspect.status` / `.select`，跟着接入方是否注入 inspect policy。
void patchbayBindUiInspectCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNoUiArguments,
    (_, requestId) async =>
        (await bridge.inspect!.status(requestId: requestId)).toJson(),
    strictKeys: true,
    available: bridge.inspect != null,
  );
  builder.bind<PatchbayInspectSelectRequestWire>(
    PatchbayInspectSelectRequestWire.fromJson,
    (request, requestId) async => (await bridge.inspect!.select(
      request: request,
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    includeReason: true,
    available: bridge.inspect != null,
  );
}

/// 五条 navigation，全部跟着接入方是否注入 adapter。
void patchbayBindNavigationCommands(
  PatchbayUiRegistrationBuilder builder,
  PatchbayFlutterBridge bridge,
) {
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNoUiArguments,
    (_, requestId) async =>
        (await bridge.navigation!.catalog(requestId: requestId)).toJson(),
    strictKeys: true,
    available: bridge.navigation != null,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNoUiArguments,
    (_, requestId) async =>
        (await bridge.navigation!.current(requestId: requestId)).toJson(),
    strictKeys: true,
    available: bridge.navigation != null,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNavigationDestination,
    (request, requestId) async => (await bridge.navigation!.go(
      destinationId: request['destinationId']! as String,
      revision: request['revision']! as int,
      timeout: Duration(milliseconds: request['timeoutMs'] as int? ?? 5000),
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    available: bridge.navigation != null,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNavigationDestination,
    (request, requestId) async => (await bridge.navigation!.push(
      destinationId: request['destinationId']! as String,
      revision: request['revision']! as int,
      timeout: Duration(milliseconds: request['timeoutMs'] as int? ?? 5000),
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    available: bridge.navigation != null,
  );
  builder.bind<Map<String, Object?>>(
    patchbayDecodeNavigationBack,
    (request, requestId) async => (await bridge.navigation!.back(
      revision: request['revision']! as int,
      timeout: Duration(milliseconds: request['timeoutMs'] as int? ?? 5000),
      requestId: requestId,
    )).toJson(),
    strictKeys: true,
    available: bridge.navigation != null,
  );
}
