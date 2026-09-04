// PB-050-38：reveal 引擎表征与阶段单测共用的固定装置。
//
// 与 `reveal_fixtures.dart` 的分工：那份是 0.5.0 起就有的 reveal 通用骨架
// （真实 `ListView`、`ShowOnScreenRecorder`、payload 不变式）；本文件只补拆分
// 需要的两样东西——**逐字节 payload 钉子**与**完全同步的假滚动容器**。
//
// 假滚动容器是表征能够写成确定整数的前提：真实 `Scrollable` 的语义滚动走
// `position.moveTo(..., duration)`，一次派发要跨若干帧做动画，步数、帧数与
// 「门放行到派发之间让出几轮微任务」都会被动画时序污染。手写
// `SemanticsConfiguration` 的容器则是同步的：`performAction` 当场调回调、当场
// 改 `scrollPosition`，因此每一条计数都可复现。手法与 `reveal_race_test.dart`
// 的 `_RawScrollSemantics` 同源，但那份是该文件的私有实现，跨文件用不了。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import 'reveal_fixtures.dart';

// --------------------------------------------------------------- payload 钉子

/// 会随环境变化的字段：值换成占位符，**键与出现顺序原样保留**。
const Set<String> revealVolatileKeys = <String>{
  'nodeId',
  'generation',
  'elapsedMs',
  'beforeTreeRevision',
  'afterTreeRevision',
};

/// 把一次 reveal 回包压成一行 JSON，用于逐字节比对。
///
/// `jsonEncode` 会按 map 的插入顺序输出，因此这条断言同时钉住**键序**——
/// 拆分若改动了 payload 组装顺序，字符串就不再相等。[volatile] 里的键只把值
/// 换成占位符：`nodeId` / `generation` 依赖真实语义树，`elapsedMs` 与两个
/// tree revision 依赖墙钟与帧数，它们的**存在与位置**才是契约。
String pinnedRevealPayload(
  Map<String, Object?> payload, {
  Set<String> volatile = revealVolatileKeys,
}) => jsonEncode(_pinnedMap(payload, volatile));

Map<String, Object?> _pinnedMap(
  Map<String, Object?> source,
  Set<String> volatile,
) {
  final Map<String, Object?> pinned = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in source.entries) {
    pinned[entry.key] = switch (entry.value) {
      _ when volatile.contains(entry.key) => '<volatile>',
      final List<Object?> list => <Object?>[
        for (final Object? element in list)
          element is Map<String, Object?>
              ? _pinnedMap(element, volatile)
              : element,
      ],
      final Map<String, Object?> map => _pinnedMap(map, volatile),
      final Object? value => value,
    };
  }
  return pinned;
}

// ------------------------------------------------------------ 记账用的门/策略

/// 记下 policy 与门各被问了几次，以及每次 policy 看到的容器 identifier。
///
/// 「每一步重新取得现场并重评动态 policy/gate」是 DG-060-04 冻结的口径，
/// 调用次数因此是外部可观测语义的一部分，不是实现细节。
final class RevealCallLog {
  final List<String> policyContainers = <String>[];
  int get policyCalls => policyContainers.length;
  int gateCalls = 0;

  void reset() {
    policyContainers.clear();
    gateCalls = 0;
  }
}

/// 逐容器授权：`byContainer` 命中就用该决定，否则用 [fallback]。
PatchbayRevealPolicy revealRecordingPolicy(
  RevealCallLog log, {
  Map<String, PatchbayRevealDecision> byContainer =
      const <String, PatchbayRevealDecision>{},
  PatchbayRevealDecision fallback = const PatchbayRevealDecision.allow(
    maxSteps: 200,
    maxDurationMs: 120000,
  ),
  PatchbayRevealDecision? Function(int call)? override,
}) => (PatchbaySemanticsTarget container, PatchbayRevealDirection direction) {
  log.policyContainers.add(container.identifier);
  final PatchbayRevealDecision? forced = override?.call(log.policyCalls);
  if (forced != null) return forced;
  return byContainer[container.identifier] ?? fallback;
};

/// 记次数的放行门；[decide] 非空时由它决定第 n 次调用的结果。
PatchbayGateEvaluator revealRecordingGates(
  RevealCallLog log, {
  FutureOr<PatchbayGateDecision> Function(int call)? decide,
}) => PatchbayGateEvaluator(
  baseGate: () {
    log.gateCalls += 1;
    return decide?.call(log.gateCalls) ?? const PatchbayGateDecision.allow();
  },
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

/// 一次 reveal 调用连同它的可观测记账。
final class RevealRun {
  const RevealRun({
    required this.result,
    required this.frames,
    required this.log,
  });

  final PatchbayInvocation result;

  /// 引擎自己观察到的帧数（`PatchbayFrameObserver.revision` 增量）。
  final int frames;
  final RevealCallLog log;

  /// 逐字节 payload；仅在受理时可用。
  String get pinned => pinnedRevealPayload(revealPayload(result));
}

/// 注入记账 policy / 门的 bridge。
PatchbayFlutterBridge revealRecordingBridge(
  RevealCallLog log, {
  Map<String, PatchbayRevealDecision> byContainer =
      const <String, PatchbayRevealDecision>{},
  PatchbayRevealDecision? Function(int call)? override,
  FutureOr<PatchbayGateDecision> Function(int call)? decide,
  bool Function()? isAppResumed,
}) => PatchbayFlutterBridge(
  registry: PatchbayUiRegistry(),
  gates: revealRecordingGates(log, decide: decide),
  revealPolicy: revealRecordingPolicy(
    log,
    byContainer: byContainer,
    override: override,
  ),
  isAppResumed: isAppResumed ?? () => true,
);

// -------------------------------------------------------------- 同步假滚动容器

/// 上下两半各放一个自带语义边界的子树。
///
/// 假容器里不能用 `Column` + `Expanded`：flex 子节点不会形成独立的
/// `SemanticsNode`，两个实例会退化成零个。`Stack` + `Positioned` 则如实产出两
/// 个兄弟节点。
Widget revealStackedRows(List<Widget> rows) => Stack(
  children: <Widget>[
    for (final (int index, Widget row) in rows.indexed)
      Positioned(
        top: index * (revealViewportExtent / rows.length),
        left: 0,
        width: revealViewportExtent,
        height: revealViewportExtent / rows.length,
        child: row,
      ),
  ],
);

/// 自带语义边界的目标行。
///
/// `reveal_fixtures.dart` 的 [revealPointerRow] 不声明 `container: true`：在真实
/// `ListView` 里每个 item 本来就有自己的节点，用不着。假容器里没有这层结构，
/// 不显式声明就会并进容器节点——那样「目标」与「容器」会是同一个 nodeId，
/// 两个挂载实例也会并成一个，`targetAmbiguous` 因此不可达。
Widget revealBoundaryRow(String identifier, {bool blocked = false}) =>
    Semantics(
      identifier: identifier,
      container: true,
      button: true,
      blockUserActions: blocked,
      onTap: () {},
      child: const ShowOnScreenRecorder(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

/// 一次同步派发的记录。
final class RevealSyntheticLog {
  int dispatches = 0;
  double position = 0;
}

/// 完全同步的假滚动容器。
///
/// `onScrollDown` 在 `SemanticsOwner.performAction` 里当场执行：计数 +1、
/// `scrollPosition` 当场前进一格，因此**不需要动画帧**就能观察到「派发发生
/// 了」。目标在 [revealAtDispatch] 次派发之后挂载并铺满容器，于是「单步成功」
/// 是一个确定的整数而不是一段动画。
///
/// [throwFromDispatch] 让第 n 次及之后的派发抛出 `StateError`，用于把
/// `scrollActionFailed` 钉在确定的步数上。[stall] 让位置不再前进，用于把
/// `scrollExhausted` 钉在 `PatchbayRevealBudget.stallSteps` 上。
final class RevealSyntheticScroll extends StatefulWidget {
  const RevealSyntheticScroll({
    super.key,
    required this.log,
    this.containerId = revealContainerId,
    this.targetId = revealTargetId,
    this.revealAtDispatch,
    this.throwFromDispatch,
    this.blockedAtDispatch,
    this.ambiguousAtDispatch,
    this.disappearAtDispatch,
    this.overlay = false,
    this.stall = false,
    this.step = revealRowExtent,
    this.maxExtent = revealRowExtent * 40,
  });

  final RevealSyntheticLog log;
  final String containerId;
  final String targetId;
  final int? revealAtDispatch;
  final int? throwFromDispatch;

  /// 目标挂载时带 `blockUserActions`：滚动穿不透，钉 `targetBlocked`。
  final int? blockedAtDispatch;

  /// 同一 identifier 同时挂两份：钉 `targetAmbiguous`。
  final int? ambiguousAtDispatch;

  /// 滚动语义节点整个消失：按 pin 重解析落空，钉 `containerChanged`。
  final int? disappearAtDispatch;

  /// 铺满容器的不透明覆盖层：目标挂载且几何上曝光却被盖住，钉 `targetObscured`。
  final bool overlay;
  final bool stall;
  final double step;
  final double maxExtent;

  @override
  State<RevealSyntheticScroll> createState() => _RevealSyntheticScrollState();
}

class _RevealSyntheticScrollState extends State<RevealSyntheticScroll> {
  void _onScrollDown() {
    widget.log.dispatches += 1;
    final int? throwFrom = widget.throwFromDispatch;
    if (throwFrom != null && widget.log.dispatches >= throwFrom) {
      throw StateError(
        'reveal_engine_fixtures: injected performAction failure',
      );
    }
    // 恒定 setState：目标的挂载条件也依赖派发次数，停滞场景同样要重建。
    setState(() {
      if (widget.stall) return;
      widget.log.position = (widget.log.position + widget.step).clamp(
        0,
        widget.maxExtent,
      );
    });
  }

  bool _reached(int? at) => at != null && widget.log.dispatches >= at;

  Widget _content() {
    if (_reached(widget.blockedAtDispatch)) {
      return revealBoundaryRow(widget.targetId, blocked: true);
    }
    if (_reached(widget.ambiguousAtDispatch)) {
      // `Stack` + `Positioned` 而不是 `Column` + `Expanded`：后者在假容器里
      // 产不出子语义节点（flex 子节点会并进父节点），两个实例就会退化成一个。
      return revealStackedRows(<Widget>[
        revealBoundaryRow(widget.targetId),
        revealBoundaryRow(widget.targetId),
      ]);
    }
    if (_reached(widget.revealAtDispatch)) {
      return revealBoundaryRow(widget.targetId);
    }
    return const SizedBox.expand();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = _content();
    // 容器整个消失：锚点还在，锚点子树里已经没有滚动语义节点了。
    final Widget body = _reached(widget.disappearAtDispatch)
        ? content
        : RevealRawScrollSemantics(
            position: widget.log.position,
            max: widget.maxExtent,
            onScrollDown: _onScrollDown,
            child: content,
          );
    return Semantics(
      identifier: widget.containerId,
      container: true,
      child: widget.overlay
          ? Stack(
              fit: StackFit.expand,
              children: <Widget>[
                body,
                const Listener(
                  behavior: HitTestBehavior.opaque,
                  child: ColoredBox(color: Colors.black),
                ),
              ],
            )
          : body,
    );
  }
}

/// 手写滚动语义节点：`Semantics` widget 不暴露 `scrollPosition` /
/// `scrollExtentMax`，真实 `ListView` 又不让测试接管它的滚动 handler。
final class RevealRawScrollSemantics extends SingleChildRenderObjectWidget {
  const RevealRawScrollSemantics({
    super.key,
    required this.position,
    required this.max,
    required this.onScrollDown,
    required Widget super.child,
  });

  final double position;
  final double max;
  final VoidCallback onScrollDown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RevealRawScrollRenderBox(
        position: position,
        max: max,
        onScrollDown: onScrollDown,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RevealRawScrollRenderBox renderObject,
  ) {
    renderObject
      ..position = position
      ..max = max
      ..onScrollDown = onScrollDown;
  }
}

final class RevealRawScrollRenderBox extends RenderProxyBox {
  RevealRawScrollRenderBox({
    required this._position,
    required this._max,
    required this._onScrollDown,
  });

  double _position;
  set position(double value) {
    if (_position == value) return;
    _position = value;
    markNeedsSemanticsUpdate();
  }

  double _max;
  set max(double value) {
    if (_max == value) return;
    _max = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback _onScrollDown;
  set onScrollDown(VoidCallback value) => _onScrollDown = value;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    // 自成语义边界：滚动节点必须是**独立的** `SemanticsNode`，否则它会并进外层
    // 锚点节点，于是「滚动节点消失」在树上看不出来（锚点还在，只是少了 action），
    // `containerChanged` 就永远不可达。真实 `Scrollable` 同样是独立节点。
    config.isSemanticBoundary = true;
    config.scrollPosition = _position;
    config.scrollExtentMin = 0;
    config.scrollExtentMax = _max;
    config.onScrollDown = _onScrollDown;
  }
}

/// 外层竖直列表 + 第 1 行里嵌一个横向列表，目标在外层第 20 行。
///
/// 与 `reveal_matrix_test.dart` 的 `_nested()` 同形，但那份是私有的。升层测试
/// 用它加上「内层 policy 只授权 1 步」把升层钉在确定的步数上。
Widget revealNestedLists() => Semantics(
  identifier: revealContainerId,
  container: true,
  child: ShowOnScreenRecorder(
    child: ListView.builder(
      itemExtent: revealRowExtent,
      itemCount: 40,
      itemBuilder: (BuildContext context, int index) {
        if (index == 1) {
          return Semantics(
            identifier: revealNestedContainerId,
            container: true,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemExtent: revealRowExtent,
              itemCount: 20,
              itemBuilder: (BuildContext context, int column) =>
                  Center(child: Text('cell $column')),
            ),
          );
        }
        if (index == 20) return revealPointerRow(revealTargetId);
        return Center(child: Text('row $index'));
      },
    ),
  ),
);

// ------------------------------------------------------------ 嵌套假滚动容器

/// 内外两层同步假滚动容器，用来把**升层**钉在确定的步数上。
///
/// 内层恒定停滞：`PatchbayRevealBudget.stallSteps` 步之后该层耗尽，引擎升层。
/// 外层每次派发前进一格，并在第 [revealAtOuterDispatch] 次派发时把目标挂到
/// 内层容器的**兄弟**位置上——因此目标只可能由外层推出来。
///
/// 为什么不用真实嵌套 `ListView`：升层本身可以做到确定，但升层**之后**外层要
/// 滚多少步才让目标进视口取决于 `Scrollable` 的动画时序，逐字节表征就只能把
/// `steps` 一起打成占位符。假容器把这一段也变成确定整数。
final class RevealNestedSyntheticScroll extends StatefulWidget {
  const RevealNestedSyntheticScroll({
    super.key,
    required this.outerLog,
    required this.innerLog,
    this.revealAtOuterDispatch = 1,
  });

  final RevealSyntheticLog outerLog;
  final RevealSyntheticLog innerLog;
  final int revealAtOuterDispatch;

  @override
  State<RevealNestedSyntheticScroll> createState() =>
      _RevealNestedSyntheticScrollState();
}

class _RevealNestedSyntheticScrollState
    extends State<RevealNestedSyntheticScroll> {
  void _outer() {
    widget.outerLog.dispatches += 1;
    setState(() => widget.outerLog.position += revealRowExtent);
  }

  // 内层不动：位置恒为 0，因此每一步都不产生进展。
  void _inner() => setState(() => widget.innerLog.dispatches += 1);

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: revealContainerId,
    container: true,
    child: RevealRawScrollSemantics(
      position: widget.outerLog.position,
      max: revealRowExtent * 40,
      onScrollDown: _outer,
      child: revealStackedRows(<Widget>[
        Semantics(
          identifier: revealNestedContainerId,
          container: true,
          child: RevealRawScrollSemantics(
            position: widget.innerLog.position,
            max: revealRowExtent * 40,
            onScrollDown: _inner,
            child: const SizedBox.expand(),
          ),
        ),
        widget.outerLog.dispatches >= widget.revealAtOuterDispatch
            ? revealBoundaryRow(revealTargetId)
            : const SizedBox.expand(),
      ]),
    ),
  );
}

// ------------------------------------------------------------ 轴与极性探针

/// 可配置的滚动语义探针：直接指定暴露哪些同轴 action 与端点位置。
///
/// `reveal_container_facts.dart` 的三个纯函数吃的是 `SemanticsData`，而
/// `SemanticsData` 只能由框架产出，构造不出来。这个探针把「暴露哪些 action、
/// `pixels` 停在哪儿」变成 widget 参数，于是轴判定、端点极性与可驱动判定的边界
/// 情形可以逐格摆出来，不必先造一棵会滚的真实列表。
final class RevealAxisProbe extends SingleChildRenderObjectWidget {
  const RevealAxisProbe({
    super.key,
    this.up = false,
    this.down = false,
    this.left = false,
    this.right = false,
    this.position,
    this.min,
    this.max,
    this.identifier = revealContainerId,
  }) : super(child: const SizedBox.expand());

  final bool up;
  final bool down;
  final bool left;
  final bool right;
  final double? position;
  final double? min;
  final double? max;
  final String identifier;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RevealAxisProbeRenderBox(this);

  @override
  void updateRenderObject(
    BuildContext context,
    RevealAxisProbeRenderBox renderObject,
  ) => renderObject.spec = this;
}

final class RevealAxisProbeRenderBox extends RenderProxyBox {
  RevealAxisProbeRenderBox(this._spec);

  RevealAxisProbe _spec;
  set spec(RevealAxisProbe value) {
    _spec = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.identifier = _spec.identifier;
    // 三个 setter 都断言非空，所以「缺失」只能通过**不赋值**表达——那正是
    // 「端点信息不足」这一格要摆出来的输入。
    if (_spec.position case final double position) {
      config.scrollPosition = position;
    }
    if (_spec.min case final double min) config.scrollExtentMin = min;
    if (_spec.max case final double max) config.scrollExtentMax = max;
    if (_spec.up) config.onScrollUp = () {};
    if (_spec.down) config.onScrollDown = () {};
    if (_spec.left) config.onScrollLeft = () {};
    if (_spec.right) config.onScrollRight = () {};
  }
}

/// 找到 [root] 子树里带 [identifier] 的唯一节点。
SemanticsNode revealNodeWith(SemanticsNode root, String identifier) {
  final List<SemanticsNode> found = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    if (node.getSemanticsData().identifier == identifier) found.add(node);
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  if (found.length != 1) {
    throw StateError('expected exactly one "$identifier", got ${found.length}');
  }
  return found.single;
}
