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

The supported device surface is deliberately narrower than the driver protocol. Android adb provides the baseline `capabilities/status/normalize/reset/fail` surface; `exercise` appears only when a configured runner is discovered on the selected device. The repository and source archive also ship a buildable [iOS XCUITest reference runner](https://github.com/cr1992/patchbay/tree/main/companions/ios-xcuitest): on a physical iPhone it can reset camera, microphone, and locationWhenInUse, then handle allow/deny plus location allowOnce after the target App has initiated its own permission request. Physical-device iOS status/normalize, notification reset and permission-specific trace events remain unsupported.

The iOS project is not inside the pub package and no signed artifact is distributed. Build it with the local Xcode account/team, compile `bin/patchbay_permission_ios_xcuitest.dart`, point `PATCHBAY_IOS_XCTESTRUN` at the absolute signed `.xctestrun`, and set `PATCHBAY_IOS_PERMISSION_RUNNER` to that wrapper. The runner uses public XCTest APIs and SpringBoard accessibility identity matching for English, simplified Chinese and traditional Chinese; other languages fail closed. It never edits a consumer Xcode project or clicks coordinates.

## Device validation checklist

Use the repository example before any optional consumer evidence:

1. Start a debug/profile App session and record its session, application and device identity.
2. Run `patchbay --session <id> --permission-driver <path> --json doctor permission`.
3. On an Android emulator and one adb device, cover camera/microphone/location/notifications status, normalize granted, reset and idempotent replay. Verify unreachable states fail before mutation and a wrong application/device is rejected.
4. Verify that missing or unproven runners do not advertise exercise/decisions. On a signed iPhone consumer, cover camera/microphone/location reset and at least microphone allow/deny plus location allowOnce. iOS status/normalize and notification reset must remain typed unsupported rather than being reported as verified.

Android OEM dialog handling and the complete iOS notification matrix are outside the current verified surface; unit fixtures must not be presented as device evidence. `resetAuthorizationStatus(for:)` may terminate the debug App, so the setup phase can require rerunning the consumer's official run/attach tool before triggering the alert. Reset is not an invisible in-process transition.
