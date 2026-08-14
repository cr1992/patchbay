import 'package:patchbay/patchbay.dart';

import 'flutter_bridge.dart';
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
  }) : _host = PatchbayServiceHost(
         applicationId: applicationId,
         appInstanceId: appInstanceId,
         registrar: registrar,
         catalog: () async {
           final Map<String, Object?> domain =
               await domainCatalog?.call() ?? const <String, Object?>{};
           return <String, Object?>{
             ...domain,
             'commands': <Object?>[
               for (final PatchbayCommandDescriptor descriptor
                   in _uiCommandDescriptors(
                     semanticsActionsEnabled: bridge.semantics.actionsEnabled,
                     navigationEnabled: bridge.navigation != null,
                     captureEnabled: bridge.capture != null,
                     captureGates: bridge.capture?.gateIds ?? const <String>{},
                   ))
                 descriptor.toJson(),
               ...?bridge.artifacts?.descriptors.map(
                 (PatchbayCommandDescriptor descriptor) => descriptor.toJson(),
               ),
               ...?domain['commands'] as List<Object?>?,
             ],
             'uiTargets': bridge
                 .catalog()
                 .map((PatchbayUiTargetDescriptor target) => target.toJson())
                 .toList(growable: false),
           };
         },
         snapshot: snapshot ?? () async => const <String, Object?>{},
         invoke: (command, arguments, requestId) async {
           if (bridge.artifacts?.handles(command) == true) {
             return bridge.artifacts!.invoke(command, arguments, requestId);
           }
           if (command == 'ui.capture') {
             final capture = bridge.capture;
             if (capture == null) {
               return PatchbayInvocation.rejected(
                 requestId: requestId,
                 rejection: const PatchbayRejection(
                   code: 'commandNotRegistered',
                 ),
               ).toJson();
             }
             final PatchbayCaptureRequestWire request;
             try {
               request = PatchbayCaptureRequestWire.fromJson(arguments);
             } on Object {
               return _invalidUiArguments(requestId);
             }
             return (await capture.capture(
               request,
               requestId: requestId,
             )).toJson();
           }
           final bool uiCommand =
               command == 'ui.text.set' ||
               command == 'ui.text.enter' ||
               command == 'ui.semantics.tree' ||
               command == 'ui.semantics.action' ||
               command == 'ui.wait' ||
               command == 'ui.capture' ||
               command.startsWith('navigation.');
           if (!uiCommand) {
             if (domainInvoke != null) {
               return domainInvoke(command, arguments, requestId);
             }
             return PatchbayInvocation.rejected(
               requestId: requestId,
               rejection: PatchbayRejection(
                 code: 'commandNotRegistered',
                 details: <String, Object?>{'command': command},
               ),
             ).toJson();
           }
           if (command == 'ui.semantics.tree') {
             final Object? maxDepth = arguments['maxDepth'];
             final Object? maxNodes = arguments['maxNodes'];
             if (maxDepth != null && maxDepth is! int ||
                 maxNodes != null && maxNodes is! int) {
               return PatchbayInvocation.rejected(
                 requestId: requestId,
                 rejection: const PatchbayRejection(code: 'invalidUiArguments'),
               ).toJson();
             }
             return (await bridge.semantics.snapshot(
               maxDepth: maxDepth as int? ?? 64,
               maxNodes: maxNodes as int? ?? 1000,
               requestId: requestId,
             )).toJson();
           }
           if (command == 'ui.semantics.action') {
             if (!bridge.semantics.actionsEnabled) {
               return PatchbayInvocation.rejected(
                 requestId: requestId,
                 rejection: const PatchbayRejection(
                   code: 'commandNotRegistered',
                 ),
               ).toJson();
             }
             final Object? nodeId = arguments['nodeId'];
             final Object? generation = arguments['generation'];
             final Object? actionName = arguments['action'];
             final PatchbaySemanticsAction? action = actionName is String
                 ? PatchbaySemanticsAction.fromWireName(actionName)
                 : null;
             final Object? text = arguments['text'];
             if (nodeId is! int ||
                 generation is! int ||
                 action == null ||
                 text != null && text is! String) {
               return PatchbayInvocation.rejected(
                 requestId: requestId,
                 rejection: const PatchbayRejection(code: 'invalidUiArguments'),
               ).toJson();
             }
             return (await bridge.semantics.invoke(
               nodeId: nodeId,
               generation: generation,
               action: action,
               text: text as String?,
               inputWasStdin: arguments['inputWasStdin'] == true,
               requestId: requestId,
             )).toJson();
           }
           if (command == 'ui.wait') {
             final PatchbayUiWaitRequest request;
             try {
               request = PatchbayUiWaitRequest.fromWire(
                 PatchbayUiWaitRequestWire.fromJson(arguments),
               );
             } on Object {
               return _invalidUiArguments(requestId);
             }
             return (await bridge.wait.wait(
               request,
               requestId: requestId,
             )).toJson();
           }
           if (command.startsWith('navigation.')) {
             final navigation = bridge.navigation;
             if (navigation == null) {
               return PatchbayInvocation.rejected(
                 requestId: requestId,
                 rejection: const PatchbayRejection(
                   code: 'commandNotRegistered',
                 ),
               ).toJson();
             }
             if (command == 'navigation.catalog') {
               if (arguments.isNotEmpty) return _invalidUiArguments(requestId);
               return (await navigation.catalog(requestId: requestId)).toJson();
             }
             if (command == 'navigation.current') {
               if (arguments.isNotEmpty) return _invalidUiArguments(requestId);
               return (await navigation.current(requestId: requestId)).toJson();
             }
             final Object? revision = arguments['revision'];
             final Object? timeoutMs = arguments['timeoutMs'];
             if (revision is! int ||
                 timeoutMs != null && timeoutMs is! int ||
                 arguments.keys.any(
                   (String key) =>
                       key != 'destinationId' &&
                       key != 'revision' &&
                       key != 'timeoutMs',
                 )) {
               return _invalidUiArguments(requestId);
             }
             final Duration timeout = Duration(
               milliseconds: timeoutMs as int? ?? 5000,
             );
             if (command == 'navigation.back') {
               if (arguments.containsKey('destinationId')) {
                 return _invalidUiArguments(requestId);
               }
               return (await navigation.back(
                 revision: revision,
                 timeout: timeout,
                 requestId: requestId,
               )).toJson();
             }
             final Object? destinationId = arguments['destinationId'];
             if (destinationId is! String) {
               return _invalidUiArguments(requestId);
             }
             if (command == 'navigation.go') {
               return (await navigation.go(
                 destinationId: destinationId,
                 revision: revision,
                 timeout: timeout,
                 requestId: requestId,
               )).toJson();
             }
             if (command == 'navigation.push') {
               return (await navigation.push(
                 destinationId: destinationId,
                 revision: revision,
                 timeout: timeout,
                 requestId: requestId,
               )).toJson();
             }
             return PatchbayInvocation.rejected(
               requestId: requestId,
               rejection: const PatchbayRejection(code: 'commandNotRegistered'),
             ).toJson();
           }
           final Object? id = arguments['id'];
           final Object? generation = arguments['generation'];
           final Object? text = arguments['text'];
           if (id is! String || generation is! int || text is! String) {
             return PatchbayInvocation.rejected(
               requestId: requestId,
               rejection: const PatchbayRejection(
                 code: 'invalidUiArguments',
                 notice: 'id, generation and text are required.',
               ),
             ).toJson();
           }
           final bool stdin = arguments['inputWasStdin'] == true;
           final PatchbayInvocation result = switch (command) {
             'ui.text.set' => await bridge.setText(
               id: id,
               generation: generation,
               text: text,
               inputWasStdin: stdin,
               requestId: requestId,
             ),
             'ui.text.enter' => await bridge.enterText(
               id: id,
               generation: generation,
               text: text,
               inputWasStdin: stdin,
               requestId: requestId,
             ),
             _ => throw StateError('unreachable UI command $command'),
           };
           return result.toJson();
         },
       );

  final PatchbayServiceHost _host;

  String get applicationId => _host.applicationId;

  String get appInstanceId => _host.appInstanceId;

  int get schemaVersion => PatchbayServiceHost.schemaVersion;

  Future<Map<String, Object?>> dispatchCatalog() => _host.dispatchCatalog();

  Future<Map<String, Object?>> dispatchSnapshot() => _host.dispatchSnapshot();

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) => _host.dispatchInvoke(command, arguments, requestId);

  void register() => _host.register();

  static Map<String, Object?> _invalidUiArguments(String requestId) =>
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'invalidUiArguments'),
      ).toJson();

  static List<PatchbayCommandDescriptor> _uiCommandDescriptors({
    required bool semanticsActionsEnabled,
    required bool navigationEnabled,
    required bool captureEnabled,
    required Set<String> captureGates,
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
      for (final String operation in <String>['go', 'push'])
        PatchbayCommandDescriptor(
          name: 'navigation.$operation',
          summary: '$operation to a cataloged consumer destination.',
          plane: PatchbayPlane.flutterUi,
          mode: PatchbayCommandMode.immediate,
          sideEffect: PatchbaySideEffect.appState,
          factSources: const <PatchbayFactSource>{
            PatchbayFactSource.uiObserved,
          },
          parameters: const <PatchbayParameterDescriptor>[
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
