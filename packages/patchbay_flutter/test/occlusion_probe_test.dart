// PB-050-16：gesture 与 semantics 共用的遮挡判定基元。
//
// 端到端的准入行为在 bridge/semantics_occlusion_admission_test.dart 与
// gesture_visibility_spike_test.dart 里断言；本文件只锁基元自己：三态判定的
// 三个分支各一条，以及三条 fail-closed 的 reason。三态里的 noPointerFootprint
// 是本条目相对 gesture 布尔规则新增的一态，没有它，仓内合法的
// `Semantics(onTap:) > SizedBox` 会被判成遮挡。
import 'dart:ui' show SemanticsUpdate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';
import 'package:patchbay_flutter/src/occlusion/occlusion_probe.dart';

import 'fixture/flutter_bridge_fixtures.dart';

void main() {
  group('three-state probe', () {
    testWidgets('a target with its own pointer footprint is reachable', (
      tester,
    ) async {
      await _withGeometry(
        tester,
        Semantics(
          identifier: 'probe.target',
          button: true,
          onTap: () {},
          child: const Listener(
            behavior: HitTestBehavior.opaque,
            child: SizedBox(width: 100, height: 100),
          ),
        ),
        (PatchbayOcclusionGeometry geometry) =>
            expect(geometry.probe(0.5, 0.5), PatchbayOcclusionState.reachable),
      );
    });

    testWidgets('an uncovered target without a pointer footprint reports '
        'noPointerFootprint, not obstruction', (tester) async {
      // 这是仓内合法的无障碍写法，也是既有绿灯用例的形状：Semantics(onTap:)
      // 包一个不参与命中测试的子树。命中链里根本没有目标，但也没有任何外来
      // 层挡在前面——链中最前一条是锚点的祖先。
      await _withGeometry(
        tester,
        Semantics(
          identifier: 'probe.target',
          button: true,
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
        (PatchbayOcclusionGeometry geometry) => expect(
          geometry.probe(0.5, 0.5),
          PatchbayOcclusionState.noPointerFootprint,
        ),
      );
    });

    testWidgets('a foreign opaque layer in front reports obstructed', (
      tester,
    ) async {
      await _withGeometry(
        tester,
        SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Semantics(
                identifier: 'probe.target',
                button: true,
                onTap: () {},
                child: const Listener(
                  behavior: HitTestBehavior.opaque,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
              const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
        (PatchbayOcclusionGeometry geometry) =>
            expect(geometry.probe(0.5, 0.5), PatchbayOcclusionState.obstructed),
      );
    });

    testWidgets('a point outside an ancestor paint clip reports obstructed', (
      tester,
    ) async {
      await _withGeometry(
        tester,
        SizedBox(
          width: 100,
          height: 50,
          child: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                const SizedBox(width: 100, height: 300),
                Semantics(
                  identifier: 'probe.target',
                  button: true,
                  onTap: () {},
                  child: const Listener(
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        (PatchbayOcclusionGeometry geometry) {
          // 目标被滚出了自己的视口：node.rect 非空（所以 isInvisible 为 false，
          // uiSemanticsActionBlocked 不会先接手），但 parentPaintClipRect 与它
          // 完全不相交。Flutter 只在「完全被裁掉」时才保留未裁剪的 rect，因此
          // 这是 clip 分支真正会触发的形状。
          for (final PatchbayOcclusionProbe probe
              in patchbaySemanticsProbeSamples) {
            expect(
              geometry.probe(probe.x, probe.y),
              PatchbayOcclusionState.obstructed,
              reason: 'probe ${probe.x},${probe.y}',
            );
          }
        },
      );
    });
  });

  group('fail-closed resolution reasons', () {
    testWidgets('an owner that belongs to no RenderView is viewUnavailable', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final SemanticsOwner detached = SemanticsOwner(
        onSemanticsUpdate: (SemanticsUpdate _) {},
      );
      addTearDown(detached.dispose);

      final PatchbayOcclusionResolution resolution =
          patchbayResolveOcclusionGeometry(
            owner: detached,
            node: SemanticsNode(),
          );

      expect(resolution.resolved, isFalse);
      expect(resolution.reason, PatchbayOcclusionReason.viewUnavailable);
    });

    testWidgets('a node with no matching RenderObject is '
        'renderAnchorUnavailable', (tester) async {
      await _withHarness(
        tester,
        Semantics(
          identifier: 'probe.target',
          button: true,
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
        (SemanticsOwner owner, SemanticsNode _) {
          final PatchbayOcclusionResolution resolution =
              patchbayResolveOcclusionGeometry(
                owner: owner,
                node: SemanticsNode(),
              );

          expect(resolution.resolved, isFalse);
          expect(
            resolution.reason,
            PatchbayOcclusionReason.renderAnchorUnavailable,
          );
        },
      );
    });

    testWidgets('a target whose global rect degenerates is emptyBounds', (
      tester,
    ) async {
      // node.rect 本身非空（所以节点不是 isInvisible，前面的
      // uiSemanticsActionBlocked 不会先接手），但到根的变换把它压成零面积。
      await _withHarness(
        tester,
        Transform(
          transform: Matrix4.diagonal3Values(0, 1, 1),
          child: Semantics(
            identifier: 'probe.target',
            button: true,
            onTap: () {},
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
        (SemanticsOwner owner, SemanticsNode node) {
          final PatchbayOcclusionResolution resolution =
              patchbayResolveOcclusionGeometry(owner: owner, node: node);

          expect(resolution.resolved, isFalse);
          expect(resolution.reason, PatchbayOcclusionReason.emptyBounds);
        },
      );
    });
  });

  test('the fixed sample set is the frozen five-point set', () {
    expect(
      patchbaySemanticsProbeSamples
          .map((PatchbayOcclusionProbe probe) => '${probe.x},${probe.y}')
          .toList(),
      <String>['0.5,0.5', '0.25,0.25', '0.75,0.25', '0.25,0.75', '0.75,0.75'],
    );
  });
}

Future<void> _withGeometry(
  WidgetTester tester,
  Widget target,
  void Function(PatchbayOcclusionGeometry geometry) body,
) => _withHarness(tester, target, (SemanticsOwner owner, SemanticsNode node) {
  final PatchbayOcclusionResolution resolution =
      patchbayResolveOcclusionGeometry(owner: owner, node: node);
  expect(resolution.resolved, isTrue, reason: 'reason: ${resolution.reason}');
  body(resolution.geometry!);
});

/// 语义句柄必须在测试体内释放：flutter_test 的
/// `_verifySemanticsHandlesWereDisposed` 在 `addTearDown` 之前跑。
Future<void> _withHarness(
  WidgetTester tester,
  Widget target,
  void Function(SemanticsOwner owner, SemanticsNode node) body,
) async {
  final PatchbayFlutterBridge bridge = interactiveBridge(PatchbayUiRegistry());
  addTearDown(bridge.semantics.dispose);
  await tester.pumpWidget(MaterialApp(home: Center(child: target)));
  final SemanticsOwner? owner = await pumpUntilComplete(
    tester,
    bridge.semantics.ensureOwner(),
  );
  final SemanticsNode? node = _find(owner!.rootSemanticsNode!, 'probe.target');
  expect(node, isNotNull, reason: 'probe.target must be in the semantics tree');
  body(owner, node!);
  bridge.semantics.dispose();
}

SemanticsNode? _find(SemanticsNode root, String identifier) {
  if (root.getSemanticsData().identifier == identifier) return root;
  SemanticsNode? found;
  root.visitChildren((SemanticsNode child) {
    found = _find(child, identifier);
    return found == null;
  });
  return found;
}
