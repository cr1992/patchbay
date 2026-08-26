// PB-050-17：reveal 测试共用的 App 骨架、bridge 构造与断言辅助。
//
// 每个 widget 用例都把目标与容器包在 [ShowOnScreenRecorder] 里：它给节点声明
// `onShowOnScreen`，于是任何一次 `performAction(node, showOnScreen)` 都会被记
// 到计数器上。机制唯一性回归靠它落地（正向对照见 reveal_contract_test.dart，
// 证明这个记录器真的会响，零派发断言因此不是空的）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

const String revealContainerId = 'reveal.list';
const String revealOuterContainerId = 'reveal.outer';
const String revealNestedContainerId = 'reveal.nested';
const String revealTargetId = 'reveal.target';
const double revealRowExtent = 60;
const double revealViewportExtent = 240;

/// 计数器：整条矩阵里它必须恒为 0。
int showOnScreenCalls = 0;

void resetRevealCounters() => showOnScreenCalls = 0;

PatchbayFlutterBridge revealBridge({
  PatchbayRevealPolicy? policy,
  PatchbayGateEvaluator? gates,
  bool Function()? isAppResumed,
}) => PatchbayFlutterBridge(
  registry: PatchbayUiRegistry(),
  gates:
      gates ??
      PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
  // 默认放到 host 硬顶：预算矩阵在 reveal_policy_test.dart 里单独锁，矩阵用例
  // 不该因为默认 policy 比参数严而被 `uiRevealBudgetExceeded` 抢答。
  revealPolicy:
      policy ??
      (_, _) => const PatchbayRevealDecision.allow(
        maxSteps: 200,
        maxDurationMs: 120000,
      ),
  isAppResumed: isAppResumed ?? () => true,
);

PatchbayGateEvaluator allowingGates() => PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

Widget revealApp(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: revealViewportExtent,
        height: revealViewportExtent,
        child: child,
      ),
    ),
  ),
);

/// 一条普通行：有指针占位，因此露出后 `reachability` 是 `pointer`。
Widget revealPointerRow(String identifier) => Semantics(
  identifier: identifier,
  button: true,
  onTap: () {},
  child: const ShowOnScreenRecorder(
    child: Listener(
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(color: Colors.blue),
    ),
  ),
);

/// `Semantics(onTap:) > SizedBox`：合法的无障碍写法，没有指针占位，因此露出后
/// `reachability` 是 `semanticsOnly`。
Widget revealSemanticsOnlyRow(String identifier) => Semantics(
  identifier: identifier,
  button: true,
  onTap: () {},
  child: const ShowOnScreenRecorder(child: SizedBox.expand()),
);

/// 一个 identifier 锚在 `ListView` 外层的滚动容器。
Widget revealList({
  required int itemCount,
  required int targetIndex,
  String containerId = revealContainerId,
  String targetId = revealTargetId,
  bool reverse = false,
  Axis axis = Axis.vertical,
  ScrollPhysics? physics,
  ScrollController? controller,
  bool semanticsOnlyTarget = false,
}) => Semantics(
  identifier: containerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      controller: controller,
      reverse: reverse,
      scrollDirection: axis,
      physics: physics,
      itemExtent: revealRowExtent,
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) => index == targetIndex
          ? (semanticsOnlyTarget
                ? revealSemanticsOnlyRow(targetId)
                : revealPointerRow(targetId))
          : Center(child: Text('row $index')),
    ),
  ),
);

/// 一个 `itemCount` 随滚动增长的懒加载列表。
final class RevealLazyList extends StatefulWidget {
  const RevealLazyList({
    super.key,
    required this.targetIndex,
    this.containerId = revealContainerId,
    this.targetId = revealTargetId,
    this.pageSize = 6,
  });

  final int targetIndex;
  final String containerId;
  final String targetId;
  final int pageSize;

  @override
  State<RevealLazyList> createState() => _RevealLazyListState();
}

final class _RevealLazyListState extends State<RevealLazyList> {
  late int _loaded = widget.pageSize;

  bool _onScroll(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (_loaded <= widget.targetIndex &&
        metrics.pixels >= metrics.maxScrollExtent - 1) {
      // 下一帧再补页，模拟分页数据到达：滚动步之后 maxScrollExtent 才增长。
      scheduleMicrotask(() {
        if (mounted) setState(() => _loaded += widget.pageSize);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: revealList(
          itemCount: _loaded,
          targetIndex: widget.targetIndex,
          containerId: widget.containerId,
          targetId: widget.targetId,
        ),
      );
}

/// 把 `onShowOnScreen` 合进最近的语义边界（目标节点或容器锚点节点）。
///
/// 框架没有任何 widget 设置 `SemanticsConfiguration.onShowOnScreen`，所以这里
/// 自己写一个 render object 把它挂上。`SemanticsOwner.performAction` 会优先走
/// 节点 `_actions` 里的 handler，于是任何一次朝这些节点派发的 `showOnScreen`
/// 都落在计数器上，而不是静悄悄地走框架的 `_showOnScreen` 兜底分支。
///
/// **不**声明 `isSemanticBoundary`：它要合进外层的 `Semantics(identifier:)`
/// 节点，而不是自己另起一个节点——否则那个 identifier 节点上的派发就抓不到。
final class ShowOnScreenRecorder extends SingleChildRenderObjectWidget {
  const ShowOnScreenRecorder({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderShowOnScreenRecorder();
}

final class _RenderShowOnScreenRecorder extends RenderProxyBox {
  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.onShowOnScreen = () => showOnScreenCalls += 1;
  }
}

/// reveal 的一步会请一帧，所以用例的帧预算要比通用 helper 大得多。
Future<T> pumpReveal<T>(
  WidgetTester tester,
  Future<T> pending, {
  int maxFrames = 800,
}) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < maxFrames && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) {
    throw StateError('reveal did not complete in $maxFrames frames');
  }
  return pending;
}

/// 跑完一次 reveal 并释放 `SemanticsHandle`。
///
/// `flutter_test` 在测试体结束时就核对句柄，早于 `addTearDown`，所以句柄必须在
/// 测试体内还回去。仓内既有 semantics 用例是同一个写法。
Future<PatchbayInvocation> runReveal(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
  Future<PatchbayInvocation> pending, {
  bool dispose = true,
}) async {
  final PatchbayInvocation result = await pumpReveal(tester, pending);
  if (dispose) bridge.semantics.dispose();
  return result;
}

Map<String, Object?> revealPayload(PatchbayInvocation result) {
  expect(
    result.admission,
    PatchbayAdmission.accepted,
    reason: 'expected an accepted reveal, got ${result.toJson()}',
  );
  return result.payload;
}

List<Map<String, Object?>> revealContainers(Map<String, Object?> payload) =>
    (payload['containers']! as List<Object?>).cast<Map<String, Object?>>();

/// 三条 payload 不变式，任何一条 reveal 回包都必须满足。
void expectRevealInvariants(Map<String, Object?> payload) {
  final List<Map<String, Object?>> containers = revealContainers(payload);
  final int steps = payload['steps']! as int;

  // 一：元素只在第一次在该容器上派发时追加。
  expect(containers.isEmpty, steps == 0, reason: '$payload');
  for (final Map<String, Object?> container in containers) {
    expect(container['steps'], greaterThanOrEqualTo(1), reason: '$payload');
  }

  // 二：各元素 steps 之和 == 顶层 steps。
  expect(
    containers.fold<int>(
      0,
      (int sum, Map<String, Object?> row) => sum + (row['steps']! as int),
    ),
    steps,
    reason: '$payload',
  );

  // 三：不存在任何单数 container 字段。
  expect(
    payload.keys.where(
      (String key) => key.startsWith('container') && key != 'containers',
    ),
    isEmpty,
    reason: '$payload',
  );

  // 字段表：reachability 只在 revealed 出现，reason 只在 failed 出现。
  if (payload['outcome'] == 'revealed') {
    expect(payload.containsKey('reachability'), isTrue, reason: '$payload');
    expect(payload.containsKey('reason'), isFalse, reason: '$payload');
    expect(payload['nodeId'], isA<int>(), reason: '$payload');
    expect(payload['generation'], isA<int>(), reason: '$payload');
  } else {
    expect(payload['outcome'], 'failed', reason: '$payload');
    expect(payload.containsKey('reachability'), isFalse, reason: '$payload');
    expect(payload['reason'], isA<String>(), reason: '$payload');
    expect(containers, isNotEmpty, reason: '$payload');
  }
  expect(payload['source'], 'uiObserved', reason: '$payload');
  expect(payload['beforeTreeRevision'], isA<int>(), reason: '$payload');
  expect(payload['afterTreeRevision'], isA<int>(), reason: '$payload');
  expect(showOnScreenCalls, 0, reason: 'reveal must never send showOnScreen');
}
