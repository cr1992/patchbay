import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';

import 'frame_observer.dart';
import 'inspect_bridge.dart';
import 'keep_awake_bridge.dart';
import 'lifecycle.dart';
import 'navigation_bridge.dart';
import 'reveal_bridge.dart';
import 'semantics_bridge.dart';
import 'ui_wait_bridge.dart';

part 'capture_bridge.dart';

/// A target key whose GlobalKey semantics stay identical in every build mode.
///
/// The key never retains a controller, formatter, or Widget callback. In
/// release builds its declaration and registry registration are const-pruned.
final class PatchbayKey extends GlobalKey<State<StatefulWidget>> {
  PatchbayKey.text(
    String id, {
    bool sensitive = false,
    PatchbaySideEffect sideEffect = PatchbaySideEffect.appState,
    Map<PatchbayUiOperation, Set<String>> operationGates =
        const <PatchbayUiOperation, Set<String>>{},
    PatchbayUiRegistry? registry,
  }) : declaration = kReleaseMode
           ? null
           : PatchbayUiTargetDeclaration.text(
               id: id,
               sensitive: sensitive,
               sideEffect: sideEffect,
               operationGates: operationGates,
             ),
       super.constructor() {
    if (!kReleaseMode) {
      (registry ?? PatchbayUiRegistry.instance)._register(this);
    }
  }

  PatchbayKey.capture(
    String id, {
    Set<String> gates = const <String>{},
    PatchbayUiRegistry? registry,
  }) : declaration = kReleaseMode
           ? null
           : PatchbayUiTargetDeclaration.capture(id: id, gates: gates),
       super.constructor() {
    if (!kReleaseMode) {
      (registry ?? PatchbayUiRegistry.instance)._register(this);
    }
  }

  /// Null only in release, where descriptor/operator code is unreachable.
  final PatchbayUiTargetDeclaration? declaration;

  @override
  String toString() => declaration == null
      ? '[PatchbayKey]'
      : '[PatchbayKey ${declaration!.id}]';
}

/// Weak target registry. Consumers create Keys, not registration lifecycles.
final class PatchbayUiRegistry {
  PatchbayUiRegistry();

  static final PatchbayUiRegistry instance = PatchbayUiRegistry();

  final Map<String, List<_RegistryEntry>> _entries =
      <String, List<_RegistryEntry>>{};
  final Map<String, int> _nextGenerationById = <String, int>{};

  void _register(PatchbayKey key) {
    final PatchbayUiTargetDeclaration? declaration = key.declaration;
    if (declaration == null) return;
    _entries
        .putIfAbsent(declaration.id, () => <_RegistryEntry>[])
        .add(_RegistryEntry(WeakReference<PatchbayKey>(key)));
  }

  /// Returns one entry per stable ID. Duplicate mounted targets are marked
  /// ambiguous and expose no operation.
  List<PatchbayUiTargetDescriptor> catalog() {
    final List<PatchbayUiTargetDescriptor> result =
        <PatchbayUiTargetDescriptor>[];
    final List<String> ids = _entries.keys.toList()..sort();
    for (final String id in ids) {
      final List<_ObservedTarget> live = _observe(id);
      if (live.isEmpty) continue;
      final List<_ObservedTarget> mounted = live
          .where((_ObservedTarget target) => target.element != null)
          .toList(growable: false);
      final bool ambiguous = mounted.length > 1;
      final _ObservedTarget representative = mounted.isNotEmpty
          ? mounted.first
          : live.first;
      result.add(
        _descriptor(
          representative,
          mounted: mounted.isNotEmpty,
          ambiguous: ambiguous,
          operations: ambiguous || mounted.isEmpty
              ? const <PatchbayUiOperation>{}
              : _supportedOperations(representative),
        ),
      );
    }
    return List<PatchbayUiTargetDescriptor>.unmodifiable(result);
  }

  List<_ObservedTarget> _observe(String id) {
    final List<_RegistryEntry>? entries = _entries[id];
    if (entries == null) return const <_ObservedTarget>[];
    final List<_ObservedTarget> result = <_ObservedTarget>[];
    entries.removeWhere((_RegistryEntry entry) => entry.key.target == null);
    for (final _RegistryEntry entry in entries) {
      final PatchbayKey? key = entry.key.target;
      if (key == null) continue;
      final Element? element = key.currentContext as Element?;
      final Element? previous = entry.element?.target;
      if (element == null) {
        entry.element = null;
      } else if (!identical(element, previous)) {
        entry.generation = (_nextGenerationById[id] ?? 0) + 1;
        _nextGenerationById[id] = entry.generation;
        entry.element = WeakReference<Element>(element);
      }
      result.add(
        _ObservedTarget(
          entry: entry,
          key: key,
          element: element,
          generation: entry.generation,
        ),
      );
    }
    if (entries.isEmpty) _entries.remove(id);
    return result;
  }

  _TargetResolution _resolve({
    required String id,
    required int generation,
    required PatchbayUiOperation operation,
  }) {
    final List<_ObservedTarget> live = _observe(id);
    if (live.isEmpty) {
      return const _TargetResolution.rejected('uiTargetNotFound');
    }
    final List<_ObservedTarget> mounted = live
        .where((_ObservedTarget target) => target.element != null)
        .toList(growable: false);
    if (mounted.isEmpty) {
      return const _TargetResolution.rejected('uiTargetUnmounted');
    }
    if (mounted.length > 1) {
      return const _TargetResolution.rejected('uiTargetAmbiguous');
    }
    final _ObservedTarget target = mounted.single;
    if (target.generation != generation) {
      return _TargetResolution.rejected(
        'uiGenerationStale',
        details: <String, Object?>{'currentGeneration': target.generation},
      );
    }
    if (!_supportedOperations(target).contains(operation)) {
      return const _TargetResolution.rejected('uiOperationUnavailable');
    }
    return _TargetResolution.resolved(target);
  }

  static PatchbayUiTargetDescriptor _descriptor(
    _ObservedTarget target, {
    required bool mounted,
    required bool ambiguous,
    required Set<PatchbayUiOperation> operations,
  }) {
    final PatchbayUiTargetDeclaration declaration = target.key.declaration!;
    return PatchbayUiTargetDescriptor(
      id: declaration.id,
      generation: target.generation,
      kind: declaration.kind,
      mounted: mounted,
      ambiguous: ambiguous,
      operations: Set<PatchbayUiOperation>.unmodifiable(operations),
      operationGates: declaration.operationGates,
      sensitivePolicy: declaration.sensitivePolicy,
      sideEffect: declaration.sideEffect,
    );
  }

  static Set<PatchbayUiOperation> _supportedOperations(_ObservedTarget target) {
    final PatchbayUiTargetDeclaration declaration = target.key.declaration!;
    return switch (declaration.kind) {
      PatchbayUiTargetKind.text =>
        _TextBinding.fromWidget(target.key.currentWidget) == null
            ? const <PatchbayUiOperation>{}
            : const <PatchbayUiOperation>{
                PatchbayUiOperation.textSet,
                PatchbayUiOperation.textEnter,
              },
      PatchbayUiTargetKind.capture =>
        target.element?.renderObject is RenderRepaintBoundary
            ? const <PatchbayUiOperation>{PatchbayUiOperation.capture}
            : const <PatchbayUiOperation>{},
    };
  }
}

/// Executes cataloged UI operators after base and descriptor gates.
final class PatchbayFlutterBridge {
  PatchbayFlutterBridge({
    required PatchbayGateEvaluator gates,
    PatchbayUiRegistry? registry,
    PatchbaySemanticsActionPolicy? semanticsActionPolicy,
    PatchbayGesturePolicy? gesturePolicy,
    PatchbayPointerEventDispatcher? gesturePointerDispatcher,
    PatchbayGestureDelay? gestureDelay,
    PatchbayRevealPolicy? revealPolicy,
    PatchbayNavigationAdapter? navigationAdapter,
    PatchbayInspectPolicy? inspectPolicy,
    PatchbayInspectorSurface? inspectorSurface,
    this.artifacts,
    Set<String> captureGates = const <String>{},
    PatchbayKeepAwakeDelegate? keepAwakeDelegate,
    Set<String> keepAwakeGates = const <String>{},
    PatchbayRootController? rootController,
    PatchbayCaptureEncoder? captureEncoder,
    PatchbayCaptureDecoder? captureDecoder,
    bool Function()? isAppResumed,
    PatchbayLifecycleStateReader? lifecycleState,
    String Function()? newRequestId,
  }) : _gates = gates,
       _registry = registry ?? PatchbayUiRegistry.instance,
       _newRequestId = newRequestId ?? _defaultRequestId,
       _isAppResumed = isAppResumed ?? _defaultIsAppResumed,
       _lifecycleState = patchbayLifecycleReaderFor(
         isAppResumed: isAppResumed,
         lifecycleState: lifecycleState,
       ),
       _frames = PatchbayFrameObserver() {
    keepAwake = PatchbayKeepAwakeBridge(
      gates: gates,
      delegate: keepAwakeDelegate,
      gateIds: keepAwakeGates,
      isAppResumed: _isAppResumed,
      lifecycleState: _lifecycleState,
      newRequestId: newRequestId,
    );
    semantics = PatchbaySemanticsBridge(
      gates: gates,
      actionPolicy: semanticsActionPolicy,
      // PB-050-07：owner 恢复帧与 `ui.wait` / reveal / navigation 共用一个计数器，
      // 所以「实际驱动的帧」与 `frameRevision` 报告的帧是同一个集合。
      frames: _frames,
      isAppResumed: _isAppResumed,
      lifecycleState: _lifecycleState,
      newRequestId: newRequestId,
    );
    gesture = PatchbayGestureBridge(
      gates: gates,
      semantics: semantics,
      policy: gesturePolicy,
      pointerDispatcher: gesturePointerDispatcher,
      delay: gestureDelay,
      isAppResumed: _isAppResumed,
      lifecycleState: _lifecycleState,
      newRequestId: newRequestId,
    );
    reveal = PatchbayRevealBridge(
      gates: gates,
      semantics: semantics,
      frames: _frames,
      policy: revealPolicy,
      isAppResumed: _isAppResumed,
      lifecycleState: _lifecycleState,
      newRequestId: newRequestId,
    );
    navigation = navigationAdapter == null
        ? null
        : PatchbayNavigationBridge(
            gates: gates,
            adapter: navigationAdapter,
            frames: _frames,
            isAppResumed: _isAppResumed,
            lifecycleState: _lifecycleState,
            newRequestId: newRequestId,
          );
    wait = PatchbayUiWaitBridge(
      gates: gates,
      semantics: semantics,
      frames: _frames,
      isAppResumed: _isAppResumed,
      lifecycleState: _lifecycleState,
      navigation: navigation,
      newRequestId: newRequestId,
    );
    inspect = inspectPolicy == null
        ? null
        : PatchbayInspectBridge(
            gates: gates,
            policy: inspectPolicy,
            surface: inspectorSurface,
          );
    capture = artifacts == null
        ? null
        : PatchbayCaptureBridge(
            gates: gates,
            registry: _registry,
            frames: _frames,
            artifacts: artifacts!,
            gateIds: captureGates,
            root: rootController,
            isAppResumed: _isAppResumed,
            lifecycleState: _lifecycleState,
            encoder: captureEncoder,
            decoder: captureDecoder,
          );
  }

  final PatchbayGateEvaluator _gates;

  /// The one evaluator every plane of this host shares.
  ///
  /// `PatchbayFlutterServiceHost` reads it to admit consumer-owned domain
  /// writes through the same base and consumer gates the UI operators already
  /// cross. It is exposed rather than injected a second time on purpose: one
  /// gate ID must mean one thing, and a host that could enforce gates on the
  /// UI plane while leaving the domain plane open would turn the gap this seam
  /// closes into a configuration option.
  PatchbayGateEvaluator get gates => _gates;

  final PatchbayArtifactService? artifacts;
  final PatchbayUiRegistry _registry;
  final String Function() _newRequestId;
  final bool Function() _isAppResumed;
  final PatchbayLifecycleStateReader _lifecycleState;
  final PatchbayFrameObserver _frames;
  late final PatchbaySemanticsBridge semantics;
  late final PatchbayGestureBridge gesture;

  /// PB-050-17：identifier 锚定的 scroll-to-reveal。
  ///
  /// 总是构造，但 `enabled` 只有在接入方注入了 `revealPolicy` 时才为真——命令
  /// 的注册按 `enabled`，所以没写下授权的 App 连 catalog 里都看不到它。
  late final PatchbayRevealBridge reveal;
  late final PatchbayNavigationBridge? navigation;
  late final PatchbayUiWaitBridge wait;
  late final PatchbayCaptureBridge? capture;

  /// Always present, unlike [capture] and [navigation].
  ///
  /// Those two are absent from the catalog when a consumer injects nothing,
  /// which is the right answer for a capability the App simply chose not to
  /// expose. Keep-awake is the one an operator reaches for *because* the UI
  /// plane just stopped answering, so it stays cataloged and says `wired:
  /// false` — a diagnosis instead of a missing row.
  late final PatchbayKeepAwakeBridge keepAwake;

  /// Non-null only when the consumer opted into the widget inspector switch.
  late final PatchbayInspectBridge? inspect;

  static int _nextRequest = 0;
  static String _defaultRequestId() => 'patchbay-ui-${++_nextRequest}';
  static bool _defaultIsAppResumed() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  int get frameRevision => _frames.revision;

  List<PatchbayUiTargetDescriptor> catalog() => _registry.catalog();

  Future<PatchbayInvocation> setText({
    required String id,
    required int generation,
    required String text,
    bool inputWasStdin = false,
    String? requestId,
  }) => _applyText(
    id: id,
    generation: generation,
    text: text,
    inputWasStdin: inputWasStdin,
    operation: PatchbayUiOperation.textSet,
    requestId: requestId ?? _newRequestId(),
  );

  Future<PatchbayInvocation> enterText({
    required String id,
    required int generation,
    required String text,
    bool inputWasStdin = false,
    String? requestId,
  }) => _applyText(
    id: id,
    generation: generation,
    text: text,
    inputWasStdin: inputWasStdin,
    operation: PatchbayUiOperation.textEnter,
    requestId: requestId ?? _newRequestId(),
  );

  Future<PatchbayInvocation> _applyText({
    required String id,
    required int generation,
    required String text,
    required bool inputWasStdin,
    required PatchbayUiOperation operation,
    required String requestId,
  }) async {
    _TargetResolution resolution = _registry._resolve(
      id: id,
      generation: generation,
      operation: operation,
    );
    if (!resolution.resolved) {
      return _rejected(requestId, resolution);
    }

    final PatchbayUiTargetDeclaration declaration =
        resolution.target!.key.declaration!;
    if (declaration.sensitivePolicy == PatchbaySensitivePolicy.redacted &&
        !inputWasStdin) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(
          code: 'sensitiveInputRequiresStdin',
          notice: 'Sensitive UI text is accepted only from stdin.',
        ),
      );
    }

    final PatchbayGateRejection? gate = await _gates.evaluate(
      declaration.gatesFor(operation),
    );
    if (gate != null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: gate.code,
          notice: gate.notice,
          details: <String, Object?>{'gateId': gate.gateId},
        ),
      );
    }

    // A gate may await. Resolve again so a remounted target or newly introduced
    // duplicate cannot receive the continuation meant for the old generation.
    resolution = _registry._resolve(
      id: id,
      generation: generation,
      operation: operation,
    );
    if (!resolution.resolved) {
      return _rejected(requestId, resolution);
    }

    final _ObservedTarget target = resolution.target!;
    final _TextBinding? binding = _TextBinding.fromWidget(
      target.key.currentWidget,
    );
    if (binding == null) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'uiOperationUnavailable'),
      );
    }

    try {
      final TextEditingValue next = switch (operation) {
        PatchbayUiOperation.textSet => _replacement(text),
        PatchbayUiOperation.textEnter => binding.format(text),
        PatchbayUiOperation.capture => throw StateError(
          'capture is not a text operation',
        ),
      };
      binding.controller.value = next;
      if (operation == PatchbayUiOperation.textEnter) {
        binding.onChanged?.call(next.text);
      }
      return PatchbayInvocation.accepted(
        requestId: requestId,
        payload: <String, Object?>{
          'outcome': 'applied',
          'source': 'uiObserved',
          'targetId': id,
          'generation': generation,
          'operation': operation.wireName,
          if (declaration.sensitivePolicy == PatchbaySensitivePolicy.redacted)
            'valueRedacted': true
          else
            'value': next.text,
          'length': next.text.length,
        },
      );
    } catch (error) {
      return PatchbayInvocation.accepted(
        requestId: requestId,
        payload: <String, Object?>{
          'outcome': 'failed',
          'source': 'uiObserved',
          'targetId': id,
          'generation': generation,
          'operation': operation.wireName,
          'failureType': error.runtimeType.toString(),
        },
      );
    }
  }

  static TextEditingValue _replacement(String text) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  static PatchbayInvocation _rejected(
    String requestId,
    _TargetResolution resolution,
  ) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(
      code: resolution.code!,
      details: resolution.details,
    ),
  );

  void dispose() {
    // Before the semantics teardown, so a live hold is given back even if that
    // one throws: the screen staying lit is the failure a consumer cannot see.
    keepAwake.dispose();
    // The inspector switch is App state Patchbay installed, so tearing the
    // bridge down puts it back rather than leaving the device in select mode.
    inspect?.dispose();
    semantics.dispose();
  }
}

final class _TextBinding {
  const _TextBinding({
    required this.controller,
    required this.inputFormatters,
    required this.onChanged,
  });

  static _TextBinding? fromWidget(Widget? widget) {
    if (widget is TextField) {
      final TextEditingController? controller = widget.controller;
      if (controller == null) return null;
      return _TextBinding(
        controller: controller,
        inputFormatters: widget.inputFormatters ?? const <TextInputFormatter>[],
        onChanged: widget.onChanged,
      );
    }
    if (widget is EditableText) {
      return _TextBinding(
        controller: widget.controller,
        inputFormatters: widget.inputFormatters ?? const <TextInputFormatter>[],
        onChanged: widget.onChanged,
      );
    }
    return null;
  }

  final TextEditingController controller;
  final List<TextInputFormatter> inputFormatters;
  final ValueChanged<String>? onChanged;

  TextEditingValue format(String text) {
    final TextEditingValue oldValue = controller.value;
    TextEditingValue next = PatchbayFlutterBridge._replacement(text);
    for (final TextInputFormatter formatter in inputFormatters) {
      next = formatter.formatEditUpdate(oldValue, next);
    }
    return next;
  }
}

final class _RegistryEntry {
  _RegistryEntry(this.key);

  final WeakReference<PatchbayKey> key;
  WeakReference<Element>? element;
  int generation = 0;
}

final class _ObservedTarget {
  const _ObservedTarget({
    required this.entry,
    required this.key,
    required this.element,
    required this.generation,
  });

  final _RegistryEntry entry;
  final PatchbayKey key;
  final Element? element;
  final int generation;
}

final class _TargetResolution {
  const _TargetResolution.resolved(_ObservedTarget this.target)
    : code = null,
      details = const <String, Object?>{};

  const _TargetResolution.rejected(
    String this.code, {
    this.details = const <String, Object?>{},
  }) : target = null;

  final _ObservedTarget? target;
  final String? code;
  final Map<String, Object?> details;

  bool get resolved => target != null;
}
