import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';
import 'package:patchbay_flutter_example/main.dart';

void main() {
  testWidgets('widget exposes stable semantics and keeps normal interaction', (
    WidgetTester tester,
  ) async {
    final ExampleCounterModel model = ExampleCounterModel();
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey noteKey = PatchbayKey.text(
      noteTargetId,
      registry: registry,
    );
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      isAppResumed: () => true,
    );
    try {
      await tester.pumpWidget(
        PatchbayExampleApp(model: model, noteKey: noteKey),
      );
      expect(find.text('Count: 0'), findsOneWidget);

      final PatchbaySemanticsIdentifierObservation? before =
          await _pumpUntilComplete(
            tester,
            host.bridge.semantics.observeIdentifier(counterSemanticsId),
          );
      expect(before?.matches, hasLength(1));
      expect(before?.matches.single.value, '0');

      await tester.tap(find.text('Increment'));
      await tester.pump();
      expect(find.text('Count: 1'), findsOneWidget);

      final PatchbaySemanticsIdentifierObservation? after =
          await _pumpUntilComplete(
            tester,
            host.bridge.semantics.observeIdentifier(counterSemanticsId),
          );
      expect(after?.matches.single.value, '1');
    } finally {
      host.dispose();
      model.dispose();
    }
  });

  testWidgets('host composes identity, catalog and consumer invoke', (
    WidgetTester tester,
  ) async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final ExampleCounterModel model = ExampleCounterModel();
    final PatchbayUiRegistry registry = PatchbayUiRegistry();
    final PatchbayKey noteKey = PatchbayKey.text(
      noteTargetId,
      registry: registry,
    );
    final PatchbayExampleHost host = PatchbayExampleHost(
      model: model,
      registry: registry,
      appInstanceId: 'example-test-instance',
      isAppResumed: () => true,
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
    )..register();
    try {
      await tester.pumpWidget(
        PatchbayExampleApp(model: model, noteKey: noteKey),
      );

      final Map<String, Object?> identity = await _call(
        handlers,
        PatchbayServiceHost.identityMethod,
      );
      expect(identity['applicationId'], exampleApplicationId);
      expect(identity['appInstanceId'], 'example-test-instance');
      expect(identity['isolateId'], isA<String>());

      final Map<String, Object?> catalog = await _call(
        handlers,
        PatchbayServiceHost.catalogMethod,
      );
      final List<Map<String, Object?>> commands =
          (catalog['commands']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        commands.map((Map<String, Object?> row) => row['name']),
        containsAll(<String>{
          incrementCommand,
          'ui.semantics.tree',
          'ui.text.set',
        }),
      );
      final List<Map<String, Object?>> targets =
          (catalog['uiTargets']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        targets.singleWhere(
          (Map<String, Object?> target) => target['id'] == noteTargetId,
        ),
        containsPair('mounted', true),
      );

      final Map<String, Object?> invocation = await _call(
        handlers,
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': incrementCommand,
          'args': '{}',
          'requestId': 'example-request',
        },
      );
      expect(invocation['admission'], 'accepted');
      expect(
        invocation['payload'],
        containsPair('source', PatchbayFactSource.appRecorded.name),
      );
      await tester.pump();
      expect(find.text('Count: 1'), findsOneWidget);
    } finally {
      host.dispose();
      model.dispose();
    }
  });
}

Future<T> _pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
  var completed = false;
  unawaited(
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace _) => completed = true,
    ),
  );
  for (var attempt = 0; attempt < 20 && !completed; attempt += 1) {
    await tester.pump();
  }
  if (!completed) {
    throw StateError(
      'Patchbay example operation did not complete in 20 frames',
    );
  }
  return pending;
}

Future<Map<String, Object?>> _call(
  Map<String, ServiceExtensionHandler> handlers,
  String method, [
  Map<String, String> arguments = const <String, String>{},
]) async {
  final ServiceExtensionResponse response = await handlers[method]!(
    method,
    arguments,
  );
  return Map<String, Object?>.from(
    jsonDecode(response.result!) as Map<String, dynamic>,
  );
}
