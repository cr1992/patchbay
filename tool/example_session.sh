#!/usr/bin/env bash
# 在一台连着的设备上把仓内 example 跑起来，并交出可用的 VM Service URI。
#
# 支持 Android 真机/模拟器、iOS Simulator 和 iOS 真机；平台由 `flutter devices --machine`
# 判定，adb 专用的唤醒解锁只发给 Android。iOS 真机额外需要签名条件（见预构建失败时的提示）。
#
# 单独成文件的理由：本地端到端预检、临时手工排查和未来的 CI 冒烟都需要同一段
# 「装 App → 起 App → 取 URI」流程。这段流程本身容易出错（lifecycle 闸要求 resumed、
# URI 带认证材料不能落日志、example 没有入库的平台目录），复制三份必然漂移。
#
# 用法：
#   source tool/example_session.sh          # 提供函数，不自动执行
#   example_session_start [device-id]       # 起 App，导出 PATCHBAY_WS_URI
#   example_session_stop                    # 关 App，清理转发
#
# device-id 取自 `flutter devices`：Android 用 adb serial，iOS Simulator 用
# `xcrun simctl list devices` 的 UDID。省略时沿用旧行为，取第一台 online 的 adb 设备。
#
# 约定：
# - URI 只写进 mktemp 文件并导出到变量，任何日志输出都先脱敏；
# - 平台目录按需生成、不入库（见 example/README.md 与 example/.gitignore）；
# - 不接管 flutter run 的 stdio，用 --vmservice-out-file，与 docs/guide.md 的会话发现一致。

set -o pipefail

# 全角标点紧跟变量展开时**必须**写成 ${VAR} 而不是 $VAR。
# macOS 自带的 bash 3.2 在 C locale + `set -u` 下会把 `$VAR）` 的高位字节当成变量名的一部分，
# 于是读到一个未定义变量并以 127 静默退出——没有报错行，表现为"脚本跑到某处就没声了"。
# 预检脚本开着 `set -u`，所以这条不是风格问题而是可运行性问题。

PATCHBAY_REPO_ROOT="${PATCHBAY_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHBAY_EXAMPLE_DIR="$PATCHBAY_REPO_ROOT/packages/patchbay_flutter/example"
PATCHBAY_CLI_DIR="$PATCHBAY_REPO_ROOT/packages/patchbay_cli"

_example_session_run_pid=""
_example_session_uri_file=""
_example_session_log=""

# 预检要发四十多条命令。`dart run` 每次都重新编译，单步就是几秒；编一次原生可执行后
# 单步降到毫秒级，也与仓库发布的 AOT 形态一致。
#
# 产物目录按**检出**隔离：主检出与各 worktree 会并行存在，共用一个路径会互相覆盖——
# 既让指纹永远不命中（每次切换都白编一次），更糟的是可能拿另一个检出编出来的二进制去跑，
# 而那正是 AOT 唯一的真风险（不报错的过时答案）。
# `shasum` 是 perl 附带的，Linux runner 上不保证存在；`sha1sum` 是 coreutils 的，macOS 上没有。
# 两边都要跑，所以选一个可用的。
_patchbay_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum "$@"
  else
    sha1sum "$@"
  fi
}

_patchbay_checkout_key() {
  printf '%s' "$PATCHBAY_REPO_ROOT" | _patchbay_sha | awk '{print substr($1, 1, 12)}'
}
PATCHBAY_CLI_BIN="${PATCHBAY_CLI_BIN:-${TMPDIR:-/tmp}/patchbay-cli/$(_patchbay_checkout_key)/patchbay}"

# 一个调试任务里只编一次 CLI，任务期间一律复用同一份 AOT 产物。
#
# 判据是**源码指纹**而不是"每次启动都编"：一次任务里常要重启 App 多次，每次重编都是白等；
# 但产物过期又是 AOT 唯一的真风险——改了 CLI 源码却拿旧二进制，会得到一个看起来正常、不报错
# 的过时答案。所以按 CLI 与其依赖的 core 包的 .dart 内容取指纹，指纹变了才重编。
#
# 指纹连同 git revision 落进 <bin>.stamp 并导出 PATCHBAY_CLI_STAMP，预检报告头部打印它：
# 一份结论必须能回答"这是哪个 CLI 跑出来的"。
# 只哈希内容、不含文件路径：同一份源码在不同检出下必须得到同一个指纹，否则换个 worktree
# 就会被判成"源码有变"。
# 用 `-exec ... +` 而不是管道进 xargs：macOS 的 xargs 没有 GNU 的 `-r`，输入为空时它仍会执行
# 一次 `shasum`，那次调用会去读 stdin 并永久阻塞——脚本会挂死而不是报错。
# 排序放在哈希列上，因此指纹与文件遍历顺序无关。
example_session_cli_fingerprint() {
  find "$PATCHBAY_CLI_DIR/bin" "$PATCHBAY_CLI_DIR/lib" \
    "$PATCHBAY_REPO_ROOT/packages/patchbay/lib" \
    -type f -name '*.dart' -exec sh -c 'for f; do
      if command -v shasum >/dev/null 2>&1; then shasum "$f"; else sha1sum "$f"; fi
    done' sh {} + 2>/dev/null |
    awk '{print $1}' | sort | _patchbay_sha | awk '{print $1}'
}

example_session_build_cli() {
  mkdir -p "$(dirname "$PATCHBAY_CLI_BIN")"
  # 逐个声明并显式初始化：macOS 自带的 bash 3.2 在 `set -u` 下对
  # `local a b c=""` 这种合并声明有坑，会让整个脚本以 127 静默退出（无任何报错行）。
  # 预检脚本本身开着 `set -u`，所以这里必须用安全写法。
  local fingerprint=""
  local revision=""
  local dirty=""
  fingerprint="$(example_session_cli_fingerprint)"
  revision="$(git -C "$PATCHBAY_REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if ! git -C "$PATCHBAY_REPO_ROOT" diff --quiet 2>/dev/null; then dirty="+dirty"; fi
  PATCHBAY_CLI_STAMP="$revision$dirty ${fingerprint:0:12}"
  export PATCHBAY_CLI_STAMP

  if [ -x "$PATCHBAY_CLI_BIN" ] &&
    [ "$(cat "$PATCHBAY_CLI_BIN.fingerprint" 2>/dev/null)" = "$fingerprint" ]; then
    echo "[session] CLI 复用已编译产物（源 ${PATCHBAY_CLI_STAMP}）"
    printf '%s\n' "$PATCHBAY_CLI_STAMP" > "$PATCHBAY_CLI_BIN.stamp"
    return 0
  fi

  echo "[session] CLI 源码有变或首次运行，编译 AOT"
  # 所有被脚本调用的 dart/flutter 命令都显式给 </dev/null：脱离终端运行时它们会去读
  # stdin 并永久阻塞，表现是脚本卡住而不是报错。
  # 失败要自解释：静默退出会让调用方（预检脚本）看起来"什么都没发生就结束了"。
  if ! (cd "$PATCHBAY_CLI_DIR" && dart pub get </dev/null >/dev/null 2>&1); then
    echo "[session] dart pub get 失败（${PATCHBAY_CLI_DIR}）" >&2
    return 1
  fi
  if ! (cd "$PATCHBAY_CLI_DIR" &&
    dart compile exe bin/patchbay.dart -o "$PATCHBAY_CLI_BIN" </dev/null >/dev/null); then
    echo "[session] dart compile exe 失败（${PATCHBAY_CLI_DIR}）" >&2
    return 1
  fi
  printf '%s\n' "$fingerprint" > "$PATCHBAY_CLI_BIN.fingerprint"
  printf '%s\n' "$PATCHBAY_CLI_STAMP" > "$PATCHBAY_CLI_BIN.stamp"
  echo "[session] CLI 已编译（源 ${PATCHBAY_CLI_STAMP}）：$PATCHBAY_CLI_BIN"
}

example_session_device() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    printf '%s' "$requested"
    return 0
  fi
  adb devices | awk '$2 == "device" { print $1; exit }'
}

# 目标平台由 `flutter devices --machine` 判定，不靠 id 形状猜：adb serial、iOS Simulator UDID
# 和 iOS 真机 UDID 在形状上并不互斥，猜错会把 adb 专用步骤发到一台 iPhone 上。
#
# 输出封闭三值：android / ios-simulator / ios-device。判不出来就失败，不默认成 android——
# 默认成 android 的代价是后面每一步都以看不懂的方式失败。
example_session_platform() {
  local device="$1"
  local machine=""
  machine="$(cd "$PATCHBAY_EXAMPLE_DIR" && flutter devices --machine </dev/null 2>/dev/null)"
  printf '%s' "$machine" | python3 -c "
import json, sys
want = sys.argv[1]
try:
    devices = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for device in devices:
    if device.get('id') != want:
        continue
    platform = device.get('targetPlatform') or ''
    if platform.startswith('android'):
        print('android')
    elif platform.startswith('ios'):
        print('ios-simulator' if device.get('emulator') else 'ios-device')
    else:
        raise SystemExit(1)
    raise SystemExit(0)
raise SystemExit(1)
" "$device"
}

# example 不带平台目录（四包仓不维护 Android / iOS 工程）。按需生成，用完留在本地。
example_session_ensure_platform() {
  local platform="$1"
  local dir=""
  local flag=""
  case "$platform" in
    android)
      dir=android
      flag=android
      ;;
    ios-simulator | ios-device)
      dir=ios
      flag=ios
      ;;
    *)
      echo "[session] 不支持的目标平台：${platform}" >&2
      return 1
      ;;
  esac
  if [ -d "$PATCHBAY_EXAMPLE_DIR/$dir" ]; then
    # 已生成的工程也要过一遍：注入是幂等的，而权限声明是后加的要求，
    # 否则老检出会静默停在"当不了权限被试对象"的状态上。
    example_session_declare_permissions "$platform" || return 1
    return 0
  fi
  echo "[session] 生成 example 的 ${flag} 工程（不入库）"
  if ! (cd "$PATCHBAY_EXAMPLE_DIR" && flutter create --platforms="$flag" \
    --org dev.patchbay --project-name patchbay_flutter_example . >/dev/null </dev/null); then
    echo "[session] flutter create 失败（${PATCHBAY_EXAMPLE_DIR}）" >&2
    return 1
  fi
  # flutter create 顺手补的默认 widget 测试引用模板里的 MyApp，与本 example 的 main.dart
  # 不是一回事，留着会让 flutter analyze 变红。它是生成物，不入库也不该留在工作树里。
  rm -f "$PATCHBAY_EXAMPLE_DIR/test/widget_test.dart"
  example_session_declare_permissions "$platform" || return 1
  # flutter create 会自己跑一次**不受 lockfile 约束**的 pub，实测把被追踪的 example lock 里
  # vm_service 从 15.2.0 顶到 15.3.0。这里只告警不代改：静默 `git checkout --` 会把开发者
  # 有意的 lock 改动一并吃掉，而一次"只是生成工程"的动作不该拥有那种权力。
  if ! git -C "$PATCHBAY_REPO_ROOT" diff --quiet -- \
    packages/patchbay_flutter/example/pubspec.lock 2>/dev/null; then
    echo "[session] 注意：flutter create 改动了被追踪的 example pubspec.lock。" >&2
    echo "[session] 这不是预检的意图，提交前请复核并复原该文件。" >&2
  fi
}

# 让 example 成为一个合格的**权限被试对象**。
#
# `flutter create` 生成的工程只声明 INTERNET，`dumpsys package` 的 `runtime permissions:`
# 段是空的。于是 P0 四权限在设备上根本没有可读事实，Android adapter 的状态查询会因为
# "正则没匹配"退化成 `permissionUnsupported`——仓内因此从来跑不出一份权限矩阵，不是
# 因为没验，而是因为唯一的测试 App 当不了被试对象。
#
# 声明写在生成物里而不是入库工程里：四包仓不维护平台工程（见 example/.gitignore），
# 所以按需注入、幂等，重复调用不会写重复条目。声明 ≠ 请求：`pm grant/revoke` 对已声明的
# 运行时权限即可工作，因此 status / normalize / reset 的矩阵不需要 App 主动发起请求；
# 真实弹窗 exercise 才需要，那条由 example 的域命令触发。
example_session_declare_permissions() {
  local platform="$1"
  case "$platform" in
    android)
      local manifest="$PATCHBAY_EXAMPLE_DIR/android/app/src/main/AndroidManifest.xml"
      [ -f "$manifest" ] || return 0
      if grep -q 'android.permission.CAMERA' "$manifest"; then
        return 0
      fi
      echo "[session] 给生成的 Android 工程注入 P0 权限声明（不入库）"
      python3 - "$manifest" <<'PY' || return 1
import re, sys
path = sys.argv[1]
source = open(path, encoding='utf-8').read()
declarations = '\n'.join(
    '    <uses-permission android:name="android.permission.%s"/>' % name
    for name in (
        'CAMERA',
        'RECORD_AUDIO',
        'ACCESS_FINE_LOCATION',
        'POST_NOTIFICATIONS',
    )
)
updated = re.sub(
    r'(<manifest[^>]*>\n)',
    r'\1' + declarations + '\n',
    source,
    count=1,
)
if updated == source:
    raise SystemExit('manifest 结构不认识，未注入')
open(path, 'w', encoding='utf-8').write(updated)
PY
      ;;
    ios-simulator | ios-device)
      local plist="$PATCHBAY_EXAMPLE_DIR/ios/Runner/Info.plist"
      [ -f "$plist" ] || return 0
      if grep -q 'NSCameraUsageDescription' "$plist"; then
        return 0
      fi
      echo "[session] 给生成的 iOS 工程注入 P0 用途声明（不入库）"
      # iOS 上缺 usage description 不是"权限被拒"，而是**进程直接崩**。所以这四条是
      # 能不能跑权限路径的前提，不是可选的礼貌项。
      local key
      for key in NSCameraUsageDescription NSMicrophoneUsageDescription \
        NSLocationWhenInUseUsageDescription; do
        /usr/libexec/PlistBuddy -c "Add :$key string Patchbay example permission probe" \
          "$plist" >/dev/null 2>&1 || true
      done
      ;;
  esac
}

example_session_start() {
  local device
  device="$(example_session_device "${1:-}")"
  if [ -z "$device" ]; then
    echo "[session] 没有可用设备：未指定 id，且 adb 里也没有 online 的设备" >&2
    return 1
  fi
  local platform=""
  platform="$(example_session_platform "$device")"
  if [ -z "$platform" ]; then
    echo "[session] flutter devices 里没有 id=${device}，或其平台不受支持" >&2
    echo "[session] 可用设备见：flutter devices" >&2
    return 1
  fi
  PATCHBAY_SESSION_PLATFORM="$platform"
  export PATCHBAY_SESSION_PLATFORM
  echo "[session] device=$device platform=$platform"

  # UI 面有 lifecycle 闸：App 不在 resumed 时 ui.* / navigation.* 全部按
  # *LifecycleNotResumed 拒绝。息屏或锁屏就会踩到，所以先把设备弄成可交互状态。
  case "$platform" in
    android)
      adb -s "$device" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
      adb -s "$device" shell wm dismiss-keyguard >/dev/null 2>&1 || true
      adb -s "$device" shell svc power stayon true >/dev/null 2>&1 || true
      ;;
    ios-simulator)
      # 未启动的 Simulator 上 flutter run 会自己拉起，但拉起过程里 App 可能先落到
      # 非 resumed；显式 boot 并等到 booted 再跑，省掉这一类偶发失败。
      xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
      ;;
    ios-device)
      # 真机无法从命令行解锁：锁屏时 UI 面会整片按 *LifecycleNotResumed 拒绝。
      echo "[session] iOS 真机请保持解锁并信任本机，否则 UI 面会按 lifecycle 闸拒绝" >&2
      ;;
  esac

  example_session_ensure_platform "$platform" || return 1

  # --enforce-lockfile：预检不得改动被追踪的 pubspec.lock。实测不加这个参数时，一次
  # 预检会把 example 的 lock 里 vm_service 从 15.2.0 顺手升到 15.3.0——一次"只读的验证"
  # 悄悄改了随版依赖，而仓内多处以 15.2.0 为评审基准。
  if ! (cd "$PATCHBAY_EXAMPLE_DIR" && flutter pub get --enforce-lockfile >/dev/null </dev/null); then
    echo "[session] example flutter pub get 失败（lock 与 pubspec 不一致时也会失败）" >&2
    return 1
  fi
  example_session_build_cli || {
    echo "[session] CLI 准备失败，终止" >&2
    return 1
  }

  # 冷构建和「App 起不起来」是两件事，分开跑才能一眼看出断在哪一头，
  # 也让后面的启动步骤不再包含几分钟的构建时间。
  # --no-pub：依赖已由上一步以 --enforce-lockfile 取好。不加这个参数时 flutter build 会
  # 自己再跑一次 pub，那次不受 lockfile 约束，实测会把被追踪的 example lock 改掉。
  local build_label=""
  local built=0
  case "$platform" in
    android) build_label="debug APK" ;;
    ios-simulator) build_label="debug .app（Simulator，不需要签名）" ;;
    ios-device) build_label="debug .app（真机，需要签名）" ;;
  esac
  echo "[session] 预构建 ${build_label}（首次最慢）"
  case "$platform" in
    android)
      (cd "$PATCHBAY_EXAMPLE_DIR" &&
        flutter build apk --debug --no-pub >/dev/null 2>&1 </dev/null) || built=$?
      ;;
    ios-simulator)
      (cd "$PATCHBAY_EXAMPLE_DIR" &&
        flutter build ios --debug --simulator --no-pub >/dev/null 2>&1 </dev/null) || built=$?
      ;;
    ios-device)
      (cd "$PATCHBAY_EXAMPLE_DIR" &&
        flutter build ios --debug --no-pub >/dev/null 2>&1 </dev/null) || built=$?
      ;;
  esac
  if [ "$built" != 0 ]; then
    echo "[session] 预构建失败（${build_label}）" >&2
    if [ "$platform" = ios-device ]; then
      # iOS 真机的头号失败原因是签名，而签名只能人工配一次，脚本代不了。
      echo "[session] iOS 真机需要有效的开发团队与 provisioning profile：" >&2
      echo "[session]   Xcode > Settings > Accounts 登录账号，再在 example/ios 里选定 team" >&2
      echo "[session] 没有签名条件时改用 iOS Simulator 的 UDID（xcrun simctl list devices）" >&2
    fi
    return 1
  fi

  _example_session_uri_file="$(mktemp "${TMPDIR:-/tmp}/patchbay-vmservice.XXXXXX")"
  _example_session_log="$(mktemp "${TMPDIR:-/tmp}/patchbay-flutter-run.XXXXXX")"
  rm -f "$_example_session_uri_file"

  echo "[session] flutter run（日志：${_example_session_log}）"
  (cd "$PATCHBAY_EXAMPLE_DIR" && flutter run -d "$device" --debug \
    --vmservice-out-file "$_example_session_uri_file" \
    >"$_example_session_log" 2>&1 </dev/null &
    echo $! >"$_example_session_uri_file.pid")
  sleep 1
  _example_session_run_pid="$(cat "$_example_session_uri_file.pid" 2>/dev/null || true)"

  local waited=0
  while [ "$waited" -lt 300 ]; do
    if [ -n "$_example_session_run_pid" ] && \
       ! kill -0 "$_example_session_run_pid" 2>/dev/null; then
      echo "[session] flutter run 已退出，App 没起来；日志尾部：" >&2
      tail -n 40 "$_example_session_log" | example_session_redact >&2
      return 1
    fi
    [ -s "$_example_session_uri_file" ] && break
    sleep 5
    waited=$((waited + 5))
  done
  if [ ! -s "$_example_session_uri_file" ]; then
    echo "[session] ${waited}s 内没等到 VM Service URI" >&2
    tail -n 40 "$_example_session_log" | example_session_redact >&2
    return 1
  fi
  sleep 1
  export PATCHBAY_WS_URI="$(cat "$_example_session_uri_file")"
  echo "[session] 已取到 VM Service URI（内容不打印）"
}

example_session_stop() {
  if [ -n "$_example_session_run_pid" ]; then
    kill "$_example_session_run_pid" 2>/dev/null || true
  fi
  [ -n "$_example_session_uri_file" ] && \
    rm -f "$_example_session_uri_file" "$_example_session_uri_file.pid"
  unset PATCHBAY_WS_URI
}

# 跑一条 CLI 命令。URI 从环境取，不进命令行历史。
example_session_cli() {
  "$PATCHBAY_CLI_BIN" --ws-uri "$PATCHBAY_WS_URI" "$@"
}
