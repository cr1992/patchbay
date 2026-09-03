import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

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
        afterFrames: null,
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
        afterFrames: null,
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
        afterFrames: null,
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
        afterFrames: null,
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

  test(
    'the needs-paint probe leaves the debug-only getter alone outside debug',
    () {
      final RenderRepaintBoundary boundary = _UnreadableNeedsPaintBoundary();

      expect(
        PatchbayCaptureBridge.needsPaintForMode(boundary, isDebugBuild: false),
        isFalse,
      );
      // Profile and release throw `LateInitializationError` from this getter, so
      // the fixture above only proves anything as long as reading it really does
      // blow up. Assert that it does, or the case above passes vacuously.
      expect(
        () => PatchbayCaptureBridge.needsPaintForMode(
          boundary,
          isDebugBuild: true,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'the needs-paint probe still reports an unpainted boundary in debug',
    () {
      expect(
        PatchbayCaptureBridge.needsPaintForMode(
          _NeedsPaintBoundary(),
          isDebugBuild: true,
        ),
        isTrue,
      );
    },
  );

  testWidgets('capture rejects a boundary with an empty size', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    var encoded = false;
    final PatchbayCaptureBridge capture = PatchbayCaptureBridge(
      gates: _gates,
      registry: PatchbayUiRegistry(),
      frames: PatchbayFrameObserver(),
      artifacts: _artifacts(),
      root: root,
      isAppResumed: () => true,
      encoder: (_, _) async {
        encoded = true;
        return PatchbayEncodedCapture(bytes: _pngBytes(), width: 1, height: 1);
      },
    );
    await tester.pumpWidget(
      Center(
        child: SizedBox.shrink(
          child: PatchbayRoot(
            controller: root,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );

    final Future<PatchbayInvocation> pending = capture.capture(
      PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
        afterFrames: null,
      ),
      requestId: 'capture-empty',
    );
    await tester.pump();
    await tester.pump();

    expect(_rejectionCode((await pending).toJson()), 'captureTargetNotPainted');
    expect(encoded, isFalse);
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
          afterFrames: null,
        ),
        requestId: 'capture-target',
      );
      await tester.pump();
      await tester.pump();
      expect((await pending).admission, PatchbayAdmission.accepted);
    },
  );

  testWidgets('afterFrames starts at the first post-admission observation', (
    WidgetTester tester,
  ) async {
    final PatchbayRootController root = PatchbayRootController();
    var encodeCalls = 0;
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: _gates,
      artifacts: _artifacts(),
      rootController: root,
      isAppResumed: () => true,
      captureEncoder: (_, _) async {
        encodeCalls += 1;
        return PatchbayEncodedCapture(bytes: _pngBytes(), width: 4, height: 4);
      },
    );
    await tester.pumpWidget(
      PatchbayRoot(
        controller: root,
        child: const SizedBox.square(dimension: 4),
      ),
    );

    final Future<PatchbayInvocation> pending = bridge.capture!.capture(
      const PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
        afterFrames: 3,
      ),
      requestId: 'capture-after-three',
    );
    for (var observed = 1; observed < 3; observed += 1) {
      await tester.pump();
      expect(encodeCalls, 0, reason: 'encoded after only $observed frames');
    }
    await tester.pump();
    await tester.pump();

    final Map<String, Object?> response = (await pending).toJson();
    final Map<String, Object?> payload =
        response['payload']! as Map<String, Object?>;
    expect(encodeCalls, 1);
    expect(payload['requestedFrames'], 3);
    expect(payload['observedFrames'], 3);
    expect(payload['pixelFormat'], 'rgba8888');
    expect(payload['maxPixels'], 16 * 1024 * 1024);
    expect(payload['maxBytes'], 8 * 1024 * 1024);
  });

  testWidgets('capture rejects an afterFrames value above its budget', (
    WidgetTester tester,
  ) async {
    final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
      gates: _gates,
      artifacts: _artifacts(),
      isAppResumed: () => true,
    );
    final Map<String, Object?> response = (await bridge.capture!.capture(
      const PatchbayCaptureRequestWire(
        targetId: null,
        generation: null,
        pixelRatio: 1,
        timeoutMs: 1000,
        afterFrames: 121,
      ),
      requestId: 'capture-too-many-frames',
    )).toJson();

    expect(_rejectionCode(response), 'invalidCaptureArguments');
    expect(
      (response['rejection']! as Map<String, Object?>)['details'],
      containsPair('maxAfterFrames', 120),
    );
  });

  test('capture diff reports no change and one changed pixel', () async {
    final PatchbayArtifactService artifacts = _artifacts();
    final PatchbayCaptureBridge capture = _diffBridge(artifacts);
    final String before = _captureBlob(artifacts, 1);
    final String same = _captureBlob(artifacts, 1);
    final String after = _captureBlob(artifacts, 2);

    final Map<String, Object?> unchanged = (await capture.diff(
      PatchbayCaptureDiffRequestWire(beforeBlobId: before, afterBlobId: same),
      requestId: 'diff-unchanged',
    )).toJson();
    final Map<String, Object?> unchangedPayload =
        unchanged['payload']! as Map<String, Object?>;
    expect(unchangedPayload['changedPixels'], 0);
    expect(unchangedPayload['totalPixels'], 2);
    expect(unchangedPayload['differenceRatio'], 0);
    expect(unchangedPayload['source'], 'uiObserved');
    expect(unchangedPayload['warnings'], contains('systemUiNotIncluded'));

    final Map<String, Object?> changed = (await capture.diff(
      PatchbayCaptureDiffRequestWire(beforeBlobId: before, afterBlobId: after),
      requestId: 'diff-one-pixel',
    )).toJson();
    final Map<String, Object?> changedPayload =
        changed['payload']! as Map<String, Object?>;
    expect(changedPayload['changedPixels'], 1);
    expect(changedPayload['totalPixels'], 2);
    expect(changedPayload['differenceRatio'], 0.5);
    expect(changedPayload, isNot(contains('passed')));
  });

  test('capture diff refuses mismatched image specifications', () async {
    final PatchbayArtifactService artifacts = _artifacts();
    final PatchbayCaptureBridge capture = _diffBridge(artifacts);
    final Map<String, Object?> response = (await capture.diff(
      PatchbayCaptureDiffRequestWire(
        beforeBlobId: _captureBlob(artifacts, 1),
        afterBlobId: _captureBlob(artifacts, 3),
      ),
      requestId: 'diff-mismatch',
    )).toJson();

    expect(_rejectionCode(response), 'captureDiffSpecMismatch');
  });

  test(
    'capture diff enforces encoded byte and decoded pixel budgets',
    () async {
      final PatchbayArtifactService artifacts = _artifacts();
      final String before = _captureBlob(artifacts, 1);
      final String after = _captureBlob(artifacts, 2);
      final Map<String, Object?> bytes =
          (await _diffBridge(artifacts, maxBytes: 8).diff(
            PatchbayCaptureDiffRequestWire(
              beforeBlobId: before,
              afterBlobId: after,
            ),
            requestId: 'diff-bytes',
          )).toJson();
      expect(_rejectionCode(bytes), 'captureDiffByteLimitExceeded');

      final Map<String, Object?> pixels =
          (await _diffBridge(artifacts, maxPixels: 1).diff(
            PatchbayCaptureDiffRequestWire(
              beforeBlobId: before,
              afterBlobId: after,
            ),
            requestId: 'diff-pixels',
          )).toJson();
      expect(_rejectionCode(pixels), 'captureDiffPixelLimitExceeded');
    },
  );

  test('VM handler and direct dispatcher share capture diff results', () async {
    final PatchbayArtifactService artifacts = _artifacts();
    final String before = _captureBlob(artifacts, 1);
    final String after = _captureBlob(artifacts, 2);
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.capture-diff',
      bridge: PatchbayFlutterBridge(
        gates: _gates,
        artifacts: artifacts,
        captureDecoder: _decodeFixture,
        isAppResumed: () => true,
      ),
      registrar: (method, handler) => handlers[method] = handler,
    )..register();
    final Map<String, Object?> arguments = <String, Object?>{
      'beforeBlobId': before,
      'afterBlobId': after,
    };
    final Map<String, Object?> direct = await host.dispatchInvoke(
      'ui.capture.diff',
      arguments,
      'direct-request',
    );
    final Map<String, Object?> vm = await _call(
      handlers,
      PatchbayServiceHost.invokeMethod,
      <String, String>{
        'command': 'ui.capture.diff',
        'args': jsonEncode(arguments),
        'requestId': 'vm-request',
      },
    );

    final Map<String, Object?> vmPayload = Map<String, Object?>.from(
      vm['payload']! as Map<String, Object?>,
    )..remove('comparedAt');
    final Map<String, Object?> directPayload = Map<String, Object?>.from(
      direct['payload']! as Map<String, Object?>,
    )..remove('comparedAt');
    expect(vmPayload, directPayload);
    final Map<String, Object?> catalog = await host.dispatchCatalog();
    expect(
      (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>().map(
        (entry) => entry['name'],
      ),
      contains('ui.capture.diff'),
    );
    final Map<String, Object?> identity = await _call(
      handlers,
      PatchbayServiceHost.identityMethod,
    );
    expect(identity['features'], contains('captureAfterFrames'));
  });

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

PatchbayCaptureBridge _diffBridge(
  PatchbayArtifactService artifacts, {
  int maxPixels = 16 * 1024 * 1024,
  int maxBytes = 8 * 1024 * 1024,
}) => PatchbayCaptureBridge(
  gates: _gates,
  registry: PatchbayUiRegistry(),
  frames: PatchbayFrameObserver(),
  artifacts: artifacts,
  isAppResumed: () => true,
  maxPixels: maxPixels,
  maxBytes: maxBytes,
  decoder: _decodeFixture,
);

String _captureBlob(PatchbayArtifactService artifacts, int marker) => artifacts
    .blobs
    .put(
      Uint8List.fromList(<int>[..._pngBytes(), marker]),
      kind: PatchbayBlobSourceWire.flutterCapture,
      source: PatchbayFactSourceWire.uiObserved,
      contentType: 'image/png',
      properties: const <String, Object?>{'pixelFormat': 'rgba8888'},
    )
    .blobId;

Future<PatchbayDecodedCapture> _decodeFixture(Uint8List bytes) async {
  final int marker = bytes.last;
  if (marker == 3) {
    return PatchbayDecodedCapture(
      bytes: Uint8List.fromList(const <int>[0, 0, 0, 255]),
      width: 1,
      height: 1,
      pixelFormat: 'rgba8888',
      bytesPerPixel: 4,
    );
  }
  return PatchbayDecodedCapture(
    bytes: Uint8List.fromList(<int>[0, 0, 0, 255, marker, 1, 1, 255]),
    width: 2,
    height: 1,
    pixelFormat: 'rgba8888',
    bytesPerPixel: 4,
  );
}

/// Stands in for a boundary in a profile or release build, where the backing
/// `late` field of `debugNeedsPaint` was never assigned because the assert that
/// writes it is stripped.
class _UnreadableNeedsPaintBoundary extends RenderRepaintBoundary {
  @override
  bool get debugNeedsPaint =>
      throw StateError('debugNeedsPaint is unavailable outside debug builds.');
}

class _NeedsPaintBoundary extends RenderRepaintBoundary {
  @override
  bool get debugNeedsPaint => true;
}

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
