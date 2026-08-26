# iOS XCUITest permission runner

这个工程是 Patchbay 的外部系统权限 companion，只使用 XCTest 公共 API：

- 对 camera、microphone、locationWhenInUse 调用 `resetAuthorizationStatus(for:)`；
- 在 App 自己发起权限请求后，从 SpringBoard accessibility tree 校验权限身份并操作唯一匹配的 decision；
- 支持英语、简体中文和繁体中文；其他语言在 capability 阶段 fail-closed；
- 不使用坐标、截图识别、私有 API，也不修改接入方工程。

## 构建

真机 runner 必须在使用者自己的 Xcode 签名环境中生成。选择一个不与接入方冲突的中性 bundle prefix：

```console
$ xcodebuild build-for-testing \
    -project companions/ios-xcuitest/PatchbayPermissionRunner.xcodeproj \
    -scheme PatchbayPermissionRunner \
    -destination 'generic/platform=iOS' \
    PATCHBAY_DEVELOPMENT_TEAM=<team-id> \
    PATCHBAY_RUNNER_BUNDLE_PREFIX=com.example.patchbay.permission \
    -derivedDataPath <derived-data>
```

从 `<derived-data>/Build/Products/` 选择生成的 `.xctestrun`，再编译两个 Dart AOT 入口：

```console
$ dart compile exe packages/patchbay_cli/bin/patchbay_permission_ios.dart \
    -o <bin-dir>/patchbay_permission_ios
$ dart compile exe packages/patchbay_cli/bin/patchbay_permission_ios_xcuitest.dart \
    -o <bin-dir>/patchbay_permission_ios_xcuitest
```

运行 CLI 时显式配置两层 driver：

```console
$ PATCHBAY_IOS_PERMISSION_RUNNER=<bin-dir>/patchbay_permission_ios_xcuitest \
  PATCHBAY_IOS_XCTESTRUN=<signed-file.xctestrun> \
  patchbay --permission-driver <bin-dir>/patchbay_permission_ios \
    permission capabilities --session <session-id> --json
```

`PATCHBAY_IOS_XCTESTRUN` 必须是绝对路径。runner 会复制并注入本次 request 的 device/application/permission
环境变量；原始签名产物和接入方 Xcode 工程不会被改写。

## 能力边界

| 权限 | reset | exercise decisions |
|---|---|---|
| camera | 是 | allow / deny |
| microphone | 是 | allow / deny |
| locationWhenInUse | 是 | allow / deny / allowOnce |
| notifications | 否 | allow / deny（仅处理 App 已触发的弹窗） |

物理真机 `status/normalize` 没有权威公共事实源，保持 unsupported。系统弹窗必须由目标 App 自己发起；
companion 不替 App 调用权限 API，也不会看到任意弹窗就点击。
