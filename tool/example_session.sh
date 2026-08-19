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

PATCHBAY_REPO_ROOT="${PATCHBAY_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHBAY_EXAMPLE_DIR="$PATCHBAY_REPO_ROOT/packages/patchbay_flutter/example"
PATCHBAY_CLI_DIR="$PATCHBAY_REPO_ROOT/packages/patchbay_cli"

_example_session_run_pid=""
_example_session_uri_file=""
_example_session_log=""

# 预检要发四十多条命令。`dart run` 每次都重新编译，单步就是几秒；编一次原生可执行后
# 单步降到毫秒级，也与仓库发布的 AOT 形态一致。
PATCHBAY_CLI_BIN="${PATCHBAY_CLI_BIN:-${TMPDIR:-/tmp}/patchbay-precheck/patchbay}"

# AOT 产物的唯一风险是过期：改了 CLI 源码而没重编时，二进制会给出一个看起来正常但过时的
# 答案，且不会报错。所以每次会话都重编（约 2 秒），并把来源 revision 落成标记文件——
# 一份预检报告因此能回答"这是哪个 CLI 跑出来的"。
example_session_build_cli() {
  mkdir -p "$(dirname "$PATCHBAY_CLI_BIN")"
  (cd "$PATCHBAY_CLI_DIR" && dart pub get >/dev/null 2>&1 &&
    dart compile exe bin/patchbay.dart -o "$PATCHBAY_CLI_BIN" >/dev/null) || return 1
  local revision dirty=""
  revision="$(git -C "$PATCHBAY_REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if ! git -C "$PATCHBAY_REPO_ROOT" diff --quiet 2>/dev/null; then dirty="+dirty"; fi
  PATCHBAY_CLI_STAMP="$revision$dirty"
  export PATCHBAY_CLI_STAMP
  printf '%s\n' "$PATCHBAY_CLI_STAMP" > "$PATCHBAY_CLI_BIN.stamp"
  echo "[session] CLI 已编译（源 $PATCHBAY_CLI_STAMP）：$PATCHBAY_CLI_BIN"
}

# 脱敏后打印一段文本：VM Service URI 带认证 token，不能原样进日志。
example_session_redact() {
  sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g'
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
  (cd "$PATCHBAY_EXAMPLE_DIR" && flutter create --platforms=android \
    --org dev.patchbay --project-name patchbay_flutter_example . >/dev/null)
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

  (cd "$PATCHBAY_EXAMPLE_DIR" && flutter pub get >/dev/null) || return 1
  example_session_build_cli || return 1

  # Gradle 冷构建和「App 起不起来」是两件事，分开跑才能一眼看出断在哪一头，
  # 也让后面的启动步骤不再包含几分钟的构建时间。
  echo "[session] 预构建 debug APK（首次最慢）"
  (cd "$PATCHBAY_EXAMPLE_DIR" && flutter build apk --debug >/dev/null 2>&1) || {
    echo "[session] APK 构建失败" >&2
    return 1
  }

  _example_session_uri_file="$(mktemp -t patchbay-vmservice)"
  _example_session_log="$(mktemp -t patchbay-flutter-run)"
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
