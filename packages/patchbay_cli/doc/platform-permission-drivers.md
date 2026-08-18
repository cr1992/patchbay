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

Android status/normalize/reset use adb package-manager facts. Exercise is only advertised when an explicitly built UiAutomator runner is configured. The runner must return a `PATCHBAY_RESULT=<base64-json>` instrumentation status and must identify `targetPackage`, `permission`, and `decision`; mismatches are `systemUiUnexpected`.

iOS Simulator reset uses `simctl privacy`. simctl has no public authoritative status read, so status/normalize remain `permissionUnsupported` instead of turning a successful shell exit into a permission fact. Exercise is advertised only when an explicit XCUITest runner is configured; its one JSON result must bind device, application, permission, decision, handled state, and the observed platform state.

## Moii app device checklist (post-code handoff)

The 0.4.0 device gate uses **moii app**, not the Patchbay example:

1. Start a debug/profile moii app session and record its real session ID, application ID, device ID and driver path. Never reuse example identifiers.
2. Run `patchbay --session <id> --permission-driver <path> --json doctor permission`.
3. Android emulator and one adb device: camera/microphone/location/notifications status, normalize, reset, allow, deny and allow-once where the OS advertises them. Verify a wrong moii application/device is rejected before mutation.
4. iOS Simulator: reset each supported protected resource. Run the configured XCUITest companion against moii app and archive unsupported resources as typed capability results. A signed iOS device run owns the final matrix.
5. After every handled dialog, assert moii app resumed, the session reconnected, catalog was refreshed, and identifiers/generations were re-resolved. The original permission-triggering command must not be replayed automatically.

SDK installation, test-runner build/signing and the device evidence above are the remaining true-device work; they are intentionally not simulated by unit fixtures.
