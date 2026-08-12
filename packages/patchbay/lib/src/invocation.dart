import 'generated/core_wire.g.dart';

enum PatchbayAdmission { accepted, rejected }

/// Stable rejection attached only when a request was not admitted.
final class PatchbayRejection {
  const PatchbayRejection({
    required this.code,
    this.notice,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String? notice;
  final Map<String, Object?> details;

  PatchbayRejectionWire _toWire() =>
      PatchbayRejectionWire(code: code, notice: notice, details: details);

  Map<String, Object?> toJson() => _toWire().toJson();
}

/// Admission envelope. It deliberately does not claim domain execution.
final class PatchbayInvocation {
  const PatchbayInvocation._({
    required this.requestId,
    required this.admission,
    required this.payload,
    this.notice,
    this.jobId,
    this.rejection,
  });

  factory PatchbayInvocation.accepted({
    required String requestId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? notice,
    String? jobId,
  }) => PatchbayInvocation._(
    requestId: requestId,
    admission: PatchbayAdmission.accepted,
    payload: payload,
    notice: notice,
    jobId: jobId,
  );

  factory PatchbayInvocation.rejected({
    required String requestId,
    required PatchbayRejection rejection,
  }) => PatchbayInvocation._(
    requestId: requestId,
    admission: PatchbayAdmission.rejected,
    payload: const <String, Object?>{},
    notice: rejection.notice,
    rejection: rejection,
  );

  static const int schemaVersion = 1;

  final String requestId;
  final PatchbayAdmission admission;
  final Map<String, Object?> payload;
  final String? notice;
  final String? jobId;
  final PatchbayRejection? rejection;

  Map<String, Object?> toJson() => PatchbayInvocationWire(
    schemaVersion: schemaVersion,
    requestId: requestId,
    admission: switch (admission) {
      PatchbayAdmission.accepted => PatchbayAdmissionWire.accepted,
      PatchbayAdmission.rejected => PatchbayAdmissionWire.rejected,
    },
    payload: payload,
    notice: notice,
    jobId: jobId,
    rejection: rejection?._toWire(),
  ).toJson();
}
