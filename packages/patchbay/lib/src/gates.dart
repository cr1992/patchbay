import 'dart:async';

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
    final PatchbayGateDecision base = await _baseGate();
    if (!base.allowed) {
      return PatchbayGateRejection(
        gateId: 'patchbay.base',
        code: base.code ?? 'baseGateRejected',
        notice: base.notice,
      );
    }

    final List<String> ordered = gateIds.toSet().toList()..sort();
    for (final String gateId in ordered) {
      final PatchbayGateDecision decision = await _consumerGate(gateId);
      if (!decision.allowed) {
        return PatchbayGateRejection(
          gateId: gateId,
          code: decision.code ?? 'consumerGateRejected',
          notice: decision.notice,
        );
      }
    }
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
