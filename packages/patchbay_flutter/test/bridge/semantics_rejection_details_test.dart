/// nodeId 路径与 identifier 路径的拒绝 details 对齐。
///
/// 按 nodeId 派发被拒时，调用方应当拿到和按 identifier 派发同一份候选事实，
/// 而不是一枚裸码；声明了 enabled 状态的节点另带 `enabled`，禁用按钮不再只能
/// 靠截图判断。没有 enabled 状态的节点不带这个键，不替 Flutter 编造事实。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  group('nodeId path carries the same candidate details', () {
    testWidgets('a disabled button reports enabled: false and no tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextButton(onPressed: null, child: const Text('Connect')),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> node = semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> n) => n['label'] == 'Connect');

      final PatchbayInvocation result = await semanticsInvoke(
        tester,
        bridge,
        node: node,
        action: PatchbaySemanticsAction.tap,
      );

      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      final Map<String, Object?> details = result.rejection!.details;
      expect(details['nodeId'], node['nodeId']);
      expect(details['generation'], node['generation']);
      expect(details['requestedAction'], 'tap');
      expect(details['enabled'], isFalse);
      expect(details['label'], 'Connect');
      expect(details['actions'], isNot(contains('tap')));
      expect(details['invisible'], isFalse);
      expect(details['userActionsBlocked'], isFalse);
      bridge.semantics.dispose();
    });

    testWidgets('a node without an enabled state does not carry the key', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            label: 'Plain label',
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> node = semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> n) => n['label'] == 'Plain label');

      final PatchbayInvocation result = await semanticsInvoke(
        tester,
        bridge,
        node: node,
        action: PatchbaySemanticsAction.tap,
      );

      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      final Map<String, Object?> details = result.rejection!.details;
      expect(details['requestedAction'], 'tap');
      expect(details.containsKey('enabled'), isFalse);
      expect(details['nodeId'], node['nodeId']);
      bridge.semantics.dispose();
    });

    testWidgets('a blocked node names itself instead of a bare code', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            blockUserActions: true,
            child: Semantics(
              identifier: 'blocked.button',
              button: true,
              label: 'Blocked',
              onTap: () => taps += 1,
              child: const SizedBox(width: 20, height: 20),
            ),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> node = semanticsNodes(tree).singleWhere(
        (Map<String, Object?> n) => n['identifier'] == 'blocked.button',
      );

      final PatchbayInvocation result = await semanticsInvoke(
        tester,
        bridge,
        node: node,
        action: PatchbaySemanticsAction.tap,
      );

      expect(result.rejection?.code, 'uiSemanticsActionBlocked');
      final Map<String, Object?> details = result.rejection!.details;
      expect(details['nodeId'], node['nodeId']);
      expect(details['generation'], node['generation']);
      expect(details['userActionsBlocked'], isTrue);
      expect(details['label'], 'Blocked');
      expect(taps, 0);
      bridge.semantics.dispose();
    });

    testWidgets('a stale generation names the node and both generations', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TextButton(
            onPressed: () => taps += 1,
            child: const Text('Settings'),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);
      final PatchbayInvocation tree = await semanticsSnapshot(tester, bridge);
      final Map<String, Object?> node = semanticsNodes(
        tree,
      ).singleWhere((Map<String, Object?> n) => n['label'] == 'Settings');
      final int observed = node['generation']! as int;

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.invoke(
          nodeId: node['nodeId']! as int,
          generation: observed + 1,
          action: PatchbaySemanticsAction.tap,
        ),
      );

      expect(result.rejection?.code, 'uiSemanticsGenerationStale');
      expect(result.rejection?.details, <String, Object?>{
        'nodeId': node['nodeId'],
        'expectedGeneration': observed + 1,
        'currentGeneration': observed,
      });
      expect(taps, 0);
      bridge.semantics.dispose();
    });
  });

  group('identifier path carries the same enabled fact', () {
    testWidgets('a disabled identifier target reports enabled: false', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'form.connect',
            button: true,
            enabled: false,
            label: 'Connect',
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'form.connect'),
      );

      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      final Map<String, Object?> details = result.rejection!.details;
      expect(details['requestedAction'], 'tap');
      expect(details['enabled'], isFalse);
      expect(details['actions'], isNot(contains('tap')));
      bridge.semantics.dispose();
    });

    testWidgets('an enabled identifier target without tap reports true', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            identifier: 'form.field',
            enabled: true,
            label: 'Field',
            child: const SizedBox(width: 20, height: 20),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = interactiveBridge(
        PatchbayUiRegistry(),
      );
      addTearDown(bridge.semantics.dispose);

      final PatchbayInvocation result = await pumpUntilComplete(
        tester,
        bridge.semantics.tapIdentifier(identifier: 'form.field'),
      );

      expect(result.rejection?.code, 'uiSemanticsActionUnavailable');
      expect(result.rejection?.details['enabled'], isTrue);
      bridge.semantics.dispose();
    });
  });
}
