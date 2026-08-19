#!/usr/bin/env bash
# 在一台连着的 Android 设备上把仓内 example 跑起来，并交出可用的 VM Service URI。
#
# 单独成文件的理由：本地端到端预检、临时手工排查和未来的 CI 冒烟都需要同一段
# 「装 App → 起 App → 取 URI」流程。这段流程本身容易出错（lifecycle 闸要求 resumed、
# URI 带认证材料不能落日志、example 没有入库的平台目录），复制三份必然漂移。
#
# 用法：
#   source tool/example_session.sh          # 提供函数，不自动执行
#   example_session_start [adb-serial]      # 起 App，导出 PATCHBAY_WS_URI
#   example_session_stop                    # 关 App，清理转发
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

# example 不带平台目录（四包仓不维护一套 Android 工程）。按需生成，用完留在本地。
example_session_ensure_android() {
  if [ -d "$PATCHBAY_EXAMPLE_DIR/android" ]; then
    return 0
  fi
  echo "[session] 生成 example 的 Android 工程（不入库）"
  if ! (cd "$PATCHBAY_EXAMPLE_DIR" && flutter create --platforms=android \
    --org dev.patchbay --project-name patchbay_flutter_example . >/dev/null </dev/null); then
    echo "[session] flutter create 失败（${PATCHBAY_EXAMPLE_DIR}）" >&2
    return 1
  fi
  # flutter create 顺手补的默认 widget 测试引用模板里的 MyApp，与本 example 的 main.dart
  # 不是一回事，留着会让 flutter analyze 变红。它是生成物，不入库也不该留在工作树里。
  rm -f "$PATCHBAY_EXAMPLE_DIR/test/widget_test.dart"
}

example_session_start() {
  local device
  device="$(example_session_device "${1:-}")"
  if [ -z "$device" ]; then
    echo "[session] adb 里没有 online 的设备" >&2
    return 1
  fi
  echo "[session] device=$device"

  # UI 面有 lifecycle 闸：App 不在 resumed 时 ui.* / navigation.* 全部按
  # *LifecycleNotResumed 拒绝。息屏或锁屏就会踩到，所以先唤醒解锁再启动。
  adb -s "$device" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$device" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb -s "$device" shell svc power stayon true >/dev/null 2>&1 || true

  example_session_ensure_android || return 1

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

  # Gradle 冷构建和「App 起不起来」是两件事，分开跑才能一眼看出断在哪一头，
  # 也让后面的启动步骤不再包含几分钟的构建时间。
  echo "[session] 预构建 debug APK（首次最慢）"
  # --no-pub：依赖已由上一步以 --enforce-lockfile 取好。不加这个参数时 flutter build 会
  # 自己再跑一次 pub，那次不受 lockfile 约束，实测会把被追踪的 example lock 改掉。
  (cd "$PATCHBAY_EXAMPLE_DIR" &&
    flutter build apk --debug --no-pub >/dev/null 2>&1 </dev/null) || {
    echo "[session] APK 构建失败" >&2
    return 1
  }

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
