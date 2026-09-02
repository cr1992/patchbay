import 'dart:async';

import 'gate_admission_scope.dart';

/// Stable decision returned by the host base gate or a consumer gate.
final class PatchbayGateDecision {
  const PatchbayGateDecision._({required this.allowed, this.code, this.notice});

  const PatchbayGateDecision.allow() : this._(allowed: true);

  const PatchbayGateDecision.reject({required String code, String? notice})
    : this._(allowed: false, code: code, notice: notice);

  final bool allowed;
  final String? code;
  final String? notice;
}

typedef PatchbayBaseGate = FutureOr<PatchbayGateDecision> Function();
typedef PatchbayConsumerGate =
    FutureOr<PatchbayGateDecision> Function(String gateId);

/// Runs the non-optional host gate before descriptor-declared consumer gates.
final class PatchbayGateEvaluator {
  const PatchbayGateEvaluator({
    required PatchbayBaseGate baseGate,
    required PatchbayConsumerGate consumerGate,
  }) : _baseGate = baseGate,
       _consumerGate = consumerGate;

  final PatchbayBaseGate _baseGate;
  final PatchbayConsumerGate _consumerGate;

  Future<PatchbayGateRejection?> evaluate(Iterable<String> gateIds) async {
    final PatchbayGateAdmissionScope? scope = patchbayGateAdmissionScope;
    if (!(scope?.skipBase ?? false)) {
      final PatchbayGateDecision base = await _baseGate();
      if (!base.allowed) {
        scope?.reportGateResult('rejected');
        return PatchbayGateRejection(
          gateId: 'patchbay.base',
          code: base.code ?? 'baseGateRejected',
          notice: base.notice,
        );
      }
    }

    final List<String> ordered =
        gateIds
            .where(
              (String gateId) =>
                  !(scope?.admittedGateIds.contains(gateId) ?? false),
            )
            .toSet()
            .toList()
          ..sort();
    if (ordered.isNotEmpty) scope?.enterOperationPolicy();
    for (final String gateId in ordered) {
      final PatchbayGateDecision decision = await _consumerGate(gateId);
      if (!decision.allowed) {
        scope?.reportGateResult('rejected');
        return PatchbayGateRejection(
          gateId: gateId,
          code: decision.code ?? 'consumerGateRejected',
          notice: decision.notice,
        );
      }
    }
    if (ordered.isNotEmpty) scope?.reportGateResult('passed');
    return null;
  }
}

final class PatchbayGateRejection {
  const PatchbayGateRejection({
    required this.gateId,
    required this.code,
    this.notice,
  });

  final String gateId;
  final String code;
  final String? notice;
}
