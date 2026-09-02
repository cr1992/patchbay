import 'dart:async';

final Object _patchbayGateAdmissionScopeKey = Object();

/// Internal facts carried from core admission into a registry-owned handler.
///
/// The scope prevents a bridge from evaluating the same base or static
/// descriptor gate twice while leaving direct bridge calls unchanged. It also
/// lets a UI handler report the dynamic operation-policy stage back to the
/// host-only audit state without adding fields to the invocation envelope.
final class PatchbayGateAdmissionScope {
  PatchbayGateAdmissionScope({
    required this.skipBase,
    required Set<String> admittedGateIds,
    this.onGateResult,
    this.onGateDisposition,
    this.onAdmissionStage,
  }) : admittedGateIds = Set<String>.unmodifiable(admittedGateIds);

  final bool skipBase;
  final Set<String> admittedGateIds;
  final void Function(String result)? onGateResult;
  final void Function(String disposition)? onGateDisposition;
  final void Function(String stage)? onAdmissionStage;

  bool _active = true;
  bool _uiPreflightReached = false;

  void enterUiPreflight() {
    _uiPreflightReached = true;
    onAdmissionStage?.call('uiPreflight');
  }

  void enterOperationPolicy() {
    if (_uiPreflightReached) onAdmissionStage?.call('operationPolicy');
  }

  void reportGateResult(String result) {
    onGateResult?.call(result);
    if (result == 'passed' || result == 'rejected') {
      onGateDisposition?.call(result);
    }
  }

  void close() => _active = false;
}

PatchbayGateAdmissionScope? get patchbayGateAdmissionScope {
  final PatchbayGateAdmissionScope? scope =
      Zone.current[_patchbayGateAdmissionScopeKey]
          as PatchbayGateAdmissionScope?;
  if (scope == null || !scope._active) return null;
  return scope;
}

Future<T> runInPatchbayGateAdmissionScope<T>({
  required bool skipBase,
  required Set<String> admittedGateIds,
  void Function(String result)? onGateResult,
  void Function(String disposition)? onGateDisposition,
  void Function(String stage)? onAdmissionStage,
  required FutureOr<T> Function() body,
}) {
  final PatchbayGateAdmissionScope scope = PatchbayGateAdmissionScope(
    skipBase: skipBase,
    admittedGateIds: admittedGateIds,
    onGateResult: onGateResult,
    onGateDisposition: onGateDisposition,
    onAdmissionStage: onAdmissionStage,
  );
  return runZoned<Future<T>>(() async {
    try {
      return await body();
    } finally {
      scope.close();
    }
  }, zoneValues: <Object?, Object?>{_patchbayGateAdmissionScopeKey: scope});
}
