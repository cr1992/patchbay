import 'package:patchbay/patchbay.dart';

import 'flutter_bridge.dart';

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
               command == 'ui.text.set' || command == 'ui.text.enter';
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
