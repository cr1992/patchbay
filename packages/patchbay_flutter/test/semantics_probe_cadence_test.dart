// PB-050-07 / DG-050-05：semantics probe 请帧策略与 `ui.wait` cadence 的帧数冻结。
//
// 三条生效结论逐格冻结在这里：
//
// 1. ready owner 的 one-shot **零额外帧**——owner/root 已可用时直接 probe，不主动
//    请帧；首建 / 替换 / root 缺失才走有界恢复（最多三轮、单帧 timeout 2 秒）。
//    one-shot 的观察语义因此是「调用开始时已 flush 的树」，不是「命令后下一帧」。
// 2. `ui.wait.frameRevision` **计入所有实际驱动的帧**，包括 owner 恢复帧——驱了帧
//    却不报告是隐瞒。
// 3. identifier index 本版不实现，安全围栏（owner/tree identity、node identity、
//    generation、门后二次复核）由既有测试守；本文件只冻结帧数与 timing 口径。
//
// 帧数是**稳定断言**而不是性能数：这里的每个数字都由 `tester.pump()` 显式驱动，
// 与机器速度无关。`_settleWithoutForcingFrame` 先把微任务排空再决定是否 pump ——
// 否则「零帧操作」会被测试脚手架自己的 pump 冤枉成一帧。
//
// 每格都在体内显式 `bridge.dispose()`：flutter_test 的 SemanticsHandle 校验跑在
// `addTearDown` 之前，`addTearDown` 只是失败路径的兜底。
import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
// owner 来源的 debug 覆写不出现在 barrel 里：它只用来构造 widget test 里天然不可
// 达的「root 尚不可用」状态（Flutter 3.44 在 ensureSemantics() 时同步建树）。
import 'package:patchbay_flutter/src/semantics/semantics_bridge.dart'
    show debugPatchbaySemanticsOwnerSource;

const String _targetId = 'cadence.target';
const String _missingId = 'cadence.missing';

void main() {
  group('one-shot 请帧策略', () {
    testWidgets('owner/root 就绪后 snapshot 不驱动任何帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final int beforeRevision = bridge.frameRevision;
      final PatchbayInvocation snapshot = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.snapshot(),
      );

      expect(snapshot.admission, PatchbayAdmission.accepted);
      expect(frames.count - before, 0, reason: 'ready owner 的 snapshot 不请帧');
      expect(bridge.frameRevision, beforeRevision);
      bridge.dispose();
    });

    testWidgets('owner/root 就绪后 identifier probe 与 treeRevision 读数不驱动任何帧', (
      WidgetTester tester,
    ) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final PatchbaySemanticsIdentifierObservation? hit =
          await _settleWithoutForcingFrame(
            tester,
            bridge.semantics.observeIdentifier(_targetId),
          );
      final PatchbaySemanticsIdentifierObservation? miss =
          await _settleWithoutForcingFrame(
            tester,
            bridge.semantics.observeIdentifier(_missingId),
          );
      final int? revision = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.observeTreeRevision(),
      );

      expect(hit?.matches, hasLength(1));
      expect(miss?.matches, isEmpty);
      expect(revision, isNotNull);
      expect(frames.count - before, 0);
      bridge.dispose();
    });

    testWidgets('空闲 App 不被连续 one-shot 探测按显示帧率驱动', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final int beforeRevision = bridge.frameRevision;
      for (var probe = 0; probe < 12; probe += 1) {
        await _settleWithoutForcingFrame(
          tester,
          bridge.semantics.observeIdentifier(_targetId),
        );
        await _settleWithoutForcingFrame(tester, bridge.semantics.snapshot());
      }

      expect(
        frames.count - before,
        0,
        reason: '24 次只读探测不得驱动任何帧——这正是空闲 App 被按帧率驱动的来源',
      );
      expect(bridge.frameRevision, beforeRevision);
      bridge.dispose();
    });

    testWidgets('one-shot 读的是已 flush 的树，不承诺命令后的下一帧', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> mounted = ValueNotifier<bool>(false);
      addTearDown(mounted.dispose);
      await tester.pumpWidget(_conditionalScene(mounted));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      // 目标此刻被标脏但尚未构建：one-shot 必须答「还没挂载」，因为它读的是
      // 调用开始时 engine 已提交的树，而不是下一帧的树。
      mounted.value = true;
      final PatchbaySemanticsIdentifierObservation? pendingBuild =
          await _settleWithoutForcingFrame(
            tester,
            bridge.semantics.observeIdentifier(_targetId),
          );
      expect(pendingBuild?.matches, isEmpty);

      await tester.pump();
      final PatchbaySemanticsIdentifierObservation? afterFrame =
          await _settleWithoutForcingFrame(
            tester,
            bridge.semantics.observeIdentifier(_targetId),
          );
      expect(afterFrame?.matches, hasLength(1));
      bridge.dispose();
    });
  });

  group('owner 恢复的有界请帧', () {
    tearDown(() => debugPatchbaySemanticsOwnerSource = null);

    testWidgets('树已 flush 时首次 ensureOwner 也是零帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final int before = frames.count;
      expect(bridge.frameRevision, 0);
      final SemanticsOwner? owner = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.ensureOwner(),
      );

      expect(owner?.rootSemanticsNode, isNotNull);
      expect(
        frames.count - before,
        0,
        reason: 'Flutter 3.44 在 ensureSemantics() 时同步建树，首建也无须请帧',
      );
      expect(bridge.frameRevision, 0);
      bridge.dispose();
    });

    testWidgets('root 尚不可用时按帧恢复，恢复帧计入 frameRevision', (
      WidgetTester tester,
    ) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final int baseline = frames.count;
      // 一帧之后才「拿得到」带 root 的 owner：这就是 root 缺失的有界恢复路径。
      debugPatchbaySemanticsOwnerSource = () =>
          frames.count > baseline ? _liveOwner() : null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final SemanticsOwner? owner = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.ensureOwner(),
      );

      expect(owner?.rootSemanticsNode, isNotNull);
      expect(frames.count - baseline, 1, reason: '恢复恰好用掉一帧');
      expect(
        bridge.frameRevision,
        1,
        reason: 'owner 恢复帧是实际驱动的帧，必须计入 frameRevision',
      );
      bridge.dispose();
    });

    testWidgets('root 一直不可用时最多三帧后稳定拒绝 uiSemanticsUnavailable', (
      WidgetTester tester,
    ) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      debugPatchbaySemanticsOwnerSource = () => null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final int before = frames.count;
      final PatchbayInvocation snapshot = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.snapshot(),
      );

      expect(snapshot.rejection?.code, 'uiSemanticsUnavailable');
      expect(frames.count - before, 3, reason: '有界恢复上限三轮，DG-050-05 不放宽');
      expect(bridge.frameRevision, 3, reason: '三帧都实际驱动了，三帧都要报告');
      bridge.dispose();
    });

    testWidgets('owner 就绪后再次 ensureOwner 不再请帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final int beforeRevision = bridge.frameRevision;
      for (var call = 0; call < 5; call += 1) {
        await _settleWithoutForcingFrame(
          tester,
          bridge.semantics.ensureOwner(),
        );
      }

      expect(frames.count - before, 0);
      expect(bridge.frameRevision, beforeRevision);
      bridge.dispose();
    });

    testWidgets('dispose 之后既不恢复也不请帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      await _establishOwner(tester, bridge);
      bridge.dispose();

      final int before = frames.count;
      final SemanticsOwner? owner = await _settleWithoutForcingFrame(
        tester,
        bridge.semantics.ensureOwner(),
      );

      expect(owner, isNull);
      expect(frames.count - before, 0, reason: 'disposed 是终态，不再驱动任何恢复帧');
    });
  });

  group('ui.wait cadence', () {
    tearDown(() => debugPatchbaySemanticsOwnerSource = null);

    testWidgets('未满足一轮恰好一帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      final ValueNotifier<bool> mounted = ValueNotifier<bool>(false);
      addTearDown(mounted.dispose);
      await tester.pumpWidget(_conditionalScene(mounted));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final int beforeRevision = bridge.frameRevision;
      final Future<PatchbayInvocation> pending = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(seconds: 5),
          semanticsIdentifier: _targetId,
        ),
      );
      mounted.value = true;
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        pending,
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(
        frames.count - before,
        1,
        reason: '一轮未满足 = 一帧：probe 自己不再请第二帧（此前是两帧）',
      );
      expect(bridge.frameRevision, beforeRevision + 1);
      expect(result.payload['frameRevision'], beforeRevision + 1);
      bridge.dispose();
    });

    testWidgets('未满足两轮恰好两帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final int beforeRevision = bridge.frameRevision;
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.frameRevision,
            timeout: const Duration(seconds: 5),
            revision: beforeRevision + 1,
          ),
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(frames.count - before, 2);
      expect(result.payload['frameRevision'], beforeRevision + 2);
      bridge.dispose();
    });

    testWidgets('第一次 probe 就满足时 wait 不驱动任何帧', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final int before = frames.count;
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.semanticsMounted,
            timeout: const Duration(seconds: 5),
            semanticsIdentifier: _targetId,
          ),
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(frames.count - before, 0);
      bridge.dispose();
    });

    testWidgets('owner 恢复帧计入 wait 报告的 frameRevision', (
      WidgetTester tester,
    ) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final int baseline = frames.count;
      // 条件在第一次 probe 就满足，wait cadence 自己零帧；唯一那一帧来自 owner
      // 恢复。它照样必须出现在 wait 报告的 frameRevision 里。
      debugPatchbaySemanticsOwnerSource = () =>
          frames.count > baseline ? _liveOwner() : null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        bridge.wait.wait(
          PatchbayUiWaitRequest(
            condition: PatchbayUiWaitCondition.semanticsMounted,
            timeout: const Duration(seconds: 5),
            semanticsIdentifier: _targetId,
          ),
        ),
      );

      expect(result.admission, PatchbayAdmission.accepted);
      expect(frames.count - baseline, 1);
      expect(
        result.payload['frameRevision'],
        1,
        reason: '实际驱了帧就必须报告，哪怕那一帧是 owner 恢复驱动的',
      );
      bridge.dispose();
    });

    testWidgets('owner 恢复不延长调用方预算：短 timeout 照样按时超时', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_scene());
      // owner 恢复注定要跑满三轮 × 2 秒；调用方只给了 20ms。恢复必须夹在调用方
      // 这一份预算里，且短调用方放弃不取消仍在跑的 flight。
      debugPatchbaySemanticsOwnerSource = () => null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final Future<PatchbayInvocation> pending = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(milliseconds: 20),
          semanticsIdentifier: _targetId,
        ),
      );
      // 先让 20ms 预算耗尽，再驱动那一帧：wait 必须已经放弃，而不是等满恢复预算。
      await tester.pump(const Duration(milliseconds: 50));
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiWaitTimeout');
      expect(result.rejection?.details['timeoutMs'], 20);
      expect(
        result.rejection?.details['elapsedMs'] as int,
        lessThan(2000),
        reason: '调用方按自己的 20ms 预算返回，没有被拖到恢复的单轮 2 秒上限',
      );
      expect(
        result.rejection?.details['frameRevision'],
        0,
        reason: '预算耗尽时还没有任何帧被驱动，报告的就是 0——照实报告，不预支',
      );

      // 放弃的调用方没有取消 flight：owner 一旦可得，flight 自己收尾。
      debugPatchbaySemanticsOwnerSource = null;
      await tester.pump();
      await tester.idle();
      bridge.dispose();
    });
  });

  group('elapsedMs / frameRevision / timeout 兼容矩阵', () {
    testWidgets('满足时的 payload 形状不变，frameRevision 是观察者真值', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> mounted = ValueNotifier<bool>(false);
      addTearDown(mounted.dispose);
      await tester.pumpWidget(_conditionalScene(mounted));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final Future<PatchbayInvocation> pending = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(seconds: 5),
          semanticsIdentifier: _targetId,
        ),
      );
      mounted.value = true;
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        pending,
      );

      final Map<String, Object?> payload = result.payload;
      expect(payload['outcome'], 'observed');
      expect(payload['source'], 'uiObserved');
      expect(payload['condition'], 'semanticsMounted');
      expect(payload['semanticsIdentifier'], _targetId);
      expect(payload['elapsedMs'], isA<int>());
      expect(payload['elapsedMs'] as int, greaterThanOrEqualTo(0));
      expect(payload['treeRevision'], isA<int>());
      expect(payload['frameRevision'], bridge.frameRevision);
      bridge.dispose();
    });

    testWidgets('超时拒绝仍带 condition/timeoutMs/elapsedMs/frameRevision', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_scene());
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      await _establishOwner(tester, bridge);

      final Future<PatchbayInvocation> pending = bridge.wait.wait(
        PatchbayUiWaitRequest(
          condition: PatchbayUiWaitCondition.semanticsMounted,
          timeout: const Duration(milliseconds: 20),
          semanticsIdentifier: _missingId,
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        pending,
      );

      expect(result.rejection?.code, 'uiWaitTimeout');
      final Map<String, Object?> details = result.rejection!.details;
      expect(details['condition'], 'semanticsMounted');
      expect(details['timeoutMs'], 20);
      expect(details['elapsedMs'], isA<int>());
      expect(details['frameRevision'], bridge.frameRevision);
      bridge.dispose();
    });
  });

  group('VM / direct 共享 owner flight', () {
    tearDown(() => debugPatchbaySemanticsOwnerSource = null);

    testWidgets('并发 one-shot 只驱动一份 owner 恢复预算', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final int before = frames.count;
      debugPatchbaySemanticsOwnerSource = () =>
          frames.count > before ? _liveOwner() : null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final Future<PatchbayInvocation> snapshot = bridge.semantics.snapshot();
      final Future<PatchbaySemanticsIdentifierObservation?> probe = bridge
          .semantics
          .observeIdentifier(_targetId);
      final Future<int?> revision = bridge.semantics.observeTreeRevision();
      await _settleWithoutForcingFrame(
        tester,
        Future.wait<Object?>(<Future<Object?>>[snapshot, probe, revision]),
      );

      expect((await snapshot).admission, PatchbayAdmission.accepted);
      expect((await probe)?.matches, hasLength(1));
      expect(await revision, isNotNull);
      expect(
        frames.count - before,
        1,
        reason: '三个并发调用共享同一次 owner flight，不是各请各的帧',
      );
      bridge.dispose();
    });

    testWidgets('一个调用方放弃等待不取消 flight，也不破坏另一个调用方', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final int before = frames.count;
      debugPatchbaySemanticsOwnerSource = () =>
          frames.count > before ? _liveOwner() : null;
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      // 短预算的传输先放弃（transport deadline 只夹总预算，不实现 cadence）。
      final Future<int?> abandoned = bridge.semantics
          .observeTreeRevision()
          .timeout(Duration.zero, onTimeout: () => null);
      final Future<PatchbayInvocation> survivor = bridge.semantics.snapshot();

      await tester.idle();
      expect(await abandoned, isNull);

      final PatchbayInvocation result = await _settleWithoutForcingFrame(
        tester,
        survivor,
      );
      expect(result.admission, PatchbayAdmission.accepted);
      expect(frames.count - before, 1);
      bridge.dispose();
    });

    testWidgets('VM 与 direct 交错调用共享 owner，两侧答复一致', (WidgetTester tester) async {
      final _Frames frames = _Frames(tester);
      await tester.pumpWidget(_scene());
      final int before = frames.count;
      debugPatchbaySemanticsOwnerSource = () =>
          frames.count > before ? _liveOwner() : null;
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.cadence',
        bridge: bridge,
        registrar: (String method, ServiceExtensionHandler handler) =>
            handlers[method] = handler,
      )..register();

      const Map<String, Object?> arguments = <String, Object?>{'maxNodes': 200};
      final Future<Map<String, Object?>> direct = host.dispatchInvoke(
        'ui.semantics.tree',
        arguments,
        'cadence-direct',
      );
      final Future<Map<String, Object?>> vm =
          _call(handlers, PatchbayServiceHost.invokeMethod, <String, String>{
            'command': 'ui.semantics.tree',
            'requestId': 'cadence-vm',
            'args': jsonEncode(arguments),
          });
      await _settleWithoutForcingFrame(
        tester,
        Future.wait<Map<String, Object?>>(<Future<Map<String, Object?>>>[
          direct,
          vm,
        ]),
      );

      final Map<String, Object?> directResult = await direct;
      final Map<String, Object?> vmResult = await vm;
      expect(directResult['admission'], 'accepted');
      expect(vmResult['admission'], 'accepted');
      expect(vmResult['payload'], directResult['payload']);
      expect(
        frames.count - before,
        1,
        reason: 'VM 与 direct 走同一个 bridge，owner 恢复只发生一次',
      );
      bridge.dispose();
    });
  });
}

/// 帧计数器：只统计真实驱动的帧，不含任何脚手架自造的 pump。
final class _Frames {
  _Frames(WidgetTester tester) {
    tester.binding.addPersistentFrameCallback((Duration _) => _count += 1);
  }

  int _count = 0;

  int get count => _count;
}

/// 先排空微任务，只有确实还没完成才 pump。
///
/// 直接 pump 的脚手架会把「零帧操作」冤枉成一帧，本文件的断言就全失去意义。
Future<T> _settleWithoutForcingFrame<T>(
  WidgetTester tester,
  Future<T> pending, {
  int maxFrames = 20,
}) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  await tester.idle();
  for (var frame = 0; frame < maxFrames && !completed; frame += 1) {
    await tester.pump();
    await tester.idle();
  }
  if (!completed) {
    throw StateError('cadence operation did not complete in $maxFrames frames');
  }
  return pending;
}

/// 当前真实的、带 root 的 semantics owner；覆写钩子「恢复成功」时返回它。
SemanticsOwner? _liveOwner() {
  for (final RenderView view in RendererBinding.instance.renderViews) {
    final SemanticsOwner? candidate = view.owner?.semanticsOwner;
    if (candidate?.rootSemanticsNode != null) return candidate;
  }
  return null;
}

/// 把 owner 建立这一次性成本移出被测区间：本文件冻结的是「之后」的 cadence。
Future<void> _establishOwner(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final SemanticsOwner? owner = await _settleWithoutForcingFrame(
    tester,
    bridge.semantics.ensureOwner(),
  );
  expect(owner?.rootSemanticsNode, isNotNull);
}

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

PatchbayFlutterBridge _bridge() => PatchbayFlutterBridge(
  gates: PatchbayGateEvaluator(
    baseGate: () => const PatchbayGateDecision.allow(),
    consumerGate: (_) => const PatchbayGateDecision.allow(),
  ),
  registry: PatchbayUiRegistry(),
  isAppResumed: () => true,
);

Widget _scene() => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: Semantics(
      identifier: _targetId,
      container: true,
      explicitChildNodes: true,
      child: const SizedBox(width: 24, height: 24),
    ),
  ),
);

Widget _conditionalScene(ValueListenable<bool> mounted) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: ValueListenableBuilder<bool>(
      valueListenable: mounted,
      builder: (BuildContext context, bool visible, Widget? _) => visible
          ? Semantics(
              identifier: _targetId,
              container: true,
              explicitChildNodes: true,
              child: const SizedBox(width: 24, height: 24),
            )
          : const SizedBox(width: 24, height: 24),
    ),
  ),
);
