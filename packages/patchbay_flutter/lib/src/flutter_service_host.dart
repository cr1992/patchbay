import 'package:patchbay/patchbay.dart';

import 'flutter_bridge.dart';
import 'inspect_bridge.dart';
import 'keep_awake_bridge.dart';
import 'semantics_bridge.dart';

/// Registers the Flutter UI catalog and operators on the generic host.
final class PatchbayFlutterServiceHost {
  PatchbayFlutterServiceHost({
    required String applicationId,
    required PatchbayFlutterBridge bridge,
    PatchbayCatalogSource? domainCatalog,
    PatchbaySnapshotSource? snapshot,
    PatchbayInvocationSource? domainInvoke,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    PatchbayAuditSink? auditSink,
    PatchbayAuditSinkErrorHandler? onAuditSinkError,
  }) : _host = PatchbayServiceHost(
         applicationId: applicationId,
         appInstanceId: appInstanceId,
         registrar: registrar,
         auditSink: auditSink,
         onAuditSinkError: onAuditSinkError,
         registry: PatchbayCommandRegistry.combine(<PatchbayCommandRegistry>[
           _uiCommandRegistry(bridge),
           if (bridge.artifacts case final PatchbayArtifactService artifacts)
             artifacts.registry,
         ]),
         catalog: () async {
           final Map<String, Object?> domain =
               await domainCatalog?.call() ?? const <String, Object?>{};
           return <String, Object?>{
             ...domain,
             'uiTargets': bridge
                 .catalog()
                 .map((PatchbayUiTargetDescriptor target) => target.toJson())
                 .toList(growable: false),
           };
         },
         snapshot: snapshot ?? () async => const <String, Object?>{},
         invoke:
             domainInvoke ??
             (command, arguments, requestId) async =>
                 PatchbayInvocation.rejected(
                   requestId: requestId,
                   rejection: PatchbayRejection(
                     code: 'commandNotRegistered',
                     details: <String, Object?>{'command': command},
                   ),
                 ).toJson(),
         // The lifecycle gate lives in this package, so this is the layer that
         // can promise a `*LifecycleNotResumed` rejection carries the engine
         // state separating "wake the screen" from "click the window". A pure
         // Dart host has no such gate and declares nothing, which is what lets
         // a client tell "this host does not report it" apart from "this App
         // reported unknown".
         features: const <PatchbayFeature>{PatchbayFeature.lifecycleState},
       );

  final PatchbayServiceHost _host;

  String get applicationId => _host.applicationId;

  String get appInstanceId => _host.appInstanceId;

  int get schemaVersion => PatchbayServiceHost.schemaVersion;

  List<PatchbayAuditEvent> get auditEvents => _host.auditEvents;

  Future<Map<String, Object?>> dispatchCatalog() => _host.dispatchCatalog();

  Future<Map<String, Object?>> dispatchSnapshot([
    Map<String, Object?>? request,
  ]) => _host.dispatchSnapshot(request);

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) => _host.dispatchInvoke(command, arguments, requestId);

  void register() => _host.register();

  /// `invalidUiArguments`, naming what is actually wrong with the request.
  ///
  /// A bare `invalidUiArguments` says only that *something* about the arguments
  /// is unacceptable, which leaves the caller to bisect their own request key by
  /// key. `details` names it instead: `missing` for a declared parameter the
  /// request left out, `unexpected` for a key the command does not declare,
  /// `invalid` for a declared key whose value has the wrong type or an
  /// undeclared enum value, and `reason` for a shape rule no single key can
  /// express (`ui.wait` conditions require different companions).
  ///
  /// Only parameter *names* travel. They are protocol vocabulary published in
  /// the catalog; the values are caller data and may be sensitive, so they stay
  /// out of the envelope exactly as they do everywhere else.
  ///
  /// [strictKeys] says whether this call site actually refuses undeclared keys.
  /// The sites that do not — `exec`-style commands that forward `--args`
  /// wholesale — must not have unrelated keys listed as if they were the reason.
  static Map<String, Object?> _invalidUiArguments(
    String requestId,
    String command,
    Map<String, Object?> arguments, {
    bool strictKeys = false,
    String? reason,
    String? notice,
  }) {
    final _UiArgumentShape? shape = _uiArgumentShapes[command];
    final List<String> missing = shape?.missing(arguments) ?? const <String>[];
    final List<String> unexpected = strictKeys
        ? shape?.unexpected(arguments) ?? const <String>[]
        : const <String>[];
    final List<String> invalid = shape?.invalid(arguments) ?? const <String>[];
    return PatchbayInvocation.rejected(
      requestId: requestId,
      rejection: PatchbayRejection(
        code: 'invalidUiArguments',
        notice: notice,
        details: <String, Object?>{
          'command': command,
          if (missing.isNotEmpty) 'missing': missing,
          if (unexpected.isNotEmpty) 'unexpected': unexpected,
          if (invalid.isNotEmpty) 'invalid': invalid,
          'reason': ?reason,
        },
      ),
    ).toJson();
  }

  /// A rejection reason that names the rule without echoing a value.
  ///
  /// The wire decoders and `PatchbayUiWaitRequest` already phrase their own
  /// failures in protocol vocabulary — field paths, expected types, which
  /// companion a condition needs — so their `FormatException` message is exactly
  /// the sentence the caller needs. Anything else is reported as its type only:
  /// an `ArgumentError.toString()` embeds the offending value, and no caller
  /// value belongs in a response envelope.
  static String _decodeFailureReason(Object failure) => switch (failure) {
    FormatException(:final String message) => message,
    ArgumentError(:final Object? name) when name is String =>
      '$name is out of the accepted range',
    _ => failure.runtimeType.toString(),
  };

  static PatchbayCommandRegistry _uiCommandRegistry(
    PatchbayFlutterBridge bridge,
  ) {
    final Iterator<PatchbayCommandDescriptor> descriptors =
        _uiCommandDescriptors(
          semanticsActionsEnabled: true,
          navigationEnabled: true,
          captureEnabled: true,
          captureGates: bridge.capture?.gateIds ?? const <String>{},
          keepAwakeGates: bridge.keepAwake.gateIds,
          inspectPolicy:
              bridge.inspect?.policy ?? const PatchbayInspectPolicy(),
        ).iterator;
    PatchbayCommandDescriptor next() {
      if (!descriptors.moveNext()) {
        throw StateError('UI command descriptor/handler count mismatch');
      }
      return descriptors.current;
    }

    final registrations = <PatchbayCommandRegistration<Object?>>[
      _uiRegistration<Map<String, Object?>>(
        next(),
        _decodeText,
        (request, requestId) async => (await bridge.setText(
          id: request['id']! as String,
          generation: request['generation']! as int,
          text: request['text']! as String,
          inputWasStdin: request['inputWasStdin'] == true,
          requestId: requestId,
        )).toJson(),
        notice: 'id, generation and text are required.',
      ),
      _uiRegistration<Map<String, Object?>>(
        next(),
        _decodeText,
        (request, requestId) async => (await bridge.enterText(
          id: request['id']! as String,
          generation: request['generation']! as int,
          text: request['text']! as String,
          inputWasStdin: request['inputWasStdin'] == true,
          requestId: requestId,
        )).toJson(),
        notice: 'id, generation and text are required.',
      ),
      _uiRegistration<Map<String, Object?>>(
        next(),
        _decodeSemanticsTree,
        (request, requestId) async => (await bridge.semantics.snapshot(
          maxDepth: request['maxDepth'] as int? ?? 64,
          maxNodes: request['maxNodes'] as int? ?? 1000,
          requestId: requestId,
        )).toJson(),
      ),
      _uiRegistration<Map<String, Object?>>(
        next(),
        _decodeSemanticsAction,
        (request, requestId) async => (await bridge.semantics.invoke(
          nodeId: request['nodeId']! as int,
          generation: request['generation']! as int,
          action: request['decodedAction']! as PatchbaySemanticsAction,
          text: request['text'] as String?,
          inputWasStdin: request['inputWasStdin'] == true,
          requestId: requestId,
        )).toJson(),
        available: bridge.semantics.actionsEnabled,
      ),
      _uiRegistration<Map<String, Object?>>(
        next(),
        _decodeSemanticsTap,
        (request, requestId) async => (await bridge.semantics.tapIdentifier(
          identifier: request['identifier']! as String,
          expectedGeneration: request['generation'] as int?,
          requestId: requestId,
        )).toJson(),
        strictKeys: true,
        available: bridge.semantics.actionsEnabled,
      ),
      _uiRegistration<PatchbayUiWaitRequest>(
        next(),
        (arguments) => PatchbayUiWaitRequest.fromWire(
          PatchbayUiWaitRequestWire.fromJson(arguments),
        ),
        (request, requestId) async =>
            (await bridge.wait.wait(request, requestId: requestId)).toJson(),
        strictKeys: true,
        includeReason: true,
      ),
      _uiRegistration<PatchbayKeepAwakeRequestWire>(
        next(),
        PatchbayKeepAwakeRequestWire.fromJson,
        (request, requestId) async => (await bridge.keepAwake.set(
          request,
          requestId: requestId,
        )).toJson(),
        strictKeys: true,
        includeReason: true,
      ),
      _uiRegistration<Map<String, Object?>>(
        next(),
        _noArguments,
        (_, requestId) async =>
            (await bridge.keepAwake.status(requestId: requestId)).toJson(),
        strictKeys: true,
      ),
      _uiRegistration<PatchbayCaptureRequestWire>(
        next(),
        PatchbayCaptureRequestWire.fromJson,
        (request, requestId) async => (await bridge.capture!.capture(
          request,
          requestId: requestId,
        )).toJson(),
        strictKeys: true,
        includeReason: true,
        available: bridge.capture != null,
      ),
      ...<PatchbayCommandRegistration<Object?>>[
        _uiRegistration<Map<String, Object?>>(
          next(),
          _noArguments,
          (_, requestId) async =>
              (await bridge.inspect!.status(requestId: requestId)).toJson(),
          strictKeys: true,
          available: bridge.inspect != null,
        ),
        _uiRegistration<PatchbayInspectSelectRequestWire>(
          next(),
          PatchbayInspectSelectRequestWire.fromJson,
          (request, requestId) async => (await bridge.inspect!.select(
            request: request,
            requestId: requestId,
          )).toJson(),
          strictKeys: true,
          includeReason: true,
          available: bridge.inspect != null,
        ),
      ],
      ...<PatchbayCommandRegistration<Object?>>[
        _uiRegistration<Map<String, Object?>>(
          next(),
          _noArguments,
          (_, requestId) async =>
              (await bridge.navigation!.catalog(requestId: requestId)).toJson(),
          strictKeys: true,
          available: bridge.navigation != null,
        ),
        _uiRegistration<Map<String, Object?>>(
          next(),
          _noArguments,
          (_, requestId) async =>
              (await bridge.navigation!.current(requestId: requestId)).toJson(),
          strictKeys: true,
          available: bridge.navigation != null,
        ),
        _uiRegistration<Map<String, Object?>>(
          next(),
          _decodeNavigationDestination,
          (request, requestId) async => (await bridge.navigation!.go(
            destinationId: request['destinationId']! as String,
            revision: request['revision']! as int,
            timeout: Duration(
              milliseconds: request['timeoutMs'] as int? ?? 5000,
            ),
            requestId: requestId,
          )).toJson(),
          strictKeys: true,
          available: bridge.navigation != null,
        ),
        _uiRegistration<Map<String, Object?>>(
          next(),
          _decodeNavigationDestination,
          (request, requestId) async => (await bridge.navigation!.push(
            destinationId: request['destinationId']! as String,
            revision: request['revision']! as int,
            timeout: Duration(
              milliseconds: request['timeoutMs'] as int? ?? 5000,
            ),
            requestId: requestId,
          )).toJson(),
          strictKeys: true,
          available: bridge.navigation != null,
        ),
        _uiRegistration<Map<String, Object?>>(
          next(),
          _decodeNavigationBack,
          (request, requestId) async => (await bridge.navigation!.back(
            revision: request['revision']! as int,
            timeout: Duration(
              milliseconds: request['timeoutMs'] as int? ?? 5000,
            ),
            requestId: requestId,
          )).toJson(),
          strictKeys: true,
          available: bridge.navigation != null,
        ),
      ],
    ];
    if (descriptors.moveNext()) {
      throw StateError('UI command descriptor/handler count mismatch');
    }
    return PatchbayCommandRegistry(registrations);
  }

  static PatchbayCommandRegistration<T> _uiRegistration<T>(
    PatchbayCommandDescriptor descriptor,
    PatchbayCommandDecoder<T> decode,
    PatchbayCommandHandler<T> handle, {
    bool strictKeys = false,
    bool includeReason = false,
    String? notice,
    bool available = true,
  }) => PatchbayCommandRegistration<T>(
    descriptor: descriptor,
    decode: decode,
    handle: handle,
    available: available,
    onDecodeFailure: (failure, arguments, requestId, descriptor) =>
        _invalidUiArguments(
          requestId,
          descriptor.name,
          arguments,
          strictKeys: strictKeys,
          reason: includeReason ? _decodeFailureReason(failure) : null,
          notice: notice,
        ),
  );

  static Map<String, Object?> _decodeText(Map<String, Object?> arguments) {
    if (arguments['id'] is! String ||
        arguments['generation'] is! int ||
        arguments['text'] is! String) {
      throw const FormatException('id, generation and text are required');
    }
    return arguments;
  }

  static Map<String, Object?> _decodeSemanticsTree(
    Map<String, Object?> arguments,
  ) {
    if (arguments['maxDepth'] != null && arguments['maxDepth'] is! int ||
        arguments['maxNodes'] != null && arguments['maxNodes'] is! int) {
      throw const FormatException('invalid semantics tree bounds');
    }
    return arguments;
  }

  static Map<String, Object?> _decodeSemanticsAction(
    Map<String, Object?> arguments,
  ) {
    final Object? rawAction = arguments['action'];
    final PatchbaySemanticsAction? action = rawAction is String
        ? PatchbaySemanticsAction.fromWireName(rawAction)
        : null;
    if (arguments['nodeId'] is! int ||
        arguments['generation'] is! int ||
        action == null ||
        arguments['text'] != null && arguments['text'] is! String) {
      throw const FormatException('invalid semantics action arguments');
    }
    return <String, Object?>{...arguments, 'decodedAction': action};
  }

  static Map<String, Object?> _decodeSemanticsTap(
    Map<String, Object?> arguments,
  ) {
    _rejectUnexpected(arguments, const <String>{'identifier', 'generation'});
    if (arguments['identifier'] is! String ||
        arguments['generation'] != null && arguments['generation'] is! int) {
      throw const FormatException('invalid semantics tap arguments');
    }
    return arguments;
  }

  static Map<String, Object?> _decodeNavigationDestination(
    Map<String, Object?> arguments,
  ) {
    _rejectUnexpected(arguments, const <String>{
      'destinationId',
      'revision',
      'timeoutMs',
    });
    if (arguments['destinationId'] is! String ||
        arguments['revision'] is! int ||
        arguments['timeoutMs'] != null && arguments['timeoutMs'] is! int) {
      throw const FormatException('invalid navigation arguments');
    }
    return arguments;
  }

  static Map<String, Object?> _decodeNavigationBack(
    Map<String, Object?> arguments,
  ) {
    _rejectUnexpected(arguments, const <String>{'revision', 'timeoutMs'});
    if (arguments['revision'] is! int ||
        arguments['timeoutMs'] != null && arguments['timeoutMs'] is! int) {
      throw const FormatException('invalid navigation arguments');
    }
    return arguments;
  }

  static Map<String, Object?> _noArguments(Map<String, Object?> arguments) {
    _rejectUnexpected(arguments, const <String>{});
    return arguments;
  }

  static void _rejectUnexpected(
    Map<String, Object?> arguments,
    Set<String> keys,
  ) {
    if (arguments.keys.any((String key) => !keys.contains(key))) {
      throw const FormatException('unexpected argument');
    }
  }

  /// Declared argument shape per UI command, read from the descriptors this
  /// host publishes.
  ///
  /// Deriving the rejection details from the same list the catalog serves is
  /// what stops "which key is missing" from becoming a second, hand-maintained
  /// copy of every command shape — one that would drift away from the
  /// declaration the caller actually reads.
  static final Map<String, _UiArgumentShape> _uiArgumentShapes =
      <String, _UiArgumentShape>{
        for (final PatchbayCommandDescriptor descriptor
            in _uiCommandDescriptors(
              semanticsActionsEnabled: true,
              navigationEnabled: true,
              captureEnabled: true,
              captureGates: const <String>{},
              keepAwakeGates: const <String>{},
              inspectPolicy: const PatchbayInspectPolicy(),
            ))
          descriptor.name: _UiArgumentShape(descriptor.parameters),
      };

  static List<PatchbayCommandDescriptor> _uiCommandDescriptors({
    required bool semanticsActionsEnabled,
    required bool navigationEnabled,
    required bool captureEnabled,
    required Set<String> captureGates,
    required Set<String> keepAwakeGates,
    required PatchbayInspectPolicy? inspectPolicy,
  }) => <PatchbayCommandDescriptor>[
    const PatchbayCommandDescriptor(
      name: 'ui.text.set',
      summary: 'Set a registered Flutter text target without IME semantics.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'id',
          type: PatchbayParameterType.string,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'generation',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'text',
          type: PatchbayParameterType.string,
          required: true,
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: 'ui.text.enter',
      summary: 'Enter text through the registered Flutter target policy.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'id',
          type: PatchbayParameterType.string,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'generation',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'text',
          type: PatchbayParameterType.string,
          required: true,
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: 'ui.semantics.tree',
      summary: 'Observe the current Flutter Semantics tree.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'maxDepth',
          type: PatchbayParameterType.integer,
          defaultValue: 64,
        ),
        PatchbayParameterDescriptor(
          name: 'maxNodes',
          type: PatchbayParameterType.integer,
          defaultValue: 1000,
        ),
      ],
    ),
    if (semanticsActionsEnabled)
      const PatchbayCommandDescriptor(
        name: 'ui.semantics.action',
        summary: 'Invoke an allowed action on an observed Semantics node.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'nodeId',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'generation',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'action',
            type: PatchbayParameterType.enumeration,
            required: true,
            allowedValues: <String>[
              'tap',
              'focus',
              'scrollUp',
              'scrollDown',
              'scrollLeft',
              'scrollRight',
              'setText',
            ],
          ),
          PatchbayParameterDescriptor(
            name: 'text',
            type: PatchbayParameterType.string,
          ),
        ],
      ),
    if (semanticsActionsEnabled)
      const PatchbayCommandDescriptor(
        name: 'ui.semantics.tap',
        summary:
            'Resolve a stable Semantics identifier and tap it in one request.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'identifier',
            type: PatchbayParameterType.string,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'generation',
            type: PatchbayParameterType.integer,
          ),
        ],
      ),
    const PatchbayCommandDescriptor(
      name: 'ui.wait',
      summary: 'Wait for one bounded Flutter observation condition.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'condition',
          type: PatchbayParameterType.enumeration,
          required: true,
          allowedValues: <String>[
            'semanticsMounted',
            'semanticsUnmounted',
            'semanticsValue',
            'navigationDestination',
            'treeRevision',
            'frameRevision',
          ],
        ),
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'semanticsIdentifier',
          type: PatchbayParameterType.string,
        ),
        PatchbayParameterDescriptor(
          name: 'value',
          type: PatchbayParameterType.string,
        ),
        PatchbayParameterDescriptor(
          name: 'destinationId',
          type: PatchbayParameterType.string,
        ),
        PatchbayParameterDescriptor(
          name: 'revision',
          type: PatchbayParameterType.integer,
        ),
      ],
    ),
    // Cataloged whether or not a delegate is wired — see
    // `PatchbayFlutterBridge.keepAwake` for why this one does not follow the
    // "absent until injected" rule the two below do.
    PatchbayCommandDescriptor(
      name: 'ui.keepAwake.set',
      summary: 'Hold the screen awake under a bounded lease, or release it.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      // The App's own bookkeeping of what it asked its host to do. Patchbay
      // never reads the platform back, so this is not a device report and must
      // not be mistaken for one.
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: keepAwakeGates,
      parameters: <PatchbayParameterDescriptor>[
        const PatchbayParameterDescriptor(
          name: 'enabled',
          type: PatchbayParameterType.boolean,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'leaseMs',
          type: PatchbayParameterType.integer,
          defaultValue: PatchbayKeepAwakeBridge.defaultLease.inMilliseconds,
          summary:
              'Lease for this engagement; the App releases on its own when it '
              'runs out. Only valid with enabled: true.',
        ),
      ],
    ),
    const PatchbayCommandDescriptor(
      name: 'ui.keepAwake.status',
      summary: 'Read the keep-awake hold the App is currently bookkeeping.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
    ),
    if (captureEnabled)
      PatchbayCommandDescriptor(
        name: 'ui.capture',
        summary: 'Capture a bounded Flutter repaint boundary as a PNG blob.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.readOnly,
        sideEffect: PatchbaySideEffect.none,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        gates: captureGates,
        parameters: const <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'targetId',
            type: PatchbayParameterType.string,
          ),
          PatchbayParameterDescriptor(
            name: 'generation',
            type: PatchbayParameterType.integer,
          ),
          PatchbayParameterDescriptor(
            name: 'pixelRatio',
            type: PatchbayParameterType.number,
            defaultValue: 1,
          ),
          PatchbayParameterDescriptor(
            name: 'timeoutMs',
            type: PatchbayParameterType.integer,
            defaultValue: 5000,
          ),
        ],
      ),
    if (inspectPolicy != null) ...<PatchbayCommandDescriptor>[
      const PatchbayCommandDescriptor(
        name: 'ui.inspect.status',
        summary: 'Read the on-device widget inspector select-mode switch.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.readOnly,
        sideEffect: PatchbaySideEffect.none,
        // The App's own record of a flag it holds, not a frame anyone watched
        // arrive: `uiObserved` would claim the overlay reached the screen.
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      ),
      PatchbayCommandDescriptor(
        name: 'ui.inspect.select',
        summary:
            'Turn the widget inspector select mode on or off, under a lease.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        gates: inspectPolicy.gates,
        parameters: <PatchbayParameterDescriptor>[
          const PatchbayParameterDescriptor(
            name: 'enabled',
            type: PatchbayParameterType.boolean,
            required: true,
            summary: 'Whether taps on the device select widgets.',
          ),
          PatchbayParameterDescriptor(
            name: 'ttlMs',
            type: PatchbayParameterType.integer,
            defaultValue: inspectPolicy.defaultLease.inMilliseconds,
            summary:
                'Lease for an enable; the App restores the switch when it '
                'expires without a renewal. Only valid with enabled=true.',
          ),
        ],
      ),
    ],
    if (navigationEnabled) ...<PatchbayCommandDescriptor>[
      const PatchbayCommandDescriptor(
        name: 'navigation.catalog',
        summary: 'Read the consumer destination catalog.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.readOnly,
        sideEffect: PatchbaySideEffect.none,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      ),
      const PatchbayCommandDescriptor(
        name: 'navigation.current',
        summary: 'Read the current settled consumer destination.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.readOnly,
        sideEffect: PatchbaySideEffect.none,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      ),
      const PatchbayCommandDescriptor(
        name: 'navigation.go',
        summary: 'go to a cataloged consumer destination.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'destinationId',
            type: PatchbayParameterType.string,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'revision',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'timeoutMs',
            type: PatchbayParameterType.integer,
            defaultValue: 5000,
          ),
        ],
      ),
      const PatchbayCommandDescriptor(
        name: 'navigation.push',
        summary: 'push to a cataloged consumer destination.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'destinationId',
            type: PatchbayParameterType.string,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'revision',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'timeoutMs',
            type: PatchbayParameterType.integer,
            defaultValue: 5000,
          ),
        ],
      ),
      const PatchbayCommandDescriptor(
        name: 'navigation.back',
        summary: 'Navigate back through the consumer adapter.',
        plane: PatchbayPlane.flutterUi,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
        parameters: <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'revision',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'timeoutMs',
            type: PatchbayParameterType.integer,
            defaultValue: 5000,
          ),
        ],
      ),
    ],
  ];
}

/// One command's declared parameters, reduced to what a rejection has to name.
///
/// It answers three questions and nothing more: which declared parameters this
/// request left out, which keys it carries that were never declared, and which
/// declared keys hold a value of the wrong shape. Every answer is a list of
/// names, sorted so two identical failures produce two identical envelopes.
final class _UiArgumentShape {
  _UiArgumentShape(List<PatchbayParameterDescriptor> parameters)
    : _parameters = <String, PatchbayParameterDescriptor>{
        for (final PatchbayParameterDescriptor parameter in parameters)
          parameter.name: parameter,
      };

  final Map<String, PatchbayParameterDescriptor> _parameters;

  /// Declared-required parameters this request omits.
  ///
  /// A key present with a `null` value counts as omitted: JSON has no way to
  /// say "explicitly absent", and every decoder here treats null as missing.
  List<String> missing(Map<String, Object?> arguments) => <String>[
    for (final PatchbayParameterDescriptor parameter in _parameters.values)
      if (parameter.required && arguments[parameter.name] == null)
        parameter.name,
  ]..sort();

  /// Keys this command does not declare at all.
  List<String> unexpected(Map<String, Object?> arguments) => <String>[
    for (final String key in arguments.keys)
      if (!_parameters.containsKey(key)) key,
  ]..sort();

  /// Declared keys whose value does not match the declaration.
  List<String> invalid(Map<String, Object?> arguments) => <String>[
    for (final MapEntry<String, PatchbayParameterDescriptor> entry
        in _parameters.entries)
      if (arguments[entry.key] case final Object value
          when !_matches(entry.value, value))
        entry.key,
  ]..sort();

  static bool _matches(PatchbayParameterDescriptor parameter, Object value) =>
      switch (parameter.type) {
        PatchbayParameterType.string => value is String,
        PatchbayParameterType.integer => value is int,
        PatchbayParameterType.number => value is num,
        PatchbayParameterType.boolean => value is bool,
        // An enumeration is a string drawn from a published set, so an
        // unlisted word is as wrong as a number would be.
        PatchbayParameterType.enumeration =>
          value is String && parameter.allowedValues.contains(value),
        // `json` declares no shape, so nothing about a value can contradict it.
        PatchbayParameterType.json => true,
      };
}
