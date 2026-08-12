import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  test('service catalog declares UI command fact sources', () async {
    final Map<String, ServiceExtensionHandler> handlers =
        <String, ServiceExtensionHandler>{};
    final PatchbayFlutterServiceHost host = PatchbayFlutterServiceHost(
      applicationId: 'dev.patchbay.flutter.test',
      bridge: _allowedBridge(PatchbayUiRegistry()),
      registrar: (String method, ServiceExtensionHandler handler) {
        handlers[method] = handler;
      },
    )..register();
    expect(host.appInstanceId, isNotEmpty);

    final ServiceExtensionResponse response =
        await handlers[PatchbayServiceHost.catalogMethod]!(
          PatchbayServiceHost.catalogMethod,
          const <String, String>{},
        );
    final Map<String, Object?> catalog = Map<String, Object?>.from(
      jsonDecode(response.result!) as Map<String, dynamic>,
    );
    final List<Object?> commands = catalog['commands']! as List<Object?>;
    for (final Map<String, Object?> command
        in commands.cast<Map<String, Object?>>()) {
      expect(command['factSources'], <String>['uiObserved']);
    }
  });

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

      await _pumpTextField(tester, key: key, controller: controller);

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

    testWidgets('text set bypasses formatter and onChanged', (tester) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController(
        text: 'old',
      );
      addTearDown(controller.dispose);
      var formatterCalls = 0;
      var changedCalls = 0;
      await _pumpTextField(
        tester,
        key: key,
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          _CountingUpperFormatter(() => formatterCalls += 1),
        ],
        onChanged: (_) => changedCalls += 1,
      );
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
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
    });

    testWidgets('text enter applies formatters then calls public onChanged', (
      tester,
    ) async {
      final PatchbayUiRegistry registry = PatchbayUiRegistry();
      final PatchbayKey key = PatchbayKey.text('form.code', registry: registry);
      final TextEditingController controller = TextEditingController(
        text: 'old',
      );
      addTearDown(controller.dispose);
      var formatterCalls = 0;
      final List<String> changed = <String>[];
      await _pumpTextField(
        tester,
        key: key,
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          _CountingUpperFormatter(() => formatterCalls += 1),
        ],
        onChanged: changed.add,
      );
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
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
      expect(result.payload['value'], 'ABC');
    });

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
      await _pumpTextField(tester, key: key, controller: controller);
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
      await _pumpTextField(tester, key: key, controller: controller);
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
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
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
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
      await _pumpTextField(tester, key: first, controller: firstController);
      final PatchbayFlutterBridge bridge = _allowedBridge(registry);
      final int oldGeneration = bridge.catalog().single.generation;

      await tester.pumpWidget(const SizedBox.shrink());
      final PatchbayKey second = PatchbayKey.text(
        'form.code',
        registry: registry,
      );
      await _pumpTextField(tester, key: second, controller: secondController);
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
      await _pumpTextField(tester, key: first, controller: firstController);
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
      await _pumpTextField(tester, key: second, controller: secondController);
      gate.complete(const PatchbayGateDecision.allow());
      final PatchbayInvocation result = await pending;

      expect(result.rejection?.code, 'uiGenerationStale');
      expect(secondController.text, isEmpty);
    });
  });

  testWidgets(
    'PatchbayKey keeps ordinary GlobalKey state reparenting semantics',
    (tester) async {
      final PatchbayKey key = PatchbayKey.text(
        'probe.state',
        registry: PatchbayUiRegistry(),
      );

      await tester.pumpWidget(_ReparentHarness(probeKey: key, left: true));
      await tester.tap(find.text('0'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(_ReparentHarness(probeKey: key, left: false));
      expect(find.text('1'), findsOneWidget);
    },
  );
}

PatchbayFlutterBridge _allowedBridge(PatchbayUiRegistry registry) =>
    PatchbayFlutterBridge(
      registry: registry,
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
    );

Future<void> _pumpTextField(
  WidgetTester tester, {
  required PatchbayKey key,
  required TextEditingController controller,
  List<TextInputFormatter>? inputFormatters,
  ValueChanged<String>? onChanged,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TextField(
        key: key,
        controller: controller,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
      ),
    ),
  ),
);

final class _CountingUpperFormatter extends TextInputFormatter {
  _CountingUpperFormatter(this.onCall);

  final VoidCallback onCall;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    onCall();
    final String text = newValue.text.toUpperCase();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

final class _ReparentHarness extends StatelessWidget {
  const _ReparentHarness({required this.probeKey, required this.left});

  final PatchbayKey probeKey;
  final bool left;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Row(
      children: <Widget>[
        if (left) _CounterProbe(key: probeKey) else const SizedBox(),
        if (left) const SizedBox() else _CounterProbe(key: probeKey),
      ],
    ),
  );
}

final class _CounterProbe extends StatefulWidget {
  const _CounterProbe({super.key});

  @override
  State<_CounterProbe> createState() => _CounterProbeState();
}

final class _CounterProbeState extends State<_CounterProbe> {
  int count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count += 1),
    child: Text('$count'),
  );
}
