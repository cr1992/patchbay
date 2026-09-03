import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';

PatchbayFlutterBridge allowedBridge(PatchbayUiRegistry registry) =>
    PatchbayFlutterBridge(
      registry: registry,
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
    );

PatchbayFlutterBridge interactiveBridge(PatchbayUiRegistry registry) =>
    PatchbayFlutterBridge(
      registry: registry,
      gates: PatchbayGateEvaluator(
        baseGate: () => const PatchbayGateDecision.allow(),
        consumerGate: (_) => const PatchbayGateDecision.allow(),
      ),
      semanticsActionPolicy: (_, _) =>
          const PatchbaySemanticsActionDecision.allow(),
      isAppResumed: () => true,
    );

Future<PatchbayInvocation> semanticsSnapshot(
  WidgetTester tester,
  PatchbayFlutterBridge bridge,
) async {
  final Future<PatchbayInvocation> pending = bridge.semantics.snapshot();
  return pumpUntilComplete(tester, pending);
}

Future<PatchbayInvocation> semanticsInvoke(
  WidgetTester tester,
  PatchbayFlutterBridge bridge, {
  required Map<String, Object?> node,
  required PatchbaySemanticsAction action,
  String? text,
}) async {
  final Future<PatchbayInvocation> pending = bridge.semantics.invoke(
    nodeId: node['nodeId']! as int,
    generation: node['generation']! as int,
    action: action,
    text: text,
  );
  return pumpUntilComplete(tester, pending);
}

Future<T> pumpUntilComplete<T>(WidgetTester tester, Future<T> pending) async {
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
    throw StateError('Patchbay test operation did not complete in 20 frames');
  }
  return pending;
}

List<Map<String, Object?>> semanticsNodes(PatchbayInvocation result) =>
    (result.payload['nodes']! as List<Object?>).cast<Map<String, Object?>>();

Future<void> pumpTextField(
  WidgetTester tester, {
  required PatchbayKey key,
  required TextEditingController controller,
  List<TextInputFormatter>? inputFormatters,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: TextField(
        key: key,
        controller: controller,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    ),
  ),
);

final class CountingUpperFormatter extends TextInputFormatter {
  CountingUpperFormatter(this.onCall);

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

final class ReparentHarness extends StatelessWidget {
  const ReparentHarness({
    super.key,
    required this.probeKey,
    required this.left,
  });

  final PatchbayKey probeKey;
  final bool left;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Row(
      children: <Widget>[
        if (left) CounterProbe(key: probeKey) else const SizedBox(),
        if (left) const SizedBox() else CounterProbe(key: probeKey),
      ],
    ),
  );
}

final class CounterProbe extends StatefulWidget {
  const CounterProbe({super.key});

  @override
  State<CounterProbe> createState() => _CounterProbeState();
}

final class _CounterProbeState extends State<CounterProbe> {
  int count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count += 1),
    child: Text('$count'),
  );
}
