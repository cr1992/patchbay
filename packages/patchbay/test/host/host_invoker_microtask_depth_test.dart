// PB-050-38：admission pipeline 的**让步结构**探针。
//
// 拆分不得改变一次调用在完成前让出多少个微任务。这不是性能洁癖：每一个让步窗口都
// 是取消信号能够插进来的地方，多一个窗口就意味着某类命令的取消**观察时机**变了——
// 本来 handler 已经进去了，现在会被 handler 前的冻结复核抓到。
//
// 探针用 `await null` 逐个数微任务轮次，因此它量的是「应答完成前让出了几轮」，
// 一个相对但完全确定的整数。三条路径分别代表准入门的三种走法：
//
//   `noGateReadOnly`   只读且无声明门 —— 门整段被同步短路，一个 await 都不走；
//   `baseGateWrite`    写命令过 base gate —— 门求值 + 门后目录复核；
//   `noEvaluatorWrite` 声明了门却没有求值器 —— 在门内早退，不到门后复核。
//
// 期望值 4 / 6 / 3 是在拆分前的 `3e5561f3` 上实测出来的，不是设计出来的：拆分只需
// 复现同一组数。其中 `noGateReadOnly` 是唯一一条会因为「门阶段被做成无条件 await」
// 而变成 5 的路径。
//
// 本文件只用公共 host 面，因此可以原样拷进拆分前的树里跑同一组数——那正是它存在
// 的理由。
library;

import 'dart:async';

import 'package:patchbay/patchbay_host.dart';
import 'package:test/test.dart';

void main() {
  group('准入门的让步结构', () {
    test('noGateReadOnly：只读且无声明门时门整段同步短路', () async {
      expect(
        await _microtaskDepth(
          _host(
            commands: <Map<String, Object?>>[
              _row('device.probe', sideEffect: 'none'),
            ],
            domainGates: _gates(),
          ),
          'device.probe',
        ),
        4,
      );
    });

    test('baseGateWrite：写命令过 base gate 并做门后复核', () async {
      expect(
        await _microtaskDepth(
          _host(
            commands: <Map<String, Object?>>[_row('device.write')],
            domainGates: _gates(),
          ),
          'device.write',
        ),
        6,
      );
    });

    test('noEvaluatorWrite：声明了门却没有求值器时在门内早退', () async {
      expect(
        await _microtaskDepth(
          _host(
            commands: <Map<String, Object?>>[
              _row('device.write', gates: <String>['sealedGate']),
            ],
          ),
          'device.write',
        ),
        3,
      );
    });
  });
}

/// 数出 [command] 的应答在完成前让出了多少个微任务轮次。
///
/// `await null` 恰好让出一轮，所以计数是确定的；上界只用来防止判据写错时死循环。
Future<int> _microtaskDepth(PatchbayServiceHost host, String command) async {
  var settled = false;
  final Future<Map<String, Object?>> response = host.dispatchInvoke(
    command,
    const <String, Object?>{},
    'req-depth',
  );
  unawaited(response.then<void>((Map<String, Object?> _) => settled = true));
  var depth = 0;
  while (!settled && depth < 64) {
    depth += 1;
    await null;
  }
  await response;
  return depth;
}

Map<String, Object?> _row(
  String name, {
  String sideEffect = 'external',
  List<String>? gates,
}) => <String, Object?>{
  'name': name,
  'mode': 'immediate',
  'sideEffect': sideEffect,
  'factSources': <String>['appRecorded'],
  if (gates != null) 'gates': gates,
};

PatchbayServiceHost _host({
  required List<Map<String, Object?>> commands,
  PatchbayGateEvaluator? domainGates,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.host-invoker-depth',
  registrar: (_, _) {},
  domainGates: domainGates,
  catalog: () async => <String, Object?>{'commands': commands},
  snapshot: () async => const <String, Object?>{},
  invoke: (String _, Map<String, Object?> _, String requestId) async =>
      PatchbayInvocation.accepted(requestId: requestId).toJson(),
);

PatchbayGateEvaluator _gates() => PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (String _) => const PatchbayGateDecision.allow(),
);
