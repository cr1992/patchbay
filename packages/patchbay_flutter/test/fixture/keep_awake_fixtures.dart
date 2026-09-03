import 'dart:convert';
import 'dart:developer';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

final class RecordingDelegate {
  RecordingDelegate({this.failOn, this.before});

  final List<bool> calls = <bool>[];
  bool? failOn;

  final Future<void> Function(bool enabled)? before;

  Future<void> call(bool enabled) async {
    await before?.call(enabled);
    if (enabled == failOn) throw const KeepAwakeDelegateFailure();
    calls.add(enabled);
  }
}

final class KeepAwakeDelegateFailure implements Exception {
  const KeepAwakeDelegateFailure();
}

const PatchbayGateEvaluator allowAllGates = PatchbayGateEvaluator(
  baseGate: allowGate,
  consumerGate: allowConsumerGate,
);

PatchbayGateDecision allowGate() => const PatchbayGateDecision.allow();

PatchbayGateDecision allowConsumerGate(String _) =>
    const PatchbayGateDecision.allow();

PatchbayKeepAwakeBridge createKeepAwakeBridge({
  RecordingDelegate? delegate,
  PatchbayGateEvaluator gates = allowAllGates,
  Set<String> gateIds = const <String>{},
  bool Function()? isAppResumed,
  AppLifecycleState? Function()? lifecycleState,
}) => PatchbayKeepAwakeBridge(
  gates: gates,
  delegate: delegate?.call,
  gateIds: gateIds,
  isAppResumed: isAppResumed ?? () => true,
  lifecycleState: lifecycleState ?? () => AppLifecycleState.resumed,
);

Map<String, Object?> payloadOf(PatchbayInvocation invocation) {
  final Map<String, Object?> response = invocation.toJson();
  expect(response['admission'], 'accepted', reason: jsonEncode(response));
  return response['payload']! as Map<String, Object?>;
}

Map<String, Object?> rejectionOf(PatchbayInvocation invocation) {
  final Map<String, Object?> response = invocation.toJson();
  expect(response['admission'], 'rejected', reason: jsonEncode(response));
  return response['rejection']! as Map<String, Object?>;
}

Future<void> releaseScreen(
  WidgetTester tester,
  PatchbayKeepAwakeBridge bridge,
) async {
  await bridge.set(
    const PatchbayKeepAwakeRequestWire(enabled: false, leaseMs: null),
  );
  await tester.pump();
}

Future<void> drainBridge(
  WidgetTester tester,
  PatchbayKeepAwakeBridge bridge,
) async {
  await tester.pump();
  await bridge.status();
  await tester.pump();
}

PatchbayFlutterServiceHost createHost(PatchbayFlutterBridge bridge) =>
    PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.test',
      bridge: bridge,
      registrar: (String method, ServiceExtensionHandler handler) {},
    );

Future<List<Map<String, Object?>>> catalogCommandsOf(
  PatchbayFlutterBridge bridge,
) async {
  final Map<String, Object?> catalog = await createHost(
    bridge,
  ).dispatchCatalog();
  return (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>();
}

Future<Set<Object?>> catalogNamesOf(PatchbayFlutterBridge bridge) async =>
    (await catalogCommandsOf(
      bridge,
    )).map((Map<String, Object?> command) => command['name']).toSet();

Future<Map<String, Object?>> catalogCommandOf(
  PatchbayFlutterBridge bridge,
  String name,
) async => (await catalogCommandsOf(
  bridge,
)).firstWhere((Map<String, Object?> command) => command['name'] == name);
