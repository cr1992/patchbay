import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

const String exampleApplicationId = 'dev.patchbay.example';
const String incrementCommand = 'example.counter.increment';
const String counterSemanticsId = 'example.counter.value';
const String incrementSemanticsId = 'example.counter.increment';
const String noteTargetId = 'example.note';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final ExampleCounterModel model = ExampleCounterModel();
  final PatchbayUiRegistry registry = PatchbayUiRegistry();
  final PatchbayKey noteKey = PatchbayKey.text(
    noteTargetId,
    registry: registry,
  );

  // Host construction is inside a compile-time false release branch. The Key
  // remains the same GlobalKey kind in every mode; only debug registrations
  // and service callbacks are removed from release reachability.
  if (!kReleaseMode) {
    PatchbayExampleHost(model: model, registry: registry).register();
  }

  runApp(PatchbayExampleApp(model: model, noteKey: noteKey));
}

final class ExampleCounterModel extends ValueNotifier<int> {
  ExampleCounterModel() : super(0);

  void increment() => value += 1;
}

/// The only consumer adapter in this example.
///
/// It owns the domain descriptor/handler while Patchbay owns transport,
/// identity envelopes, Flutter catalog composition and UI observation.
final class PatchbayExampleHost {
  PatchbayExampleHost({
    required ExampleCounterModel model,
    required PatchbayUiRegistry registry,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
    bool Function()? isAppResumed,
  }) : _model = model,
       bridge = PatchbayFlutterBridge(
         gates: const PatchbayGateEvaluator(
           baseGate: _allowBaseGate,
           consumerGate: _allowConsumerGate,
         ),
         registry: registry,
         isAppResumed: isAppResumed,
       ) {
    _service = PatchbayFlutterServiceHost(
      applicationId: exampleApplicationId,
      appInstanceId: appInstanceId,
      bridge: bridge,
      registrar: registrar,
      domainCatalog: _catalog,
      snapshot: _snapshot,
      domainInvoke: _invoke,
    );
  }

  static const PatchbayCommandDescriptor _incrementDescriptor =
      PatchbayCommandDescriptor(
        name: incrementCommand,
        summary: 'Increment the example consumer counter.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.appState,
        factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      );

  final ExampleCounterModel _model;
  final PatchbayFlutterBridge bridge;
  late final PatchbayFlutterServiceHost _service;

  String get appInstanceId => _service.appInstanceId;

  void register() => _service.register();

  Future<Map<String, Object?>> _catalog() async => <String, Object?>{
    'commands': <Object?>[_incrementDescriptor.toJson()],
  };

  Future<Map<String, Object?>> _snapshot() async => <String, Object?>{
    'source': PatchbayFactSource.appRecorded.name,
    'counter': _model.value,
  };

  Future<Map<String, Object?>> _invoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    if (command != incrementCommand) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: 'commandNotRegistered',
          details: <String, Object?>{'command': command},
        ),
      ).toJson();
    }
    if (arguments.isNotEmpty) {
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'invalidArguments'),
      ).toJson();
    }
    _model.increment();
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: <String, Object?>{
        'outcome': 'completed',
        'source': PatchbayFactSource.appRecorded.name,
        'counter': _model.value,
      },
    ).toJson();
  }

  void dispose() => bridge.dispose();
}

FutureOr<PatchbayGateDecision> _allowBaseGate() =>
    const PatchbayGateDecision.allow();

FutureOr<PatchbayGateDecision> _allowConsumerGate(String _) =>
    const PatchbayGateDecision.allow();

final class PatchbayExampleApp extends StatefulWidget {
  const PatchbayExampleApp({
    required this.model,
    required this.noteKey,
    super.key,
  });

  final ExampleCounterModel model;
  final PatchbayKey noteKey;

  @override
  State<PatchbayExampleApp> createState() => _PatchbayExampleAppState();
}

final class _PatchbayExampleAppState extends State<PatchbayExampleApp> {
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Patchbay example')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ValueListenableBuilder<int>(
              valueListenable: widget.model,
              builder: (BuildContext context, int count, Widget? child) =>
                  Semantics(
                    identifier: counterSemanticsId,
                    label: 'Counter value',
                    value: '$count',
                    liveRegion: true,
                    child: Text('Count: $count'),
                  ),
            ),
            const SizedBox(height: 16),
            Semantics(
              identifier: incrementSemanticsId,
              button: true,
              child: ElevatedButton(
                onPressed: widget.model.increment,
                child: const Text('Increment'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: widget.noteKey,
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Debug note'),
            ),
          ],
        ),
      ),
    ),
  );
}
