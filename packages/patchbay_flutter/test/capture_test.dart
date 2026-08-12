import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  testWidgets('root wrapper preserves constraints and waits for next frame', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    final PatchbayArtifactService artifacts = _artifacts();
    var encodeCalls = 0;
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: _gates,
      artifacts: artifacts,
      rootController: root,
      captureEncoder:
          (RenderRepaintBoundary boundary, double pixelRatio) async {
            encodeCalls += 1;
            return PatchbayEncodedCapture(
              bytes: _pngBytes(),
              width: 80,
              height: 40,
            );
          },
      isAppResumed: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 80,
            height: 40,
            child: PatchbayRoot(
              controller: root,
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(PatchbayRoot)), const Size(80, 40));

    final Future<PatchbayInvocation> pending = bridge.capture!.capture(
      PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
      ),
      requestId: 'capture-root',
    );
    expect(encodeCalls, 0);
    await tester.pump();
    await tester.pump();
    final Map<String, Object?> result = (await pending).toJson();

    expect(encodeCalls, 1);
    expect(result['admission'], 'accepted', reason: jsonEncode(result));
    final Map<String, Object?> payload =
        result['payload']! as Map<String, Object?>;
    expect(payload, containsPair('target', 'root'));
    expect(payload, containsPair('width', 80));
    expect(payload['warnings'], <String>[
      'flutterSubtreeOnly',
      'platformViewsMayBeMissing',
      'systemUiNotIncluded',
    ]);
    final Map<String, Object?> blob = payload['blob']! as Map<String, Object?>;
    expect(blob, containsPair('contentType', 'image/png'));
    expect(blob, containsPair('source', 'uiObserved'));
    expect(blob, containsPair('kind', 'flutterCapture'));
    expect(blob, containsPair('length', 8));
  });

  testWidgets('capture rejects background before frame or encoding', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    var encoded = false;
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: _gates,
      artifacts: _artifacts(),
      rootController: root,
      isAppResumed: () => false,
      captureEncoder: (_, _) async {
        encoded = true;
        return PatchbayEncodedCapture(bytes: _pngBytes(), width: 1, height: 1);
      },
    );
    await tester.pumpWidget(
      PatchbayRoot(
        controller: root,
        child: const SizedBox.square(dimension: 5),
      ),
    );

    final Map<String, Object?> result = (await bridge.capture!.capture(
      PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
      ),
      requestId: 'capture-background',
    )).toJson();

    expect(_rejectionCode(result), 'captureLifecycleNotResumed');
    expect(encoded, isFalse);
  });

  testWidgets('capture checks the pixel limit before encoding', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    final PatchbayArtifactService artifacts = _artifacts();
    final PatchbayCaptureBridge capture = PatchbayCaptureBridge(
      gates: _gates,
      registry: PatchbayUiRegistry(),
      frames: PatchbayFrameObserver(),
      artifacts: artifacts,
      root: root,
      isAppResumed: () => true,
      maxPixels: 10,
      encoder: (_, _) async =>
          PatchbayEncodedCapture(bytes: _pngBytes(), width: 10, height: 10),
    );
    await tester.pumpWidget(
      PatchbayRoot(
        controller: root,
        child: const SizedBox.square(dimension: 5),
      ),
    );
    final Future<PatchbayInvocation> pending = capture.capture(
      PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
      ),
      requestId: 'capture-pixels',
    );
    await tester.pump();
    await tester.pump();
    expect(
      _rejectionCode((await pending).toJson()),
      'capturePixelLimitExceeded',
    );
  });

  testWidgets('capture checks the encoded byte limit', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    final PatchbayCaptureBridge capture = PatchbayCaptureBridge(
      gates: _gates,
      registry: PatchbayUiRegistry(),
      frames: PatchbayFrameObserver(),
      artifacts: _artifacts(),
      root: root,
      isAppResumed: () => true,
      maxBytes: 7,
      encoder: (_, _) async =>
          PatchbayEncodedCapture(bytes: _pngBytes(), width: 5, height: 5),
    );
    await tester.pumpWidget(
      PatchbayRoot(
        controller: root,
        child: const SizedBox.square(dimension: 5),
      ),
    );
    final Future<PatchbayInvocation> pending = capture.capture(
      PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
      ),
      requestId: 'capture-bytes',
    );
    await tester.pump();
    await tester.pump();
    expect(
      _rejectionCode((await pending).toJson()),
      'captureByteLimitExceeded',
    );
  });

  testWidgets(
    'registered capture targets require an existing repaint boundary',
    (WidgetTester tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey target = PatchbayKey.capture(
        'fixture.preview',
        registry: registry,
      );
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        gates: _gates,
        registry: registry,
        artifacts: _artifacts(),
        isAppResumed: () => true,
        captureEncoder: (_, _) async =>
            PatchbayEncodedCapture(bytes: _pngBytes(), width: 10, height: 10),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: target,
          child: const SizedBox.square(dimension: 10),
        ),
      );
      final PatchbayUiTargetDescriptor descriptor = bridge.catalog().single;
      expect(descriptor.operations, contains(PatchbayUiOperation.capture));

      final Future<PatchbayInvocation> pending = bridge.capture!.capture(
        PatchbayCaptureRequestWire(
          targetId: 'fixture.preview',
          generation: descriptor.generation,
          pixelRatio: 1,
          timeoutMs: 1000,
        ),
        requestId: 'capture-target',
      );
      await tester.pump();
      await tester.pump();
      expect((await pending).admission, PatchbayAdmission.accepted);
    },
  );

  testWidgets('service host omits capture and artifacts without injection', (
    WidgetTester tester,
  ) async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.capture',
      bridge: PatchbayFlutterBridge(gates: _gates),
      registrar: (method, handler) => handlers[method] = handler,
    ).register();

    final Map<String, Object?> catalog = await _call(
      handlers,
      PatchbayServiceHost.catalogMethod,
    );
    final Set<Object?> commands = (catalog['commands']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((entry) => entry['name'])
        .toSet();
    expect(commands, isNot(contains('ui.capture')));
    expect(commands, isNot(contains('blob.read')));
    expect(commands, isNot(contains('logs.query')));

    final Map<String, Object?> invocation = await _call(
      handlers,
      PatchbayServiceHost.invokeMethod,
      <String, String>{'command': 'ui.capture', 'args': '{}'},
    );
    expect(_rejectionCode(invocation), 'commandNotRegistered');
  });

  testWidgets(
    'service host catalogs and dispatches explicitly injected artifacts',
    (WidgetTester tester) async {
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      final PatchbayArtifactService artifacts = _artifacts();
      PatchbayFlutterServiceHost(
        applicationId: 'dev.patchbay.capture',
        bridge: PatchbayFlutterBridge(
          gates: _gates,
          artifacts: artifacts,
          captureGates: const <String>{'capture.ready'},
          isAppResumed: () => true,
        ),
        registrar: (method, handler) => handlers[method] = handler,
      ).register();

      final Map<String, Object?> catalog = await _call(
        handlers,
        PatchbayServiceHost.catalogMethod,
      );
      final Set<Object?> commands = (catalog['commands']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((entry) => entry['name'])
          .toSet();
      expect(
        commands,
        containsAll(<String>{'ui.capture', 'blob.metadata', 'blob.read'}),
      );
      expect(commands, isNot(contains('logs.query')));
      final Map<String, Object?> captureDescriptor =
          (catalog['commands']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .singleWhere((entry) => entry['name'] == 'ui.capture');
      expect(captureDescriptor['gates'], <String>['capture.ready']);

      final Map<String, Object?> invocation = await _call(
        handlers,
        PatchbayServiceHost.invokeMethod,
        <String, String>{'command': 'ui.capture', 'args': '{}'},
      );
      expect(_rejectionCode(invocation), 'captureRootNotMounted');
    },
  );

  test('release mode path returns the exact child widget', () {
    final Widget child = Container();
    expect(
      identical(
        PatchbayRoot.buildForMode(
          child: child,
          controller: PatchbayRootController(),
          enabled: false,
        ),
        child,
      ),
      isTrue,
    );
  });
}

final PatchbayGateEvaluator _gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

PatchbayArtifactService _artifacts() =>
    PatchbayArtifactService(blobs: PatchbayMemoryBlobStore(), gates: _gates);

Uint8List _pngBytes() =>
    Uint8List.fromList(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);

String? _rejectionCode(Map<String, Object?> response) =>
    (response['rejection'] as Map<String, Object?>?)?['code'] as String?;

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
