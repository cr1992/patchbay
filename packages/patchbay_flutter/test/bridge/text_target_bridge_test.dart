import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

import '../fixture/flutter_bridge_fixtures.dart';

void main() {
  group('Patchbay text target', () {
    testWidgets('catalog exposes only mounted public-API operations', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'login.phone',
        registry: registry,
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);

      await pumpTextField(tester, key: key, controller: controller);

      final PatchbayUiTargetDescriptor descriptor = registry.catalog().single;
      expect(descriptor.id, 'login.phone');
      expect(descriptor.mounted, isTrue);
      expect(descriptor.ambiguous, isFalse);
      expect(descriptor.generation, 1);
      expect(descriptor.operations, <PatchbayUiOperation>{
        PatchbayUiOperation.textSet,
        PatchbayUiOperation.textEnter,
      });
    });

    testWidgets(
      'text set replaces text without formatter or submit callbacks',
      (tester) async {
        final PatchbayUiRegistry registry = PatchbayUiRegistry();
        final PatchbayKey key = PatchbayKey.text(
          'form.code',
          registry: registry,
        );
        final TextEditingController controller = TextEditingController(
          text: 'old',
        );
        addTearDown(controller.dispose);
        var formatterCalls = 0;
        var changedCalls = 0;
        var submittedCalls = 0;
        await pumpTextField(
          tester,
          key: key,
          controller: controller,
          inputFormatters: <TextInputFormatter>[
            CountingUpperFormatter(() => formatterCalls += 1),
          ],
          onChanged: (_) => changedCalls += 1,
          onSubmitted: (_) => submittedCalls += 1,
        );
        final PatchbayFlutterBridge bridge = allowedBridge(registry);
        final int generation = bridge.catalog().single.generation;

        final PatchbayInvocation result = await bridge.setText(
          id: 'form.code',
          generation: generation,
          text: 'abc',
        );
        await tester.pump();

        expect(result.admission, PatchbayAdmission.accepted);
        expect(controller.text, 'abc');
        expect(formatterCalls, 0);
        expect(changedCalls, 0);
        expect(submittedCalls, 0);
        expect(result.payload['value'], 'abc');
      },
    );

    testWidgets(
      'text enter applies formatters then calls only public onChanged',
      (tester) async {
        final PatchbayUiRegistry registry = PatchbayUiRegistry();
        final PatchbayKey key = PatchbayKey.text(
          'form.code',
          registry: registry,
        );
        final TextEditingController controller = TextEditingController(
          text: 'old',
        );
        addTearDown(controller.dispose);
        var formatterCalls = 0;
        final List<String> changed = <String>[];
        final List<String> submitted = <String>[];
        await pumpTextField(
          tester,
          key: key,
          controller: controller,
          inputFormatters: <TextInputFormatter>[
            CountingUpperFormatter(() => formatterCalls += 1),
          ],
          onChanged: changed.add,
          onSubmitted: submitted.add,
        );
        final PatchbayFlutterBridge bridge = allowedBridge(registry);
        final int generation = bridge.catalog().single.generation;

        final PatchbayInvocation result = await bridge.enterText(
          id: 'form.code',
          generation: generation,
          text: 'abc',
        );
        await tester.pump();

        expect(result.admission, PatchbayAdmission.accepted);
        expect(controller.text, 'ABC');
        expect(formatterCalls, 1);
        expect(changed, <String>['ABC']);
        expect(submitted, isEmpty);
        expect(result.payload['value'], 'ABC');
      },
    );

    testWidgets('base and descriptor gates both fail closed', (tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'form.code',
        registry: registry,
        operationGates: const <PatchbayUiOperation, Set<String>>{
          PatchbayUiOperation.textEnter: <String>{'consumer.ready'},
        },
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpTextField(tester, key: key, controller: controller);
      final int generation = registry.catalog().single.generation;
      var consumerCalls = 0;
      final PatchbayFlutterBridge baseRejected = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () =>
              const PatchbayGateDecision.reject(code: 'hostDisabled'),
          consumerGate: (_) {
            consumerCalls += 1;
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final PatchbayInvocation baseResult = await baseRejected.enterText(
        id: 'form.code',
        generation: generation,
        text: 'blocked',
      );
      expect(baseResult.rejection?.code, 'hostDisabled');
      expect(consumerCalls, 0);
      expect(controller.text, isEmpty);

      final PatchbayFlutterBridge consumerRejected = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String gateId) => PatchbayGateDecision.reject(
            code: 'consumerNotReady',
            notice: gateId,
          ),
        ),
      );
      final PatchbayInvocation consumerResult = await consumerRejected
          .enterText(id: 'form.code', generation: generation, text: 'blocked');
      expect(consumerResult.rejection?.code, 'consumerNotReady');
      expect(consumerResult.rejection?.details['gateId'], 'consumer.ready');
      expect(controller.text, isEmpty);
    });

    testWidgets('sensitive values require stdin and never echo plaintext', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text(
        'login.password',
        sensitive: true,
        registry: registry,
      );
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpTextField(tester, key: key, controller: controller);
      final PatchbayFlutterBridge bridge = allowedBridge(registry);
      final int generation = bridge.catalog().single.generation;

      final PatchbayInvocation rejected = await bridge.setText(
        id: 'login.password',
        generation: generation,
        text: 'secret',
      );
      expect(rejected.rejection?.code, 'sensitiveInputRequiresStdin');
      expect(controller.text, isEmpty);

      final PatchbayInvocation accepted = await bridge.setText(
        id: 'login.password',
        generation: generation,
        text: 'secret',
        inputWasStdin: true,
      );
      expect(controller.text, 'secret');
      expect(accepted.payload['valueRedacted'], isTrue);
      expect(accepted.payload.values, isNot(contains('secret')));
    });

    testWidgets('duplicate mounted IDs reject instead of picking tree order', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TextField(key: first, controller: firstController),
                TextField(key: second, controller: secondController),
              ],
            ),
          ),
        ),
      );
      final PatchbayFlutterBridge bridge = allowedBridge(registry);
      final PatchbayUiTargetDescriptor descriptor = bridge.catalog().single;

      expect(descriptor.ambiguous, isTrue);
      expect(descriptor.operations, isEmpty);
      final PatchbayInvocation result = await bridge.setText(
        id: 'form.code',
        generation: descriptor.generation,
        text: 'never applied',
      );
      expect(result.rejection?.code, 'uiTargetAmbiguous');
      expect(firstController.text, isEmpty);
      expect(secondController.text, isEmpty);
    });

    testWidgets('remount assigns a new generation and fences stale calls', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await pumpTextField(tester, key: first, controller: firstController);
      final PatchbayFlutterBridge bridge = allowedBridge(registry);
      final int oldGeneration = bridge.catalog().single.generation;

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await pumpTextField(tester, key: second, controller: secondController);
      final int newGeneration = bridge.catalog().single.generation;

      expect(newGeneration, greaterThan(oldGeneration));
      final PatchbayInvocation result = await bridge.setText(
        id: 'form.code',
        generation: oldGeneration,
        text: 'stale',
      );
      expect(result.rejection?.code, 'uiGenerationStale');
      expect(secondController.text, isEmpty);
    });

    testWidgets('late gate continuation cannot target a replacement', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final Completer<PatchbayGateDecision> gate =
          Completer<PatchbayGateDecision>();
      final TextEditingController firstController = TextEditingController();
      final TextEditingController secondController = TextEditingController();
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      final PatchbayKey first = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await pumpTextField(tester, key: first, controller: firstController);
      final PatchbayFlutterBridge bridge = PatchbayFlutterBridge(
        registry: registry,
        gates: PatchbayGateEvaluator(
          baseGate: () => gate.future,
          consumerGate: (_) => const PatchbayGateDecision.allow(),
        ),
      );
      final int generation = bridge.catalog().single.generation;
      final Future<PatchbayInvocation> pending = bridge.setText(
        id: 'form.code',
        generation: generation,
        text: 'late',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await pumpTextField(tester, key: second, controller: secondController);
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pending;

      expect(result.rejection?.code, 'uiGenerationStale');
      expect(secondController.text, isEmpty);
    });

    // DG-060-05 (`interactionModel: directTarget`) and the sentence
    // docs/guide.md now states outright: the registered-target surface
    // deliberately runs no occlusion check, so a text target buried under an
    // opaque overlay still applies. Without this case that claim is unverified
    // prose, and adding a hit-test to this channel later — the change the
    // proposal rejects as "把显式 controller 自动化错误伪装成用户触摸" — would
    // land silently. `ui.gesture.*` / `ui.semantics.*` keep their own
    // occlusion admission; this covers only the direct surface.
    testWidgets('an opaque overlay does not block a direct text write', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController(
        text: 'old',
      );
      addTearDown(controller.dispose);
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      final List<String> changed = <String>[];
      var overlayTaps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: TextField(
                    key: key,
                    controller: controller,
                    focusNode: focus,
                    onChanged: changed.add,
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => overlayTaps += 1,
                    child: const ColoredBox(color: Color(0xFF202020)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // The overlay really occludes rather than merely sitting nearby: a
      // pointer aimed at the field lands on the overlay and the field never
      // takes focus. That is the situation a userLike channel refuses on.
      await tester.tap(find.byType(TextField), warnIfMissed: false);
      await tester.pump();
      expect(overlayTaps, 1);
      expect(focus.hasFocus, isFalse);

      final PatchbayFlutterBridge bridge = allowedBridge(registry);
      final PatchbayUiTargetDescriptor descriptor = bridge.catalog().single;
      // Covered is not unmounted: the catalog keeps offering both operations.
      expect(descriptor.mounted, isTrue);
      expect(descriptor.operations, <PatchbayUiOperation>{
        PatchbayUiOperation.textSet,
        PatchbayUiOperation.textEnter,
      });

      final PatchbayInvocation set = await bridge.setText(
        id: 'form.code',
        generation: descriptor.generation,
        text: 'abc',
      );
      await tester.pump();
      expect(set.admission, PatchbayAdmission.accepted);
      expect(set.payload['value'], 'abc');
      expect(controller.text, 'abc');

      final PatchbayInvocation entered = await bridge.enterText(
        id: 'form.code',
        generation: bridge.catalog().single.generation,
        text: 'xyz',
      );
      await tester.pump();
      expect(entered.admission, PatchbayAdmission.accepted);
      expect(controller.text, 'xyz');
      expect(changed, <String>['xyz']);
      // Still unreachable by pointer throughout: applied never implied reach.
      expect(focus.hasFocus, isFalse);
    });
  });

  testWidgets(
    'PatchbayKey keeps ordinary GlobalKey state reparenting semantics',
    (tester) async {
      final PatchbayKey key = PatchbayKey.text(
        'probe.state',
        registry: PatchbayUiRegistry(),
      );

      await tester.pumpWidget(ReparentHarness(probeKey: key, left: true));
      await tester.tap(find.text('0'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(ReparentHarness(probeKey: key, left: false));
      expect(find.text('1'), findsOneWidget);
    },
  );
}
