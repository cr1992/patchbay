// PB-050-17 / DG-050-10：`ui.reveal` 的 VM Service / direct 对拍。
//
// 复用仓内既定基建（同 gesture_bridge_test.dart「VM extension and direct seam
// use the same gesture dispatcher」、capture_test.dart 的 `_call` 辅助）：
// 用 `registrar` 截获 VM 侧的 `ServiceExtensionHandler`，与
// `PatchbayFlutterServiceHost.dispatchInvoke` 的 direct 结果比较解码后的 JSON。
//
// reveal 会真的滚动 UI、真的耗时，因此矩阵里的每一格都让两条传输各自跑在一棵
// **独立**的、刚挂载的场景树上（而不是对同一棵树连续调两次，那样第二次会从
// 第一次滚完的位置起步，两侧不再可比）。`elapsedMs` 是唯一允许不同的字段——
// 它就是一次真实调用的墙钟耗时，两次调用不可能相等；其余字段逐一断言相等。
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'reveal_fixtures.dart';

void main() {
  setUp(resetRevealCounters);

  group('VM / direct 对拍', () {
    test('准入前拒绝（invalidUiArguments）：两侧逐字节一致', () async {
      // 参数校验在 reveal() 里发生在任何语义树访问之前：这一格不需要挂载任何
      // widget，纯粹验证两条传输对同一次非法调用给出同一份 rejection JSON。
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      final PatchbayFlutterBridge bridge = revealBridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.reveal-parity',
        bridge: bridge,
        registrar: (String method, ServiceExtensionHandler handler) =>
            handlers[method] = handler,
      )..register();
      const Map<String, Object?> arguments = <String, Object?>{
        'identifier': '',
        'timeoutMs': 5000,
      };

      final Map<String, Object?> direct = await host.dispatchInvoke(
        'ui.reveal',
        arguments,
        'reveal-parity-invalid',
      );
      final Map<String, Object?> vm = await _call(
        handlers,
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': 'ui.reveal',
          'requestId': 'reveal-parity-invalid',
          'args': jsonEncode(arguments),
        },
      );

      expect(vm, direct);
      expect(
        (direct['rejection']! as Map<String, Object?>)['code'],
        'invalidUiArguments',
      );
    });

    testWidgets('已经露出（steps 0）：两侧逐字节一致（elapsedMs 除外）', (
      WidgetTester tester,
    ) async {
      const Map<String, Object?> arguments = <String, Object?>{
        'identifier': revealTargetId,
        'timeoutMs': 60000,
      };
      Widget scene() => revealApp(revealList(itemCount: 40, targetIndex: 0));

      final Map<String, Object?> direct = await _runOnFreshTree(
        tester,
        scene: scene,
        invoke:
            (
              PatchbayFlutterBridge bridge,
              PatchbayFlutterServiceHost host,
              Map<String, ServiceExtensionHandler> handlers,
            ) => host.dispatchInvoke(
              'ui.reveal',
              arguments,
              'reveal-parity-direct',
            ),
      );
      final Map<String, Object?> vm = await _runOnFreshTree(
        tester,
        scene: scene,
        invoke:
            (
              PatchbayFlutterBridge bridge,
              PatchbayFlutterServiceHost host,
              Map<String, ServiceExtensionHandler> handlers,
            ) => _call(
              handlers,
              PatchbayServiceHost.invokeMethod,
              <String, String>{
                'command': 'ui.reveal',
                'requestId': 'reveal-parity-vm',
                'args': jsonEncode(arguments),
              },
            ),
      );

      final Map<String, Object?> directPayload =
          direct['payload']! as Map<String, Object?>;
      final Map<String, Object?> vmPayload =
          vm['payload']! as Map<String, Object?>;
      expect(directPayload['outcome'], 'revealed');
      expect(directPayload['steps'], 0);
      expect(
        _withoutElapsed(vmPayload),
        _withoutElapsed(directPayload),
        reason: 'direct=$direct vm=$vm',
      );
      expect(vm['requestId'], 'reveal-parity-vm');
      expect(direct['requestId'], 'reveal-parity-direct');
    });

    testWidgets('受理后失败（stepBudgetExceeded，containers 非空）：两侧逐字节'
        '一致（elapsedMs 除外）', (WidgetTester tester) async {
      const Map<String, Object?> arguments = <String, Object?>{
        'identifier': revealTargetId,
        'direction': 'forward',
        'maxSteps': 1,
        'timeoutMs': 60000,
      };
      Widget scene() => revealApp(revealList(itemCount: 400, targetIndex: 380));

      final Map<String, Object?> direct = await _runOnFreshTree(
        tester,
        scene: scene,
        invoke:
            (
              PatchbayFlutterBridge bridge,
              PatchbayFlutterServiceHost host,
              Map<String, ServiceExtensionHandler> handlers,
            ) => host.dispatchInvoke(
              'ui.reveal',
              arguments,
              'reveal-parity-direct-2',
            ),
      );
      final Map<String, Object?> vm = await _runOnFreshTree(
        tester,
        scene: scene,
        invoke:
            (
              PatchbayFlutterBridge bridge,
              PatchbayFlutterServiceHost host,
              Map<String, ServiceExtensionHandler> handlers,
            ) => _call(
              handlers,
              PatchbayServiceHost.invokeMethod,
              <String, String>{
                'command': 'ui.reveal',
                'requestId': 'reveal-parity-vm-2',
                'args': jsonEncode(arguments),
              },
            ),
      );

      final Map<String, Object?> directPayload =
          direct['payload']! as Map<String, Object?>;
      final Map<String, Object?> vmPayload =
          vm['payload']! as Map<String, Object?>;
      expect(directPayload['outcome'], 'failed');
      expect(directPayload['reason'], 'stepBudgetExceeded');
      expect(directPayload['steps'], 1);
      expect(
        _withoutElapsed(vmPayload),
        _withoutElapsed(directPayload),
        reason: 'direct=$direct vm=$vm',
      );
    });
  });
}

/// 每次调用都跑在**自己的** bridge 与刚挂载的场景树上：`beforeTreeRevision`
/// / `afterTreeRevision` 是 bridge 生命周期内的累计计数，同一个 bridge 连续
/// 调两次天然不可比；nodeId / generation 则是 Flutter 按同一序列重新挂载时
/// 复用出来的，一棵结构相同的新树配一个全新 bridge 会独立收敛到同一个值。
Future<Map<String, Object?>> _runOnFreshTree(
  WidgetTester tester, {
  required Widget Function() scene,
  required Future<Map<String, Object?>> Function(
    PatchbayFlutterBridge bridge,
    PatchbayFlutterServiceHost host,
    Map<String, ServiceExtensionHandler> handlers,
  )
  invoke,
}) async {
  final Map<String, ServiceExtensionHandler> handlers =
      <String, ServiceExtensionHandler>{};
  final PatchbayFlutterBridge bridge = revealBridge();
  final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
    applicationId: 'dev.patchbay.reveal-parity',
    bridge: bridge,
    registrar: (String method, ServiceExtensionHandler handler) =>
        handlers[method] = handler,
  )..register();
  await tester.pumpWidget(scene());
  final Map<String, Object?> result = await pumpReveal(
    tester,
    invoke(bridge, host, handlers),
  );
  bridge.semantics.dispose();
  return result;
}

/// `elapsedMs` 是一次真实调用的墙钟耗时：两次独立调用不可能相等，因此这是
/// 矩阵里唯一允许在比较前被剥掉的字段。
Map<String, Object?> _withoutElapsed(Map<String, Object?> payload) =>
    Map<String, Object?>.from(payload)..remove('elapsedMs');

Future<Map<String, Object?>> _call(
  Map<String, ServiceExtensionHandler> handlers,
  String method, [
  Map<String, String> parameters = const <String, String>{},
]) async {
  final ServiceExtensionResponse response = await handlers[method]!(
    method,
    parameters,
  );
  return Map<String, Object?>.from(
    jsonDecode(response.result!) as Map<String, dynamic>,
  );
}
