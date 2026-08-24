// 拆分前 `trace.dart` 的公共面。domain 目录里的类型是拆分产物，
// 不因为被拆出来就成为公共 API——这里用 show 显式声明兼容面。
export 'trace/trace_models.dart'
    show
        PatchbayTraceEvent,
        PatchbayTraceException,
        PatchbayTraceManifest,
        PatchbayTracePruneResult,
        PatchbayTraceReadResult,
        defaultPatchbayTraceDirectory,
        patchbayTraceMaxAge,
        patchbayTraceMaxArtifactBytes,
        patchbayTraceMaxCount,
        patchbayTraceMaxEventBytes,
        patchbayTraceMaxTotalBytes,
        patchbayTraceSchemaVersion,
        patchbayTraceWriterEventTypes;
export 'trace/trace_recorder.dart' show PatchbayTraceRecorder;
export 'trace/trace_store.dart';
