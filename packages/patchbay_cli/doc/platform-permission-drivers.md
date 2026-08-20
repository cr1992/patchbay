# Platform permission drivers

Patchbay keeps native permission UI outside all four public packages. The CLI ships two **source** adapters; it does not bundle adb, Xcode, test APKs, signed runners, or downloaded executables.

## Build and select an adapter

```console
dart compile exe bin/patchbay_permission_android.dart -o ~/.local/bin/patchbay-permission-android
dart compile exe bin/patchbay_permission_ios.dart -o ~/.local/bin/patchbay-permission-ios
export PATCHBAY_PERMISSION_DRIVER=~/.local/bin/patchbay-permission-android
patchbay --json doctor permission
```

`--permission-driver` overrides the environment for one invocation. Android also accepts `PATCHBAY_ADB` and `PATCHBAY_ANDROID_PERMISSION_RUNNER`; iOS accepts `PATCHBAY_XCRUN` and `PATCHBAY_IOS_PERMISSION_RUNNER`. Every value is explicit; the CLI never downloads a runner or chooses a different App/device after an error.

Android status/normalize/reset use adb package-manager facts. Exercise is only advertised when an explicitly built UiAutomator runner is configured and found on the selected device. The runner must return a `PATCHBAY_RESULT=<base64-json>` instrumentation status and must identify `targetPackage`, `permission`, and `decision`; mismatches are `systemUiUnexpected`.

iOS Simulator reset uses `simctl privacy`. simctl has no public authoritative status read, so status/normalize remain `permissionUnsupported` instead of turning a successful shell exit into a permission fact. Exercise is advertised only when an explicit XCUITest runner is configured; its one JSON result must bind device, application, permission, decision, handled state, and the observed platform state.

For 0.4.0, the supported device surface is deliberately narrower than the driver protocol: Android adb `capabilities/status/normalize/reset/fail` is release-gated, while generic system-dialog exercise, `allowOnce` decisions, iOS status/normalize/exercise, and permission-specific trace events are not. Patchbay does not ship or qualify a reference UiAutomator/XCUITest runner in this release. An explicitly supplied runner is an external extension and must not be inferred as portable OEM/platform support.

## 0.4.0 device checklist

The 0.4.0 permission gate uses the repository example before any optional consumer evidence:

1. Start a debug/profile App session and record its session, application and device identity.
2. Run `patchbay --session <id> --permission-driver <path> --json doctor permission`.
3. On an Android emulator and one adb device, cover camera/microphone/location/notifications status, normalize granted, reset and idempotent replay. Verify unreachable states fail before mutation and a wrong application/device is rejected.
4. Verify that missing or unproven runners do not advertise exercise/decisions. iOS status/normalize/exercise and system-dialog handling are typed unsupported/unavailable and do not block 0.4.0.

Building/signing reference runners and collecting Android OEM plus iOS Simulator/device dialog matrices are deferred work; unit fixtures must not be presented as that device evidence.
