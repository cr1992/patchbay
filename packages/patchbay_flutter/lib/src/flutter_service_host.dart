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
               <String, Object?>{
                 'name': 'ui.text.set',
                 'plane': 'flutterUi',
                 'mode': 'immediate',
                 'sideEffect': 'appState',
                 'factSources': <String>[PatchbayFactSource.uiObserved.name],
               },
               <String, Object?>{
                 'name': 'ui.text.enter',
                 'plane': 'flutterUi',
                 'mode': 'immediate',
                 'sideEffect': 'appState',
                 'factSources': <String>[PatchbayFactSource.uiObserved.name],
               },
               <String, Object?>{
                 'name': 'ui.semantics.tree',
                 'plane': 'flutterUi',
                 'mode': 'readOnly',
                 'sideEffect': 'none',
                 'factSources': <String>[PatchbayFactSource.uiObserved.name],
               },
               if (bridge.semantics.actionsEnabled)
                 <String, Object?>{
                   'name': 'ui.semantics.action',
                   'plane': 'flutterUi',
                   'mode': 'immediate',
                   'sideEffect': 'appState',
                   'factSources': <String>[PatchbayFactSource.uiObserved.name],
                 },
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
           final bool uiCommand =
               command == 'ui.text.set' ||
               command == 'ui.text.enter' ||
               command == 'ui.semantics.tree' ||
               command == 'ui.semantics.action';
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
             )).toJson();
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
             ),
             'ui.text.enter' => await bridge.enterText(
               id: id,
               generation: generation,
               text: text,
               inputWasStdin: stdin,
             ),
             _ => throw StateError('unreachable UI command $command'),
           };
           return result.toJson();
         },
       );

  final PatchbayServiceHost _host;

  String get appInstanceId => _host.appInstanceId;

  void register() => _host.register();
}
