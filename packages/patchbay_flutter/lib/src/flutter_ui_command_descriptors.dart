// PB-050-38：UI 命令的**声明阶段**——这个 host 发布哪几条命令、每条长什么样。
//
// 这里只有静态声明加运行期覆写，没有任何 handler、桥或现场状态：descriptor 是目录
// 里那份「调用方读得到的事实」，DG-060-04 冻结的口径是它**只能**声明 `gates`、
// `sideEffect` 与 `interactionModel`，动态 policy 一律不进 wire。
//
// 顺序是契约的一部分，而不是排版：注册表按位置把第 N 个 descriptor 配给第 N 个
// handler（见 `flutter_ui_registration.dart`），所以这张表的次序必须与
// `flutter_ui_command_bindings.dart` 里 bind 的次序逐条对齐。
//
// 本文件不出现在包的 barrel 里，全部符号都是包内实现，不构成公共 API。
import 'package:patchbay/patchbay_protocol.dart';

import 'inspect_bridge.dart';
import 'keep_awake_bridge.dart';

/// 本 host 发布的 UI 命令声明，按注册顺序排列。
///
/// 三个参数是运行期覆写的全部来源：capture 与 keep-awake 的门跟着桥的构造参数走，
/// inspect 的门与租约缺省跟着接入方注入的 policy 走。同一份声明既服务目录，也是
/// 拒绝时「哪个键缺了」的判据来源（见 `flutter_ui_rejection.dart`）。
List<PatchbayCommandDescriptor> patchbayFlutterUiCommandDescriptors({
  required Set<String> captureGates,
  required Set<String> keepAwakeGates,
  required PatchbayInspectPolicy inspectPolicy,
}) => <PatchbayCommandDescriptor>[
  patchbayUiTextSetCommandDescriptor,
  patchbayUiTextEnterCommandDescriptor,
  patchbayUiSemanticsTreeCommandDescriptor,
  patchbayUiSemanticsActionCommandDescriptor,
  patchbayUiSemanticsActionByIdentifierCommandDescriptor,
  patchbayUiSemanticsTapCommandDescriptor,
  patchbayUiGesturePressHoldCommandDescriptor,
  patchbayUiGestureDragCommandDescriptor,
  patchbayUiGestureFlingCommandDescriptor,
  patchbayUiGestureTapCommandDescriptor,
  patchbayUiRevealCommandDescriptor,
  patchbayUiWaitCommandDescriptor,
  patchbayUiKeepAwakeSetCommandDescriptor.withRuntimeOverrides(
    gates: keepAwakeGates,
    parameterDefaults: <String, Object?>{
      'leaseMs': PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
    },
  ),
  patchbayUiKeepAwakeStatusCommandDescriptor,
  patchbayUiCaptureCommandDescriptor.withRuntimeOverrides(gates: captureGates),
  // 共享侧尚未收录 ui.capture.diff（它随 !54 才进 main），先保留内联声明；
  // 与上面的 capture 一样跟随 captureGates，不再单独开关。
  PatchbayCommandDescriptor(
    name: 'ui.capture.diff',
    summary: 'Compare two bounded Flutter capture artifacts pixel by pixel.',
    plane: PatchbayPlane.flutterUi,
    mode: PatchbayCommandMode.readOnly,
    sideEffect: PatchbaySideEffect.none,
    factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
    gates: captureGates,
    parameters: const <PatchbayParameterDescriptor>[
      PatchbayParameterDescriptor(
        name: 'beforeBlobId',
        type: PatchbayParameterType.string,
        required: true,
      ),
      PatchbayParameterDescriptor(
        name: 'afterBlobId',
        type: PatchbayParameterType.string,
        required: true,
      ),
    ],
  ),
  patchbayUiInspectStatusCommandDescriptor,
  patchbayUiInspectSelectCommandDescriptor.withRuntimeOverrides(
    gates: inspectPolicy.gates,
    parameterDefaults: <String, Object?>{
      'ttlMs': inspectPolicy.defaultLease.inMilliseconds,
    },
  ),
  patchbayNavigationCatalogCommandDescriptor,
  patchbayNavigationCurrentCommandDescriptor,
  patchbayNavigationGoCommandDescriptor,
  patchbayNavigationPushCommandDescriptor,
  patchbayNavigationBackCommandDescriptor,
];
