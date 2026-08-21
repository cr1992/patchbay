// 拆分前 `doctor.dart` 的公共面，见 trace.dart 的说明。
export 'doctor/doctor_checks.dart'
    show
        patchbayActiveSessionWarnings,
        patchbayCapabilityWarnings,
        patchbayCatalogDigestDetails,
        patchbayCatalogFinding,
        patchbayFailureFinding,
        patchbayIdentityFinding,
        patchbayLifecycleBanner,
        patchbayLifecycleBannerFor,
        patchbayLifecycleFinding,
        patchbaySessionDirectoryFinding,
        patchbaySessionFinding,
        probePatchbayLifecycle;
export 'doctor/doctor_models.dart';
export 'doctor/doctor_runner.dart';
