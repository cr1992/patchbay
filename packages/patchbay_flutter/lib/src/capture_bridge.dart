part of 'flutter_bridge.dart';

typedef PatchbayCaptureEncoder =
    Future<PatchbayEncodedCapture> Function(
      RenderRepaintBoundary boundary,
      double pixelRatio,
    );

typedef PatchbayCaptureDecoder =
    Future<PatchbayDecodedCapture> Function(Uint8List bytes);

/// Optional composition-root wrapper. In release this is exactly its child;
/// in other modes it adds only a repaint boundary and no layout/state widget.
final class PatchbayRoot extends StatelessWidget {
  const PatchbayRoot({required this.child, this.controller, super.key});

  final Widget child;
  final PatchbayRootController? controller;

  @override
  Widget build(BuildContext context) {
    return buildForMode(
      child: child,
      controller: controller ?? PatchbayRootController.instance,
      enabled: !kReleaseMode,
    );
  }

  @visibleForTesting
  static Widget buildForMode({
    required Widget child,
    required PatchbayRootController controller,
    required bool enabled,
  }) => enabled ? RepaintBoundary(key: controller._key, child: child) : child;
}

final class PatchbayRootController {
  PatchbayRootController();

  static final PatchbayRootController instance = PatchbayRootController();

  final GlobalKey _key = GlobalKey(debugLabel: 'PatchbayRoot');

  RenderRepaintBoundary? get _boundary =>
      _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
}

/// Captures only Flutter-composited repaint boundaries and stores PNG bytes in
/// the shared bounded blob store.
final class PatchbayCaptureBridge {
  PatchbayCaptureBridge({
    required PatchbayGateEvaluator gates,
    required PatchbayUiRegistry registry,
    required PatchbayFrameObserver frames,
    required PatchbayArtifactService artifacts,
    Set<String> gateIds = const <String>{},
    PatchbayRootController? root,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    PatchbayCaptureEncoder? encoder,
    PatchbayCaptureDecoder? decoder,
    this.maxPixels = 16 * 1024 * 1024,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxPixelRatio = 3,
    this.defaultTimeout = const Duration(seconds: 5),
  }) : _gates = gates,
       _registry = registry,
       _frames = frames,
       _artifacts = artifacts,
       _gateIds = Set<String>.unmodifiable(gateIds),
       _root = root ?? PatchbayRootController.instance,
       _isAppResumed =
           isAppResumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed),
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _encoder = encoder ?? _encode,
       _decoder = decoder ?? _decode {
    if (maxPixels <= 0 ||
        maxBytes <= 0 ||
        maxPixelRatio <= 0 ||
        defaultTimeout <= Duration.zero) {
      throw ArgumentError('Capture limits must be positive.');
    }
  }

  final PatchbayGateEvaluator _gates;
  final PatchbayUiRegistry _registry;
  final PatchbayFrameObserver _frames;
  final PatchbayArtifactService _artifacts;
  final Set<String> _gateIds;
  final PatchbayRootController _root;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final PatchbayCaptureEncoder _encoder;
  final PatchbayCaptureDecoder _decoder;
  final int maxPixels;
  final int maxBytes;
  final double maxPixelRatio;
  final Duration defaultTimeout;

  Set<String> get gateIds => _gateIds;

  static const int maxAfterFrames = 120;

  Future<PatchbayInvocation> capture(
    PatchbayCaptureRequestWire request, {
    required String requestId,
  }) async {
    final Duration timeout = request.timeoutMs == null
        ? defaultTimeout
        : Duration(milliseconds: request.timeoutMs!);
    final double pixelRatio = request.pixelRatio?.toDouble() ?? 1;
    final int requestedFrames = request.afterFrames ?? 1;
    final List<String> outOfRange = <String>[
      if (timeout <= Duration.zero || timeout > const Duration(seconds: 30))
        'timeoutMs',
      if (!pixelRatio.isFinite || pixelRatio <= 0 || pixelRatio > maxPixelRatio)
        'pixelRatio',
      if (requestedFrames <= 0 || requestedFrames > maxAfterFrames)
        'afterFrames',
    ];
    if (outOfRange.isNotEmpty) {
      // Which bound was crossed, and what the bound is. Both are declared in
      // the catalog already; repeating them here saves the caller a round trip
      // through the descriptor to find out why a plausible number was refused.
      return _reject(
        requestId,
        'invalidCaptureArguments',
        details: <String, Object?>{
          'invalid': outOfRange,
          'maxTimeoutMs': const Duration(seconds: 30).inMilliseconds,
          'maxPixelRatio': maxPixelRatio,
          'maxAfterFrames': maxAfterFrames,
        },
      );
    }
    if (!_isAppResumed()) {
      return _reject(
        requestId,
        'captureLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }
    final _CaptureResolution before = _resolve(request);
    if (!before.resolved) return _rejectResolution(requestId, before);

    final Set<String> gates = <String>{..._gateIds, ...before.gates};
    final PatchbayGateRejection? gate = await _gates.evaluate(gates);
    if (gate != null) {
      return _reject(
        requestId,
        gate.code,
        details: <String, Object?>{'gateId': gate.gateId},
        notice: gate.notice,
      );
    }
    if (!_isAppResumed()) {
      return _reject(
        requestId,
        'captureLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }
    final DateTime deadline = DateTime.now().add(timeout);
    final int observedFrames = await _frames.framesBefore(
      deadline,
      requestedFrames,
    );
    if (observedFrames != requestedFrames) {
      return _reject(
        requestId,
        'captureFrameTimeout',
        details: <String, Object?>{
          'requestedFrames': requestedFrames,
          'observedFrames': observedFrames,
        },
      );
    }
    if (!_isAppResumed()) {
      return _reject(
        requestId,
        'captureLifecycleNotResumed',
        details: patchbayLifecycleDetails(_lifecycleState),
      );
    }
    final _CaptureResolution after = _resolve(request);
    if (!after.resolved) return _rejectResolution(requestId, after);
    if (!identical(before.boundary, after.boundary)) {
      return _reject(requestId, 'captureTargetChanged');
    }

    final RenderRepaintBoundary boundary = after.boundary!;
    if (needsPaintForMode(boundary, isDebugBuild: kDebugMode) ||
        !boundary.hasSize ||
        boundary.size.isEmpty) {
      return _reject(requestId, 'captureTargetNotPainted');
    }
    final int expectedWidth = (boundary.size.width * pixelRatio).ceil();
    final int expectedHeight = (boundary.size.height * pixelRatio).ceil();
    if (expectedWidth <= 0 ||
        expectedHeight <= 0 ||
        expectedWidth * expectedHeight > maxPixels) {
      return _reject(
        requestId,
        'capturePixelLimitExceeded',
        details: <String, Object?>{
          'width': expectedWidth,
          'height': expectedHeight,
          'maxPixels': maxPixels,
        },
      );
    }

    final Duration encodingRemaining = deadline.difference(DateTime.now());
    if (encodingRemaining <= Duration.zero) {
      return _reject(requestId, 'captureEncodingTimeout');
    }
    final PatchbayEncodedCapture encoded;
    try {
      encoded = await _encoder(boundary, pixelRatio).timeout(encodingRemaining);
    } on TimeoutException {
      return _reject(requestId, 'captureEncodingTimeout');
    } on Object {
      return _reject(requestId, 'captureEncodingFailed');
    }
    if (!_isPng(encoded.bytes) ||
        encoded.width <= 0 ||
        encoded.height <= 0 ||
        encoded.width * encoded.height > maxPixels) {
      return _reject(requestId, 'captureEncodingFailed');
    }
    if (encoded.bytes.length > maxBytes) {
      return _reject(
        requestId,
        'captureByteLimitExceeded',
        details: <String, Object?>{
          'length': encoded.bytes.length,
          'maxBytes': maxBytes,
        },
      );
    }

    final PatchbayBlobMetadataWire blob;
    try {
      blob = _artifacts.blobs.put(
        encoded.bytes,
        kind: PatchbayBlobSourceWire.flutterCapture,
        source: PatchbayFactSourceWire.uiObserved,
        contentType: 'image/png',
        filename: request.targetId == null
            ? 'patchbay-root.png'
            : 'patchbay-${request.targetId}.png',
        properties: <String, Object?>{
          'width': encoded.width,
          'height': encoded.height,
          'pixelRatio': pixelRatio,
          'pixelFormat': 'rgba8888',
        },
      );
    } on PatchbayBlobFailure catch (failure) {
      return _reject(requestId, switch (failure.code) {
        PatchbayBlobFailureCode.capacityExceeded => 'blobCapacityExceeded',
        PatchbayBlobFailureCode.blobTooLarge => 'blobTooLarge',
        _ => 'blobAdmissionFailed',
      }, details: failure.details);
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: PatchbayCaptureResultWire(
        outcome: 'captured',
        source: PatchbayFactSourceWire.uiObserved,
        target: request.targetId == null
            ? PatchbayCaptureTargetWire.root
            : PatchbayCaptureTargetWire.registeredTarget,
        targetId: request.targetId,
        generation: request.generation,
        width: encoded.width,
        height: encoded.height,
        pixelRatio: pixelRatio,
        pixelFormat: 'rgba8888',
        capturedAt: blob.createdAt,
        requestedFrames: requestedFrames,
        observedFrames: observedFrames,
        maxPixels: maxPixels,
        maxBytes: maxBytes,
        warnings: const <PatchbayCaptureWarningWire>[
          PatchbayCaptureWarningWire.flutterSubtreeOnly,
          PatchbayCaptureWarningWire.platformViewsMayBeMissing,
          PatchbayCaptureWarningWire.systemUiNotIncluded,
        ],
        blob: blob,
      ).toJson(),
    );
  }

  /// Compares two capture artifacts after decoding both to RGBA8888.
  ///
  /// The comparison is deliberately a fact, not a verdict: callers own any
  /// pass/fail threshold. Both inputs remain bounded by the same limits as
  /// capture and the result stays in this command payload rather than adding
  /// fields to the strictly decoded blob metadata wire type.
  Future<PatchbayInvocation> diff(
    PatchbayCaptureDiffRequestWire request, {
    required String requestId,
  }) async {
    final PatchbayGateRejection? gate = await _gates.evaluate(_gateIds);
    if (gate != null) {
      return _reject(
        requestId,
        gate.code,
        details: <String, Object?>{'gateId': gate.gateId},
        notice: gate.notice,
      );
    }
    final PatchbayBlobMetadataWire beforeMetadata;
    final PatchbayBlobMetadataWire afterMetadata;
    try {
      beforeMetadata = _artifacts.blobs.metadata(request.beforeBlobId);
      afterMetadata = _artifacts.blobs.metadata(request.afterBlobId);
    } on PatchbayBlobFailure catch (failure) {
      return _reject(requestId, switch (failure.code) {
        PatchbayBlobFailureCode.expired => 'captureDiffArtifactExpired',
        PatchbayBlobFailureCode.notFound => 'captureDiffArtifactNotFound',
        _ => 'captureDiffArtifactUnavailable',
      }, details: failure.details);
    }
    for (final PatchbayBlobMetadataWire metadata in <PatchbayBlobMetadataWire>[
      beforeMetadata,
      afterMetadata,
    ]) {
      if (metadata.kind != PatchbayBlobSourceWire.flutterCapture ||
          metadata.contentType != 'image/png') {
        return _reject(
          requestId,
          'captureDiffArtifactUnsupported',
          details: <String, Object?>{'blobId': metadata.blobId},
        );
      }
      if (metadata.length > maxBytes) {
        return _reject(
          requestId,
          'captureDiffByteLimitExceeded',
          details: <String, Object?>{
            'blobId': metadata.blobId,
            'length': metadata.length,
            'maxBytes': maxBytes,
          },
        );
      }
    }

    final PatchbayDecodedCapture before;
    final PatchbayDecodedCapture after;
    try {
      before = await _decoder(_readBlob(beforeMetadata));
      after = await _decoder(_readBlob(afterMetadata));
    } on PatchbayBlobFailure catch (failure) {
      return _reject(
        requestId,
        'captureDiffArtifactUnavailable',
        details: failure.details,
      );
    } on Object {
      return _reject(requestId, 'captureDiffDecodeFailed');
    }
    for (final PatchbayDecodedCapture image in <PatchbayDecodedCapture>[
      before,
      after,
    ]) {
      final int pixels = image.width * image.height;
      if (image.width <= 0 ||
          image.height <= 0 ||
          pixels > maxPixels ||
          image.bytesPerPixel <= 0 ||
          image.bytes.length != pixels * image.bytesPerPixel) {
        return _reject(
          requestId,
          'captureDiffPixelLimitExceeded',
          details: <String, Object?>{
            'width': image.width,
            'height': image.height,
            'maxPixels': maxPixels,
          },
        );
      }
    }
    if (before.width != after.width ||
        before.height != after.height ||
        before.pixelFormat != after.pixelFormat ||
        before.bytesPerPixel != after.bytesPerPixel) {
      return _reject(
        requestId,
        'captureDiffSpecMismatch',
        details: <String, Object?>{'before': before.spec, 'after': after.spec},
      );
    }

    final int totalPixels = before.width * before.height;
    var changedPixels = 0;
    for (var pixel = 0; pixel < totalPixels; pixel += 1) {
      final int offset = pixel * before.bytesPerPixel;
      var changed = false;
      for (var byte = 0; byte < before.bytesPerPixel; byte += 1) {
        if (before.bytes[offset + byte] != after.bytes[offset + byte]) {
          changed = true;
          break;
        }
      }
      if (changed) changedPixels += 1;
    }
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: PatchbayCaptureDiffResultWire(
        outcome: 'compared',
        source: PatchbayFactSourceWire.uiObserved,
        beforeBlobId: request.beforeBlobId,
        afterBlobId: request.afterBlobId,
        width: before.width,
        height: before.height,
        pixelFormat: before.pixelFormat,
        changedPixels: changedPixels,
        totalPixels: totalPixels,
        differenceRatio: changedPixels / totalPixels,
        comparedAt: DateTime.now().toUtc().toIso8601String(),
        maxPixels: maxPixels,
        maxBytes: maxBytes,
        warnings: const <PatchbayCaptureWarningWire>[
          PatchbayCaptureWarningWire.flutterSubtreeOnly,
          PatchbayCaptureWarningWire.platformViewsMayBeMissing,
          PatchbayCaptureWarningWire.systemUiNotIncluded,
        ],
      ).toJson(),
    );
  }

  Uint8List _readBlob(PatchbayBlobMetadataWire metadata) {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < metadata.length) {
      final PatchbayBlobChunkWire chunk = _artifacts.blobs.read(
        blobId: metadata.blobId,
        offset: offset,
        limit: _artifacts.blobs.maxChunkBytes,
      );
      bytes.add(base64Decode(chunk.dataBase64));
      if (chunk.nextOffset <= offset) {
        throw const PatchbayBlobFailure(
          PatchbayBlobFailureCode.offsetOutOfBounds,
        );
      }
      offset = chunk.nextOffset;
    }
    return bytes.takeBytes();
  }

  _CaptureResolution _resolve(PatchbayCaptureRequestWire request) {
    final String? targetId = request.targetId;
    if (targetId == null) {
      if (request.generation != null) {
        return const _CaptureResolution.rejected(
          'captureGenerationWithoutTarget',
        );
      }
      final RenderRepaintBoundary? boundary = _root._boundary;
      return boundary == null
          ? const _CaptureResolution.rejected('captureRootNotMounted')
          : _CaptureResolution.resolved(boundary);
    }
    final int? generation = request.generation;
    if (generation == null) {
      return const _CaptureResolution.rejected(
        'captureTargetGenerationRequired',
      );
    }
    final _TargetResolution resolution = _registry._resolve(
      id: targetId,
      generation: generation,
      operation: PatchbayUiOperation.capture,
    );
    if (!resolution.resolved) {
      return _CaptureResolution.rejected(
        resolution.code!,
        details: resolution.details,
      );
    }
    final RenderObject? renderObject = resolution.target!.element?.renderObject;
    if (renderObject is! RenderRepaintBoundary) {
      return const _CaptureResolution.rejected('uiOperationUnavailable');
    }
    return _CaptureResolution.resolved(
      renderObject,
      gates: resolution.target!.key.declaration!.gatesFor(
        PatchbayUiOperation.capture,
      ),
    );
  }

  /// Whether the boundary still owes a paint, to the extent the build mode can
  /// answer that at all.
  ///
  /// `RenderObject.debugNeedsPaint` is debug-only: it returns a `late` field
  /// assigned inside an `assert`, so profile and release strip the assignment
  /// and reading it throws `LateInitializationError`. Capture is supported
  /// outside debug — [PatchbayRoot] wraps the root boundary whenever
  /// `!kReleaseMode` — so outside debug this answers "cannot tell" rather than
  /// letting that error escape the bridge as an untyped host failure. Nothing
  /// is silently admitted: a boundary that really has not painted still fails
  /// closed one step later, where `toImage` throws and capture rejects with
  /// `captureEncodingFailed`.
  @visibleForTesting
  static bool needsPaintForMode(
    RenderRepaintBoundary boundary, {
    required bool isDebugBuild,
  }) => isDebugBuild && boundary.debugNeedsPaint;

  static Future<PatchbayEncodedCapture> _encode(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) async {
    final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) throw StateError('PNG encoder returned no data.');
      return PatchbayEncodedCapture(
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }

  static Future<PatchbayDecodedCapture> _decode(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      try {
        final ByteData? data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null) throw StateError('RGBA decoder returned no data.');
        return PatchbayDecodedCapture(
          bytes: data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          width: frame.image.width,
          height: frame.image.height,
          pixelFormat: 'rgba8888',
          bytesPerPixel: 4,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  static bool _isPng(Uint8List bytes) {
    const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index += 1) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static PatchbayInvocation _rejectResolution(
    String requestId,
    _CaptureResolution resolution,
  ) => _reject(requestId, resolution.code!, details: resolution.details);

  static PatchbayInvocation _reject(
    String requestId,
    String code, {
    Map<String, Object?> details = const <String, Object?>{},
    String? notice,
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  );
}

final class PatchbayEncodedCapture {
  const PatchbayEncodedCapture({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

final class PatchbayDecodedCapture {
  const PatchbayDecodedCapture({
    required this.bytes,
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String pixelFormat;
  final int bytesPerPixel;

  Map<String, Object?> get spec => <String, Object?>{
    'width': width,
    'height': height,
    'pixelFormat': pixelFormat,
  };
}

final class _CaptureResolution {
  const _CaptureResolution.resolved(
    RenderRepaintBoundary this.boundary, {
    this.gates = const <String>{},
  }) : code = null,
       details = const <String, Object?>{};

  const _CaptureResolution.rejected(
    String this.code, {
    this.details = const <String, Object?>{},
  }) : boundary = null,
       gates = const <String>{};

  final RenderRepaintBoundary? boundary;
  final Set<String> gates;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => boundary != null;
}
