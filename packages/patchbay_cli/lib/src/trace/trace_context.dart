import 'dart:async';

import '../trace.dart';

/// Zone symbol keys for ambient trace context.
abstract final class PatchbayTraceZoneKeys {
  static const Symbol initialized = #patchbayTraceZoneInitialized;
  static const Symbol recorder = #patchbayTraceRecorder;
  static const Symbol includeLegacyPayload = #patchbayTraceIncludeLegacyPayload;
}

/// Helper for accessing ambient trace state from the current Zone.
abstract final class PatchbayTraceContext {
  static PatchbayTraceRecorder? get currentRecorder =>
      Zone.current[PatchbayTraceZoneKeys.recorder] as PatchbayTraceRecorder?;

  static bool get includesLegacyPayload =>
      Zone.current[PatchbayTraceZoneKeys.includeLegacyPayload] == true;

  static bool get isInitialized =>
      Zone.current[PatchbayTraceZoneKeys.initialized] == true;
}
